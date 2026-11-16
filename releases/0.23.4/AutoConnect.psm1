#requires -Version 5.1
<#
Step 3 integration contract (the owner of Worker/RuntimeBridge wires these):
1. Worker actions AutoConnectPreview / AutoConnectCommit load this module. Pass
   Root, StartupLaunch, SelfTest, ReadOnlyLaunch; Commit additionally requires
   RecordSHA256, PreviewToken and the worker-owned RequestId. Reject isolated
   worker contexts. Preview is a 45s read; Commit is a 240s global mutation.
   The private CTPreview/CTExecute seams preserve the saved Intent. The public
   ConnectionSwitchPreview API has no Intent parameter and is insufficient.
2. SetUserSetting/AutoConnectOnLogin calls Set-TCLoginAutoConnect
   (UserSettings.psm1); ordinary SetStartup requests keep their current meaning.
3. ConnectionTransactions records success ONLY after a Completed transaction
   and a fresh matching runtime observation, using Save-TCLastSuccessfulConnection
   -Root -Transaction <full persisted journal> -Observed <runtime observation>.
   Cover Session Connect and ConnectionSwitchCommit through the bridge. Do not
   record previews, failed/rolled-back attempts, Disconnect or routine Overview
   reads. A save failure is a warning, not a reason to roll back a live connection.
4. BuildPreviewCore includes UserSettings.psm1 + AutoConnect.psm1 in the package
   and its checksum manifest, and rebuilds Launcher.cs. No extra scheduled task.

Import/reads never write or connect. The UI owns one bounded login attempt; this
module rechecks the real state at preview AND commit. CTExecute still owns locks,
preflight, token expiry/replay, full binding validation, deadlines and rollback.
Tests replace only private adapters, never inject executable callbacks via JSON.
#>
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'UserSettings.psm1') -DisableNameChecking

