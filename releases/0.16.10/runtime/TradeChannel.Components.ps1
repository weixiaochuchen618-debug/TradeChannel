function Initialize-TCRuntimeComponent {param([ValidateSet('TradeChannelGuard','TCDevicePath')][string]$Name,[string]$PackageRoot)
 if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
 $relative='runtime\'+$Name+'.dll';$path=[IO.Path]::GetFullPath((Join-Path $PackageRoot $relative));$receipt=Join-Path $PackageRoot 'package.sha256'
 $cursor=$path
 while($cursor){if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '[TC:ComponentIntegrityInvalid] 运行组件路径不可信。'}};$cursor=[IO.Path]::GetDirectoryName($cursor)}
 if(-not [IO.File]::Exists($path) -or -not [IO.File]::Exists($receipt)){throw '[TC:ComponentMissing] 缺少随包运行组件，请安装完整版本。'}
 $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
 $writeMask=[Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
 foreach($item in @($PackageRoot,$path,$receipt)){
  $acl=Get-Acl -LiteralPath $item -ErrorAction Stop
  foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed -and ($rule.FileSystemRights -band $writeMask)){throw '[TC:ComponentUnsafeAcl] 运行组件目录可被其他账户写入，请重新安装完整版本。'}}
 }
 $rows=@([IO.File]::ReadAllLines($receipt)|Where-Object {$_ -match ('^[A-Fa-f0-9]{64}\|'+[regex]::Escape($relative)+'$')})
 if($rows.Count -ne 1 -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine ($rows[0] -split '\|')[0]){throw '[TC:ComponentIntegrityInvalid] 随包运行组件校验未通过。'}
 $version=[string]([IO.File]::ReadAllText((Join-Path $PackageRoot 'version.json'))|ConvertFrom-Json).Version
 $assembly=[Reflection.AssemblyName]::GetAssemblyName($path)
 if($assembly.Name -cne $Name -or $assembly.Version.ToString() -cne ($version+'.0')){throw '[TC:ComponentVersionConflict] 运行组件版本与当前软件不一致。'}
 $type=$Name -as [type]
 if($type){if(-not [string]::Equals($type.Assembly.Location,$path,[StringComparison]::OrdinalIgnoreCase)){throw '[TC:ComponentVersionConflict] 已加载的运行组件属于其他版本。'}}
 else{Add-Type -Path $path -ErrorAction Stop}
}
