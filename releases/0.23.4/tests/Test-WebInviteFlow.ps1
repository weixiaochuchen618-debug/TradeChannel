#requires -Version 5.1
# 0.22.0 A2/A4/A16 acceptance for the web-native 「邀请其他电脑」 page.
#
# What this fixture proves, and why it is a separate file from
# Test-WebInviteSession.ps1: that one covers the headless management session (A3,
# A5). This one covers the page around it - which lines may invite, the message
# surface with its own field gate, the three stages including the A4 reachability
# probe, the masked code, and the status cadence.
#
# It loads the real ui/BackgroundJobs.ps1, ui/ServerPages.ps1,
# ui/OnlinePairingPages.ps1, ui/WebShell.ps1 and ui/WebInvite.ps1 and replaces only
# the boundaries that need a live window, a worker, a registry file or a network:
#   ShowServerManagement (counted), StartUiCommand, StartJob (which still asks the
#   real TestUiJobCallbackContext), SyncTCWebState, Toast, ErrorDialog, OpenDialog,
#   CopyText, Get-TCServers, the intent store, the task lease, module loading and
#   the saved-credential reader.
# No directory, credential, session, worker or network call is created.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
# Named only; this fixture never creates it.
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-web-invite-flow-'+[guid]::NewGuid().ToString('N'))
$script:Checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$script:Checks.Add($Name)}

. (Join-Path $script:PackageRoot 'ui\BackgroundJobs.ps1')
. (Join-Path $script:PackageRoot 'ui\ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui\OnlinePairingPages.ps1')
. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')
. (Join-Path $script:PackageRoot 'ui\WebInvite.ps1')

# ---- boundaries -----------------------------------------------------------------
$script:Shows=0;$script:Syncs=0;$script:Copied='';$script:CredentialReads=0
$script:Jobs=New-Object 'Collections.Generic.List[object]'
$script:Commands=New-Object 'Collections.Generic.List[object]'
$script:Toasts=New-Object 'Collections.Generic.List[string]'
$script:Dialogs=New-Object 'Collections.Generic.List[string]'
$script:Sent=New-Object 'Collections.Generic.List[string]'
# The snapshot also reads a handful of product constants that live in the module
# hosts this fixture does not load (ProductText.psm1, ConnectionMethods.psm1,
# LineQuality.psm1) or in TradeChannel.ps1 itself. They are constants for the
# projection's purposes, so fixed values are enough to build one.
function Get-TCTextCatalog {return @{}}
function Get-TCConnectionMethods {return @()}
function Get-TCLineQualityContext {param($Overview)return @{Eligible=$false;Key=''}}
function GetUiPendingOperationViews {return @()}
function StateKey {return 'Stopped'}
function DailyLaneValue {return 'Daily'}
function AgentLaneValue {return 'Daily'}
function TradeLabel {return ''}
function ShowServerManagement {$script:Shows=$script:Shows+1}
# The snapshot reads the dialog state off the window. This fixture has no window,
# so a stub answers every lookup with a collapsed, empty element - the same shape a
# closed dialog has - which keeps GetTCWebSnapshot on its no-dialog branch.
function NewWindowStub {
 $w=New-Object psobject
 $w|Add-Member -MemberType ScriptMethod -Name FindName -Value {param($Name)return [pscustomobject]@{Visibility='Collapsed';Text='';Content='';Style=$null}}
 $w|Add-Member -MemberType ScriptMethod -Name FindResource -Value {param($Key)return $null}
 $w|Add-Member -MemberType NoteProperty -Name WindowState -Value 'Normal'
 $w|Add-Member -MemberType NoteProperty -Name IsVisible -Value $true
 return $w
}
function SyncTCWebState {param([switch]$Force)$script:Syncs=$script:Syncs+1}
function Toast {param([string]$Text)$script:Toasts.Add([string]$Text)}
function ErrorDialog {param([string]$Text)$script:Dialogs.Add([string]$Text)}
# The invitation page has no modal: every refusal must reach it through the model.
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Style,$Context)throw 'The web invitation page must not open a native modal.'}
function IsBusy {return $false}
function CopyText {param([string]$Text,[string]$Done='')$script:Copied=[string]$Text;if($Done){$script:Toasts.Add([string]$Done)};return $true}
function CloseUiDeploymentSession {param($SessionRef)if($SessionRef){$script:Closed.Add([string]$SessionRef.InstanceId)}}
$script:Closed=New-Object 'Collections.Generic.List[string]'
function Open-TCServerTaskLease {param($Root,$ServerId)New-Object IO.MemoryStream}
# The intent record itself is still built by the real NewManagementIntent; only the
# file write is dropped, because this fixture must not touch disk.
function SaveManagementIntent {param($Intent)}
function Import-Module {param($Name,[switch]$DisableNameChecking)}
function UIProductPath {param([string]$Leaf)return $Leaf}
function Write-TCPerfTrace {param([string]$Mark)}
function GetOnlineInviteFingerprintUI {return 'FIXTURE-MANAGEMENT-FINGERPRINT'}
function Get-TCDeploySavedCredential {param($Root,$CredentialRef,$Binding,$CurrentManagementSigningKeyDigest)
 $script:CredentialReads=$script:CredentialReads+1
 return @{Kind='Password';Password=(ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force)}
}
function Get-TCServers {param([string]$Root) return @($script:ServerRecords)}
# The real probe lives in PairingOnline.psm1 and needs a socket. Here only the
# dispatch boundary matters, so the command exists but is never executed.
function Test-TCPairOnlineReachability {param($PublicHost,$Port,$TlsSha256,$TimeoutSeconds)throw 'the fixture never runs the probe'}
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

