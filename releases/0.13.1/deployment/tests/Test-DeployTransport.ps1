#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent};$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Await-Deploy {param($Ref)$until=[DateTime]::UtcNow.AddSeconds(30);do{$state=Get-TCDeploySession $Ref;if($state.Status -notin @('Running','Connecting')){return $state};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until);throw 'Fixture operation timed out.'}
Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -Force -DisableNameChecking
$testRoot=Join-Path $PackageRoot ('deployment\test-runs\transport-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
$meta=Join-Path $testRoot 'fixture.json';$fixture=Join-Path $PSScriptRoot 'loopback_ssh_fixture.py';$python=Start-Process -FilePath 'python.exe' -ArgumentList ('"'+$fixture+'" "'+$meta+'"') -WindowStyle Hidden -PassThru
$ref=$null
try{
    $until=[DateTime]::UtcNow.AddSeconds(15);while(-not (Test-Path -LiteralPath $meta)){if([DateTime]::UtcNow -gt $until){throw 'SSH fixture failed.'};Start-Sleep -Milliseconds 100}
    $target=Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json;$connection=@{Host='127.0.0.1';Port=$target.Port;User='root'};$secret=ConvertTo-SecureString 'TC_Isolated_Fixture_Only_91!' -AsPlainText -Force
    $session=Start-TCDeploySession -Root (Join-Path $testRoot 'state') -RunId ([guid]::NewGuid().ToString());$ref=$session.SessionRef
    $null=Set-TCDeployCredential $ref $connection @{Kind='Password';Password=$secret};$state=Await-Deploy $ref
    Assert-Check ($state.Code -ceq 'HostTrustRequired' -and $state.ObservedFingerprint -ceq $target.Fingerprint -and -not $state.HasSession) 'First trust never authenticates unknown host'
    $wrong='SHA256:'+('A'*43);$null=Set-TCDeployCredential $ref $connection @{Kind='Password';Password=$secret} $wrong;$state=Await-Deploy $ref
    Assert-Check ($state.Code -ceq 'HostKeyChanged' -and -not $state.HasSession) 'Changed host identity blocked'
    $null=Set-TCDeployCredential $ref $connection @{Kind='Password';Password=$secret} $target.Fingerprint;$state=Await-Deploy $ref
    Assert-Check ($state.Status -ceq 'Ready' -and $state.HasSession) 'Explicit trusted authentication loads Framework dependencies'
    foreach($operation in @('Inspect','Status')){
        $started=Invoke-TCDeployOperation $ref $operation @{};Assert-Check ($started.Status -ceq 'Running') ($operation+' asynchronous starts')
        $state=Await-Deploy $ref;Assert-Check ($state.Status -ceq 'Completed' -and $state.Data.StdinHashVerified) ($operation+' real SSH stdin JSON and source hash: '+$state.Status+'/'+$state.Code)
    }
    Assert-Check ($state.Data.SessionStats.AuthenticationCount -eq 1 -and $state.Data.SessionStats.CommandCount -eq 2) 'Two phases reuse one authenticated SSH session'
    $operationId=[guid]::NewGuid().ToString();$started=Invoke-TCDeployOperation -SessionRef $ref -Operation capabilities -Input @{} -OperationId $operationId;$state=Await-Deploy $ref
    $repeated=Invoke-TCDeployOperation -SessionRef $ref -Operation capabilities -Input @{} -OperationId $operationId
    Assert-Check ($state.Data.SessionStats.CommandCount -eq 3 -and $repeated.OperationId -ceq $operationId -and $repeated.Status -ceq 'Completed') 'Repeated durable operation ID returns original result without SSH redispatch'
    $rejected=Invoke-TCDeployOperation $ref 'devices' @{Command='cat /etc/shadow'}
    Assert-Check ($rejected.Code -ceq 'InvalidRequest') 'Operation field injection rejected by executor'
    $changed=@{PipeName=$ref.PipeName;RunId=[guid]::NewGuid().ToString();InstanceId=$ref.InstanceId;ProcessId=$ref.ProcessId;StartTimeUtcTicks=$ref.StartTimeUtcTicks;Root=$ref.Root}
    $module=Get-Module DeploymentTransport;$rejected=& $module {param($Ref) Invoke-TCDeployPipe $Ref @{Command='Poll'}} $changed
    Assert-Check ($rejected.Code -ceq 'SessionMismatch') 'Pipe enforces RunId and instance binding'
    $files=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -Recurse -File)
    $leaks=@($files|Where-Object { [IO.File]::ReadAllText($_.FullName).Contains('TC_Isolated_Fixture_Only_91!') })
    Assert-Check ($leaks.Count -eq 0) 'Password absent from persisted state and events'
    $commandLine=(Get-CimInstance Win32_Process -Filter ('ProcessId='+$ref.ProcessId)).CommandLine
    Assert-Check (-not $commandLine.Contains('TC_Isolated_Fixture_Only_91!')) 'Password absent from process command line'
    $acl=Get-Acl -LiteralPath (Join-Path $ref.Root 'receipt.json');Assert-Check $acl.AreAccessRulesProtected 'Receipt has protected ACL'
    $null=Stop-TCDeploySession $ref;$ref=$null
    [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='127.0.0.1 only; no system setting changes'}|ConvertTo-Json -Depth 8
}finally{
    if($ref){try{$null=Stop-TCDeploySession $ref -Cancel;$null=Stop-TCDeploySession $ref}catch{}}
    if(-not $python.HasExited){$python.Kill()};$python.Dispose()
    $absolute=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if($absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
