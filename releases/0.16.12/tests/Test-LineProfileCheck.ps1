#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent};$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$module=Import-Module (Join-Path $PackageRoot 'LineConnectionCheck.psm1') -PassThru -Force -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-line-check-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($root)
try{
 $result=& $module {
  param($FixtureRoot,$Package)
  $script:CheckRoot=$FixtureRoot;$script:CheckPackage=$Package;$script:Assertions=0;$script:Calls=New-Object 'Collections.Generic.List[object]'
  function script:Check {param($ok,$name)if(-not $ok){throw $name};$script:Assertions++}
  function script:Import-Module {param([string]$Name,[switch]$DisableNameChecking)
   if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Name)) -cne [IO.Path]::GetFullPath($script:CheckPackage) -or [IO.Path]::GetFileName($Name) -notin @('LineStore.psm1','RuntimeBridge.psm1','CandidateProbe.psm1','ProtocolSelection.psm1')){throw 'Unknown actor module'}
  }
  function script:Get-TCLine {param($Root,$Id)
   if($Root -cne $script:CheckRoot -or $Id -cne $script:Line.LineId){throw 'Fixture line escaped its exact target'}
   if($script:Changed){$script:Line.Revision++};return ($script:Line|ConvertTo-Json -Depth 20|ConvertFrom-Json)
  }
  function script:Get-TCOverview {$script:Runtime}
  function script:Test-TCActiveConnection {$script:Calls.Add(@{Kind='Active';LineId=$script:Runtime.ActiveLineId;ProfileId=$script:Runtime.ActiveProfileId});[pscustomobject]@{Status='Passed';Code='ForwardingPassed';ForwardingPassed=$true;Time=[DateTimeOffset]::UtcNow.ToString('o')}}
  function script:Test-TCCandidateProbe {param($Root,$NodeId,$ProfileId,$TimeoutSeconds,$ExpectedExitIPv4,$ExpectedExitSource)
   if($Root -cne $script:CheckRoot -or $NodeId -cne $script:Line.LineId -or $TimeoutSeconds -ne 45){throw 'Candidate escaped bounded exact fixture'}
   $script:Calls.Add(@{Kind='Candidate';LineId=$NodeId;ProfileId=$ProfileId});$script:Changed=$script:InjectChange
   [pscustomobject]@{Status='Passed';Code='CandidateReachabilityVerified';ForwardingPassed=$true;NetworkFingerprint=('A'*64)}
  }
  function script:ConvertTo-TCProtocolEvidence {param($Result,$Profile,$NetworkContext)[pscustomobject]@{Status=$Result.Status;CandidateSHA256=$Profile.CandidateSHA256;ForwardingPassed=$true}}
  function script:Set-TCLineProfileValidation {param($Root,$Id,$ProfileId,$Validation,$ExpectedRevision)
   if($Root -cne $script:CheckRoot -or $Id -cne $script:Line.LineId -or $ExpectedRevision -ne $script:Line.Revision){throw 'Validation escaped target or CAS revision'}
   $script:Calls.Add(@{Kind='Persist';LineId=$Id;ProfileId=$ProfileId;ExpectedRevision=$ExpectedRevision})
  }
  foreach($actor in @('Start-Process','Stop-Process','Get-Process','Invoke-TCController','Invoke-WebRequest','Invoke-RestMethod','Invoke-TCCommand','Set-TCLinePreferredProfile')){Set-Item ('Function:script:'+$actor) {throw 'Forbidden production or preference actor'}}
  $script:Line=[pscustomobject]@{LineId='fixture-B';Revision=8;Profiles=@([pscustomobject]@{Id='Udp';PreparationState='Ready';CandidateSHA256=('B'*64);Validation=$null},[pscustomobject]@{Id='Tcp';PreparationState='Ready';CandidateSHA256=('C'*64);Validation=$null});ServerConnectionBlock=''}
  $script:Runtime=[pscustomobject]@{Running=$true;ActiveLineId='fixture-B';ActiveProfileId='Tcp';SessionId='fixture-session';ConfigHash=('C'*64)}
  $script:Changed=$false;$script:InjectChange=$false
  $r=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Tcp -ExpectedRevision 8
  Check ($r.Check.LineId -ceq 'fixture-B' -and $r.Check.ProfileId -ceq 'Tcp' -and $r.Check.SessionId -ceq 'fixture-session' -and $script:Calls.Count -eq 1 -and $script:Calls[0].Kind -eq 'Active') 'active result is exactly bound to current target/session'
  $r=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 8
  Check ($r.Code -eq 'ActiveIdentityInUse' -and $script:Calls.Count -eq 1) 'other protocol on same active identity blocks parallel probe'
  $script:Runtime.ActiveLineId='fixture-A';$r=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 8
  Check ($r.ProfileId -ceq 'Udp' -and $script:Calls[1].Kind -eq 'Candidate' -and $script:Calls[1].LineId -ceq 'fixture-B' -and $script:Calls[2].Kind -eq 'Persist' -and $script:Calls[2].ProfileId -ceq 'Udp') 'other line uses one selected candidate and persists only its evidence'
  $before=$script:Calls.Count;$script:Line.ServerConnectionBlock='HostKeyChanged';$r=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 8
  Check ($r.Code -eq 'ServerBindingChanged' -and $script:Calls.Count -eq $before) 'server conflict invokes no network or persistence actor'
  $script:Line.ServerConnectionBlock='';$script:Line.Profiles[0].PreparationState='Missing';$r=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 8
  Check ($r.Code -eq 'ProfileConfigurationMissing' -and $script:Calls.Count -eq $before) 'missing protocol invokes no actor'
  $script:Line.Profiles[0].PreparationState='Ready';$rejected=$false;try{$null=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 7}catch{$rejected=$_.Exception.Message -like '*LineRevisionChanged*'}
  Check ($rejected -and $script:Calls.Count -eq $before) 'stale card version rejects before a probe'
  $script:InjectChange=$true;$rejected=$false;try{$null=Invoke-TCLineProfileCheck -Root $FixtureRoot -Id fixture-B -ProfileId Udp -ExpectedRevision 8}catch{$rejected=$_.Exception.Message -like '*LineRevisionChanged*'}
  Check ($rejected -and @($script:Calls|Where-Object Kind -eq Persist).Count -eq 1) 'change during probe cannot persist a late result'
  [pscustomobject]@{Passed=$true;Assertions=$script:Assertions;ActualActionExercised=$true;CapturedActors=@($script:Calls.ToArray());FixtureRoot=$FixtureRoot;ProductionActorsCalled=$false}
 } $root $PackageRoot
 if($ReportPath){$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Depth 8
}finally{Remove-Module LineConnectionCheck -ErrorAction SilentlyContinue;$full=[IO.Path]::GetFullPath($root);if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^tc-line-check-[a-f0-9]{32}$'){throw 'Cleanup boundary rejected'};Remove-Item -LiteralPath $full -Recurse -Force}
