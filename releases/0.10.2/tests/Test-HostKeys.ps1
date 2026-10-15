#requires -Version 5.1
# Only generated known_hosts files are changed. No SSH login or network action.
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'LinuxServerSetup.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([IO.Path]::GetTempPath()) ('TC-HostKeys-'+[guid]::NewGuid().ToString('N'))
try {
 & $module {param($Directory) New-TCLinuxDirectory $Directory} $work
 $path=Join-Path $work 'known_hosts';$salt=[byte[]](1..20)
 $hmac=New-Object Security.Cryptography.HMACSHA1;$hmac.Key=$salt
 try{$hash=$hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes('8.8.8.8'))}finally{$hmac.Dispose()}
 $hashed='|1|'+[Convert]::ToBase64String($salt)+'|'+[Convert]::ToBase64String($hash)
 $name=[Text.Encoding]::ASCII.GetBytes('ssh-ed25519');$blob=New-Object IO.MemoryStream
 $blob.Write([byte[]]@(0,0,0,$name.Length),0,4);$blob.Write($name,0,$name.Length);$blob.Write([byte[]]@(0,0,0,32),0,4);$blob.Write((New-Object byte[] 32),0,32)
 $key='ssh-ed25519 '+[Convert]::ToBase64String($blob.ToArray());$blob.Dispose()
 [IO.File]::WriteAllLines($path,@(('8.8.8.8 '+$key),('8.8.8.80 '+$key),('[8.8.8.8]:2222 '+$key),($hashed+' '+$key)))
 & $module {param($File) Protect-TCLinuxPath $File} $path
 $result=Reset-TCLinuxHostKey -ServerHost '8.8.8.8' -Port 22 -Root $work
 $lines=@(Get-Content -LiteralPath $path)
 if($result.RemovedEntries -ne 2 -or $lines.Count -ne 2 -or -not @($lines|Where-Object {$_ -like '8.8.8.80 *'}).Count -or -not @($lines|Where-Object {$_ -like '[[]8.8.8.8]:2222 *'}).Count){throw 'Host-key reset removed another host/port or failed to remove the hashed target.'}
 [pscustomobject]@{Passed=$true;RemovedTargetEntries=2;SimilarHostPreserved=$true;OtherPortPreserved=$true;HashedTargetRemoved=$true;NetworkChanges=0}
}finally{
 Remove-Module LinuxServerSetup -ErrorAction SilentlyContinue
 $full=[IO.Path]::GetFullPath($work);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-HostKeys-[0-9a-f]{32}$'){throw 'Cleanup rejected.'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
