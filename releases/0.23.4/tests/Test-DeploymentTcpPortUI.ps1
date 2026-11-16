#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$harness=[IO.File]::ReadAllText((Join-Path $PackageRoot 'ui/Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'");$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt $preambleEnd -or $setupEnd -lt $setupStart){throw 'WPF fixture initialization changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
$passed=$false;$failure=''
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 ResetUI;ShowProductDeployment;$script:Controls.DeploymentAdvanced.IsExpanded=$true
 $port=$script:Controls.DeployTcpPort;$box=$script:Controls.DeployPassword
 CheckUI ($port -is [Windows.Controls.ComboBox] -and ($port.Items -join ',') -ceq '443,8443,2443' -and $port.IsReadOnly) 'Supported TCP ports are a real readonly WPF selection control'
 $box.Password='FAKE_PORT_SWITCH_SECRET';ClickUI 'DeployPasswordReveal'
 foreach($value in @('8443','2443')){
  $port.SelectedItem=$value;$script:Window.UpdateLayout()
  CheckUI ($port.Text -ceq $value) ('Selected preferred port stays exact '+$value)
  CheckUI ($script:DeployUI.CredentialDraft.Revealed -and $script:Controls.DeployPasswordPlainText.Text -ceq 'FAKE_PORT_SWITCH_SECRET' -and [object]::ReferenceEquals($box,$script:Controls.DeployPassword)) ('Selecting port preserves edited password and visibility '+$value)
 }
 SetDeploymentPasswordVisibilityUI $false;Shot '01614-tcp-port-selection' 'DeployTcpPort'
 ResetUI;$script:DeployUI.FormDraft=@{DeployTcpPort='1443'};ShowProductDeployment;$script:Controls.DeploymentAdvanced.IsExpanded=$true
 CheckUI ($script:Controls.DeployTcpPort.Text -ceq '1443') 'An old unsupported draft keeps its exact original value'
 CheckUI ((VisibleText) -match '请选择支持端口' -and (VisibleText) -match '1443') 'The retained unsupported value has an explicit correction notice'
 $script:Controls.DeployConnectionText.Text='192.0.2.10';$script:Controls.DeployPassword.Password='FAKE_OLD_DRAFT'
 StartProductDeployment
 CheckUI ($script:Requests.Count -eq 0 -and $script:LastErrorDialog -match '443.*8443.*2443') 'Unsupported legacy port cannot submit a new deployment request'
 CheckUI ($script:Controls.DeployPassword.Password -ceq 'FAKE_OLD_DRAFT') 'Port validation does not delete the password draft'
 CloseDialog
 $notice=@(Descendants $script:HostPanel|Where-Object {$_ -is [Windows.Controls.TextBlock] -and $_.Text -match '原草稿保存的端口'})[0];$notice.BringIntoView()
 Shot '01614-tcp-old-port-correction'
 $script:Controls.DeployTcpPort.SelectedItem='8443';StartProductDeployment
 CheckUI ($script:Requests.Count -eq 1 -and $script:Requests[0].Request.TcpPort -eq 8443) 'A corrected selection reaches the deployment worker request exactly once'
 CheckUI ($script:DeniedActors.Count -eq 0) 'WPF port verification invokes no actual deployment or connection actors'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($script:Window){$script:Window.Close()}
 $result=[pscustomobject]@{Passed=$passed;Count=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionDataAccess=0;Screenshots=@($script:Shots.ToArray())}
 [IO.File]::WriteAllText((Join-Path $qa 'tcp-port-ui-result.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership check failed'}
 Remove-Item -LiteralPath $owned -Recurse -Force
 $result|Select-Object Passed,Count,Failure|ConvertTo-Json
}
