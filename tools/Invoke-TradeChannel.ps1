#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Trading','Global','Status','Emergency','HongKong','Provider')][string]$Action)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.State.ps1')
$root='C:\ProgramData\TradeChannel'
$deployment=Join-Path $root 'deployment.json'
$statePath=Join-Path $root 'runtime.json'
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this command in an elevated PowerShell.'}
if(-not(Test-Path -LiteralPath $deployment)){throw 'No validated deployment has been selected yet.'}
$d=Get-Content -LiteralPath $deployment -Encoding UTF8 -Raw|ConvertFrom-Json
$m=Get-Content -LiteralPath $d.ManifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
$state=if(Test-Path -LiteralPath $statePath){Read-TradeChannelState -Path $statePath}else{$null}
$running=$false
if($state -and $state.State -eq 'Running'){
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$state.SupervisorPid) -ErrorAction SilentlyContinue
    $engine=Get-Process -Id ([int]$state.EnginePid) -ErrorAction SilentlyContinue
    $running=($owner -and $owner.CommandLine -like '*Run-TradeChannel.ps1*' -and $engine -and $engine.Path -eq $m.EnginePath)
}
if($Action -eq 'Emergency'){
    [IO.File]::WriteAllText((Join-Path $root 'stop.request'),(Get-Date).ToString('o'))
    if($running){
        $deadline=(Get-Date).AddSeconds(15)
        do{
            Start-Sleep -Milliseconds 300
            $state=Read-TradeChannelState -Path $statePath
            if($state.State -ne 'Running' -and $state.State -ne 'Starting'){break}
        }while((Get-Date) -lt $deadline)
        if($state.State -eq 'Running' -or $state.State -eq 'Starting'){throw 'Supervisor did not stop in time; trading firewall remains in place.'}
    }elseif($state -and $state.EnginePid){
        $orphan=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$state.EnginePid) -ErrorAction SilentlyContinue
        if($orphan -and $orphan.ExecutablePath -eq $m.EnginePath -and $orphan.CommandLine.Contains([string]$m.CandidatePath)){
            Stop-Process -Id ([int]$state.EnginePid) -Force
            $state.State='EmergencyStoppedOrphan'
            $state.Error='Supervisor was absent; the identified orphan engine was stopped. Proxy restoration must be checked.'
            [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
            Write-Output 'Stopped the identified orphan channel engine. Persistent trading blocks were not removed.'
        }
    }
    Write-Output 'Emergency stop requested. Trading blocks are retained. Reopen the browser using the ordinary network or your independent backup connection.'
    $state|Select-Object State,TradingDirectAccessBlocked,Error
    return
}
if($Action -eq 'Status'){
    if($running){& (Join-Path $PSScriptRoot 'Set-TradeChannelMode.ps1') -Mode Status -ConfigPath $m.CandidatePath}
    else{[pscustomobject]@{Running=$false;LastState=$(if($state){$state.State}else{'NotStarted'});LastError=$(if($state){$state.Error}else{$null});Protection='Persistent filter state must be queried separately; engine status alone is not proof.'}}
    Add-Type -Path (Join-Path $PSScriptRoot 'TradeChannelGuard.cs')
    $guard=[TradeChannelGuard]::GetStatus()
    [pscustomobject]@{GuardProviderPresent=$guard.ProviderPresent;PersistentBlocks=@($guard.Filters|Where-Object{$_.IsBlock -and $_.IsPersistent}).Count;DynamicTunPermits=@($guard.Filters|Where-Object{$_.IsPermit}).Count;RecognizedFilters=@($guard.Filters|Where-Object{$_.Recognized}).Count}
    return
}
if(-not $running){
    if(-not $m.IndependentGuardVerified){throw 'Complete the independent guard tests before starting the trading channel.'}
    $script=Join-Path $PSScriptRoot 'Run-TradeChannel.ps1'
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'),'-ManifestPath',('"'+$d.ManifestPath+'"'))
    $launcher=Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'logs\supervisor.out.log') -RedirectStandardError (Join-Path $root 'logs\supervisor.err.log')
    $deadline=(Get-Date).AddSeconds(20)
    do{
        if($launcher.HasExited){throw 'Channel supervisor exited; inspect restricted supervisor logs.'}
        if(Test-Path -LiteralPath $statePath){$state=Read-TradeChannelState -Path $statePath|Select-Object -First 1;if($state.SupervisorPid -eq $launcher.Id -and $state.State -eq 'Running'){break}}
        Start-Sleep -Milliseconds 300
    }while((Get-Date) -lt $deadline)
    if(-not $state -or $state.SupervisorPid -ne $launcher.Id -or $state.State -ne 'Running'){throw 'Channel did not reach ready state; do not open NinjaTrader yet.'}
}
if($Action -in @('HongKong','Provider')){& (Join-Path $PSScriptRoot 'Set-TradeChannelExit.ps1') -Exit $Action -ManifestPath $d.ManifestPath}
else{& (Join-Path $PSScriptRoot 'Set-TradeChannelMode.ps1') -Mode $Action -ConfigPath $m.CandidatePath}
