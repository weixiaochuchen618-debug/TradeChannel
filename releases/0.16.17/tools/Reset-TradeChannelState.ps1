#requires -Version 5.1
# Default is read-only. Repair uses only the product's identified disconnect.
[CmdletBinding()]
param([string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'),[switch]$Repair,[switch]$ClearProviders)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Maintenance.psm1') -Force -DisableNameChecking
if($ClearProviders -and -not $Repair){throw '清除服务商偏好需显式指定 -Repair；默认仅诊断。'}
if($Repair){Repair-TCClientState -Root $Root -ClearProviders:$ClearProviders}else{Get-TCMaintenanceReport -Root $Root}
