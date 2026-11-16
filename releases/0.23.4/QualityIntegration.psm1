#requires -Version 5.1
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'StandbyQuality.psm1') -DisableNameChecking
$script:QILine=Import-Module (Join-Path $PSScriptRoot 'LineQuality.psm1') -PassThru -DisableNameChecking
$script:QIPaths=Import-Module (Join-Path $PSScriptRoot 'ProbePath.psm1') -PassThru -DisableNameChecking
$script:QINodes=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking

<#
Trusted worker boundary. Both exports require an explicit DATA Root and a
verified current Overview. No request-supplied targets or callbacks. Only owned
prepared Tcp profiles are read. Keys, UUIDs, credentials and raw documents never
enter output/cache. Active runtime is checked against Root before/after probing.
Physical path comes from ProbePath; StandbyQuality binds source + interface.

Discovery has an 8-second admission deadline checked around bounded file reads
and synchronous local inventory APIs, plus a 16-target cap. The Worker process
limit bounds blocking inventory APIs. TCP retains its 4-second total budget.
Full network snapshots are compared across probing; durable target fingerprints
include physical path, default-route selection and unknown virtual networks.
Private readers/factories are test seams only, never public parameters.
#>
function QIField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function QIDigest {param($Value)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 12 -Compress))))).Replace('-','').ToUpperInvariant()}finally{$sha.Dispose()}
}
function QIRoot {param([string]$Root)
 if($Root -notmatch '^[A-Za-z]:[\\/]' -or $Root.Substring(2) -match '[:*?"<>|\x00-\x1f]'){throw '[TC:QualityRoot] 需要显式的本机数据根目录。'}
 $full=[IO.Path]::GetFullPath($Root).TrimEnd('\');if($full.Length -le 3){throw '[TC:QualityRoot] 需要独立数据目录。'}
 & $script:QINodes {param($p) Assert-TCNoReparse $p} $full
 return $full
}
function QIPath {param([string]$Root,[string]$Path)
 if($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2) -match '[:*?"<>|\x00-\x1f]'){throw 'Invalid owned path.'}
 $full=[IO.Path]::GetFullPath($Path)
 # Containment precedes filesystem inspection, including reparse checks.
 if(-not $full.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Profile outside explicit root.'}
 & $script:QINodes {param($p) Assert-TCNoReparse $p} $full
 return $full
}
function QIReadVerifiedJson {param([string]$Root,[string]$Path,[string]$ExpectedHash,[int]$MaxBytes)
 if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Invalid profile hash.'}
 $full=QIPath $Root $Path;$stream=$null;$sha=$null
 try{
  $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  if($stream.Length -gt $MaxBytes){throw 'Bounded profile size exceeded.'}
  $bytes=New-Object byte[] ([int]$stream.Length);$offset=0
  while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -le 0){throw 'Profile changed.'};$offset+=$read}
  if($stream.ReadByte() -ne -1){throw 'Profile changed.'}
  $sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
  if($hash -ine $ExpectedHash){throw 'Profile changed.'}
  $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes).TrimStart([char]0xfeff)
  ConvertFrom-Json -InputObject $text -ErrorAction Stop
 }finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
}
function QIActiveContext {param([string]$Root,$Overview)
 $context=Get-TCLineQualityContext $Overview
 if(-not $context.Eligible){return $context}
 try{$null=QIPath $Root ([string]$context.Binding.ManifestPath);$null=& $script:QILine {param($r,$c) LQRuntimeConfig $r $c} $Root $context}
 catch{$context.Eligible=$false;$context.Reason='BindingChanged'}
 return $context
}
function Get-TCQualityNetwork {
 & $script:QIPaths {
  $network=Get-TCProbeNetworkContext;if($network.Status -cne 'Available'){return $null}
  $choice=Get-TCProbeDefaultRouteSelection $network;if($choice.Status -cne 'Ready'){return $null}
  $interfaces=@($network.Interfaces|Where-Object {$_.Index -eq $choice.InterfaceIndex -and $_.Id -ceq $choice.Route.InterfaceId -and $_.Hardware -and $_.Status -ceq 'Up' -and $_.Type -ne 'Loopback'})
  if($interfaces.Count -ne 1){return $null}
  $addresses=@($interfaces[0].Addresses|Where-Object {$_.Family -ceq 'InterNetwork' -and $_.State -ceq 'Preferred'})
  if($addresses.Count -ne 1){return $null}
  [pscustomobject]@{Network=$network;Interface=$interfaces[0];LocalAddress=$addresses[0].Address;DefaultRouteFingerprint=$choice.Fingerprint;EnvironmentGuardFingerprint=(Get-TCProbeEnvironmentGuard $network)}
 }
}
function Get-TCQualityCards {param([Parameter(Mandatory=$true)][string]$Root) @(Get-TCLineCards -Root $Root)}
function Get-TCQualityProfile {param([Parameter(Mandatory=$true)][string]$Root,[string]$LineId) Get-TCLineProfile -Root $Root -Id $LineId -ProfileId Tcp}
function QICreateUnderlay {param($Outer,$Network)
 $binding=& $script:QIPaths {param($o,$n) New-TCProbeBinding $o $n.Interface $n.Network $n.LocalAddress '1.1.1.1'} $Outer $Network
 if(-not $binding -or $binding.Scope -cne 'BoundPhysicalIPv4.v1'){throw 'Physical underlay unavailable.'}
 [pscustomobject][ordered]@{InterfaceIndex=[int]$binding.InterfaceIndex;LocalAddress=[string]$binding.LocalAddress;InterfaceId=[string]$binding.InterfaceId;NetworkFingerprint=(QIDigest ([ordered]@{Scope='StandbyPhysicalPath.v1';Underlay=$binding.UnderlayFingerprint;Environment=$Network.EnvironmentGuardFingerprint;DefaultRoute=$Network.DefaultRouteFingerprint}))}
}
function Get-TCQualityTarget {param([Parameter(Mandatory=$true)][string]$Root,$Card,$Profile,$Network)
 if(-not $Network){return $null}
 $line=[guid]::Empty;$source=[guid]::Empty
 if(-not [guid]::TryParse([string](QIField $Card LineId ''),[ref]$line) -or $line -eq [guid]::Empty -or (QIField $Profile Id '') -cne 'Tcp' -or (QIField $Profile Mode '') -cne 'Tcp' -or (QIField $Profile PreparationState '') -cnotin @('Ready','SyntaxValidated','Prepared')){return $null}
 $lineId=$line.ToString();$path=QIPath $Root ([string](QIField $Profile ManifestPath ''))
 $immutableBase=Join-Path $Root ('Product\lines\'+$lineId+'\profiles');$immutable=$path.StartsWith($immutableBase+'\',[StringComparison]::OrdinalIgnoreCase)
 if(-not $immutable){
  if(-not [guid]::TryParse([string](QIField $Profile SourceNodeId ''),[ref]$source) -or $source -eq [guid]::Empty){return $null}
  if($source.ToString() -ine $lineId -and $source.ToString() -notin @(QIField $Card AliasIds @())){return $null}
  $legacyBase=Join-Path $Root ('Product\nodes\'+$source.ToString());if(-not $path.StartsWith($legacyBase+'\',[StringComparison]::OrdinalIgnoreCase)){return $null}
 }
 $manifestHash=[string](QIField $Profile ManifestSHA256 '');$configHash=[string](QIField $Profile CandidateSHA256 '')
 $manifest=QIReadVerifiedJson $Root $path $manifestHash 1048576
 $owner=[string](QIField $manifest TCLineId '');$profileOwner=[string](QIField $manifest TCProfileId '')
 $allowedOwners=@($lineId);if(-not $immutable){$allowedOwners+=,$source.ToString()}
 if(($immutable -and ($owner -ine $lineId -or $profileOwner -cne 'Tcp')) -or ($owner -and $owner -notin $allowedOwners) -or ($profileOwner -and $profileOwner -cne 'Tcp') -or (QIField $manifest CandidateSHA256 '') -ine $configHash){return $null}
 $candidate=QIPath $Root ([string](QIField $manifest CandidatePath ''))
 if(-not $candidate.StartsWith((Split-Path $path -Parent)+'\',[StringComparison]::OrdinalIgnoreCase)){return $null}
 $config=QIReadVerifiedJson $Root $candidate $configHash 4194304
 $outer=& $script:QIPaths {param($cfg) Get-TCProbeOuter $cfg} $config;$ip=$null
 if($outer.Protocol -cne 'Tcp' -or -not [Net.IPAddress]::TryParse($outer.Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $outer.Port -lt 1 -or $outer.Port -gt 65535){return $null}
 $underlay=QICreateUnderlay $outer $Network
 $null=QIPath $Root $path;$null=QIPath $Root $candidate
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $manifestHash -or (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $configHash){return $null}
 [pscustomobject][ordered]@{NodeId=$lineId;ProfileId='Tcp';Exit='hk';Host=$ip.ToString();Port=[int]$outer.Port;ConfigHash=$configHash.ToUpperInvariant();Enabled=$true;Underlay=$underlay}
}
function QIResolve {param([string]$Root,$Overview)
 $watch=[Diagnostics.Stopwatch]::StartNew();$targets=New-Object 'Collections.Generic.List[object]'
 $result=[pscustomobject]@{Complete=$false;Reason='TargetsUnavailable';Targets=@();ProofKey='';BindingKey='';ResolutionBudgetMs=8000}
 try{
  $context=QIActiveContext $Root $Overview;$result.BindingKey=$context.Key
  if(-not $context.Eligible){$result.Reason=$context.Reason;return $result}
  $network=Get-TCQualityNetwork;if(-not $network){$result.Reason='UnderlayUnavailable';return $result}
  $cards=@(Get-TCQualityCards $Root);$counts=@{}
  foreach($card in $cards){$id=[string](QIField $card LineId '');if(-not $counts.ContainsKey($id)){$counts[$id]=0};$counts[$id]++}
  foreach($card in @($cards|Sort-Object LineId)){
   if($watch.ElapsedMilliseconds -gt 8000){$result.Reason='TargetResolutionTimeout';return $result};if($targets.Count -ge 16){break}
   $id=[string](QIField $card LineId '')
   if(-not $id -or $counts[$id] -ne 1 -or $id -ieq $context.Binding.NodeId -or $context.Binding.NodeId -in @(QIField $card AliasIds @()) -or (QIField $card ServerConnectionBlock '')){continue}
   $profiles=@((QIField $card Profiles @())|Where-Object {(QIField $_ Id '') -ceq 'Tcp' -and (QIField $_ PreparationState '') -in @('Ready','SyntaxValidated','Prepared')})
   if($profiles.Count -ne 1){continue}
   try{
    $profile=Get-TCQualityProfile -Root $Root -LineId $id
    foreach($field in @('ManifestSHA256','CandidateSHA256','ManifestPath','SourceNodeId','Revision')){if([string](QIField $profile $field '') -ine [string](QIField $profiles[0] $field '')){throw 'Profile discovery changed.'}}
    $target=Get-TCQualityTarget -Root $Root -Card $card -Profile $profile -Network $network;if($target){$targets.Add($target)}
   }catch{}
  }
  if($watch.ElapsedMilliseconds -gt 8000){$result.Reason='TargetResolutionTimeout';return $result}
  $end=QIActiveContext $Root $Overview;if(-not $end.Eligible -or $end.Key -cne $context.Key){$result.Reason='BindingChanged';return $result}
  $result.Targets=$targets.ToArray();$result.Complete=$true;$result.Reason=if($targets.Count){'Available'}else{'NoEligibleCandidates'}
  $result.ProofKey=QIDigest ([ordered]@{BindingKey=$context.Key;Targets=$result.Targets;NetworkSnapshot=$network.Network.SnapshotFingerprint})
 }catch{$result.Reason='TargetsUnavailable'}
 return $result
}
function Get-TCStandbyTargets {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,$Overview)
 $rootPath=QIRoot $Root;$resolved=QIResolve $rootPath $Overview;if($resolved.Complete){$resolved.Targets}
}
function Invoke-TCStandbyObservation {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,$Overview)
 $rootPath=QIRoot $Root;$before=QIResolve $rootPath $Overview
 if(-not $before.Complete){
  $null=Clear-TCStandbyQuality -Root $rootPath
  $view=Get-TCStandbyQualitySummary -Root $rootPath -Overview $Overview -Candidates @();$view.Reason=$before.Reason;return $view
 }
 $measured=Invoke-TCStandbyQualitySample -Root $rootPath -Overview $Overview -Candidates $before.Targets
 $after=QIResolve $rootPath $Overview
 if(-not $after.Complete -or $after.ProofKey -cne $before.ProofKey -or $measured.Reason -in @('BindingChanged','StoreBusy','StoreUnavailable')){
  # Never repair a failed post-check by fetching an older cached success.
  if(-not $after.Complete -or $after.BindingKey -cne $before.BindingKey){$null=Clear-TCStandbyQuality -Root $rootPath}
  else{
   $changed=@($before.Targets|Where-Object {$old=$_;-not @($after.Targets|Where-Object {(QIDigest $_) -ceq (QIDigest $old)}).Count}|ForEach-Object NodeId)
   if(-not $changed.Count){$changed=@($before.Targets|ForEach-Object NodeId)}
   if($changed.Count){$null=Clear-TCStandbyQuality -Root $rootPath -NodeId $changed}
  }
  $view=Get-TCStandbyQualitySummary -Root $rootPath -Overview $Overview -Candidates @()
  $view.Reason=if(-not $after.Complete){$after.Reason}elseif($measured.Reason -in @('StoreBusy','StoreUnavailable')){$measured.Reason}else{'BindingChanged'}
  $view.Sampled=$measured.Sampled;$view.AttemptedCount=$measured.AttemptedCount;return $view
 }
 $result=Get-TCStandbyQualitySummary -Root $rootPath -Overview $Overview -Candidates $after.Targets
 $result.Sampled=$measured.Sampled;$result.AttemptedCount=$measured.AttemptedCount;return $result
}
Export-ModuleMember -Function Invoke-TCStandbyObservation,Get-TCStandbyTargets
