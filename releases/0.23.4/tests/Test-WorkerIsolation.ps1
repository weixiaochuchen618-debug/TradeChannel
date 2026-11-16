#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent}
$ErrorActionPreference='Stop';$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param($Condition,$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
$jobs=Join-Path $fixture 'Product\jobs';$null=New-Item -ItemType Directory -Path $jobs -Force
$before=@(Get-Process -Name 'sing-box','NinjaTrader' -ErrorAction SilentlyContinue|ForEach-Object {$_.Id}|Sort-Object)
function Invoke-FixtureWorker {param([hashtable]$Request)
 $id=[guid]::NewGuid().ToString('N');$requestPath=Join-Path $jobs ($id+'.request.json');$resultPath=Join-Path $jobs ($id+'.result.json')
 $Request=$Request.Clone();$Request.RequestId=$id;$Request.PageGeneration=7
 [IO.File]::WriteAllText($requestPath,($Request|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($true)))
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' +(Join-Path $PackageRoot 'Worker.ps1')+'"'),'-RequestPath',('"'+$requestPath+'"'),'-ResultPath',('"'+$resultPath+'"'),'-IsolatedTest','-TestRoot',('"'+$fixture+'"'))
 $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
 try{if(-not $process.WaitForExit(45000)){$process.Kill();throw 'Fixture Worker timed out.'};if(-not(Test-Path -LiteralPath $resultPath)){throw 'Fixture Worker did not produce a result.'};$response=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;Assert-Check ($response.RequestId -ceq $id -and $response.PageGeneration -eq 7) 'request envelope round-trips without entering business fields';return $response}finally{$process.Dispose()}
}
try{
 $overview=Invoke-FixtureWorker @{Action='Overview'}
 Assert-Check $overview.Ok ('real Worker overview exported API works: '+$overview.Message)
 Assert-Check ($overview.Data.StateKey -in @('Unconfigured','Disconnected')) 'empty fixture never presents live channel'
 $report=Invoke-FixtureWorker @{Action='RuntimeReport'};Assert-Check $report.Ok 'real Worker readable runtime report resolves modules'
 $discover=Invoke-FixtureWorker @{Action='DeploymentDiscover'};Assert-Check ($discover.Ok -and @($discover.Data.Servers).Count -eq 0) 'discovery reads isolated empty store'
 $created=Invoke-FixtureWorker @{Action='DeploymentCreate';Intent='New';Connection=@{Host='203.0.113.70';Port=22;User='root';IdentityFile=''};Name='隔离新服务器';Transport='Udp';TcpPort=443;ServerName='www.bing.com'}
 Assert-Check $created.Ok ('create stores run without remote SSH: '+$created.Message)
 Assert-Check ($created.Data.Stage -eq 'PrepareAccess' -and $created.Data.NetworkChanged -eq $false) 'created run waits access without mutation'
 $discover=Invoke-FixtureWorker @{Action='DeploymentDiscover'}
 Assert-Check ($discover.Ok -and @($discover.Data.Servers).Count -eq 1 -and @($discover.Data.ContinueRuns).Count -eq 1) 'persisted run and server survive separate Worker process'
 foreach($invalid in @(
  @{Action='DeploymentAccessState';RunId='';SessionRef=@{RunId=$created.Data.RunId;InstanceId=[guid]::NewGuid().ToString()}},
  @{Action='DeploymentAccessState';RunId='00000000-0000-0000-0000-000000000000';SessionRef=@{RunId=$created.Data.RunId;InstanceId=[guid]::NewGuid().ToString()}},
  @{Action='DeploymentAttach';RunId=$created.Data.RunId;SessionRef=@{RunId=[guid]::NewGuid().ToString();InstanceId=[guid]::NewGuid().ToString()}},
  @{Action='DeploymentProceed';RunId=$created.Data.RunId;Command='Approve';ApprovedChangeDigest=''},
  @{Action='DeploymentPoll';RunId=$created.Data.RunId;ReconciliationIntentId='bad-reference'}
 )){
  $rejected=Invoke-FixtureWorker $invalid
  Assert-Check (-not $rejected.Ok -and -not $rejected.OutcomeUnknown -and $rejected.Phase -ceq 'BeforeDispatch' -and $rejected.Code -in @('InvalidRequest','SessionBindingMismatch') -and $rejected.TechnicalId -and $rejected.NextAction) 'invalid reference is rejected by real Worker preflight without unknown outcome'
 }
 $blocked=Invoke-FixtureWorker @{Action='Session';SessionAction='Disconnect'}
 Assert-Check (-not $blocked.Ok -and $blocked.Message -match '禁止') 'isolation refuses actual session operation before dispatch'
 $after=@(Get-Process -Name 'sing-box','NinjaTrader' -ErrorAction SilentlyContinue|ForEach-Object {$_.Id}|Sort-Object)
 Assert-Check (($before -join ',') -ceq ($after -join ',')) 'production channel and trading process unchanged'
 [pscustomobject]@{Ok=$true;CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkChanged=$false;DataRoot='temporary isolated fixture'}|ConvertTo-Json -Depth 5
}finally{
 $absolute=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not ($absolute+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
