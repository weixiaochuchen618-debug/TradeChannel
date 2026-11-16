#requires -Version 5.1
param([string]$Root,[string]$PackageRoot,[string]$SourceRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $SourceRoot 'runtime\TradeChannel.Provider.ps1')
$script:FixturePackage=$PackageRoot
$script:OriginalRelayLoader=${function:Initialize-TCProviderRelayComponent}
function Initialize-TCProviderRelayComponent { & $script:OriginalRelayLoader -PackageRoot $script:FixturePackage }
function Get-TCForeignTunnel { $null }
function Test-TCProviderForwarding {
    param([int]$Port,[int]$TimeoutSeconds=6)
    # Only the synthetic loopback backend is touched. No curl, DNS, Internet,
    # route, real provider, WFP or TUN operation is permitted in this fixture.
    $client=New-Object Net.Sockets.TcpClient
    try{
        $client.ReceiveTimeout=2000;$client.SendTimeout=2000;$client.Connect('127.0.0.1',$Port);$s=$client.GetStream()
        $s.Write([byte[]]@(5,1,0),0,3);if($s.ReadByte() -ne 5 -or $s.ReadByte() -ne 0){throw 'SOCKS failed'}
        $s.Write([byte[]]@(5,1,0,1,198,51,100,42,1,187),0,10)
        $b=New-Object byte[] 10;$i=0;while($i -lt 10){$n=$s.Read($b,$i,10-$i);if(-not $n){throw 'EOF'};$i+=$n}
        $mark=$s.ReadByte();$ok=$b[1] -eq 0 -and $mark -in @(65,66)
        if([IO.File]::Exists((Join-Path $Root 'fixture-forwarding-fail'))){$ok=$false}
        [pscustomobject]@{Ok=$ok;IP='198.51.100.42';TradingEgressVerified=$false}
    }catch{[pscustomobject]@{Ok=$false;IP=$null;TradingEgressVerified=$false}}finally{$client.Dispose()}
}
function Test-TCProviderTradingPolicy {param($Provider);[pscustomobject]@{Allowed=$true;TradingEgressVerified=$true}}
$manifest=Read-TCRelayJson (Join-Path $Root 'manifest.json');$engine=$null;$context=$null
try{
    $engine=Start-Process -FilePath $manifest.EnginePath -ArgumentList @('run','-c',('"'+$manifest.CandidatePath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $Root 'fixture-engine.log') -RedirectStandardOutput (Join-Path $Root 'fixture-engine.out')
    $session=[guid]::NewGuid().ToString('N')
    $runtime=[ordered]@{State='Starting';SessionId=$session;SupervisorPid=$PID;SupervisorStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');EnginePid=$engine.Id;EngineStartedAt=$engine.StartTime.ToUniversalTime().ToString('o');ManifestPath=(Join-Path $Root 'manifest.json');ConfigPath=$manifest.CandidatePath}
    [IO.File]::WriteAllText((Join-Path $Root 'runtime.json'),($runtime|ConvertTo-Json))
    # The production host validates the very same protected package receipt.
    $context=Start-TCProviderRelay -Root $Root -Manifest $manifest -SessionId $session
    $runtime.State='Running';[IO.File]::WriteAllText((Join-Path $Root 'runtime.json'),($runtime|ConvertTo-Json))
    $ready=Join-Path $Root 'fixture-ready';[IO.File]::WriteAllText($ready,[string]$PID)
    while(-not [IO.File]::Exists((Join-Path $Root 'fixture-stop')) -and -not $engine.HasExited){
        Sync-TCProviderRelay $context {
            if([IO.File]::Exists((Join-Path $Root 'fixture-protected.json'))){@((Read-TCRelayJson (Join-Path $Root 'fixture-protected.json')).Tags)}else{@('hk','direct')}
        }
        Start-Sleep -Milliseconds 100
    }
}catch{[IO.File]::WriteAllText((Join-Path $Root 'fixture-error.txt'),($_.Exception.Message+"`n"+$_.ScriptStackTrace));exit 1}
finally{
    if($context){Stop-TCProviderRelay $context}
    if($engine){if(-not $engine.HasExited){$engine.Kill();$null=$engine.WaitForExit(5000)};$engine.Dispose()}
}
