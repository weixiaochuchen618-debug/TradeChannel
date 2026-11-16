#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -Force -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-state-size-'+[guid]::NewGuid().ToString('N'));$checks=0
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
try{
 $null=New-TCDDirectory $root;$path=Join-Path $root 'state.json'
 $value=[pscustomobject]@{SchemaVersion=1;History=@(1..600|ForEach-Object {@{Index=$_;AtUtc='2026-10-13T00:00:00Z';Status='Completed'}});Evidence=('x'*3355443);Reference=@{Id='fixture';SHA256=('A'*64)}}
 Write-TCDJson $path $value;$pretty=(Get-Item -LiteralPath $path).Length;$digest=Get-TCDDigest (Read-TCDJson $path)
 Write-TCDJson $path $value -Compact;$compact=(Get-Item -LiteralPath $path).Length
 Check ($compact -lt $pretty -and (Get-TCDDigest (Read-TCDJson $path)) -ceq $digest) 'compact state preserves fields references and canonical digest'
 Check ((Get-TCDStateSize $path).State -eq 'NearLimit') 'near-limit state is diagnosed without reading raw evidence into UI'
 $before=(Get-FileHash -LiteralPath $path).Hash
 try{Write-TCDJson $path @{Evidence=('x'*4194304)} -Compact;throw 'oversize write unexpectedly succeeded'}catch{Check ($_.Exception.Message -like '*DataTooLarge*') 'oversize write has an explicit bounded error'}
 Check ((Get-FileHash -LiteralPath $path).Hash -ceq $before -and (Read-TCDJson $path).History.Count -eq 600) 'rejected write preserves original complete history'
 [pscustomobject]@{Passed=$true;Checks=$checks;PrettyBytes=$pretty;CompactBytes=$compact;LimitBytes=4194304;ProductionWrites=0}|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($root)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-state-size-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
