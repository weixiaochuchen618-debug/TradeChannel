#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory,[string]$TestOutputDirectory='')
$ErrorActionPreference='Stop'
if(-not $SourceDirectory){$SourceDirectory=Split-Path $PSScriptRoot -Parent}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with Windows PowerShell -Sta.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:PackageRoot=[IO.Path]::GetFullPath($SourceDirectory)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-pair-ui-015-'+[guid]::NewGuid().ToString('N'))
$qa=if($TestOutputDirectory){[IO.Path]::GetFullPath($TestOutputDirectory)}else{Join-Path $script:Root 'qa'}
$common=[IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData')).TrimEnd('\')+'\'
if(($qa.TrimEnd('\')+'\').StartsWith($common,[StringComparison]::OrdinalIgnoreCase)){throw 'QA output cannot use the installed store.'}
$null=[IO.Directory]::CreateDirectory($qa)
$script:Smoke=$false;$script:ReadOnly=$false;$script:Controls=@{};$script:Role='product-pair';$script:Page='setup'
$script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
$script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0'};warn=@{Fg='#A15C07';Bg='#FDF5E8'};bad=@{Fg='#B42318';Bg='#FEF1F0'};info=@{Fg='#1D4ED8';Bg='#EEF3FE'};idle=@{Fg='#4B5360';Bg='#F2F3F5'}}
$script:Checks=New-Object 'Collections.Generic.List[string]';$script:Requests=New-Object 'Collections.Generic.List[object]';$script:AllRequests=New-Object 'Collections.Generic.List[object]'
function Start-Process {throw 'Standalone pairing UI test forbids worker/process launches.'}
function Invoke-WebRequest {throw 'Pairing UI fixtures forbid network IO.'}
function Invoke-RestMethod {throw 'Pairing UI fixtures forbid network IO.'}
function AssertPairUI {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('015 pairing UI FAILED: '+$Name)};$script:Checks.Add($Name)}
function ImportPairPresentation {param([string]$Path,[string[]]$Names)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Source parse failed: '+$Path)}
 foreach($name in $Names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -eq $name);if($nodes.Count -ne 1){throw ('Missing function: '+$name)};$body=$nodes[0].Body.Extent.Text;Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))}
}
# Load real presentation functions and real Shell.xaml, without executing app initialization.
ImportPairPresentation (Join-Path $script:PackageRoot 'TradeChannel.ps1') @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile')
ImportPairPresentation (Join-Path $script:PackageRoot 'ui/Pages.ps1') @('Tx','Head','Note')
ImportPairPresentation (Join-Path $script:PackageRoot 'ui/SetupPages.ps1') @('SetupCardHeader')
ImportPairPresentation (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1') @('DeploymentField','DeploymentActions')
. (Join-Path $script:PackageRoot 'ui/Test-PairingFixture.ps1')
[xml]$xaml=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'ui/Shell.xaml') -Raw -Encoding UTF8
$reader=New-Object Xml.XmlNodeReader($xaml);$script:Window=[Windows.Markup.XamlReader]::Load($reader)
$script:HostPanel=$script:Window.FindName('ContentHost');$script:Window.ShowInTaskbar=$false;$script:Window.ShowActivated=$false;$script:Window.Left=-16000;$script:Window.Top=-16000
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:Controls=@{};$script:HostPanel.Children.Clear();$script:Window.FindName('Scroll').ScrollToTop();AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold');AddC $script:HostPanel (Margin (T $Description 13 $script:Text3) '0,4,0,22')
}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null)
 $script:Requests.Add([pscustomobject]@{Request=$Request.Clone();Complete=$Complete});$script:AllRequests.Add($Request.Clone())
}
function IsBusy {return $false}
function Toast {param([string]$Text)$script:LastToast=$Text}
function ErrorDialog {param([string]$Text)$script:LastError=$Text}
function OpenDialog {throw 'Actual pairing UX must render trust/review inline, not create a second modal.'}
function ShowNodes {$script:OpenedNodes=$true}
function FetchNodes {StartJob @{Action='Nodes'} {} 'fixture'}
. (Join-Path $script:PackageRoot 'ui/ServerPages.ps1')
. (Join-Path $script:PackageRoot 'ui/PairingPages.ps1')
function ShowServerManagement {$script:Role='servers';$script:OpenedManager=$true}
function LoadServersUI {StartJob @{Action='ServerList'} {} 'fixture'}
function ConnectServerUI {
 $script:InlineManagerLoginId=[string]$script:DeployUI.Management.ServerId
 $script:DeployUI.PendingManagement=@{Purpose='Authenticate';ServerId=$script:InlineManagerLoginId}
 StartJob @{Action='ManagementSessionFixture';ServerId=$script:InlineManagerLoginId} {} 'login captured only'
 ShowServerManagement
}
# Management dispatch is captured; no SSH or remote mutations are executed.
function StartServerOperation {param([string]$Operation,$InputData,[string]$Purpose)
 StartJob @{Action='ServerOperation';Operation=$Operation;Input=$InputData;Purpose=$Purpose} {} 'captured only'
}
function LastPairRequest {return $script:Requests[$script:Requests.Count-1].Request}
function CompletePairFixture {param($Value)$callback=$script:Requests[$script:Requests.Count-1].Complete;& $callback $Value}
function ClickPairUI {param([string]$Id)AssertPairUI ($script:Controls.ContainsKey($Id)) ('Control '+$Id);$script:Controls[$Id].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
function ResetPairUI {
 if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()}
 $script:DeployUI=@{Invite=$null;PairRequest=$null;EnrollmentId=$null;Run=$null;Management=$null;Discovery=$null;PairFields=$null;PairIntake=$null;PairRequestInspection=$null;PairCompletion=$null;PendingManagement=$null}
 $script:Role='product-pair';$script:Requests.Clear();$script:LastError='';$script:ReadOnly=$false
}
function PumpPairUI {param([int]$Milliseconds=450)
 $frame=New-Object Windows.Threading.DispatcherFrame;$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds);$timer.Tag=$frame
 $timer.Add_Tick({$this.Stop();$this.Tag.Continue=$false});$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function VisiblePairControls {return @($script:Controls.Values|Where-Object {$_.IsVisible})}
