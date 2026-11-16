#requires -Version 5.1
# Compatibility entrypoint. Automatic completion now belongs to the backend,
# after verified reachability, rather than a UI-only prepared-files shortcut.
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Test-AvailableProtocolCompletion.ps1') -PackageRoot $PackageRoot -ReportPath $ReportPath
