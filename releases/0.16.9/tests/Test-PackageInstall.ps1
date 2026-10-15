#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$OldPackageDirectory='C:\tradechannel',[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
$expectedVersion=([IO.File]::ReadAllText((Join-Path $PackageDirectory 'version.json'))|ConvertFrom-Json).Version
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-install-test-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
$installer=Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\Install-TradeChannelPackage.ps1'
function Check {param($condition,$name)if(-not $condition){throw $name};$script:checks++}
function Fingerprint {param($directory)$rows=@(Get-ChildItem -LiteralPath $directory -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName.Substring($directory.Length+1)+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash});return $rows -join "`n"}
try{
 $fresh=Join-Path $root 'fresh'
 $result=& $installer -PackageDirectory $PackageDirectory -TargetDirectory $fresh -BackupDirectory (Join-Path $root 'fresh-receipt')
 Check ($result.Installed -and $result.AclVerified -and $result.Version -ceq $expectedVersion) 'new dedicated installation validates files version and ACL'
 $loaded=& (Join-Path $fresh 'tools\Install-TradeChannelPackage.ps1') -PackageDirectory $fresh -TargetDirectory (Join-Path $root 'unused') -BackupDirectory (Join-Path $root 'unused-receipt') -ValidateOnly
 Check ($loaded.Validated -and $loaded.Files -eq $result.VerifiedFiles) 'installed copy validates as a complete package'
 $upgrade=Join-Path $root 'upgrade'
 $old=& $installer -PackageDirectory $OldPackageDirectory -TargetDirectory $upgrade -BackupDirectory (Join-Path $root 'old-receipt')
 $before=Fingerprint $upgrade;$failed=$false
 try{$null=& $installer -PackageDirectory $PackageDirectory -TargetDirectory $upgrade -BackupDirectory (Join-Path $root 'failed-receipt') -TestFailAfterWrites 9}catch{$failed=$true}
 Check ($failed -and (Fingerprint $upgrade) -ceq $before) 'injected mid-update failure restores every original byte and removes new files'
 $new=& $installer -PackageDirectory $PackageDirectory -TargetDirectory $upgrade -BackupDirectory (Join-Path $root 'upgrade-receipt')
 Check ($new.Installed -and $new.Version -ceq $expectedVersion) 'overwrite update succeeds after rollback'
 $rollback=& $installer -PackageDirectory $new.Backup -TargetDirectory $upgrade -BackupDirectory (Join-Path $root 'rollback-receipt')
 Check ($rollback.Installed -and $rollback.Version -eq $old.Version -and (Fingerprint $upgrade) -ceq $before) 'retained old package can be reinstalled with matching metadata and hashes'
 [IO.File]::AppendAllText((Join-Path $fresh 'version.json'),' ')
 $rejected=$false;try{$null=& $installer -PackageDirectory $fresh -TargetDirectory (Join-Path $root 'invalid') -BackupDirectory (Join-Path $root 'invalid-receipt') -ValidateOnly}catch{$rejected=$true}
 Check ($rejected -and -not (Test-Path -LiteralPath (Join-Path $root 'invalid'))) 'damaged package is rejected before touching installation'
 $result=[pscustomobject]@{Passed=$true;Checks=$checks;Files=$new.VerifiedFiles;OldVersion=$old.Version;NewVersion=$new.Version;NewInstall=$true;Upgrade=$true;InjectedRollback=$true;ExplicitRollback=$true;ProductionWrites=0}
 if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($root)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-install-test-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
