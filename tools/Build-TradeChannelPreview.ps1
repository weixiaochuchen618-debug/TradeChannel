#requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,[Parameter(Mandatory=$true)][string]$SourceDirectory,[Parameter(Mandatory=$true)][string]$OutputDirectory,[switch]$StageOnly)
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $SourceDirectory).Path
$core=Join-Path $source 'deployment\BuildPreviewCore.ps1'
if(-not (Test-Path -LiteralPath $core -PathType Leaf)){throw 'Source release lacks the versioned 0.10.0 build contract.'}
$parameters=@{SourceDirectory=$source;OutputDirectory=$OutputDirectory;StageOnly=$StageOnly};if($Version){$parameters.Version=$Version}
& $core @parameters