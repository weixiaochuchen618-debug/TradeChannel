#requires -Version 5.1
# Isolated stores, generated keys, real sing-box check only. No runtime launch.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
Import-Module (Join-Path $package 'ConfigurationRecovery.psm1') -Force -DisableNameChecking
& $nodes {function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()};$script:RecoveryNative=${function:Invoke-TCProcess};$script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)if($ArgumentList[0] -notin @('check','pubkey')){throw 'Runtime execution forbidden.'};& $script:RecoveryNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds}}
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-ConfigurationRecovery-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param($Ok,$Label)if(-not $Ok){throw ('Configuration recovery regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Label}
function ReadJson {param($p)[IO.File]::ReadAllText($p)|ConvertFrom-Json}
function WriteJson {param($p,$v)[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))}
function Hash {param($p)(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
try{
    $wg=Join-Path $package 'assets\wg.exe';$engine=Join-Path $package 'assets\sing-box.exe';$private=(& $wg genkey).Trim();$serverPrivate=(& $wg genkey).Trim()
    $pub=& $nodes {param($exe,$key)Invoke-TCNative -FilePath $exe -ArgumentList @('pubkey') -InputText $key} $wg $serverPrivate
    $conf=Join-Path $work 'client.conf';$program=Join-Path $work 'NinjaTrader.exe';[IO.File]::WriteAllText($program,'inert')
    [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.99.0.2/24`n[Peer]`nPublicKey = $($pub.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`n"),(New-Object Text.UTF8Encoding($false)))
    $store=Join-Path $work 'Product';$node=Import-TCWireGuard -Root $store -Path $conf -Name 'Recovery fixture' -EnginePath $engine -WgPath $wg -TradeProgramPaths @($program) -DirectDnsIPv4 '192.168.100.1'
    $original=ReadJson $node.manifestPath;$originalHash=Hash $original.CandidatePath
    $none=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;Check (-not $none.Available) 'no rollback is advertised before an update'
    $up=Update-TCNodePolicy -Root $store -ManifestPath $node.manifestPath;$null=Set-TCNodeManifest -Root $store -PreviousManifestPath $node.manifestPath -ManifestPath $up.ManifestPath
    $preview=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;Check ($preview.Available -and $preview.CanRestore -and $preview.PreviousManifestPath -eq $node.manifestPath) 'policy updates persist an actual previous-manifest rollback point'
    WriteJson (Join-Path $work 'deployment.json') @{ManifestPath=$up.ManifestPath;Stage='Active'};WriteJson (Join-Path $work 'runtime.json') @{ManifestPath=$up.ManifestPath;State='Running';CleanupError=$false}
    $active=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;Check ($active.Available -and $active.RequiresMaintenance -and -not $active.CanRestore) 'active configuration is previewable but cannot restore'
    $before=Hash (Join-Path $store 'index.json');Reject {Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $active.PreviewToken} 'active restore rejected without disconnecting'
    Check ((Hash (Join-Path $store 'index.json')) -eq $before -and (ReadJson (Join-Path $work 'runtime.json')).State -eq 'Running') 'rejected restore leaves index and active state untouched'
    WriteJson (Join-Path $work 'runtime.json') @{ManifestPath=$up.ManifestPath;State='Disconnected';CleanupError=$false}
    Reject {Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $active.PreviewToken} 'active-state drift invalidates prior preview'
    $preview=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;$restored=Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $preview.PreviewToken
    Check ($restored.Restored -and -not $restored.NetworkChanged -and -not $restored.Activated -and (ReadJson (Join-Path $work 'deployment.json')).ManifestPath -eq $restored.ManifestPath) 'stopped selected restore changes records only and preserves no-auto-connect boundary'
    $rm=ReadJson $restored.ManifestPath;Check ((Hash $rm.CandidatePath) -eq $originalHash -and $rm.PreviousManifestPath -eq $up.ManifestPath) 'restored configuration is exact previous candidate and has reversible pointer'
    Check (@((ReadJson $rm.ProbePath).inbounds[0].users).Count -eq 1 -and (ReadJson $rm.ProbePath).inbounds[0].users[0].password.Length -ge 32) 'recovery generates safe authenticated probe assets without changing old probe'
    $preview=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;$back=Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $preview.PreviewToken
    Check ($back.Restored -and (ReadJson $back.ManifestPath).CandidatePath -eq (ReadJson $up.ManifestPath).CandidatePath) 'a restore can be undone using next valid rollback point'
    $preview=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;$current=ReadJson $back.ManifestPath;$current|Add-Member NoteProperty Drift 'fixture' -Force;WriteJson $back.ManifestPath $current
    Reject {Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $preview.PreviewToken} 'current manifest hash drift rejects stale preview'
    $preview=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;$prior=ReadJson $preview.PreviousManifestPath;$saved=[IO.File]::ReadAllText($prior.CandidatePath);[IO.File]::AppendAllText($prior.CandidatePath,' ')
    Check (-not (Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id).Available) 'corrupt prior candidate disables recovery'
    [IO.File]::WriteAllText($prior.CandidatePath,$saved,(New-Object Text.UTF8Encoding($false)))
    $current=ReadJson $back.ManifestPath;[IO.File]::AppendAllText($current.CandidatePath,' ')
    $manual=Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id;Check ($manual.Available -and $manual.CurrentConfigurationChanged -and $manual.Message.Contains('不能再次恢复')) 'manual current edits can restore a valid prior config with accurate reverse limitation'
    $manualResult=Restore-TCNodeConfiguration -Root $work -NodeId $node.id -PreviewToken $manual.PreviewToken
    Check ($manualResult.Restored -and -not (Get-TCConfigurationRollbackPreview -Root $work -NodeId $node.id).Available) 'invalid edited prior config is preserved but never offered as valid reverse recovery'
    Check ((Hash $original.CandidatePath) -eq $originalHash) 'original candidate remains untouched across successful restore and reverse'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;NativeScope='pubkey and check';ActiveRestoreBlocked=$true;ReversibleConfigurationRestore=$true}
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-ConfigurationRecovery-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
