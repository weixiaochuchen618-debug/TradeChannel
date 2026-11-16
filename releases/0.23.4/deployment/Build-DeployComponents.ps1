#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$lib=Join-Path $PackageRoot 'assets\lib'
foreach($build in @(@{Name='TradeChannelDeployHost';Target='exe';Reference='Renci.SshNet.dll'},@{Name='TradeChannelPairCrypto';Target='library';Reference='jose-jwt.dll'})){
    $source=Join-Path $PSScriptRoot ($build.Name+'.cs');$out=Join-Path $PSScriptRoot ($build.Name+$(if($build.Target -eq 'exe'){'.exe'}else{'.dll'}))
    & $compiler /nologo ('/target:'+$build.Target) /platform:x64 ('/out:'+$out) /reference:System.Web.Extensions.dll ('/reference:'+(Join-Path $lib $build.Reference)) $source
    if($LASTEXITCODE -ne 0){throw 'Deployment component build failed.'}
}
