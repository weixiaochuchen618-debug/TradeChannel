#requires -Version 5.1
# Every OS, signature, download and installer-execution boundary is mocked.
# Only disposable local package fixtures/directories are written.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'InstallerSetup.psm1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('TC-Installer-'+[guid]::NewGuid().ToString('N'))
try{
 $result=& $module {
  param($FixtureRoot)
  $script:Checks=0;$script:Launches=0;$script:Downloads=0
  $script:Context=[pscustomobject]@{IsServer=$true;Build=20348;Is64Bit=$true;Elevated=$true}
  $script:Existing=$false;$script:AfterInstall=$true;$script:Finished=$false;$script:Signature='Valid';$script:Signer='O=WireGuard LLC';$script:Exit=0;$script:DownloadFailure=$false
  $package=Join-Path $FixtureRoot 'package';$assets=Join-Path $package 'assets';$null=[IO.Directory]::CreateDirectory($assets)
  $binary=Join-Path $assets 'wireguard-installer.exe';[IO.File]::WriteAllText($binary,'inert fixture, never executed')
  $hash=(Get-FileHash -LiteralPath $binary).Hash;$manifest=Join-Path $package 'package.sha256';[IO.File]::WriteAllText($manifest,$hash+'|assets\wireguard-installer.exe')
  $runRoot=Join-Path $FixtureRoot 'state'
  function script:Assert-Install {param([bool]$Value,[string]$Label)if(-not $Value){throw ('Installer regression: '+$Label)};$script:Checks++}
  function script:Reject-Install {param([scriptblock]$Action,[string]$Label)$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-Install $failed $Label}
  function script:Get-TCInstallerContext {$script:Context}
  function script:Get-TCInstalledWireGuard {if($script:Finished){$script:AfterInstall}else{$script:Existing}}
  function script:Get-AuthenticodeSignature {param($LiteralPath,$ErrorAction)[pscustomobject]@{Status=$script:Signature;SignerCertificate=[pscustomobject]@{Subject=$script:Signer}}}
  function script:Receive-TCOfficialInstaller {param($Destination)$script:Downloads++;if($script:DownloadFailure){throw 'injected download failure'};[IO.File]::WriteAllText($Destination,'inert official fixture')}
  function script:Invoke-TCWireGuardBootstrap {param($Path)$script:Launches++;$script:Finished=$true;$script:Exit}
  function script:Reset-Install {$script:Launches=0;$script:Downloads=0;$script:Existing=$false;$script:Finished=$false;$script:AfterInstall=$true;$script:Exit=0;$script:Signature='Valid';$script:Signer='O=WireGuard LLC';$script:DownloadFailure=$false}
  $script:Context.IsServer=$false
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'client cannot install server dependency'
  Assert-Install ($script:Launches -eq 0 -and $script:Downloads -eq 0 -and -not(Test-Path $runRoot)) 'client rejection has no side effects'
  $script:Context.IsServer=$true;$script:Context.Build=17763
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'unsupported server rejected'
  $script:Context.Build=20348;$script:Context.Elevated=$false
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'non-admin rejected'
  $script:Context.Elevated=$true;$script:Context.Is64Bit=$false
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'wrong architecture rejected';$script:Context.Is64Bit=$true
  $script:Existing=$true;$data=Invoke-TCWireGuardInstall -Source Online -PackageRoot $package -Root $runRoot
  Assert-Install ($data.Installed -and $data.AlreadyInstalled -and $script:Launches -eq 0 -and $script:Downloads -eq 0) 'existing install untouched even for online source'
  Reset-Install;$data=Invoke-TCWireGuardInstall -Source Bundled -PackageRoot $package -Root $runRoot
  Assert-Install ($data.Installed -and $data.Source -eq 'Bundled' -and $script:Launches -eq 1 -and $script:Downloads -eq 0) 'bundled starts one verified local bootstrap'
  Assert-Install ($data.BootstrapNeedsNetwork -and -not $data.RebootRequired) 'bundle truthfully reports network bootstrap'
  Assert-Install ((Get-Acl -LiteralPath $data.InstallerPath).AreAccessRulesProtected -eq $false) 'installer inherits restricted workdir ACL'
  Reset-Install;$data=Invoke-TCWireGuardInstall -Source Online -PackageRoot $package -Root $runRoot
  Assert-Install ($data.Installed -and $script:Downloads -eq 1 -and $script:Launches -eq 1) 'online download followed by one install'
  Reset-Install;[IO.File]::WriteAllText($binary,'tampered')
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'modified bundle rejected'
  Assert-Install ($script:Launches -eq 0 -and $script:Downloads -eq 0) 'modified bundle never executed'
  [IO.File]::WriteAllText($binary,'inert fixture, never executed')
  Reset-Install;$script:Signature='HashMismatch'
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'invalid package signature rejected'
  Assert-Install ($script:Launches -eq 0) 'invalid signature never executed'
  Reset-Install;$script:Signer='CN=WireGuard LLC, O=Someone Else'
  Reject-Install {Invoke-TCWireGuardInstall -Source Online -PackageRoot $package -Root $runRoot} 'wrong publisher rejected after download'
  Assert-Install ($script:Downloads -eq 1 -and $script:Launches -eq 0) 'wrong publisher never executes'
  Reset-Install;$script:DownloadFailure=$true
  Reject-Install {Invoke-TCWireGuardInstall -Source Online -PackageRoot $package -Root $runRoot} 'download failure does not report success'
  Assert-Install ($script:Launches -eq 0) 'download failure never installs'
  Reset-Install;$script:Exit=1602
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'cancelled installer does not report success'
  Reset-Install;$script:Exit=1603
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'failed installer does not report success'
  Reset-Install;$script:AfterInstall=$false
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'zero exit without installed binary fails readback'
  Reset-Install;$script:Exit=3010;$script:AfterInstall=$false;$data=Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot
  Assert-Install ($data.RebootRequired -and -not $data.Installed) 'pending reboot is not incorrectly marked installed'
  Reset-Install;$script:Exit=1641;$data=Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot
  Assert-Install ($data.RebootRequired -and $data.Installed) 'reboot exit is communicated'
  Reset-Install;[IO.File]::WriteAllText($manifest,($hash+'|assets\wireguard-installer.exe'+"`n"+$hash+'|assets\wireguard-installer.exe'))
  Reject-Install {Invoke-TCWireGuardInstall -PackageRoot $package -Root $runRoot} 'duplicate installer manifest item rejected'
  Assert-Install ($script:Launches -eq 0) 'invalid manifest prevents execution'
  [pscustomobject]@{Passed=$true;Checks=$script:Checks;Scope='Isolated server/client, signed bundle, download, cancellation, readback, reboot';RealInstallations=0;RealDownloads=0;RealNetworkChanges=0}
 } $testRoot
 $result
}finally{
 if($module){Remove-Module $module.Name -Force}
 $full=[IO.Path]::GetFullPath($testRoot);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'TC-Installer-*'){throw 'Fixture cleanup path rejected'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
