#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10,600)][int]$Seconds=90,
    [ValidateRange(1,10)][int]$IntervalSeconds=2,
    [string]$ReportDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'reports')
)
# Bounded metadata-only sampling. Does not inspect payloads, account data or credentials.
$ErrorActionPreference='Stop'
$seen=@{}
$processHistory=@{}
$udpSeen=@{}
$started=Get-Date
$deadline=$started.AddSeconds($Seconds)
$samples=0
do {
    $now=(Get-Date).ToString('o')
    $all=@(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath)
    $family=@($all|Where-Object {$_.Name -eq 'NinjaTrader.exe'})
    $ids=@($family|ForEach-Object{[int]$_.ProcessId})
    do {
        $children=@($all|Where-Object {[int]$_.ParentProcessId -in $ids -and [int]$_.ProcessId -notin $ids})
        $family+=$children
        $ids+=@($children|ForEach-Object{[int]$_.ProcessId})
    }while($children.Count)
    foreach($p in $family){$processHistory[[string]$p.ProcessId]=$p}
    if($ids.Count){
        foreach($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue|Where-Object {$_.OwningProcess -in $ids})){
            $key=@($c.OwningProcess,$c.LocalAddress,$c.LocalPort,$c.RemoteAddress,$c.RemotePort,[string]$c.State) -join '|'
            if($seen.ContainsKey($key)){$seen[$key].LastSeen=$now;$seen[$key].Samples++}
            else{$seen[$key]=[pscustomobject]@{FirstSeen=$now;LastSeen=$now;Samples=1;ProcessId=$c.OwningProcess;LocalAddress=$c.LocalAddress;LocalPort=$c.LocalPort;RemoteAddress=$c.RemoteAddress;RemotePort=$c.RemotePort;State=[string]$c.State}}
        }
        foreach($c in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue|Where-Object {$_.OwningProcess -in $ids})){
            $key=@($c.OwningProcess,$c.LocalAddress,$c.LocalPort) -join '|'
            $udpSeen[$key]=[pscustomobject]@{LastSeen=$now;ProcessId=$c.OwningProcess;LocalAddress=$c.LocalAddress;LocalPort=$c.LocalPort}
        }
    }
    $samples++
    if((Get-Date) -lt $deadline){Start-Sleep -Seconds $IntervalSeconds}
}while((Get-Date) -lt $deadline)
$report=[ordered]@{
    StartedAt=$started.ToString('o');EndedAt=(Get-Date).ToString('o');Samples=$samples
    Processes=@($processHistory.Values|Sort-Object ProcessId)
    TCP=@($seen.Values|Sort-Object FirstSeen,ProcessId)
    UDPLocalEndpoints=@($udpSeen.Values|Sort-Object ProcessId,LocalPort)
    Limitations=@('Polling can miss very short-lived connections.','UDP remote destinations require separate scoped tracing.','Connection observations alone do not prove the egress IP or order delivery.')
}
$null=New-Item -ItemType Directory -Path $ReportDirectory -Force
$out=Join-Path $ReportDirectory ('ninjatrader-connections-'+$started.ToString('yyyyMMdd-HHmmss')+'.json')
[IO.File]::WriteAllText($out,($report|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))
[pscustomobject]@{Report=$out;Processes=$processHistory.Count;TCPSnapshots=$seen.Count;UDPLocalEndpoints=$udpSeen.Count;DurationSeconds=[int]((Get-Date)-$started).TotalSeconds}
