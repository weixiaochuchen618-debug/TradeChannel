#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('ProductTests-Bridge-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try{
    $checks=& $module {
        param($testRoot)
        $script:Root=$testRoot
        $atomic=Join-Path $testRoot 'atomic.json'
        [IO.File]::WriteAllText($atomic,'{"value":"old"}')
        $held=[IO.File]::Open($atomic,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $writeFailed=$false
        try{try{Write-TCSessionText $atomic '{"value":"new"}'}catch{$writeFailed=$true}}finally{$held.Dispose()}
        if(-not $writeFailed -or [IO.File]::ReadAllText($atomic) -ne '{"value":"old"}' -or @(Get-ChildItem $testRoot -Filter '*.tmp').Count){throw 'Failed replacement lost original file or left a temporary writer'}
        Write-TCSessionText $atomic '{"value":"new"}'
        if((Get-Content $atomic -Raw|ConvertFrom-Json).value -ne 'new'){throw 'Atomic replacement did not commit'}
        $script:Commands=New-Object 'System.Collections.Generic.List[string]'
        $script:FailCandidate=$false;$script:NinjaBusy=$false;$script:FailCommand=$null;$script:RequireExplicitSelection=$false
        function script:Get-Process {param($Name,$ErrorAction)if($script:NinjaBusy){[pscustomobject]@{Name='NinjaTrader'}}}
        function script:Get-TCOverview {[pscustomobject]@{Running=$true;Mode='rule';Exit='hk'}}
        function script:Invoke-TCCommand {param($Action)$script:Commands.Add([string]$Action);if($Action -eq $script:FailCommand){throw 'Injected command failure'}}
        function script:Test-TCActiveConnection {
            if($script:RequireExplicitSelection -and ($script:Commands.ToArray() -join ',') -ne 'Emergency,Connect,Provider,Global'){throw 'Connectivity probe ran before explicit selection was applied'}
            if($script:FailCandidate){throw 'Injected candidate probe failure'}
            [pscustomobject]@{ExitHttp=$true;ObservedIP='203.0.113.20';TradingViewHttp=$true}
        }
        $cfg=Join-Path $testRoot 'dual-mode.json';[IO.File]::WriteAllText($cfg,'{}')
        $manifest=Join-Path $testRoot 'candidate.json'
        [IO.File]::WriteAllText($manifest,(@{SchemaVersion=1;CandidatePath=$cfg;SyntaxValidated=$true;DeploymentApproved=$false;ProviderProgramPaths=@('C:\Mock\provider.exe');ProviderDirectory='C:\Mock';ProviderSocksPort=10823}|ConvertTo-Json))
        $deployment=Join-Path $testRoot 'deployment.json'
        $prior='{"ManifestPath":"original-manifest.json","Stage":"Existing"}'
        [IO.File]::WriteAllText($deployment,$prior)
        $script:FailCandidate=$true
        $caught=$false;try{$null=Enable-TCNode -ManifestPath $manifest}catch{$caught=$true}
        if(-not $caught -or [IO.File]::ReadAllText($deployment) -ne $prior){throw 'Old deployment was not restored after candidate failure'}
        if(($script:Commands.ToArray() -join ',') -ne 'Emergency,Connect,Disconnect'){throw 'Rollback must stop the candidate without automatic reconnect'}
        $script:Commands.Clear();$script:FailCommand='Emergency'
        $caught=$false;try{$null=Enable-TCNode -ManifestPath $manifest}catch{$caught=$true}
        if(-not $caught -or ($script:Commands.ToArray() -join ',') -ne 'Emergency' -or [IO.File]::ReadAllText($deployment) -ne $prior){throw 'Stop failure attempted automatic recovery or changed deployment'}
        $script:Commands.Clear();$script:FailCommand='Disconnect'
        $caught=$false;try{$null=Enable-TCNode -ManifestPath $manifest}catch{$caught=$true}
        if(-not $caught -or ($script:Commands.ToArray() -join ',') -ne 'Emergency,Connect,Disconnect' -or (Get-Content -LiteralPath $deployment -Raw|ConvertFrom-Json).ManifestPath -ne $manifest){throw 'Candidate cleanup failure lost the live deployment identity'}
        $script:FailCommand=$null;[IO.File]::WriteAllText($deployment,$prior)
        $script:Commands.Clear();$script:NinjaBusy=$true
        $caught=$false;try{$null=Enable-TCNode -ManifestPath $manifest}catch{$caught=$true}
        if(-not $caught -or $script:Commands.Count){throw 'Running trading app did not block activation before mutation'}
        $script:NinjaBusy=$false;Remove-Item -LiteralPath $deployment
        $script:Commands.Clear();$caught=$false
        try{$null=Enable-TCNode -ManifestPath $manifest}catch{$caught=$true}
        if(-not $caught -or (Test-Path -LiteralPath $deployment)){throw 'First-install failure left a selected deployment'}
        $script:FailCandidate=$false
        $r=Enable-TCNode -ManifestPath $manifest
        if(-not $r.Activated -or (Get-Content -LiteralPath $deployment -Raw|ConvertFrom-Json).ManifestPath -ne $manifest){throw 'Successful candidate not selected'}
        $script:Commands.Clear();$script:RequireExplicitSelection=$true
        $r=Enable-TCNode -ManifestPath $manifest -Mode Global -Exit Provider
        if(-not $r.Activated -or ($script:Commands.ToArray() -join ',') -ne 'Emergency,Connect,Provider,Global'){throw 'Explicit node selection was not applied before probe'}
        [pscustomobject]@{Passed=$true;Checks=9;Scope='Atomic replacement failure, mocked transitions; rollback, failed stop, cleanup identity, busy gate, first-install cleanup, selection, explicit mode/exit before probe';RealNetworkChanges=0}
    } $root
    $checks
}finally{
    Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'ProductTests-Bridge-*'){throw 'Cleanup guard rejected path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
