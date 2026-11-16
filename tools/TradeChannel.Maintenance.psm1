#requires -Version 5.1
$ErrorActionPreference='Stop'

function Write-TCMJson {
    param([string]$Path,$Value,[switch]$NoBom)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 14),(New-Object Text.UTF8Encoding((-not $NoBom))))
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-TCMJson {param([string]$Path);Get-Content -LiteralPath $Path -Encoding UTF8 -Raw|ConvertFrom-Json}
function Test-TCMSamePath {param([string]$A,[string]$B);$A -and $B -and [IO.Path]::GetFullPath($A).Equals([IO.Path]::GetFullPath($B),[StringComparison]::OrdinalIgnoreCase)}
function Assert-TCMBelow {
    param([string]$Path,[string]$Root)
    $full=[IO.Path]::GetFullPath($Path);$prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw '维护路径超出计划目录。'}
    $current=$full
    while($current){if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '维护路径不能经过链接。'}};$current=[IO.Path]::GetDirectoryName($current)}
}
function Assert-TCMElevated {
    $p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw '请以管理员身份运行维护入口。'}
}
function Assert-TCMNinjaClosed {if(Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue){throw '请先退出整个 NinjaTrader 控制中心；当前通道未改变。'}}
function Assert-TCMEngineConfig {
    param([string]$Engine,[string]$Config)
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Engine;$start.Arguments='check -c "'+$Config+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$start
    try{
        $null=$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(20000)){$p.Kill();$null=$p.WaitForExit(2000);throw '本地配置检查超时，未停止通道。'}
        $null=$out.GetAwaiter().GetResult();$null=$err.GetAwaiter().GetResult()
        if($p.ExitCode -ne 0){throw '本地配置检查未通过，未停止通道；原始诊断内容不输出以保护密钥。'}
    }finally{$p.Dispose()}
}
function Assert-TCMDeclaredModes {
    param($Config)
    $modes=New-Object 'System.Collections.Generic.List[string]'
    function Read-Modes {param($Rules)
        foreach($rule in @($Rules)){
            if($rule.clash_mode){$modes.Add([string]$rule.clash_mode)}
            if($rule.rules){Read-Modes $rule.rules}
        }
    }
    Read-Modes $Config.route.rules;Read-Modes $Config.dns.rules
    if('rule' -notin $modes -or 'global' -notin $modes){throw '候选配置没有显式声明交易/全局两种模式，未停止香港通道。'}
}
function Import-TCMBridge {param([string]$Package);Import-Module (Join-Path $Package 'RuntimeBridge.psm1') -Force -DisableNameChecking -Global}
function Assert-TCMPackage {
    param([string]$Package)
    $manifest=Join-Path $Package 'package.sha256';$rows=[IO.File]::ReadAllLines($manifest);$seen=@{}
    foreach($row in $rows){
        if($row -notmatch '^([A-Fa-f0-9]{64})\|(.+)$'){throw '软件包清单格式无效。'}
        $hash=$matches[1];$relative=$matches[2];$path=Join-Path $Package $relative
        Assert-TCMBelow $path $Package
        if($seen.ContainsKey($relative)){throw '软件包清单重复。'};$seen[$relative]=$true
        if((Get-FileHash -LiteralPath $path).Hash -ine $hash){throw '软件包校验未通过。'}
    }
    foreach($required in @('RuntimeBridge.psm1','NodeStore.psm1','runtime\Run-TradeChannel.ps1','runtime\Invoke-TradeChannel.ps1','assets\sing-box.exe')){if(-not $seen.ContainsKey($required)){throw '软件包缺少运行组件。'}}
    if(@(Get-ChildItem -LiteralPath $Package -Recurse -File|Where-Object {$_.Name -ne 'package.sha256'}).Count -ne $rows.Count){throw '软件包存在清单之外的文件。'}
}
function Get-TCMState {param([string]$PlanPath);$path=Join-Path (Split-Path $PlanPath -Parent) 'result.json';if(Test-Path -LiteralPath $path){Read-TCMJson $path}}
function Set-TCMState {
    param($Plan,[string]$State,[string]$Message,$Evidence=$null)
    $record=[ordered]@{PlanId=$Plan.Id;State=$State;Message=$Message;At=(Get-Date).ToString('o');WorkerPid=$PID;Evidence=$Evidence}
    Write-TCMJson (Join-Path $Plan.Directory 'result.json') $record
    [pscustomobject]$record
}
function New-TCMPlan {
    param([string]$Package,[string]$RollbackArchive,[string]$Root='C:\ProgramData\TradeChannel')
    Assert-TCMElevated;Assert-TCMPackage $Package
    Import-TCMBridge $Package
    $overview=Get-TCOverview
    if(-not $overview.Running -or $overview.Mode -ne 'global' -or $overview.Exit -ne 'hk'){throw '准备维护时需保持已连接的全局香港线路。'}
    $depPath=Join-Path $Root 'deployment.json';$prefsPath=Join-Path $Root 'ui-preferences.json';$indexPath=Join-Path $Root 'Product\index.json'
    $d=Read-TCMJson $depPath;$old=Read-TCMJson $d.ManifestPath;$runtime=Read-TCMJson (Join-Path $Root 'runtime.json')
    $probe=& (Join-Path $Package 'runtime\Test-SelectedTradeExit.ps1')
    if($probe.CurlExit -ne 0 -or $probe.HTTPStatus -ne 200 -or -not $probe.ObservedIP){throw '香港出口尚未通过维护前检查，未停止通道。'}
    $node=Import-Module (Join-Path $Package 'NodeStore.psm1') -Force -DisableNameChecking -PassThru
    $id=[guid]::NewGuid().ToString('N');$dir=Join-Path $Root ('maintenance\'+$id)
    & $node {param($p)New-TCPrivateDirectory $p} $dir
    foreach($pair in @(@($depPath,'original-deployment.json'),@($prefsPath,'original-preferences.json'),@($indexPath,'original-index.json'))){Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $dir $pair[1])}
    $app=Join-Path $dir 'candidate-app';$oldApp=Join-Path $dir 'rollback-app'
    Copy-Item -LiteralPath $Package -Destination $app -Recurse
    Assert-TCMPackage $app
    $expected=([IO.File]::ReadAllText($RollbackArchive+'.sha256').Trim() -split '\s+')[0]
    if((Get-FileHash -LiteralPath $RollbackArchive).Hash -ine $expected){throw '回退程序包校验失败，未停止通道。'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($RollbackArchive)
    try{foreach($entry in $zip.Entries){Assert-TCMBelow (Join-Path $oldApp $entry.FullName) $oldApp}}finally{$zip.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($RollbackArchive,$oldApp);Assert-TCMPackage $oldApp
    . (Join-Path $Package 'runtime\TradeChannel.Providers.ps1')
    $providers=Read-TCProviderStore (Join-Path $Root 'Product')
    $up=Update-TCNodePolicy -Root (Join-Path $Root 'Product') -ManifestPath $d.ManifestPath -Providers @($providers.Providers) -ReplaceProviders
    $next=Read-TCMJson $up.ManifestPath;$cfg=Read-TCMJson $next.CandidatePath
    # Global HK from the first packet; do not wait for the controller to patch it.
    $cfg.experimental.clash_api.default_mode='global'
    Assert-TCMDeclaredModes $cfg
    Write-TCMJson $next.CandidatePath $cfg -NoBom
    $next.EnginePath=Join-Path $app 'assets\sing-box.exe';$next.CandidateSHA256=(Get-FileHash -LiteralPath $next.CandidatePath).Hash
    Write-TCMJson $up.ManifestPath $next
    $seal=Join-Path $dir 'candidate-manifest-sealed.json';Copy-Item -LiteralPath $up.ManifestPath -Destination $seal
    Assert-TCMEngineConfig $next.EnginePath $next.CandidatePath
    $recovery=Read-TCMJson $d.ManifestPath;$oldCfg=Read-TCMJson $old.CandidatePath
    $oldCfg.experimental.clash_api.default_mode='global'
    $recovery.CandidatePath=Join-Path $dir 'recovery-config.json';$recovery.EnginePath=Join-Path $oldApp 'assets\sing-box.exe';$recovery.DeploymentApproved=$true
    Write-TCMJson $recovery.CandidatePath $oldCfg -NoBom
    $recovery.CandidateSHA256=(Get-FileHash -LiteralPath $recovery.CandidatePath).Hash
    $recoverManifest=Join-Path $dir 'recovery-manifest.json';Write-TCMJson $recoverManifest $recovery
    Assert-TCMEngineConfig $recovery.EnginePath $recovery.CandidatePath
    foreach($file in @('TradeChannel.Maintenance.psm1','Invoke-TradeChannelMaintenance.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $dir $file)}
    $baseline=@()
    foreach($item in @(@('Deployment',$depPath),@('Preferences',$prefsPath),@('Index',$indexPath),@('Providers',(Join-Path $Root 'Product\providers.json')), @('OldManifest',$d.ManifestPath),@('OldConfig',$old.CandidatePath))){$baseline+=@{Name=$item[0];Path=$item[1];Hash=(Get-FileHash -LiteralPath $item[1]).Hash}}
    $protected=@($seal,$next.CandidatePath,$recoverManifest,$recovery.CandidatePath,(Join-Path $dir 'original-deployment.json'),(Join-Path $dir 'original-preferences.json'),(Join-Path $dir 'original-index.json'),(Join-Path $dir 'TradeChannel.Maintenance.psm1'),(Join-Path $dir 'Invoke-TradeChannelMaintenance.ps1'))
    $plan=[ordered]@{SchemaVersion=1;Id=$id;Directory=$dir;Root=$Root;CreatedAt=(Get-Date).ToString('o');ExpiresAt=(Get-Date).AddHours(24).ToString('o');Package=$app;RollbackPackage=$oldApp;OldManifest=$d.ManifestPath;CandidateManifest=$up.ManifestPath;RecoveryManifest=$recoverManifest;ExpectedIP=$probe.ObservedIP;OriginalSupervisor=$runtime.SupervisorPid;OriginalEngine=$runtime.EnginePid;Baseline=$baseline;Files=@(foreach($file in $protected){@{Path=$file;Hash=(Get-FileHash -LiteralPath $file).Hash}});TargetMode='global';TargetExit='hk'}
    $planPath=Join-Path $dir 'plan.json';Write-TCMJson $planPath $plan
    $null=Set-TCMState $plan Prepared '已生成候选、回退与独立恢复入口，尚未切换。'
    $cmd='@echo off'+"`r`n"+'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-TradeChannelMaintenance.ps1" -Action Recover -PlanPath "%~dp0plan.json"'+"`r`n"+'pause'+"`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'recover-hongkong.cmd'),$cmd,[Text.Encoding]::ASCII)
    $after=Read-TCMJson (Join-Path $Root 'runtime.json')
    if($after.EnginePid -ne $runtime.EnginePid -or (Get-FileHash -LiteralPath $old.CandidatePath).Hash -ne ($baseline|Where-Object {$_.Name -eq 'OldConfig'}).Hash){throw '准备期间现网状态发生变化，请重新核验。'}
    [pscustomobject]@{PlanPath=$planPath;RecoveryEntry=(Join-Path $dir 'recover-hongkong.cmd');ExpectedExit=$probe.ObservedIP;PolicyVersion=$next.PolicyVersion;ChangedLiveNetwork=$false;CandidateChecked=$true;RollbackChecked=$true}
}
function Read-TCMPlan {
    param([string]$PlanPath,[switch]$BeforeUpgrade)
    $plan=Read-TCMJson $PlanPath
    if($plan.SchemaVersion -ne 1 -or $plan.Id -notmatch '^[a-f0-9]{32}$' -or -not (Test-TCMSamePath (Split-Path $PlanPath -Parent) $plan.Directory)){throw '维护计划身份无效。'}
    Assert-TCMBelow $plan.Directory (Join-Path $plan.Root 'maintenance')
    foreach($path in @($plan.CandidateManifest,$plan.OldManifest)){Assert-TCMBelow $path $plan.Root}
    foreach($path in @($plan.Package,$plan.RollbackPackage,$plan.RecoveryManifest)){Assert-TCMBelow $path $plan.Directory}
    Assert-TCMPackage $plan.Package;Assert-TCMPackage $plan.RollbackPackage
    foreach($file in $plan.Files){Assert-TCMBelow $file.Path $plan.Root;if((Get-FileHash -LiteralPath $file.Path).Hash -ine $file.Hash){throw '维护文件校验失败，未启动新会话。'}}
    $actual=Read-TCMJson $plan.CandidateManifest;$sealed=Read-TCMJson (Join-Path $plan.Directory 'candidate-manifest-sealed.json')
    $actual.DeploymentApproved=$false;$sealed.DeploymentApproved=$false
    if(($actual|ConvertTo-Json -Depth 30 -Compress) -cne ($sealed|ConvertTo-Json -Depth 30 -Compress)){throw '候选记录发生了计划外变化。'}
    if($BeforeUpgrade){
        if([DateTimeOffset]::Now -gt [DateTimeOffset]$plan.ExpiresAt){throw '维护计划已过期，请重新准备。'}
        foreach($file in $plan.Baseline){Assert-TCMBelow $file.Path $plan.Root;if((Get-FileHash -LiteralPath $file.Path).Hash -ine $file.Hash){throw ('准备后设置发生变化：'+$file.Name+'，未停止通道。')}}
    }
    $plan
}
function Get-TCMSummary {
    param($Plan)
    $o=Get-TCOverview
    [pscustomobject]@{Running=$o.Running;Mode=$o.Mode;Exit=$o.Exit;Guard=$o.GuardState;ManifestPath=$o.ManifestPath;PolicyVersion=$o.PolicyVersion}
}
function Assert-TCMHongKong {
    param($Plan,[string]$Package)
    $o=Get-TCOverview
    if(-not $o.Running -or $o.Mode -ne 'global' -or $o.Exit -ne 'hk' -or $o.GuardState -ne 'Protected'){throw '香港连接或保护状态未通过核验。'}
    $probe=& (Join-Path $Package 'runtime\Test-SelectedTradeExit.ps1')
    if($probe.CurlExit -ne 0 -or $probe.HTTPStatus -ne 200 -or $probe.ObservedIP -ne $Plan.ExpectedIP){throw '香港实际公网出口未通过核验。'}
    [pscustomobject]@{Mode=$o.Mode;Exit=$o.Exit;ObservedIP=$probe.ObservedIP;Guard=$o.GuardState;PolicyVersion=$o.PolicyVersion;EngineRestarted=$true}
}
function Invoke-TCMTransaction {
    # Side effects are explicit callbacks so failure ordering is tested offline.
    param([scriptblock]$Upgrade,[scriptblock]$Verify,[scriptblock]$Commit,[scriptblock]$Recover)
    try{$null=& $Upgrade;$proof=& $Verify;$null=& $Commit;[pscustomobject]@{State='Complete';Evidence=$proof}}
    catch{try{$proof=& $Recover;[pscustomobject]@{State='RolledBack';Evidence=$proof}}catch{[pscustomobject]@{State='RecoveryFailed';Evidence=$null}}}
}
function Restore-TCMMaintenance {
    param($Plan)
    Assert-TCMNinjaClosed
    Import-TCMBridge $Plan.Package
    $d=Get-TCInstalledDeployment
    if(-not $d -or $d.ManifestPath -notin @($Plan.OldManifest,$Plan.CandidateManifest,$Plan.RecoveryManifest)){throw '当前部署不属于本计划，未覆盖其他线路。'}
    $o=Get-TCOverview
    if($o.Running -and (Test-TCMSamePath $o.ManifestPath $Plan.RecoveryManifest)){return Assert-TCMHongKong $Plan $Plan.Package}
    $null=Set-TCMState $Plan Recovering '正在恢复原香港路由，交易程序保护保留。'
    $null=Invoke-TCCommand Disconnect
    # Disconnect verifies process ownership and absence; never clear a live owner.
    $o=Get-TCOverview;if($o.SessionPresent){throw '通道尚未完全停止，未启动第二个引擎。'}
    $dep=Read-TCMJson (Join-Path $Plan.Directory 'original-deployment.json');$dep.ManifestPath=$Plan.RecoveryManifest
    $dep.SelectedAt=(Get-Date).ToString('o')
    Write-TCMJson (Join-Path $Plan.Root 'deployment.json') $dep
    Write-TCMJson (Join-Path $Plan.Root 'ui-preferences.json') (Read-TCMJson (Join-Path $Plan.Directory 'original-preferences.json'))
    # Keep the corrected identity checks while restoring the proven v3 network
    # configuration and original engine binary; old WMI time logic was brittle.
    Import-TCMBridge $Plan.Package
    $null=Invoke-TCCommand Connect
    $proof=Assert-TCMHongKong $Plan $Plan.Package
    Import-Module (Join-Path $Plan.Package 'NodeStore.psm1') -Force -DisableNameChecking -Global
    $null=Set-TCNodeManifest -Root (Join-Path $Plan.Root 'Product') -PreviousManifestPath $Plan.OldManifest -ManifestPath $Plan.RecoveryManifest
    $null=Set-TCNodeManifest -Root (Join-Path $Plan.Root 'Product') -PreviousManifestPath $Plan.CandidateManifest -ManifestPath $Plan.RecoveryManifest
    $proof
}
function Start-TCMWatchdog {
    param($Plan,[string]$PlanPath)
    $shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $stamp=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    $runner=Join-Path $Plan.Directory 'Invoke-TradeChannelMaintenance.ps1'
    $ready=Join-Path $Plan.Directory 'watchdog.ready';if(Test-Path -LiteralPath $ready){Remove-Item -LiteralPath $ready -Force}
    $launchArgs=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$runner+'"'),'-Action','Watchdog','-PlanPath',('"'+$PlanPath+'"'),'-OwnerId',$PID,'-OwnerTicks',$stamp)
    $p=Start-Process -FilePath $shell -ArgumentList $launchArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $Plan.Directory 'watchdog.out.log') -RedirectStandardError (Join-Path $Plan.Directory 'watchdog.err.log')
    $deadline=(Get-Date).AddSeconds(8)
    while((Get-Date) -lt $deadline){if((Test-Path -LiteralPath $ready) -and -not $p.HasExited){return $p.Id};if($p.HasExited){break};Start-Sleep -Milliseconds 150}
    throw '独立恢复看守未就绪，未停止香港通道。'
}
function Invoke-TCMMaintenance {
    param([string]$PlanPath,[switch]$Recover)
    Assert-TCMElevated
    $state=Get-TCMState $PlanPath
    if(-not $Recover -and $state.State -in @('Complete','RolledBack')){return $state}
    $plan=Read-TCMPlan $PlanPath -BeforeUpgrade:(-not $Recover)
    Assert-TCMNinjaClosed
    $sessionLock=[IO.File]::Open((Join-Path $plan.Root '.session.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $lock=$null
    try{
        $lock=[IO.File]::Open((Join-Path $plan.Directory 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Import-TCMBridge $plan.Package
        if($Recover){
            try{$proof=Restore-TCMMaintenance $plan;return Set-TCMState $plan RolledBack '已恢复原香港线路；请先确认状态再打开 NinjaTrader。' $proof}
            catch{return Set-TCMState $plan RecoveryFailed '恢复尚未完成。交易保护保留，请保持 NinjaTrader 关闭并查看维护记录。'}
        }
        $o=Get-TCOverview;$runtime=Read-TCMJson (Join-Path $plan.Root 'runtime.json')
        if(-not $o.Running -or $o.Mode -ne 'global' -or $o.Exit -ne 'hk' -or $runtime.EnginePid -ne $plan.OriginalEngine -or $runtime.SupervisorPid -ne $plan.OriginalSupervisor){throw '现网已不是准备时的香港会话，未执行切换。'}
        $null=Start-TCMWatchdog $plan $PlanPath
        $null=Set-TCMState $plan Applying '正在升级；本机任务独立运行，agent 暂时离线不会取消任务。'
        $result=Invoke-TCMTransaction -Upgrade {
            $null=Enable-TCNode -ManifestPath $plan.CandidateManifest -Mode Global -Exit HongKong
        } -Verify {
            $supported=(Get-TCOverview).ControllerModes
            if('rule' -notin $supported -or 'global' -notin $supported){throw '新引擎未加载交易/全局两种模式，将恢复原香港连接。'}
            Assert-TCMHongKong $plan $plan.Package
        } -Commit {
            Import-Module (Join-Path $plan.Package 'NodeStore.psm1') -Force -DisableNameChecking -Global
            $null=Set-TCNodeManifest -Root (Join-Path $plan.Root 'Product') -PreviousManifestPath $plan.OldManifest -ManifestPath $plan.CandidateManifest
        } -Recover {Restore-TCMMaintenance $plan}
        $message=switch($result.State){'Complete'{'升级完成：全局香港出口及交易保护通过检查。'}'RolledBack'{'升级未通过，已恢复原香港路由。'}default{'自动恢复尚未完成；请保持 NinjaTrader 关闭，使用本地恢复入口。'}}
        Set-TCMState $plan $result.State $message $result.Evidence
    }finally{if($lock){$lock.Dispose()};$sessionLock.Dispose()}
}
function Watch-TCMMaintenance {
    param([string]$PlanPath,[int]$OwnerId,[long]$OwnerTicks,[int]$DeadlineSeconds=150)
    $plan=Read-TCMPlan $PlanPath
    [IO.File]::WriteAllText((Join-Path $plan.Directory 'watchdog.ready'),[string]$PID)
    $deadline=(Get-Date).AddSeconds($DeadlineSeconds)
    while((Get-Date) -lt $deadline){
        $state=$null;try{$state=Get-TCMState $PlanPath}catch{}
        if($state.State -in @('Complete','RolledBack','RecoveryFailed','Aborted')){return}
        $p=Get-Process -Id $OwnerId -ErrorAction SilentlyContinue
        if(-not $p -or $p.StartTime.ToUniversalTime().Ticks -ne $OwnerTicks){break}
        $p.Dispose();Start-Sleep -Seconds 1
    }
    $state=Get-TCMState $PlanPath
    if($state.State -notin @('Applying','Recovering')){return}
    $p=Get-Process -Id $OwnerId -ErrorAction SilentlyContinue
    if($p){try{if($p.StartTime.ToUniversalTime().Ticks -eq $OwnerTicks -and $p.ProcessName -eq 'powershell'){$p.Kill();$null=$p.WaitForExit(8000)}}finally{$p.Dispose()}}
    Invoke-TCMMaintenance -PlanPath $PlanPath -Recover
}
Export-ModuleMember -Function New-TCMPlan,Get-TCMState,Invoke-TCMMaintenance,Watch-TCMMaintenance,Invoke-TCMTransaction
