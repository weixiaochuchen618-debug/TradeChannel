#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-receipt-'+[guid]::NewGuid().ToString('N'))
$run=[guid]::NewGuid().ToString('D');$checks=New-Object 'Collections.Generic.List[string]';$failure='';$ref=$null;$handle=$null;$receipt=$null
$module=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
try{
 # This executor is deliberately started without Connection or Credential.
 # It can only service local protocol/receipt requests; no SSH is attempted.
 $started=Start-TCDeploySession -Root $root -RunId $run
 $ref=$started.SessionRef
 Check ($started.Status -ceq 'AwaitingCredential' -and $ref.Root -ceq (Join-Path $root ('deployments\hosts\'+$ref.InstanceId))) 'Actual packaged executor starts under the unique owned fixture root with no login'
 $invalid=& $module {param($r)Invoke-TCDeployPipe $r @{Command='Authenticate';AccessContext=@{Password='FAKE_DIAGNOSTIC_REJECT_ONLY'}}} $ref
 Check (-not $invalid.Ok -and $invalid.Code -ceq 'InvalidRequest') 'Rebuilt host independently rejects non-whitelisted diagnostic input before authentication'
 $poll=Get-TCDeploySession $ref
 Check (-not $poll.HasSession -and $poll.Status -ceq 'AwaitingCredential' -and @($poll.Events|Where-Object Code -eq 'AuthenticationStarted').Count -eq 0) 'Rejected metadata does not advance authentication or create a remote connection'
 foreach($i in 1..140){$poll=Stop-TCDeploySession $ref -Cancel}
 Check ($poll.Events.Count -eq 128 -and $poll.Events[0].Sequence -gt 1 -and $poll.Events[-1].Sequence -gt $poll.Events[0].Sequence) 'Actual host caps durable event history at the most recent 128 ordered events'
 $receiptPath=Join-Path $ref.Root 'receipt.json'
 $handle=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 try{$poll=Stop-TCDeploySession $ref -Cancel}finally{$handle.Dispose();$handle=$null}
 Check ($poll.DiagnosticPersistenceFailed -eq $true -and -not $poll.HasSession -and $poll.Status -ceq 'Failed') 'A real receipt replacement failure is visible in the live snapshot and never becomes successful authentication'
 $closed=Stop-TCDeploySession $ref
 Check $closed.Closed 'Actual executor acknowledges an ordinary Close after the diagnostic write fault'
 $process=Get-Process -Id $ref.ProcessId -ErrorAction SilentlyContinue
 if($process){try{Check ($process.Path -ceq (Join-Path $PackageRoot 'deployment\TradeChannelDeployHost.exe') -and [string]$process.StartTime.ToUniversalTime().Ticks -ceq [string]$ref.StartTimeUtcTicks) 'Wait is bound to the exact packaged fixture process';Check ($process.WaitForExit(5000)) 'Normal close has a bounded process exit'}finally{$process.Dispose()}}
 $text=[IO.File]::ReadAllText($receiptPath);$receipt=$text|ConvertFrom-Json
 Check ($receipt.Status -ceq 'Closed' -and $receipt.DiagnosticPersistenceFailed -eq $true -and $receipt.Events.Count -eq 128 -and $receipt.InstanceId -ceq $ref.InstanceId -and $receipt.RunId -ceq $run) 'Final durable receipt preserves the diagnostic fault and bounded session-bound history'
 Check (-not $text.Contains('FAKE_DIAGNOSTIC_REJECT_ONLY') -and @(Get-ChildItem -LiteralPath $ref.Root -Force -Filter '.receipt-*').Count -eq 0) 'Rejected input is absent and failed atomic writes leave no temporary receipt files'
}catch{$failure=$_.Exception.Message}
finally{
 if($handle){$handle.Dispose()}
 if($ref){try{$null=Stop-TCDeploySession $ref -TotalTimeoutMs 200}catch{}}
 $result=[pscustomobject]@{Passed=(-not $failure);Checks=$checks.ToArray();CheckCount=$checks.Count;Failure=$failure;PackageRoot=$PackageRoot;HostSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'deployment\TradeChannelDeployHost.exe')).Hash;RunId=$run;SessionRef=$ref;EventCount=$(if($receipt){$receipt.Events.Count}else{0});DiagnosticPersistenceFailed=$(if($receipt){$receipt.DiagnosticPersistenceFailed}else{$null});SshConnections=0;CredentialsProvided=0;Scope='one exact packaged executor, local named pipe and temporary receipt only'}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))}
 if(-not $failure -and [IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($root) -cmatch '^tc-receipt-[a-f0-9]{32}$'){Remove-Item -LiteralPath $root -Recurse -Force}
}
$result|ConvertTo-Json -Depth 7
if($failure){exit 1}
