#requires -Version 5.1
param([string]$PackageDirectory=(Split-Path $PSScriptRoot -Parent),[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0;$hostProcess=$null;$wake=$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
$jobs=Join-Path $root 'Product\jobs';$null=[IO.Directory]::CreateDirectory($jobs)
$readerId=[guid]::NewGuid().ToString('N');$inbox=Join-Path $jobs ('read-'+$readerId+'.inbox.json')
$wake=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::AutoReset,('Local\TradeChannel.Read.'+$readerId))
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
function StartReader {param([long]$Ticks)
 $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PackageDirectory 'runtime\Read-TradeChannel.ps1')+'"'),'-InboxPath',('"'+$inbox+'"'),'-OwnerProcessId',$PID,'-OwnerStartedTicks',$Ticks,'-IsolatedTest','-TestRoot',('"'+$root+'"'))
 Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -PassThru -WindowStyle Hidden
}
function ReadFixture {param([string]$Action='Overview',[int]$Generation=1,[switch]$Legacy)
 $id=[guid]::NewGuid().ToString('N');$requestPath=Join-Path $jobs ($id+'.request.json');$resultPath=Join-Path $jobs ($id+'.result.json')
 $request=@{Action=$Action;RequestId=$id;PageGeneration=$Generation}
 if(-not $Legacy){$request.UiRequestId=[guid]::NewGuid().ToString('N')}
 [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($true))
 $temp=$inbox+'.partial';[IO.File]::WriteAllText($temp,(@{ReaderId=$readerId;RequestId=$id}|ConvertTo-Json -Compress))
 if([IO.File]::Exists($inbox)){[IO.File]::Replace($temp,$inbox,[NullString]::Value)}else{[IO.File]::Move($temp,$inbox)};$null=$wake.Set()
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not [IO.File]::Exists($resultPath) -and -not $hostProcess.HasExited -and $clock.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 20}
 Check ([IO.File]::Exists($resultPath)) 'reader returns a bounded atomic result'
 $result=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
 Check ($result.RequestId -ceq $id -and $result.Action -ceq $Action -and [int]$result.PageGeneration -eq $Generation) 'each result binds the original request and page'
 if(-not $Legacy){Check ($result.UiRequestId -ceq $request.UiRequestId) 'read result carries the original UI lifecycle identity'}
 return $result
}
try{
 $owner=[Diagnostics.Process]::GetCurrentProcess();$ticks=$owner.StartTime.ToUniversalTime().Ticks;$owner.Dispose()
 $hostProcess=StartReader $ticks
 $first=ReadFixture -Legacy;Check ($first.Ok -and $first.Data.StateKey -eq 'Unconfigured') ('first isolated request reads the real module without production access: '+$first.Message+' / '+$first.Data.StateKey)
 [IO.File]::WriteAllText((Join-Path $root 'ui-preferences.json'),'{"Mode":"Trading","Daily":"Provider","Agents":"Daily"}',[Text.UTF8Encoding]::new($true))
 $second=ReadFixture -Generation 2
 Check ($second.Ok -and $second.Data.DesiredDaily -eq 'Provider') 'reused module rereads current preferences instead of returning stale state'
 Check ($first.ReadMetrics.ProcessId -eq $second.ReadMetrics.ProcessId -and $second.ReadMetrics.ReusedProcess) 'sequential reads reuse exactly one owned process'
 $denied=ReadFixture Session
 Check (-not $denied.Ok -and -not $denied.OutcomeUnknown) 'mutation is rejected before dispatch by read-only contract'
 Check (-not [IO.File]::Exists((Join-Path $root 'deployment.json'))) 'rejected mutation creates no deployment'
 $next=ReadFixture -Generation 3;Check $next.Ok 'reader remains usable after a rejected request'
 [IO.File]::WriteAllText(($inbox+'.stop'),'stop');$null=$wake.Set()
 Check ($hostProcess.WaitForExit(5000) -and $hostProcess.ExitCode -eq 0) 'console release stops the reader without killing a mutation'
 Check (-not [IO.File]::Exists($inbox) -and -not [IO.File]::Exists($inbox+'.stop')) 'normal reader shutdown removes its mailbox'
 $hostProcess.Dispose();$hostProcess=StartReader ($ticks+1)
 Check ($hostProcess.WaitForExit(5000) -and $hostProcess.ExitCode -ne 0) 'reused owner PID with a different birth is refused'
 $hostProcess.Dispose();$hostProcess=StartReader $ticks
 $afterRestart=ReadFixture -Generation 4
 Check $afterRestart.Ok 'a new owned reader starts after the previous process ended'
 $hostProcess.Kill();Check ($hostProcess.WaitForExit(3000)) 'only the retained fixture reader process is terminated'
 $script:JobRoot=$jobs
 . (Join-Path $PackageDirectory 'ui\BackgroundJobs.ps1')
 $script:UiReadWorker=@{Id=$readerId;Inbox=$inbox;Wake=$wake;Process=$hostProcess}
 StopUiReadWorker
 $hostProcess=$null;$wake=$null
 Check (-not $script:UiReadWorker -and -not [IO.File]::Exists($inbox)) 'window cleanup removes the exact mailbox after an owned reader was terminated'
 $result=[pscustomobject]@{Passed=$true;Checks=$checks;ProductionAccess=$false;NetworkChanges=0;Cold=$first.ReadMetrics;Warm=$second.ReadMetrics}
 if($ReportPath){$result|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Depth 4
}finally{
 if($hostProcess){try{if(-not $hostProcess.HasExited){$hostProcess.Kill();$null=$hostProcess.WaitForExit(3000)}}finally{$hostProcess.Dispose()}}
 if($wake){$wake.Dispose()}
 $full=[IO.Path]::GetFullPath($root)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
