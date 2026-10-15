#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Prepare','Apply','Recover','Status','Watchdog')][string]$Action,[string]$PlanPath,[string]$Package,[string]$RollbackArchive,[int]$OwnerId,[long]$OwnerTicks)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $PSScriptRoot 'TradeChannel.Maintenance.psm1') -Force -DisableNameChecking
$result=switch($Action){
    'Prepare' {
        $workspace=Split-Path $PSScriptRoot -Parent
        if(-not $Package){$Package=Join-Path $workspace 'product'}
        if(-not $RollbackArchive){$RollbackArchive=Join-Path $workspace 'dist\TradeChannel-0.6.0-windows-x64-preview.zip'}
        New-TCMPlan -Package $Package -RollbackArchive $RollbackArchive
    }
    'Apply' {Invoke-TCMMaintenance -PlanPath $PlanPath}
    'Recover' {Invoke-TCMMaintenance -PlanPath $PlanPath -Recover}
    'Status' {Get-TCMState -PlanPath $PlanPath}
    'Watchdog' {Watch-TCMMaintenance -PlanPath $PlanPath -OwnerId $OwnerId -OwnerTicks $OwnerTicks}
}
$result|ConvertTo-Json -Depth 10
