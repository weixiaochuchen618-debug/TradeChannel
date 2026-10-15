#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportDirectory,[switch]$ExpectOldFailure)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if(-not $ReportDirectory){$ReportDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tc-focus-report-'+[guid]::NewGuid().ToString('N'))}
$harness=[IO.File]::ReadAllText((Join-Path $PackageRoot 'ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupEnd -lt $setupStart){throw 'WPF harness boundaries changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
$passed=$false;$failure='';$oldFailureObserved=$false;$facts=@()
function Pump {$script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)}
function TypeAtFocus {param([string]$Text)
 $focus=[Windows.Input.Keyboard]::FocusedElement
 if($focus){$composition=New-Object Windows.Input.TextComposition([Windows.Input.InputManager]::Current,$focus,$Text);$null=[Windows.Input.TextCompositionManager]::StartComposition($composition)}
 Pump
}
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 ResetUI;BeginProductDeployment 'New';Pump
 $box=$script:Controls.DeployConnectionText;$null=$script:Window.Activate();$box.BringIntoView();$null=$box.Focus();Pump
 CheckUI ([object]::ReferenceEquals([Windows.Input.Keyboard]::FocusedElement,$box)) 'Fixture owns real keyboard focus before discovery finishes'
 TypeAtFocus '192.0.2.10';CheckUI ($box.Text -ceq '192.0.2.10') 'WPF TextComposition enters the first address without direct Text assignment'
 $box.Select(8,2);$script:Controls.DeployPassword.Password='FOCUS_SYNTHETIC_ONLY';$password=$script:Controls.DeployPassword
 DeliverUI ([pscustomobject]@{Servers=@();ContinueRuns=@()});Pump
 $same=[object]::ReferenceEquals($box,$script:Controls.DeployConnectionText)
 $focused=[object]::ReferenceEquals([Windows.Input.Keyboard]::FocusedElement,$box)
 $selection=($script:Controls.DeployConnectionText.SelectionStart -eq 8 -and $script:Controls.DeployConnectionText.SelectionLength -eq 2)
 TypeAtFocus '25'
 $facts+=,[pscustomobject]@{SameControl=$same;KeyboardFocusKept=$focused;SelectionKept=$selection;TextAfterCallbackAndTyping=$script:Controls.DeployConnectionText.Text}
 $oldFailureObserved=(-not $same -and -not $focused -and $script:Controls.DeployConnectionText.Text -cne '192.0.2.25')
 if($ExpectOldFailure){CheckUI $oldFailureObserved 'Old callback replaces the focused control and loses subsequent typing';Shot 'old-discovery-focus-loss'}
 else{
  CheckUI ($same -and $focused -and $selection) 'Discovery preserves the actual address box, keyboard focus and selection'
  CheckUI ($box.Text -ceq '192.0.2.25') 'Typing continues at the same selection after discovery without a second click'
  CheckUI ([object]::ReferenceEquals($password,$script:Controls.DeployPassword) -and $password.Password -ceq 'FOCUS_SYNTHETIC_ONLY') 'Discovery preserves the actual password box and its input'
  CheckUI ($script:AllRequests.Count -eq 1 -and $script:AllRequests[0].Action -ceq 'DeploymentDiscover') 'Discovery neither submits deployment nor logs in'
  Shot 'new-discovery-preserves-input'
  ResetUI;BeginProductDeployment 'New';$old=$script:Requests[0];BeginProductDeployment 'New';$currentBox=$script:Controls.DeployConnectionText;$currentBox.Text='192.0.2.31'
  & $old.Complete ([pscustomobject]@{Servers=@();ContinueRuns=@()}) $old.CallbackContext
  CheckUI ([object]::ReferenceEquals($currentBox,$script:Controls.DeployConnectionText) -and $currentBox.Text -ceq '192.0.2.31' -and $null -eq $script:DeployUI.Discovery) 'A late callback from a previous flow does not touch the new form'
  ResetUI;BeginProductDeployment 'New';$late=$script:Requests[0];ShowHome
  & $late.Complete ([pscustomobject]@{Servers=@();ContinueRuns=@()}) $late.CallbackContext
  CheckUI ($script:Page -ceq 'home') 'A late discovery cannot reopen a form after navigation'
  ResetUI;$serverId=[guid]::NewGuid().ToString();BeginProductDeployment 'Existing' $serverId
  CheckUI (-not $script:Controls.ContainsKey('DeployConnectionText')) 'Known server waits for its actual defaults before presenting an editable form'
  DeliverUI ([pscustomobject]@{Servers=@([pscustomobject]@{LocalRecordId=$serverId;Name='Existing fixture';Connection=[pscustomobject]@{Host='192.0.2.88';User='admin';Port=2222;IdentityFile=''};CredentialRef=$null})});Pump
  CheckUI ($script:Controls.DeployConnectionText.Text -ceq '192.0.2.88' -and $script:Controls.DeployUser.Text -ceq 'admin' -and $script:Controls.DeployPort.Text -ceq '2222') 'Existing server address and login defaults are populated correctly'
  Shot 'existing-server-defaults'
 }
 CheckUI ($script:DeniedActors.Count -eq 0) 'No network, real worker or production actor executed'
 $passed=$true
}catch{$failure=$_.ToString()+' '+$_.ScriptStackTrace}
finally{
 $summary=[ordered]@{Passed=$passed;ExpectedOldFailure=[bool]$ExpectOldFailure;OldFailureObserved=$oldFailureObserved;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();Facts=$facts;Failure=$failure;Screenshots=$script:Shots.ToArray();FixtureOnly=$true;RealActorAttempts=$script:DeniedActors.ToArray();PowerShellVersion=$PSVersionTable.PSVersion.ToString()}
 $summary|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $qa 'summary.json') -Encoding UTF8
 if($script:Window){$script:Window.Close()}
 if($script:Root.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath (Join-Path $script:Root '.owned-ui-015'))){Remove-Item -LiteralPath $script:Root -Recurse -Force}
}
if(-not $passed){throw $failure}
$summary|Select-Object Passed,Checks,OldFailureObserved,ExpectedOldFailure|ConvertTo-Json
