#requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,[Parameter(Mandatory=$true)][string]$SourceDirectory,[Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$StageOnly)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2.0
function Assert-BuildPath {param([string]$Path)
 if(-not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')){throw 'Build paths must be absolute local disk paths.'}
 $full=[IO.Path]::GetFullPath($Path);if($full.Length -gt 3){$full=$full.TrimEnd('\')};$cursor=$full
 while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Build paths cannot traverse reparse points.'}};$parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent};return $full
}
function Remove-BuildOwnedPath {param([string]$Path,[string]$Parent)
 $full=Assert-BuildPath $Path;$boundary=(Assert-BuildPath $Parent).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^\.tc-build-[0-9a-f]{32}$'){throw 'Refusing cleanup outside owned build staging.'}
 if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
function Write-BuildText {param([string]$Path,[string]$Value,[switch]$Bom) [IO.File]::WriteAllText($Path,$Value,(New-Object Text.UTF8Encoding([bool]$Bom))) }
$source=Assert-BuildPath (Resolve-Path -LiteralPath $SourceDirectory).Path;$dist=Assert-BuildPath ([IO.Path]::GetFullPath($OutputDirectory))
if($dist -ieq $source -or $dist.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Output must be outside the source release directory.'}
$versionPath=Join-Path $source 'version.json';if(-not [IO.File]::Exists($versionPath)){throw 'Authoritative version.json is required; no historical version default is used.'}
$versionData=[IO.File]::ReadAllText($versionPath)|ConvertFrom-Json
if($versionData.Version -cnotmatch '^\d+\.\d+\.\d+$' -or $versionData.Preview -ne $true){throw 'version.json must identify a semantic preview release.'}
if($Version -and $Version -cne $versionData.Version){throw 'Requested version differs from version.json.'};$Version=[string]$versionData.Version
if([version]$Version -lt [version]'0.10.0'){throw 'This builder requires the 0.10.0 deployment package contract.'}
$compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not [IO.File]::Exists($compiler)){throw '.NET Framework x64 compiler is required.'}
$framework=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
if([int]$framework.Release -lt 528040){throw '.NET Framework 4.8 or later is required.'}

# Explicit allowlist; source-tree recursion never selects package content.
$top=@('TradeChannel.ps1','Worker.ps1','Version.psm1','version.json','RuntimeBridge.psm1','NodeStore.psm1','NodeOperations.ps1','ServerSetup.psm1','Startup.psm1','InstallerSetup.psm1','InstallationDiscovery.psm1','Create-DesktopShortcut.ps1','ProviderBridge.psm1','ProviderManagement.ps1','ManagementStore.psm1','Maintenance.psm1','Diagnostics.psm1','ConfigurationRecovery.psm1','RuntimeObservability.psm1','WindowPreferences.psm1','AutoTransport.psm1','LineStore.psm1','ConnectionTransactions.psm1','ConnectionBundle.psm1','LineRecovery.psm1','LinuxServerSetup.psm1','LinuxJobManagement.ps1','DeploymentStore.psm1','DeploymentFlow.psm1','ServerRegistry.psm1','DeploymentTransport.psm1','DeploymentPairing.psm1','DeploymentDependencies.psm1','CandidateProbe.psm1','ProtocolSelection.psm1','ProtocolComparison.psm1','ProbePath.psm1','ProbePath.Native.cs','ProbePath.Etw.cs','Launcher.cs','app.manifest','Start-TradeChannel.cmd','启动TradeChannel.cmd','创建桌面入口.cmd','Build-Launcher.cmd','编译TradeChannel.exe.cmd','Sync-Binaries.cmd','从旧版本同步二进制组件.cmd','README.md','更新说明.md','新手部署指南.md','Linux部署指南.md','服务商接入.md','快速部署.html','THIRD-PARTY-NOTICES.md')
$ui=@('Shell.xaml','Pages.ps1','SetupPages.ps1','LinuxPages.ps1','ManagementPages.ps1','RuntimePages.ps1','TransportPages.ps1','DeploymentPages.ps1','ServerPages.ps1','PairingPages.ps1','SelfTest.ps1','Test-010UI.ps1','Test-011UI.ps1','Test-012UI.ps1','Test-0110UI.ps1','Test-0120UI.ps1','Test-013UI.ps1','ConnectionProfilePages.ps1','AutomaticTransportPages.ps1','WindowLifecycle.ps1','Test-092UI.ps1','Test-093UI.ps1','Test-LinuxUI.ps1')|ForEach-Object {'ui\'+$_}
$runtime=@('Run-TradeChannel.ps1','Invoke-TradeChannel.ps1','TradeChannel.Provider.ps1','TradeChannel.Providers.ps1','TradeChannel.ProviderSetup.ps1','TradeChannel.Proxy.ps1','TradeChannel.State.ps1','Set-TradeChannelDaily.ps1','TradeChannel.Agents.ps1','Set-TradeChannelAgents.ps1','Set-TradeChannelMode.ps1','Set-TradeChannelExit.ps1','Test-SelectedTradeExit.ps1','TradeChannelGuard.cs')|ForEach-Object {'runtime\'+$_}
$runtime+=@('runtime\TradeChannel.Diagnostics.ps1')
$linux=@('tradechannel_linux.py','transport_support.py','management_support.py','Invoke-LinuxConsole.ps1')|ForEach-Object {'linux\'+$_}
$assets=@('sing-box.exe','wg.exe','wireguard-installer.exe','TradeChannel.ico','TradeChannel.png','GPL-2.0.txt','GPL-3.0.txt','sing-box.LICENSE.txt')|ForEach-Object {'assets\'+$_}
$deploy=@('TradeChannelDeployHost.cs','TradeChannelPairCrypto.cs','Build-DeployComponents.ps1','BuildPreviewCore.ps1','dependencies.lock.json','THIRD-PARTY-NOTICES.md','ArchiveVerifier.cs')|ForEach-Object {'deployment\'+$_}
$tools=@('tools\Build-TradeChannelPreview.ps1','tools\Reset-TradeChannelState.ps1')
$top+=@('UiState.psm1','BrandNative.cs','DeploymentDecision.psm1')
$top+=@('OperationHistory.psm1','DraftDisposition.psm1')
$ui+=@('ui\Branding.ps1','ui\FlowEvidence.ps1','ui\Test-014UI.ps1','ui\Test-0142UI.ps1')
$ui+=@('ui\OperationHistoryPages.ps1','ui\DeploymentIdentityPages.ps1','ui\Test-015UI.ps1','ui\Test-015PairUI.ps1','ui\Test-PairingFixture.ps1')
$ui+=@('ui\NavigationContext.ps1','ui\DeploymentCenterPages.ps1','ui\Test-016UI.ps1','ui\Test-016MaintenanceUI.ps1')
$assets+=@('assets\TradeChannel.svg','assets\TradeChannel-small.png')
foreach($state in @('connected','busy','idle','fault')){foreach($extension in @('ico','png')){$assets+=('assets\TradeChannel-'+$state+'.'+$extension)}}
$tools+=@('tools\Build-SpiderIcons.py')
$allow=@($top+$ui+$runtime+$linux+$assets+$deploy+$tools|Select-Object -Unique)
$lock=[IO.File]::ReadAllText((Join-Path $source 'deployment\dependencies.lock.json'))|ConvertFrom-Json
if($lock.SchemaVersion -ne 1 -or @($lock.Dependencies).Count -ne 13){throw 'Dependency lock must contain all 13 Framework assets.'}
foreach($dependency in $lock.Dependencies){if($dependency.File -cnotmatch '^assets/lib/[A-Za-z0-9.-]+\.dll$'){throw 'Invalid dependency path.'};$allow+=($dependency.File.Replace('/','\'))}
$licenseRoot=Join-Path $source 'assets\lib\licenses';if(-not [IO.Directory]::Exists($licenseRoot)){throw 'Vendor licenses are missing.'}
foreach($license in @(Get-ChildItem -LiteralPath $licenseRoot -File)){if($license.Name -cnotmatch '^[A-Za-z0-9_.-]+\.txt$'){throw 'Unexpected vendor license file.'};$allow+=('assets\lib\licenses\'+$license.Name)}
foreach($relative in $allow){$requiredPath=Assert-BuildPath (Join-Path $source $relative);if(-not [IO.File]::Exists($requiredPath)){throw ('Missing required package file: '+$relative)}}
$expected=@{'sing-box.exe'='7BBEF1DEA9189EE12799AE834EA4B4658355DA25C47A21AD8804904C0CCD9410';'wg.exe'='E1F8CB5C9E30A878FA7EB0B2251BB4EB4946E669063E6FD5E4383CA4BD0DCAF2';'wireguard-installer.exe'='6962B6F42BC442E2A822608817222C93C7EF03F34476337608B170D4D76FD5F3'}
foreach($name in $expected.Keys){if((Get-FileHash -LiteralPath (Join-Path $source ('assets\'+$name))).Hash -cne $expected[$name]){throw ('Unexpected helper hash: '+$name)}}
$signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $source 'assets\wireguard-installer.exe')
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=WireGuard LLC(?:,|$)'){throw 'WireGuard installer signature verification failed.'}
foreach($dependency in $lock.Dependencies){if((Get-FileHash -LiteralPath (Join-Path $source $dependency.File)).Hash -cne $dependency.SHA256){throw ('Vendor dependency hash mismatch: '+$dependency.Package)}}

$null=[IO.Directory]::CreateDirectory($dist);$staging=Join-Path $dist ('.tc-build-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($staging)
$partial=$null;$sourceHashes=@();$rows=@();$scanCount=0
try{
 foreach($relative in $allow){$inputFile=Join-Path $source $relative;$destination=Join-Path $staging $relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination));$before=(Get-FileHash -LiteralPath $inputFile).Hash;Copy-Item -LiteralPath $inputFile -Destination $destination;if((Get-FileHash -LiteralPath $destination).Hash -cne $before -or (Get-FileHash -LiteralPath $inputFile).Hash -cne $before){throw ('Source changed during build snapshot: '+$relative)};$sourceHashes+=@{Path=$relative.Replace('\','/');SHA256=$before}}
 foreach($name in $expected.Keys){if((Get-FileHash -LiteralPath (Join-Path $staging ('assets\'+$name))).Hash -cne $expected[$name]){throw ('Staged immutable helper hash mismatch: '+$name)}}
 foreach($dependency in $lock.Dependencies){if((Get-FileHash -LiteralPath (Join-Path $staging $dependency.File)).Hash -cne $dependency.SHA256){throw ('Staged dependency hash mismatch: '+$dependency.Package)}}
 # Canonicalization modifies only this build's staging directory.
 foreach($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File|Where-Object {$_.Extension -in @('.ps1','.psm1')})){
  Write-BuildText $file.FullName ([IO.File]::ReadAllText($file.FullName)) -Bom
  $tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw ('PowerShell parse failed: '+$file.Name)}
 }
 foreach($file in @(Get-ChildItem -LiteralPath $staging -File -Filter '*.cmd')){Write-BuildText $file.FullName ([regex]::Replace([IO.File]::ReadAllText($file.FullName),'(?<=TradeChannel )0\.\d+\.\d+',$Version))}
 [xml]$app=[IO.File]::ReadAllText((Join-Path $staging 'app.manifest'));$app.assembly.assemblyIdentity.version=$Version+'.0';$app.Save((Join-Path $staging 'app.manifest'))
 $assemblyInfo=Join-Path $staging 'deployment\TradeChannel.AssemblyInfo.cs'
 Write-BuildText $assemblyInfo ('[assembly:System.Reflection.AssemblyVersion("'+$Version+'.0")]'+"`r`n"+'[assembly:System.Reflection.AssemblyFileVersion("'+$Version+'.0")]'+"`r`n"+'[assembly:System.Reflection.AssemblyInformationalVersion("'+$Version+'-preview")]'+"`r`n"+'[assembly:System.Reflection.AssemblyProduct("TradeChannel")]'+"`r`n"+'[assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]'+"`r`n")
 # Staged compilation avoids writing into running or historical product copies.
 & $compiler /nologo /target:winexe /platform:x64 ('/out:'+(Join-Path $staging 'TradeChannel.exe')) ('/win32manifest:'+(Join-Path $staging 'app.manifest')) ('/win32icon:'+(Join-Path $staging 'assets\TradeChannel.ico')) /reference:System.Windows.Forms.dll (Join-Path $staging 'Launcher.cs') $assemblyInfo
 if($LASTEXITCODE -ne 0){throw 'Staged launcher build failed.'}
 foreach($component in @(@{Name='TradeChannelDeployHost';Kind='exe';Library='Renci.SshNet.dll'},@{Name='TradeChannelPairCrypto';Kind='library';Library='jose-jwt.dll'})){
  $extension=if($component.Kind -eq 'exe'){'.exe'}else{'.dll'}
  & $compiler /nologo ('/target:'+$component.Kind) /platform:x64 ('/out:'+(Join-Path $staging ('deployment\'+$component.Name+$extension))) /reference:System.Web.Extensions.dll ('/reference:'+(Join-Path $staging ('assets\lib\'+$component.Library))) (Join-Path $staging ('deployment\'+$component.Name+'.cs')) $assemblyInfo
  if($LASTEXITCODE -ne 0){throw ('Staged component build failed: '+$component.Name)}
 }
 & $compiler /nologo /target:library /platform:x64 ('/out:'+(Join-Path $staging 'deployment\ArchiveVerifier.dll')) /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $staging 'deployment\ArchiveVerifier.cs') $assemblyInfo
 if($LASTEXITCODE -ne 0){throw 'Staged archive verifier build failed.'}
 foreach($leaf in @('TradeChannel.exe','deployment\TradeChannelDeployHost.exe','deployment\TradeChannelPairCrypto.dll')){$info=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $staging $leaf));if($info.FileVersion -cne ($Version+'.0')){throw 'FileVersion differs from version.json.'}}
 $meta=@{SchemaVersion=1;Kind='TradeChannel.PackageMetadata';Version=$Version;Preview=$true;Framework='net48';BuiltAtUtc=[DateTime]::UtcNow.ToString('o');SourceFiles=$sourceHashes;ExcludedDirectoryClasses=@('runtime-data','jobs','nodes','identities','credentials','pairing','probes','logs','packages','test-libs','test-runs');NetworkChanged=$false}
 Write-BuildText (Join-Path $staging 'package-metadata.json') ($meta|ConvertTo-Json -Depth 12) -Bom
 $jsonAllow=@('version.json','package-metadata.json','deployment\dependencies.lock.json')
 foreach($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File)){
  $relative=$file.FullName.Substring($staging.Length+1)
  if($relative -match '(?i)(^|\\)(?:packages|test-libs|test-runs|test-state|tests|jobs|qa|nodes|configs|logs|identities|credentials|pairing|probes|servers|linux-jobs)(?:\\|$)' -or $file.Extension -in @('.conf','.key','.dpapi','.pem','.pfx','.p12','.nupkg','.pyc','.zip','.log','.jsonl')){throw ('Forbidden runtime/dev artifact in staging: '+$relative)}
  if($file.Extension -eq '.json' -and $relative -cnotin $jsonAllow){throw ('Unexpected JSON runtime data: '+$relative)}
  if($file.Extension -in @('.ps1','.psm1','.cs','.py','.json','.md','.txt','.html','.cmd','.xaml','.manifest')){
   $text=[IO.File]::ReadAllText($file.FullName)
   if($text -match '(?ms)-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----' -or $text -match '(?m)^\s*(?:PrivateKey|PresharedKey)\s*=\s*[A-Za-z0-9+/]{43}=\s*$' -or $text -match '(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{18,}\.[A-Za-z0-9_-]{40,}\.[A-Za-z0-9_-]{40,}(?![A-Za-z0-9_-])'){throw ('Potential private key or compact authorization: '+$relative)}
   if($file.Extension -eq '.json' -and $text -match '"(?:Password|Passphrase|PrivateKey|PresharedKey|Protected|Uuid|ClientRequest|ClientResponse|CredentialRef|Authorization|PairRequest)"\s*:'){throw ('Unexpected credential/runtime JSON field: '+$relative)}
   $scanCount++
  }
 }
 Write-BuildText (Join-Path $staging 'package-leak-check.txt') ('Version: '+$Version+"`r`n"+'Allowlisted content only; runtime/development data excluded.'+"`r`n"+'Text files scanned: '+$scanCount+"`r`n"+'Private key blocks, WireGuard private assignments and compact authorizations: none.'+"`r`n"+'Runtime JSON allowlist: version.json, package-metadata.json, deployment/dependencies.lock.json.'+"`r`n")
 $rows=@(Get-ChildItem -LiteralPath $staging -Recurse -File|Where-Object Name -ne 'package.sha256'|Sort-Object FullName|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash+'|'+$_.FullName.Substring($staging.Length+1)})
 [IO.File]::WriteAllLines((Join-Path $staging 'package.sha256'),$rows,(New-Object Text.UTF8Encoding($true)))
 $expectedArchiveRows=@($rows)+@((Get-FileHash -LiteralPath (Join-Path $staging 'package.sha256')).Hash+'|package.sha256')
 # Real Framework/Jose load from standalone staging, not the developer package tree.
 $gate=Join-Path $staging '.build-load-gate.ps1';Write-BuildText $gate @'
param([string]$Root)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Root 'DeploymentDependencies.psm1') -DisableNameChecking
$result=Test-TCDeploymentDependencies -PackageRoot $Root
[Reflection.Assembly]::LoadFrom((Join-Path $Root 'assets\lib\jose-jwt.dll'))|Out-Null
[Reflection.Assembly]::LoadFrom((Join-Path $Root 'deployment\TradeChannelPairCrypto.dll'))|Out-Null
$key=[TradeChannel.Deployment.PairCrypto]::NewPrivateKey();$public=[TradeChannel.Deployment.PairCrypto]::PublicJwk($key)
$signed=[TradeChannel.Deployment.PairCrypto]::Sign('{"Kind":"LoadGate","Version":1}',$key)
$sealed=[TradeChannel.Deployment.PairCrypto]::Encrypt($signed,$public)
$decoded=[TradeChannel.Deployment.PairCrypto]::Decrypt($sealed,$key)
if([TradeChannel.Deployment.PairCrypto]::Verify($decoded,$public) -cne '{"Kind":"LoadGate","Version":1}'){throw 'Staged JOSE roundtrip failed.'}
'FrameworkLoadAndCryptoPassed'
'@ -Bom
 try{$shell=Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe';& $shell -NoProfile -ExecutionPolicy Bypass -File $gate -Root $staging|Out-Null;if($LASTEXITCODE -ne 0){throw 'Staged Framework load/crypto gate failed.'}}finally{if([IO.File]::Exists($gate)){[IO.File]::Delete($gate)}}
 if($StageOnly){[pscustomobject]@{Stage=$staging;Version=$Version;ManifestEntries=$rows.Count;StandaloneDependenciesPassed=$true;RuntimeSecretsIncluded=$false};$staging=$null;return}
 foreach($snapshot in $sourceHashes){if((Get-FileHash -LiteralPath (Join-Path $source $snapshot.Path)).Hash -cne $snapshot.SHA256){throw ('Source changed after snapshot; rebuild latest release: '+$snapshot.Path)}}
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $zip=Join-Path $dist ('TradeChannel-'+$Version+'-windows-x64-preview.zip');$partial=$zip+'.partial-'+[guid]::NewGuid().ToString('N')
 $archive=[IO.Compression.ZipFile]::Open($partial,[IO.Compression.ZipArchiveMode]::Create)
 try{foreach($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File|Sort-Object FullName)){$entry=$archive.CreateEntry($file.FullName.Substring($staging.Length+1).Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$file.LastWriteTime;$inputStream=[IO.File]::OpenRead($file.FullName);$outputStream=$entry.Open();try{$inputStream.CopyTo($outputStream)}finally{$inputStream.Dispose();$outputStream.Dispose()}}}finally{$archive.Dispose()}
 $verifierAssembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $staging 'deployment\ArchiveVerifier.dll')))
 $verifierMethod=$verifierAssembly.GetType('TradeChannel.Packaging.ArchiveVerifier',$true).GetMethod('VerifyExpected')
 $verifyArguments=New-Object object[] 2;$verifyArguments[0]=$partial;$verifyArguments[1]=[string[]]$expectedArchiveRows
 $verified=[int]$verifierMethod.Invoke($null,$verifyArguments)
 if($verified -ne ($rows.Count+1)){throw 'ZIP count differs from checksum manifest.'}
 if([IO.File]::Exists($zip)){[IO.File]::Replace($partial,$zip,[NullString]::Value)}else{[IO.File]::Move($partial,$zip)};$partial=$null
 $hash=(Get-FileHash -LiteralPath $zip).Hash;$hashFile=$zip+'.sha256';$hashTemp=$hashFile+'.'+[guid]::NewGuid().ToString('N');Write-BuildText $hashTemp ($hash+'  '+[IO.Path]::GetFileName($zip)+"`r`n");if([IO.File]::Exists($hashFile)){[IO.File]::Replace($hashTemp,$hashFile,[NullString]::Value)}else{[IO.File]::Move($hashTemp,$hashFile)}
 [pscustomobject]@{Archive=$zip;Bytes=(Get-Item -LiteralPath $zip).Length;SHA256=$hash;Version=$Version;ManifestEntries=$rows.Count;ZipEntries=$verified;CrcAndSHA256Verified=$true;StandaloneDependenciesPassed=$true;RuntimeSecretsIncluded=$false;NetworkChanged=$false}
}finally{
 if($partial -and [IO.File]::Exists($partial)){$expectedParent=(Assert-BuildPath $dist).TrimEnd('\')+'\';$partialFull=Assert-BuildPath $partial;if($partialFull.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($partialFull) -match '^TradeChannel-[0-9.]+-windows-x64-preview\.zip\.partial-[0-9a-f]{32}$'){[IO.File]::Delete($partialFull)}}
 if($staging){Remove-BuildOwnedPath -Path $staging -Parent $dist}
}
