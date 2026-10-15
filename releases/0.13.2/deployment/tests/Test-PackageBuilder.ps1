#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$RuntimeStage)
$ErrorActionPreference='Stop';$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
$root=Join-Path $PackageRoot ('deployment\test-runs\package-'+[guid]::NewGuid().ToString('N'));$source=Join-Path $root 'source';$out=Join-Path $root 'output'
try{
 New-Item -ItemType Directory -Path $source -Force|Out-Null
 foreach($file in Get-ChildItem -LiteralPath $RuntimeStage -Recurse -File){$relative=$file.FullName.Substring($RuntimeStage.Length+1);$destination=Join-Path $source $relative;New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $destination}
 # Runtime-only stage is a sufficient independent build source; extra data must never be bundled.
 $extra=Join-Path $source 'identities\must-never-ship';New-Item -ItemType Directory -Path $extra -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $extra 'secret.conf'),'Private fixture must never be selected')
 $builder=Join-Path $source 'tools\Build-TradeChannelPreview.ps1'
 Assert-Reject {& $builder -Version 0.10.1 -SourceDirectory $source -OutputDirectory $out} 'Version argument cannot override authoritative source version'
 $build=& $builder -Version 0.10.0 -SourceDirectory $source -OutputDirectory $out
 Assert-Check ($build.CrcAndSHA256Verified -and $build.StandaloneDependenciesPassed) 'Standalone-source ZIP passes real Framework load and entry CRC/SHA gates'
 $zip=[IO.Compression.ZipFile]::OpenRead($build.Archive)
 try{
  Assert-Check (-not @($zip.Entries|Where-Object {$_.FullName -match 'identities|test-libs|packages/|test-runs|\.conf$'}).Count) 'User identity and developer fixtures are excluded from archive'
  $names=@($zip.Entries|ForEach-Object {$_.FullName});Assert-Check ('DeploymentDependencies.psm1' -in $names -and 'deployment/TradeChannelDeployHost.exe' -in $names -and 'ui/Test-010UI.ps1' -in $names) 'Deployment runtime and standalone UI validation are complete'
 }finally{$zip.Dispose()}
 $checksum=[IO.File]::ReadAllText($build.Archive+'.sha256').Split(' ')[0]
 Assert-Check ($checksum -ceq (Get-FileHash -LiteralPath $build.Archive).Hash) 'External SHA256 exactly matches published ZIP'
 $readme=Join-Path $source 'README.md';$clean=[IO.File]::ReadAllText($readme);[IO.File]::WriteAllText($readme,($clean+"`r`nPrivateKey = "+('A'*43)+"=`r`n"),(New-Object Text.UTF8Encoding($true)))
 $originalHash=(Get-FileHash -LiteralPath $build.Archive).Hash
 Assert-Reject {& $builder -Version 0.10.0 -SourceDirectory $source -OutputDirectory $out} 'Private WireGuard key in allowed text blocks publication'
 Assert-Check ((Get-FileHash -LiteralPath $build.Archive).Hash -ceq $originalHash) 'Failed build preserves previous published archive'
 [IO.File]::WriteAllText($readme,$clean,(New-Object Text.UTF8Encoding($true)))
 # A CRC mismatch is detected even when ZIP still decompresses cleanly.
 $corrupt=Join-Path $out 'crc-negative.zip';Copy-Item -LiteralPath $build.Archive -Destination $corrupt
 $bytes=[IO.File]::ReadAllBytes($corrupt);$position=-1;for($i=$bytes.Length-22;$i -ge [math]::Max(0,$bytes.Length-65557);$i--){if([BitConverter]::ToUInt32($bytes,$i) -eq 0x06054b50){$position=$i;break}}
 if($position -lt 0){throw 'Fixture ZIP central directory missing.'};$central=[BitConverter]::ToUInt32($bytes,$position+16);$bytes[$central+16]=$bytes[$central+16] -bxor 1;[IO.File]::WriteAllBytes($corrupt,$bytes)
 Assert-Reject {[TradeChannel.Packaging.ArchiveVerifier]::Verify($corrupt,$RuntimeStage)} 'CRC-mutated entry is rejected'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkChanged=$false}|ConvertTo-Json -Depth 8
}finally{
 $absolute=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
