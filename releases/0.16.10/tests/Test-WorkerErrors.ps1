#requires -Version 5.1
param([string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WorkerErrors.psm1') -DisableNameChecking
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
$id=[guid]::NewGuid().ToString('N')
foreach($code in @('EngineChanged','ServerBindingChanged','DiagnosticAddressChanged','SavedDefaultMissing','ComponentIntegrityInvalid')){
 $safe=Get-TCWorkerFailure -Failure ('[TC:'+$code+'] SECRET_RAW_PARSER_CONTENT {"password":"also-secret"}') -Action Session -RequestId $id -Phase Executing -MayHaveChanged $true
 Check ($safe.Code -ceq $code -and $safe.RequestId -ceq $id -and $safe.NextAction -ne 'ReviewOperation' -and ($safe|ConvertTo-Json) -notmatch 'SECRET_RAW|also-secret') ('known reason preserved without raw text: '+$code)
}
$unsafe=Get-TCWorkerFailure -Failure 'ConvertFrom-Json failed near {"secret":"AUTHORIZATION_SAMPLE"}' -Action Session -RequestId $id -Phase Executing -MayHaveChanged $true
Check ($unsafe.Code -eq 'WorkerStepFailed' -and $unsafe.OutcomeUnknown -and $unsafe.NextAction -eq 'ReconcileOperation' -and ($unsafe|ConvertTo-Json) -notmatch 'AUTHORIZATION_SAMPLE') 'ambiguous mutation never exposes source JSON or promises it failed before effects'
$before=Get-TCWorkerFailure -Failure 'parser private contents' -Action Session -RequestId $id
Check (-not $before.OutcomeUnknown -and $before.Phase -eq 'BeforeDispatch') 'failure before dispatch is not treated as remote execution'
$unknown=Get-TCWorkerFailure -Failure '[TC:SECRET_UNKNOWN_REASON] credential=raw' -Action Overview -RequestId $id
Check ($unknown.Code -eq 'WorkerStepFailed' -and ($unknown|ConvertTo-Json) -notmatch 'SECRET_UNKNOWN_REASON|credential=raw') 'unrecognized reason is not a path for leaking arbitrary content'
$known=Get-TCWorkerFailure -Failure '[TC:DispatchOutcomeUnknown] secret server output' -Action DeploymentProceed -RequestId $id -Phase Executing
Check ($known.OutcomeUnknown -and $known.ErrorId -cmatch '^[a-f0-9]{32}$') 'unknown remote outcome retains correlation and recovery state'
$result=[pscustomobject]@{Passed=$true;Checks=$checks;RawExceptionPublished=$false;NetworkChanges=0}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json
