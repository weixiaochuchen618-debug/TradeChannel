#requires -Version 5.1
# Regression: a stopped session with an unfinished teardown must not deadlock the
# connection gate. The gate resolves the cleanup (idempotent) instead of refusing
# forever, and still refuses when the cleanup cannot be verified or needs a choice.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$script:failures=0
function Check {param([bool]$Condition,[string]$Name) if(-not $Condition){$script:failures++;Write-Host ('FAIL '+$Name) -ForegroundColor Red}else{Write-Host ('ok   '+$Name)}}
$module=Import-Module (Join-Path $root 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking -Force
& $module {
    param($Config)
    $script:CleanupTest=$Config
    $script:TestAdapter={
        param($Operation,$DataRoot,$Payload)
        $script:CleanupTest.Calls.Add($Operation)
        switch($Operation){
            'Observe'{return [pscustomobject]@{State=$script:CleanupTest.State;OwnershipKnown=$script:CleanupTest.OwnershipKnown;CleanupPending=$script:CleanupTest.Pending;SessionId='fixture';ManifestPath='fixture'}}
            'ResolveCleanup'{return [pscustomobject]@{Resolved=$script:CleanupTest.Resolved;NeedsChoice=$script:CleanupTest.NeedsChoice;Message=$script:CleanupTest.Message}}
            default{throw ('unexpected runtime operation '+$Operation)}
        }
    }
} ([pscustomobject]@{State='Stopped';OwnershipKnown=$true;Pending=$false;Resolved=$true;NeedsChoice=$false;Message='';Calls=(New-Object 'System.Collections.Generic.List[string]')})
function Assert-Calls {param($Config,[string[]]$Expected,[string]$Name)
    Check (($Config.Calls -join ',') -ceq ($Expected -join ',')) ($Name+' (calls: '+($Config.Calls -join ',')+')')
}
function Invoke-Gate {param($Config)
    & $module {param($C) $script:CleanupTest.Calls.Clear();try{CTAssertStopped 'fixture'|Out-Null;''}catch{$_.Exception.Message}} $Config
}
$cfg=$null
# 1. Normal stopped session: no cleanup work, single observation.
$cfg=& $module {param($State,$Known,$Pending,$Resolved,$Choice,$Message) $script:CleanupTest.State=$State;$script:CleanupTest.OwnershipKnown=$Known;$script:CleanupTest.Pending=$Pending;$script:CleanupTest.Resolved=$Resolved;$script:CleanupTest.NeedsChoice=$Choice;$script:CleanupTest.Message=$Message;$script:CleanupTest} 'Stopped' $true $false $true $false ''
& $module {param($C) $script:CleanupTest.Calls.Clear()} $cfg
$err=Invoke-Gate $cfg
Check (-not $err) 'stopped session without pending cleanup passes'
Assert-Calls $cfg @('Observe') 'no cleanup call without the flag'

# 2. Stopped + pending cleanup that resolves: gate clears it and re-observes.
$cfg=& $module {param($State,$Known,$Pending,$Resolved,$Choice,$Message) $script:CleanupTest.State=$State;$script:CleanupTest.OwnershipKnown=$Known;$script:CleanupTest.Pending=$Pending;$script:CleanupTest.Resolved=$Resolved;$script:CleanupTest.NeedsChoice=$Choice;$script:CleanupTest.Message=$Message;$script:CleanupTest} 'Stopped' $true $true $true $false ''
$err=Invoke-Gate $cfg
Check (-not $err) ('pending cleanup resolves instead of blocking: '+$err)
Assert-Calls $cfg @('Observe','ResolveCleanup','Observe') 'cleanup runs once and state is re-read'

# 3. Pending cleanup that needs a user choice: actionable, not a loop.
$cfg=& $module {param($State,$Known,$Pending,$Resolved,$Choice,$Message) $script:CleanupTest.State=$State;$script:CleanupTest.OwnershipKnown=$Known;$script:CleanupTest.Pending=$Pending;$script:CleanupTest.Resolved=$Resolved;$script:CleanupTest.NeedsChoice=$Choice;$script:CleanupTest.Message=$Message;$script:CleanupTest} 'Stopped' $true $true $false $true ''
$err=Invoke-Gate $cfg
Check ($err -like '*CleanupChoiceRequired*') ('conflicting proxy needs a choice: '+$err)

# 4. Pending cleanup that cannot be verified: the original guard still applies.
$cfg=& $module {param($State,$Known,$Pending,$Resolved,$Choice,$Message) $script:CleanupTest.State=$State;$script:CleanupTest.OwnershipKnown=$Known;$script:CleanupTest.Pending=$Pending;$script:CleanupTest.Resolved=$Resolved;$script:CleanupTest.NeedsChoice=$Choice;$script:CleanupTest.Message=$Message;$script:CleanupTest} 'Stopped' $true $true $false $false '清理未完成。'
$err=Invoke-Gate $cfg
Check ($err -like '*NeedsRecovery*' -and $err -like '*清理未完成*') ('unverifiable cleanup keeps the guard: '+$err)

# 5. Unknown ownership is never rescued by cleanup.
$cfg=& $module {param($State,$Known,$Pending,$Resolved,$Choice,$Message) $script:CleanupTest.State=$State;$script:CleanupTest.OwnershipKnown=$Known;$script:CleanupTest.Pending=$Pending;$script:CleanupTest.Resolved=$Resolved;$script:CleanupTest.NeedsChoice=$Choice;$script:CleanupTest.Message=$Message;$script:CleanupTest} 'Unknown' $false $true $true $false ''
$err=Invoke-Gate $cfg
Check ($err -like '*NeedsRecovery*') ('unknown ownership still refuses: '+$err)
Assert-Calls $cfg @('Observe') 'no cleanup attempted when ownership is unknown'

# 6. Empty reconciliation is not success.
$rows=@()
$resolved=($rows.Count -gt 0 -and @($rows|Where-Object Status -notin @('Completed','RolledBack','ResolvedStopped','Aborted')).Count -eq 0)
Check (-not $resolved) 'zero reconciled rows never reports resolved'
$rows=@([pscustomobject]@{Status='Completed'})
$resolved=($rows.Count -gt 0 -and @($rows|Where-Object Status -notin @('Completed','RolledBack','ResolvedStopped','Aborted')).Count -eq 0)
Check $resolved 'completed rows report resolved'

if($script:failures){throw ($script:failures.ToString()+' cleanup gate checks failed')}
Write-Host 'All cleanup gate checks passed.' -ForegroundColor Green
