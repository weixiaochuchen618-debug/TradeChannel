#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:Commands=New-Object 'Collections.Generic.List[object]'
$script:Closed=New-Object 'Collections.Generic.List[string]'
$script:Dialogs=New-Object 'Collections.Generic.List[string]'
$script:Smoke=$false;$script:ReadOnly=$false;$script:Role='servers';$script:Root='isolated-in-memory';$script:AutoTCP=$null
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$script:Checks.Add($Message)}
function ImportFunctions {param([string]$File,[string[]]$Names)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source $File),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'UI source parse failure'}
 foreach($name in $Names){$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true);$body=$definition.Body.Extent.Text;Set-Item ('Function:script:'+$name) ([scriptblock]::Create($body.Substring(1,$body.Length-2)))}
}
ImportFunctions 'ui\ServerPages.ps1' @('ServerUIGet','ServerUIReadOnly','ConnectServerReinstallUI','ShowServerReinstallTrustUI','ResetServerReinstallUI','FailServerDispatchUI','StartServerOperation','ManagementMutation')
function Import-Module {param($Name,[switch]$DisableNameChecking)if($Name -notin @('ServerRegistry.psm1','DeploymentTransport.psm1')){throw 'Unexpected module in async model fixture'}}
function UIProductPath {param($Leaf)$Leaf}
function ShowServerManagement {$script:Renders++}
function InitializeServerUI {}
function ErrorDialog {param($Message)$script:Dialogs.Add($Message)}
function StartUiCommand {param($Module,$Command,$Arguments,$Complete,$Failed,$Context,$Message)
 $script:Commands.Add(@{Command=$Command;Arguments=$Arguments;Complete=$Complete;Failed=$Failed;Context=$Context})
}
function CloseUiDeploymentSession {param($SessionRef)$script:Closed.Add($SessionRef.InstanceId)}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Style,$Context)$script:Dialog=@{Action=$Action;Context=$Context}}
function Open-TCServerTaskLease {param($Root,$ServerId)New-Object IO.MemoryStream}
function SaveManagementIntent {param($Intent)$script:SavedState=$Intent.State}
function NewManagementIntent {param($Operation,$InputData,$Purpose)[pscustomobject]@{State='Prepared';OperationId=[guid]::NewGuid().ToString('D')}}
function ResetFixture {
 $script:Commands.Clear();$script:Closed.Clear();$script:Dialogs.Clear();$script:Renders=0;$script:SavedState='';$script:Dialog=$null
 $model=@{ServerId='server-a';Server=@{Connection=@{Host='192.0.2.10';Port=22;User='root'};RecordState='Active'};ReinstallStage='NeedsCredentials';SessionRef=$null;Credential=$null;Authenticated=$false;Input=@{KeyPath=''};Error=''}
 $script:DeployUI=@{Management=$model;PendingManagement=$null;SessionRef=$null}
 $script:Controls=@{ServerKeyPath=@{Text=''};ServerPassword=@{SecurePassword=(ConvertTo-SecureString 'fixture-secret' -AsPlainText -Force)}}
}
ResetFixture
ConnectServerReinstallUI
$first=$script:Commands[0];$original=$script:DeployUI.Management
Check ($first.Command -eq 'Start-TCServerReinstallVerification' -and $original.CommandPending -and $original.ReinstallStage -eq 'Starting' -and -not $original.SessionRef) 'Reinstall identity verification is pending without blocking or claiming authentication'
ConnectServerReinstallUI
Check ($script:Commands.Count -eq 1) 'Repeated login click cannot submit another identity verification'
ResetServerReinstallUI;$original.ReinstallStage='NeedsCredentials';ConnectServerReinstallUI
$second=$script:Commands[1]
& $first.Complete ([pscustomobject]@{SessionRef=@{InstanceId='cancelled-session'};VerificationToken='cancelled'}) $first.Context
Check ($script:Closed.Contains('cancelled-session') -and $original.CommandPending -and -not $original.SessionRef) 'Late cancelled result closes only its own session and cannot attach to a new attempt'
& $second.Complete ([pscustomobject]@{SessionRef=@{InstanceId='active-session'};VerificationToken='active'}) $second.Context
Check (-not $original.CommandPending -and $original.SessionRef.InstanceId -eq 'active-session' -and $original.ReinstallStage -eq 'Observing') 'The matching identity attempt resumes at observation'
$original.ReinstallStage='AwaitingTrust';$original.ReinstallPreview=@{Connection=$original.Server.Connection;PreviewToken='preview-a';NewFingerprint='pin-new';PreviousFingerprint='pin-old'}
ShowServerReinstallTrustUI
& $script:Dialog.Action $script:Dialog.Context
$approval=$script:Commands[2]
Check ($approval.Command -eq 'Approve-TCServerReinstallFingerprint' -and $original.CommandPending -and $original.ReinstallStage -eq 'Approving') 'Fingerprint approval is asynchronous and tied to the observed session'
ResetServerReinstallUI
& $approval.Complete ([pscustomobject]@{ApprovalToken='late-approval'}) $approval.Context
Check (-not $original.ReinstallApprovalToken -and -not $original.SessionRef -and -not $original.Credential) 'Cancelled approval cannot revive an identity session or credential'

foreach($phase in @('BeforeDispatch','Executing')){
 ResetFixture;$model=$script:DeployUI.Management;$model.ReinstallStage=$null;$model.Authenticated=$true;$model.SessionRef=@{InstanceId='management-session'}
 StartServerOperation invite_create @{DeviceName='fixture'} InviteCreate
 $command=$script:Commands[0];$lease=$command.Context.Lease
 Check ($command.Command -eq 'Invoke-TCDeployOperation' -and $model.CommandPending -and $command.Context.Intent.State -eq 'Prepared') ($phase+': original intent is preserved before asynchronous dispatch')
 StartServerOperation invite_create @{DeviceName='fixture'} InviteCreate
 Check ($script:Commands.Count -eq 1) ($phase+': a pending mutation cannot be submitted twice')
 & $command.Failed 'safe fixture message' $command.Context ([pscustomobject]@{Phase=$phase})
 if($phase -eq 'BeforeDispatch'){
  Check ($command.Context.Intent.State -eq 'Rejected' -and -not $model.UnresolvedIntent -and $model.Authenticated) 'Proven undispatched operation remains retryable without claiming an unknown server mutation'
 }else{
  Check ($command.Context.Intent.State -eq 'OutcomeUnknown' -and $model.UnresolvedIntent.OperationId -eq $command.Context.Intent.OperationId -and -not $model.Authenticated) 'Dispatched failure keeps the exact original operation for reconciliation'
 }
 Check (-not $model.CommandPending -and -not $script:DeployUI.PendingManagement -and -not $lease.CanRead) ($phase+': terminal dispatch callback releases UI state and the original lease')
}
ResetFixture;$model=$script:DeployUI.Management;$model.ReinstallStage=$null;$model.Authenticated=$true;$model.SessionRef=@{InstanceId='management-session'}
StartServerOperation invite_create @{DeviceName='fixture'} InviteCreate
$command=$script:Commands[0];$lease=$command.Context.Lease
& $command.Complete ([pscustomobject]@{Ok=$false;OperationId=$command.Context.Intent.OperationId}) $command.Context
Check ($command.Context.Intent.State -eq 'Rejected' -and -not $model.UnresolvedIntent -and -not $lease.CanRead) 'Explicit executor rejection is a known rejection, never a replay or an unknown result'
$result=[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();ActualPresentationFunctions=$true;BackendFixtureOnly=$true;RemoteOperations=0}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
$result|ConvertTo-Json -Depth 6
