#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$target=Join-Path $PSScriptRoot 'TradeChannel.exe'
$desktop=[Environment]::GetFolderPath('DesktopDirectory')
if(-not(Test-Path -LiteralPath $target -PathType Leaf)){throw '请完整解压 TradeChannel 安装包后创建快捷方式。'}
if(-not $desktop -or -not(Test-Path -LiteralPath $desktop -PathType Container)){throw '未找到当前用户的桌面目录。'}
$path=Join-Path $desktop 'TradeChannel.lnk'
$shell=New-Object -ComObject WScript.Shell
try{
 $link=$shell.CreateShortcut($path)
 if((Test-Path -LiteralPath $path) -and $link.TargetPath -ne $target -and $link.Description -notlike 'TradeChannel *'){
  throw '桌面存在同名的其他快捷方式，请先重命名它，避免覆盖。'
 }
 $link.TargetPath=$target;$link.WorkingDirectory=$PSScriptRoot
 $link.IconLocation=(Join-Path $PSScriptRoot 'assets\TradeChannel.ico')+',0'
 $link.Description='TradeChannel 交易通道；打开只读取状态，连接由你控制'
 $link.WindowStyle=1;$link.Save()
 $verify=$shell.CreateShortcut($path)
 if($verify.TargetPath -ne $target -or $verify.WorkingDirectory -ne $PSScriptRoot){throw '桌面快捷方式回读未通过。'}
 [pscustomobject]@{path=$path;TargetPath=$target;Friendly='桌面 TradeChannel 快捷方式已创建。双击即可打开控制台。'}
}finally{if($shell){$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
