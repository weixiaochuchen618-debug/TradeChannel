#requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='0.9.2',[string]$SourceDirectory,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$workspace=Split-Path $PSScriptRoot -Parent
$source=if($SourceDirectory){(Resolve-Path -LiteralPath $SourceDirectory).Path}else{$workspace}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw '.NET Framework x64 C# compiler was not found.'}
$required=@('NodeOperations.ps1','Diagnostics.psm1','Maintenance.psm1','ui\TransportPages.ps1','linux\transport_support.py','更新说明.md','TradeChannel.ps1','Worker.ps1','RuntimeBridge.psm1','NodeStore.psm1','ServerSetup.psm1','Startup.psm1','InstallerSetup.psm1','Create-DesktopShortcut.ps1','创建桌面入口.cmd','ui\Shell.xaml','ui\Pages.ps1','ui\SetupPages.ps1','ui\SelfTest.ps1','Launcher.cs','app.manifest','assets\sing-box.exe','assets\wg.exe','assets\TradeChannel.ico','assets\TradeChannel.png','assets\wireguard-installer.exe','runtime\Run-TradeChannel.ps1','runtime\Invoke-TradeChannel.ps1','runtime\TradeChannel.Provider.ps1','runtime\TradeChannel.Proxy.ps1','runtime\Set-TradeChannelDaily.ps1','runtime\TradeChannel.Agents.ps1','runtime\Set-TradeChannelAgents.ps1','runtime\Set-TradeChannelMode.ps1','runtime\Set-TradeChannelExit.ps1','runtime\Test-SelectedTradeExit.ps1','runtime\TradeChannelGuard.cs','新手部署指南.md','快速部署.html')
foreach($file in $required){if(-not(Test-Path -LiteralPath (Join-Path $source $file))){throw ('Missing product file: '+$file)}}
if([version]$Version -ge [version]'0.7.0'){
    foreach($file in @('ProviderBridge.psm1','runtime\TradeChannel.Providers.ps1','runtime\TradeChannel.ProviderSetup.ps1')){if(-not(Test-Path -LiteralPath (Join-Path $source $file))){throw ('Missing provider integration file: '+$file)}}
}
if([version]$Version -ge [version]'0.8.0'){
    foreach($file in @('LinuxServerSetup.psm1','linux\tradechannel_linux.py','linux\Invoke-LinuxConsole.ps1','ui\LinuxPages.ps1','Linux部署指南.md')){if(-not(Test-Path -LiteralPath (Join-Path $source $file))){throw ('Missing Linux deployment file: '+$file)}}
}
$expected=@{'sing-box.exe'='7BBEF1DEA9189EE12799AE834EA4B4658355DA25C47A21AD8804904C0CCD9410';'wg.exe'='E1F8CB5C9E30A878FA7EB0B2251BB4EB4946E669063E6FD5E4383CA4BD0DCAF2';'wireguard-installer.exe'='6962B6F42BC442E2A822608817222C93C7EF03F34476337608B170D4D76FD5F3'}
foreach($name in $expected.Keys){if((Get-FileHash -LiteralPath (Join-Path $source ('assets\'+$name))).Hash -ne $expected[$name]){throw ('Unexpected helper hash: '+$name)}}
$signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $source 'assets\wireguard-installer.exe')
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=WireGuard LLC(?:,|$)'){throw 'WireGuard installer signature verification failed.'}
foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File|Where-Object {$_.Extension -in @('.ps1','.psm1')}){
    $text=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($file.FullName,$text,(New-Object Text.UTF8Encoding($true)))
    $t=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$errors)
    if($errors.Count){throw ('Parser failed: '+$file.Name)}
}
& $compiler /nologo /target:winexe /platform:x64 ('/out:'+(Join-Path $source 'TradeChannel.exe')) ('/win32manifest:'+(Join-Path $source 'app.manifest')) ('/win32icon:'+(Join-Path $source 'assets\TradeChannel.ico')) /reference:System.Windows.Forms.dll (Join-Path $source 'Launcher.cs')
if($LASTEXITCODE -ne 0){throw 'Launcher build failed.'}
$manifest=Join-Path $source 'package.sha256'
$rows=@(Get-ChildItem -LiteralPath $source -Recurse -File|Where-Object {$_.Name -ne 'package.sha256'}|Sort-Object FullName|ForEach-Object {
    $relative=$_.FullName.Substring($source.Length+1)
    if($relative -match '\.(zip|conf|key|dpapi|pem|log)$' -or $relative -match '(^|\\)__pycache__(\\|$)' -or $relative -match '\.pyc$' -or $relative -match '(^|\\)(jobs|qa|nodes|configs|logs)(\\|$)'){throw ('Unexpected runtime/secret file in product: '+$relative)}
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash+'|'+$relative
})
[IO.File]::WriteAllLines($manifest,$rows,(New-Object Text.UTF8Encoding($true)))
$dist=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path (Split-Path $workspace -Parent) 'dist'};$null=New-Item -ItemType Directory -Path $dist -Force
$zip=Join-Path $dist ('TradeChannel-'+$Version+'-windows-x64-preview.zip')
# Shared reads, because an open console keeps its assets open. The previous archive stays until the new one is complete.
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$partial=$zip+'.partial';if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
$archive=[IO.Compression.ZipFile]::Open($partial,[IO.Compression.ZipArchiveMode]::Create)
try{foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File|Sort-Object FullName){
    $entry=$archive.CreateEntry($file.FullName.Substring($source.Length+1).Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal);$entry.LastWriteTime=$file.LastWriteTime
    $in=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]'ReadWrite, Delete');$out=$entry.Open()
    try{$in.CopyTo($out)}finally{$out.Dispose();$in.Dispose()}
}}finally{$archive.Dispose()}
if(Test-Path -LiteralPath $zip){[IO.File]::Replace($partial,$zip,[NullString]::Value)}else{[IO.File]::Move($partial,$zip)}
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($zip+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($zip)+"`r`n"),(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{Archive=$zip;Bytes=(Get-Item -LiteralPath $zip).Length;SHA256=$hash;ManifestEntries=$rows.Count;RuntimeSecretsIncluded=$false}
