#requires -Version 5.1
param([string]$SourceDirectory=(Join-Path $PSScriptRoot '..'))
$ErrorActionPreference='Stop';Add-Type -AssemblyName PresentationFramework
$script:Smoke=$true;$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-management-ui-'+[guid]::NewGuid().ToString('N'))
$script:Controls=@{};$script:Requests=New-Object 'Collections.Generic.List[object]';$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:HostPanel=New-Object Windows.Controls.StackPanel;$script:Ink='#141414';$script:Text2='#333333';$script:Text3='#666666';$script:Role='servers';$script:Page='setup'
$script:Overview=[pscustomobject]@{ManifestPath='not-read-in-smoke'};$script:Dialog=$null
function Start-Process {throw 'UI regression must not launch processes.'}
function AssertUI($condition,$name){if(-not $condition){throw ('UI regression failed: '+$name)};$script:Checks.Add($name)}
function AddC($p,$c){$null=$p.Children.Add($c)}
function T($text,$size=13,$color='black',$weight='Normal'){$c=New-Object Windows.Controls.TextBlock;$c.Text=[string]$text;return $c}
function Card($padding='20'){$c=New-Object Windows.Controls.Border;return $c}
function Stack($orientation='Vertical'){$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$orientation;return $s}
function Margin($control,$margin){return $control}
function ControlName($control,$name){$script:Controls[$name]=$control;return $control}
function Btn($text,$id,$action,$style='Btn'){$b=New-Object Windows.Controls.Button;$b.Content=$text;$b.Add_Click($action);if($id){$script:Controls[$id]=$b};return $b}
function Head($kicker,$title,$description){$script:HostPanel.Children.Clear();$script:Controls=@{}}
function SetupCardHeader($p,$title,$description,$icon){AddC $p (T $title)}
function Note($text,$tone='blue'){return T $text}
function SectionLabel($p,$text,$hint){AddC $p (T $text)}
function KeyValue($p,$key,$value){AddC $p (T ($key+':'+$value))}
function StatusLine($tone,$text){return T $text}
function Toast($text){$script:LastToast=$text}
function ErrorDialog($message){$script:Dialog=@{Title='error';Body=$message;Action=$null}}
function OpenDialog($title,$body,$note,$confirm='确定',$action=$null,$cancel='取消',$style='Primary'){$script:Dialog=@{Title=$title;Body=$body;Note=$note;Action=$action}}
function StartJob($request,$complete,$message='',$transition='',[switch]$Silent,$failed=$null){$script:Requests.Add([pscustomobject]@{Request=$request.Clone();Complete=$complete})}
function IsRunning {return $true}
function ActiveNodeId {return '11111111-1111-1111-1111-111111111111'}
function IsBusy {return $false}
function FetchNodes {}
function ShowNodes {}
function BeginProductDeployment {}
function ResumeProductDeployment($id){StartJob @{Action='DeploymentGet';RunId=$id} {} 'fixture resume'}
function DeploymentField($parent,$label,$id,$value='',$hint='',[switch]$Multiline){$box=ControlName (New-Object Windows.Controls.TextBox) $id;$box.Text=$value;AddC $parent $box;return $box}
function DeploymentActions($parent,$label,$id,$action,$style='Primary'){$b=Btn $label $id $action $style;AddC $parent $b;return $b}
function Click($id){AssertUI ($null -ne $script:Controls[$id]) ('control '+$id);$script:Controls[$id].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function Complete($data){$last=$script:Requests[$script:Requests.Count-1];& $last.Complete $data}
function Confirm {AssertUI ($null -ne $script:Dialog.Action) 'confirmation has explicit action';& $script:Dialog.Action;$script:Dialog=$null}
function Last {return $script:Requests[$script:Requests.Count-1].Request}

. (Join-Path $SourceDirectory 'ui/ServerPages.ps1')
. (Join-Path $SourceDirectory 'ui/PairingPages.ps1')
$server=[pscustomobject]@{LocalRecordId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='隔离服务器';Connection=[pscustomobject]@{Host='1.1.1.1';Port=22;User='root'};RemoteOwnerId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';NodeId='cccccccc-cccc-cccc-cccc-cccccccccccc';ServerPublicKey=('A'*43+'=');PinnedHostKey=$null;OwnershipState='Applied';LinkedNodeIds=@();ManagementSigningPublicKey=@{kty='RSA';n='fixture';e='AQAB'}}
$resume=[pscustomobject]@{RunId='91919191-9191-9191-9191-919191919191';Name='未完成线路';Stage='MaterializeCandidate';Status='Failed'}
$script:DeployUI=@{Run=$null;Management=$null;Discovery=[pscustomobject]@{Servers=@($server);ContinueRuns=@($resume)};PendingManagement=$null;DeviceResult=$null;Invite=$null;PairRequest=$null;EnrollmentId=$null}
ShowServerManagement;AssertUI ($script:Requests.Count -eq 0) 'passive server page has no backend side effects'
AssertUI ((UIProductPath 'DeploymentTransport.psm1') -eq (Join-Path ([IO.Path]::GetFullPath($SourceDirectory)) 'DeploymentTransport.psm1')) 'UI module imports resolve package root rather than ui folder'
Click ('ContinueDeployment'+($resume.RunId-replace '-',''));AssertUI ((Last).RunId -eq $resume.RunId) 'unfinished deployment entry resumes original run'
Click ServersLegacy;AssertUI ((Last).Action -eq 'ServerImportLegacy') 'legacy registration invokes actual import action rather than discovery'
Click ('ServerSelect'+($server.LocalRecordId-replace '-',''));Click ServerConnect
AssertUI ((Last).Action -eq 'ManagementSessionFixture') 'server login uses isolated session fixture'
AssertUI (-not (Last).ContainsKey('Credential')) 'login capture never contains credential'
Complete ([pscustomobject]@{SessionRef=[pscustomobject]@{RunId='dddddddd-dddd-dddd-dddd-dddddddddddd'}})
AssertUI ((Last).Operation -eq 'server_info') 'management login queries server instead of authorizing itself'
$info=[pscustomobject]@{RemoteOwnerId=$server.RemoteOwnerId;Node=[pscustomobject]@{NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey};ManagementApiVersion=2;ManagementSigningPublicKey=$server.ManagementSigningPublicKey;ConfigRevision=3}
Complete $info;AssertUI ((Last).Operation -eq 'devices') 'server info chains metadata-only device list'
$device=[pscustomobject]@{DeviceId='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';Name='第二台电脑';State='Authorized';ClientAddress='10.78.0.3/32';ClientPublicKey=('B'*43+'=');AuthorizedAtUtc=$null}
$devices=[pscustomobject]@{Devices=@($device);Total=1;NextOffset=$null;ActiveDeviceCount=1;RevokedDeviceCount=0;ConfigRevision=3};Complete $devices
Click ('DeviceRevoke'+($device.DeviceId-replace '-',''));AssertUI ((Last).Operation -eq 'revoke_preview') 'device removal begins with authoritative preview'
$count=$script:Requests.Count;$preview=[pscustomobject]@{DeviceId=$device.DeviceId;AffectedDeviceIds=@($device.DeviceId);ConfigRevision=3;ChangeDigest=('0'*64)};Complete $preview
AssertUI ($script:Requests.Count -eq $count) 'preview alone never revokes';Confirm
AssertUI ((Last).Operation -eq 'revoke' -and (Last).Input.ExpectedConfigRevision -eq 3 -and (Last).Input.ApprovedChangeDigest -eq ('0'*64)) 'revoke is exact device revision/digest approved'
Complete ([pscustomobject]@{Status='Revoked'});Complete $devices
$script:DeployUI.ActiveClientPublicKey=$device.ClientPublicKey
Click ('DeviceRevoke'+($device.DeviceId-replace '-',''));$count=$script:Requests.Count;Complete $preview
AssertUI ($script:Dialog.Title -eq 'error' -and $script:Requests.Count -eq $count) 'active device identity cannot be revoked by management UI'
$script:DeployUI.ActiveClientPublicKey=$null
Click ServerCreateInvite;AssertUI ((Last).Operation -eq 'invite_create') 'invite creation does not add a peer'
Complete ([pscustomobject]@{Invite='PUBLIC-INVITE';InviteId='ffffffff-ffff-ffff-ffff-ffffffffffff';State='Open';ExpiresAtUtc='2026-10-09T00:00:00Z'})
Click ServerCancelInvite;AssertUI ((Last).Operation -eq 'invite_cancel') 'invite cancellation is explicit remote action';Complete ([pscustomobject]@{InviteId='ffffffff-ffff-ffff-ffff-ffffffffffff';State='Cancelled'})
Click ServerTcpPreview;AssertUI ((Last).Operation -eq 'transport_plan') 'TCP add is incremental plan rather than reinstall'
$tcp=[pscustomobject]@{PlanId='dddddddd-dddd-dddd-dddd-dddddddddddd';ChangeDigest=('1'*64);Transport=@{Port=443;ServerName='www.bing.com'}};$count=$script:Requests.Count;Complete $tcp
AssertUI ($script:Requests.Count -eq $count -and $script:Dialog.Body -like '*保留*') 'TCP addition preview explains preservation before apply';Confirm
AssertUI ((Last).Operation -eq 'transport_apply') 'approved incremental TCP uses transport apply';$script:DeployUI.PendingManagement=$null
ShowProductPairing;$script:Controls.PairInviteText.Text='PUBLIC-INVITE';Click PairInspectInvite
AssertUI ((Last).Action -eq 'PairInviteInspect') 'new computer starts with signed invitation validation'
Complete ([pscustomobject]@{Fingerprint='SHA256:fixture'});Confirm
AssertUI ((Last).Action -eq 'PairRequestCreate' -and (Last).ConfirmedFingerprint -eq 'SHA256:fixture') 'first invite trust is bound to explicit fingerprint'
Complete ([pscustomobject]@{EnrollmentId='abababab-abab-abab-abab-abababababab';PairRequest='PUBLIC-REQUEST';PairingCode='ABCDE1234567'})
Click PairInspectRequest;AssertUI ((Last).Action -eq 'PairRequestInspect') 'manager inspects request before authorizing'
Complete ([pscustomobject]@{Payload=[pscustomobject]@{InviteId='ffffffff-ffff-ffff-ffff-ffffffffffff';DeviceName='新电脑';ServerBinding=@{RemoteOwnerId=$server.RemoteOwnerId;NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey};ClientRequest=[pscustomobject]@{RequestId='cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd'};RequestDigest=('2'*64)};PairingCode='ABCDE1234567'});Confirm
AssertUI ((Last).Operation -eq 'authorize_external' -and (Last).Input.PairRequest -eq 'PUBLIC-REQUEST') 'manager submits external public request not its own identity'
Complete ([pscustomobject]@{Status='Authorized';Authorization='CONFIDENTIAL-SIGNED-AUTH'})
AssertUI ((Last).Action -eq 'PairAuthorizationProtectFixture' -and -not ((Last)|ConvertTo-Json).Contains('CONFIDENTIAL')) 'signed authorization never enters a disk-backed request'
Complete ([pscustomobject]@{EncryptedAuthorization='SAFE-ENCRYPTED-RETURN'});$script:Controls.PairReturnText.Text='SAFE-ENCRYPTED-RETURN';Click PairCompleteReturn
AssertUI ((Last).Action -eq 'PairComplete' -and (Last).EnrollmentId -eq 'abababab-abab-abab-abab-abababababab') 'new computer completes original enrollment from encrypted return'
ShowManagementRecovery;$script:Controls.RecoveryExportPassword.Password='THIS-IS-A-SECRET';$script:Controls.RecoveryCredential.Password='SSH-TOP-SECRET';Click RecoveryExport
AssertUI ((Last).Action -eq 'ManagementRecoveryExportFixture' -and -not ((Last)|ConvertTo-Json).Contains('SECRET')) 'recovery passwords and management credentials remain out of worker request'
$savedInvite=$script:DeployUI.PairFields.InviteText;$savedInviteCache=$script:DeployUI.Invite;$script:DeployUI.Invite=$null;$script:DeployUI.PairFields.InviteText='';$before=$script:Requests.Count
AuthorizePairRequestUI;AssertUI ($script:Requests.Count -eq $before -and $script:Dialog.Title -eq 'error') 'missing original invitation prevents committing peer before encryption'
$script:DeployUI.PairFields.InviteText=$savedInvite;$script:DeployUI.Invite=$savedInviteCache;$savedNode=$script:DeployUI.PairRequestInspection.Payload.ServerBinding.NodeId
$script:DeployUI.PairRequestInspection.Payload.ServerBinding.NodeId='12121212-1212-1212-1212-121212121212'
AuthorizePairRequestUI;AssertUI ($script:Requests.Count -eq $before -and $script:Dialog.Title -eq 'error') 'wrong server binding prevents external authorization in UI'
$script:DeployUI.PairRequestInspection.Payload.ServerBinding.NodeId=$savedNode
$script:Smoke=$false
$intent=NewManagementIntent authorize_external @{InviteId='ffffffff-ffff-ffff-ffff-ffffffffffff';PairRequest='PUBLIC-REQUEST'} AuthorizeExternal
$intentPath=Join-Path (ManagementIntentDirectory) ($intent.OperationId+'.json')
AssertUI ([IO.File]::Exists($intentPath)) 'management mutation intent is durable before dispatch'
$text=[IO.File]::ReadAllText($intentPath);AssertUI ($text.Contains('PUBLIC-REQUEST') -and -not $text.Contains('Authorization') -and -not $text.Contains('Credential')) 'durable intent stores public identity only no signed authorization or credentials'
$intent.State='OutcomeUnknown';SaveManagementIntent $intent;$script:DeployUI.Management.UnresolvedIntent=$null;RestoreManagementIntent
AssertUI ($script:DeployUI.Management.UnresolvedIntent.OperationId -eq $intent.OperationId) 'unknown management outcome survives UI reopening'
$before=$script:Requests.Count;StartServerOperation invite_create @{DeviceName='Another computer'} InviteCreate
AssertUI ($script:Requests.Count -eq $before -and $script:Dialog.Title -eq 'error') 'unknown prior management mutation blocks blind new dispatch'
$script:DeployUI.Management.UnresolvedIntent=$null;$script:Smoke=$true
function IsRunning {return $false}
$script:Overview=[pscustomobject]@{SessionPresent=$true;Running=$false;StateKey='Fault';ManifestPath='fixture-not-read'}
$script:DeployUI.ActiveClientPublicKey=$device.ClientPublicKey
AssertUI (ServerDeviceInUse $device.ClientPublicKey) 'Fault state with actual session still protects active device identity'
$script:DeployUI.UnknownActiveIdentity=$true
AssertUI (ServerCurrentlyInUse) 'unknown server binding with possible active session blocks destructive server actions'
$storedDiscovery=$script:DeployUI.Discovery;$script:DeployUI.Discovery=$null;$script:DeployUI.ServerDiscoveryAttempted=$false;$before=$script:Requests.Count
ShowServerManagement;AssertUI ($script:Requests.Count -eq $before+1 -and (Last).Action -eq 'DeploymentDiscover') 'first server page opening loads registry automatically'
ShowServerManagement;AssertUI ($script:Requests.Count -eq $before+1) 'pending passive discovery does not recursively create background jobs'
$script:DeployUI.Discovery=$storedDiscovery
AssertUI ($server.OwnershipState -ceq 'Applied' -and (ManagementLabel $server.OwnershipState) -eq '已部署') 'friendly management labels preserve strict backend payload values'
foreach($r in $script:Requests){AssertUI ($r.Request.Action -notin @('Session','ActivateNode','SavePreferences')) ('no activation from '+$r.Request.Action)}
$script:ReadOnly=$true;$before=$script:Requests.Count
StartServerOperation revoke @{DeviceId=$device.DeviceId} Revoke
AssertUI ($script:Requests.Count -eq $before -and $script:Dialog.Title -eq 'error') 'read-only window cannot bypass Worker restrictions through direct remote operation'
ExportRecoveryUI;AssertUI ($script:Requests.Count -eq $before) 'read-only window does not export management credentials'
$absolute=[IO.Path]::GetFullPath($script:Root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if([IO.Directory]::Exists($absolute) -and $absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('tc-management-ui-')){Remove-Item -LiteralPath $absolute -Recurse -Force}
[pscustomobject]@{Ok=$true;Checks=$script:Checks.Count;Assertions=@($script:Checks);RealNetworkChanged=$false}|ConvertTo-Json -Depth 4
