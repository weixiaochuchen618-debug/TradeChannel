#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-components-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $root 'runtime'))
foreach($leaf in @('version.json','package.sha256','runtime\TradeChannelGuard.dll','runtime\TCDevicePath.dll','runtime\TradeChannel.Components.ps1')){[IO.File]::Copy((Join-Path $PackageDirectory $leaf),(Join-Path $root $leaf))}
# Match the protected installation contract, including the temporary parents.
foreach($item in @((Get-Item -LiteralPath $root))+@(Get-ChildItem -LiteralPath $root -Recurse -Force)){
 $acl=if($item.PSIsContainer){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
 $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
 foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')){
  $rights=if($sid -eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
  $inherit=if($item.PSIsContainer){'ContainerInherit,ObjectInherit'}else{'None'}
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,$inherit,'None','Allow'))
 };Set-Acl -LiteralPath $item.FullName -AclObject $acl
}
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
$runner=Join-Path $root 'load.ps1'
[IO.File]::WriteAllText($runner,@'
param($Root,$Name,$Preload)
$ErrorActionPreference='Stop'
try{if($Preload){Add-Type -Path $Preload};. (Join-Path $Root 'runtime\TradeChannel.Components.ps1');Initialize-TCRuntimeComponent -PackageRoot $Root -Name $Name;'Loaded'}catch{if($_.Exception.Message -match '^\[TC:([A-Za-z]+)\]'){$matches[1]}else{$_.Exception.GetType().Name};exit 4}
'@,[Text.UTF8Encoding]::new($true))
function Load {param($name='TCDevicePath',$preload='')
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$runner,'-Root',$root,'-Name',$name)
 if($preload){$arguments+=@('-Preload',$preload)}
 & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments
}
try{
 $code=Load;Check ($code -eq 'Loaded') ('valid device helper loads from verified package: '+$code)
 Check ((Load TradeChannelGuard) -eq 'Loaded') 'valid protection library loads without installing filters'
 $dll=Join-Path $root 'runtime\TCDevicePath.dll';$original=[IO.File]::ReadAllBytes($dll)
 [IO.File]::Delete($dll);Check ((Load) -eq 'ComponentMissing') 'missing helper has explicit integrity error'
 [IO.File]::WriteAllBytes($dll,$original);[IO.File]::AppendAllText($dll,'tampered')
 Check ((Load) -eq 'ComponentIntegrityInvalid') 'tampered helper never loads'
 [IO.File]::WriteAllBytes($dll,$original)
 $versionPath=Join-Path $root 'version.json';$version=[IO.File]::ReadAllText($versionPath);[IO.File]::WriteAllText($versionPath,'{"Version":"0.16.99"}')
 Check ((Load) -eq 'ComponentVersionConflict') 'mixed version helper rejected even with valid DLL digest'
 [IO.File]::WriteAllText($versionPath,$version)
 $other=Join-Path $root 'other.dll';[IO.File]::WriteAllBytes($other,$original)
 Check ((Load TCDevicePath $other) -eq 'ComponentVersionConflict') 'preloaded different package path cannot replace the verified component'
 $acl=Get-Acl -LiteralPath $dll;$weak=Get-Acl -LiteralPath $dll
 $weak.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Write','Allow'));Set-Acl -LiteralPath $dll -AclObject $weak
 Check ((Load) -eq 'ComponentUnsafeAcl') 'ordinary-user write permission is rejected'
 Set-Acl -LiteralPath $dll -AclObject $acl
 $result=[pscustomobject]@{Passed=$true;Checks=$checks;NetworkChanges=0;ProtectionChanges=0;Fixture='temporary minimal package'}
 if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json -Compress
}finally{
 $full=[IO.Path]::GetFullPath($root)
 if($full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^tc-components-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
