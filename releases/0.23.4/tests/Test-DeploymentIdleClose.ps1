#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$module=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
$nonce=[guid]::NewGuid().ToString('N');$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-idle-close-'+$nonce)
$checks=New-Object 'Collections.Generic.List[string]';$ref=$null;$passed=$false;$failure='';$duration=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw $Name};$checks.Add($Name)}
try{
 $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.222';Port=22;User='root';IdentityFile=''} -Name 'Isolated idle close'
 $started=Start-TCDeploySession -Root $root -RunId $run.RunId
 $ref=$started.SessionRef;$run.SessionRef=$ref;$run.AttemptSessionRef=$ref;$null=& $flow {param($root,$run)Save-TCDeploymentRun $root $run} $root $run
 $observation=Get-TCDeploySession $ref
 Check ($observation.Status -ceq 'AwaitingCredential' -and -not $observation.HasSession -and -not $observation.HasMutatingOperations) 'A real shipped host is idle with no SSH login or remote operation'
 $stopwatch=[Diagnostics.Stopwatch]::StartNew()
 $result=Close-TCDeployIdleSessionsForCleanup -Root $root -Executors @(@{RunId=$run.RunId;SessionRef=$ref}) -WaitSeconds 5
 $duration=$stopwatch.ElapsedMilliseconds
 Check ($result.ClosedCount -eq 1 -and -not $result.RemoteChanges) 'The real pipe Close response is accepted by the real cleanup command'
 $process=Get-Process -Id $ref.ProcessId -ErrorAction SilentlyContinue
 Check (-not $process) 'The exact idle product host has exited without a kill'
 Check ($duration -lt 6000) 'Real identity check, pipe close and exit complete within the bounded wait'
 $ref=$null
 # A local byte stream with deliberately delayed fragments verifies that the
 # same monotonic deadline covers all reads, not one timeout per fragment.
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class TCSlowReadFixture : Stream {
 int count;
 public override IAsyncResult BeginRead(byte[] b,int o,int n,AsyncCallback cb,object s) {
  Func<int> f=()=>{Thread.Sleep(80);b[o]=1;Interlocked.Increment(ref count);return 1;};
  return f.BeginInvoke(cb,s);
 }
 public override int EndRead(IAsyncResult r){return ((Func<int>)((System.Runtime.Remoting.Messaging.AsyncResult)r).AsyncDelegate).EndInvoke(r);}
 public override bool CanRead{get{return true;}} public override bool CanWrite{get{return false;}} public override bool CanSeek{get{return false;}}
 public override long Length{get{throw new NotSupportedException();}} public override long Position{get{throw new NotSupportedException();}set{throw new NotSupportedException();}}
 public override int Read(byte[] b,int o,int n){throw new NotSupportedException();} public override void Flush(){}
 public override long Seek(long o,SeekOrigin s){throw new NotSupportedException();} public override void SetLength(long n){throw new NotSupportedException();}
 public override void Write(byte[] b,int o,int n){throw new NotSupportedException();}
}
'@
 $stream=New-Object TCSlowReadFixture;$watch=[Diagnostics.Stopwatch]::StartNew();$timedOut=$false
 try{& $module {param($stream,$watch)Read-TCDeployPipeBytes $stream 8 1000 $watch 130} $stream $watch|Out-Null}catch{$timedOut=$_.Exception.Message -match '\[TC:PipeTimeout\]'}finally{$stream.Dispose()}
 Check ($timedOut -and $watch.ElapsedMilliseconds -lt 1000) 'Slow response fragments cannot restart the total response deadline'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 if($ref){try{$null=Stop-TCDeploySession $ref -TotalTimeoutMs 1000}catch{}}
 $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFileName($full)-cne ('tc-idle-close-'+$nonce)){throw 'Fixture cleanup ownership mismatch'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
 $report=[pscustomobject]@{Passed=$passed;Checks=@($checks);Failure=$failure;RealCloseMilliseconds=$duration;RemoteCommands=0;PackageRoot=$PackageRoot;TransportSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'DeploymentTransport.psm1')).Hash}
 [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true));$report|Select-Object Passed,Failure,RealCloseMilliseconds,RemoteCommands|ConvertTo-Json
}
