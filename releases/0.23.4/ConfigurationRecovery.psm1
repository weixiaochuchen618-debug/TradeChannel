#requires -Version 5.1
Set-StrictMode -Version 2
function Invoke-TCRecoveryContext {
    param([string]$Root,[scriptblock]$Action,[object[]]$Arguments=@())
    $module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    & $module $Action ([IO.Path]::GetFullPath($Root)) @Arguments
}
function Get-TCConfigurationRollbackPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId)
    $ErrorActionPreference='Stop'
    Invoke-TCRecoveryContext $Root {
        param($DataRoot,$Id)
        $store=Join-Path $DataRoot 'Product';$id=ConvertTo-TCId $Id
        $node=@(Get-TCNodes -Root $store|Where-Object {$_.id -eq $id})
        if($node.Count -ne 1){Stop-TCError '找不到指定线路。'}
        $current=Get-TCFullPath $node[0].manifestPath;Assert-TCNoReparse $current
        $m=Read-TCJson $current;$previous=[string](Get-TCProperty $m 'PreviousManifestPath' (Get-TCProperty $m 'UpgradedFrom' ''))
        $result=[ordered]@{Available=$false;CanRestore=$false;RequiresMaintenance=$false;NodeId=$id;Name=$node[0].name;CurrentManifestPath=$current;PreviousManifestPath=$previous;PreviewToken=$null;CurrentHash=$null;PreviousHash=$null;CurrentConfigurationChanged=$false;ConfigurationChangedAt=(Get-TCProperty $m 'ConfigurationChangedAt');ChangeKind=(Get-TCProperty $m 'ConfigurationChangeKind' 'LegacyUpdate');Reason='NoRollbackPoint';Message='这条线路没有有效的上一版配置。恢复配置不会自动连接。'}
        if(-not $previous -or -not [IO.File]::Exists($previous)){return [pscustomobject]$result}
        try{
            $previous=Get-TCFullPath $previous;Assert-TCNoReparse $previous
            if(Test-TCSamePath $previous $current){Stop-TCError '回退点不能指向当前配置。'}
            $old=Read-TCJson $previous
            foreach($field in @('ClientPublicKey','ServerPublicKey','ClientAddress')){
                if(-not (Get-TCProperty $m $field) -or (Get-TCProperty $m $field) -cne (Get-TCProperty $old $field)){Stop-TCError '回退点不属于同一设备和服务器身份。'}
            }
            $candidate=Get-TCFullPath $old.CandidatePath;Assert-TCNoReparse $candidate
            $hash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            if(-not (Get-TCProperty $old 'CandidateSHA256') -or $hash -cne $old.CandidateSHA256){Stop-TCError '上一版配置完整性核验失败。'}
            $probePath=[string](Get-TCProperty $old 'ProbePath' '');$probeHash=''
            if($probePath){Assert-TCNoReparse $probePath;$probeHash=(Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash;if($probeHash -cne (Get-TCProperty $old 'ProbeSHA256' '')){Stop-TCError '上一版探测配置完整性核验失败。'}}
            $currentCandidate=Get-TCFullPath $m.CandidatePath;Assert-TCNoReparse $currentCandidate
            $currentCandidateHash=$(if([IO.File]::Exists($currentCandidate)){(Get-FileHash -LiteralPath $currentCandidate -Algorithm SHA256).Hash}else{'missing'})
            $deployment=Join-Path $DataRoot 'deployment.json';$selected=$false;$binding='unselected'
            if([IO.File]::Exists($deployment)){Assert-TCNoReparse $deployment;$dep=Read-TCJson $deployment;$selected=Test-TCSamePath (Get-TCProperty $dep 'ManifestPath' '') $current;$binding=[string](Get-TCProperty $dep 'ManifestPath' '')}
            $state='NoRuntime';$rtPath=Join-Path $DataRoot 'runtime.json';$blocked=$false
            if([IO.File]::Exists($rtPath)){Assert-TCNoReparse $rtPath;$rt=Read-TCJson $rtPath;$runtimeMatches=Test-TCSamePath (Get-TCProperty $rt 'ManifestPath' '') $current;if($selected -or $runtimeMatches){$state=[string](Get-TCProperty $rt 'State' 'Unknown');$blocked=($state -notin @('Disconnected','Stopped','StoppedWithError') -or [bool](Get-TCProperty $rt 'CleanupError' $false))}}
            $currentHash=(Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash;$previousHash=(Get-FileHash -LiteralPath $previous -Algorithm SHA256).Hash
            $tokenInput=@($id,$current,$previous,$currentHash,$previousHash,$currentCandidateHash,$hash,$probeHash,$binding,$state) -join "`n"
            $sha=[Security.Cryptography.SHA256]::Create();try{$token=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($tokenInput))).Replace('-','')}finally{$sha.Dispose()}
            $result.Available=$true;$result.CanRestore=(-not $blocked);$result.RequiresMaintenance=$blocked;$result.PreviousManifestPath=$previous;$result.PreviewToken=$token;$result.CurrentHash=$currentHash;$result.PreviousHash=$previousHash;$result.CurrentConfigurationChanged=($currentCandidateHash -cne (Get-TCProperty $m 'CandidateSHA256' ''))
            $result.Reason=$(if($blocked){'RuntimeActive'}else{'Ready'});$result.Message=$(if($blocked){'该线路仍在运行或清理未完成。请通过现有确认流程停止连接，再恢复配置；不会自动断开或换线。'}else{'恢复上一版配置只更新线路记录，不自动连接、不改变网络。恢复后可再次回到恢复前的配置。'})
            if(-not $blocked -and $result.CurrentConfigurationChanged){$result.Message='当前配置被修改或缺失，可恢复已校验的上一版。恢复前记录会保留，但未通过完整性核验的记录不能再次恢复；不会自动连接。'}
        }catch{$result.Reason='InvalidRollbackPoint';$result.Message='上一版配置缺失、身份不匹配或完整性核验失败，未恢复任何配置。'}
        [pscustomobject]$result
    } @($NodeId)
}
function Prepare-TCConfigurationRollback {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId,[Parameter(Mandatory=$true)][string]$PreviewToken)
    $ErrorActionPreference='Stop';$preview=Get-TCConfigurationRollbackPreview -Root $Root -NodeId $NodeId
    if(-not $preview.Available -or $PreviewToken -cne $preview.PreviewToken){throw '回退点或运行状态已变化，请重新查看恢复预览。'}
    Invoke-TCRecoveryContext $Root {
        param($DataRoot,$Preview)
        $old=Read-TCJson $Preview.PreviousManifestPath
        Test-TCCheckedConfiguration $old.EnginePath $old.CandidatePath
        $configs=Join-Path $DataRoot 'configs';New-TCPrivateDirectory $configs
        $dir=Join-Path $configs ('recovery-'+[guid]::NewGuid().ToString('N'));New-TCPrivateDirectory $dir
        $next=[ordered]@{};foreach($p in $old.PSObject.Properties){$next[$p.Name]=$p.Value}
        $next.PreviousManifestPath=$Preview.CurrentManifestPath;$next.ConfigurationChangeKind='Rollback';$next.ConfigurationChangedAt=[DateTimeOffset]::UtcNow.ToString('o');$next.TCManagedNodeId=$Preview.NodeId
        $next.DeploymentApproved=$false;$next.ServerForwardingVerified=$false;$next.ProcessRoutingVerified=$false;$next.IndependentGuardVerified=$false
        $path=Join-Path $dir 'manifest.json'
        try{
            # Legacy probe assets are upgraded in this new recovery directory.
            # The original configuration, private key and rollback point stay untouched.
            $probe=[string](Get-TCProperty $old 'ProbePath' '')
            if($probe){$cfg=Read-TCJson $old.CandidatePath;$auth=@($cfg.inbounds|Where-Object {$_.tag -eq 'egress-probe'});if($auth.Count -ne 1 -or -not @($auth[0].users).Count){Stop-TCError '上一版配置缺少本机诊断认证。'};$pc=Set-TCAuthenticatedProbe (Read-TCJson $probe) ([string]$auth[0].users[0].password);$probeNew=Join-Path $dir 'probe.json';Write-TCAtomicJson $probeNew $pc -NewOnly -NoBom;Test-TCCheckedConfiguration $old.EnginePath $probeNew;$next.ProbePath=$probeNew;$next.ProbeSHA256=(Get-FileHash -LiteralPath $probeNew -Algorithm SHA256).Hash}
            Write-TCAtomicJson $path $next -NewOnly
        }catch{foreach($f in @('manifest.json','probe.json')){$owned=Join-Path $dir $f;if([IO.File]::Exists($owned)){[IO.File]::Delete($owned)}};[IO.Directory]::Delete($dir,$false);Stop-TCOperation $_ '回退配置未准备，请检查回退点和引擎。'}
        [pscustomobject]@{Prepared=$true;NodeId=$Preview.NodeId;ManifestPath=$path;PreviousManifestPath=$Preview.CurrentManifestPath;RollbackTarget=$Preview.PreviousManifestPath;PreviewToken=$Preview.PreviewToken;NetworkChanged=$false;Activated=$false}
    } @($preview)
}
function Restore-TCNodeConfiguration {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId,[Parameter(Mandatory=$true)][string]$PreviewToken)
    $ErrorActionPreference='Stop';$preview=Get-TCConfigurationRollbackPreview -Root $Root -NodeId $NodeId
    if(-not $preview.CanRestore -or $PreviewToken -cne $preview.PreviewToken){throw '线路尚未停止或回退点已变化。请重新查看恢复预览；未断开或切换任何线路。'}
    $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    $sessionLock=& $nodeModule {param($r)Open-TCNodeSessionLock (Join-Path $r 'Product')} ([IO.Path]::GetFullPath($Root))
    try{
        $again=Get-TCConfigurationRollbackPreview -Root $Root -NodeId $NodeId
        if(-not $again.CanRestore -or $again.PreviewToken -cne $PreviewToken){throw '运行状态或配置发生变化，请重新预览。'}
        $null=& $nodeModule {param($r,$p)$m=Read-TCJson $p;Assert-TCNodeStopped (Join-Path $r 'Product') $p $m} $Root $preview.CurrentManifestPath
        $prepared=Prepare-TCConfigurationRollback -Root $Root -NodeId $NodeId -PreviewToken $PreviewToken
        $latest=Get-TCConfigurationRollbackPreview -Root $Root -NodeId $NodeId
        if(-not $latest.CanRestore -or $latest.PreviewToken -cne $PreviewToken){throw '准备期间配置或状态发生变化；候选保留，未替换线路。'}
        $changed=@(Set-TCNodeManifest -Root (Join-Path $Root 'Product') -PreviousManifestPath $preview.CurrentManifestPath -ManifestPath $prepared.ManifestPath -ExpectedNodeId $NodeId -ExpectedCurrentHash $preview.CurrentHash)
        if($changed.Count -ne 1){throw '线路记录未匹配，未完成恢复。'}
        # A stopped selected line follows the restored record; this is a data-only
        # transaction and cannot launch, stop or configure the runtime.
        try{
            & $nodeModule {param($r,$old,$next)$dp=Join-Path $r 'deployment.json';if([IO.File]::Exists($dp)){$d=Read-TCJson $dp;if(Test-TCSamePath (Get-TCProperty $d 'ManifestPath' '') $old){$d.ManifestPath=$next;Write-TCAtomicJson $dp $d}}} $Root $preview.CurrentManifestPath $prepared.ManifestPath
        }catch{$null=Set-TCNodeManifest -Root (Join-Path $Root 'Product') -PreviousManifestPath $prepared.ManifestPath -ManifestPath $preview.CurrentManifestPath;throw '恢复记录提交失败，原线路记录已恢复。'}
        Import-Module (Join-Path $PSScriptRoot 'RuntimeObservability.psm1') -DisableNameChecking
        try{$null=Add-TCRuntimeEvent -Root $Root -SessionId ('configuration-'+[guid]::NewGuid().ToString('N')) -Type ConfigurationRestored}catch{}
        [pscustomobject]@{Restored=$true;NodeId=$NodeId;ManifestPath=$prepared.ManifestPath;PreviousManifestPath=$preview.CurrentManifestPath;NetworkChanged=$false;Activated=$false;Message='上一版配置已恢复。当前连接未自动启用；需要时在概览页明确连接。'}
    }finally{if($sessionLock){$sessionLock.Dispose()}}
}
Export-ModuleMember -Function Get-TCConfigurationRollbackPreview,Prepare-TCConfigurationRollback,Restore-TCNodeConfiguration
