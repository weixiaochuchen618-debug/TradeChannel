#requires -Version 5.1
# Server-only dependency installation. Import/status do not install anything.
# The bundled EXE is WireGuard's online bootstrap, not an offline MSI.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Get-TCInstallerContext {
 $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try{$principal=New-Object Security.Principal.WindowsPrincipal($identity)
  [pscustomobject]@{IsServer=($os.ProductType -ne 1);Build=[int]$os.BuildNumber;Is64Bit=[Environment]::Is64BitOperatingSystem;Elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
 }finally{$identity.Dispose()}
}
function Get-TCInstalledWireGuard {
 $path=Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
 [bool](Test-Path -LiteralPath $path -PathType Leaf)
}
function Assert-TCInstallerPath {
 param([string]$Path)
 if([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f"<>|?*]' -or $Path.Substring(2).Contains(':')){throw '安装文件必须使用本机绝对路径。'}
 $full=[IO.Path]::GetFullPath($Path);$cursor=$full
 while($cursor){
  if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '安装目录不能经过链接或重解析点。'}}
  $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
 }
 $full
}
function Assert-TCWireGuardSignature {
 param([string]$Path)
 $signature=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
 if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=WireGuard LLC(?:,|$)'){
  throw 'WireGuard 官方签名校验失败，安装未执行。'
 }
}
function Get-TCBundledInstaller {
 param([string]$PackageRoot)
 $package=Assert-TCInstallerPath $PackageRoot
 $file=Assert-TCInstallerPath (Join-Path $package 'assets\wireguard-installer.exe')
 $manifest=Assert-TCInstallerPath (Join-Path $package 'package.sha256')
 if(-not(Test-Path -LiteralPath $file -PathType Leaf) -or -not(Test-Path -LiteralPath $manifest -PathType Leaf)){throw '随包安装程序或校验清单缺失，请完整重新解压。'}
 $entries=@(foreach($line in [IO.File]::ReadAllLines($manifest,[Text.Encoding]::UTF8)){
  $pair=$line -split '\|',2
  if($pair.Count -eq 2 -and $pair[1].Replace('/','\') -ieq 'assets\wireguard-installer.exe'){$pair[0]}
 })
 if($entries.Count -ne 1 -or $entries[0] -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $entries[0]){throw '随包安装程序校验未通过，安装未执行。'}
 Assert-TCWireGuardSignature $file
 [pscustomobject]@{Path=$file;Hash=$entries[0]}
}
function New-TCInstallerDirectory {
 param([string]$Path)
 $full=Assert-TCInstallerPath $Path
 $acl=New-Object Security.AccessControl.DirectorySecurity
 $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')));$acl.SetAccessRuleProtection($true,$false)
 foreach($id in @('S-1-5-18','S-1-5-32-544')){
  $sid=New-Object Security.Principal.SecurityIdentifier($id)
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
 }
 if(-not(Test-Path -LiteralPath $full)){$null=[IO.Directory]::CreateDirectory($full,$acl)}
 $item=Get-Item -LiteralPath $full -Force
 if(-not $item.PSIsContainer){throw '安装目录已被其他文件占用。'}
 # Only validate existing directories; never rewrite an unrelated directory ACL.
 $existing=Get-Acl -LiteralPath $full
 if(-not $existing.AreAccessRulesProtected -or $existing.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw '安装目录权限不符合要求。'}
 foreach($rule in $existing.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')){throw '安装目录存在其他用户权限。'}
 }
 $full
}
function Receive-TCOfficialInstaller {
 param([string]$Destination)
 # Fixed official source, no third-party mirrors or user-supplied URL.
 $oldProtocol=[Net.ServicePointManager]::SecurityProtocol
 try{
  [Net.ServicePointManager]::SecurityProtocol=$oldProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri 'https://download.wireguard.com/windows-client/wireguard-installer.exe' -OutFile $Destination -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop | Out-Null
 }catch{throw '无法从 WireGuard 官网下载安装程序。可改用随包引导器；完整组件下载仍需服务器能够访问官网。'}
 finally{[Net.ServicePointManager]::SecurityProtocol=$oldProtocol}
}
function Invoke-TCWireGuardBootstrap {
 param([string]$Path)
 $process=Start-Process -FilePath $Path -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
 try{[int]$process.ExitCode}finally{$process.Dispose()}
}
function Invoke-TCWireGuardInstall {
 [CmdletBinding()]
 param([ValidateSet('Bundled','Online')][string]$Source='Bundled',[string]$PackageRoot=$PSScriptRoot,[string]$Root=(Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'))
 $context=Get-TCInstallerContext
 if(-not $context.IsServer){throw '交易电脑使用内置 WireGuard 协议，无需安装图形客户端；此操作仅用于转发服务器。'}
 if($context.Build -ne 20348 -or -not $context.Is64Bit){throw '当前服务器安装向导支持 64 位 Windows Server 2022，请在目标服务器执行。'}
 if(-not $context.Elevated){throw '请以管理员身份打开服务器控制台后安装。'}
 if(Get-TCInstalledWireGuard){return [pscustomobject]@{Installed=$true;AlreadyInstalled=$true;Source=$Source;RebootRequired=$false;Friendly='WireGuard 已安装，保留原组件和隧道设置。';Next='返回环境检查继续；没有重新安装或启动隧道。'}}
 $bundle=$null;if($Source -eq 'Bundled'){$bundle=Get-TCBundledInstaller $PackageRoot}
 $base=Assert-TCInstallerPath $Root
 if(-not(Test-Path -LiteralPath $base)){$null=New-TCInstallerDirectory $base}
 $downloads=New-TCInstallerDirectory (Join-Path $base 'installer-downloads')
 $lock=$null
 try{
  $lockPath=Assert-TCInstallerPath (Join-Path $downloads '.install.lock')
  try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw '已有 WireGuard 安装操作正在进行，请等待完成。'}
  if(Get-TCInstalledWireGuard){return [pscustomobject]@{Installed=$true;AlreadyInstalled=$true;Source=$Source;RebootRequired=$false;Friendly='WireGuard 已安装，本次不重复安装。';Next='重新检查服务器环境。'}}
  $work=New-TCInstallerDirectory (Join-Path $downloads ([guid]::NewGuid().ToString('N')))
  $installer=Join-Path $work 'wireguard-installer.exe'
  if($Source -eq 'Bundled'){
   Copy-Item -LiteralPath $bundle.Path -Destination $installer -ErrorAction Stop
   if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $bundle.Hash){throw '复制后的安装程序校验失败，安装未执行。'}
  }else{Receive-TCOfficialInstaller $installer}
  Assert-TCInstallerPath $installer | Out-Null
  Assert-TCWireGuardSignature $installer
  $code=Invoke-TCWireGuardBootstrap $installer
  if($code -notin @(0,3010,1641)){throw ('WireGuard 安装未完成，返回代码 '+$code+'。没有将本次标记为成功。')}
  $installed=[bool](Get-TCInstalledWireGuard);$restart=$code -in @(3010,1641)
  if(-not $installed -and -not $restart){throw '安装程序已退出，但没有检测到 WireGuard，安装未通过回读。请检查服务器网络和安装结果。'}
  [pscustomobject]@{Installed=$installed;AlreadyInstalled=$false;Source=$Source;RebootRequired=$restart;ExitCode=$code;InstallerPath=$installer;BootstrapNeedsNetwork=$true;Friendly=$(if($restart){'官方安装程序要求重启服务器，重启后再检查组件。'}else{'WireGuard 组件已安装并通过文件回读；隧道仍需部署配置。'});Next=$(if($restart){'请安排服务器重启后返回环境检查；工具未发起重启。'}else{'重新检查服务器环境，然后继续节点部署。'})}
 }finally{if($lock){$lock.Dispose()}}
}
Export-ModuleMember -Function Invoke-TCWireGuardInstall
