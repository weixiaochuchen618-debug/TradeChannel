#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Code,[string]$Name)
 $caught=$false;$actual='Uncoded';try{& $Action|Out-Null}catch{$caught=$_.Exception.Message.Contains('[TC:'+$Code+']');if($_.Exception.Message -match '\[TC:([A-Za-z0-9]+)\]'){$actual=$Matches[1]}elseif($_.FullyQualifiedErrorId -match '^([A-Za-z0-9]+)'){$actual=$Matches[1]}}
 if(-not $caught){throw ('FAILED: '+$Name+'; expected '+$Code+', actual '+$actual)};$checks.Add($Name)
}
function global:Start-Process {throw 'Isolated reinstall tests forbid process launches.'}
function global:Stop-Process {throw 'Isolated reinstall tests forbid process stops.'}
function global:Invoke-WebRequest {throw 'Isolated reinstall tests forbid network requests.'}
function global:Invoke-RestMethod {throw 'Isolated reinstall tests forbid network requests.'}
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -Force -DisableNameChecking
$registry=Get-Module ServerRegistry;$transport=Get-Module DeploymentTransport
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-server-reinstall-'+[guid]::NewGuid().ToString('N'))
$fixture=[pscustomobject]@{Sessions=@{};Calls=(New-Object 'Collections.Generic.List[object]');ObservedFingerprint=('SHA256:'+('B'*43))}
# Only the existing transport/authentication boundary is simulated. All token,
# registry, ACL, record binding, task discovery and atomic commits are real.
& $transport {
 param($Fixture)
 $script:ReinstallFixture=$Fixture
 function script:Start-TCDeploySession {
  param($Root,$RunId,$Connection,$Credential,[string]$PinnedFingerprint='')
  if(-not $Root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture rejects non-temporary roots.'}
  if($PinnedFingerprint){throw 'Discovery cannot carry an old or implicitly trusted pin.'}
  $instance=[guid]::NewGuid().ToString('D')
  $ref=[pscustomobject]@{PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));RunId=$RunId;InstanceId=$instance;ProcessId=2147483600;StartTimeUtcTicks='1';Root=(Join-Path (Join-Path $Root 'deployments/hosts') $instance)}
  $script:ReinstallFixture.Sessions[$instance]=[pscustomobject]@{Ok=$false;RunId=$RunId;InstanceId=$instance;Status='Failed';Code='HostTrustRequired';ObservedFingerprint=$script:ReinstallFixture.ObservedFingerprint;HasSession=$false;OperationId='';Operation=''}
  $script:ReinstallFixture.Calls.Add([pscustomobject]@{Kind='Discover';Connection=$Connection;PinnedFingerprint=$PinnedFingerprint;CredentialKind=$Credential.Kind})
  return [pscustomobject]@{Ok=$true;SessionRef=$ref}
 }
 function script:Get-TCDeploySession {param($SessionRef)return $script:ReinstallFixture.Sessions[$SessionRef.InstanceId]}
 function script:Set-TCDeployCredential {
  param($SessionRef,$Connection,$Credential,$PinnedFingerprint)
  $state=$script:ReinstallFixture.Sessions[$SessionRef.InstanceId]
  $script:ReinstallFixture.Calls.Add([pscustomobject]@{Kind='Authenticate';Connection=$Connection;PinnedFingerprint=$PinnedFingerprint;CredentialKind=$Credential.Kind})
  if($state.ObservedFingerprint -cne $PinnedFingerprint){$state.Code='HostKeyChanged';return [pscustomobject]@{Ok=$false}}
  $state.Status='Ready';$state.Code='Authenticated';$state.HasSession=$true
  return [pscustomobject]@{Ok=$true}
 }
 function script:Invoke-TCDeployOperation {throw 'Reinstall verification must never execute a remote operation.'}
 function script:Stop-TCDeploySession {throw 'Reinstall verification must never stop an existing process or session.'}
} $fixture
function Change-FixtureToken {param([string]$Token,[scriptblock]$Change)
 Add-Type -AssemblyName System.Security
 $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),[Text.Encoding]::UTF8.GetBytes('TradeChannel.ServerReinstall.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
 try{$value=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json;& $Change $value;return & $registry {param($Context)Protect-TCServerReinstallToken $Context} $value}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
try{
 $null=New-TCDDirectory $testRoot
 $oldFingerprint='SHA256:'+('A'*43);$newFingerprint=$fixture.ObservedFingerprint;$thirdFingerprint='SHA256:'+('C'*43)
 $connection=@{Host='192.0.2.10';Port=22;User='root';IdentityFile=(Join-Path $testRoot 'old-ssh-key')}
 $oldNode=[guid]::NewGuid().ToString('D');$oldJob=[guid]::NewGuid().ToString('D');$oldRun=[guid]::NewGuid().ToString('D');$oldIntent=[guid]::NewGuid().ToString('D')
 $info=@{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('D'*43+'=')};ManagementSigningPublicKey=@{kty='RSA';n=('A'*512);e='AQAB'};OwnershipState='Applied';ManagementApiVersion=1}
 $old=Set-TCServerRecord -Root $testRoot -Connection $connection -Name '隔离重装目标' -PinnedFingerprint $oldFingerprint -ServerInfo $info -CredentialRef ([guid]::NewGuid().ToString('D')) -SourceJobIds @($oldJob)
 $old=Set-TCServerLink -Root $testRoot -ServerId $old.LocalRecordId -NodeId $oldNode -ObservedExitIPv4 '192.0.2.10' -EvidenceSource 'Fixture'
 $other=Set-TCServerRecord -Root $testRoot -Connection @{Host='192.0.2.20';Port=2222;User='admin';IdentityFile=''} -Name '其他服务器' -PinnedFingerprint $thirdFingerprint
 $otherDigest=Get-TCDDigest $other;$originalDigest=Get-TCDDigest $old
 $runPath=Join-Path (Join-Path (Join-Path $testRoot 'deployments/runs') $oldRun) 'state.json'
 $run=[pscustomobject]@{SchemaVersion=1;RunId=$oldRun;Revision=3;ServerRecordId=$old.LocalRecordId;Status='WaitingUser';Stage='PlanReady';ClientRequest=@{RequestId=[guid]::NewGuid().ToString('D');ClientPublicKey='ISOLATED-OLD-CLIENT';DeviceId=[guid]::NewGuid().ToString('D')};ClientResponse=@{Authorization='ISOLATED-OLD-AUTHORIZATION'};ApprovedChangeDigest=('d'*64);AllowDeviceAuthorize=$true;AllowManagementInitialize=$true}
 Write-TCDJson $runPath $run
 $intentPath=Join-Path (Join-Path $testRoot 'deployments/management-intents') ($oldIntent+'.json')
 Write-TCDJson $intentPath @{SchemaVersion=1;OperationId=$oldIntent;ServerRecordId=$old.LocalRecordId;State='OutcomeUnknown';Operation='authorize_external';Input=@{PairRequest='ISOLATED-OLD-REQUEST'}}
 $legacyPath=Join-Path (Join-Path (Join-Path $testRoot 'linux-jobs') $oldJob) 'job.json'
 Write-TCDJson $legacyPath @{SchemaVersion=1;JobId=$oldJob;Connection=$connection;Name='旧任务';Status='Completed'}
 $keyPath=Join-Path ([IO.Path]::GetDirectoryName($runPath)) 'client/client.key';$null=New-TCDDirectory ([IO.Path]::GetDirectoryName($keyPath));[IO.File]::WriteAllText($keyPath,'ISOLATED-PRIVATE-KEY-MARKER')
 Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
 $null=Initialize-TCStore -Root (Join-Path $testRoot 'Product')
 $productPath=Join-Path $testRoot 'Product/active-fixture.json';Write-TCDJson $productPath @{ActiveNodeId=$oldNode;Session='ISOLATED-ACTIVE-SESSION';Protocol='Udp'}
 $keepPaths=@($runPath,$intentPath,$legacyPath,$keyPath,$productPath,(Join-Path $testRoot 'Product/index.json'));$keepHashes=@{};foreach($path in $keepPaths){$keepHashes[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
 $registryPath=Join-Path $testRoot 'servers/registry.json';$registryBefore=(Get-FileHash -LiteralPath $registryPath).Hash
 $credential=@{Kind='Password';Password=(ConvertTo-SecureString 'Isolated newly typed password' -AsPlainText -Force)}
 Assert-Reject {Set-TCServerRecord -Root $testRoot -Id $old.LocalRecordId -PinnedFingerprint $newFingerprint} HostChanged 'Ordinary changed host pin remains blocked'
 Assert-Reject {Start-TCServerReinstallVerification -Root $testRoot -ServerId $old.LocalRecordId -Credential $credential} ReinstallDeclarationRequired 'Explicit reinstall declaration required before any authentication'
 Assert-Check ($fixture.Calls.Count -eq 0) 'Rejected declaration starts no session'
 $started=Start-TCServerReinstallVerification -Root $testRoot -ServerId $old.LocalRecordId -Credential $credential -DeclaredReinstalled
 $ref=$started.SessionRef;$state=$fixture.Sessions[$ref.InstanceId]
 Assert-Check ($ref.RunId -cne $oldRun -and $fixture.Calls[0].Connection.IdentityFile -ceq '' -and -not $fixture.Calls[0].PinnedFingerprint) 'Discovery uses fresh session and no inherited pin or SSH identity path'
 Assert-Check ((Get-TCServer $testRoot $old.LocalRecordId).PinnedHostKey -ceq $oldFingerprint -and (Get-FileHash -LiteralPath $registryPath).Hash -ceq $registryBefore) 'Read-only discovery leaves original registry and pin unchanged'
 $preview=New-TCServerReinstallPreview -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -VerificationToken $started.VerificationToken
 Assert-Check ($preview.NewFingerprint -ceq $newFingerprint -and $preview.PreviousFingerprint -ceq $oldFingerprint -and $preview.ArchivedTasks.Count -eq 3 -and -not $preview.NetworkChanged -and -not $preview.RemoteChanges) 'Preview binds observed new key and retained deployment management and legacy tasks'
 Assert-Check ((Get-FileHash -LiteralPath $registryPath).Hash -ceq $registryBefore) 'Preview does not clear old pin or write management record'
 $broken=[Convert]::FromBase64String($started.VerificationToken);$broken[$broken.Length-1]=$broken[$broken.Length-1] -bxor 1;$tampered=[Convert]::ToBase64String($broken)
 Assert-Reject {New-TCServerReinstallPreview -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -VerificationToken $tampered} ReinstallTokenInvalid 'Tampered DPAPI token rejected'
 Assert-Reject {New-TCServerReinstallPreview -Root (Join-Path $testRoot 'alternate-root') -ServerId $old.LocalRecordId -SessionRef $ref -VerificationToken $started.VerificationToken} ReinstallBindingMismatch 'Token cannot move to another data root'
 Assert-Reject {New-TCServerReinstallPreview -Root $testRoot -ServerId $other.LocalRecordId -SessionRef $ref -VerificationToken $started.VerificationToken} ReinstallBindingMismatch 'Token cannot target another server'
 $wrongRef=$ref|ConvertTo-Json|ConvertFrom-Json;$wrongRef.InstanceId=[guid]::NewGuid().ToString('D')
 Assert-Reject {New-TCServerReinstallPreview -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $wrongRef -VerificationToken $started.VerificationToken} ReinstallBindingMismatch 'Token cannot reuse another SSH session'
 $expired=Change-FixtureToken $started.VerificationToken {param($c)$c.ExpiresAtUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')}
 Assert-Reject {New-TCServerReinstallPreview -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -VerificationToken $expired} ReinstallPreviewExpired 'Expired verification rejected'
 $state.ObservedFingerprint=$oldFingerprint
 Assert-Reject {New-TCServerReinstallPreview -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -VerificationToken $started.VerificationToken} ReinstallIdentityUnchanged 'Unchanged SSH identity cannot create duplicate reinstall record'
 $state.ObservedFingerprint=$newFingerprint
 Assert-Reject {Approve-TCServerReinstallFingerprint -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $thirdFingerprint -Credential $credential} ReinstallConfirmationMismatch 'Confirmation must match exact displayed fingerprint'
 $state.ObservedFingerprint=$thirdFingerprint
 Assert-Reject {Approve-TCServerReinstallFingerprint -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $newFingerprint -Credential $credential} ReinstallObservationChanged 'Changed observation before approval is blocked'
 $state.ObservedFingerprint=$newFingerprint
 $approved=Approve-TCServerReinstallFingerprint -Root $testRoot -ServerId $old.LocalRecordId -SessionRef $ref -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $newFingerprint -Credential $credential
 Assert-Check ($fixture.Calls.Count -eq 2 -and $fixture.Calls[1].PinnedFingerprint -ceq $preview.NewFingerprint -and $fixture.Calls[1].Connection.Host -ceq $connection.Host) 'Authentication uses only explicitly confirmed key and original endpoint'
 $confirm=@{Root=$testRoot;ServerId=$old.LocalRecordId;SessionRef=$ref;ApprovalToken=$approved.ApprovalToken;ConfirmedFingerprint=$newFingerprint;ApprovedChangeDigest=$preview.ChangeDigest}
 $state.HasSession=$false;$state.Code='AuthenticationFailed';$state.Status='Failed'
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallAuthenticationRequired 'Authentication failure preserves original identity'
 Assert-Check ((Get-FileHash -LiteralPath $registryPath).Hash -ceq $registryBefore) 'Failed login archives no record'
 $state.HasSession=$true;$state.Code='Authenticated';$state.Status='Ready'
 $bad=$confirm.Clone();$bad.ApprovalToken=$preview.PreviewToken
 Assert-Reject {Confirm-TCServerReinstallRecord @bad} ReinstallBindingMismatch 'Observation token alone is not explicit approval'
 $bad=$confirm.Clone();$bad.ConfirmedFingerprint=$thirdFingerprint
 Assert-Reject {Confirm-TCServerReinstallRecord @bad} ReinstallConfirmationMismatch 'Commit rejects substituted fingerprint'
 $bad=$confirm.Clone();$bad.ApprovedChangeDigest=('e'*64)
 Assert-Reject {Confirm-TCServerReinstallRecord @bad} ReinstallConfirmationMismatch 'Commit rejects substituted change digest'
 $bad=$confirm.Clone();$bad.ApprovalToken=Change-FixtureToken $approved.ApprovalToken {param($c)$c.ExpiresAtUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')}
 Assert-Reject {Confirm-TCServerReinstallRecord @bad} ReinstallPreviewExpired 'Expired approval cannot commit'
 $state.ObservedFingerprint=$thirdFingerprint
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallAuthenticationRequired 'Key changing again before commit is blocked'
 $state.ObservedFingerprint=$newFingerprint;$state.OperationId=[guid]::NewGuid().ToString('D')
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallSessionMismatch 'Session that executed another operation cannot commit'
 $state.OperationId='';$boundRun=$state.RunId;$state.RunId=[guid]::NewGuid().ToString('D')
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallSessionMismatch 'Live poll run identity must match signed session'
 $state.RunId=$boundRun
 $null=Set-TCServerRecord -Root $testRoot -Id $old.LocalRecordId -Name '核验期间改变的名称'
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallRecordChanged 'Changed original record invalidates preview'
 $null=Set-TCServerRecord -Root $testRoot -Id $old.LocalRecordId -Name $old.Name
 $run.Revision++;Write-TCDJson $runPath $run
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ReinstallTasksChanged 'Changed old authorization task invalidates approval'
 $run.Revision--;Write-TCDJson $runPath $run
 $run.Status='Running';Write-TCDJson $runPath $run
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ServerTaskBusy 'Running old task blocks archive without stopping its process'
 $run.Status='WaitingUser';Write-TCDJson $runPath $run
 $lease=Open-TCServerTaskLease -Root $testRoot -ServerId $old.LocalRecordId
 try{Assert-Reject {Confirm-TCServerReinstallRecord @confirm} Busy 'Same-server lease blocks concurrent archive and dispatch'}finally{$lease.Dispose()}
 $other=Set-TCServerRecord -Root $testRoot -Id $other.LocalRecordId -Name '其他服务器独立更新';$otherDigest=Get-TCDDigest $other
 $revisionBefore=(Read-TCDJson $registryPath).Revision
 $result=Confirm-TCServerReinstallRecord @confirm;$new=$result.Server
 Assert-Check ($result.Code -ceq 'ServerReinstallConfirmed' -and $new.LocalRecordId -ceq $preview.NewServerId -and $new.LocalRecordId -cne $old.LocalRecordId) 'Confirmed authenticated fingerprint creates new record identity'
 Assert-Check ((Read-TCDJson $registryPath).Revision -eq $revisionBefore+1 -and @(Get-TCServers $testRoot).Count -eq 3) 'Archive and new record commit in one registry revision'
 $archived=Get-TCServer -Root $testRoot -Id $old.LocalRecordId -IncludeArchived
 Assert-Check ($archived.RecordState -ceq 'Archived' -and $archived.ReplacedByServerId -ceq $new.LocalRecordId -and $archived.PinnedHostKey -ceq $oldFingerprint -and $archived.CredentialRef -ceq $old.CredentialRef -and $archived.ArchivedTasks.Count -eq 3) 'Old identity pin credential reference and history retained rather than deleted'
 Assert-Check ($new.PinnedHostKey -ceq $newFingerprint -and -not $new.CredentialRef -and -not $new.ServerPublicKey -and -not $new.NodeId -and -not $new.RemoteOwnerId -and -not $new.ManagementSigningPublicKey -and -not $new.Connection.IdentityFile -and @($new.LinkedNodeIds).Count -eq 0 -and @($new.SourceJobIds).Count -eq 0 -and $new.Reinstall.FreshDeviceIdentityRequired) 'New record inherits no client server signing device authorization or saved management credential'
 Assert-Check ((Get-TCDDigest (Get-TCServer $testRoot $other.LocalRecordId)) -ceq $otherDigest) 'Other server update neither invalidates preview nor changes during commit'
 foreach($path in $keepPaths){Assert-Check ((Get-FileHash -LiteralPath $path).Hash -ceq $keepHashes[$path]) ('Retained fixture file unchanged: '+[IO.Path]::GetFileName($path))}
 Assert-Reject {Get-TCServer $testRoot $old.LocalRecordId} ServerArchived 'Default record lookup cannot revive archived identity'
 Assert-Reject {Assert-TCServerTaskActive -Root $testRoot -RunId $oldRun} ServerArchived 'Old deployment task cannot continue its existing authorization'
 Assert-Reject {Assert-TCServerTaskActive -Root $testRoot -SourceJobId $oldJob} ServerArchived 'Old legacy task cannot continue its authorization'
 Assert-Reject {Open-TCServerTaskLease -Root $testRoot -ServerId $old.LocalRecordId} ServerArchived 'Archived record cannot acquire dispatch lease'
 Assert-Reject {Set-TCServerRecord -Root $testRoot -Id $old.LocalRecordId -Name '尝试恢复旧记录'} ServerArchived 'Ordinary record update cannot unarchive old identity'
 Assert-Reject {Set-TCServerRecord -Root $testRoot -Id $new.LocalRecordId -ServerInfo $info} ReinstallOldIdentity 'Old server authorization binding cannot enter new record'
 Assert-Reject {Set-TCServerRecord -Root $testRoot -Id $new.LocalRecordId -CredentialRef $old.CredentialRef} ReinstallOldCredential 'Old saved credential reference cannot enter new record'
 Assert-Reject {Set-TCServerRecord -Root $testRoot -Id $new.LocalRecordId -SourceJobIds @($oldJob)} ServerArchived 'Old source task cannot enter new record'
 Assert-Reject {Set-TCServerLink -Root $testRoot -ServerId $new.LocalRecordId -NodeId $oldNode} ReinstallOldDevice 'Old device line cannot be linked into new record'
 Assert-Reject {Set-TCServerRecord -Root $testRoot -ServerInfo $info -ConnectorOnly} ServerArchived 'Old invitation identity cannot create an alternate active record'
 Assert-Reject {Confirm-TCServerReinstallRecord @confirm} ServerArchived 'Replayed confirmation does not duplicate new record'
 $again=Set-TCServerRecord -Root $testRoot -Connection $connection -Name $new.Name
 Assert-Check ($again.LocalRecordId -ceq $new.LocalRecordId -and @(Get-TCServers $testRoot).Count -eq 3) 'Endpoint registration reuses active new card while ignoring archived historical card'
 $import=Import-TCLegacyServerIndex -Root $testRoot
 Assert-Check ($import.Imported -eq 0 -and @((Get-TCServer $testRoot $new.LocalRecordId).SourceJobIds).Count -eq 0) 'Legacy discovery cannot silently import archived task into new record'
 Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
 $freshRun=New-TCDeploymentRun -Root $testRoot -ServerId $new.LocalRecordId -Intent Add -Name '重装后的新部署' -ClientInspection @{NinjaTraderPaths=@();DirectDnsIPv4=@('192.0.2.53')}
 Assert-Check ($freshRun.RunId -cne $oldRun -and -not $freshRun.ClientRequest -and -not $freshRun.ClientResponse -and -not $freshRun.RequestDirectory -and -not $freshRun.ApprovedChangeDigest -and -not $freshRun.AllowDeviceAuthorize -and -not $freshRun.AllowManagementInitialize) 'Actual new deployment starts with fresh request and authorization state'
 Assert-Check ((Assert-TCServerTaskActive -Root $testRoot -RunId $freshRun.RunId).LocalRecordId -ceq $new.LocalRecordId) 'Fresh deployment passes active record guard'
 Assert-Reject {New-TCDeploymentRun -Root $testRoot -ServerId $new.LocalRecordId -Intent Existing -TemplateNodeId $oldNode} ExistingIdentityMismatch 'Existing-device shortcut cannot reuse the archived client line'
 Assert-Check ($fixture.Calls.Count -eq 2) 'Whole workflow uses discovery and exact-pin authentication only, no remote command'

 # Exercise real WPF controls and confirmation callbacks without a window,
 # production paths, a live session, or a worker process.
 Add-Type -AssemblyName PresentationFramework
 $script:Smoke=$true;$script:ReadOnly=$false;$script:AutoTCP=$false;$script:Root=$testRoot;$script:Role='servers';$script:Text3='#666666';$script:Ink='#111111';$script:Controls=@{};$script:HostPanel=New-Object Windows.Controls.StackPanel
 $script:Requests=New-Object 'Collections.Generic.List[object]';$script:Dialog=$null
 function AddC($p,$c){$null=$p.Children.Add($c)}
 function T($text,$size=13,$color='black',$weight='Normal'){$c=New-Object Windows.Controls.TextBlock;$c.Text=[string]$text;return $c}
 function Card($padding='20'){return New-Object Windows.Controls.Border}
 function Stack {return New-Object Windows.Controls.StackPanel}
 function Margin($c,$m){return $c}
 function ControlName($c,$name){$script:Controls[$name]=$c;return $c}
 function Btn($text,$id,$action,$style='Primary'){$b=New-Object Windows.Controls.Button;$b.Content=$text;$b.Add_Click($action);$script:Controls[$id]=$b;return $b}
 function Head {$script:HostPanel.Children.Clear();$script:Controls=@{}}
 function SetupCardHeader($p,$title,$description,$icon){AddC $p (T $title)}
 function Note($text,$tone='blue'){return T $text}
 function SectionLabel($p,$text,$hint){AddC $p (T $text)}
 function KeyValue($p,$key,$value){AddC $p (T ($key+':'+$value))}
 function OpenDialog($title,$body,$note,$confirm='确定',$action=$null,$cancel='取消',$style='Primary',$context=$null){$script:Dialog=@{Title=$title;Body=$body;Note=$note;Action=$action;Context=$context}}
 function ErrorDialog($message){$script:Dialog=@{Title='error';Body=$message;Action=$null;Context=$null}}
 function StartJob($request,$complete,$message='',$transition='',[switch]$Silent,$failed=$null){$script:Requests.Add(@{Request=$request.Clone();Complete=$complete})}
 function DeploymentField($p,$label,$id,$value='',$hint='',[switch]$Multiline){$c=ControlName (New-Object Windows.Controls.TextBox) $id;$c.Text=$value;AddC $p $c;return $c}
 function DeploymentActions($p,$label,$id,$action,$style='Primary'){$c=Btn $label $id $action $style;AddC $p $c;return $c}
 function IsRunning {return $false}
 function Click-UI($id){if(-not $script:Controls.ContainsKey($id)){throw ('Missing fixture UI control: '+$id)};$script:Controls[$id].RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))}
 function Confirm-UI {$dialog=$script:Dialog;$script:Dialog=$null;& $dialog.Action $dialog.Context}
 function Complete-UI($data){& $script:Requests[$script:Requests.Count-1].Complete $data}
 . (Join-Path $PackageRoot 'ui/ServerPages.ps1')
 $oldUiRun=[pscustomobject]@{RunId=$oldRun;ServerRecordId=$old.LocalRecordId;Name='旧任务';Stage='PlanReady';Status='WaitingUser'}
 $script:DeployUI=@{Management=$null;Discovery=[pscustomobject]@{Servers=@($archived,$new,$other);ContinueRuns=@($oldUiRun)};Run=$oldUiRun;PendingManagement=$null;DeviceResult=$null;Invite=$null;RecoveredCredential=$credential;Credential=$credential;SessionRef=$ref;SessionAttached=$false}
 InitializeServerUI;$m=$script:DeployUI.Management;$m.Server=$new;$m.ServerId=$new.LocalRecordId;$m.UseSavedCredential=$true;$m.UnresolvedIntent=@{OperationId=$oldIntent;Operation='authorize_external';State='OutcomeUnknown'}
 ShowServerManagement
 Assert-Check ($script:Requests.Count -eq 0 -and -not $script:Controls.ContainsKey('ContinueDeployment'+($oldRun-replace '-','')) -and -not $script:Controls.ContainsKey('ServerSelect'+($old.LocalRecordId-replace '-',''))) 'UI passive render makes no backend calls and removes archived resume actions'
 Click-UI ServerReinstall
 Assert-Check ($m.ReinstallStage -eq $null -and $script:Dialog.Action -and $script:Requests.Count -eq 0) 'Declaring reinstall is a separate explicit confirmation'
 Confirm-UI
 Assert-Check ($m.ReinstallStage -ceq 'NeedsCredentials' -and -not $m.UseSavedCredential -and -not $m.Credential -and -not $script:DeployUI.RecoveredCredential -and -not $script:DeployUI.Credential -and -not $m.Input.KeyPath) 'Entering reinstall clears only UI credential caches and requests fresh input'
 Assert-Check ($m.UnresolvedIntent.OperationId -ceq $oldIntent) 'Entering identity verification preserves previous unresolved management outcome'
 Click-UI ServerReinstallConnect
 Assert-Check ($script:Requests[$script:Requests.Count-1].Request.Action -ceq 'ServerReinstallVerificationFixture' -and -not $script:Requests[$script:Requests.Count-1].Request.ContainsKey('Credential')) 'UI captures read-only session intent without putting credential in worker request'
 Complete-UI @{SessionRef=$ref;VerificationToken='fixture-verification'}
 PollServerReinstallUI @{Code='HostTrustRequired';Status='Failed';HasSession=$false;ObservedFingerprint=$thirdFingerprint}
 $request=$script:Requests[$script:Requests.Count-1].Request
 Assert-Check ($request.Action -ceq 'ServerReinstallPreview' -and $request.ServerId -ceq $new.LocalRecordId -and $request.VerificationToken -ceq 'fixture-verification' -and -not $request.ContainsKey('ObservedFingerprint')) 'Preview worker contract binds session token rather than trusting a GUI observed value'
 $uiPreview=@{ServerId=$new.LocalRecordId;NewServerId=[guid]::NewGuid().ToString('D');Connection=$new.Connection;PreviousFingerprint=$newFingerprint;NewFingerprint=$thirdFingerprint;PreviewToken='fixture-preview';ChangeDigest=('f'*64)}
 Complete-UI $uiPreview
 Assert-Check ($m.ReinstallStage -ceq 'AwaitingTrust' -and $script:Dialog.Body.Contains($thirdFingerprint) -and $script:Dialog.Body.Contains($newFingerprint) -and $script:Dialog.Note.Contains('云控制台') -and $script:Requests.Count -eq 2) 'New fingerprint is displayed for trusted-source verification before confirmation'
 $script:ReadOnly=$true;Confirm-UI
 Assert-Check ($m.ReinstallStage -ceq 'AwaitingTrust' -and -not $m.ReinstallApprovalToken -and $script:Requests.Count -eq 2) 'Read-only mode entered while confirmation is open prevents exact-pin authentication'
 $script:ReadOnly=$false
 $uiRegistryHash=(Get-FileHash -LiteralPath $registryPath).Hash
 ResetServerReinstallUI
 Assert-Check (-not $m.ReinstallStage -and -not $m.Credential -and $m.UnresolvedIntent.OperationId -ceq $oldIntent -and (Get-FileHash -LiteralPath $registryPath).Hash -ceq $uiRegistryHash) 'Cancelling fingerprint review retains records and unresolved outcome without process stop'
 $m.ReinstallStage='AwaitingTrust';$m.ReinstallPreview=$uiPreview;$m.SessionRef=$ref;ShowServerReinstallTrustUI;Confirm-UI
 Assert-Check ($m.ReinstallStage -ceq 'Authenticating' -and $m.ReinstallApprovalToken -ceq 'fixture-approval' -and $script:Requests.Count -eq 2) 'Explicit fingerprint confirmation precedes any commit request'
 PollServerReinstallUI @{Code='Authenticated';Status='Ready';HasSession=$true;ObservedFingerprint=$thirdFingerprint}
 $request=$script:Requests[$script:Requests.Count-1].Request
 Assert-Check ($request.Action -ceq 'ServerReinstallConfirm' -and $request.ConfirmedFingerprint -ceq $thirdFingerprint -and $request.ApprovedChangeDigest -ceq $uiPreview.ChangeDigest -and $request.ApprovalToken -ceq 'fixture-approval') 'Commit worker request carries exact confirmed fingerprint digest and approval token'
 $uiNew=$new|ConvertTo-Json -Depth 12|ConvertFrom-Json;$uiNew.LocalRecordId=$uiPreview.NewServerId;$uiNew.PinnedHostKey=$thirdFingerprint;$script:DeployUI.Run=[pscustomobject]@{ServerRecordId=$new.LocalRecordId;RunId=$freshRun.RunId;ApprovedChangeDigest='ISOLATED-OLD-APPROVAL'};$script:DeployUI.PairFields=@{InviteText='ISOLATED-OLD-INVITE';RequestText='ISOLATED-OLD-PAIR-REQUEST'};$script:DeployUI.PairRequest='ISOLATED-OLD-PAIR-REQUEST';$script:DeployUI.EnrollmentId=$oldRun;$m.Input.RenameId=$oldNode
 Complete-UI @{Server=$uiNew}
 Assert-Check ($m.ServerId -ceq $uiNew.LocalRecordId -and -not $m.ReinstallStage -and -not $m.ReinstallApprovalToken -and -not $script:DeployUI.Run -and -not $script:DeployUI.DeviceResult -and -not $script:DeployUI.Invite) 'Successful UI confirmation selects new record and detaches old deployment and authorization caches'
 Assert-Check (-not $script:DeployUI.PairRequest -and -not $script:DeployUI.PairFields -and -not $script:DeployUI.EnrollmentId -and -not $m.Input.RenameId -and -not $m.UnresolvedIntent) 'New UI record retains no old pairing enrollment device rename or management intent cache'
 Assert-Check (@($script:Requests|Where-Object {$_.Request.Action -in @('Session','DeploymentProceed','DeploymentCreate','ServerOperation')}).Count -eq 0 -and $fixture.Calls.Count -eq 2) 'UI confirmation performs no activation deployment service restart or device authorization'
 $script:ReadOnly=$true;$before=$script:Requests.Count;BeginServerReinstallUI
 Assert-Check ($script:Requests.Count -eq $before -and $script:Dialog.Title -ceq 'error') 'Read-only inspection window cannot initiate SSH re-verification'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='Simulated authentication only';RealNetworkChanged=$false;RealProcessStartedOrStopped=$false}|ConvertTo-Json -Depth 4
}finally{
 # Remove only this run's verified temporary root, using one native shell.
 $absolute=[IO.Path]::GetFullPath($testRoot);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($absolute.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -match '^tc-server-reinstall-[a-f0-9]{32}$' -and [IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
