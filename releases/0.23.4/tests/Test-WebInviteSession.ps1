#requires -Version 5.1
# 0.22.0 A3 + A5 host-side acceptance.
#
# The web invitation page drives the SSH management session headlessly. Before
# 0.22.0 every completion, failure and poll of that session ended in
# ShowServerManagement, which rewrote the page and the Role - so a web page that
# reused it was either replaced by the server page or never saw its result.
#
# This fixture loads the real ui/BackgroundJobs.ps1, ui/ServerPages.ps1,
# ui/OnlinePairingPages.ps1, ui/WebShell.ps1 and ui/WebInvite.ps1 and replaces
# only the boundaries that need a live window, a worker or disk:
#   ShowServerManagement (counted), StartUiCommand, StartJob (which still asks the
#   real TestUiJobCallbackContext about admission), SyncTCWebState, Toast,
#   ErrorDialog, OpenDialog, CopyText, the intent file store, the task lease,
#   module loading and the saved-credential reader.
# No directory, credential, session, worker or network call is created.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
# Named only; this fixture never creates it.
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-web-invite-'+[guid]::NewGuid().ToString('N'))
$script:Checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$script:Checks.Add($Name)}

. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')
. (Join-Path $script:PackageRoot 'ui\WebInvite.ps1')

# ---- boundaries -----------------------------------------------------------------
$script:Shows=0;$script:Syncs=0;$script:CredentialReads=0;$script:Copied=''
$script:Jobs=New-Object 'Collections.Generic.List[object]'
$script:Commands=New-Object 'Collections.Generic.List[object]'
$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Dialogs=New-Object 'Collections.Generic.List[string]'
$script:Closed=New-Object 'Collections.Generic.List[string]'
function ShowServerManagement {$script:Shows=$script:Shows+1}
function SyncTCWebState {param([switch]$Force)$script:Syncs=$script:Syncs+1}
function Toast {param([string]$Text)$script:Toasts.Add([string]$Text)}
function ErrorDialog {param([string]$Text)$script:Dialogs.Add([string]$Text)}
# The invitation page has no modal: every refusal must reach it through the model.
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Style,$Context)throw 'The web invitation page must not open a native modal.'}
function IsBusy {return $false}
function CopyText {param([string]$Text,[string]$Done='')$script:Copied=[string]$Text;if($Done){$script:Toasts.Add([string]$Done)};return $true}
function CloseUiDeploymentSession {param($SessionRef)if($SessionRef){$script:Closed.Add([string]$SessionRef.InstanceId)}}
function Open-TCServerTaskLease {param($Root,$ServerId)New-Object IO.MemoryStream}
# The intent record itself is still built by the real NewManagementIntent; only
# the file write is dropped, because this fixture must not touch disk.
function SaveManagementIntent {param($Intent)}
function Import-Module {param($Name,[switch]$DisableNameChecking)}
function UIProductPath {param([string]$Leaf)return $Leaf}
function GetOnlineInviteFingerprintUI {return 'FIXTURE-MANAGEMENT-FINGERPRINT'}
function Get-TCDeploySavedCredential {param($Root,$CredentialRef,$Binding,$CurrentManagementSigningKeyDigest)
 $script:CredentialReads=$script:CredentialReads+1
 return @{Kind='Password';Password=(ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force)}
}
# 0.23.0: the availability gate and the identity proof are plaintext metadata reads
# and an I/O leaf respectively, so the fixture replaces them here. The real contract
# is covered by Test-DeploymentTaskCredentials and the record-side probe.
function Get-TCDeploySavedCredentialInfo {param($Root,$CredentialRef,$Binding,$CurrentManagementSigningKeyDigest)
 [pscustomobject]@{Status='Available';CredentialKind='Password';SavedAtUtc='2026-10-25T00:00:00.0000000Z';KeyPathHint=$null;BindingDigest=('0'*64)}
}
function Get-TCServerCredentialBinding {param($Record,[ValidateSet('Password','PrivateKey','')][string]$CredentialKind)
 [ordered]@{ServerRecordId=[string](ServerUIGet $Record LocalRecordId '');Host='192.0.2.10';Port=22;User='root';PinnedHostKey=('SHA256:'+('A'*43));IdentityTransitionRevision=0}
}
function Get-TCDDigest {param($Value)return ('0'*64)}
function StartUiCommand {param([string]$Module,[string]$Command,[hashtable]$Arguments,[scriptblock]$Complete,[scriptblock]$Failed,$Context,[string]$Message='')
 $script:Commands.Add([pscustomobject]@{Module=$Module;Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context;Message=$Message})
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$OriginContext=$null,$CallbackContext=$null,[scriptblock]$Finalized=$null,[switch]$PassThru,$Lifecycle=$null)
 # Admission is decided by the real gate, exactly as a dispatched job would be.
 $script:Jobs.Add([pscustomobject]@{Request=$Request;Complete=$Complete;Failed=$Failed;Context=$CallbackContext
  Admitted=[bool](TestUiJobCallbackContext $Request $CallbackContext $null ([guid]::NewGuid().ToString('N')))})
}
function Write-TCPerfTrace {param([string]$Mark)}

