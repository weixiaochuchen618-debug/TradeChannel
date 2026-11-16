#requires -Version 5.1
# Journal transforms are verified entirely in memory. All module I/O helpers throw.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent
$line=Import-Module (Join-Path $package 'LineQuality.psm1') -Force -PassThru -DisableNameChecking
$standby=Import-Module (Join-Path $package 'StandbyQuality.psm1') -Force -PassThru -DisableNameChecking
$script:Checks=0
function Check { param([bool]$Ok,[string]$Label) if (-not $Ok) { throw ('QualityOwnedState check failed: '+$Label) }; $script:Checks++ }
function Json { param($Value) ConvertTo-Json -InputObject $Value -Depth 12 -Compress }
$now=[DateTimeOffset]'2026-10-16T10:00:00Z'
$a='11111111-1111-1111-1111-111111111111'; $b='22222222-2222-2222-2222-222222222222'; $c='33333333-3333-3333-3333-333333333333'
$overview=[pscustomobject]@{Running=$true;StateKey='Connected';SessionId='owned-state';ActiveLineId=$a;ActiveProfileId='Udp';ProfileBindingVerified=$true;Exit='hk';ConfigHash=('A'*64);EnginePid=1234;ConnectedSince=$now.AddDays(-1).ToString('o');ManifestPath='C:\fixture\manifest.json';Mode='rule';ObservedAt=$now.ToString('o')}
try {
    foreach ($m in @($line,$standby)) {
        $bytes=[IO.File]::ReadAllBytes($m.Path); Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('module BOM '+$m.Name)
    }
    $tokens=$null; $errors=$null; $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0) 'PowerShell parser'
    & $line {
        function script:LQPath { throw 'Pure transform attempted path I/O.' }
        function script:LQReadJson { throw 'Pure transform attempted JSON I/O.' }
        function script:LQReadState { throw 'Pure transform attempted store read.' }
        function script:LQWriteState { throw 'Pure transform attempted store write.' }
        function script:LQOpenStore { throw 'Pure transform attempted lock.' }
        function script:LQNow { throw 'Pure transform attempted wall-clock retention.' }
    }
    & $standby {
        function script:SQPath { throw 'Pure transform attempted path I/O.' }
        function script:SQReadState { throw 'Pure transform attempted store read.' }
        function script:SQWriteState { throw 'Pure transform attempted store write.' }
        function script:SQOpenStore { throw 'Pure transform attempted lock.' }
        function script:SQNow { throw 'Pure transform attempted clock.' }
    }
    $state=& $line { LQNewState }; $context=Get-TCLineQualityContext $overview $now
    $state.BindingKey=$context.Key; $state.Binding=$context.Binding; $state.LastAttemptAtUtc=$now.ToString('o'); $state.BadCount=4; $state.AlertLatched=$true
    $state.LastAlert=[pscustomobject]@{Id=('b'*32);AtUtc=$now.ToString('o');Reason='ConsecutiveHighLatency';Message='当前交易出口连续 3 次延迟较高，请检查线路；当前线路保持。'}
    $state.Samples=@([pscustomobject]@{AtUtc=$now.ToString('o');LatencyMs=600;Quality='Poor';Reason='Measured';Source='ControllerDelay'})
    foreach ($id in @($b,$c)) {
        $overview.ActiveLineId=$id; $otherContext=Get-TCLineQualityContext $overview $now
        $state.ArchivedSeries+=,[pscustomobject]@{SeriesId=[guid]::NewGuid().ToString('N');BindingKey=$otherContext.Key;Binding=$otherContext.Binding;Samples=@([pscustomobject]@{AtUtc=$now.AddHours(-2).ToString('o');LatencyMs=80;Quality='Good';Reason='Measured';Source='ControllerDelay'})}
    }
    $original=Json $state
    $none=Remove-TCLineQualityOwnedState -State $state -NodeId '44444444-4444-4444-4444-444444444444'
    Check (-not $none.Changed -and (Json $none.Value) -ceq $original -and (Json $state) -ceq $original) 'non-owner leaves schema, revision and input unchanged'
    $change=Remove-TCLineQualityOwnedState -State $state -NodeId $b
    Check ($change.Changed -and $change.Value.ArchivedSeries.Count -eq 1 -and $change.Value.ArchivedSeries[0].Binding.NodeId -eq $c -and $change.Value.Binding.NodeId -eq $a) 'delete one archived owner preserves active and unrelated history'
    Check ($change.Value.Revision -cne $state.Revision -and $change.Value.BadCount -eq 4 -and $change.Value.AlertLatched -and (Json $state) -ceq $original) 'revision changes while unrelated active alert and immutable input are preserved'
    $active=Remove-TCLineQualityOwnedState -State $state -NodeId $a
    Check ($active.Changed -and $active.Value.ArchivedSeries.Count -eq 2 -and -not $active.Value.BindingKey -and $null -eq $active.Value.Binding -and $active.Value.Samples.Count -eq 0) 'active owner removed without erasing unrelated archives'
    Check ($active.Value.BadCount -eq 0 -and $active.Value.RecoveryCount -eq 0 -and -not $active.Value.AlertLatched -and $null -eq $active.Value.LastAlert -and $null -eq $active.Value.LastAttemptAtUtc) 'active deletion clears notifications and debounce reservation'
    $family=Remove-TCLineQualityOwnedState -State $state -NodeId @($a,$b)
    Check ($family.Value.ArchivedSeries.Count -eq 1 -and $family.Value.ArchivedSeries[0].Binding.NodeId -eq $c) 'multi-ID family removes exactly its owned series'
    $repeat=Remove-TCLineQualityOwnedState -State $state -NodeId @($b.ToUpperInvariant(),$a,$b)
    Check ((Json $family) -ceq (Json $repeat)) 'preview and commit produce identical revisions, series IDs and values for normalized ID sets'
    $all=Remove-TCLineQualityOwnedState -State $state -NodeId @($c,$b,$a)
    Check ($all.Changed -and $all.Empty -and $all.Value.ArchivedSeries.Count -eq 0 -and -not $all.Value.BindingKey) 'empty shared line cache may be journal-deleted only after all owners are removed'
    $legacy=ConvertFrom-Json -InputObject $original; $legacy.SchemaVersion=1; $legacy.PSObject.Properties.Remove('SeriesId'); $legacy.PSObject.Properties.Remove('ArchivedSeries'); $legacyBefore=Json $legacy
    $upgrade=Remove-TCLineQualityOwnedState -State $legacy -NodeId $a
    Check ($upgrade.Changed -and $upgrade.Value.SchemaVersion -eq 2 -and $upgrade.Value.Revision -cne $legacy.Revision -and (Json $legacy) -ceq $legacyBefore) 'legacy Schema 1 cleanup upgrades a copy and invalidates late reservations'
    $minimal=[pscustomobject]@{SchemaVersion=1;Owner='TradeChannel.LineQuality';Binding=@{NodeId=$a};Revision=('a'*32);Samples=@()}
    $removed=Remove-TCLineQualityOwnedState -State $minimal -NodeId $a
    Check ($removed.Changed -and $removed.Empty -and $removed.Value.SchemaVersion -eq 2) 'legacy single-owner minimal cache can still be removed'
    $repeat=Remove-TCLineQualityOwnedState -State $minimal -NodeId $a
    Check ((Json $removed) -ceq (Json $repeat)) 'legacy empty replacement is deterministic'
    Check (-not (Remove-TCLineQualityOwnedState -State $minimal -NodeId $b).Changed) 'minimal legacy cache owned by another line is preserved'
    $empty=Remove-TCLineQualityOwnedState -State $state -NodeId @(); Check (-not $empty.Changed) 'empty ownership list cannot mean delete all'

    $overview.ActiveLineId=$a; $context=Get-TCLineQualityContext $overview $now; $sq=& $standby { SQNewState }
    $sq.Binding=$context.Binding; $sq.BindingKey=$context.Key; $sq.CandidateSetKey=('d'*64); $sq.LastAttemptAtUtc=$now.ToString('o')
    foreach ($id in @($b,$c)) {
        $target=& $standby { param($id) SQCandidate @{NodeId=$id;ProfileId='Tcp';Exit='hk';Host='127.0.0.1';Port=443;ConfigHash=('C'*64)} } $id
        $sq.Entries+=,[pscustomobject]@{CandidateKey=$target.Key;Binding=$target.Binding;LastAttemptAtUtc=$now.ToString('o');AtUtc=$now.ToString('o');LatencyMs=45;Source='TcpConnect';Reason='Measured'}
    }
    $original=Json $sq
    $none=Remove-TCStandbyQualityOwnedState -State $sq -NodeId '44444444-4444-4444-4444-444444444444'
    Check (-not $none.Changed -and (Json $none.Value) -ceq $original) 'non-owned standby state remains byte-equivalent'
    $change=Remove-TCStandbyQualityOwnedState -State $sq -NodeId $b
    Check ($change.Changed -and $change.Value.Entries.Count -eq 1 -and $change.Value.Entries[0].Binding.NodeId -eq $c -and $change.Value.BindingKey -ceq $context.Key) 'standby targeted deletion preserves unrelated entry and active context'
    Check ($change.Value.Revision -cne $sq.Revision -and (Json $sq) -ceq $original) 'standby journal transform changes revision without touching input'
    $active=Remove-TCStandbyQualityOwnedState -State $sq -NodeId $a
    Check ($active.Changed -and $active.Value.Entries.Count -eq 2 -and -not $active.Value.BindingKey -and $null -eq $active.Value.LastAttemptAtUtc) 'deleting observation owner retains other entries but invalidates their live recommendation context'
    $null=& $standby { param($value) SQNormalizeState $value } $active.Value
    $view=& $standby { param($value,$context,$now) SQSummary $value $context @() $now $true } $active.Value $context $now
    Check ($null -eq $view.Recommendation -and $view.Reason -eq 'BindingChanged') 'unbound retained entries cannot produce a recommendation'
    $family=Remove-TCStandbyQualityOwnedState -State $sq -NodeId @($a,$b)
    Check ($family.Value.Entries.Count -eq 1 -and $family.Value.Entries[0].Binding.NodeId -eq $c -and -not $family.Value.BindingKey) 'family cleanup preserves unrelated standby entry'
    $repeat=Remove-TCStandbyQualityOwnedState -State $sq -NodeId @($b,$a.ToUpperInvariant(),$b)
    Check ((Json $family) -ceq (Json $repeat)) 'standby preview and commit replacement digest is deterministic'
    $all=Remove-TCStandbyQualityOwnedState -State $sq -NodeId @($c,$a,$b)
    Check ($all.Empty -and $all.Changed -and $all.Value.Entries.Count -eq 0) 'standby cache reports Empty only when no ownership remains'
    foreach ($pair in @(@('LineQuality',$state),@('StandbyQuality',$sq))) {
        $foreign=ConvertFrom-Json -InputObject (Json $pair[1]); $foreign.Owner='SomeoneElse'; $rejected=$false
        try { if ($pair[0] -eq 'LineQuality') { $null=Remove-TCLineQualityOwnedState -State $foreign -NodeId $a } else { $null=Remove-TCStandbyQualityOwnedState -State $foreign -NodeId $b } } catch { $rejected=$true }
        Check $rejected ('foreign '+$pair[0]+' state cannot authorize removal')
    }
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;PowerShellVersion=$PSVersionTable.PSVersion.ToString();StoreReads=0;StoreWrites=0;LockAcquisitions=0;NetworkChanges=0}
} finally { Remove-Module $standby,$line -ErrorAction SilentlyContinue }
