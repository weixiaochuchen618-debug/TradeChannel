#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-AutoTrustLoopback-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentTrust.psm1') -DisableNameChecking
$linux=Import-Module (Join-Path $PackageRoot 'LinuxServerSetup.psm1') -PassThru -DisableNameChecking
& $linux {param($p)Protect-TCLinuxPath $p -Directory} $root
$checks=New-Object 'Collections.Generic.List[string]';$refs=New-Object 'Collections.Generic.List[object]'
$server=$null;$passed=$false;$failure='';$secret=$null
function Check($ok,$message){if(-not $ok){throw $message};$checks.Add($message)}
function AwaitLogin($ref){$deadline=[DateTime]::UtcNow.AddSeconds(25);do{$s=Get-TCDeploySession $ref;if($s.Status -notin @('Connecting','Starting','Running')){return $s};Start-Sleep -Milliseconds 30}while([DateTime]::UtcNow -lt $deadline);throw 'Loopback login deadline exceeded'}
try{
 $meta=Join-Path $root 'fixture.json';$log=Join-Path $root 'auth.json'
 $fixture=Join-Path $PSScriptRoot 'login_ssh_fixture.py'
 $server=Start-Process -FilePath 'python.exe' -ArgumentList ('-B "'+$fixture+'" "'+$meta+'" "'+$log+'"') -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $root 'fixture.stderr')
 $deadline=[DateTime]::UtcNow.AddSeconds(20);while(-not [IO.File]::Exists($meta)){if($server.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'Local fixture failed to initialize'};Start-Sleep -Milliseconds 30}
 $target=[IO.File]::ReadAllText($meta)|ConvertFrom-Json
 $connection=@{Host='127.0.0.1';Port=[int]$target.Port;User='root'}
 $secret=ConvertTo-SecureString 'TC_Identity_Local_Fixture_Only!' -AsPlainText -Force
 $run=[guid]::NewGuid().ToString('D');$started=Start-TCDeploySession -Root $root -RunId $run;$ref=$started.SessionRef;$refs.Add($ref)
 $null=Set-TCDeployCredential $ref $connection @{Kind='Password';Password=$secret}
 $wait=AwaitLogin $ref
 Check ($wait.Status -ceq 'AwaitingTrust' -and -not $wait.HasSession -and $wait.ObservedFingerprint -ceq $target.Fingerprint) 'Executor returns the exact first-seen localhost identity before authentication'
 $decision=New-TCFirstTrustDecision -RunId $run -ServerRecordId ([guid]::NewGuid().ToString('D')) -Connection $connection -Fingerprint $wait.ObservedFingerprint -Origin AutomaticFirstUse
 $context=@{TrustDecisionId=$decision.TrustDecisionId;TrustOrigin='AutomaticFirstUse';RetryReason='FirstHostTrust';RetryCount=0;PriorInstanceId=''}
 $null=Set-TCDeployCredential $ref $connection @{Kind='Password';Password=$secret} $decision.Fingerprint $context
 $ready=AwaitLogin $ref
 Check ($ready.Status -ceq 'Ready' -and $ready.HasSession) 'The rebuilt executor accepts the automatic first-use origin and authenticates'
 # Hold the authenticated executor's handle before requesting its shutdown.
 # Reading StartTime after Close races with the normal, successful process exit.
 $proc=Get-Process -Id $ref.ProcessId -ErrorAction Stop
 try{
  $null=$proc.Handle
  $ownedBirth=[string]$proc.StartTime.ToUniversalTime().Ticks
  if($ownedBirth -cne [string]$ref.StartTimeUtcTicks){throw 'Authenticated executor identity changed before close'}
  $null=Stop-TCDeploySession $ref
  Check ($proc.WaitForExit(5000)) 'The same owned executor closes within the bounded wait'
 }finally{$proc.Dispose()}
 $receipt=[IO.File]::ReadAllText((Join-Path $ref.Root 'receipt.json'))|ConvertFrom-Json
 Check (@($receipt.Events|Where-Object {$_.Code -ceq 'ClientAccessContextReceived' -and $_.AccessContext.TrustOrigin -ceq 'AutomaticFirstUse' -and $_.AccessContext.TrustDecisionId -ceq $decision.TrustDecisionId}).Count -eq 1) 'Persisted executor evidence records AutomaticFirstUse honestly'
 $started=Start-TCDeploySession -Root $root -RunId ([guid]::NewGuid().ToString('D'));$changed=$started.SessionRef;$refs.Add($changed)
 $null=Set-TCDeployCredential $changed $connection @{Kind='Password';Password=$secret} ('SHA256:'+('A'*43)) @{TrustDecisionId='';TrustOrigin='AuthenticatedPin';RetryReason='InitialAttempt';RetryCount=0;PriorInstanceId=''}
 $blocked=AwaitLogin $changed
 Check ($blocked.Code -ceq 'HostKeyChanged' -and -not $blocked.HasSession) 'A changed saved identity blocks authentication'
 $evidence=[IO.File]::ReadAllText($log)|ConvertFrom-Json
 Check ($evidence.Authenticated -eq 1 -and $evidence.RemoteCommandAttempts -eq 0 -and @($evidence.AuthenticationAttempts).Count -eq 1) 'Only one loopback login occurred; no remote command or changed-identity login ran'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}finally{
 foreach($ref in $refs){
  try{$null=Stop-TCDeploySession $ref -Cancel;$null=Stop-TCDeploySession $ref}catch{}
  $p=Get-Process -Id $ref.ProcessId -ErrorAction SilentlyContinue
  if($p){try{if([string]$p.StartTime.ToUniversalTime().Ticks -ceq [string]$ref.StartTimeUtcTicks -and -not $p.WaitForExit(2000)){$p.Kill();$null=$p.WaitForExit(2000)}}finally{$p.Dispose()}}
 }
 if($server){try{if(-not $server.HasExited){$server.Kill();$null=$server.WaitForExit(3000)}}finally{$server.Dispose()}}
 if($secret){$secret.Dispose()}
 $result=[pscustomobject]@{Passed=$passed;Checks=$checks.Count;Assertions=$checks.ToArray();Failure=$failure;NetworkScope='127.0.0.1 only';RemoteCommands=0;ProductionWrites=0;HostSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'deployment\TradeChannelDeployHost.exe')).Hash}
 $report=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($report));[IO.File]::WriteAllText($report,($result|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))
 $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cmatch '^TC-AutoTrustLoopback-[a-f0-9]{32}$' -and -not @(Get-ChildItem -LiteralPath $full -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){Remove-Item -LiteralPath $full -Recurse -Force}
 $result|ConvertTo-Json -Depth 7
}
