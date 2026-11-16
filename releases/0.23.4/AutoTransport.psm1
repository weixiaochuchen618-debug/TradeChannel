#requires -Version 5.1
Set-StrictMode -Version 2

# Compatibility facade. Root is the data root. LineStore owns offline validation
# and immutable profile publication; no legacy node/index/runtime writes here.
# TransportInfo must be an authenticated transport_info envelope. No SSH here.
$script:TCAutoLines = Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -PassThru -DisableNameChecking

function Get-TCTransportPreparation {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    & $script:TCAutoLines {param($Root,$Id)
        & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Preparation' $null '' $null $script:TCLineWg
    } $Root $Id
}
function Get-TCSavedTransportInfo {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    # Secret-bearing compatibility envelope: pass to preparation, never log/UI.
    & $script:TCAutoLines {param($Root,$Id)
        & $script:TCLineNodes $script:TCLineImplementation $Root $Id 'Saved' $null '' $null $script:TCLineWg
    } $Root $Id
}
function New-TCAutomaticTransportCandidate {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[Parameter(Mandatory=$true)]$TransportInfo)
    Prepare-TCTcpLineProfile -Root $Root -Id $Id -TransportInfo $TransportInfo
}
Export-ModuleMember -Function Get-TCTransportPreparation,Get-TCSavedTransportInfo,New-TCAutomaticTransportCandidate