function ACField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name}
 return $Default
}
function ACPath {param([string]$Path)
 if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')){throw '[TC:AutoConnectBinding] 自动连接资料必须位于本机绝对路径。'}
 $full=[IO.Path]::GetFullPath($Path);$cursor=$full
 while($cursor){
  if(Test-Path -LiteralPath $cursor -ErrorAction Stop){if((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '[TC:AutoConnectBinding] 自动连接资料不能经过重解析点。'}}
  $cursor=[IO.Path]::GetDirectoryName($cursor)
 }
 return $full
}
function ACHash {param([string]$Path) (Get-FileHash -LiteralPath (ACPath $Path) -Algorithm SHA256 -ErrorAction Stop).Hash}
function ACRecordPath {param([string]$Root) ACPath (Join-Path (ACPath $Root) 'last-successful-connection.json')}
function ACIntent {param($Intent)
 $body=[ordered]@{}
 foreach($key in @('Mode','Exit','Daily','NodeId','ProfileId','ProviderId','TradeProviderId','Agents','AgentIds','AgentCustom')){
  if($null -eq $Intent -or $null -eq $Intent.PSObject.Properties[$key]){throw '[TC:AutoConnectBinding] 上次成功连接的分流资料不完整。'}
  $body[$key]=$Intent.$key
 }
 if($body.Mode -cnotin @('Trading','Global') -or $body.Exit -cne 'HongKong' -or $body.Daily -cnotin @('Direct','Provider') -or $body.Agents -cnotin @('Daily','Trade') -or $body.ProfileId -cnotin @('Udp','Tcp') -or -not $body.NodeId){throw '[TC:AutoConnectBinding] 上次成功连接的选择无效；请手动连接。'}
 # Preserve empty arrays and explicit provider/agent choices; never merge newer
 # UI preferences into the saved successful intent.
 $body.AgentIds=@($body.AgentIds);$body.AgentCustom=@($body.AgentCustom)
 [pscustomobject]$body
}
function ACAssertRecord {param($Record,[string]$Root)
 if((ACField $Record SchemaVersion) -ne 1 -or (ACField $Record Root '') -ine (ACPath $Root) -or -not (ACField $Record TransactionId '') -or -not (ACField $Record SessionId '')){throw '[TC:AutoConnectBinding] 上次成功连接记录无效。'}
 $intent=ACIntent (ACField $Record Intent)
 if($intent.NodeId -cne (ACField $Record NodeId) -or $intent.ProfileId -cne (ACField $Record ProfileId)){throw '[TC:AutoConnectBinding] 线路与连接方式绑定不一致。'}
 $binding=ACField $Record Binding
 foreach($key in @('ManifestSHA256','CandidateSHA256')){if((ACField $binding $key '') -cnotmatch '^[A-F0-9]{64}$'){throw '[TC:AutoConnectBinding] 上次成功连接缺少配置哈希。'}}
 foreach($key in @('ManifestPath','CandidatePath')){$null=ACPath ([string](ACField $binding $key ''))}
}
function ACAssertFiles {param($Record)
 $b=$Record.Binding
 if((ACHash $b.ManifestPath) -cne $b.ManifestSHA256 -or (ACHash $b.CandidatePath) -cne $b.CandidateSHA256){throw '[TC:AutoConnectBinding] 上次成功线路的配置已变化；本次不自动连接。'}
}
function Get-TCLastSuccessfulConnection {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
 $path=ACRecordPath $Root
 if(-not [IO.File]::Exists($path)){return $null}
 if((Get-Item -LiteralPath $path -ErrorAction Stop).Length -gt 65536){throw '[TC:AutoConnectBinding] 上次成功记录大小异常。'}
 $value=[IO.File]::ReadAllText($path,(New-Object Text.UTF8Encoding($false,$true))).TrimStart([char]0xfeff)|ConvertFrom-Json -ErrorAction Stop
 ACAssertRecord $value $Root
 return $value
}
function Save-TCLastSuccessfulConnection {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)]$Transaction,[Parameter(Mandatory=$true)]$Observed)
 # Legacy/provider-only connections cannot be converted into a different profile.
 if((ACField $Transaction Status) -cne 'Completed' -or (ACField $Transaction ProfileId) -cnotin @('Udp','Tcp')){return $false}
 $check=ACField $Transaction TargetCheck;$target=ACField $Transaction Target;$identity=ACField $Transaction CandidateIdentity
 if((ACField $Observed State) -cne 'Running' -or (ACField $Observed OwnershipKnown) -ne $true -or (ACField $check ExitHttp) -ne $true -or (ACField $check DnsHttps) -ne $true -or (ACField $check ExitVerified) -ne $true -or (ACField $check ProfileValidated) -ne $true -or (ACField $check ActualExit) -cne 'hk'){throw '[TC:AutoConnectUnverified] 不能记住尚未验证成功的线路。'}
 foreach($key in @('SessionId','SupervisorPid','SupervisorStartedAt','EnginePid','EngineStartedAt')){
  if(-not (ACField $identity $key) -or [string](ACField $identity $key) -cne [string](ACField $Observed $key)){throw '[TC:AutoConnectUnverified] 实际会话已变化，未更新成功记录。'}
 }
 if((ACField $Observed ManifestPath) -ine (ACField $Transaction ActiveManifestPath) -or (ACField $Observed CandidateSHA256) -cne (ACField $target CandidateSHA256) -or (ACField $Transaction TargetHash) -cne (ACField $target CandidateSHA256)){throw '[TC:AutoConnectUnverified] 成功会话的配置绑定不一致。'}
 $record=[pscustomobject][ordered]@{
  SchemaVersion=1;Root=(ACPath $Root);SucceededAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
  TransactionId=$Transaction.Id;SessionId=$Observed.SessionId;NodeId=$Transaction.LineId;ProfileId=$Transaction.ProfileId
  Intent=(ACIntent $Transaction.Intent)
  Binding=[pscustomobject][ordered]@{ManifestPath=$target.ManifestPath;ManifestSHA256=$target.ManifestSHA256;CandidatePath=$target.CandidatePath;CandidateSHA256=$target.CandidateSHA256}
 }
 ACAssertRecord $record $Root;ACAssertFiles $record
 $path=ACRecordPath $Root;$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  [IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Depth 30 -Compress),(New-Object Text.UTF8Encoding($true)))
  if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
 }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
 return $true
}
function Invoke-TCAutoConnectOperation {param([string]$Operation,[string]$Root,$Payload)
 $ct=Get-Module ConnectionTransactions|Select-Object -First 1
 if(-not $ct){$ct=Import-Module (Join-Path $PSScriptRoot 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking}
 & $ct {param($Op,$DataRoot,$Data)
  switch($Op){
   'Preflight'{CTRuntime 'Preflight' $DataRoot $null}
   'Observe'{CTRuntime 'Observe' $DataRoot $null}
   'Pending'{CTPending $DataRoot}
   'Preview'{CTPreview $DataRoot $Data.NodeId $Data.ProfileId $null $Data.Intent}
   'Commit'{CTExecute $DataRoot $Data.Record.NodeId $Data.Record.ProfileId $Data.PreviewToken $null $Data.Record.Intent -RequestId $Data.RequestId}
   default{throw 'Unknown auto-connect operation'}
  }
 } $Operation $Root $Payload
}
function ACAssertLaunch {param([string]$Root,[bool]$StartupLaunch,[bool]$SelfTest,[bool]$ReadOnlyLaunch)
 if(-not $StartupLaunch -or $SelfTest -or $ReadOnlyLaunch){throw '[TC:AutoConnectLaunch] 仅允许正常 Windows 登录启动尝试自动连接。'}
 if(-not (Get-TCUserSettings -Root $Root).AutoConnectOnLogin){throw '[TC:AutoConnectDisabled] 登录自动连接未开启。'}
 $null=Invoke-TCAutoConnectOperation 'Preflight' $Root $null
 if(Invoke-TCAutoConnectOperation 'Pending' $Root $null){throw '[TC:NeedsRecovery] 存在未决连接事务，未自动连接。'}
 $observed=Invoke-TCAutoConnectOperation 'Observe' $Root $null
 if((ACField $observed State) -cne 'Stopped' -or (ACField $observed OwnershipKnown) -ne $true){throw '[TC:AutoConnectState] 当前连接未被核验为完全停止，未自动连接。'}
}
function ACPreview {param([string]$Root,$Record)
 ACAssertFiles $Record
 $preview=Invoke-TCAutoConnectOperation 'Preview' $Root $Record
 if((ACField $preview CanSwitch) -ne $true -or (ACField $preview PreviewToken '') -cnotmatch '^ct1:\d+:[A-F0-9]{64}$'){throw '[TC:AutoConnectPreview] 上次成功线路未通过连接预览。'}
 $baseline=ACField $preview Baseline;$target=ACField $baseline Target
 if((ACField $preview LineId) -cne $Record.NodeId -or (ACField $preview ProfileId) -cne $Record.ProfileId -or (ACField (ACField $preview Observed) State) -cne 'Stopped'){throw '[TC:AutoConnectBinding] 预览线路或会话状态已变化。'}
 foreach($key in @('ManifestPath','ManifestSHA256','CandidatePath','CandidateSHA256')){
  if([string](ACField $target $key) -cne [string]$Record.Binding.$key){throw '[TC:AutoConnectBinding] 预览配置与上次成功线路不同。'}
 }
 $intent=ACIntent (ACField $baseline Intent)
 if(($intent|ConvertTo-Json -Depth 30 -Compress) -cne ((ACIntent $Record.Intent)|ConvertTo-Json -Depth 30 -Compress)){throw '[TC:AutoConnectBinding] 预览分流与上次成功设置不同。'}
 return $preview
}
function Get-TCAutoConnectPreview {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[switch]$StartupLaunch,[switch]$SelfTest,[switch]$ReadOnlyLaunch)
 ACAssertLaunch $Root $StartupLaunch $SelfTest $ReadOnlyLaunch
 $path=ACRecordPath $Root
 if(-not [IO.File]::Exists($path)){throw '[TC:AutoConnectMissing] 尚无验证成功的线路，请先手动连接一次。'}
 $hash=ACHash $path;$record=Get-TCLastSuccessfulConnection $Root;$preview=ACPreview $Root $record
 if((ACHash $path) -cne $hash){throw '[TC:AutoConnectBinding] 成功记录在预览期间发生变化。'}
 [pscustomobject]@{Ready=$true;NodeId=$record.NodeId;ProfileId=$record.ProfileId;PreviewToken=$preview.PreviewToken;RecordSHA256=$hash}
}
function Invoke-TCAutoConnectCommit {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[switch]$StartupLaunch,[switch]$SelfTest,[switch]$ReadOnlyLaunch,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-F0-9]{64}$')][string]$RecordSHA256,
  [Parameter(Mandatory=$true)][ValidatePattern('^ct1:\d+:[A-F0-9]{64}$')][string]$PreviewToken,[Parameter(Mandatory=$true)][string]$RequestId)
 ACAssertLaunch $Root $StartupLaunch $SelfTest $ReadOnlyLaunch
 $path=ACRecordPath $Root
 if((ACHash $path) -cne $RecordSHA256){throw '[TC:AutoConnectBinding] 成功记录已变化，请手动连接。'}
 $record=Get-TCLastSuccessfulConnection $Root;$null=ACPreview $Root $record
 if((ACHash $path) -cne $RecordSHA256){throw '[TC:AutoConnectBinding] 成功记录在核对期间发生变化。'}
 # Keep the original token, never substitute the token of the recheck. CTExecute
 # refuses changed observations/config/preferences, expired and replayed tokens.
 Invoke-TCAutoConnectOperation 'Commit' $Root ([pscustomobject]@{Record=$record;PreviewToken=$PreviewToken;RequestId=$RequestId})
}

