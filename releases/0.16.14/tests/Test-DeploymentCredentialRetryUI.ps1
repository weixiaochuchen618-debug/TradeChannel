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
$passed=$false;$failure='';$held=$null;$timings=New-Object 'Collections.Generic.List[object]'
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 $flow=Import-Module (Join-Path $script:PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking;GuardModuleActors $flow
 $registry=Import-Module (Join-Path $script:PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking;GuardModuleActors $registry
 $transport=Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking;GuardModuleActors $transport
 ResetUI
 $run=New-TCDeploymentRun -Root $script:Root -Connection @{Host='192.0.2.80';Port=22;User='root';IdentityFile=''} -Name '登录资料重读夹具'
 & $registry {param($Root,$Id)
  $reg=Read-TCServerRegistry $Root;$server=@($reg.Servers|Where-Object LocalRecordId -eq $Id)[0]
  $server.PinnedHostKey='SHA256:'+('A'*43);$server.RecordState='Active'
  Write-TCDJson (Join-Path (Get-TCDPath $Root servers) 'registry.json') $reg
 } $script:Root $run.ServerRecordId
 $null=Save-TCDeployTaskCredential -Root $script:Root -RunId $run.RunId -Credential @{Kind='Password';Password=(ConvertTo-SecureString 'FAKE_SAVED_METADATA_ONLY' -AsPlainText -Force)} -CredentialRevision ([guid]::NewGuid().ToString())
 $credentialPath=Join-Path $script:Root ('deployments/credentials/'+$run.RunId+'.json')
 $statePath=Join-Path $script:Root ('deployments/runs/'+$run.RunId+'/state.json')
 $credentialBefore=(Get-FileHash -LiteralPath $credentialPath).Hash;$stateBefore=(Get-FileHash -LiteralPath $statePath).Hash
 $script:DeployUI.Run=$run;$script:DeployUI.Reauth=$true;$script:DeployUI.TaskCredentialAvailable=$true
 $script:DeployUI.FormDraft=@{DeployConnectionText='192.0.2.80';UseTaskCredential=$false;RememberTask=$false}
 ShowProductDeployment
 $box=$script:Controls.DeployPassword;$box.Password='FAKE_NEW_EDITED_PASSWORD';ClickUI 'DeployPasswordReveal'
 CheckUI (-not $script:Controls.DeployUseTaskCredential.IsChecked -and -not $script:Controls.DeployRemember.IsChecked) 'Explicit saved-credential and remembering choices begin unchecked'
 $held=[IO.File]::Open($statePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 $script:DeployUI.TaskCredentialReadState=Get-TCDeployTaskCredentialState -Root $script:Root -RunId $run.RunId -InfoOnly
 ShowProductDeployment
 CheckUI ($script:DeployUI.TaskCredentialReadState.Status -ceq 'TemporarilyUnavailable' -and $script:Controls.ContainsKey('DeployRetryTaskCredential')) 'A real locked state file exposes the actual metadata retry button'
 $watch=[Diagnostics.Stopwatch]::StartNew();ClickUI 'DeployRetryTaskCredential';$watch.Stop()
 $timings.Add([pscustomobject]@{Case='HeldFileLock';ElapsedMilliseconds=$watch.ElapsedMilliseconds})
 CheckUI ($watch.ElapsedMilliseconds -lt 2000 -and $script:DeployUI.TaskCredentialReadState.Status -ceq 'TemporarilyUnavailable') 'The real retry click is bounded and does not wait for a held file lock'
 CheckUI ([object]::ReferenceEquals($box,$script:Controls.DeployPassword) -and $script:DeployUI.CredentialDraft.Revealed -and $script:Controls.DeployPasswordPlainText.Text -ceq 'FAKE_NEW_EDITED_PASSWORD') 'A failed metadata retry preserves the actual password editor and reveal state'
 $script:Window.FindName('Scroll').ScrollToTop();$script:Window.UpdateLayout()
 $notice=$script:Controls.DeployCredentialReadNotice;$retry=$script:Controls.DeployRetryTaskCredential;$scroll=$script:Window.FindName('Scroll')
 $top=$notice.TranslatePoint([Windows.Point]::new(0,0),$scroll).Y;$bottom=$retry.TranslatePoint([Windows.Point]::new(0,$retry.ActualHeight),$scroll).Y
 CheckUI ($top -ge 0 -and $bottom -le $scroll.ActualHeight) 'Both the local-read explanation and retry action are visible without scrolling'
 Shot '01614-credential-read-locked'
 $held.Dispose();$held=$null
 $watch=[Diagnostics.Stopwatch]::StartNew();ClickUI 'DeployRetryTaskCredential';$watch.Stop()
 $timings.Add([pscustomobject]@{Case='ReleasedFileLock';ElapsedMilliseconds=$watch.ElapsedMilliseconds})
 CheckUI ($script:DeployUI.TaskCredentialAvailable -and $script:DeployUI.TaskCredentialReadState.Status -ceq 'Available' -and -not $script:DeployUI.TaskCredentialReadState.Credential) 'Releasing the lock and clicking retries real InfoOnly metadata without decrypting a credential'
 CheckUI ([object]::ReferenceEquals($box,$script:Controls.DeployPassword) -and $script:DeployUI.CredentialDraft.Revealed -and $script:Controls.DeployPasswordPlainText.Text -ceq 'FAKE_NEW_EDITED_PASSWORD') 'Successful metadata reread cannot replace newly edited input or its show/hide state'
 CheckUI (-not $script:Controls.DeployUseTaskCredential.IsChecked -and -not $script:Controls.DeployRemember.IsChecked) 'Reread preserves both explicit checkbox choices'
 CheckUI ((Get-FileHash -LiteralPath $credentialPath).Hash -ceq $credentialBefore -and (Get-FileHash -LiteralPath $statePath).Hash -ceq $stateBefore) 'Repeated metadata reads preserve the exact saved encrypted credential and task bytes'
 CheckUI ($script:Requests.Count -eq 0 -and $script:DeniedActors.Count -eq 0) 'Neither retry click authenticates, deploys, dispatches a worker, or changes the active connection'
 Shot '01614-credential-read-restored'
 $script:DeployUI.Reauth=$false;StartProductDeployment
 CheckUI ($script:Requests.Count -eq 1 -and $script:DeployUI.CredentialFresh) 'Only an explicit later submit dispatches a request and uses the newly typed credential'
 $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:DeployUI.Credential.Password)
 try{CheckUI ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -ceq 'FAKE_NEW_EDITED_PASSWORD') 'The explicit later submit keeps the new input instead of replacing it with saved login data'}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)}
 CheckUI ($script:DeniedActors.Count -eq 0) 'Credential retry verification uses only isolated data and guarded actors'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($held){$held.Dispose()}
 if($script:Window){$script:Window.Close()}
 $result=[pscustomobject]@{Passed=$passed;Count=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;Timings=$timings.ToArray();SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $script:PackageRoot 'ui/DeploymentPages.ps1')).Hash;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionDataAccess=0;Screenshots=@($script:Shots.ToArray())}
 [IO.File]::WriteAllText((Join-Path $qa 'credential-retry-ui-result.json'),($result|ConvertTo-Json -Depth 9),[Text.UTF8Encoding]::new($true))
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership check failed'}
 Remove-Item -LiteralPath $owned -Recurse -Force
 $result|Select-Object Passed,Count,Failure,Timings|ConvertTo-Json -Depth 4
}
