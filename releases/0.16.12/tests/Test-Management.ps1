#requires -Version 5.1
# All OS/client/controller mutations are mocked. Native actions are pubkey/check
# against generated configurations; no real profile, job or network is edited.
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $package 'ProviderBridge.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-Management-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param($Ok,$Label)if(-not $Ok){throw ('Management regression: '+$Label)};$script:Checks++}
function Reject {param([scriptblock]$Body,$Label)$failed=$false;try{$null=& $Body}catch{$failed=$true};Check $failed $Label}
try {
 & $module {
  $script:TestLive=$false
  function script:Get-TCProviderRuntimeOverview {[pscustomobject]@{Running=$script:TestLive;StateKey=$(if($script:TestLive){'Connected'}else{'Disconnected'});Daily='provider2';Exit='hk'}}
  function script:Find-TCProviderCandidates {@()}
 }
 $a=Join-Path $work 'ClientA';$b=Join-Path $work 'ClientB';$null=[IO.Directory]::CreateDirectory($a);$null=[IO.Directory]::CreateDirectory($b)
 $aExe=Join-Path $a 'client.exe';$bExe=Join-Path $b 'client.exe';[IO.File]::WriteAllText($aExe,'inert');[IO.File]::WriteAllText($bExe,'inert')
 $one=Register-TCProviderProfile -Request ([pscustomobject]@{Kind='custom';Name='Old BatVPN';Directory=$a;DailyPort=12081;TradePort=$null}) -Root $work
 [IO.File]::Delete($aExe)
 $two=Register-TCProviderProfile -Request ([pscustomobject]@{Kind='custom';Name='Current client';Directory=$b;DailyPort=12083;TradePort=$null}) -Root $work
 Check ($two.Registered) 'can add a valid client while an old profile has missing files'
 $selection=Select-TCImportProviders -Root $work -SkipUnavailable
 Check ($selection.Providers.Count -eq 1 -and $selection.Providers[0].id -eq $two.Id -and $selection.Warnings.Count -eq 1) 'auto import skips only unavailable profile with warning'
 Reject {Select-TCImportProviders -Root $work} 'manual inclusion rejects stale profile with actionable error'
 $count=& $module {param($r) @(Read-TCProviderStore (Join-Path $r 'Product')).Providers.Count} $work
 Check ($count -eq 2) 'candidate filtering does not delete source profiles'
 # Import a real new candidate with the selected valid profile.
 $nodeModule=Import-Module (Join-Path $package 'NodeStore.psm1') -PassThru -DisableNameChecking
 $wg=Join-Path $package 'assets\wg.exe';$engine=Join-Path $package 'assets\sing-box.exe'
 $private=(& $wg genkey).Trim();$serverPrivate=(& $wg genkey).Trim()
 $pub=& $nodeModule {param($p,$k)Invoke-TCNative -FilePath $p -ArgumentList @('pubkey') -InputText $k} $wg $serverPrivate
 $conf=Join-Path $work 'client.conf';$program=Join-Path $work 'NinjaTrader.exe';[IO.File]::WriteAllText($program,'inert')
 [IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.99.0.2/24`n[Peer]`nPublicKey = $($pub.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`n"),(New-Object Text.UTF8Encoding($false)))
 $node=Import-TCWireGuard -Root (Join-Path $work 'Product') -Path $conf -Name 'Resume import' -EnginePath $engine -WgPath $wg -TradeProgramPaths @($program) -DirectDnsIPv4 '192.168.100.1' -Providers $selection.Providers
 Check ($node.manifestPath -and (Test-Path -LiteralPath $node.manifestPath)) 'stale BatVPN scenario completes real candidate import'
 $prefs=Join-Path $work 'ui-preferences.json';[IO.File]::WriteAllText($prefs,(@{ProviderId=$one.Id;TradeProviderId=$one.Id;Daily='Provider';Exit='Provider';NodeId=$node.id}|ConvertTo-Json))
 $removed=Remove-TCProviderProfile -Root $work -Id $one.Id
 $after=Get-Content -LiteralPath $prefs -Raw|ConvertFrom-Json
 Check ($removed.Removed -and -not $after.ProviderId -and -not $after.TradeProviderId -and (Test-Path $a)) 'remove only profile and corresponding intent; client directory kept'
 $c=Join-Path $work 'ClientC';$null=[IO.Directory]::CreateDirectory($c);[IO.File]::WriteAllText((Join-Path $c 'client.exe'),'inert')
 $updated=Update-TCProviderProfile -Request ([pscustomobject]@{Id=$two.Id;Name='Edited';Directory=$c;DailyPort=12083;TradePort=$null;RefreshPaths=$false}) -Root $work
 Check ($updated.Updated -and $updated.Id -eq $two.Id) 'editing preserves identity and slot'
 & $module {$script:TestLive=$true}
 Reject {Remove-TCProviderProfile -Root $work -Id $two.Id} 'active provider cannot be removed'
 & $module {$script:TestLive=$false}
 Import-Module (Join-Path $package 'ManagementStore.psm1') -Force
 $domains=Set-TCTradeDomainManagement -Root $work -Operation Add -Domain 'https://trade.example.com/quote'
 Check ($domains.Domains -contains 'trade.example.com' -and $domains.NetworkChanged -eq $false) 'domain saved and normalized without runtime change'
 $domains=Set-TCTradeDomainManagement -Root $work -Operation Remove -Domain 'trade.example.com'
 Check ($domains.Domains -notcontains 'trade.example.com') 'domain removed from saved list'
 $null=Set-TCTradeDomainManagement -Root $work -Operation Reset
 $linux=Import-Module (Join-Path $package 'LinuxServerSetup.psm1') -Force -PassThru -DisableNameChecking
 $jobs=Join-Path $work 'linux-jobs';$id=[guid]::NewGuid().ToString('D');$dir=Join-Path $jobs $id
 & $linux {param($r,$d)New-TCLinuxDirectory $r;New-TCLinuxDirectory $d} $jobs $dir
 $keyFile=Join-Path $dir 'client.key';[IO.File]::WriteAllText($keyFile,'fixture-private-state')
 & $linux {param($p)Protect-TCLinuxPath $p;$script:ManageStatus='Completed';function script:Get-TCLinuxJob {param($Id,$Root)[pscustomobject]@{JobId=$Id;Status=$script:ManageStatus}}} $keyFile
 $result=& $linux {param($r,$j)Set-TCLinuxJobArchived $r $j $true} $jobs $id
 Check ($result.Archived -and (Test-Path $keyFile)) 'archiving preserves private state'
 $result=& $linux {param($r,$j)Set-TCLinuxJobArchived $r $j $false} $jobs $id
 Check (-not $result.Archived) 'archive restore is reversible'
 & $linux {$script:ManageStatus='Running'}
 Reject {& $linux {param($r,$j)Set-TCLinuxJobArchived $r $j $true} $jobs $id} 'running job cannot be archived'
 [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;SourceProfilesPreserved=$true;StaleProviderImportReproducedAndFixed=$true}
}finally{
 Remove-Module ProviderBridge,NodeStore,LinuxServerSetup,ManagementStore -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
 if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-Management-[0-9a-f]{32}$'){throw 'Cleanup rejected.'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
