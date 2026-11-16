#requires -Version 5.1
Set-StrictMode -Version 2.0
function Get-TCProductVersion {
 [CmdletBinding()]param([string]$PackageRoot=$PSScriptRoot)
 $path=Join-Path ([IO.Path]::GetFullPath($PackageRoot)) 'version.json'
 if(-not [IO.File]::Exists($path)){throw '产品版本元数据缺失，请完整解压安装包。'}
 $data=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json
 $value=[string]$data.Version
 if($value -notmatch '^\d+\.\d+\.\d+$'){throw '产品版本元数据格式无效。'}
 return $value
}
Export-ModuleMember -Function Get-TCProductVersion
