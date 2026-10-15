#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$TargetDirectory='C:\tradechannel',[Parameter(Mandatory=$true)][string]$BackupDirectory,[switch]$ValidateOnly,[int]$TestFailAfterWrites=0)
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
function CheckedInstallPath {param([string]$Path)
 if(-not [IO.Path]::IsPathRooted($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')){throw 'Install path must be an absolute local directory'}
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$cursor=$full
 while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Install path contains a reparse point'}};$cursor=[IO.Path]::GetDirectoryName($cursor)}
 return $full
}
function InstallChild {param([string]$Root,[string]$Relative)
 if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)'){throw 'Invalid package path'}
 $full=CheckedInstallPath (Join-Path $Root $Relative)
 if(-not $full.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package path escaped installation'};return $full
}
function ReadInstallManifest {param([string]$Root)
 $entries=@{};$manifest=InstallChild $Root 'package.sha256'
 if((Get-Item -LiteralPath $manifest).Length -gt 1048576){throw 'Package manifest too large'}
 foreach($line in [IO.File]::ReadAllLines($manifest)){
  if(-not $line){continue};$parts=$line -split '\|',2
  if($parts.Count -ne 2 -or $parts[0] -notmatch '^[A-Fa-f0-9]{64}$' -or $entries.ContainsKey($parts[1]) -or $parts[1] -ieq 'package.sha256'){throw 'Invalid package manifest'}
  $file=InstallChild $Root $parts[1]
  if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $parts[0]){throw ('Package integrity failure: '+$parts[1])}
  $entries[$parts[1]]=$parts[0]
 }
 $entries['package.sha256']=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
 foreach($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)){$relative=$file.FullName.Substring($Root.Length+1);$null=InstallChild $Root $relative;if(-not $entries.ContainsKey($relative)){throw ('Unmanaged file in dedicated installation: '+$relative)}}
 if($entries.Count -lt 20){throw 'Incomplete product package'}
 return $entries
}
function SetInstallAcl {param([string]$Path,[bool]$Directory)
 $acl=if($Directory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
 $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')));$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')){
  $rights=if($sid -eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
  $identity=New-Object Security.Principal.SecurityIdentifier($sid)
  $rule=if($Directory){New-Object Security.AccessControl.FileSystemAccessRule($identity,$rights,'ContainerInherit,ObjectInherit','None','Allow')}else{New-Object Security.AccessControl.FileSystemAccessRule($identity,$rights,'Allow')}
  $null=$acl.AddAccessRule($rule)
 }
 Set-Acl -LiteralPath $Path -AclObject $acl
}
function AssertInstallAcl {param([string]$Path)
 $acl=Get-Acl -LiteralPath $Path
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544') -or -not $acl.AreAccessRulesProtected){throw 'Installation ownership or inheritance is unsafe'}
 $mask=[Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $mask)){throw 'Installation permits writes by an untrusted identity'}}
}
$source=CheckedInstallPath $PackageDirectory;$target=CheckedInstallPath $TargetDirectory;$backup=CheckedInstallPath $BackupDirectory
if($target.Length -le 3 -or $target -ieq $source -or $target.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $backup -ieq $target -or $backup.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Installation and backup require separate dedicated directories'}
foreach($pair in @(@($source,$target),@($source,$backup),@($target,$backup))){if($pair[0] -ieq $pair[1] -or $pair[0].StartsWith($pair[1]+'\',[StringComparison]::OrdinalIgnoreCase) -or $pair[1].StartsWith($pair[0]+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source, installation and backup directories must not overlap'}}
foreach($reserved in @([Environment]::GetFolderPath('UserProfile'),[Environment]::GetFolderPath('DesktopDirectory'),[Environment]::GetFolderPath('CommonApplicationData'),(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'),$env:WINDIR)){if($reserved -and $target -ieq ([IO.Path]::GetFullPath($reserved).TrimEnd('\'))){throw 'Refusing to replace a shared or data directory'}}
if($TestFailAfterWrites -gt 0 -and -not $target.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){throw 'Failure injection is restricted to disposable temp installations'}
$entries=ReadInstallManifest $source
$startup=Import-Module (Join-Path $source 'Startup.psm1') -PassThru -DisableNameChecking
$null=& $startup {param($p)Get-TCStartupPackage $p} $source
$version=[string]([IO.File]::ReadAllText((Join-Path $source 'version.json'))|ConvertFrom-Json).Version
$old=@{}
if([IO.Directory]::Exists($target) -and @(Get-ChildItem -LiteralPath $target -Force).Count){$old=ReadInstallManifest $target}
if($ValidateOnly){[pscustomobject]@{Validated=$true;Version=$version;Files=$entries.Count;Upgrade=($old.Count -gt 0);Target=$target};return}
foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe' OR Name='sing-box.exe' OR Name='TradeChannel.exe' OR Name='TradeChannelDeployHost.exe'" -ErrorAction Stop)){
 if($process.ProcessId -eq $PID){continue};$command=[string]$process.CommandLine
 if($command -match '-EncodedCommand\s+([A-Za-z0-9+/=]+)'){try{$command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($matches[1]))}catch{}}
 if(($process.ExecutablePath -and [string]$process.ExecutablePath -like ($target+'\*')) -or $command.IndexOf($target+'\',[StringComparison]::OrdinalIgnoreCase) -ge 0){throw 'Close the old console and complete its active operations before installing'}
}
if(Test-Path -LiteralPath $backup){throw 'Backup directory already exists; use a new installation receipt directory'}
$null=[IO.Directory]::CreateDirectory($backup);SetInstallAcl $backup $true
$backupPackage=Join-Path $backup 'package';$null=[IO.Directory]::CreateDirectory($backupPackage)
foreach($relative in $old.Keys){$dest=InstallChild $backupPackage $relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));Copy-Item -LiteralPath (InstallChild $target $relative) -Destination $dest}
$written=New-Object 'Collections.Generic.List[string]'
try{
 $null=[IO.Directory]::CreateDirectory($target);SetInstallAcl $target $true
 foreach($relative in @($entries.Keys|Sort-Object @{Expression={$_ -eq 'package.sha256'}},@{Expression={$_}})){
  $dest=InstallChild $target $relative;$parent=[IO.Path]::GetDirectoryName($dest);$null=[IO.Directory]::CreateDirectory($parent)
  $cursor=$parent;while($cursor.StartsWith($target,[StringComparison]::OrdinalIgnoreCase)){SetInstallAcl $cursor $true;if($cursor -ieq $target){break};$cursor=[IO.Path]::GetDirectoryName($cursor)}
  $temp=$dest+'.tc-update-'+[guid]::NewGuid().ToString('N')
  try{Copy-Item -LiteralPath (InstallChild $source $relative) -Destination $temp;SetInstallAcl $temp $false
   if((Get-FileHash -LiteralPath $temp).Hash -ine $entries[$relative]){throw 'Staged file changed'}
   if([IO.File]::Exists($dest)){[IO.File]::Replace($temp,$dest,[NullString]::Value)}else{[IO.File]::Move($temp,$dest)}
   $written.Add($relative);SetInstallAcl $dest $false;AssertInstallAcl $dest
   if($TestFailAfterWrites -gt 0 -and $written.Count -eq $TestFailAfterWrites){throw 'Injected installation failure'}
  }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
 }
 foreach($relative in $old.Keys){if(-not $entries.ContainsKey($relative)){[IO.File]::Delete((InstallChild $target $relative));$written.Add($relative)}}
 $verified=ReadInstallManifest $target;AssertInstallAcl $target
 $receipt=[pscustomobject]@{Installed=$true;Version=$version;Target=$target;Backup=$backupPackage;VerifiedFiles=$verified.Count;AclVerified=$true;DataModified=$false;AtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
 [IO.File]::WriteAllText((Join-Path $backup 'installation-receipt.json'),($receipt|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true));$receipt
}catch{
 $failure=$_.Exception.Message
 foreach($relative in $written){$dest=InstallChild $target $relative;if($old.ContainsKey($relative)){Copy-Item -LiteralPath (InstallChild $backupPackage $relative) -Destination $dest -Force;SetInstallAcl $dest $false}else{if([IO.File]::Exists($dest)){[IO.File]::Delete($dest)}}}
 if($old.Count){$null=ReadInstallManifest $target;foreach($relative in $old.Keys){SetInstallAcl (InstallChild $target $relative) $false;AssertInstallAcl (InstallChild $target $relative)}}
 throw ('Installation failed; original program restored. '+$failure)
}
