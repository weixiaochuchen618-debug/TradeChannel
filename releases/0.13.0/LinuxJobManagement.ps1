# Archive only changes local display metadata. Keys, replies, plans, rollback
# receipts and server state are kept so archived jobs remain resumable.
function Set-TCLinuxJobArchived {
    param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id,[bool]$Archived=$true)
    $rootPath=Resolve-TCLinuxRoot $Root;Assert-TCLinuxId $Id
    $job=Get-TCLinuxJob -Id $Id -Root $rootPath
    if($job.Status -notin @('Completed','Complete','Failed')){Stop-TCLinux JobRunning '正在执行或等待认证的任务不能归档，请先等待任务结束。'}
    $directory=Join-Path $rootPath $Id;Assert-TCLinuxPrivatePath $directory
    $marker=Join-Path $directory 'archive.json'
    $temp=Join-Path $directory ('.archive-'+[guid]::NewGuid().ToString('N'))
    $lock=[IO.File]::Open((Join-Path $directory '.archive.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        Protect-TCLinuxPath (Join-Path $directory '.archive.lock')
        Write-TCLinuxJson $temp ([ordered]@{SchemaVersion=1;JobId=$Id;Archived=$Archived;UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')})
        if([IO.File]::Exists($marker)){Assert-TCLinuxPrivatePath $marker;[IO.File]::Replace($temp,$marker,[NullString]::Value)}else{[IO.File]::Move($temp,$marker)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};$lock.Dispose()}
    [pscustomobject]@{JobId=$Id;Archived=$Archived;ServerChanged=$false;KeysDeleted=$false;Message=$(if($Archived){'任务已归档，配置与私钥保留，可从任务管理恢复。'}else{'任务已恢复到近期列表。'})}
}
function Test-TCLinuxJobArchived {
    param([string]$Root,[string]$Id)
    $marker=Join-Path (Join-Path $Root $Id) 'archive.json'
    if(-not [IO.File]::Exists($marker)){return $false}
    Assert-TCLinuxPrivatePath $marker;$value=Read-TCLinuxJson $marker 4096
    if($value.SchemaVersion -ne 1 -or $value.JobId -cne $Id -or $value.Archived -isnot [bool]){Stop-TCLinux InvalidState '任务归档记录无效，请导出诊断后处理。'}
    return [bool]$value.Archived
}
