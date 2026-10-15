#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportDirectory)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
if(-not $ReportDirectory){$ReportDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tc-login-edit-report-'+[guid]::NewGuid().ToString('N'))}
$harness=[IO.File]::ReadAllText((Join-Path $PackageRoot 'ui\Test-015UI.ps1'),[Text.Encoding]::UTF8)
$preambleEnd=$harness.IndexOf('$passed=$false;$failure=''''',$harness.IndexOf('function SelectHistoryFilter'))
$setupStart=$harness.IndexOf(" ImportNamedPresentation 'TradeChannel.ps1'")
$setupEnd=$harness.IndexOf(" ResetUI;ShowSetup;Shot '015-01-single-add-line'")
if($preambleEnd -lt 0 -or $setupStart -lt $preambleEnd -or $setupEnd -lt $setupStart){throw 'WPF fixture initialization boundaries changed'}
. ([scriptblock]::Create($harness.Substring(0,$preambleEnd))) -SourceDirectory $PackageRoot -TestOutputDirectory $ReportDirectory
$passed=$false;$failure=''
try{
 . ([scriptblock]::Create($harness.Substring($setupStart,$setupEnd-$setupStart)))
 $transport=Import-Module (Join-Path $script:PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking;GuardModuleActors $transport
 ResetUI
 $run=BaseRun 'PrepareAccess' 'WaitingUser'
 $run.LastError=[pscustomobject]@{Code='AuthenticationFailed';Message='服务器已响应，但拒绝了本次登录认证。本次登录已结束，尚未开始部署。'}
 $instance=[guid]::NewGuid().ToString();$attempt=[guid]::NewGuid().ToString()
 $ref=[pscustomobject]@{RunId=$run.RunId;InstanceId=$instance;ProcessId=999999;PipeName='FIXTURE-NOT-A-PIPE';StartTimeUtcTicks='1';Root=(Join-Path $script:Root 'session')}
 $target=[pscustomobject]@{Host='192.0.2.10';User='root';Port=22;IdentityFile=''}
 $run.AccessIssue=[pscustomobject]@{Kind='Credentials';Code='AuthenticationFailed';Connection=$target;SessionInstanceId=$instance;AuthenticationGeneration=2;RecordedAtUtc='2026-10-14T11:32:31Z'}
 $script:DeployUI.ServerId=$run.ServerRecordId;$script:DeployUI.AccessAttemptId=$attempt;$script:DeployUI.MinimumAuthenticationGeneration=2
 $script:DeployUI.Discovery=@{Servers=@([pscustomobject]@{LocalRecordId=$run.ServerRecordId;Connection=$target;Name='登录修改回归';CredentialRef=$null})}
 $script:DeployUI.SessionRef=$ref
 RenderRun $run;ClickUI 'DeployRetryLogin'
 CheckUI ((VisibleText) -match '拒绝.*登录认证') 'The original authentication reason remains visible while editing'
 CheckUI ((VisibleText) -match 'root@192.0.2.10:22') 'The failed SSH target remains explicit'
 CheckUI ((VisibleText) -notmatch '正在核对服务器登录|正在连接服务器') 'A failed login never claims to be connecting while editing'
 CheckUI ($script:Controls.ContainsKey('DeployPasswordReveal')) 'The actual retry form offers show and hide'
 $box=$script:Controls.DeployPassword;$box.Password='FAKE_TYPING_0';ShowProductDeployment
 CheckUI ([object]::ReferenceEquals($box,$script:Controls.DeployPassword) -and $box.Password -ceq 'FAKE_TYPING_0') 'Ordinary repaint retains the actual password control and input'
 $context=NewDeploymentCallbackContext -Session
 $snapshot=[pscustomobject]@{InstanceId=$instance;Poll=[pscustomobject]@{Status='Failed';Code='AuthenticationFailed';HasSession=$false;AuthenticationGeneration=2}}
 foreach($n in 1..30){
  $box.Password=('FAKE_TYPING_'+$n);$expected=$box.Password
  ApplyDeploymentSessionSnapshot $snapshot $context
  CheckUI ($box.Password -ceq $expected -and $script:Requests.Count -eq 0) ('Repeated old failure preserves edited input '+$n)
 }
 $box.Password='  FAKE_密码_$!`_UPPER  '
 $selectionFlags=[Reflection.BindingFlags]'Instance,NonPublic';$null=$box.GetType().GetMethod('Select',$selectionFlags).Invoke($box,@(3,5))
 ClickUI 'DeployPasswordReveal'
 CheckUI ($script:Controls.DeployPasswordPlainText.Text -ceq '  FAKE_密码_$!`_UPPER  ') 'Reveal preserves whitespace Unicode and punctuation exactly'
 CheckUI ($script:Controls.DeployPasswordPlainText.SelectionStart -eq 3 -and $script:Controls.DeployPasswordPlainText.SelectionLength -eq 5) 'Reveal preserves the selection and caret'
 $script:Controls.DeployPasswordPlainText.Text='  FAKE_corrected_密码$!  ';$script:Controls.DeployPasswordPlainText.Select(5,3)
 ClickUI 'DeployPasswordReveal'
 CheckUI ($box.Password -ceq '  FAKE_corrected_密码$!  ' -and $script:Controls.DeployPasswordPlainText.Text -ceq '') 'Hide synchronizes the draft and removes displayed clear text'
 $selection=GetDeploymentPasswordSelectionUI $box
 CheckUI ($selection.Start -eq 5 -and $selection.Length -eq 3) 'Hide preserves the selection in PasswordBox'
 ClickUI 'DeployPasswordReveal';SetDeploymentPasswordVisibilityUI $false
 CheckUI (-not $script:DeployUI.CredentialDraft.Revealed -and $box.Password -ceq '  FAKE_corrected_密码$!  ') 'Deactivation hides without deleting the draft'
 $script:DeployUI.Credential=@{Kind='Password';Password=(ConvertTo-SecureString 'FAKE_SUBMITTED' -AsPlainText -Force)}
 ClearDeploymentCredentialUI -KeepDraft
 CheckUI (-not $script:DeployUI.Credential -and $box.Password -ceq '  FAKE_corrected_密码$!  ') 'Submitted credential invalidation does not invalidate the editing draft'
 $script:DeployUI.AccessAttemptId=[guid]::NewGuid().ToString();$script:DeployUI.Reauth=$false
 ApplyDeploymentSessionSnapshot $snapshot $context
 CheckUI ($box.Password -ceq '  FAKE_corrected_密码$!  ' -and $script:Requests.Count -eq 0) 'A late callback cannot affect a later attempt in the same executor'
 $script:DeployUI.MinimumAuthenticationGeneration=3
 ApplyDeploymentSessionSnapshot $snapshot (NewDeploymentCallbackContext -Session)
 CheckUI ($box.Password -ceq '  FAKE_corrected_密码$!  ' -and $script:Requests.Count -eq 0) 'An older authentication generation cannot invalidate a later submission'
 $script:DeployUI.Reauth=$true;ShowProductDeployment
 $script:Controls.DeployLoginMethod.SelectedIndex=1
 CheckUI ($script:Controls.DeployPassword.SecurePassword.Length -eq 0 -and $script:Controls.DeployCredentialLabel.Text -match '私钥解密口令') 'Explicitly changing authentication method clears only that draft and updates its meaning'
 $script:Controls.DeployPassword.Password='FAKE_KEY_PHRASE';ClickUI 'DeployPasswordReveal'
 CheckUI ($script:Controls.DeployPasswordPlainText.Text -ceq 'FAKE_KEY_PHRASE') 'Private-key passphrases have the same reveal control'
 SetDeploymentPasswordVisibilityUI $false;ClearDeploymentCredentialDraftUI
 Shot '01-retry-reason-and-reveal' 'DeployPassword'
 ResetUI;ShowProductDeployment
 CheckUI ($script:Controls.ProductDeployInspect.Content -ceq '部署这台服务器' -and $script:Controls.DeployRemember.IsChecked) 'First submission states deployment intent and task-scoped remembering'
 $script:Controls.DeployPassword.Password='FAKE_SUBMISSION_SNAPSHOT'
 $script:Controls.DeployConnectionText.Text='192.0.2.10'
 $script:Controls.DeployName.Text='Snapshot fixture'
 StartProductDeployment
 CheckUI ($script:Requests.Count -eq 1 -and $script:Requests[0].Request.Action -ceq 'DeploymentCreate') 'One user submission produces one task creation'
 $submitted=$script:DeployUI.Credential.Password
 $script:Controls.DeployPassword.Password='FAKE_NEW_DRAFT'
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($submitted)
 try{$unchanged=([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) -ceq 'FAKE_SUBMISSION_SNAPSHOT')}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 CheckUI $unchanged 'Editing after submission cannot mutate the submitted credential snapshot'
 CheckUI (-not (($script:Requests[0].Request|ConvertTo-Json -Depth 20) -match 'FAKE_SUBMISSION|FAKE_NEW_DRAFT|Password|PrivateKeyPem|Passphrase')) 'No secret is serialized into the file-worker request'
 ResetUI;$script:DeployUI.TaskCredentialAvailable=$true;$script:DeployUI.FormDraft=@{LoginMethod=1};ShowProductDeployment
 CheckUI ([bool]$script:Controls.DeployUseTaskCredential.IsChecked) 'Task credentials are offered without decrypting them during form rendering'
 $keyPath=Join-Path $script:Root 'replacement-key.fixture.txt';[IO.File]::WriteAllText($keyPath,'FAKE_REPLACEMENT_KEY_CONTENT',[Text.Encoding]::UTF8)
 $script:Controls.DeployKeyPath.Text=$keyPath
 CheckUI (-not $script:Controls.DeployUseTaskCredential.IsChecked -and $script:DeployUI.TaskCredentialKeyChanged) 'Selecting a new private key deselects saved task credentials'
 ShowProductDeployment
 CheckUI (-not $script:Controls.DeployUseTaskCredential.IsChecked) 'Repainting cannot opt back into saved task credentials'
 $script:Controls.DeployUseTaskCredential.IsChecked=$true;$script:Controls.DeployConnectionText.Text='192.0.2.10'
 StartProductDeployment
 CheckUI ($script:Requests.Count -eq 1 -and $script:DeployUI.Credential.Kind -ceq 'PrivateKey' -and $script:DeployUI.Credential.Passphrase.Length -eq 0 -and $script:DeployUI.CredentialFresh) 'A newly selected unencrypted key wins even if an old saved-credential checkbox is checked'
 ResetUI;$resume=BaseRun 'PrepareAccess' 'WaitingUser';$resume|Add-Member NoteProperty Transport 'Tcp';$resume|Add-Member NoteProperty ServerName 'resume.example'
 ResumeProductDeployment $resume.RunId;DeliverUI $resume
 $server=[pscustomobject]@{LocalRecordId=$resume.ServerRecordId;Name=$resume.Name;Connection=$target;CredentialRef=$null}
 DeliverUI ([pscustomobject]@{Servers=@($server)})
 CheckUI ($script:Controls.DeployConnectionText.Text -ceq '192.0.2.10' -and $script:Controls.DeployTransport.SelectedItem.Tag -ceq 'Tcp' -and $script:Controls.DeployServerName.Text -ceq 'resume.example') 'Resume restores the original address and selected transport parameters'
 $script:DeployUI.CredentialStorageError='任务登录资料保存失败；本次可以继续。';ShowProductDeployment
 CheckUI ($script:Controls.ContainsKey('DeployCredentialStorageNotice') -and (VisibleText) -match '任务登录资料保存失败') 'A nonblocking credential-storage problem remains visible in the form'
 RenderRun $resume
 CheckUI ($script:Controls.ContainsKey('DeployCredentialStorageNotice') -and $script:Controls.ContainsKey('DeployAbandonLocal')) 'The stopped task offers both the storage result and a direct local cleanup entry'
 ResetUI;$script:Smoke=$false;$script:Role='deployment';$script:DeployUI.Run=$run;$script:DeployUI.SessionRef=$ref
 $script:DeployUI.MinimumAuthenticationGeneration=2;$script:DeployUI.LastAccessSignature='consumed-terminal-result';$script:DeployUI.Reauth=$false
 CheckUI (TestDeploymentAccessIdleUI) 'A consumed failed login is idle for this run, executor and authentication generation'
 $script:DeployUI.LastPoll=[DateTime]::MinValue;PollProductDeployment
 CheckUI ($script:Requests.Count -eq 0) 'The failed result page stops remote polling while waiting for user input'
 $script:DeployUI.MinimumAuthenticationGeneration=3
 CheckUI (-not (TestDeploymentAccessIdleUI)) 'A new authentication generation resumes polling even in the same executor'
 $script:DeployUI.MinimumAuthenticationGeneration=2;$script:DeployUI.SessionStarting=$true
 CheckUI (-not (TestDeploymentAccessIdleUI)) 'A new login submission cannot inherit the previous polling stop'
 $script:DeployUI.SessionStarting=$false;$run.Status='Running'
 CheckUI (-not (TestDeploymentAccessIdleUI)) 'An active operation is never mistaken for idle access'
 $run.Status='WaitingUser';$script:DeployUI.Reauth=$true;ShowProductDeployment
 $script:TimerTicks=0;$script:TimerFailure='';$script:TimerContext=NewDeploymentCallbackContext -Session
 $script:TimerSnapshot=$snapshot;$script:TimerFrame=New-Object Windows.Threading.DispatcherFrame
 $script:EditingTimer=New-Object Windows.Threading.DispatcherTimer;$script:EditingTimer.Interval=[TimeSpan]::FromSeconds(2)
 $script:EditingTimer.Add_Tick({
  try{
   $script:TimerTicks++;$expected='FAKE_REAL_TIMER_'+$script:TimerTicks;$script:Controls.DeployPassword.Password=$expected
   $script:DeployUI.LastPoll=[DateTime]::MinValue;PollProductDeployment
   ApplyDeploymentSessionSnapshot $script:TimerSnapshot $script:TimerContext
   if($script:Controls.DeployPassword.Password -cne $expected -or $script:Requests.Count){throw 'Real timer affected the editing draft or polled a failed executor'}
  }catch{$script:TimerFailure=$_.Exception.Message}
  if($script:TimerTicks -ge 5 -or $script:TimerFailure){$script:EditingTimer.Stop();$script:TimerFrame.Continue=$false}
 })
 $script:EditingTimer.Start();[Windows.Threading.Dispatcher]::PushFrame($script:TimerFrame)
 CheckUI ($script:TimerTicks -eq 5 -and -not $script:TimerFailure) 'Five real two-second WPF timer ticks preserve new input and ignore late failure callbacks'
 ResetUI;$ready=ReadyFixture;RenderRun $ready.Run
 CheckUI ($script:Controls.DeployLeave.Content -ceq '完成并返回，保持当前连接' -and $script:Controls.ContainsKey('DeployConnectRecommended')) 'A completed saved deployment emphasizes returning while keeping an explicit optional connection action'
 CheckUI ($script:DeniedActors.Count -eq 0) 'All verification stays inside isolated WPF and simulated workers'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($script:EditingTimer){$script:EditingTimer.Stop()}
 if($script:Window){$script:Window.Close()}
 $result=[pscustomobject]@{Passed=$passed;Version=(Get-Content -LiteralPath (Join-Path $script:PackageRoot 'version.json') -Raw -Encoding UTF8|ConvertFrom-Json).Version;Count=$script:Checks.Count;Checks=@($script:Checks.ToArray());Failure=$failure;RealActorAttempts=@($script:DeniedActors.ToArray());ProductionDataAccess=0;SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $script:PackageRoot 'ui\DeploymentPages.ps1')).Hash;Screenshots=@($script:Shots.ToArray())}
 [IO.File]::WriteAllText((Join-Path $qa 'login-editing-result.json'),($result|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($true))
 $owned=SafeLocalPath $script:Root;$marker=Join-Path $owned '.owned-ui-015'
 if($owned -cne (Join-Path ([IO.Path]::GetTempPath()) ('tc-ui-015-data-'+$testId)) -or -not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne $testId){throw 'Fixture cleanup ownership check failed'}
 Remove-Item -LiteralPath $owned -Recurse -Force
 $result|Select-Object Passed,Version,Count,Failure|ConvertTo-Json
}
