#requires -Version 5.1
# Disposable journals and fixture child processes only; no live runtime/network.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $package 'RuntimeObservability.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-RuntimeObservability-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0;$child=$null
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Runtime observability regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,[string]$Label)$caught=$false;try{$null=& $Body}catch{$caught=$true;Check (-not $_.Exception.Message.Contains('fixture-secret')) ($Label+' does not expose secret')};Check $caught $Label}
try{
    Reject {Add-TCRuntimeEvent -Root $work -SessionId 'safe' -Type SessionStarting -Data @{Password='fixture-secret'}} 'arbitrary and secret fields refused'
    Reject {Add-TCRuntimeEvent -Root $work -SessionId 'safe' -Type DailyExitChanged -Data @{Target='fixture-secret'}} 'arbitrary outbound values refused'
    Reject {Add-TCRuntimeEvent -Root $work -SessionId '../escape' -Type SessionReady} 'event path identities refused'
    $null=Add-TCRuntimeEvent -Root $work -SessionId 'safe' -Type SessionStarting -Data @{State='Starting'} -DedupKey 'start'
    $added=Add-TCRuntimeEvent -Root $work -SessionId 'safe' -Type SessionStarting -Data @{State='Starting'} -DedupKey 'start'
    Check (-not $added -and @(Get-TCRuntimeEvents -Root $work).Count -eq 1) 'persisted idempotence survives repeated observation'
    for($i=0;$i -lt 210;$i++){$null=Add-TCRuntimeEvent -Root $work -SessionId 'safe' -Type ProxyNormalized -Data @{Kind='Provider';Count=$i}}
    $events=@(Get-TCRuntimeEvents -Root $work);Check ($events.Count -eq 200 -and $events[0].Data.Count -eq 10 -and $events[-1].Data.Count -eq 209) 'journal retains only newest 200 typed events'
    Check ((Get-Item -LiteralPath (Join-Path $work 'runtime-events.json')).Length -le 524288) 'event storage stays within byte limit'
    $rt=@{State='StoppedWithError';SessionId='terminal-fixture';StartedAt='2026-10-08T01:00:00Z';EngineStartedAt='2026-10-08T01:00:00Z';FinishedAt='2026-10-08T02:00:00Z';Error='fixture-secret';ProxyEvents=4;TransientErrors=1}
    [IO.File]::WriteAllText((Join-Path $work 'runtime.json'),($rt|ConvertTo-Json))
    $report=Get-TCRuntimeReport -Root $work;$again=Get-TCRuntimeReport -Root $work
    Check ($report.Current.DurationSeconds -eq 3600 -and $report.Current.Guard.State -eq 'Unknown' -and $report.Current.TradeExit.Source -eq 'Unavailable') 'raw runtime never proves observed exit or guard health'
    Check (@(Get-TCRuntimeEvents -Root $work -SessionId 'terminal-fixture').Count -eq 1) 'terminal fault persists without repeated fault events'
    Check (-not ($report|ConvertTo-Json -Depth 20).Contains('fixture-secret')) 'raw runtime errors never leak to report'
    $overview=[pscustomobject]@{Running=$true;StateKey='Connected';Exit='hk';Daily='provider2';DesiredDaily='Provider';Connections=18;GuardState='Protected';GuardSummary='fixture observed protection';ForeignTunnel=$null}
    $observed=Get-TCRuntimeReport -Root $work -Overview $overview
    Check ($observed.Current.TradeExit.Source -eq 'ControllerSelector' -and -not $observed.Current.TradeExit.Verified -and $observed.Current.Connections.Source -eq 'Controller' -and $observed.Current.Connections.Value -eq 18) 'selection and public exit evidence are distinguished'
    Check ($observed.Current.DailyExit.Value -eq 'provider2' -and $observed.Current.DailyExit.Configured -eq 'Provider') 'effective daily selection and intent are distinct'
    $rt.State='Running';$rt.SessionId='observer-fixture';$rt.ManifestPath='C:\Fixture\manifest.json';$rt.Remove('FinishedAt');[IO.File]::WriteAllText((Join-Path $work 'runtime.json'),($rt|ConvertTo-Json))
    $overview|Add-Member NoteProperty ConnectedSince $rt.EngineStartedAt;$overview|Add-Member NoteProperty ManifestPath $rt.ManifestPath;$overview|Add-Member NoteProperty Mode 'rule'
    $first=Observe-TCRuntimeState -Root $work -Overview $overview;$repeat=Observe-TCRuntimeState -Root $work -Overview $overview
    Check ($first.EventsAdded -eq 4 -and $repeat.EventsAdded -eq 0) 'observer persists typed baseline and deduplicates repeated snapshots'
    $overview.Exit='provider2-trade';$overview.Mode='global';$overview.GuardState='Unprotected';$changes=Observe-TCRuntimeState -Root $work -Overview $overview
    Check ($changes.EventsAdded -eq 3 -and @(Get-TCRuntimeEvents -Root $work -SessionId 'observer-fixture'|Where-Object {$_.Source -eq 'RuntimeObserver'}).Count -eq 7) 'exit/mode/guard changes are persisted with observer source'
    $overview.ConnectedSince='2026-10-08T03:00:00Z';$stale=Observe-TCRuntimeState -Root $work -Overview $overview
    Check (-not $stale.Observed -and $stale.Reason -eq 'StaleOrUnboundObservation') 'old overview cannot bind to a replacement runtime session'
    $bad=Join-Path $work 'tamper';$null=[IO.Directory]::CreateDirectory($bad)
    [IO.File]::WriteAllText((Join-Path $bad 'runtime-events.json'),' {"SchemaVersion":1,"Events":[{"Id":"00000000000000000000000000000000","SessionId":"safe","AtUtc":"2026-10-08T01:00:00Z","Type":"SessionFault","Data":{"Password":"fixture-secret"}}]}')
    Reject {Get-TCRuntimeEvents -Root $bad} 'tampered arbitrary journal fields refused'
    Check (-not (Get-TCRuntimeReport -Root $bad).SummaryText.Contains('fixture-secret')) 'corrupt journal remains untouched and is not exported'
    $logDir=Join-Path $work 'logs';$null=[IO.Directory]::CreateDirectory($logDir);$legacy=Join-Path $logDir 'channel-existing.err.log';[IO.File]::WriteAllText($legacy,'original user log')
    # One deliberately long unterminated line on each stream exercises bounded
    # chunk draining and rotation while the fixture remains alive.
    $code="for(`$i=0;`$i -lt 100;`$i++){[Console]::Out.Write(('A'*8192));[Console]::Error.Write(('B'*8192))};[Threading.Thread]::Sleep(60000)"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code));$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $child=Start-TCBoundedEngineProcess -Root $work -Executable $exe -Arguments ('-NoProfile -NonInteractive -EncodedCommand '+$encoded) -SessionId 'long-running-fixture' -MaxBytes 16384
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while(-not [IO.File]::Exists($child.LogPath+'.2') -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    Check (-not $child.HasExited -and [IO.File]::Exists($child.LogPath+'.2')) 'current long-running process rotates before exit or restart'
    $files=@(Get-ChildItem -LiteralPath $logDir -File -Filter 'bounded-channel-*');Check ($files.Count -ge 1 -and $files.Count -le 3 -and @($files|Where-Object {$_.Length -gt 16384}).Count -eq 0 -and ($files|Measure-Object Length -Sum).Sum -le 49152) 'both streams and unbroken long lines stay within disk budget'
    Check ([IO.File]::ReadAllText($legacy) -ceq 'original user log') 'preexisting user logs remain unchanged'
    $child.Kill();$null=$child.WaitForExit(5000);Check (-not $child.CollectionError) 'bounded collector drains both streams without collection error';$child.Dispose();$child=$null
    for($i=0;$i -lt 4;$i++){
        $quick=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::Out.Write("fixture")'))
        $child=Start-TCBoundedEngineProcess -Root $work -Executable $exe -Arguments ('-NoProfile -NonInteractive -EncodedCommand '+$quick) -SessionId ('retention-'+$i) -MaxBytes 16384
        $null=$child.WaitForExit(5000);$child.Dispose();$child=$null
    }
    Check (@(Get-ChildItem -LiteralPath $logDir -File -Filter 'bounded-channel-*.log').Count -eq 4 -and (Test-Path -LiteralPath $legacy)) 'only collector-owned sessions are pruned to four sessions'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;FixtureProcessesOnly=$true;CurrentLogBoundVerified=$true;ExistingLogsUntouched=$true}
}finally{
    if($child){if(-not $child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-RuntimeObservability-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
