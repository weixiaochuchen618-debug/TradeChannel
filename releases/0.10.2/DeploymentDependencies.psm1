#requires -Version 5.1
Set-StrictMode -Version 2.0
function Test-TCDeploymentDependencies {
    [CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
    $path=Join-Path $PackageRoot 'deployment\dependencies.lock.json'
    if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 128KB){throw '[TC:DependencyLockMissing] 缺少部署依赖锁，请重新解压完整包。'}
    $lock=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    $required=@('Renci.SshNet.dll','jose-jwt.dll','BouncyCastle.Cryptography.dll','Microsoft.Bcl.AsyncInterfaces.dll','Microsoft.Extensions.Logging.Abstractions.dll','Microsoft.Extensions.DependencyInjection.Abstractions.dll','System.Formats.Asn1.dll','System.Buffers.dll','System.Memory.dll','System.Numerics.Vectors.dll','System.Runtime.CompilerServices.Unsafe.dll','System.Threading.Tasks.Extensions.dll','System.ValueTuple.dll')
    if($lock.SchemaVersion -ne 1 -or @($lock.Dependencies).Count -ne $required.Count){throw '[TC:DependencyLockInvalid] 部署依赖锁不完整。'}
    $found=@()
    foreach($dependency in $lock.Dependencies){
        if($dependency.File -cnotmatch '^assets/lib/([A-Za-z0-9.-]+\.dll)$' -or $dependency.SHA256 -cnotmatch '^[A-F0-9]{64}$'){throw '[TC:DependencyLockInvalid] 部署依赖路径或摘要无效。'}
        $name=[IO.Path]::GetFileName($dependency.File);if($name -notin $required -or $name -in $found){throw '[TC:DependencyLockInvalid] 部署依赖列表有未知或重复条目。'};$found+=$name
        $file=Join-Path $PackageRoot $dependency.File
        if(-not [IO.File]::Exists($file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -cne $dependency.SHA256){throw '[TC:DependencyIntegrityFailed] 部署组件摘要不匹配，已拒绝加载。请重新解压完整包。'}
    }
    [pscustomobject]@{Ok=$true;Count=$found.Count;Framework='net48';Locked=$true}
}
Export-ModuleMember -Function Test-TCDeploymentDependencies
