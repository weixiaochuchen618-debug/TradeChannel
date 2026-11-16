#requires -Version 5.1
# 0.20 host contract for the three-step "add line" page.
#
# No window, no WebView2, no worker, no network: ui/WebShell.ps1 is dot-sourced
# into a fixture scope and the message entry point is called directly, which is
# exactly the seam the production WebView2 message handler uses.
[CmdletBinding()]
param([string]$PackageRoot='',[string]$ReportDirectory='')
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if(-not $ReportDirectory){$ReportDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tc-020-'+[guid]::NewGuid().ToString('N'))}
$reportRoot=[IO.Path]::GetFullPath($ReportDirectory)
$null=[IO.Directory]::CreateDirectory($reportRoot)
$script:Checks=New-Object 'Collections.Generic.List[string]'
$passed=$false;$failure=$null

function Check {param([bool]$Condition,[string]$Message)
 if(-not $Condition){throw $Message}
 $script:Checks.Add($Message)
}
function Field {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name}
 return $Default
}

# ---- fixture scope ----------------------------------------------------------
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-Pair-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$script:Root=$fixture;$script:Smoke=$false;$script:ReadOnly=$false;$script:Page='web';$script:WebPage='add-line';$script:Version='0.20.0'
$script:Requests=New-Object 'Collections.Generic.List[object]';$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Prefs=@{NodeId='';Daily='Direct';Agents='Daily';OpenAtLogin=$false}
$script:UserSettings=@{AutoTrustFirstConnection=$true;AutoConnectOnLogin=$false}
$script:Providers=@{Items=@()}
$script:Nodes=@()
$script:Overview=[pscustomobject]@{StateKey='Disconnected';Running=$false;ActiveLineId='';ActiveProfileId='';NodeName='';GuardState='Protected';NinjaRunning=$false}
$script:Job=$null;$script:JobQueue=@();$script:LastToast='';$script:WebTasks=@()
$script:BusyState=$false
$script:OverlayVisible='Collapsed'
$script:Window=[pscustomobject]@{}
$script:Window|Add-Member -MemberType ScriptMethod -Name FindName -Value {param($name) [pscustomobject]@{Visibility=$script:OverlayVisible;Text='';Content='';Opacity=1;IsHitTestVisible=$true} }
function StateKey {$script:Overview.StateKey}
function IsBusy {$script:BusyState}
function DailyLaneValue {$script:Prefs.Daily}
function UILineId($n){[string](Field $n LineId (Field $n id ''))}
function SetNavigationContext {param($Section,$View) $script:Navigation=@{Section=$Section;View=$View}}
function Toast($Value){$script:LastToast=[string]$Value;$script:Toasts.Add([string]$Value)}
function ErrorDialog($Message){throw $Message}
function StartJob {param($Request,$Complete,$Message='',$Transition='',[switch]$Silent,$Failed=$null,$OriginContext=$null,$CallbackContext=$null,[scriptblock]$Finalized=$null,[switch]$PassThru,$Lifecycle=$null)
 $script:Requests.Add(@{Kind='Job';Request=$Request;Complete=$Complete;Failed=$Failed;Context=$CallbackContext})
}
function StartUiCommand {param([string]$Module,[string]$Command,[hashtable]$Arguments,[scriptblock]$Complete,[scriptblock]$Failed,$Context,[string]$Message='')
 $script:Requests.Add(@{Kind='Memory';Module=$Module;Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context})
}
function FetchNodes {}

. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')

$origin='https://tradechannel.local/index.html'
function Send-Pair([hashtable]$Message) {InvokeTCWebMessage ($Message|ConvertTo-Json -Compress -Depth 8) $origin}
function New-Code {
 # A structurally valid TCI1 envelope. It is never validated here: the host only
 # checks the prefix and length before handing it to the worker.
 $payload=@{v=1;h='203.0.113.9';p=18443;i=[guid]::NewGuid().ToString();k=('A'*43);t=('b'*64);m=('SHA256:'+('c'*43));e=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()}|ConvertTo-Json -Compress
 return 'TCI1.'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))).Replace('+','-').Replace('/','_').TrimEnd('=')
}