# ---- fixtures -------------------------------------------------------------------
$script:ManagedKey='management-key'
function NewServerRecord {param([string]$Id,[string]$Name,[string[]]$Links=@(),[string]$Access='Authenticated',[string]$State='Active',[string]$SshHost='192.0.2.10')
 [pscustomobject]@{LocalRecordId=$Id;Name=$Name;RecordState=$State;OwnershipState='Applied';ManagementAccessState=$Access
  ManagementSigningPublicKey=$(if($Access -ceq 'ConnectorOnly'){$null}else{$script:ManagedKey})
  SavedLoginRef='8f0c2f0e-0000-4000-8000-000000000001'
  Connection=$(if($SshHost){@{Host=$SshHost;Port=22;User='root'}}else{$null})
  LinkedNodeIds=@($Links)}
}
$script:ServerRecords=@()
function ResetServers {
 $script:ServerRecords=@(
  (NewServerRecord 'server-a' 'Singapore A' @('line-a')),
  (NewServerRecord 'server-b' 'Rented B' @('line-b') 'ConnectorOnly'),
  (NewServerRecord 'server-c' 'Shared C' @('line-c','line-d')),
  (NewServerRecord 'server-d' 'Retired D' @('line-e') 'Authenticated' 'Archived'),
  (NewServerRecord 'server-e' 'No SSH E' @('line-f') 'Authenticated' 'Active' ''),
  (NewServerRecord 'server-g' 'Second C' @('line-d'))
 )
 $null=@($script:ServerRecords)
}
$script:ServerRecords=@()
$script:ServerInfo=[pscustomobject]@{RemoteOwnerId='owner-1';OwnershipState='Applied';ManagementSigningPublicKey=$script:ManagedKey
 Node=[pscustomobject]@{NodeId='node-1';ServerPublicKey='server-public-key';PublicEndpoint='192.0.2.10:443'}}
