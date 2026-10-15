#requires -Version 5.1
Set-StrictMode -Version 2.0
function Get-TCDField {param($Object,[string]$Name,$Default=$null)
 if($null -eq $Object){return $Default}
 if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
 elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
 return $Default
}
function Assert-TCDId {param([string]$Id)
 $parsed=[guid]::Empty
 if(-not [guid]::TryParseExact($Id,'D',[ref]$parsed) -or $parsed -eq [guid]::Empty){throw '[TC:InvalidId] 对象标识无效。'}
 return $parsed.ToString('D')
}
function Assert-TCDPath {param([string]$Path)
 if(-not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f\x7f"*?<>|]' -or $Path.Substring(2).Contains(':')){throw '[TC:UnsafePath] 数据必须使用本机绝对磁盘路径。'}
 $full=[IO.Path]::GetFullPath($Path);$cursor=$full
 while($cursor){
  if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '[TC:UnsafePath] 数据路径不能经过重解析点。'}}
  $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
 }
 return $full
}
function Assert-TCDFields {param($Value,[string[]]$Allowed,[string[]]$Required=@())
 if($null -eq $Value -or ($Value -isnot [Collections.IDictionary] -and $Value -isnot [pscustomobject])){throw '[TC:InvalidRequest] 请求必须是结构化对象。'}
 if($Value -is [Collections.IDictionary]){$names=@($Value.Keys)}else{$names=@($Value.PSObject.Properties.Name)}
 foreach($name in $names){if($name -notin $Allowed){throw ('[TC:InvalidRequest] 请求包含不支持的字段：'+$name)}}
 foreach($name in $Required){if($name -notin $names){throw ('[TC:InvalidRequest] 缺少字段：'+$name)}}
}
function New-TCDDirectory {param([string]$Path)
 $full=Assert-TCDPath $Path
 if([IO.File]::Exists($full)){throw '[TC:UnsafePath] 数据目录被文件占用。'}
 if(-not [IO.Directory]::Exists($full)){
  $node=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
  & $node {param($p) New-TCPrivateDirectory $p} $full
 }
 return $full
}
function Read-TCDJson {param([string]$Path,[switch]$AllowMissing,[int]$MaxBytes=4194304)
 $full=Assert-TCDPath $Path
 if(-not [IO.File]::Exists($full)){if($AllowMissing){return $null};throw '[TC:DataMissing] 操作记录不存在。'}
 if((Get-Item -LiteralPath $full).Length -gt $MaxBytes){throw '[TC:DataTooLarge] 数据文件超过允许大小。'}
 $acl=Get-Acl -LiteralPath $full -ErrorAction Stop;$allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){throw '[TC:UnsafeAcl] 数据文件对其他账户开放，拒绝读取。'}}
 try{return [IO.File]::ReadAllText($full,[Text.Encoding]::UTF8)|ConvertFrom-Json}catch{throw '[TC:InvalidData] 数据记录损坏，保留原文件以便恢复。'}
}
function Write-TCDJson {param([string]$Path,$Value,[switch]$NewOnly,[switch]$Compact)
 $full=Assert-TCDPath $Path;$parent=New-TCDDirectory ([IO.Path]::GetDirectoryName($full))
  $json=ConvertTo-Json -InputObject $Value -Depth 40 -Compress:$Compact
 $bytes=[Text.Encoding]::UTF8.GetBytes($json);if($bytes.Length -gt 4194304){throw '[TC:DataTooLarge] 数据超过允许大小。'}
 if($NewOnly -and [IO.File]::Exists($full)){throw '[TC:AlreadyExists] 记录已经存在。'}
 $temp=Join-Path $parent ('.write-'+[guid]::NewGuid().ToString('N')+'.tmp')
 $stream=$null
 try{
  $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  $node=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
  & $node {param($p) Set-TCPrivateAcl $p} $temp
  $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
  if([IO.File]::Exists($full)){if($NewOnly){throw '[TC:AlreadyExists] 记录已经存在。'};[IO.File]::Replace($temp,$full,[NullString]::Value)}
  else{[IO.File]::Move($temp,$full)}
 }finally{if($stream){$stream.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};[Array]::Clear($bytes,0,$bytes.Length)}
}
function Open-TCDLock {param([string]$Path,[int]$TimeoutMs=5000)
 $full=Assert-TCDPath $Path;$null=New-TCDDirectory ([IO.Path]::GetDirectoryName($full))
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($true){try{return [IO.File]::Open($full,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{if($watch.ElapsedMilliseconds -ge $TimeoutMs){throw '[TC:Busy] 另一个操作正在更新这些记录，请稍后重试。'};Start-Sleep -Milliseconds 40}}
}
function ConvertTo-TCDCanonical {param($Value)
 if($null -eq $Value){return $null}
 if($Value -is [DateTime]){return $Value.ToUniversalTime().ToString('o')}
 if($Value -is [string] -or $Value -is [ValueType]){return $Value}
 if($Value -is [Collections.IDictionary]){$out=[ordered]@{};foreach($name in @($Value.Keys|Sort-Object)){$out[[string]$name]=ConvertTo-TCDCanonical $Value[$name]};return $out}
 if($Value -is [Collections.IEnumerable]){$out=@();foreach($item in $Value){$out+=,(ConvertTo-TCDCanonical $item)};return ,$out}
 $out=[ordered]@{};foreach($name in @($Value.PSObject.Properties.Name|Sort-Object)){$out[$name]=ConvertTo-TCDCanonical $Value.$name};return $out
}
function Get-TCDDigest {param($Value)
 $canonical=ConvertTo-TCDCanonical $Value;$json=if($null -eq $canonical){'null'}else{ConvertTo-Json -InputObject $canonical -Depth 40 -Compress}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TCDPath {param([string]$Root,[ValidateSet('servers','deployments','identities','probes','pairing')][string]$Category,[string]$Id)
 $base=Join-Path (Assert-TCDPath $Root) $Category
 if($Id){return Join-Path $base (Assert-TCDId $Id)}
 return $base
}
function Get-TCDStateSize {param([string]$Path)
 $full=Assert-TCDPath $Path;$length=if([IO.File]::Exists($full)){(Get-Item -LiteralPath $full).Length}else{0}
 [pscustomobject]@{Path=$full;Bytes=$length;LimitBytes=4194304;State=$(if($length -gt 4194304){'TooLarge'}elseif($length -ge 3355443){'NearLimit'}else{'Normal'});Message=$(if($length -ge 3355443){'记录接近大小上限，请先导出诊断并保留原文件；删除展示记录不会物理缩小此文件。'}else{''})}
}
function Assert-TCLocalCleanupReady {param([string]$Root)
 $base=Join-Path (Assert-TCDPath $Root) 'local-cleanup'
 if(-not [IO.Directory]::Exists($base)){return}
 foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory)){
  $journal=Read-TCDJson (Join-Path $dir.FullName 'journal.json') -AllowMissing
  if($journal -and (Get-TCDField $journal Status '') -notin @('Completed','RolledBack')){throw '[TC:CleanupRecoveryRequired] 上次本机清理尚未结束，请先在部署中心完成本机恢复。'}
 }
}
Export-ModuleMember -Function Get-TCDField,Assert-TCDId,Assert-TCDPath,Assert-TCDFields,New-TCDDirectory,Read-TCDJson,Write-TCDJson,Open-TCDLock,Get-TCDDigest,Get-TCDPath,Get-TCDStateSize,Assert-TCLocalCleanupReady
