#requires -Version 5.1
# Isolated disposable stores; native commands are limited to pubkey/check.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -DisableNameChecking -PassThru
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-NodeLifecycle-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work)
$engine=Join-Path $package 'assets\sing-box.exe';$wg=Join-Path $package 'assets\wg.exe';$script:Checks=0
& $module {
    $script:LifecycleNative=${function:Invoke-TCProcess};$script:LifecycleFail=$false
    $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
        if($ArgumentList[0] -notin @('check','pubkey')){throw 'Native action forbidden in lifecycle tests.'}
        if($script:LifecycleFail -and $ArgumentList[0] -eq 'check'){return [pscustomobject]@{ExitCode=1;StandardOutput='';StandardError='fixture rejected'}}
        & $script:LifecycleNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
    }
    function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction) @()}
}
function Assert-Case {param([bool]$Ok,[string]$Label) if(-not $Ok){throw ('Lifecycle regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,[string]$Label) $failed=$false;try{$null=& $Body}catch{$failed=$true};Assert-Case $failed $Label}
function ReadJson {param($Path) Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}
function WriteJson {param($Path,$Value) [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))}
function Hash {param($Path) (Get-FileHash -LiteralPath $Path).Hash}
function Current {param($Fixture) @(Get-TCNodes -Root $Fixture.Store|Where-Object {$_.id -eq $Fixture.Id})[0]}
function NewFixture {param([string]$Name)
    $dir=Join-Path $work $Name;$null=[IO.Directory]::CreateDirectory($dir);$store=Join-Path $dir 'Product'
    $program=Join-Path $dir 'NinjaTrader.exe';[IO.File]::WriteAllText($program,'inert fixture')
    $private=(& $wg genkey).Trim();$serverPrivate=(& $wg genkey).Trim()
    $public=& $module {param($Exe,$Key) Invoke-TCNative -FilePath $Exe -ArgumentList @('pubkey') -InputText $Key} $wg $serverPrivate
    $conf=Join-Path $dir 'client.conf';$text="[Interface]`nPrivateKey = $private`nAddress = 10.99.0.2/24`n[Peer]`nPublicKey = $($public.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n"
    [IO.File]::WriteAllText($conf,$text,(New-Object Text.UTF8Encoding($false)))
    $node=Import-TCWireGuard -Root $store -Path $conf -Name $Name -EnginePath $engine -WgPath $wg -TradeProgramPaths @($program) -DirectDnsIPv4 '192.168.100.1'
    [pscustomobject]@{Root=$dir;Store=$store;Id=$node.id;OriginalManifest=$node.manifestPath}
}
$parameters=@{Server='192.0.2.10';Port=443;Uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';ServerName='www.example.com';RealityPublicKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';RealityShortId='1234567890abcdef'}
try {
    $f=NewFixture 'transaction';$old=ReadJson $f.OriginalManifest;$oldHash=Hash $old.CandidatePath;$indexHash=Hash (Join-Path $f.Store 'index.json')
    Reject {Set-TCTransportMode -Root $f.Store -Id $f.Id -Mode Tcp} 'TCP without server credentials is rejected'
    Assert-Case ((Hash $old.CandidatePath) -eq $oldHash) 'missing credentials preserve original'
    & $module {$script:LifecycleFail=$true}
    Reject {Set-TCTransportMode -Root $f.Store -Id $f.Id -Mode Tcp -TransportParams $parameters} 'native check failure aborts'
    & $module {$script:LifecycleFail=$false}
    Assert-Case ((Hash $old.CandidatePath) -eq $oldHash -and (Hash (Join-Path $f.Store 'index.json')) -eq $indexHash) 'failed conversion leaves original and index intact'
    $null=Set-TCTransportMode -Root $f.Store -Id $f.Id -Mode Tcp -TransportParams $parameters
    $node=Current $f;$mf=ReadJson $node.manifestPath;$cfg=ReadJson $mf.CandidatePath;$probe=ReadJson $mf.ProbePath
    Assert-Case ($node.manifestPath -ne $f.OriginalManifest -and (Hash $old.CandidatePath) -eq $oldHash) 'successful conversion commits a new manifest and preserves old files'
    Assert-Case ($cfg.endpoints[0].detour -eq 'tc-transport' -and $probe.endpoints[0].detour -eq 'tc-transport') 'candidate and probe both carry TCP'
    Assert-Case ($mf.CandidateSHA256 -eq (Hash $mf.CandidatePath) -and $mf.ProbeSHA256 -eq (Hash $mf.ProbePath)) 'both hashes match'
    $up=Update-TCNodePolicy -Root $f.Store -ManifestPath $node.manifestPath
    $upMf=ReadJson $up.ManifestPath;Assert-Case ($upMf.Transport.Type -eq 'tcp-reality') 'policy upgrade preserves TCP metadata'
    $legacy=ReadJson $node.manifestPath;$legacy.PSObject.Properties.Remove('Transport');WriteJson $node.manifestPath $legacy
    $legacyUp=Update-TCNodePolicy -Root $f.Store -ManifestPath $node.manifestPath;$legacyMf=ReadJson $legacyUp.ManifestPath
    Assert-Case ($legacyMf.Transport.Type -eq 'tcp-reality' -and (ReadJson $legacyMf.CandidatePath).endpoints[0].detour -eq 'tc-transport') 'legacy injected TCP migrates instead of losing outbound'
    WriteJson (Join-Path $f.Root 'deployment.json') @{ManifestPath=$node.manifestPath;Stage='Active'}
    WriteJson (Join-Path $f.Root 'runtime.json') @{State='Disconnected'}
    $null=Set-TCTransportMode -Root $f.Store -Id $f.Id -Mode Udp
    $node=Current $f;$udp=ReadJson $node.manifestPath
    Assert-Case (-not $udp.Transport -and -not (ReadJson $udp.CandidatePath).endpoints[0].PSObject.Properties['detour']) 'disconnected selected node can switch to UDP'
    Assert-Case ((ReadJson (Join-Path $f.Root 'deployment.json')).ManifestPath -eq $node.manifestPath) 'selected deployment follows the new checked manifest'
    WriteJson (Join-Path $f.Root 'runtime.json') @{State='Running'}
    Reject {Set-TCTransportMode -Root $f.Store -Id $f.Id -Mode Tcp -TransportParams $parameters} 'running selected node cannot be mutated'
    Reject {Remove-TCNode -Root $f.Store -Id $f.Id} 'running selected node cannot be deleted'
    WriteJson (Join-Path $f.Root 'runtime.json') @{State='Disconnected'}
    $null=Remove-TCNode -Root $f.Store -Id $f.Id
    Assert-Case (@(Get-TCNodes -Root $f.Store).Count -eq 0 -and -not (Test-Path (Join-Path $f.Root 'deployment.json'))) 'stopped selected node can be removed with selection cleanup'
    $f=NewFixture 'locked';$mf=ReadJson $f.OriginalManifest;$held=[IO.File]::Open($mf.CandidatePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{Reject {Remove-TCNode -Root $f.Store -Id $f.Id} 'locked deletion is not reported successful';Assert-Case (@(Get-TCNodes -Root $f.Store).Count -eq 1 -and (Test-Path $mf.CandidatePath)) 'failed deletion retains node and file'}finally{$held.Dispose()}
    $external=Join-Path $work 'original-files';$null=[IO.Directory]::CreateDirectory($external)
    $sentinel=Join-Path $external 'user-data.txt';[IO.File]::WriteAllText($sentinel,'preserve me')
    $candidate=Join-Path $external 'config.json';WriteJson $candidate @{}
    $manifest=Join-Path $external 'manifest.json';WriteJson $manifest @{SchemaVersion=1;EnginePath=$engine;CandidatePath=$candidate;ServerEndpoint='192.0.2.11:51820'}
    $store=Join-Path (Join-Path $work 'adoption') 'Product';$node=Register-TCExisting -Root $store -ManifestPath $manifest -Name 'adopted'
    $result=Remove-TCNode -Root $store -Id $node.id
    Assert-Case ($result.ExternalFilesPreserved -and (Test-Path $sentinel) -and (Test-Path $manifest)) 'deleting adopted node preserves external directory and unrelated files'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;NativeScope='pubkey and check only';LegacyTcpMigrated=$true}
}finally{
    Remove-Module NodeStore -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-NodeLifecycle-[0-9a-f]{32}$'){throw 'Cleanup rejected.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
