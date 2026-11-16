#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ConnectionTransactions.psm1') -PassThru -DisableNameChecking
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('TC-connection-diagnostic-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try{
 $result=& $module {
  param($DataRoot)
  $requestId=[guid]::NewGuid().ToString('N');$sentinel='DO_NOT_RETAIN_DIAGNOSTIC_SECRET'
  try{throw ('[TC:DiagnosticConfigReadFailed] '+$sentinel)}catch{$failure=CTFailure $_ 'VerifyTarget' $DataRoot $requestId}
  $path=Join-Path $DataRoot ('diagnostics\failures\'+$failure.DiagnosticId+'.json')
  $checks=New-Object 'Collections.Generic.List[string]'
  function CheckDiagnostic {param([bool]$Condition,[string]$Name)if(-not $Condition){throw $Name};$checks.Add($Name)}
  CheckDiagnostic ($failure.Code -ceq 'DiagnosticConfigReadFailed') 'The original classified code is retained'
  CheckDiagnostic ($failure.DiagnosticId -cmatch '^[a-f0-9]{32}$' -and [IO.File]::Exists($path)) 'The connection failure retains a real structural diagnostic'
  $raw=[IO.File]::ReadAllText($path);$diagnostic=$raw|ConvertFrom-Json
  CheckDiagnostic ($diagnostic.RequestId -ceq $requestId -and $diagnostic.Action -ceq 'ConnectionSwitch' -and $diagnostic.Stage -ceq 'VerifyTarget') 'Diagnostic identity binds request, action and phase'
  CheckDiagnostic (@($diagnostic.ExceptionChain).Count -gt 0 -and @($diagnostic.Frames).Count -gt 0) 'Exception types and source locations are retained'
  CheckDiagnostic (-not $raw.Contains($sentinel) -and -not (($failure|ConvertTo-Json).Contains($sentinel))) 'Exception text and secret sentinel remain absent'
  [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();RealNetworkChanges=0}
 } $fixture
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
 $result|ConvertTo-Json -Depth 5
}finally{
 $full=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-connection-diagnostic-[a-f0-9]{32}$'){throw 'Fixture cleanup path was rejected.'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