function AssertPairActions {param([string]$Stage)
 $script:Window.UpdateLayout();$buttons=@(VisiblePairControls|Where-Object {$_ -is [Windows.Controls.Button] -and $_.Name -ne 'PairReturnToOrigin'})
 AssertPairUI ($buttons.Count -eq 2) ($Stage+' has exactly one primary and one secondary action')
 AssertPairUI (@($buttons|Where-Object {$_.Style -eq $script:Window.FindResource('Primary')}).Count -eq 1) ($Stage+' primary uses actual WPF Primary style')
 foreach($button in $buttons){$button.BringIntoView();$script:Window.UpdateLayout();PumpPairUI 10;$viewport=$script:Window.FindName('Scroll');$point=$button.TransformToAncestor($viewport).Transform((New-Object Windows.Point(0,0)))
  AssertPairUI ($button.ActualWidth -gt 40 -and $button.ActualHeight -gt 20 -and $point.Y -ge -1 -and ($point.Y+$button.ActualHeight) -le ($viewport.ActualHeight+1)) ($Stage+' action renders with reachable viewport bounds')
 }
}
function AssertClientPairUI {param([string]$Stage)
 AssertPairActions $Stage
 AssertPairUI ($script:DeployUI.PairIntake.Role -ceq 'Client') ($Stage+' retains client role')
 AssertPairUI (-not $script:Controls.ContainsKey('PairRequestText') -and -not $script:Controls.ContainsKey('PairManageServer') -and @((VisiblePairControls)|Where-Object {$_ -is [Windows.Controls.PasswordBox]}).Count -eq 0) ($Stage+' has no management or SSH credential controls')
}
function SnapshotPairUI {param([string]$Name)
 $script:Window.FindName('Scroll').ScrollToTop();$script:Window.UpdateLayout()
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$script:Window.ActualWidth,[int]$script:Window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($script:Window)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create((Join-Path $qa ($Name+'.png')));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function SetPairManagerFixture {param($Fixture,[switch]$WithoutInvite)
 InitializePairingUI;InitializeServerUI;$b=$Fixture.RequestInfo.Payload.ServerBinding;$m=$script:DeployUI.Management
 $m.Authenticated=$true;$m.ServerId=[guid]::NewGuid().ToString();$m.Info=[pscustomobject]@{RemoteOwnerId=$b.RemoteOwnerId;Node=[pscustomobject]@{NodeId=$b.NodeId;ServerPublicKey=$b.ServerPublicKey};ManagementSigningPublicKey=$Fixture.ServerJwk};$m.SessionRef=@{RunId=[guid]::NewGuid().ToString()}
 if(-not $WithoutInvite){$script:DeployUI.Invite=@{Invite=$Fixture.Invite;InviteId=$Fixture.InviteBody.InviteId;State='Open';ExpiresAtUtc=$Fixture.InviteBody.ExpiresAtUtc};$script:DeployUI.PairFields.InviteText=$Fixture.Invite}
}
try{
 $script:Window.Show();ResetPairUI;ShowProductPairing -Role Client;AssertClientPairUI 'Empty client';SnapshotPairUI '01-client-invite'
 AssertPairUI ($script:Requests.Count -eq 0) 'Passive page never reads clipboard or dispatches work'
 $f=New-PairIntakeFixture -PackageRoot $script:PackageRoot -FixtureRoot $script:Root
 $script:Controls.PairMaterialText.Text=$f.Invite;PumpPairUI
 AssertPairUI ((LastPairRequest).Action -ceq 'PairInviteInspect') 'Explicit paste automatically recognizes invitation and verifies signature'
 CompletePairFixture (Get-TCPairInvite -Invite $f.Invite -AllowUnconfirmed);AssertClientPairUI 'Invite trust';SnapshotPairUI '02-client-trust'
 $script:Window.Width=1000;$script:Window.Height=680;ShowProductPairing;AssertClientPairUI 'Minimum invitation trust';SnapshotPairUI '10-minimum-trust';$script:Window.Width=1180;$script:Window.Height=800
 AssertPairUI ($script:DeployUI.PairIntake.Stage -ceq 'InviteTrust' -and $script:Requests.Count -eq 1) 'Source trust is still an explicit inline action'
 ClickPairUI PairCreateRequest;$r=LastPairRequest
 AssertPairUI ($r.Action -ceq 'PairRequestCreate' -and $r.ConfirmedFingerprint -ceq $f.Fingerprint -and -not $r.ContainsKey('Credential')) 'Source confirmation binds fingerprint without requesting SSH credentials'
 CompletePairFixture (New-TCPairRequest -Invite $r.Invite -ConfirmedFingerprint $r.ConfirmedFingerprint -DeviceName $r.DeviceName -Root $script:Root -WgPath $f.Wg)
 AssertClientPairUI 'Waiting request';SnapshotPairUI '03-client-waiting'
 AssertPairUI ($script:DeployUI.EnrollmentId -ceq $f.Created.EnrollmentId -and $script:DeployUI.PairRequest -ceq $f.Created.PairRequest) 'Retry waiting state preserves actual original application'

 ResetPairUI;ShowProductPairing -Role Manager -Material $f.Created.PairRequest
 AssertPairUI ((LastPairRequest).Action -ceq 'PairRequestInspect') 'Request automatically chooses manager review'
 CompletePairFixture (Get-TCPairRequestInfo -PairRequest $f.Created.PairRequest);AssertPairActions 'Manager login';SnapshotPairUI '04-manager-login'
 AssertPairUI (-not $script:Controls.ContainsKey('PairInviteText') -and -not $script:Controls.ContainsKey('PairReturnText') -and $script:Controls.PairManageServer.IsVisible) 'Manager has login continuation and no client generation/completion forms'
 ClickPairUI PairManageServer;AssertPairUI ((LastPairRequest).Action -ceq 'ServerList' -and $script:OpenedManager) 'Manager login continues through existing server management'
 SetPairManagerFixture $f -WithoutInvite
 $script:DeployUI.PairFields=$null;$script:DeployUI.PairRequest=$null;$script:DeployUI.PairRequestInspection=$null
 ShowProductPairing -Role Manager;ContinuePairManagerReviewUI
 AssertPairUI ($script:DeployUI.PairRequest -ceq $f.Created.PairRequest) 'Manager server selection restores explicitly supplied public request after resetting old fields'
 AssertPairUI ((LastPairRequest).Operation -ceq 'invite_status' -and (LastPairRequest).Input.InviteId -ceq $f.InviteBody.InviteId) 'Authenticated continuation retrieves original invitation by verified request identity'
 SetPairManagerFixture $f;ContinuePairManagerReviewUI;ShowProductPairing -Role Manager;AssertPairActions 'Manager review';SnapshotPairUI '05-manager-review'
 $script:Window.Width=1000;$script:Window.Height=680;ShowProductPairing;AssertPairActions 'Minimum manager review';SnapshotPairUI '11-minimum-review';$script:Window.Width=1180;$script:Window.Height=800
 $script:ReadOnly=$true;ShowProductPairing;AssertPairUI (-not $script:Controls.PairAuthorize.IsEnabled) 'Read-only approval is visibly disabled';$count=$script:Requests.Count;AuthorizePairRequestUI;AssertPairUI ($script:Requests.Count -eq $count -and $script:LastError) 'Read-only manager cannot approve through direct handler';$script:ReadOnly=$false;ShowProductPairing
 $originalNode=$script:DeployUI.Management.Info.Node.NodeId;$script:DeployUI.Management.Info.Node.NodeId=[guid]::NewGuid().ToString();$count=$script:Requests.Count;AuthorizePairRequestUI
 AssertPairUI ($script:Requests.Count -eq $count) 'Wrong management target fails exact server binding before mutation';$script:DeployUI.Management.Info.Node.NodeId=$originalNode
 ClickPairUI PairAuthorize
 AssertPairUI ((LastPairRequest).Operation -ceq 'authorize_external' -and (LastPairRequest).Input.PairRequest -ceq $f.Created.PairRequest) 'Single inline approval dispatches exact external device request'
 $script:DeployUI.Invite.State='Consumed';ShowProductPairing -Role Manager;AssertPairActions 'Manager lost reply';ClickPairUI PairRecoverReturn
 AssertPairUI ((LastPairRequest).Operation -ceq 'request_status' -and (LastPairRequest).Input.RequestId -ceq $f.RequestInfo.RequestId -and (LastPairRequest).Input.RequestDigest -ceq $f.Created.RequestDigest) 'Lost reply refreshes original authorization without another approval/device'
 $script:DeployUI.EncryptedAuthorization=$f.Grant;ShowProductPairing;AssertPairActions 'Manager encrypted transfer';SnapshotPairUI '06-manager-encrypted'
 AssertPairUI (-not $script:Controls.ContainsKey('PairReturnText') -and $script:Controls.PairCopyEncrypted.IsVisible) 'Manager shares encrypted material and has no client completion controls'

 # Exact Root registry routing, not stale discovery or unverified material classification.
 Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
 Import-Module (Join-Path $script:PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
 $registryPath=Join-Path $script:Root 'servers\registry.json';$originalCatalog=Read-TCDJson $registryPath -AllowMissing
 $binding=$f.RequestInfo.Payload.ServerBinding
 $registration=@{RemoteOwnerId=$binding.RemoteOwnerId;Node=@{NodeId=$binding.NodeId;ServerPublicKey=$binding.ServerPublicKey;PublicEndpoint=$f.Response.PublicEndpoint};ManagementSigningPublicKey=$f.ServerJwk;ManagementApiVersion=2}
 $knownId=[guid]::NewGuid().ToString();$known=Set-TCServerRecord -Root $script:Root -Id $knownId -Name '已登记的申请目标' -Connection @{Host='8.8.8.8';Port=2222;User='root'} -ServerInfo $registration -CredentialRef 'fixture-reference-never-read'
 $wrong=$known|ConvertTo-Json -Depth 16|ConvertFrom-Json;$wrong.LocalRecordId=[guid]::NewGuid().ToString();$wrong.Name='相同入口但不同身份';$wrong.NodeId=[guid]::NewGuid().ToString()
 $archived=$known|ConvertTo-Json -Depth 16|ConvertFrom-Json;$archived.LocalRecordId=[guid]::NewGuid().ToString();$archived.Name='归档的原目标';$archived.RecordState='Archived'
 $invalid=$known|ConvertTo-Json -Depth 16|ConvertFrom-Json;$invalid.LocalRecordId=[guid]::NewGuid().ToString();$invalid.Name='连接数据损坏';$invalid.Connection.Port=0
 $catalog=Read-TCDJson $registryPath;$catalog.Servers=@($catalog.Servers)+@($wrong,$archived,$invalid)
 Write-TCDJson $registryPath $catalog
 ResetPairUI;$script:DeployUI.Discovery=[pscustomobject]@{Servers=@($archived);ContinueRuns=@()}
 ShowProductPairing -Role Manager -Material $f.Created.PairRequest
 AssertPairUI (-not $script:DeployUI.Management.ServerId) 'Unverified material classification never auto-selects a management target'
 CompletePairFixture (Get-TCPairRequestInfo -PairRequest $f.Created.PairRequest)
 AssertPairUI ($script:DeployUI.Management.ServerId -ceq $knownId -and $script:DeployUI.PairIntake.TargetMatch -ceq 'Unique' -and $script:DeployUI.PairIntake.TargetCandidates.Count -eq 1) 'Unique exact Root registry binding ignores stale discovery, archived identity, wrong node and malformed connection'
 AssertPairUI ($script:Role -ceq 'product-pair' -and $script:Controls.ServerPassword.IsVisible -and $script:Controls.ServerKeyPath.IsVisible -and -not $script:Controls.ContainsKey('PairManagerTargetChoice')) 'Unique manager target shows inline login without a server-choice step'
 AssertPairUI (-not $script:DeployUI.Management.Authenticated -and -not $script:DeployUI.Management.Info -and -not $script:DeployUI.Management.Credential -and $script:Requests.Count -eq 1) 'Registry hint never authenticates, loads saved credentials or authorizes a device'
 AssertPairActions 'Unique target inline login';SnapshotPairUI '12-manager-auto-target-login'
 $count=$script:Requests.Count;AuthorizePairRequestUI;AssertPairUI ($script:Requests.Count -eq $count) 'Unique local match cannot approve before real authenticated server_info'
 $script:ReadOnly=$true;ShowProductPairing;AssertPairUI (-not $script:Controls.PairManageServer.IsEnabled) 'Read-only inline manager login is disabled';$script:ReadOnly=$false;ShowProductPairing
 ClickPairUI PairManageServer
 AssertPairUI ($script:InlineManagerLoginId -ceq $knownId -and (LastPairRequest).Action -ceq 'ManagementSessionFixture' -and $script:Role -ceq 'product-pair') 'Inline login reuses existing ConnectServerUI for the uniquely selected registry target'
 $count=$script:Requests.Count;ConnectPairManagerUI;AssertPairUI ($script:Requests.Count -eq $count) 'Pending inline login cannot create a second management session'
 $script:DeployUI.PendingManagement=$null;$script:DeployUI.Management.Authenticated=$true
 $script:DeployUI.Management.Info=[pscustomobject]@{RemoteOwnerId=$binding.RemoteOwnerId;Node=[pscustomobject]@{NodeId=[guid]::NewGuid().ToString();ServerPublicKey=$binding.ServerPublicKey};ManagementSigningPublicKey=$f.ServerJwk}
 $count=$script:Requests.Count;ContinuePairManagerReviewUI
 AssertPairUI ($script:DeployUI.PairIntake.TargetMatch -ceq 'LiveMismatch' -and $script:Requests.Count -eq $count -and -not $script:Controls.ContainsKey('PairAuthorize')) 'Actual server_info mismatch blocks invitation retrieval and approval despite exact local routing hint'
 $script:DeployUI.Management.Info.Node.NodeId=$binding.NodeId;ContinuePairManagerReviewUI
 AssertPairUI ((LastPairRequest).Operation -ceq 'invite_status' -and (LastPairRequest).Input.InviteId -ceq $f.InviteBody.InviteId) 'Main ServerInfo continuation retrieves only original invite after actual target binding matches'
 $secondTarget=$known|ConvertTo-Json -Depth 16|ConvertFrom-Json;$secondTarget.LocalRecordId=[guid]::NewGuid().ToString();$secondTarget.Name='同一身份的另一管理入口';$secondTarget.Connection.Host='8.8.4.4';$secondTarget.Connection.Port=22
 $catalog=Read-TCDJson $registryPath;$catalog.Servers=@($catalog.Servers)+@($secondTarget);Write-TCDJson $registryPath $catalog
 ResetPairUI;ShowProductPairing -Role Manager -Material $f.Created.PairRequest;CompletePairFixture (Get-TCPairRequestInfo -PairRequest $f.Created.PairRequest)
 AssertPairUI ($script:DeployUI.PairIntake.TargetMatch -ceq 'Ambiguous' -and $script:Controls.PairManagerTargetChoice.Items.Count -eq 2 -and -not $script:Controls.ContainsKey('ServerPassword') -and -not $script:Controls.PairManageServer.IsEnabled) 'Only ambiguous exact registry matches require explicit choice and do not guess a login target'
 AssertPairActions 'Ambiguous manager target';SnapshotPairUI '13-manager-ambiguous-target'
 $script:Controls.PairManagerTargetChoice.SelectedIndex=1;$selectedId=[string]$script:Controls.PairManagerTargetChoice.SelectedItem.Tag;ClickPairUI PairManageServer
 AssertPairUI ($script:DeployUI.Management.ServerId -ceq $selectedId -and $script:Controls.ServerPassword.IsVisible -and $script:DeployUI.PairRequest -ceq $f.Created.PairRequest) 'Explicit ambiguous choice preserves original signed request and enters selected inline login'
 $catalog=Read-TCDJson $registryPath;$selectedRow=@($catalog.Servers|Where-Object LocalRecordId -eq $selectedId)[0];$originalHost=$selectedRow.Connection.Host;$selectedRow.Connection.Host='9.9.9.9';Write-TCDJson $registryPath $catalog
 $count=$script:Requests.Count;ConnectPairManagerUI;AssertPairUI ($script:DeployUI.PairIntake.TargetMatch -ceq 'Blocked' -and $script:Requests.Count -eq $count) 'Management endpoint changed after selection cannot silently receive login credentials'
 $selectedRow.Connection.Host=$originalHost;Write-TCDJson $registryPath $catalog;$script:DeployUI.PairIntake.TargetMatch='Unique'
 $catalog=Read-TCDJson $registryPath;foreach($row in $catalog.Servers){if($row.LocalRecordId -ceq $selectedId){$row.RecordState='Archived'}};Write-TCDJson $registryPath $catalog
 $count=$script:Requests.Count;ConnectPairManagerUI;AssertPairUI ($script:DeployUI.PairIntake.TargetMatch -ceq 'Blocked' -and $script:Requests.Count -eq $count) 'Target archived after selection is rejected before login by fresh registry validation'
 Write-TCDJson $registryPath $(if($originalCatalog){$originalCatalog}else{[pscustomobject]@{SchemaVersion=1;Revision=0;Servers=@()}})

 ResetPairUI;ShowProductPairing -Role Client
 AssertPairUI ($script:DeployUI.EnrollmentId -ceq $f.Created.EnrollmentId -and $script:DeployUI.PairIntake.Stage -ceq 'Waiting') 'Reopened client restores original waiting enrollment from real local record'
 $file=Join-Path $script:Root 'opened.tcgrant';[IO.File]::WriteAllText($file,(@{EncryptedAuthorization=$f.Grant}|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($true)))
 ShowProductPairing -Path $file;AssertPairUI ((LastPairRequest).Action -ceq 'PairGrantInspect') 'Explicit opened JSON grant automatically enters original-enrollment inspection'
 $resolved=Resolve-TCPairEnrollment -Root $script:Root -EncryptedAuthorization (LastPairRequest).EncryptedAuthorization
 CompletePairFixture $resolved;AssertClientPairUI 'Grant completion';SnapshotPairUI '07-client-grant'
 AssertPairUI ($script:DeployUI.EnrollmentId -ceq $f.Created.EnrollmentId -and $script:DeployUI.PairIntake.Stage -ceq 'GrantReady') 'Grant resumes cryptographically matched original enrollment'
 ClickPairUI PairCompleteReturn;AssertPairUI ((LastPairRequest).Action -ceq 'PairComplete' -and (LastPairRequest).EnrollmentId -ceq $f.Created.EnrollmentId) 'Grant completion dispatches actual local backend candidate action'
 Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
 $actual=Complete-TCPairCandidate -Root $script:Root -EnrollmentId $f.Created.EnrollmentId -EncryptedAuthorization $f.Grant -Name '隔离 WPF 配对线路'
 $actual|Add-Member NoteProperty AttentionRequired $true -Force;CompletePairFixture $actual;AssertClientPairUI 'Candidate attention';SnapshotPairUI '08-client-attention'
 AssertPairUI ($script:Controls.PairCompletionSummary.Text -like '*待处理*') 'Candidate UI preserves actionable attention instead of declaring checked completion'
 $script:Window.Width=1000;$script:Window.Height=680;ShowProductPairing;AssertClientPairUI 'Minimum size';SnapshotPairUI '09-minimum-attention'
 ResetPairUI;ShowProductPairing -Role Client;AssertClientPairUI 'Saved authorization resume'
 AssertPairUI ($script:DeployUI.PairIntake.Stage -ceq 'Resume' -and $script:Controls.PairCompleteReturn.IsVisible) 'Reopening saved verified authorization offers actual local resume without requesting another device'
 ResetPairUI;ShowProductPairing -Role Client -Material $f.Grant;$old=Resolve-TCPairEnrollment -Root $script:Root -EncryptedAuthorization $f.Grant
 QueuePairMaterialUI ($f.Grant+'A');CompletePairFixture $old
 AssertPairUI (-not $script:DeployUI.PairIntake.Grant -and $script:DeployUI.PairIntake.Stage -ne 'GrantReady') 'Stale verified grant cannot approve newly edited material'
 if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()}
 ReceivePairMaterialUI -Material ('x'*131073);AssertPairUI ($script:DeployUI.PairIntake.Error -like '*128*') 'Oversized explicit input becomes bounded inline error'
 AssertPairUI (@($script:AllRequests|Where-Object {$_.ContainsKey('Credential') -or $_.ContainsKey('Authorization') -or $_.Action -in @('Session','ConnectionSwitchCommit','DeploymentProceed')}).Count -eq 0) 'Captured pairing actions never activate TUN or expose plaintext authorization/credentials'
 AssertPairUI (@(Get-TCPairEnrollments -Root $script:Root).Count -eq 1) 'Actual WPF flow retains one independent device through retry and completion'
 $summary=[ordered]@{Ok=$true;Suite='UI-0.15.0-pairing';Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$script:Checks.Count;Checks=$script:Checks.ToArray();WpfParsed=$true;WpfRendered=$true;WorkerLaunched=$false;NetworkChanged=$false;OutputDirectory=$qa}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-015-pair-result.json'),($summary|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)));$summary|ConvertTo-Json -Depth 8
}finally{
 if(Get-Variable PairIntakeTimer -Scope Script -ErrorAction SilentlyContinue){$script:PairIntakeTimer.Stop()}
 if($script:Window){$script:Window.Close()};$f=$null
 $absolute=[IO.Path]::GetFullPath($script:Root);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if([IO.Directory]::Exists($absolute) -and $absolute.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('tc-pair-ui-015-')){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
