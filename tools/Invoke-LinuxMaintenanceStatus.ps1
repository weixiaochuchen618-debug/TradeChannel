#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$product=Join-Path (Split-Path $PSScriptRoot -Parent) 'product'
$module=Import-Module (Join-Path $product 'LinuxServerSetup.psm1') -Force -PassThru -DisableNameChecking
$result=& $module {
 $connection=@{Host='203.0.113.98';Port=22;User='root'}
 $known=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\linux-jobs\known_hosts'
 $transport=Get-TCLinuxTransportPlan $connection $known
 $backend=Get-TCLinuxBackend
 $payload=@{SchemaVersion=1;Source=$backend.Source;SourceSHA256=$backend.SourceSHA256;Action='status';Input=@{}}
 $native=Invoke-TCLinuxNativeTransport $transport ($payload|ConvertTo-Json -Depth 24 -Compress) ([DateTimeOffset]::UtcNow.AddMinutes(5))
 $reply=ConvertFrom-TCLinuxEnvelope $native.Output 'Status'
 Assert-TCLinuxPublicData $reply
 [pscustomobject]@{At=[DateTime]::UtcNow.ToString('o');ExitCode=$native.ExitCode;Response=$reply}
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($result|ConvertTo-Json -Depth 18),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json -Depth 8
if($result.ExitCode -ne 0 -or -not $result.Response.Ok){exit 1}
