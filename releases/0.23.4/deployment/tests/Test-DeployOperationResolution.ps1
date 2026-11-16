#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$BackendEvidence,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -Force -DisableNameChecking
function Await-Resolution {param($Ref)$deadline=[DateTimeOffset]::UtcNow.AddSeconds(30);do{$p=Get-TCDeploySession $Ref;if($p.Status -notin @('Running','Connecting')){return $p};Start-Sleep -Milliseconds 100}while([DateTimeOffset]::UtcNow -lt $deadline);throw 'Loopback response timed out'}
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-resolution-host-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $testRoot
$meta=Join-Path $testRoot 'fixture.json';$fixture=Join-Path $PSScriptRoot 'loopback_ssh_fixture.py';$python=$null;$ref=$null
try{
 $python=Start-Process -FilePath (Get-Command python.exe).Source -ArgumentList ('"'+$fixture+'" "'+$meta+'" none "'+[IO.Path]::GetFullPath($BackendEvidence)+'"') -WindowStyle Hidden -PassThru
 $deadline=[DateTimeOffset]::UtcNow.AddSeconds(15);while(-not [IO.File]::Exists($meta)){if([DateTimeOffset]::UtcNow -gt $deadline){throw 'Loopback SSH did not start'};Start-Sleep -Milliseconds 100}
 $target=Get-Content -LiteralPath $meta -Raw -Encoding UTF8|ConvertFrom-Json
 $session=Start-TCDeploySession -Root (Join-Path $testRoot 'state') -RunId ([guid]::NewGuid().ToString());$ref=$session.SessionRef
 $secret=ConvertTo-SecureString 'TC_Isolated_Fixture_Only_91!' -AsPlainText -Force
 $null=Set-TCDeployCredential $ref @{Host='127.0.0.1';Port=$target.Port;User='root'} @{Kind='Password';Password=$secret} $target.Fingerprint
 $state=Await-Resolution $ref;if($state.Status -cne 'Ready'){throw ('Loopback authentication failed '+$state.Code)}
 $evidence=Get-Content -LiteralPath $BackendEvidence -Raw -Encoding UTF8|ConvertFrom-Json
 foreach($case in $evidence.Cases){
  $inputData=@{Operation=$case.Operation;IntentId=$case.IntentId;OriginalInput=$case.Input;OriginalFailureCode=$case.Reply.Data.Code}
  if($case.Reply.Data.PSObject.Properties['TransactionId']){$inputData.TransactionId=$case.Reply.Data.TransactionId}
  $accepted=Invoke-TCDeployOperation -SessionRef $ref -Operation operation_result -Input $inputData -OperationId ([guid]::NewGuid().ToString())
  if($accepted.Status -cne 'Running'){throw ('Result query rejected '+$accepted.Code)}
  $state=Await-Resolution $ref
  if($state.Status -cne 'Completed' -or $state.Data.Outcome -cne $case.ExpectedOutcome){throw ('Result contract failed '+$case.Case+': '+$state.Code)}
  $case.ResolutionReply.Data=$state.Data
 }
 # Host rejects unsupported TCP values before any SSH dispatch.
 $rejected=Invoke-TCDeployOperation -SessionRef $ref -Operation transport_plan -Input @{Transport=@{Type='tcp-reality';Port=1443;ServerName='www.bing.com'}}
 if($rejected.Code -cne 'UnsupportedTcpPort'){throw 'Host accepted unsupported TCP port'}
 $evidence|Add-Member NoteProperty HostContractValidated $true
 $evidence|Add-Member NoteProperty NetworkScope '127.0.0.1 SSH fixture only'
 $evidence|Add-Member NoteProperty HostSHA256 (Get-FileHash -LiteralPath (Join-Path $PackageRoot 'deployment/TradeChannelDeployHost.exe')).Hash
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($evidence|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($true))
 [pscustomobject]@{Passed=$true;Cases=$evidence.Cases.Count;HostContractValidated=$true;UnsupportedPortRejected=$true;NetworkScope='127.0.0.1 only'}|ConvertTo-Json
}finally{
 if($ref){try{$null=Stop-TCDeploySession $ref -Cancel;$null=Stop-TCDeploySession $ref}catch{}}
 if($python){if(-not $python.HasExited){$python.Kill()};$python.Dispose()}
 $full=[IO.Path]::GetFullPath($testRoot);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-resolution-host-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
