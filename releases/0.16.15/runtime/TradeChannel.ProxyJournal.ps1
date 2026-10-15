# Persist only in the restricted data root. Values never appear in diagnostics.
function Get-TCProxyValueSnapshot {
 $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$false)
 try{
  $values=[ordered]@{}
  foreach($name in @('ProxyEnable','ProxyServer','AutoConfigURL')){
   $exists=$key.GetValueNames() -contains $name
   $values[$name]=[pscustomobject]@{Exists=$exists;Value=$(if($exists){$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}else{$null});Kind=$(if($exists){[string]$key.GetValueKind($name)}else{$null})}
  }
  [pscustomobject]$values
 }finally{$key.Dispose()}
}
function Send-TCProxyChangeNotification {
 . (Join-Path $PSScriptRoot 'TradeChannel.Components.ps1')
 Initialize-TCRuntimeComponent -Name TCDevicePath
 if(-not [TCDevicePath]::NotifyProxyChange()){throw '[TC:ProxyRefreshFailed] 代理值已写入，系统通知未完成，请核对普通网络。'}
}
function Set-TCProxyValueSnapshot {param($Snapshot,[string[]]$Names=@('ProxyEnable','ProxyServer','AutoConfigURL'))
 $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings',$true)
 try{foreach($name in $Names){$entry=$Snapshot.$name;if($entry.Exists){$key.SetValue($name,$entry.Value,[Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$entry.Kind)))}else{$key.DeleteValue($name,$false)}}}finally{$key.Dispose()}
 Send-TCProxyChangeNotification
}
function Get-TCProxyRecoveryDecision {param($Entry,$Current,[bool]$SessionEnded,[string]$CurrentSid)
 if(-not $SessionEnded){return 'SessionAlive'}
 if($Entry.UserSid -cne $CurrentSid){return 'DifferentUser'}
 $now=$Current|ConvertTo-Json -Depth 8 -Compress
 if($now -ceq ($Entry.Expected|ConvertTo-Json -Depth 8 -Compress)){return 'Restore'}
 if($now -ceq ($Entry.Before|ConvertTo-Json -Depth 8 -Compress)){return 'AlreadyRestored'}
 return 'Conflict'
}
function Test-TCProxyJournalOwnerEnded {param($Entry)
 # PID reuse never grants ownership. Read failure is uncertainty, not exit.
 try{$p=Get-Process -Id ([int]$Entry.ProcessId) -ErrorAction Stop;try{return ($p.StartTime.ToUniversalTime().Ticks -ne [long]$Entry.ProcessStartedTicks)}finally{$p.Dispose()}}
 catch [Microsoft.PowerShell.Commands.ProcessCommandException]{return $true}
 catch{return $false}
}
function Restore-TCProxyJournal {param([string]$Root,[string]$CompletedSessionId='')
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $dir=New-TCDDirectory (Join-Path $Root 'proxy-recovery');$lock=Open-TCDLock (Join-Path $dir '.recovery.lock')
 try{Restore-TCProxyJournalCore $Root $CompletedSessionId}finally{$lock.Dispose()}
}
function Restore-TCProxyJournalCore {param([string]$Root,[string]$CompletedSessionId='')
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $dir=Join-Path $Root 'proxy-recovery';if(-not [IO.Directory]::Exists($dir)){return [pscustomobject]@{Restored=0;Conflicts=0}}
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$restored=0;$conflicts=0
 $files=@(Get-ChildItem -LiteralPath $dir -File -Filter '*.json'|Sort-Object Name -Descending)
 foreach($file in $files){
  $entry=Read-TCDJson $file.FullName
  if($entry.SchemaVersion -ne 1 -or $entry.Stage -in @('Restored','Unchanged','UserRestored','UserKeptCurrent')){continue}
  $ended=($CompletedSessionId -and $entry.SessionId -ceq $CompletedSessionId) -or (Test-TCProxyJournalOwnerEnded $entry)
  $decision=Get-TCProxyRecoveryDecision $entry (Get-TCProxyValueSnapshot) $ended $sid
  if($decision -eq 'Restore'){Set-TCProxyValueSnapshot $entry.Before -Names @($entry.Name);$entry.Stage='Restored';$restored++}
  elseif($decision -eq 'AlreadyRestored'){$entry.Stage='Unchanged'}
  elseif($decision -eq 'Conflict'){$entry.Stage='Conflict';$conflicts++}
  else{continue}
  Write-TCDJson $file.FullName $entry
 }
 [pscustomobject]@{Restored=$restored;Conflicts=$conflicts}
}
function Get-TCProxyRecoveryEntries {param([string]$Root)
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $dir=Join-Path $Root 'proxy-recovery';if(-not [IO.Directory]::Exists($dir)){return}
 foreach($file in @(Get-ChildItem -LiteralPath (Assert-TCDPath $dir) -File -Filter '*.json'|Sort-Object Name)){
  $entry=Read-TCDJson $file.FullName
  if($entry.SchemaVersion -ne 1 -or $entry.Name -notin @('ProxyEnable','ProxyServer','AutoConfigURL')){throw '[TC:ProxyJournalInvalid] 代理恢复记录无法核验。'}
  if($entry.Stage -notin @('Restored','Unchanged','UserRestored','UserKeptCurrent')){[pscustomobject]@{Path=$file.FullName;Entry=$entry}}
 }
}
function Get-TCProxyRecoveryStatus {param([string]$Root)
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 $entries=@(Get-TCProxyRecoveryEntries $Root|Where-Object {$_.Entry.UserSid -ceq $sid})
 foreach($group in @($entries|Group-Object {$_.Entry.SessionId})){
  $ended=@($group.Group|Where-Object {-not (Test-TCProxyJournalOwnerEnded $_.Entry)}).Count -eq 0
  [pscustomobject]@{SessionId=$group.Name;CanResolve=$ended;State=$(if($ended){'NeedsReview'}else{'SessionAlive'});Changes=@($group.Group.Entry.Name|Select-Object -Unique);AtUtc=$group.Group[0].Entry.AtUtc;Message=$(if($ended){'原连接已结束，代理设置有待恢复或后续修改，请选择保留当前设置或恢复原设置。'}else{'原会话仍在运行，保留当前代理设置。'})}
 }
}
function Invoke-TCProxyRecoveryChoice {param([string]$Root,[string]$SessionId,[ValidateSet('KeepCurrent','RestorePrevious')][string]$Choice,[string]$PreviewToken='')
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $dir=New-TCDDirectory (Join-Path $Root 'proxy-recovery');$lock=Open-TCDLock (Join-Path $dir '.recovery.lock')
 try{
  $all=@(Get-TCProxyRecoveryEntries $Root);$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $rows=@($all|Where-Object {$_.Entry.SessionId -ceq $SessionId -and $_.Entry.UserSid -ceq $sid})
  if(-not $rows.Count){throw '[TC:ProxyRecoveryStale] 这份代理恢复记录已变化。'}
  if(@($all|Where-Object {$_.Entry.UserSid -ceq $sid -and -not (Test-TCProxyJournalOwnerEnded $_.Entry)}).Count){throw '[TC:SessionActive] 仍有原会话在使用代理设置，请结束后再处理。'}
  $current=Get-TCProxyValueSnapshot;$expiry=[DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()
  if($PreviewToken){if($PreviewToken -notmatch '^pr1:(\d+):([a-f0-9]{64})$'){throw '[TC:ProxyRecoveryStale] 缺少有效恢复预览。'};$expiry=[long]$matches[1];if($expiry -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()){throw '[TC:ProxyRecoveryStale] 恢复预览已过期。'}}
  $token='pr1:'+$expiry+':'+(Get-TCDDigest @{Rows=$rows;Current=$current;User=$sid;Choice=$Choice;Expiry=$expiry})
  if(-not $PreviewToken){return [pscustomobject]@{SessionId=$SessionId;Choice=$Choice;PreviewToken=$token;Message=$(if($Choice -eq 'KeepCurrent'){'保留当前系统代理设置，并结束这次遗留恢复提醒。'}else{'恢复本程序在这次会话首次修改前的相关代理字段；其他代理字段保持。'})}}
  if($PreviewToken -cne $token){throw '[TC:ProxyRecoveryStale] 当前设置或记录已变化，请重新预览。'}
  if($Choice -eq 'RestorePrevious'){
   $target=$current|ConvertTo-Json -Depth 8|ConvertFrom-Json;$names=@($rows.Entry.Name|Select-Object -Unique)
   foreach($name in $names){$first=@($rows|Where-Object {$_.Entry.Name -ceq $name})[0];$target.$name=$first.Entry.Before.$name}
   if((Get-TCDDigest (Get-TCProxyValueSnapshot)) -cne (Get-TCDDigest $current)){throw '[TC:ProxyRecoveryStale] 代理刚被其他程序修改，请重新核对。'}
   Set-TCProxyValueSnapshot $target -Names $names
  }
  foreach($row in $rows){$row.Entry.Stage=if($Choice -eq 'KeepCurrent'){'UserKeptCurrent'}else{'UserRestored'};Write-TCDJson $row.Path $row.Entry}
  [pscustomobject]@{Resolved=$true;Choice=$Choice;SessionId=$SessionId;TradingProtectionChanged=$false}
 }finally{$lock.Dispose()}
}
function Set-TCProxyJournaledValue {param([string]$Root,[string]$SessionId,[ValidateSet('ProxyEnable','AutoConfigURL')][string]$Name,$Value,[switch]$Remove)
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $dir=New-TCDDirectory (Join-Path $Root 'proxy-recovery');$lock=Open-TCDLock (Join-Path $dir '.recovery.lock')
 try{Set-TCProxyJournaledValueCore -Root $Root -SessionId $SessionId -Name $Name -Value $Value -Remove:$Remove}finally{$lock.Dispose()}
}
function Set-TCProxyJournaledValueCore {param([string]$Root,[string]$SessionId,[ValidateSet('ProxyEnable','AutoConfigURL')][string]$Name,$Value,[switch]$Remove)
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
 $before=Get-TCProxyValueSnapshot;$expected=$before|ConvertTo-Json -Depth 8|ConvertFrom-Json
 $expected.$Name=[pscustomobject]@{Exists=(-not $Remove);Value=$(if($Remove){$null}else{$Value});Kind=$(if($Remove){$null}elseif($Name -eq 'ProxyEnable'){'DWord'}else{'String'})}
 $owner=[Diagnostics.Process]::GetCurrentProcess()
 try{$entry=[pscustomobject]@{SchemaVersion=1;SessionId=$SessionId;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ProcessId=$PID;ProcessStartedTicks=$owner.StartTime.ToUniversalTime().Ticks;AtUtc=[DateTimeOffset]::UtcNow.ToString('o');Stage='Pending';Before=$before;Expected=$expected}}finally{$owner.Dispose()}
 $directory=New-TCDDirectory (Join-Path $Root 'proxy-recovery');$path=Join-Path $directory ([DateTimeOffset]::UtcNow.Ticks.ToString('D19')+'-'+[guid]::NewGuid().ToString('N')+'.json')
 $entry|Add-Member NoteProperty Name $Name
 Write-TCDJson $path $entry -NewOnly
 # Recheck after write-ahead persistence so a concurrent user edit is retained.
 if(((Get-TCProxyValueSnapshot)|ConvertTo-Json -Depth 8 -Compress) -cne ($before|ConvertTo-Json -Depth 8 -Compress)){$entry.Stage='Conflict';Write-TCDJson $path $entry;return $false}
 Set-TCProxyValueSnapshot $expected -Names @($Name)
 $entry.Stage='Applied';Write-TCDJson $path $entry;return $true
}
