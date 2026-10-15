#requires -Version 5.1
[CmdletBinding()]
param()
# Explicit rollback: remove this project's trading blocks only after NinjaTrader exits.
$ErrorActionPreference='Stop'
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run in an elevated PowerShell.'}
if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw 'Close NinjaTrader before removing its channel protection.'}
& (Join-Path $PSScriptRoot 'Invoke-TradeChannel.ps1') -Action Emergency
Add-Type -Path (Join-Path $PSScriptRoot 'TradeChannelGuard.cs')
$deleted=[TradeChannelGuard]::RemovePersistentBlocks()
$status=[TradeChannelGuard]::GetStatus()
if($status.ProviderPresent -or $status.Filters.Count){throw 'Project protection removal was not verified.'}
$statePath='C:\ProgramData\TradeChannel\runtime.json'
if(Test-Path -LiteralPath $statePath){$state=Get-Content -LiteralPath $statePath -Encoding UTF8 -Raw|ConvertFrom-Json;$state.State='RolledBack';$state.TradingDirectAccessBlocked=$false;[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
Write-Output ('Removed project filters: '+$deleted)
Write-Output 'NinjaTrader can now use the ordinary network. The original WireGuard export and GUI tunnel were preserved.'