$script:InviteCode='TCI1.'+('A'*40)
$script:TlsSha256=('B'*64)
$script:InviteExpires=(Get-Date).ToUniversalTime().AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$script:InviteRetry=(Get-Date).ToUniversalTime().AddHours(2).AddMinutes(2).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
function NewInviteData {param([string]$State='Open',[string]$InviteId='invite-1')
 [pscustomobject]@{InviteId=$InviteId;State=$State;InvitationCode=$(if($State -ceq 'Open'){$script:InviteCode}else{''})
  ExpiresAtUtc=$script:InviteExpires;RetryUntilUtc=$script:InviteRetry;Port=18443
  PublicHost='192.0.2.10';TlsSha256=$script:TlsSha256}
}
function ResetFixture {
 $script:Shows=0;$script:Syncs=0;$script:Copied='';$script:CredentialReads=0
 $script:Jobs.Clear()
 $script:Commands.Clear()
 $script:Toasts.Clear()
 $script:Dialogs.Clear()
 $script:Sent.Clear()
 $script:Closed.Clear()
 $script:Role='client';$script:Page='web';$script:WebPage='invite';$script:WebReady=$false;$script:Smoke=$false;$script:ReadOnly=$false
 $script:WebAck=0;$script:WebShell=$null;$script:Window=NewWindowStub
 $script:Overview=[pscustomobject]@{};$script:Providers=$null;$script:Prefs=[pscustomobject]@{NodeId=''}
 $script:Nodes=@()
 $script:DeployUI=@{Management=$null;PendingManagement=$null;SessionRef=$null;SessionAttached=$false;DeviceResult=$null;Invite=$null
  Discovery=@{Servers=@($script:ServerRecords);ManagementServers=@($script:ServerRecords)};ServerDiscoveryAttempted=$true;ServersLoading=$false;ManagementMode=$false}
 ResetTCWebInviteServerCache
 InitializeServerUI
 $null=ResetTCWebInvite
}
function SetLiveSession {param([string]$ServerId='server-a')
 $m=$script:DeployUI.Management
 $m.ServerId=$ServerId;$m.Server=@($script:ServerRecords|Where-Object {$_.LocalRecordId -ceq $ServerId})[0]
 $m.Authenticated=$true;$m.SessionRef=@{InstanceId='s1';RunId='fixture'};$m.Info=$script:ServerInfo;$m.ReadContinuation='';$m.Driver='WebInvite'
 $script:DeployUI.SessionRef=$m.SessionRef;$script:DeployUI.ManagementMode=$true
}
function LastCommand {param([string]$Command)return (@($script:Commands|Where-Object {$_.Command -ceq $Command})|Select-Object -Last 1)}
function SendInvite {param([string]$Phase,[string]$Id='',[string]$Value='',[int]$Sequence=0)
 # Everything below goes through the real envelope, so Ack, the origin check and the
 # type/field gates are the product's and not this fixture's.
 $payload=[ordered]@{Type='invite';Phase=$Phase}
 if($Id -ne ''){$payload.Id=$Id}
 if($Value -ne ''){$payload.Value=$Value}
 if($Sequence -gt 0){$payload.Sequence=$Sequence}
 InvokeTCWebMessage ($payload|ConvertTo-Json -Compress) 'https://tradechannel.local/index.html'
}
# Every string a projection carries, joined, so a secret scan cannot miss a field
# because it was nested one level deeper than the scan expected.
function GetFlatText {param($Value)
 $out=New-Object 'Collections.Generic.List[string]'
 $queue=New-Object 'Collections.Generic.Queue[object]'
 $queue.Enqueue($Value);$guard=0
 while($queue.Count -gt 0 -and $guard -lt 5000){
  $guard=$guard+1;$item=$queue.Dequeue()
  if($null -eq $item){continue}
  if($item -is [string]){$out.Add([string]$item);continue}
  if($item -is [System.Collections.IDictionary]){foreach($k in @($item.Keys)){$queue.Enqueue($item[$k])};continue}
  if($item -is [System.Collections.IEnumerable]){foreach($v in $item){$queue.Enqueue($v)};continue}
  foreach($p in @($item.PSObject.Properties)){$queue.Enqueue($p.Value)}
 }
 return ($out -join '|')
}
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
function NewLine {param([string]$Id,[string[]]$Aliases=@())
 [pscustomobject]@{LineId=$Id;Name='线路 '+$Id;AliasIds=@($Aliases);Profiles=@();SavedConnectionPreference=$null}
}

# ==== 1. A-16: only a line with one manageable server can invite ================
ResetServers;ResetFixture
$script:Nodes=@((NewLine 'line-a'),(NewLine 'line-b'),(NewLine 'line-c'),(NewLine 'line-d'),(NewLine 'line-e'),(NewLine 'line-f'),(NewLine 'line-z'))
$managed=GetTCWebLineInviteBindingUI 'line-a'
Check ([bool]$managed.CanInvite -and [string]$managed.ServerRecordId -ceq 'server-a') 'A2 a line linked to one manageable server can invite'
$connectorOnly=GetTCWebLineInviteBindingUI 'line-b'
$ambiguous=GetTCWebLineInviteBindingUI 'line-d'
$archived=GetTCWebLineInviteBindingUI 'line-e'
$noSsh=GetTCWebLineInviteBindingUI 'line-f'
$unlinked=GetTCWebLineInviteBindingUI 'line-z'
Check (-not [bool]$connectorOnly.CanInvite) 'A-16 a computer with only 使用权 never gets the entry'
Check (-not [bool]$ambiguous.CanInvite) 'A2 two linked server records are an ambiguity, not an invitation'
Check (-not [bool]$archived.CanInvite) 'A2 an archived record cannot invite'
Check (-not [bool]$noSsh.CanInvite) 'A2 a record without an SSH management entry cannot invite'
Check (-not [bool]$unlinked.CanInvite) 'A2 a line with no server at all cannot invite'
# An alias still resolves: a rename keeps the id the server recorded.
$script:Nodes=@((NewLine 'line-a2' @('line-a')))
Check ([bool](GetTCWebLineInviteBindingUI 'line-a2').CanInvite) 'A2 a renamed line still finds its server through the alias'
# The page offers only the servers that pass the same test.
$targets=@(GetTCWebInviteTargetsUI)
Check ($targets.Count -eq 3 -and @($targets|Where-Object {$_.Id -ceq 'server-a'}).Count -eq 1) 'A2 only manageable servers are offered to the page'
Check (@($targets|Where-Object {$_.Id -ceq 'server-b'}).Count -eq 0) 'A-16 a 使用权-only server is never offered'
# No projection may carry a credential reference or a connection user name.
ResetFixture
$snapshot=GetTCWebSnapshot
$json=$snapshot|ConvertTo-Json -Depth 12
Check ($json -cnotmatch 'TCI1\.[A-Za-z0-9_-]{20,}') 'A-06 no snapshot can contain a full invitation code'
Check ($json -cnotmatch 'fixture-credential|CredentialRef|SavedLoginRef|8f0c2f0e') 'A-06 the projection carries no credential reference'
Check ($json -cnotmatch '"root"|IdentityFile') 'A-06 the projection carries no connection user or key path'
Check ($null -ne $snapshot.Invite) 'A2 the snapshot publishes an Invite projection'

