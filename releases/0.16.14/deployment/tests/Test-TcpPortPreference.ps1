#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-port-acceptance-'+[guid]::NewGuid().ToString('N'));$checks=New-Object 'Collections.Generic.List[object]'
try{
 foreach($port in @(8443,2443)){
  $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.72';Port=22;User='root';IdentityFile=''} -TcpPort $port
  $review=& $flow {param($Root,$Run)Set-TCDeploymentReview $Root $Run Deploy @{PlanId=[guid]::NewGuid().ToString()} 'fixture' 'fixture';$Run.Review} $root $run
  $expected=@($port)+@(443,8443,2443|Where-Object {$_ -ne $port})
  if(($review.OptionalTcpPreparation.CandidatePorts -join ',') -cne ($expected -join ',')){throw 'Preferred port ordering lost'}
  $run.ApprovedTransportChoices=$review.OptionalTcpPreparation;$digest=$review.ChangeDigest;$run.Review=$review
  $run.TcpPort=443
  $stored=& $flow {param($Run)Get-TCDeploymentApprovedTransportChoices $Run} $run
  if(($stored.CandidatePorts -join ',') -cne ($expected -join ',') -or $run.Review.ChangeDigest -cne $digest){throw 'Approved choices changed'}
  $checks.Add([pscustomobject]@{Case='Preferred'+$port;ExpectedBehaviorSatisfied=$true;ApprovedCandidatePorts=$stored.CandidatePorts;ApprovalDigestUnchanged=$true})
 }
 $rejected=$false;try{$null=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.73';Port=22;User='root';IdentityFile=''} -TcpPort 1443}catch{$rejected=$_.Exception.Message.StartsWith('[TC:UnsupportedTcpPort]')}
 if(-not $rejected){throw 'Unsupported new port accepted'}
 $checks.Add([pscustomobject]@{Case='New1443Rejected';ExpectedBehaviorSatisfied=$true})
 # Seed an old unsupported draft without rerunning new-input validation.
 $old=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.74';Port=22;User='root';IdentityFile=''};$old.TcpPort=1443
 $old=& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $root $old
 $loaded=Get-TCDeploymentRun -Root $root -RunId $old.RunId
 if($loaded.TcpPort -ne 1443){throw 'Old unsupported value silently changed'}
 $blocked=$false;try{$null=& $flow {param($Root,$Run)Set-TCDeploymentReview $Root $Run Deploy @{} 'fixture' 'fixture'} $root $loaded}catch{$blocked=$_.Exception.Message.StartsWith('[TC:UnsupportedTcpPort]')}
 if(-not $blocked -or $loaded.TcpPort -ne 1443){throw 'Old unsupported draft not preserved and blocked'}
 $oldChoices=& $flow {param($Run)Get-TCDeploymentApprovedTransportChoices $Run} $loaded
 if(($oldChoices.CandidatePorts -join ',') -cne '443,8443,2443'){throw 'Legacy absent choices were expanded from old approval'}
 $checks.Add([pscustomobject]@{Case='LegacyDraftPreserved';ExpectedBehaviorSatisfied=$true;Port=$loaded.TcpPort;OldApprovalChoicesPreserved=$true})
 $report=[pscustomobject]@{Passed=$true;ExpectedMode='Acceptance';Cases=$checks.ToArray();UnexpectedActors=0;ProductionStateTouched=$false;Runtime=$PSVersionTable.PSVersion.ToString()}
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true));$report|ConvertTo-Json -Depth 12
}finally{
 $full=[IO.Path]::GetFullPath($root);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^tc-port-acceptance-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