function New-TCAutoConnectLaunch {
 [CmdletBinding()]param([switch]$StartupLaunch,[switch]$SelfTest,[switch]$ReadOnlyLaunch)
 @{Status=$(if($StartupLaunch -and -not $SelfTest -and -not $ReadOnlyLaunch){'Waiting'}else{'Skipped'});Reason='';Watch=[Diagnostics.Stopwatch]::StartNew()}
}
function Get-TCAutoConnectLaunchDecision {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][hashtable]$State,$Settings,$Overview,[bool]$Busy,[bool]$NetworkReady,[bool]$UserDisconnect,[double]$ElapsedSeconds)
 if($State.Status -cne 'Waiting'){return $false}
 $reason=''
 if($UserDisconnect){$reason='已选择手动操作'}
 elseif(-not (ACField $Settings AutoConnectOnLogin $false)){$reason='登录自动连接已关闭'}
 elseif((ACField $Overview NinjaRunning $false) -eq $true){$reason='NinjaTrader 正在运行'}
 elseif((ACField $Overview Running $false) -eq $true){$reason='通道已连接'}
 elseif($Overview -and ((ACField $Overview ReadState '') -eq 'Unknown' -or (ACField $Overview StateKey '') -cnotin @('Disconnected','Unconfigured'))){$reason='连接状态需要核对'}
 elseif($ElapsedSeconds -ge 30){$reason='等待网络或连接状态超过 30 秒'}
 if($reason){$State.Status='Skipped';$State.Reason=$reason;return $false}
 if($Busy -or -not $NetworkReady -or -not $Overview){return $false}
 $State.Status='Previewing'
 return $true
}
Export-ModuleMember -Function Get-TCLastSuccessfulConnection,Save-TCLastSuccessfulConnection,Get-TCAutoConnectPreview,Invoke-TCAutoConnectCommit,New-TCAutoConnectLaunch,Get-TCAutoConnectLaunchDecision
