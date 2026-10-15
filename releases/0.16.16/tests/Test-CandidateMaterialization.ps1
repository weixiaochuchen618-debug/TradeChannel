#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$ReportPath,[string]$PackageRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$package=if($PackageRoot){[IO.Path]::GetFullPath($PackageRoot)}else{Split-Path $PSScriptRoot -Parent}
$parent=[Environment]::GetFolderPath('LocalApplicationData')
$work=Join-Path $parent ('CandidateMaterializationTests-'+[guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $package 'NodeStore.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $package 'WorkerErrors.psm1') -Force -DisableNameChecking
$module=Get-Module NodeStore;$originalRunner=& $module {$script:TCNativeRunner}
$checks=New-Object 'Collections.Generic.List[string]';$failures=New-Object 'Collections.Generic.List[object]'
$flow=$null;$originalSave=$null;$result=$null
function Check {param([bool]$Value,[string]$Label)if(-not $Value){throw ('Candidate materialization check failed: '+$Label)};$checks.Add($Label)}
function Write-Json {param([string]$Path,$Value)[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))}
function Read-Json {param([string]$Path)ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))}
function Set-NativeMode {param([string]$Mode)& $module {param($Mode)$script:TCCandidateMode=$Mode} $Mode}
function Expect-Failure {
 param([scriptblock]$Action,[string]$Code,[string]$Stage,[string]$Field='')
 $caught=$null;try{$null=& $Action}catch{$caught=$_}
 Check ($null -ne $caught) ('failure injected: '+$Code+'/'+$Stage)
 $safe=Get-TCWorkerFailure -Failure $caught -Action DeploymentFlow -Phase Executing
 Check ($safe.Code -ceq $Code -and $safe.FailureContext.Stage -ceq $Stage) ('specific public reason: '+$Code+'/'+$Stage+' observed '+$safe.Code+'/'+$safe.FailureContext.Stage)
 if($Field){Check ($safe.FailureContext.Field -ceq $Field) ('public diagnostic field: '+$Field)}
 $id=Write-TCFailureDiagnostic -Root $work -Failure $caught -Action DeploymentFlow -RunId ([guid]::NewGuid().ToString('D')) -Stage MaterializeCandidate
 Check ($id -cmatch '^[a-f0-9]{32}$') 'failure diagnostic persisted'
 $diagnosticPath=Join-Path $work ('diagnostics\failures\'+$id+'.json')
 $text=[IO.File]::ReadAllText($diagnosticPath,[Text.Encoding]::UTF8)
 $diagnostic=ConvertFrom-Json $text
 Check ($text -notmatch 'CANDIDATE_SECRET_CANARY|BEGIN PRIVATE KEY|do-not-persist' -and ($safe|ConvertTo-Json -Depth 10) -notmatch 'CANDIDATE_SECRET_CANARY|BEGIN PRIVATE KEY|do-not-persist') 'native/parser credential canaries are never published'
 Check ($diagnostic.SchemaVersion -eq 2 -and $diagnostic.FailureContext.Code -ceq $Code -and $diagnostic.FailureContext.Stage -ceq $Stage) 'disk and public structured diagnostic agree'
 $failures.Add([pscustomobject]@{Code=$Code;Stage=$Stage;Field=$diagnostic.FailureContext.Field;NativeExitCode=$diagnostic.FailureContext.NativeExitCode;OriginalFailures=$diagnostic.OriginalFailures;SourceFrames=$diagnostic.SourceFrames})
 return $diagnostic
}
try{
 & $module {param($Directory)New-TCPrivateDirectory $Directory} $work
 & $module {
  $script:TCCandidateOriginalRunner=$script:TCNativeRunner;$script:TCCandidateMode='Real';$script:TCCandidateIndexLock=$null;$script:TCCandidateIndexPath=''
  $script:TCCandidateNativeAudit=New-Object 'Collections.Generic.List[string]'
  $script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)
   if($ArgumentList[0] -notin @('pubkey','check')){throw 'Isolation: only offline pubkey/check are permitted.'}
   $script:TCCandidateNativeAudit.Add([string]$ArgumentList[0])
   $canary='CANDIDATE_SECRET_CANARY password=do-not-persist -----BEGIN PRIVATE KEY-----'
   if($script:TCCandidateMode -eq 'KeyReject' -and $ArgumentList[0] -eq 'pubkey'){return [pscustomobject]@{ExitCode=17;StandardOutput=$canary;StandardError=$canary}}
   $leaf=if($ArgumentList.Count -ge 3){[IO.Path]::GetFileName($ArgumentList[2])}else{''}
   if($script:TCCandidateMode -eq 'CandidateReject' -and $leaf -eq 'dual-mode.json'){return [pscustomobject]@{ExitCode=37;StandardOutput=$canary;StandardError=('parse rule-set: '+$canary)}}
   if($script:TCCandidateMode -eq 'ProbeReject' -and $leaf -eq 'probe.json'){return [pscustomobject]@{ExitCode=43;StandardOutput=$canary;StandardError=$canary}}
   $native=& $script:TCCandidateOriginalRunner -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds
   if($script:TCCandidateMode -eq 'LockCommit' -and $leaf -eq 'probe.json'){$script:TCCandidateIndexLock=[IO.File]::Open($script:TCCandidateIndexPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
   return $native
  }
 }
 $private=[Convert]::ToBase64String([byte[]](1..32));$serverPrivate=[Convert]::ToBase64String([byte[]](33..64))
 $wg=Join-Path $package 'assets\wg.exe';$engine=Join-Path $package 'assets\sing-box.exe'
 $serverResult=& $module {param($Exe,$Key)Invoke-TCNative -FilePath $Exe -ArgumentList @('pubkey') -InputText $Key} $wg $serverPrivate
 $clientResult=& $module {param($Exe,$Key)Invoke-TCNative -FilePath $Exe -ArgumentList @('pubkey') -InputText $Key} $wg $private
 Check ($serverResult.ExitCode -eq 0 -and $clientResult.ExitCode -eq 0) 'disposable keys derive using real wg'
 $serverPublic=$serverResult.StandardOutput.Trim();$clientPublic=$clientResult.StandardOutput.Trim()
 $text="[Interface]`nPrivateKey = {0}`nAddress = 10.77.0.2/32`nDNS = 1.1.1.1`nMTU = 1408`n[Peer]`nPublicKey = {1}`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`nPersistentKeepalive = 25`n" -f $private,$serverPublic
 $source=Join-Path $work '虚拟服务器.conf';[IO.File]::WriteAllText($source,$text,(New-Object Text.UTF8Encoding($false)))
 $seedArgs=@{Root=(Join-Path $work 'seed\Product');Path=$source;Name='模拟香港主线';EnginePath=$engine;WgPath=$wg;DirectDnsIPv4='1.1.1.1'}
 $seed=Import-TCWireGuard @seedArgs
 $root=Join-Path $work '中文 空格路径\第二层\第三层\Product'
 $prior=Register-TCExisting -Root $root -ManifestPath $seed.manifestPath -Name '既有主线引用'
 Check ($prior.kind -ceq 'existing' -and $prior.status -ceq 'Registered') 'existing registered line is preserved as a real index entry'
 $records=@(foreach($slot in @(1,2)){
  $directory=Join-Path $work ('Provider '+$slot+' 安装');$null=[IO.Directory]::CreateDirectory($directory)
  $program=Join-Path $directory 'client.exe';[IO.File]::WriteAllBytes($program,[byte[]]@(0))
  [pscustomobject]@{id=[guid]::NewGuid().ToString('D');slot=$slot;kind='custom';name=('测试服务商'+$slot);directory=$directory;extraDirectories=@();programPaths=@($program);dailyPort=(10820+2*$slot);tradePort=(10821+2*$slot);httpPort=$null;pacPort=$null;bootstrapDomains=@('provider.example');settingsDirectory=$null;addedAt=[DateTimeOffset]::UtcNow.ToString('o')}
 })
 $registryPath=Join-Path $root 'providers.json';Write-Json $registryPath ([ordered]@{version=1;providers=$records})
 $trade=Join-Path $work 'NinjaTrader.exe';[IO.File]::WriteAllBytes($trade,[byte[]]@(0))
 . (Join-Path $package 'runtime\TradeChannel.Provider.ps1')
 . (Join-Path $package 'runtime\TradeChannel.ProviderSetup.ps1')
 $script:TCProviderSummaryCacheRoot=Join-Path $root 'display-cache'
 $null=Get-TCClashRuntimeFacts @('mixed-port: 7897','proxies: [{name: Sample, type: socks5, server: fixture.invalid, port: 10001}]','rules: ["MATCH,Sample"]') -DisplayOnly
 $common=@{Root=$root;Path=$source;Name='新候选';EnginePath=$engine;WgPath=$wg;DirectDnsIPv4='1.1.1.1';Providers=$records;TradeProgramPaths=@($trade)}
 $positive=Import-TCWireGuard @common
 $manifest=Read-Json $positive.manifestPath
 Check ($manifest.SyntaxValidated -and @($manifest.Providers).Count -eq 2 -and @($manifest.TradeProgramPaths).Count -eq 1) 'real candidate/probe checks pass with existing line, two providers, cache and Chinese paths'
 $indexPath=Join-Path $root 'index.json';$indexBytes=[IO.File]::ReadAllBytes($indexPath);$registryBytes=[IO.File]::ReadAllBytes($registryPath)
 $priorManifestHash=(Get-FileHash -LiteralPath $prior.manifestPath -Algorithm SHA256).Hash
 $countBefore=@(Get-TCNodes -Root $root).Count

 $unexpected=Join-Path $root 'unexpected';$null=[IO.Directory]::CreateDirectory($unexpected)
 try{$layout=Expect-Failure {Import-TCWireGuard @common} 'NodeStoreLayoutInvalid' 'ValidateStoreLayout' 'Store.children'}finally{[IO.Directory]::Delete($unexpected)}
 Check ($layout.OriginalFailures.Count -eq 1 -and $layout.OriginalFailures[0].File -ceq 'NodeStore.psm1' -and @($layout.SourceFrames|Where-Object Function -eq 'Initialize-TCStore').Count -eq 1) 'nested wrappers retain original layout validator instead of wrapper throw line'
 $boundaryRoot=Join-Path $work 'boundary\Product';$null=Initialize-TCStore -Root $boundaryRoot
 $boundaryArgs=$common.Clone();$boundaryArgs.Root=$boundaryRoot;$boundaryCache=Join-Path $boundaryRoot 'display-cache'
 [IO.File]::WriteAllText($boundaryCache,'not a cache directory')
 try{$null=Expect-Failure {Import-TCWireGuard @boundaryArgs} 'NodeStoreLayoutInvalid' 'ValidateStoreLayout' 'Store.displayCache'}finally{[IO.File]::Delete($boundaryCache)}
 $junctionTarget=Join-Path $work 'junction-target';$null=[IO.Directory]::CreateDirectory($junctionTarget)
 $null=New-Item -ItemType Junction -Path $boundaryCache -Target $junctionTarget
 try{$null=Expect-Failure {Import-TCWireGuard @boundaryArgs} 'NodeStoreLayoutInvalid' 'ValidateStoreLayout' 'Store.displayCache'}finally{[IO.Directory]::Delete($boundaryCache)}
 Check ([IO.Directory]::Exists($junctionTarget)) 'rejecting a cache junction does not follow or modify its target'
 [IO.File]::WriteAllText($indexPath,'{"schemaVersion":1,"nodes":null,"tradeDomains":[]}')
 try{$null=Expect-Failure {Import-TCWireGuard @common} 'NodeStoreIndexInvalid' 'ReadIndex'}finally{[IO.File]::WriteAllBytes($indexPath,$indexBytes)}
 [IO.File]::WriteAllText($registryPath,'{"version":1,"providers":null}')
 try{$null=Expect-Failure {Import-TCWireGuard @common} 'NodeStoreProviderInvalid' 'ReadProviders'}finally{[IO.File]::WriteAllBytes($registryPath,$registryBytes)}
 $missing=Join-Path $work 'missing-private.conf';[IO.File]::WriteAllText($missing,($text -replace '(?m)^PrivateKey = [^\r\n]*\r?\n',''),(New-Object Text.UTF8Encoding($false)))
 $missingArgs=$common.Clone();$missingArgs.Path=$missing
 $null=Expect-Failure {Import-TCWireGuard @missingArgs} 'CandidateFieldMissing' 'ParseWireGuard' 'WireGuard.Interface.PrivateKey'
 foreach($case in @(@{Mode='KeyReject';Code='CandidateKeyValidationFailed';Stage='DeriveClientPublicKey';Exit=17},@{Mode='CandidateReject';Code='CandidateValidationFailed';Stage='ValidateCandidate';Exit=37},@{Mode='ProbeReject';Code='ProbeValidationFailed';Stage='ValidateProbe';Exit=43})){
  Set-NativeMode $case.Mode
  try{$nativeFailure=Expect-Failure {Import-TCWireGuard @common} $case.Code $case.Stage;Check ($nativeFailure.FailureContext.NativeExitCode -eq $case.Exit) 'native exit code survives sanitized wrapping'}finally{Set-NativeMode Real}
 }
 & $module {param($Path)$script:TCCandidateIndexPath=$Path} $indexPath
 Set-NativeMode LockCommit
 try{$locked=Expect-Failure {Import-TCWireGuard @common} 'CandidateCommitFailed' 'CommitIndex';Check (($locked.OriginalFailures[0].HResult -band 65535) -in @(32,33)) 'actual sharing violation retains Win32 cause'}finally{& $module {if($script:TCCandidateIndexLock){$script:TCCandidateIndexLock.Dispose();$script:TCCandidateIndexLock=$null}};Set-NativeMode Real}
 Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))) -ceq [Convert]::ToBase64String($indexBytes)) 'every precommit failure leaves the original index bytes intact'
 Check (@(Get-TCNodes -Root $root).Count -eq $countBefore -and @(Get-ChildItem -LiteralPath (Join-Path $root '.staging') -Force).Count -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $root 'nodes') -Directory).Count -eq 1) 'failed candidate writes leave no published node or staging/final directory'
 Check ((Get-FileHash -LiteralPath $prior.manifestPath -Algorithm SHA256).Hash -ceq $priorManifestHash) 'preexisting line manifest stays unchanged'
 $outsideHistory=Join-Path ([IO.Path]::GetDirectoryName($root)) 'linux-jobs';$null=[IO.Directory]::CreateDirectory($outsideHistory);Write-Json (Join-Path $outsideHistory 'orphan-reference.json') @{MissingNode=[guid]::NewGuid().ToString('D')}
 $afterOrphan=Import-TCWireGuard @common
 Check ($afterOrphan.id -and @(Get-TCNodes -Root $root).Count -eq $countBefore+1) 'unrelated orphan history does not block candidate materialization'

 # Reproduce interruption after a real node/index commit but before the run
 # receives CandidateNodeId. Recovery uses actual persisted request/config
 # binding and the real profile builder; no success stubs are used.
 Import-Module (Join-Path $package 'DeploymentFlow.psm1') -DisableNameChecking
 $flow=Get-Module DeploymentFlow;$recoveryRoot=Join-Path $work 'recovery'
 $existing=Register-TCExisting -Root (Join-Path $recoveryRoot 'Product') -ManifestPath $seed.manifestPath -Name '保留的主线'
 $run=New-TCDeploymentRun -Root $recoveryRoot -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -ClientInspection @{NinjaTraderPaths=@($trade);DirectDnsIPv4=@('1.1.1.1')}
 $run.ClientRequest=[pscustomobject]@{RequestId=[guid]::NewGuid().ToString('D');DeviceId=[guid]::NewGuid().ToString('D');ClientPublicKey=$clientPublic}
 $run.ClientResponse=[pscustomobject]@{ServerPublicKey=$serverPublic;ClientPublicKey=$clientPublic;NodeId=[guid]::NewGuid().ToString('D');ClientAddress='10.77.0.2';PublicEndpoint='192.0.2.10:51820';TunnelSubnet='10.77.0.0/24'}
 $originalSave=& $flow {${function:Save-TCDeploymentRun}}
 & $flow {param($Original)
  $script:TCCandidateOriginalSave=$Original;$script:TCCandidateFailPublication=$true
  function script:Save-TCDeploymentRun {param([string]$Root,$Run)
   if($script:TCCandidateFailPublication -and $Run.CandidateTransaction -and $Run.CandidateTransaction.State -eq 'Imported'){$script:TCCandidateFailPublication=$false;throw 'Injected interruption before publishing candidate to run.'}
   & $script:TCCandidateOriginalSave $Root $Run
  }
  function script:Start-TCDeploymentRemote {throw 'Isolation: no remote operation is permitted.'}
 } $originalSave
 $interrupted=$false
 try{& $flow {param($Root,$Run,$Conf)Complete-TCDeploymentCandidate -Root $Root -Run $Run -UseExistingConfig -SourceConfigPath $Conf} $recoveryRoot $run $source}catch{$interrupted=$_.Exception.Message -ceq 'Injected interruption before publishing candidate to run.';if(-not $interrupted){throw}}
 & $flow {param($Original)Set-Item Function:script:Save-TCDeploymentRun $Original} $originalSave
 $beforeRecovery=Get-TCDeploymentRun -Root $recoveryRoot -RunId $run.RunId
 $committedNodes=@(Get-TCNodes -Root (Join-Path $recoveryRoot 'Product')|Where-Object id -ne $existing.id)
 Check ($interrupted -and $beforeRecovery.CandidateTransaction.State -ceq 'Prepared' -and -not $beforeRecovery.CandidateNodeId -and $committedNodes.Count -eq 1) 'interruption leaves real committed node and original prepared run'
 & $flow {param($Root,$Run,$Conf)Complete-TCDeploymentCandidate -Root $Root -Run $Run -UseExistingConfig -SourceConfigPath $Conf;$null=Save-TCDeploymentRun $Root $Run} $recoveryRoot $beforeRecovery $source
 $restored=Get-TCDeploymentRun -Root $recoveryRoot -RunId $run.RunId
 Check ($restored.CandidateNodeId -ceq $committedNodes[0].id -and $restored.CandidateTransaction.State -ceq 'Completed' -and $restored.ProtocolPreparation.Udp.LocalPreparation -ceq 'SyntaxValidated') 'recovery reuses the original committed node and completes real UDP profile creation'
 & $flow {param($Root,$Run,$Conf)Complete-TCDeploymentCandidate -Root $Root -Run $Run -UseExistingConfig -SourceConfigPath $Conf;$null=Save-TCDeploymentRun $Root $Run} $recoveryRoot $restored $source
 Check (@(Get-TCNodes -Root (Join-Path $recoveryRoot 'Product')).Count -eq 2 -and $restored.CandidateNodeId -ceq $committedNodes[0].id) 'repeating recovered completion does not create duplicate candidate'

 $malicious=New-Object InvalidOperationException('CANDIDATE_SECRET_CANARY')
 foreach($key in @('TCFailureCode','TCFailureStage','TCFailureField','TCFailureRule','TCFailureNativeTool','TCFailureType','TCFailureFile','TCFailureLine','TCFailureHResult')){$malicious.Data[$key]='CANDIDATE_SECRET_CANARY'}
 $malicious.Data['TCFailureFrames']=@([pscustomobject]@{Function='CANDIDATE_SECRET_CANARY';File='NodeStore.psm1';Line='CANDIDATE_SECRET_CANARY'})
 $safe=Get-TCWorkerFailure -Failure $malicious -Action DeploymentFlow
 $id=Write-TCFailureDiagnostic -Root $work -Failure $malicious -Action DeploymentFlow -Stage MaterializeCandidate
 Check ($id -and ([IO.File]::ReadAllText((Join-Path $work ('diagnostics\failures\'+$id+'.json')))) -notmatch 'CANDIDATE_SECRET_CANARY' -and ($safe|ConvertTo-Json -Depth 10) -notmatch 'CANDIDATE_SECRET_CANARY') 'unrecognized metadata cannot bypass the diagnostic allowlist'
 $audit=@(& $module {$script:TCCandidateNativeAudit.ToArray()})
 Check (@($audit|Where-Object {$_ -notin @('check','pubkey')}).Count -eq 0) 'all native commands remained offline'
 $result=[ordered]@{Passed=$true;PowerShell=$PSVersionTable.PSVersion.ToString();Checks=$checks.Count;Names=$checks.ToArray();FailureCases=$failures.ToArray();NativeCalls=$audit.Count;NativeCheckCalls=@($audit|Where-Object {$_ -eq 'check'}).Count;RecoveryCandidateCount=1;ExistingLinePreserved=$true;RemoteAuthenticationAttempts=0;ProductionWrites=0;NetworkChanges=0;SecretsIncluded=$false;Cleaned=$false}
}finally{
 & $module {param($Runner)if($script:TCCandidateIndexLock){$script:TCCandidateIndexLock.Dispose();$script:TCCandidateIndexLock=$null};$script:TCNativeRunner=$Runner} $originalRunner
 if($flow -and $originalSave){& $flow {param($Original)Set-Item Function:script:Save-TCDeploymentRun $Original} $originalSave}
 $private=$null;$serverPrivate=$null;$text=$null;$script:TCProviderSummaryCacheRoot=$null
 if(Test-Path -LiteralPath $work){
  $full=[IO.Path]::GetFullPath($work);$boundary=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
  if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^CandidateMaterializationTests-[a-f0-9]{32}$'){throw 'Candidate fixture cleanup refused an unowned path.'}
  & $module {param($Path)Assert-TCNoReparse $Path} $full
  Remove-Item -LiteralPath $full -Recurse -Force
 }
}
if($result){$result.Cleaned=(-not (Test-Path -LiteralPath $work));if($ReportPath){$result|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Depth 12}
