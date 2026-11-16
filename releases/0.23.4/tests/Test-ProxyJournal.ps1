#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\TradeChannel.ProxyJournal.ps1')
$checks=0
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$script:checks++}
$before=[pscustomobject]@{ProxyEnable=@{Exists=$true;Value=1;Kind='DWord'};ProxyServer=@{Exists=$true;Value='127.0.0.1:8001';Kind='String'};AutoConfigURL=@{Exists=$false;Value=$null;Kind=$null}}
$expected=$before|ConvertTo-Json -Depth 8|ConvertFrom-Json;$expected.ProxyEnable.Value=0
$entry=[pscustomobject]@{SchemaVersion=1;UserSid='fixture';Stage='Pending';Before=($before|ConvertTo-Json -Depth 8|ConvertFrom-Json);Expected=$expected}
foreach($stage in @('Pending','Applied')){$entry.Stage=$stage;Check ((Get-TCProxyRecoveryDecision $entry $expected $true 'fixture') -eq 'Restore') 'Crash after write must recover';Check ((Get-TCProxyRecoveryDecision $entry $entry.Before $true 'fixture') -eq 'AlreadyRestored') 'Crash before write must be a no-op'}
Check ((Get-TCProxyRecoveryDecision $entry $expected $false 'fixture') -eq 'SessionAlive') 'A live session must never be restored'
Check ((Get-TCProxyRecoveryDecision $entry $expected $true 'different') -eq 'DifferentUser') 'Different user settings must not be restored'
$changed=$expected|ConvertTo-Json -Depth 8|ConvertFrom-Json;$changed.ProxyServer.Value='127.0.0.1:9001'
Check ((Get-TCProxyRecoveryDecision $entry $changed $true 'fixture') -eq 'Conflict') 'Later user choice must be preserved'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('tc-proxy-journal-'+[guid]::NewGuid().ToString('N'))
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeploymentStore.psm1') -DisableNameChecking
function Get-TCProxyValueSnapshot {return ($script:Registry|ConvertTo-Json -Depth 8|ConvertFrom-Json)}
function Set-TCProxyValueSnapshot {param($Snapshot,$Names)
 if($script:Crash -eq 'BeforeChange'){throw 'fixture power loss before registry write'}
 foreach($name in $Names){$script:Registry.$name=$Snapshot.$name}
 if($script:Crash -eq 'AfterChange'){throw 'fixture power loss after registry write'}
}
function Test-TCProxyJournalOwnerEnded {param($Entry)return $true}
try{
 foreach($crash in @('BeforeChange','AfterChange','Applied')){
  $root=Join-Path $fixture $crash;$script:Registry=$before|ConvertTo-Json -Depth 8|ConvertFrom-Json;$original=Get-TCDDigest $script:Registry;$script:Crash=$crash
  try{$null=Set-TCProxyJournaledValue -Root $root -SessionId $crash -Name ProxyEnable -Value 0}catch{if($crash -eq 'Applied'){throw}}
  $script:Crash='';$null=Restore-TCProxyJournal -Root $root
  Check ((Get-TCDDigest $script:Registry) -ceq $original) ('durable '+$crash+' crash recovers exactly')
  Check (@(Get-TCProxyRecoveryStatus $root).Count -eq 0) 'completed restore no longer prompts'
 }
 $root=Join-Path $fixture 'multi';$script:Registry=$before|ConvertTo-Json -Depth 8|ConvertFrom-Json;$script:Registry.AutoConfigURL=@{Exists=$true;Value='http://fixture.invalid/pac';Kind='String'};$original=Get-TCDDigest $script:Registry
 $null=Set-TCProxyJournaledValue $root 'multi' ProxyEnable 0
 $null=Set-TCProxyJournaledValue $root 'multi' AutoConfigURL -Remove
 $null=Restore-TCProxyJournal -Root $root
 Check ((Get-TCDDigest $script:Registry) -ceq $original) 'PAC and manual proxy restore in reverse write order'
 $root=Join-Path $fixture 'conflict';$script:Registry=$before|ConvertTo-Json -Depth 8|ConvertFrom-Json
 $null=Set-TCProxyJournaledValue $root 'conflict' ProxyEnable 0;$script:Registry.ProxyServer.Value='127.0.0.1:9999'
 $later=Get-TCDDigest $script:Registry;$r=Restore-TCProxyJournal -Root $root
 Check ($r.Conflicts -eq 1 -and (Get-TCDDigest $script:Registry) -ceq $later) 'external edit remains unchanged and surfaces a conflict'
 $preview=Invoke-TCProxyRecoveryChoice $root 'conflict' RestorePrevious
 $script:Registry.ProxyServer.Value='127.0.0.1:9998'
 $rejected=$false;try{$null=Invoke-TCProxyRecoveryChoice $root 'conflict' RestorePrevious $preview.PreviewToken}catch{$rejected=$true}
 Check $rejected 'changed settings invalidate an explicit restore preview'
 $preview=Invoke-TCProxyRecoveryChoice $root 'conflict' KeepCurrent
 $null=Invoke-TCProxyRecoveryChoice $root 'conflict' KeepCurrent $preview.PreviewToken
 Check ($script:Registry.ProxyServer.Value -eq '127.0.0.1:9998' -and @(Get-TCProxyRecoveryStatus $root).Count -eq 0) 'keep current resolves reminder without changing any registry value'
}finally{
 $full=[IO.Path]::GetFullPath($fixture)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-proxy-journal-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
[pscustomobject]@{Passed=$true;Checks=$checks;RegistryWrites=0}|ConvertTo-Json -Compress
