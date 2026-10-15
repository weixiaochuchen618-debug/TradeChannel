#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $package 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $package 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $package 'DeploymentFlow.psm1') -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-TaskLease-'+[guid]::NewGuid().ToString('N'));$count=0
function Check {param([bool]$Pass,[string]$Message)if(-not $Pass){throw $Message};$script:count++}
function Reject {param([scriptblock]$Body,[string]$Message)$caught=$false;try{$null=& $Body}catch{$caught=$true};Check $caught $Message}
try{
 $s=Set-TCServerRecord -Root $root -Connection @{Host='192.0.2.50';Port=22;User='root';IdentityFile=''} -Name 'Fixture'
 $run=New-TCDeploymentRun -Root $root -ServerId $s.LocalRecordId -Name 'Fixture' -ClientInspection @{NinjaTraderPaths=@();DirectDnsIPv4=@('1.1.1.1')}
 $session=[pscustomobject]@{RunId=$run.RunId;InstanceId=[guid]::NewGuid().ToString('D')}
 $lease=Open-TCServerTaskLease -Root $root -ServerId $s.LocalRecordId
 try{
  Reject {Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $session} 'Direct attach cannot pass a held server lease'
  Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Save} 'Direct advance cannot pass a held server lease'
  Reject {Sync-TCDeploymentRun -Root $root -RunId $run.RunId} 'Direct poll cannot pass a held server lease'
 }finally{$lease.Dispose()}
 $dir=Join-Path (Join-Path (Join-Path $root 'deployments') 'runs') $run.RunId
 $held=Open-TCDLock (Join-Path $dir '.run.lock')
 try{Reject {Sync-TCDeploymentRun -Root $root -RunId $run.RunId} 'Run-lock failure is reported'}finally{$held.Dispose()}
 $lease=Open-TCServerTaskLease -Root $root -ServerId $s.LocalRecordId;$lease.Dispose();Check $true 'Run-lock failure releases the earlier server lease'
 $r=Sync-TCDeploymentRun -Root $root -RunId $run.RunId
 Check ($r.RunId -ceq $run.RunId -and $r.Stage -eq 'PrepareAccess') 'Idle direct poll acquires and releases its own leases without a remote action'
 $before=(Get-FileHash -LiteralPath (Join-Path $dir 'state.json')).Hash
 $registryPath=Join-Path $root 'servers\registry.json';$registry=Read-TCDJson $registryPath
 $registry.Servers[0]|Add-Member NoteProperty RecordState 'Archived' -Force;Write-TCDJson $registryPath $registry
 Reject {Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $session} 'Archived direct attach remains blocked'
 Reject {Invoke-TCDeploymentAdvance -Root $root -RunId $run.RunId -Command Save} 'Archived direct advance remains blocked'
 Reject {Sync-TCDeploymentRun -Root $root -RunId $run.RunId} 'Archived direct poll remains blocked'
 Check ((Get-FileHash -LiteralPath (Join-Path $dir 'state.json')).Hash -ceq $before) 'Archive guard failures preserve task bytes'
 [pscustomobject]@{Passed=$true;Checks=$count;ServerOperations=0;NetworkChanges=0}|ConvertTo-Json
}finally{
 $full=[IO.Path]::GetFullPath($root);$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($full) -ine $parent -or [IO.Path]::GetFileName($full) -notmatch '^TC-TaskLease-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