# ---- fixtures -------------------------------------------------------------------
$script:ServerRecord=[pscustomobject]@{LocalRecordId='server-a';Name='Singapore A';RecordState='Active';OwnershipState='Authenticated'
 PinnedHostKey='SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';SavedLoginRef='8f0c2f0e-0000-4000-8000-000000000001'
 Connection=@{Host='192.0.2.10';Port=22;User='root'};LinkedNodeIds=@()}
$script:ServerInfo=[pscustomobject]@{RemoteOwnerId='owner-1';OwnershipState='Applied';ManagementSigningPublicKey='management-key'
 Node=[pscustomobject]@{NodeId='node-1';ServerPublicKey='server-public-key';PublicEndpoint='192.0.2.10:443'}}
$script:InviteCode='TCI1.'+('A'*40)
# Relative to the fixture clock: a fixed date would rot once it is in the past.
$script:InviteExpires=(Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$script:InviteRetry=(Get-Date).ToUniversalTime().AddHours(2).AddMinutes(2).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
function NewInviteData {param([string]$State='Open',[string]$InviteId='invite-1')
 [pscustomobject]@{InviteId=$InviteId;State=$State;InvitationCode=$(if($State -ceq 'Open'){$script:InviteCode}else{''})
  ExpiresAtUtc=$script:InviteExpires;RetryUntilUtc=$script:InviteRetry;Port=18443}
}
function ResetFixture {param([string]$Page='web',[string]$WebPage='invite')
 $script:Shows=0;$script:Syncs=0;$script:Copied='';$script:CredentialReads=0
 $script:Jobs.Clear();$script:Commands.Clear();$script:Toasts.Clear();$script:Dialogs.Clear();$script:Closed.Clear()
 $script:Role='client';$script:Page=$Page;$script:WebPage=$WebPage;$script:WebReady=$false;$script:Smoke=$false;$script:ReadOnly=$false
 $script:DeployUI=@{Management=$null;PendingManagement=$null;SessionRef=$null;SessionAttached=$false;DeviceResult=$null;Invite=$null
  Discovery=@{Servers=@($script:ServerRecord);ManagementServers=@($script:ServerRecord)};ServerDiscoveryAttempted=$true;ServersLoading=$false;ManagementMode=$false}
 InitializeServerUI
 $null=ResetTCWebInvite
}
function SetLiveSession {
 # What a successful silent login leaves behind: an authenticated session for the
 # target server, with the server info the create input is built from.
 $m=$script:DeployUI.Management
 $m.ServerId='server-a';$m.Server=$script:ServerRecord;$m.Authenticated=$true
 $m.SessionRef=@{InstanceId='s1';RunId='fixture'};$m.Info=$script:ServerInfo;$m.ReadContinuation='';$m.Driver='WebInvite'
 $script:DeployUI.SessionRef=$m.SessionRef;$script:DeployUI.ManagementMode=$true
}
function LastCommand {param([string]$Command)return (@($script:Commands|Where-Object {$_.Command -ceq $Command})|Select-Object -Last 1)}
function DispatchOk {param($Record)
 if(-not $Record){throw 'no command to dispatch'}
 $operationId=if($Record.Context.Intent){[string]$Record.Context.Intent.OperationId}else{''}
 & $Record.Complete ([pscustomobject]@{Ok=$true;OperationId=$operationId}) $Record.Context
}
function NewPoll {param($Data=$null,[string]$Status='Completed',[string]$Code='',[bool]$HasSession=$true)
 [pscustomobject]@{Status=$Status;Code=$Code;HasSession=$HasSession
  OperationId=$(if($script:DeployUI.PendingManagement){[string]$script:DeployUI.PendingManagement.OperationId}else{''})
  Data=$Data;ObservedFingerprint='SHA256:OBSERVEDFINGERPRINT';ElapsedMs=11}
}
function InvokePoll {param($Poll)
 $m=$script:DeployUI.Management
 $m.LastPoll=[DateTime]::MinValue;$m.CommandPending=$false;$script:Jobs.Clear()
 PollServerOperation
 if($script:Jobs.Count -ne 1){throw 'the session poll did not schedule a snapshot'}
 if(-not $script:Jobs[0].Admitted){throw 'the session snapshot was refused by the real callback gate'}
 & $script:Jobs[0].Complete ([pscustomobject]@{InstanceId='s1';Poll=$Poll}) $null
}

# ==== 1. A5: no saved session -> one silent login, and A3 keeps the page =========
ResetFixture
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
Check ($script:Commands.Count -eq 1 -and (LastCommand 'Start-TCDeploySession')) 'A5 a silent login is the first step when there is no session'
Check ($script:WebInvite.Phase -ceq 'LoggingIn') 'A5 the page reports the login step instead of a blank screen'
Check ($script:CredentialReads -eq 1) 'A5 the login uses the credential saved for this server'
Check ($script:Shows -eq 0) 'A3 the server page is never rendered for the invitation flow'
Check ($script:Dialogs.Count -eq 0) 'A3 the invitation flow opens no native dialog'
Check ($script:DeployUI.Management.ServerId -ceq 'server-a') 'A3 the target server is selected on the management model'
Check ($script:DeployUI.Management.Driver -ceq 'WebInvite') 'A3 the driver survives the server-model rebuild of a selection'
Check ([bool]$script:DeployUI.ManagementMode) 'A3 the timer keeps polling the management session'
Check ($script:Page -ceq 'web' -and $script:WebPage -ceq 'invite') 'A3 the web invitation page is still the current surface'
$login=LastCommand 'Start-TCDeploySession'
& $login.Complete ([pscustomobject]@{SessionRef=@{InstanceId='s1';RunId='fixture'}}) $login.Context
Check ($script:DeployUI.Management.SessionRef.InstanceId -ceq 's1') 'A5 the live session is kept on the model'
# The session exists but the record is not authenticated yet: the poll records it.
InvokePoll (NewPoll -Status 'Running' -Code 'Authenticated')
$record=LastCommand 'Set-TCServerRecord'
Check ($null -ne $record) 'A3 the authenticated session updates its record through the normal path'
& $record.Complete $script:ServerRecord $record.Context
DispatchOk (LastCommand 'Invoke-TCDeployOperation')
InvokePoll (NewPoll -Data $script:ServerInfo)
$record=LastCommand 'Set-TCServerRecord'
& $record.Complete $script:ServerRecord $record.Context
DispatchOk (LastCommand 'Invoke-TCDeployOperation')
InvokePoll (NewPoll -Data ([pscustomobject]@{Devices=@()}))
Check ($script:Shows -eq 0) 'A3 the whole login and read chain still renders no server page'
Check ($script:WebInvite.Phase -ceq 'Creating') 'A5 the create step follows the login without a click'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($null -ne $create) 'A1 the create is the online invitation operation the server page uses'
$inputData=$create.Arguments.InputData
Check ([int]$inputData.ExpiresInSeconds -eq 1800) 'A1 only the chosen lifetime is sent'
Check ([int]$inputData.Port -eq 18443) 'A4 the invitation still uses TCP 18443'
Check ($inputData.DeviceName -match '^.+ \d{2}-\d{2} \d{2}:\d{2}$') 'A6 the host fills the invitation label instead of asking for a name'
Check ([string]$inputData.ExpectedServerBinding.NodeId -ceq 'node-1' -and [string]$inputData.ExpectedManagementFingerprint -ceq 'FIXTURE-MANAGEMENT-FINGERPRINT') 'A3 the binding and management fingerprint are the ones read over SSH'
DispatchOk $create
Check ($script:Shows -eq 0) 'A3 accepting the create does not repaint the server page'
InvokePoll (NewPoll -Data (NewInviteData))
Check ($script:WebInvite.Phase -ceq 'Open' -and $script:WebInvite.State -ceq 'Open') 'A2 a generated invitation lands on the invitation page'
Check ($script:WebInvite.InviteId -ceq 'invite-1') 'A2 the returned invitation is the one the page reports'
Check ($script:WebInvite.ExpiresAtUtc -ceq $script:InviteExpires -and $script:WebInvite.RetryUntilUtc -ceq $script:InviteRetry) 'A1 the deadline and the retry window are projected unchanged'
Check ($script:Shows -eq 0) 'A3 a successful create renders the server page zero times'
Check ((GetTCWebInviteCode) -ceq $script:InviteCode) 'A2 the full code is available to the host for copying'
Check ([bool]$script:WebInvite.CodePresent -and $script:WebInvite.CodePreview -match '^TCI1\.\u2022{8}AAAA$') 'A2 the model only carries a masked preview of the code'
Check ((($script:WebInvite.Values|ForEach-Object {[string]$_}) -join '|') -notmatch 'TCI1\.[A-Za-z0-9_-]{20,}') 'A2 no snapshot field can carry the full code'

# ==== 2. A1/A5: a server refusal is carried, not dialled, and stays retryable ====
ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 7200 -ServerId 'server-a'
Check ($script:Commands.Count -eq 1 -and (LastCommand 'Invoke-TCDeployPairOnlineOperation')) 'A5 an authenticated session is reused instead of logging in again'
Check ($script:CredentialReads -eq 0) 'A5 reuse never re-reads the saved credential'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ([int]$create.Arguments.InputData.ExpiresInSeconds -eq 7200) 'A1 a two hour invitation reaches the server unchanged'
DispatchOk $create
InvokePoll (NewPoll -Status 'Failed' -Code 'OnlinePortConflict')
Check ($script:WebInvite.Phase -ceq 'Failed') 'A1 a refusal ends the step on the invitation page'
Check ($script:WebInvite.ErrorCode -ceq 'OnlinePortConflict') 'A1 the refusal code is kept for the page'
Check ($script:WebInvite.ErrorMessage -match '18443') 'A1 the refusal is explained with the server sentence'
Check ($script:WebInvite.NextAction -ceq 'Retry') 'A5 a refusal keeps the session, so the same step can be retried'
Check ($script:Dialogs.Count -eq 0) 'A3 a refusal never opens a native dialog over the web page'
Check ($script:Shows -eq 0) 'A3 a refusal never repaints the server page'

# ==== 3. A3: an unknown outcome blocks the next create ==========================
ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
& $create.Failed '无法确认管理操作是否被接受，请先查询原申请或服务器状态。' $create.Context ([pscustomobject]@{Phase='Executing';Code='PipeTimeout';OutcomeUnknown=$true})
Check ($null -ne $script:DeployUI.Management.UnresolvedIntent) 'A3 an unknown outcome is kept as the unresolved intent'
Check ($script:DeployUI.PendingManagement -eq $null) 'A3 the pending marker is released once the outcome is unknown'
Check ($script:WebInvite.ErrorCode -ceq 'OutcomePending') 'A3 the invitation page reports a result waiting to be confirmed'
Check ($script:WebInvite.NextAction -ceq 'OpenServer') 'A3 only the server page can reconcile an unknown result'
Check ($script:Dialogs.Count -eq 0) 'A3 the unknown outcome is carried without a dialog'
$before=$script:Commands.Count
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
Check ($script:Commands.Count -eq $before) 'A3 no second create is sent while the previous result is unknown'
Check ($script:WebInvite.ErrorCode -ceq 'OutcomePending') 'A3 the refused retry keeps the pending-result message'
Check ($script:Shows -eq 0) 'A3 the refused retry still does not repaint the server page'

# ==== 4. A2: cancel and status are the same operations as the server page =======
ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
InvokePoll (NewPoll -Data (NewInviteData))
$count=$script:Commands.Count
CancelTCWebInviteUI
$cancel=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($script:Commands.Count -eq $count+1 -and $cancel.Arguments.Action -ceq 'cancel') 'A2 cancelling is the online cancel operation'
Check ([string]$cancel.Arguments.InputData.InviteId -ceq 'invite-1') 'A2 cancel targets the invitation this page owns'
DispatchOk $cancel
InvokePoll (NewPoll -Data ([pscustomobject]@{InviteId='invite-1';State='Cancelled';ExpiresAtUtc=$script:InviteExpires;RetryUntilUtc=$script:InviteRetry}))
Check ($script:WebInvite.State -ceq 'Cancelled') 'A2 the cancelled state reaches the page'
Check ($script:WebInvite.Phase -ceq 'Ended') 'A2 a cancelled invitation ends the open phase'
Check (-not $script:WebInvite.CodePresent -and -not (GetTCWebInviteCode)) 'A2 the code is dropped as soon as the invitation ends'
Check ($script:Shows -eq 0) 'A3 cancel never repaints the server page'
$count=$script:Commands.Count
RefreshTCWebInviteStatusUI
$status=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($script:Commands.Count -eq $count+1 -and $status.Arguments.Action -ceq 'status') 'A2 refreshing is a read-only status query'
Check (-not $status.Arguments.InputData.ContainsKey('RefreshAuthorization')) 'A2 refreshing sends no authorization or approval field'
DispatchOk $status
InvokePoll (NewPoll -Data ([pscustomobject]@{InviteId='invite-1';State='Consumed';ExpiresAtUtc=$script:InviteExpires;RetryUntilUtc=$script:InviteRetry}))
Check ($script:WebInvite.State -ceq 'Consumed' -and $script:WebInvite.Phase -ceq 'Ended') 'A2 a used invitation is reported as used'
Check ($script:Shows -eq 0) 'A3 a status query never repaints the server page'

# ==== 5. A5: one silent re-login for a session the host ended ==================
ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
$reads=$script:CredentialReads
InvokePoll (NewPoll -Status 'Failed' -Code 'SessionMismatch')
Check ([bool]$script:WebInvite.LoginRetried -and $script:WebInvite.Phase -ceq 'LoggingIn') 'A5 a lost session triggers one silent re-login'
Check ($script:CredentialReads -eq $reads+1) 'A5 the re-login reuses the saved credential'
Check ($null -ne (LastCommand 'Start-TCDeploySession')) 'A5 the re-login starts a new management session'
Check ($script:Dialogs.Count -eq 0) 'A3 the re-login needs no dialog'
# The retry is spent: the same loss is reported instead of looping.
ResetFixture;SetLiveSession
$script:WebInvite.LoginRetried=$true
$script:WebInvite.ServerId='server-a'
$script:WebInvite.PendingStep='Create'
$script:DeployUI.Management.ErrorCode='SessionMismatch'
$before=$script:Commands.Count
$null=UpdateTCWebInviteFromManagement
Check ($script:Commands.Count -eq $before) 'A5 the silent re-login is tried once, not in a loop'
Check ($script:WebInvite.ErrorCode -ceq 'SessionMismatch' -and $script:WebInvite.NextAction -ceq 'OpenServer') 'A5 the second loss sends the operator to the server page'
Check ($script:Shows -eq 0) 'A3 the reported loss still does not repaint the server page'

# ==== 6. A3: leaving the page makes the callback render the server page =========
ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($script:Page -ceq 'web' -and $script:Role -ceq 'client') 'A3 the invitation flow never turns the window into the server page'
DispatchOk $create
Check ($script:Page -ceq 'web' -and $script:Role -ceq 'client' -and $script:Shows -eq 0) 'A3 accepting a create keeps the web page exactly as it is'
ClearTCWebInvite
Check ([string]$script:DeployUI.Management.Driver -ceq '') 'A3 leaving the page releases the management model'
$before=$script:Shows
InvokePoll (NewPoll -Data (NewInviteData))
# 0.22.2: the late result is now SETTLED instead of dropped. Dropping it was the
# defect - PendingManagement stayed set and the page refused to open again.
Check ($null -eq $script:DeployUI.PendingManagement) 'A3 a late result settles the operation after leaving the page (0.22.2)'
Check ($script:Shows -eq $before) 'A3 after leaving a web page, a late result renders nothing'
Check ($script:WebInvite.Phase -cne 'Open') 'A3 a late result cannot revive the invitation view'
# The result itself is kept in the management model, so the server page shows it
# without asking the server again.
Check ([string]$script:DeployUI.Management.OnlineInvite.InviteId -ceq 'invite-1') 'A3 the settled result stays in the management model (0.22.2)'
$script:Role='servers'
$before=$script:Shows
ShowServerManagement
Check ($script:Shows -eq $before+1) 'A3 the server page renders the kept result once'

# ==== 6b. 0.22.2: leaving mid-operation no longer locks the page ================
# The operator generates a code, a status poll is in flight, and they leave. Before
# 0.22.2 the poll result was dropped (the callback required the page to be visible),
# PendingManagement stayed set, and every later visit was refused with
# 「上一步还没有结束」. Three rounds, because a single round can pass by luck.
$script:ManageableServer=[pscustomobject]@{LocalRecordId='server-a';Name='Singapore A';RecordState='Active';OwnershipState='Authenticated'
 ManagementAccessState='Authenticated';ManagementSigningPublicKey='management-key'
 PinnedHostKey='SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';SavedLoginRef='8f0c2f0e-0000-4000-8000-000000000001'
 Connection=@{Host='192.0.2.10';Port=22;User='root'};LinkedNodeIds=@('node-1')}
function Get-TCServers {param($Root) @($script:ManageableServer)}
for($round=1;$round -le 3;$round++){
 ResetFixture;SetLiveSession
 $script:WebInviteServers=@{At=[DateTime]::MinValue;Records=@($script:ManageableServer)}
 $null=OpenTCWebInvitePageUI 'server-a'
 StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
 $create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
 DispatchOk $create
 $script:DeployUI.PendingManagement=@{Operation='pair_online_status';Purpose='OnlineInviteStatus';ServerId='server-a';InputData=@{};OperationId='op-1';Intent=$null;Continuation=''}
 ClearTCWebInvite
 InvokePoll (NewPoll -Data (NewInviteData))
 Check ($null -eq $script:DeployUI.PendingManagement) "6b round $round settles the in-flight operation after leaving"
 Check ([string]$script:DeployUI.Management.OnlineInvite.State -ceq 'Open') "6b round $round the result stays open in the management model"
 $reopen=OpenTCWebInvitePageUI 'server-a'
 Check ($reopen -eq $true) "6b round $round the page opens again"
 Check ([string]$script:WebInvite.InviteId -ceq 'invite-1') "6b round $round resumes the same invitation"
}

# ==== 7. A3: an empty Driver keeps the 0.21.8 server page behaviour ============
ResetFixture -Page 'setup' -WebPage 'servers'
$script:Role='servers';SetLiveSession
$script:DeployUI.Management.Driver=''
$null=ResetTCWebInvite
$before=$script:Shows
StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices
DispatchOk (LastCommand 'Invoke-TCDeployOperation')
CompleteServerOperation ([pscustomobject]@{Devices=@()})
Check ($script:Shows -eq $before+3) 'A3 with an empty Driver the server page renders at exactly its three call sites, as in 0.21.8'
Check ($script:WebInvite.Phase -ceq 'Idle') 'A3 with an empty Driver the invitation model is never written'
# The web shell keeps its own page: an empty Driver must not render the server page.
ResetFixture -Page 'web' -WebPage 'lines'
$script:Role='client';SetLiveSession
$script:DeployUI.Management.Driver=''
$before=$script:Shows
StartServerOperation devices @{Offset=0;Limit=50;IncludeRevoked=$true} Devices
DispatchOk (LastCommand 'Invoke-TCDeployOperation')
CompleteServerOperation ([pscustomobject]@{Devices=@()})
Check ($script:Shows -eq $before) 'A3 with an empty Driver a web page is still never replaced by the server page'
Check ($script:WebInvite.Phase -ceq 'Idle') 'A3 a read result on a web page does not touch the invitation model'

$result=[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Suite='WebInviteSession';Assertions=$script:Checks.ToArray()
 RealNetwork=$false;WorkerLaunched=$false;FileWrites=0;HostSideOnly=$true}
$result|ConvertTo-Json -Depth 6
