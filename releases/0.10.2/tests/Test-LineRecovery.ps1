#requires -Version 5.1
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'LineRecovery.psm1') -Force -DisableNameChecking
$checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw $Label};$script:checks++}
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck @{ExitHttp=$true;ObservedIP='1.1.1.1'}
# The real bridge returns a PSCustomObject, not untyped remote JSON maps.
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck ([pscustomobject]@{ExitHttp=$true;ObservedIP='1.1.1.1'})
Check ($r.Code -eq 'ActiveForwardingPassed' -and -not $r.CanPrepareTcp) 'working UDP is not classified as requiring TCP'
$r=Get-TCRecoveryDecision -ActiveTarget $true -ActiveCheck ([pscustomobject]@{ExitHttp=$true;ObservedIP=$null})
Check ($r.Code -eq 'ActiveForwardingUnverified') 'HTTP success without exit trace does not claim verified forwarding'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ActiveIdentity'})
Check ($r.Code -eq 'IdentityInUse' -and -not $r.NetworkChanged) 'active peer is not probed concurrently'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ForwardingPassedPhysicalPathUnverified'})
Check ($r.Code -eq 'CandidateForwardingPassed' -and $r.Summary -like '*物理*') 'candidate forwarding and switched physical route remain distinct'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='ExpectedExitUnverified';ObservedExitIPv4='1.1.1.1';Checks=@([pscustomobject]@{Name='AddressHttps';Status='Passed'},[pscustomobject]@{Name='DomainDnsHttps';Status='Passed'})})
Check ($r.Code -eq 'CandidateForwardingPassed' -and $r.Summary -like '*归属*未核验*') 'successful forwarding is not hidden when authoritative egress identity is unavailable'
$r=Get-TCRecoveryDecision -ActiveTarget $false -CandidateCheck ([pscustomobject]@{Code='CandidateForwardingFailed'})
Check ($r.Code -eq 'ForwardingNotVerified' -and $r.Summary -like '*不能证明 UDP*') 'timeout does not claim UDP blocking'
# Check that actual exit validation retries the network check without calling
# any mutation. Fake reader scripts and module function replacements are scoped
# to this disposable test and never execute a production channel command.
$work=Join-Path ([IO.Path]::GetTempPath()) ('TC-LineReadiness-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $work 'runtime') -Force
$reader=@'
param([string]$Url='https://1.1.1.1/cdn-cgi/trace',[string]$Lane='Trade')
if($Url -like '*1.1.1.1*'){[pscustomobject]@{CurlExit=28;HTTPStatus=0;ObservedIP=$null}}
elseif($Url -like '*cloudflare*'){[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP='1.1.1.1'}}
else{[pscustomobject]@{CurlExit=0;HTTPStatus=200;ObservedIP=$null}}
'@
[IO.File]::WriteAllText((Join-Path $work 'runtime\Test-SelectedTradeExit.ps1'),$reader,[Text.Encoding]::UTF8)
$module=Import-Module (Join-Path $root 'RuntimeBridge.psm1') -Force -PassThru -DisableNameChecking
try{
 $result=& $module {
  param($Fixture)
  $script:Package=$Fixture
  function script:Get-TCOverview {[pscustomobject]@{Running=$true;DailySupported=$false;Mode='rule';Daily='direct';AgentsSupported=$false;Agents='Daily'}}
  function script:Get-TCInstalledDeployment {$null}
  function script:Get-TCExitLatency {$null}
  function script:Invoke-TCCommand {throw 'readiness must not change network'}
  Test-TCActiveConnection
 } $work
 Check ($result.ExitHttp -and $result.ObservedIP -eq '1.1.1.1' -and $result.ExitChecks.Count -eq 2) 'cold connection timeout retries another trusted trace and preserves evidence'
 Check ($result.TradingViewHttp -and $result.Control -eq '通过') 'exit retry still checks the application target'
 [pscustomobject]@{Passed=$true;Checks=$checks;RealNetworkChanges=0}|ConvertTo-Json -Compress
}finally{
 Remove-Module RuntimeBridge -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-LineReadiness-[a-f0-9]{32}$'){throw 'Unexpected fixture cleanup boundary.'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
