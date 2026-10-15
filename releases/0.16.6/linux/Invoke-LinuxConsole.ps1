#requires -Version 5.1
<# This entry point is launched visibly, only by a user-triggered LinuxStart.
   Never pass passwords, payloads or scripts in argv. Authentication belongs to
   System32 OpenSSH's attached console. Closing the window is detected by Poll. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Id, [Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = Join-Path $PSHOME 'Modules'

function Test-TCLinuxInteractiveTerminal {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) }
    catch { return $false }
}

function Wait-TCLinuxFailureClose {
    # This is a close-window acknowledgement after a terminal result, never an
    # authentication prompt. Redirected/noninteractive callers must not block.
    if (Test-TCLinuxInteractiveTerminal) { $null = Read-Host '读取上方错误后，按回车关闭' }
}

try {
    $module = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'LinuxServerSetup.psm1') -Force -PassThru -DisableNameChecking
    $result = & $module { param($Id,$Root) Invoke-TCLinuxConsoleJob -Id $Id -Root $Root } $Id $Root
    Write-Host $result.Message
    if ($result.Status -ne 'Completed') {
        Write-Host ('错误类别：' + $result.ErrorCode)
        Write-Host ('阶段：{0}；退出码：{1}' -f $result.Stage,$(if ($null -eq $result.ExitCode) { '尚未取得' } else { [string]$result.ExitCode }))
        Wait-TCLinuxFailureClose
        exit 1
    }
    exit 0
} catch {
    # Failure before the runner can publish is detected by the poller's PID +
    # creation-time check. Never print raw errors, source, keys or SSH stdout.
    Write-Host '认证控制台未能完成初始化。请回到向导查询任务状态。'
    Wait-TCLinuxFailureClose
    exit 1
}