# ==== 2. page registration and the message whitelist ============================
$pageParam=(Get-Command ShowTCWebShell).Parameters['Page']
Check (@($pageParam.Attributes|Where-Object {@($_.ValidValues) -contains 'invite'}).Count -eq 1) 'A2 ShowTCWebShell accepts the invite page'
$shellSource=[IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\WebShell.ps1'),[Text.Encoding]::UTF8)
Check ($shellSource -match "if\(\`$page -cnotin @\('home','lines','apps','settings','add-line','invite'\)\)") 'A2 the navigate whitelist accepts the invite page'
# The real gate answers an unknown phase instead of dropping the intent.
$script:Window=New-Object psobject
$script:Window|Add-Member -MemberType ScriptMethod -Name FindName -Value {param($Name)if($Name -ceq 'Overlay'){return [pscustomobject]@{Visibility='Collapsed'}};return $null}
SetLiveSession
$script:WebAck=0
InvokeTCWebMessage '{"Type":"invite","Phase":"Nonsense","Id":"","Value":"","Sequence":11}' 'https://tradechannel.local/index.html'
Check ($script:WebAck -eq 11) 'A2 a refused invite phase still advances Ack, so the page cannot stay busy'
Check (@($script:Toasts|Where-Object {$_ -ceq '这一步没有生效，请重试'}).Count -ge 1) 'A2 a refused invite phase says so on the page'
$script:WebAck=0;$script:Toasts.Clear()
InvokeTCWebMessage '{"Type":"invite","Phase":"Close","Id":"","Value":"","Sequence":12,"Code":"TCI1.evil"}' 'https://tradechannel.local/index.html'
Check ($script:WebAck -eq 12 -and @($script:Toasts|Where-Object {$_ -eq '这一步没有生效，请重试'}).Count -eq 1) 'A2 an extra field is rejected by the invite field gate and answered'
$script:WebAck=0;$script:Toasts.Clear()
InvokeTCWebMessage '{"Type":"invite","Phase":"Close","Id":"","Sequence":13}' 'https://trader.example/index.html'
Check ($script:WebAck -eq 0) 'A2 a message from another origin never reaches the handler'

# ==== 3. Begin opens the page and sends nothing =================================
ResetServers;ResetFixture;SetLiveSession
$opened=OpenTCWebInvitePageUI '' 'line-a'
Check ($opened) 'A2 opening from a line succeeds'
Check ($script:WebInvite.ServerId -ceq 'server-a') 'A2 beginning from a line preselects that line'"'"'s server'
Check ($script:Commands.Count -eq 0) 'A2 opening the page does not start a create or a login'
Check ($script:ReadOnly -eq $false -and $script:DeployUI.Management.Driver -ceq 'WebInvite') 'A2 the page takes the management driver'
Check ([bool]$script:DeployUI.ManagementMode) 'A2 the timer keeps polling the management session'
Check ($script:Shows -eq 0) 'A3 opening the page never renders the server page'
# Exactly one manageable server: there is no choice to make, so the page picks it.
$script:ServerRecords=@((NewServerRecord 'server-a' 'Singapore A' @('line-a')))
ResetTCWebInviteServerCache
$auto=ResolveTCWebInviteServerUI '' ''
Check ($null -ne $auto -and [string]$auto.Id -ceq 'server-a') 'A2 with one manageable server the page selects it without asking'
# Several manageable servers: asking is the only honest answer.
ResetServers;ResetFixture;SetLiveSession
$auto=ResolveTCWebInviteServerUI '' ''
Check ($null -eq $auto) 'A2 with several manageable servers the page asks instead of guessing'
ResetFixture;SetLiveSession
$blocked=OpenTCWebInvitePageUI '' 'line-b'
Check (-not $blocked -and @($script:Toasts|Where-Object {$_ -match '没有可管理的服务器'}).Count -eq 1) 'A-16 beginning from a 使用权 line explains why there is no page'

# ==== 4. Create: lifetime validation, then three stages including A4 ============
ResetServers;ResetFixture;SetLiveSession
StartTCWebInviteUI -LifetimeSeconds 7200 -ServerId 'server-a'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($null -ne $create -and $create.Arguments.Action -ceq 'create') 'A2 生成邀请码 is the online create operation'
Check ([int]$create.Arguments.InputData.ExpiresInSeconds -eq 7200) 'A1 the chosen lifetime reaches the server unchanged'
Check ([int]$create.Arguments.InputData.Port -eq 18443) 'A4 the invitation still uses TCP 18443'
DispatchOk $create
InvokePoll (NewPoll -Data (NewInviteData))
Check ($script:WebInvite.Phase -ceq 'Checking') 'A4 the create hands over to the 18443 check'
$probe=LastCommand 'Test-TCPairOnlineReachability'
Check ($null -ne $probe -and $probe.Module -ceq 'PairingOnline.psm1') 'A4 the check is the shared reachability probe'
Check ([string]$probe.Arguments.PublicHost -ceq '192.0.2.10' -and [int]$probe.Arguments.Port -eq 18443) 'A4 the probe targets the public endpoint of this invitation'
Check ([string]$probe.Arguments.TlsSha256 -ceq $script:TlsSha256) 'A4 the probe compares the certificate the invitation pins'
Check ($null -eq $probe.Arguments.Token -and -not $probe.Arguments.ContainsKey('InvitationCode')) 'A4 the probe sends no token and no code'
Check ([string]$probe.Context.Type -ceq 'Invite' -and [string]$probe.Context.SessionId -ceq [string]$script:WebInvite.SessionId) 'A4 the probe result is bound to this invitation session'
& $probe.Complete ([pscustomobject]@{Status='Reachable';ElapsedMs=42;CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
Check ($script:WebInvite.Phase -ceq 'Open' -and $script:WebInvite.State -ceq 'Open') 'A4 a reachable endpoint opens the invitation'
Check ($script:WebInvite.Reachability.Status -ceq 'Reachable' -and [int]$script:WebInvite.Reachability.Port -eq 18443) 'A4 the result keeps the status and the port the page reports'
Check ($script:Shows -eq 0) 'A3 the whole flow renders the server page zero times'
# A refused port is an advisory, not a failed invitation.
ResetServers;ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
StartTCWebInviteUI -LifetimeSeconds 600 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
InvokePoll (NewPoll -Data (NewInviteData))
$probe=LastCommand 'Test-TCPairOnlineReachability'
& $probe.Complete ([pscustomobject]@{Status='Refused';ElapsedMs=5;CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
Check ($script:WebInvite.Phase -ceq 'Open' -and $script:WebInvite.State -ceq 'Open') 'A4 a refused port still leaves a usable invitation'
Check ($script:WebInvite.Reachability.Status -ceq 'Refused') 'A4 the refusal is carried for the page to explain'
Check ((GetTCWebInviteCode) -ceq $script:InviteCode) 'A2 the code survives a failed reachability check'
# A lifetime outside 10 分钟 .. 24 小时 never reaches the server.
ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
$before=$script:Commands.Count
SendInvite -Phase 'Create' -Value '300' -Sequence 21
Check ($script:Commands.Count -eq $before) 'A1 a 5 minute lifetime is refused before it is sent'
Check (@($script:Toasts|Where-Object {$_ -match '10 分钟到 24 小时'}).Count -eq 1) 'A1 the refusal names the accepted range'
Check ($script:WebAck -eq 21) 'A2 the refusal answers, so the button cannot stay disabled'
$before=$script:Commands.Count
SendInvite -Phase 'Create' -Value '86400' -Sequence 22
Check ($script:Commands.Count -eq $before+1) 'A1 the 24 hour preset is accepted'

# ==== 5. A2 the code: masked in the snapshot, revealed once, copied =============
# A live invitation, as the create reply leaves it.
$script:WebInvite.InviteId='invite-1';$script:WebInvite.State='Open'
$script:WebInvite.ExpiresAtUtc=$script:InviteExpires
SetTCWebInviteCode $script:InviteCode
$view=GetTCWebInviteView
Check (@($view.LifetimePresets) -join ',' -ceq '600,1800,7200,86400') 'A2 the page receives the four prescribed presets'
Check (-not [bool]$view.CodePresent -or $view.CodePreview -cnotmatch 'TCI1\.[A-Za-z0-9_-]{20,}') 'A2 the projection only carries a masked preview'
Check ((GetFlatText $view) -cnotmatch 'TCI1\.[A-Za-z0-9_-]{20,}') 'A-06 no field of the invitation projection can carry the full code'
Check ((GetFlatText $view) -cnotmatch $script:TlsSha256) 'A-06 the TLS identity never reaches the page'
$script:WebInvite.LifetimeSeconds=7200
Check ([bool](GetTCWebInviteView).CompatNoteVisible) 'A1 a two hour invitation shows the compatibility note'
$script:WebInvite.LifetimeSeconds=1800
Check (-not [bool](GetTCWebInviteView).CompatNoteVisible) 'A1 half an hour does not show it'
# Reveal needs a page to answer to, and answers when it cannot.
$script:WebReady=$false
$before=$script:Sent.Count
Check (-not (SendTCWebInviteCodeUI)) 'A2 the code is not revealed without a live page'
$script:WebReady=$true
$script:WebShell=[pscustomobject]@{CoreWebView2=[pscustomobject]@{}}
$script:WebShell.CoreWebView2|Add-Member -MemberType ScriptMethod -Name PostWebMessageAsJson -Value {param($Json)$script:Sent.Add([string]$Json)}
$before=$script:Sent.Count
SendInvite -Phase 'Reveal' -Id 'invite-1' -Sequence 31
Check ($script:Sent.Count -eq $before+1) 'A2 Reveal sends exactly one message'
$sentMessage=($script:Sent[$script:Sent.Count-1]|ConvertFrom-Json)
Check ([string]$sentMessage.Type -ceq 'inviteCode' -and [string]$sentMessage.Code -ceq $script:InviteCode) 'A2 that message is the code itself, keyed to this invitation'
Check ($script:WebAck -eq 31) 'A2 Reveal is acknowledged'
# Copy goes through the platform clipboard helper with the full code.
$script:Toasts.Clear()
SendInvite -Phase 'Copy' -Id 'invite-1' -Sequence 32
Check ($script:Copied -ceq $script:InviteCode) 'A2 复制邀请码 copies the full code'
Check (@($script:Toasts|Where-Object {$_ -ceq '已复制邀请码'}).Count -eq 1) 'A2 the copy is confirmed on the page'
# A closed invitation has no code to reveal or copy.
$script:WebInvite.State='Consumed';SetTCWebInviteCode ''
$script:Toasts.Clear()
SendInvite -Phase 'Reveal' -Id 'invite-1' -Sequence 33
Check (@($script:Toasts|Where-Object {$_ -match '不在这台电脑上'}).Count -eq 1) 'A2 a lost code is reported instead of showing an empty field'
$script:WebAck=0
Check ($script:WebInvite.State -ceq 'Consumed') 'A2 the ended invitation is unchanged by the refusal'

# ==== 6. A2 the status cadence, and where it stops ==============================
ResetServers;ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
InvokePoll (NewPoll -Data (NewInviteData))
# The A4 probe finishes before the cadence is measured; the page is Open from here.
$probe=LastCommand 'Test-TCPairOnlineReachability'
& $probe.Complete ([pscustomobject]@{Status='Reachable';ElapsedMs=42;CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
Check ($script:WebInvite.State -ceq 'Open') 'A2 the invitation is open before the cadence is measured'
$count=$script:Commands.Count
$script:WebInvite.PollAt=[DateTime]::UtcNow
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 a poll inside the 30 second window sends nothing'
$script:WebInvite.PollAt=[DateTime]::UtcNow.AddSeconds(-31)
PollTCWebInviteUI
$status=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ($script:Commands.Count -eq $count+1 -and $status.Arguments.Action -ceq 'status') 'A2 after 30 seconds the page reads the status once'
Check (-not $status.Arguments.InputData.ContainsKey('RefreshAuthorization')) 'A2 the read sends no authorization field'
DispatchOk $status
InvokePoll (NewPoll -Data (NewInviteData))
# After ten minutes the cadence slows to one minute.
$script:WebInvite.StartedAtUtc=(Get-Date).ToUniversalTime().AddMinutes(-11).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$count=$script:Commands.Count
$script:WebInvite.PollAt=[DateTime]::UtcNow.AddSeconds(-31)
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 past ten minutes 31 seconds is not yet a poll'
$script:WebInvite.PollAt=[DateTime]::UtcNow.AddSeconds(-61)
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count+1) 'A2 past ten minutes the page polls once a minute'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation');InvokePoll (NewPoll -Data (NewInviteData))
# Two hours ends the automatic reads; 刷新状态 remains.
$script:WebInvite.StartedAtUtc=(Get-Date).ToUniversalTime().AddMinutes(-121).ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$count=$script:Commands.Count
$script:WebInvite.PollAt=[DateTime]::MinValue
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 after two hours the automatic read stops'
# Leaving the page or hiding the window stops it as well.
$script:WebInvite.StartedAtUtc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
$script:WebInvite.PollAt=[DateTime]::MinValue
$script:WebPage='lines'
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 another page stops the poll'
$script:WebPage='invite';$script:Page='setup'
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 leaving the web shell stops the poll'
$script:Page='web'
$script:Window=New-Object psobject
$script:Window|Add-Member -MemberType NoteProperty -Name WindowState -Value 'Normal'
$script:Window|Add-Member -MemberType NoteProperty -Name IsVisible -Value $false
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 a hidden window stops the poll'
$script:Window.IsVisible=$true
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count+1) 'A2 a visible window resumes it'

# ==== 7. A2 leaving, closing, and the two server-page exits =====================
ResetServers;ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
InvokePoll (NewPoll -Data (NewInviteData))
$count=$script:Commands.Count
SendInvite -Phase 'Close' -Sequence 41
# 0.22.2: leaving the page keeps the open invitation and its code. Dropping them on
# the way out is what made a second visit look like the feature was one-shot; the
# code now dies only when the invitation ends or another server is chosen.
Check ([string]$script:WebInvite.State -ceq 'Open' -and [string](GetTCWebInviteCode)) 'A2 closing the page keeps the open invitation (0.22.2)'
Check ([bool]$script:WebInvite.CodePresent) 'A2 the masked preview survives the visit (0.22.2)'
Check ($script:DeployUI.Management.Driver -ceq '') 'A3 closing the page releases the driver'
PollTCWebInviteUI
Check ($script:Commands.Count -eq $count) 'A2 a closed page stops polling'
$null=OpenTCWebInvitePageUI 'server-a'
Check ([string]$script:WebInvite.InviteId -ceq 'invite-1' -and [string](GetTCWebInviteCode)) 'A2 re-entering the same invitation resumes it (0.22.2)'
ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
SendInvite -Phase 'OpenServer' -Sequence 42
Check ([string]$script:DeployUI.Management.LoginStage -ceq 'Method') 'A5 去服务器页处理 opens the login card at its method step'
Check ($script:DeployUI.Management.Driver -ceq '') 'A3 the server page takes the model back'
Check ($script:Shows -eq 1) 'A3 on the server page the server page renders'
ResetFixture;SetLiveSession
$null=OpenTCWebInvitePageUI 'server-a'
SendInvite -Phase 'Offline' -Sequence 43
Check (@($script:Toasts|Where-Object {$_ -match '离线邀请'}).Count -eq 1) 'A2 the offline fallback explains where it went (T04b finishes it)'
# Multi-server select resets the invitation instead of carrying it over.
ResetServers;ResetFixture;SetLiveSession
$script:ServerRecords=@($script:ServerRecords)+@(NewServerRecord 'server-f' 'Tokyo F' @('line-g'))
ResetTCWebInviteServerCache
$script:DeployUI.Discovery=@{Servers=@($script:ServerRecords);ManagementServers=@($script:ServerRecords)}
$null=OpenTCWebInvitePageUI 'server-a'
StartTCWebInviteUI -LifetimeSeconds 1800 -ServerId 'server-a'
DispatchOk (LastCommand 'Invoke-TCDeployPairOnlineOperation')
InvokePoll (NewPoll -Data (NewInviteData))
$probe=LastCommand 'Test-TCPairOnlineReachability'
& $probe.Complete ([pscustomobject]@{Status='Reachable';ElapsedMs=42;CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
SelectTCWebInviteServerUI 'server-f'
Check ($script:WebInvite.ServerId -ceq 'server-f') 'A2 selecting another server switches the page'
Check (-not (GetTCWebInviteCode) -and -not [string]$script:WebInvite.InviteId) 'A2 the previous invitation does not follow the switch'
Check ($script:Shows -eq 0) 'A3 switching servers never renders the server page'

# ==== 8. 0.22.1: snapshot contract, CreateNew identity, Rearm and read-only recovery ==
ResetServers;ResetFixture;SetLiveSession
$script:Nodes=@((NewLine 'line-a'))
$null=OpenTCWebInvitePageUI 'server-a'
$view=GetTCWebInviteView
$viewKeys=@($view.Keys)
Check ($viewKeys -contains 'InviteSessionId' -and $viewKeys -notcontains 'SessionId') 'the snapshot exposes InviteSessionId and no ambiguous SessionId'
$serverView=@($view.Servers|Where-Object {$_.Id -ceq 'server-a'})[0]
Check ($null -ne $serverView -and $serverView.Contains('Host') -and $serverView.Contains('Lines') -and $serverView.Contains('SavedLogin')) 'each server projection carries Id, Name, Host, Lines and SavedLogin'
Check (@($serverView['Lines']) -contains '线路 line-a' -and [bool]$serverView['SavedLogin']) 'the server projection names linked lines and reports saved login as a boolean'
$flat=GetFlatText $view
Check ($flat -cnotmatch '8f0c2f0e|fixture-secret|TCI1\.[A-Za-z0-9_-]{20,}') 'the extended snapshot still carries no credential, secret or full code'

# CreateNew always generates a fresh InviteId; the ended state may create another.
StartTCWebInviteUI -LifetimeSeconds 600 -ServerId 'server-a'
$firstCreate=LastCommand 'Invoke-TCDeployPairOnlineOperation'
$firstId=[string]$firstCreate.Arguments.InputData.InviteId
DispatchOk $firstCreate
InvokePoll (NewPoll -Data (NewInviteData -InviteId $firstId))
& (LastCommand 'Test-TCPairOnlineReachability').Complete ([pscustomobject]@{Status='Reachable';CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) (LastCommand 'Test-TCPairOnlineReachability').Context
$script:WebInvite.State='Consumed';SetTCWebInvitePhase 'Ended'
StartTCWebInviteUI -LifetimeSeconds 7200 -ServerId 'server-a'
$secondCreate=LastCommand 'Invoke-TCDeployPairOnlineOperation'
$secondId=[string]$secondCreate.Arguments.InputData.InviteId
Check ($firstId -and $secondId -and $firstId -cne $secondId) 'CreateNew after an ended invitation generates a new InviteId'
Check ([int]$secondCreate.Arguments.InputData.ExpiresInSeconds -eq 7200) 'CreateNew uses the newly selected lifetime'

# Rearm reuses the exact input and leaves the open invitation/context intact.
DispatchOk $secondCreate
InvokePoll (NewPoll -Data (NewInviteData -InviteId $secondId))
$probe=LastCommand 'Test-TCPairOnlineReachability'
& $probe.Complete ([pscustomobject]@{Status='Reachable';CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
$openId=[string]$script:WebInvite.InviteId;$openExpiry=[string]$script:WebInvite.ExpiresAtUtc;$openCode=[string]$script:WebInvite.CodePresent
RearmTCWebInviteUI
$rearm=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ([string]$rearm.Arguments.InputData.InviteId -ceq $openId) 'Rearm replays the same InviteId instead of creating a new invitation'
Check ([string]$script:WebInvite.InviteId -ceq $openId -and [string]$script:WebInvite.ExpiresAtUtc -ceq $openExpiry -and [string]$script:WebInvite.CodePresent -ceq $openCode) 'Rearm leaves the original id, expiry and code context in place'

# Recheck is only the local probe; Refresh is only the status read.
ResetFixture;SetLiveSession
$script:Nodes=@((NewLine 'line-a'))
$null=OpenTCWebInvitePageUI 'server-a'
StartTCWebInviteUI -LifetimeSeconds 600 -ServerId 'server-a'
$create=LastCommand 'Invoke-TCDeployPairOnlineOperation'
DispatchOk $create;InvokePoll (NewPoll -Data (NewInviteData -InviteId $create.Arguments.InputData.InviteId))
$probe=LastCommand 'Test-TCPairOnlineReachability';& $probe.Complete ([pscustomobject]@{Status='Reachable';CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $probe.Context
$pairOpsBefore=@($script:Commands|Where-Object {$_.Command -ceq 'Invoke-TCDeployPairOnlineOperation'}).Count
$probesBefore=@($script:Commands|Where-Object {$_.Command -ceq 'Test-TCPairOnlineReachability'}).Count
RecheckTCWebInviteUI
Check (@($script:Commands|Where-Object {$_.Command -ceq 'Invoke-TCDeployPairOnlineOperation'}).Count -eq $pairOpsBefore) 'Recheck sends no create, cancel or status operation'
$recheck=LastCommand 'Test-TCPairOnlineReachability'
Check (@($script:Commands|Where-Object {$_.Command -ceq 'Test-TCPairOnlineReachability'}).Count -eq $probesBefore+1) 'Recheck sends the local TCP/TLS probe'
& $recheck.Complete ([pscustomobject]@{Status='Reachable';CheckedAtUtc=(Get-Date).ToUniversalTime().ToString('o')}) $recheck.Context
RefreshTCWebInviteStatusUI
$status=LastCommand 'Invoke-TCDeployPairOnlineOperation'
Check ([string]$status.Arguments.Action -ceq 'status') 'Refresh sends only the status operation'

$result=[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Suite='WebInviteFlow';Assertions=$script:Checks.ToArray()
 RealNetwork=$false;WorkerLaunched=$false;FileWrites=0;HostSideOnly=$true}
$result|ConvertTo-Json -Depth 6
