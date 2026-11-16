#requires -Version 5.1
Set-StrictMode -Version 2
# The per-machine switches the console owns: remembering a first-seen server identity,
# reconnecting after Windows restarts, and whether a degraded line raises a banner.
# Stored in ui-settings.json under the product root.
# An unreadable or unexpected file never changes behaviour silently: it falls back to the
# defaults and reports a warning, and the original file is left in place.
$script:TCSettingDefaults=[ordered]@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false;QualityWarning=$true}
function Get-TCUserSettingsPath {
 param([Parameter(Mandatory=$true)][string]$Root)
 if($Root -notmatch '^[A-Za-z]:[\\/]'){throw '[TC:SettingsPath] 设置目录必须是本机绝对路径。'}
 $full=[IO.Path]::GetFullPath($Root)
 if(-not [IO.Path]::IsPathRooted($full) -or $full.StartsWith('\\')){throw '[TC:SettingsPath] 设置目录必须是本机绝对路径。'}
 $path=Join-Path $full 'ui-settings.json';$cursor=$path
 while($cursor){
  if(Test-Path -LiteralPath $cursor -ErrorAction Stop){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '[TC:SettingsPath] 设置路径不能经过重解析点。'}}
  $cursor=[IO.Path]::GetDirectoryName($cursor)
 }
 $path
}
function Get-TCUserSettings {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
 $path=Get-TCUserSettingsPath $Root
 $result=[ordered]@{Source='Default';Warning=''}
 foreach($key in $script:TCSettingDefaults.Keys){$result[$key]=$script:TCSettingDefaults[$key]}
 if(-not [IO.File]::Exists($path)){return [pscustomobject]$result}
 try{
  $info=New-Object IO.FileInfo $path
  if($info.Length -gt 4096){throw 'too large'}
  $value=[IO.File]::ReadAllText($path,(New-Object Text.UTF8Encoding($false,$true))).TrimStart([char]0xfeff)|ConvertFrom-Json
  if($null -eq $value -or $value -isnot [pscustomobject]){throw 'not an object'}
  foreach($key in $script:TCSettingDefaults.Keys){
   $property=$value.PSObject.Properties[$key]
   if($property){if($property.Value -isnot [bool]){throw 'not boolean'};$result[$key]=[bool]$property.Value}
  }
  $result.Source='Saved'
 }catch{
  foreach($key in $script:TCSettingDefaults.Keys){$result[$key]=$script:TCSettingDefaults[$key]}
  $result.Source='Corrupt';$result.Warning='界面设置文件无法读取，已使用默认值；原文件保留。保存新设置时会覆盖它。'
 }
 [pscustomobject]$result
}
function Set-TCUserSetting {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][ValidateSet('AutoTrustFirstConnection','AutoConnectOnLogin','QualityWarning')][string]$Name,[Parameter(Mandatory=$true)][bool]$Value)
 $path=Get-TCUserSettingsPath $Root
 if(-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw '[TC:SettingsPath] 设置目录不存在。'}
 $current=Get-TCUserSettings -Root $Root
 $body=[ordered]@{}
 foreach($key in $script:TCSettingDefaults.Keys){$body[$key]=[bool]$current.$key}
 $body[$Name]=$Value
 $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $body -Compress),(New-Object Text.UTF8Encoding($true)))
  if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
 Get-TCUserSettings -Root $Root
}
function Test-TCStartupStateVerified {
 param($State)
 if($null -eq $State){return $false}
 $enabledProperty=$State.PSObject.Properties['Enabled']
 $verifiedProperty=$State.PSObject.Properties['Verified']
 # Reject old/malformed contracts without strict-mode property exceptions or
 # truthy string coercion. Only Startup's explicit boolean proof is accepted.
 return ($null -ne $enabledProperty -and $enabledProperty.Value -is [bool] -and
  $null -ne $verifiedProperty -and $verifiedProperty.Value -is [bool] -and $verifiedProperty.Value)
}
# Worker integration: SetUserSetting/AutoConnectOnLogin calls this wrapper.
# Persist only after the existing protected UI task has been verified. Turning
# auto-connect off retains UI startup; it never disconnects an existing session.
function Set-TCLoginAutoConnect {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][bool]$Enabled,[string]$SourceDirectory=$PSScriptRoot)
 if(-not $Enabled){return Set-TCUserSetting -Root $Root -Name AutoConnectOnLogin -Value $false}
 $null=Get-TCUserSettingsPath $Root
 if(-not (Get-Command Set-TCStartup -ErrorAction SilentlyContinue)){Import-Module (Join-Path $PSScriptRoot 'Startup.psm1') -DisableNameChecking}
 $prior=Get-TCStartup
 if(-not (Test-TCStartupStateVerified $prior)){throw '[TC:StartupUnverified] 登录任务状态无法核验，自动连接设置未保存。'}
 try{
  $started=Set-TCStartup -Enabled $true -SourceDirectory $SourceDirectory
  if(-not (Test-TCStartupStateVerified $started) -or -not $started.Enabled){throw '登录任务启用后未通过核验。'}
  return Set-TCUserSetting -Root $Root -Name AutoConnectOnLogin -Value $true
 }catch{
  $failure=$_.Exception.Message
  # Existing enabled UI startup stays enabled (its package may have refreshed).
  # If we enabled it here, undo that change, including a failed readback after
  # registration. Ownership checks in Set-TCStartup are never bypassed.
  if(-not $prior.Enabled){
   try{
    $rolledBack=Set-TCStartup -Enabled $false -SourceDirectory $SourceDirectory
    if(-not (Test-TCStartupStateVerified $rolledBack) -or $rolledBack.Enabled){throw '登录任务回滚后未通过核验。'}
   }
   catch{throw ('[TC:StartupRollbackFailed] 自动连接设置未保存：'+$failure+'；登录任务回滚未完成：'+$_.Exception.Message+'。请核对登录启动设置。')}
  }
  throw ('[TC:StartupSettingFailed] 自动连接设置未保存，保留原设置；登录 UI 启用状态已还原。'+$failure)
 }
}
# 0.18.4: "set as default line" for the home page only. A separate UI-only file: the engine, connection
# transactions, routing preferences and login auto-connect never read it.
function Get-TCHomeLinePath {param([Parameter(Mandatory=$true)][string]$Root)
 $settings=Get-TCUserSettingsPath $Root
 Join-Path ([IO.Path]::GetDirectoryName($settings)) 'ui-home-line.json'
}
function Get-TCHomeLineId {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
 $path=Get-TCHomeLinePath $Root
 if(-not [IO.File]::Exists($path)){return ''}
 try{
  if((New-Object IO.FileInfo $path).Length -gt 1024){return ''}
  $value=[IO.File]::ReadAllText($path,(New-Object Text.UTF8Encoding($false,$true))).TrimStart([char]0xfeff)|ConvertFrom-Json
  $id=[string]$value.HomeLineId
  if($id -cmatch '\A[A-Za-z0-9._-]{1,64}\z'){return $id}
 }catch{}
 return ''
}
function Set-TCHomeLineId {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[string]$Id='')
 $path=Get-TCHomeLinePath $Root
 if(-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($path))){throw '[TC:SettingsPath] 设置目录不存在。'}
 if($Id -and $Id -cnotmatch '\A[A-Za-z0-9._-]{1,64}\z'){throw '[TC:HomeLineInvalid] 线路编号无效。'}
 if(-not $Id){if([IO.File]::Exists($path)){[IO.File]::Delete($path)};return ''}
 $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject ([ordered]@{HomeLineId=$Id}) -Compress),(New-Object Text.UTF8Encoding($true)))
  if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
 return $Id
}
Export-ModuleMember -Function Get-TCUserSettings,Set-TCUserSetting,Set-TCLoginAutoConnect,Get-TCHomeLineId,Set-TCHomeLineId