try{
 # --- 1. message gates -------------------------------------------------------
 $allowedLine=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\WebShell.ps1'),[Text.Encoding]::UTF8)
 Check ($allowedLine -match "'pairOnline','pairCancel','pairReset'") 'pairOnline, pairCancel and pairReset are registered message types'
 $fieldsNeedle="elseif(`$type -ceq 'pairOnline'){@('Type','Id','Phase','Code','Name','Sequence')}"
 Check ($allowedLine.Contains($fieldsNeedle)) 'pairOnline has its own six-field whitelist (Id carries PairId)'
 # 0.22.0 A2: the invitation page has its own five-field whitelist.
 Check ($allowedLine.Contains("elseif(`$type -ceq 'invite'){@('Type','Id','Phase','Value','Sequence')}")) 'invite has its own five-field whitelist (Id carries the line, Value the lifetime)'
 $allowedStart=$allowedLine.IndexOf('$allowed=@(')
 $allowedEnd=$allowedLine.IndexOf(')',[Math]::Max(0,$allowedStart))
 $typeCount=@($allowedLine.Substring($allowedStart+11,$allowedEnd-$allowedStart-11).Split(',')).Count
 # Measured baseline: 0.19.1 ships 41 entries (the plan says 40); 0.20 adds three;
 # 0.21.2 adds lineServer (the drawer's server and devices entry); 0.22.0 adds invite.
 Check ($typeCount -eq 46) ('the allowed type list grew from 41 to 46 entries, got '+$typeCount)

 # A field outside the pair whitelist is rejected AND answered: toast + Ack.
 $script:WebAck=0;$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=(New-Code);Name='PC';Sequence=7;Command='evil'}
 Check ($null -eq $script:PairSession) 'an extra field cannot create a session'
 Check ($script:LastToast -ceq '这一步没有生效，请重试') 'a rejected pair message toasts instead of failing silently'
 Check ($script:WebAck -eq 7) 'a rejected pair message still advances Ack, so the page cannot stay busy'

 # Length gate: a pair message over 4096 bytes never reaches the handler.
 $script:WebAck=0;$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=('TCI1.'+('A'*5000));Name='PC';Sequence=8}
 Check ($null -eq $script:PairSession -and $script:WebAck -eq 0) 'oversized pair messages are dropped before the sequence gate'

 # Sequence replay is still refused (monotonicity is not relaxed).
 $script:WebAck=20;$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Reset';Sequence=20}
 Check ($script:LastToast -eq '') 'a replayed sequence number is refused'

 # --- 2. Verify: positive path ----------------------------------------------
 $script:WebAck=0;$script:LastToast='';$script:Requests.Clear();$script:PairSession=$null;$script:PairEpoch=0
 $code=New-Code
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=$code;Name='交易机-01';Sequence=1}
 Check ($script:Requests.Count -eq 1 -and $script:Requests[0].Kind -eq 'Memory' -and $script:Requests[0].Command -ceq 'New-TCPairOnlineEnrollment') 'Verify dispatches the existing in-memory enrollment command'
 Check ($script:Requests[0].Arguments.InvitationCode -ceq $code) 'the invitation code reaches the worker unchanged'
 $pair=GetTCWebPairView
 Check ($null -ne $pair) 'a legal Verify turns Pair from null into an object'
 Check ($pair.Phase -ceq 'Creating' -and $pair.StageLabel -ceq '正在确认邀请码') 'Verify enters the Creating phase with its own sentence'
 Check ($pair.Epoch -eq 0) 'Verify does not change the epoch'
 Check ((Field $script:PairSession Host '') -ceq '203.0.113.9') 'the host address is read from the envelope for display'
 Check (@($pair.Keys).Count -eq 15) ('Pair publishes exactly fifteen keys, got '+@($pair.Keys).Count)
 $expected=@('PairId','Epoch','Phase','StageLabel','DeploymentCompleteness','Host','Port','ExpiresAtUtc','DeviceName','LocalName','ErrorCode','ErrorMessage','NextAction','AtUtc','StageChangedAtUtc')
 Check ((@($pair.Keys) -join ',') -ceq ($expected -join ',')) 'the Pair key set is exactly the documented fifteen'

 # Completion callback moves to the resting Authorizing phase.
 $context=$script:Requests[0].Context
 & $script:Requests[0].Complete @{EnrollmentId='e'*32;ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o')} $context
 $pair=GetTCWebPairView
 Check ($pair.Phase -ceq 'Authorizing' -and $pair.StageLabel -ceq '邀请码已确认，可以加入这台电脑') 'a confirmed invitation waits for the local line name'
 Check ($pair.DeploymentCompleteness -ceq 'Unknown') 'completeness stays Unknown until the join finishes'

 # --- 3. Join requires the session id ---------------------------------------
 $script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Join';Id='ffffffffffffffffffffffffffffffff';Name='主线';Sequence=2}
 Check ($script:LastToast -ceq '这一步没有生效，请重试') 'Join with a foreign PairId is refused with a toast'
 Check ((GetTCWebPairView).Phase -ceq 'Authorizing') 'a refused Join leaves the phase untouched'

 $script:Requests.Clear();$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Join';Id=$pair.PairId;Name='香港主线';Sequence=3}
 Check ($script:Requests.Count -eq 1 -and $script:Requests[0].Request.Action -ceq 'PairOnlineFinish') 'Join dispatches the existing PairOnlineFinish job'
 Check ((GetTCWebPairView).LocalName -ceq '香港主线') 'the local line name is kept for PairComplete'
 Check ((GetTCWebPairView).Phase -ceq 'Authorizing' -and (GetTCWebPairView).StageLabel -ceq '正在为这台电脑开通线路') 'Join switches the stage sentence'

 & $script:Requests[0].Complete @{EnrollmentId=('e'*32);NodeName='服务器给的线路'} $script:Requests[0].Context
 Check ((GetTCWebPairView).Phase -ceq 'Preparing') 'the authorization callback enters Preparing'
 $inner=@($script:Requests|Where-Object {$_.Request.Action -ceq 'PairComplete'})
 Check ($inner.Count -eq 1 -and $inner[0].Request.Name -ceq '香港主线') 'PairComplete receives the local line name, not the server name'

 & $inner[0].Complete @{EnrollmentId=('e'*32);NodeId=('1'*32);RunId=('2'*32);DeploymentCompleteness='Complete'} $inner[0].Context
 $pair=GetTCWebPairView
 Check ($pair.Phase -ceq 'Complete' -and $pair.NextAction -ceq 'None') 'a complete deployment ends in Complete with no next action'
 Check ($pair.DeploymentCompleteness -ceq 'Complete') 'DeploymentCompleteness is projected, never Validation'

 # --- 4. Cancel while busy (the 0.19 defect) --------------------------------
 $script:BusyState=$true;$script:LastToast=''
 $before=(GetTCWebPairView).PairId
 Send-Pair @{Type='pairOnline';Phase='Cancel';Id=$before;Sequence=4}
 Check ($null -eq $script:PairSession) 'cancel clears the session even while IsBusy is true'
 Check ($script:PairEpoch -eq 1) 'cancel advances the session generation'
 $script:BusyState=$false

 # A late callback from the cancelled session must not resurrect it.
 & $inner[0].Complete @{EnrollmentId=('e'*32);NodeId=('1'*32);DeploymentCompleteness='Complete'} $inner[0].Context
 Check ($null -eq $script:PairSession) 'a callback from a cancelled session is ignored'

 # Cancel is idempotent.
 $script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Cancel';Id=$before;Sequence=5}
 Check ($null -eq $script:PairSession) 'cancel without a session succeeds silently'

 # --- 5. Reset and the legacy cancelWaiting path ----------------------------
 $script:PairSession=$null;$script:PairEpoch=0
 $script:Requests.Clear()
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=(New-Code);Name='PC';Sequence=6}
 $script:BusyState=$true
 Send-Pair @{Type='pairOnline';Phase='Reset';Sequence=7}
 Check ($null -eq $script:PairSession -and $script:PairEpoch -eq 1) 'reset clears the session and advances the generation'
 $script:WebPendingConnection=@{Id='l1';Name='主线';CreatedAt=[DateTime]::UtcNow;SessionId='s'}
 Send-Pair @{Type='cancelWaiting';Sequence=8}
 Check ($null -eq $script:WebPendingConnection) 'cancelWaiting is reachable while busy (it used to be unreachable inside the switch)'
 $script:BusyState=$false

 # --- 6. Overlay blocks the pair messages (accepted cost) -------------------
 $script:PairSession=$null;$script:PairEpoch=0;$script:OverlayVisible='Visible';$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=(New-Code);Name='PC';Sequence=9}
 Check ($null -eq $script:PairSession -and $script:LastToast -eq '') 'while a modal dialog is open a pair message changes nothing'
 $script:OverlayVisible='Collapsed'

 # --- 7. Error table: 22 rows, verbatim -------------------------------------
 $rows=[ordered]@{
  'InvalidOnlineInput'=@('这张邀请码不是本产品生成的，请让给你的人重新生成。','Reenter')
  'InvalidOnlineCode'=@('邀请码不完整或已损坏，请复制完整的一次性邀请码。','Reenter')
  'InvalidOnlineJson'=@('邀请码内容无法识别，请重新复制完整的一次性邀请码。','Reenter')
  'InvalidOnlineHost'=@('邀请码里的服务器地址无效，请让管理员重新生成。','Reenter')
  'OnlineInviteExpired'=@('邀请码已过期，请让管理电脑重新生成（可以设更长的有效期）。','Reenter')
  'InviteConsumed'=@('这张邀请码已经被用过了，请在原申请电脑上重试或索取新码。','Reenter')
  'OnlineInviteIdentityMismatch'=@('邀请码与本机原申请不匹配，请使用同一张邀请码重试。','ContinueJoin')
  'PairingBusy'=@('本机正在完成这个申请，请稍后再试。','Retry')
  'InvalidDeviceName'=@('这台电脑的名称必须是 1–64 个字符，首尾不能有空格。','FixName')
  'OnlineEnrollmentConflict'=@('这台电脑上同一张邀请码已有多份申请，请先恢复原申请再试。','UseLegacyForm')
  'InvalidOnlineResponse'=@('服务器返回的登记结果无法核对，本次没有登记成功。','Retry')
  'OnlineAuthorizationMismatch'=@('服务器给的授权不属于这台电脑的申请，没有采用。','Retry')
  'InvalidOnlineEnrollment'=@('本机的在线申请记录损坏，需要重新开始一次申请。','UseLegacyForm')
  'OnlineSourceMissing'=@('这台电脑缺少在线登记所需的组件，请修复安装后重试。','Diagnostics')
  'OnlineSourceTooLarge'=@('在线登记组件超出大小限制，请修复安装后重试。','Diagnostics')
  'InvalidOnlineSshReply'=@('服务器返回的结果无法对应本次邀请码操作，没有采用。','Retry')
  'OnlineOperationFailed'=@('服务器没有完成这次邀请码操作；重试会沿用原申请。','Retry')
  'EnrollmentMismatch'=@('本机保存的申请、密钥或签名身份与服务器返回不一致，没有采用。','Retry')
  'AuthorizationUnavailable'=@('本机没有可恢复的已验签授权，请重新取得一次服务器返回。','Retry')
  'OnlineInvitationUnavailable'=@('这一步没有完成。','Retry')
  'OnlineEnrollmentIncomplete'=@('这台电脑的线路还没有设置完。','ContinueJoin')
  'WorkerStepFailed'=@('需要联网才能校验邀请码；请检查网络后重试。','Retry')
 }
 Check ($rows.Count -eq 22) 'the error table has 22 rows (19 host codes + 2 fallbacks + 1 transport)'
 foreach($code in $rows.Keys){
  $copy=GetTCWebPairErrorCopy $code ''
  Check ($copy.Message -ceq $rows[$code][0]) ('error copy matches for '+$code)
  Check ($copy.NextAction -ceq $rows[$code][1]) ('next action matches for '+$code)
 }
 $unknown=GetTCWebPairErrorCopy 'SomeUnregisteredCode' '宿主自己写的中文句子。'
 Check ($unknown.Message -ceq '宿主自己写的中文句子。') 'an unregistered code prefers the host sentence'
 $bare=GetTCWebPairErrorCopy 'SomeUnregisteredCode' ''
 Check ($bare.Message -ceq '这一步没有完成') 'an unregistered code falls back to 这一步没有完成, never to a network claim'
 Check ($bare.Message -cnotmatch '联网') 'the old network claim is gone'

 # InvalidDeviceName is refused locally and asks for a name, not a network check.
 $script:PairSession=$null;$script:PairEpoch=0;$script:Requests.Clear();$script:LastToast=''
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=(New-Code);Name=('X'*65);Sequence=10}
 Check ($script:Requests.Count -eq 0) 'an invalid device name never reaches the worker'
 Check ((GetTCWebPairView).ErrorCode -ceq 'InvalidDeviceName' -and (GetTCWebPairView).NextAction -ceq 'FixName') 'an invalid device name asks for a fix, not a retry'
 Check ((GetTCWebPairView).Epoch -eq 0) 'a failed verification keeps the epoch, so the pasted code survives'

 # --- 8. Quality30m projection ---------------------------------------------
 $script:HistoryCalls=0
 function Get-TCLineQualityHistory {param($Root,[string[]]$NodeId=@(),[string]$ProfileId='',[string]$Exit='',$SessionId='',[string]$Window='Day',[scriptblock]$Clock)
  $script:HistoryCalls++
  $buckets=@(); for($i=0;$i -lt 60;$i++){$buckets+=[pscustomobject]@{AverageLatencyMs=$(if($i -lt 22){120+$i*20}else{$null});MeasuredCount=$(if($i -lt 22){1}else{0})}}
  $stats=[pscustomobject]@{SampleCount=25;MeasuredCount=22;UnavailableCount=3;TimeoutCount=3;ControllerUnavailableCount=0}
  return [pscustomobject]@{Series=@([pscustomobject]@{Binding=@{NodeId=$NodeId[0];ProfileId='Udp';Exit='hk'};Aggregate=[pscustomobject]@{Statistics=$stats;Buckets=$buckets}})}
 }
 $line=@{LineId='11111111-1111-1111-1111-111111111111';Name='主线'}
 $q=GetTCWebQuality30m $line 'Udp'
 Check ($null -ne $q) 'the 30 minute projection is produced from the store'
 Check ($q.SampleCount -eq 25 -and $q.MeasuredCount -eq 22 -and $q.UnavailableCount -eq 3 -and $q.TimeoutCount -eq 3 -and $q.ControllerUnavailableCount -eq 0) 'the projection carries the five counters'
 Check ($q.Samples.Count -eq 60) 'the projection always carries 60 buckets'
 # Exact key set, not a count: the P50/P95 series were added on purpose so the
 # chart can show "usual" and "worst" separately, and a bare count would keep
 # passing if one of them were silently dropped.
 $qualityKeys=@('SampleCount','MeasuredCount','UnavailableCount','TimeoutCount','ControllerUnavailableCount','Samples','MedianSamples','P95Samples','MedianLatencyMs','P95LatencyMs','AtUtc')
 $qualityDiff=@(Compare-Object @($q.Keys|Sort-Object) @($qualityKeys|Sort-Object))
 Check ($qualityDiff.Count -eq 0) ('Quality30m publishes exactly the documented eleven keys, got '+(($q.Keys|Sort-Object) -join ','))
 $script:HistoryCalls=0;$script:WebQuality30m=@{};$script:WebQuality30mAt=@{}
 for($i=0;$i -lt 120;$i++){$null=GetTCWebQuality30m $line 'Udp'}
 Check ($script:HistoryCalls -le 4) ('120 snapshot builds read the store at most 4 times, got '+$script:HistoryCalls)
 $q=GetTCWebQuality30m $line 'Udp'
 Check ($q.MeasuredCount -eq 22) 'a cached projection still returns the same figures'

 # --- 9. Snapshot wiring ----------------------------------------------------
 $script:Page='web';$script:WebFormActive=$false
 $script:Nodes=@([pscustomobject]@{LineId='11111111-1111-1111-1111-111111111111';Name='主线';Profiles=@(@{Id='Udp';PreparationState='SyntaxValidated'});SavedConnectionPreference=@{ProfileId='Udp'}})
 $snapshot=GetTCWebSnapshot
 Check ($snapshot.Contains('Pair')) 'the snapshot publishes Pair'
 Check ($snapshot.Lines[0].PSObject.Properties.Name -contains 'Quality30m') 'each line publishes Quality30m'
 Check ($snapshot.ExitEvidence.ContainsKey('ObservedIP')) 'the exit evidence publishes ObservedIP'
 $script:Overview|Add-Member NoteProperty RuntimeValidation ([pscustomobject]@{ServerAttributionVerified=$false;Status='Passed';Code='';ValidatedAt=[DateTimeOffset]::UtcNow.ToString('o');ObservedIP='198.51.100.7'}) -Force
 $evidence=GetTCWebExitEvidence $script:Overview
 Check ($evidence.ObservedIP -ceq '198.51.100.7') 'ObservedIP is projected when the runtime reports it'
 $script:Overview.PSObject.Properties.Remove('RuntimeValidation')
 $evidence=GetTCWebExitEvidence $script:Overview
 Check ($null -eq $evidence.ObservedIP) 'ObservedIP stays null when the runtime has no address'

 # No secret ever reaches the snapshot.
 $script:PairSession=$null
 Send-Pair @{Type='pairOnline';Phase='Verify';Code=(New-Code);Name='PC';Sequence=11}
 $json=(GetTCWebSnapshot|ConvertTo-Json -Depth 8 -Compress)
 Check ($json -cnotmatch 'TCI1\.') 'the snapshot never contains the invitation code'
 Check ($json -cnotmatch 'TlsSha256') 'the snapshot never contains the TLS pin'
 $pairKeys=@((GetTCWebPairView).Keys)
 Check ($pairKeys -notcontains 'Code' -and $pairKeys -notcontains 'Token') 'Pair has no Code or Token key'

 # --- 10. Routing and navigation -------------------------------------------
 $shell=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\WebShell.ps1'),[Text.Encoding]::UTF8)
 Check ($shell -match "ValidateSet\('home','lines','apps','settings','add-line'") 'ShowTCWebShell accepts add-line'
 Check ($shell -match "ValidateSet\('home','lines','apps','settings','add-line'[^)]*'invite'") 'ShowTCWebShell accepts the invitation page too'
 Check ($shell -match "\`$page -cnotin @\('home','lines','apps','settings','add-line'[^)]*'invite'") 'the navigate whitelist accepts add-line and invite'
 $nav=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\NavigationContext.ps1'),[Text.Encoding]::UTF8)
 Check ($nav -match "@\('home','lines','apps','settings','add-line'") 'the return stack accepts the four pages and add-line'
 # 0.22.1: the invitation page needs its server id back, so it gets its own branch
 # instead of riding along in the page list.
 Check ($nav -match "\`$view -ceq 'invite'") 'the return stack accepts the invitation page'
 $app=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'web\app.js'),[Text.Encoding]::UTF8)
 Check ($app -match "'add-line':'添加线路'") 'the browser page table knows add-line'
 Check ($app -match "'add-line':addLine") 'the render map has an explicit add-line entry'
 Check ($app -match "PAGE_PARENT\[page\] \|\| page") 'the sidebar highlight follows PAGE_PARENT'

 $passed=$true
}catch{
 $failure=[pscustomobject]@{Message=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage;Stack=$_.ScriptStackTrace}
}finally{
 $result=[ordered]@{Passed=$passed;Checks=$script:Checks.Count;Assertions=@($script:Checks);Failure=$failure;PowerShellVersion=$PSVersionTable.PSVersion.ToString();Scope='Dot-sourced WebShell message entry point; no window, worker, network or production data'}
 $json=$result|ConvertTo-Json -Depth 8
 [IO.File]::WriteAllText((Join-Path $reportRoot 'Test-020PairOnline.json'),$json,(New-Object Text.UTF8Encoding($false)))
 Write-Output ($json -replace "`r?`n",' ')
}
