#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$LegacyPackageRoot,[Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $LegacyPackageRoot 'DeploymentFlow.psm1') -DisableNameChecking
Import-Module (Join-Path $LegacyPackageRoot 'OperationHistory.psm1') -DisableNameChecking
function ContentSnapshot {return @(Get-ChildItem -LiteralPath $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash})}
$before=ContentSnapshot;$rows=New-Object 'Collections.Generic.List[object]'
foreach($folder in @(Get-ChildItem -LiteralPath (Join-Path $Root 'deployments/runs') -Directory)){
 $run=Get-TCDeploymentRun -Root $Root -RunId $folder.Name
 if($run.SchemaVersion -ne 1 -or $run.LastRemoteMutation.State -cne 'NotApplied' -or $run.RecoveryRequired -or $run.Status -cne 'WaitingUser' -or $run.Stage -cne 'RecoveryVerified' -or @($run.ResolvedMutationHistory).Count -ne 1){throw 'Legacy Flow misread new terminal state'}
 $rows.Add([pscustomobject]@{RunId=$run.RunId;SchemaVersion=$run.SchemaVersion;State=$run.LastRemoteMutation.State;RecoveryRequired=$run.RecoveryRequired;OriginalError=$run.ResolvedMutationHistory[0].OriginalError.Code})
}
$history=@(Get-TCOperationHistory -Root $Root -IncludeHidden)
if(@($history|Where-Object {$_.SourceKind -eq 'DeploymentRun'}).Count -ne $rows.Count){throw 'Legacy history lost terminal runs'}
if(@($history|Where-Object {$_.ProtectionReasons -contains 'UnresolvedMutation' -or $_.ProtectionReasons -contains 'InFlightOperation'}).Count){throw 'Legacy history invented unresolved mutation'}
$after=ContentSnapshot
if(($before -join "`n") -cne ($after -join "`n")){throw 'Legacy read modified newly written records'}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),([pscustomobject]@{Passed=$true;LegacyVersion=(Get-Content (Join-Path $LegacyPackageRoot 'version.json') -Raw|ConvertFrom-Json).Version;Cases=$rows.ToArray();HistoryCount=$history.Count;NewDataByteIdentical=$true;Mode='ReadOnlyCompatibility';DoesNotAuthorizeOldMutations=$true}|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
