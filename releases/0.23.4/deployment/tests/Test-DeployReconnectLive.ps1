#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
$root=Join-Path ([IO.Path]::GetTempPath()) ('TC-ReconnectSSH-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$checks=New-Object 'Collections.Generic.List[string]';$sessions=New-Object 'Collections.Generic.List[object]';$python=$null
function Check {param([bool]$Ok,[string]$Name)if(-not $Ok){throw $Name};$checks.Add($Name)}
function AwaitSession {param($Ref)
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$poll=Get-TCDeploySession $Ref;if($poll.Status -notin @('Connecting','Running')){return $poll};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
 throw 'Bounded local SSH wait expired'
}
Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -Force -DisableNameChecking
try{
 foreach($action in @('transport_plan','transport_apply')){
  $case=Join-Path $root $action;$null=[IO.Directory]::CreateDirectory($case);$meta=Join-Path $case 'fixture.json'
  $fixture=Join-Path $PSScriptRoot 'loopback_ssh_fixture.py'
  $python=Start-Process -FilePath 'python.exe' -ArgumentList ('"'+$fixture+'" "'+$meta+'" '+$action) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $case 'python.err')
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not (Test-Path -LiteralPath $meta)){if($python.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'Local SSH fixture did not become ready'};Start-Sleep -Milliseconds 100}
  $target=Get-Content -LiteralPath $meta -Raw -Encoding UTF8|ConvertFrom-Json
  $connection=@{Host='127.0.0.1';Port=$target.Port;User='root'}
  $credential=@{Kind='Password';Password=(ConvertTo-SecureString 'TC_Isolated_Fixture_Only_91!' -AsPlainText -Force)}
  $runId=[guid]::NewGuid().ToString('D')
  $first=Start-TCDeploySession -Root (Join-Path $case 'state') -RunId $runId -Connection $connection -Credential $credential -PinnedFingerprint $target.Fingerprint;$sessions.Add($first.SessionRef)
  $p=AwaitSession $first.SessionRef;Check ($p.HasSession -and $p.Code -ceq 'Authenticated') ($action+' initial authentication succeeds')
  $operationInput=@{};if($action -eq 'transport_apply'){$operationInput=@{PlanId=[guid]::NewGuid().ToString('D');ApprovedChangeDigest=('A'*64)}}
  $null=Invoke-TCDeployOperation -SessionRef $first.SessionRef -Operation $action -OperationInput $operationInput
  $p=AwaitSession $first.SessionRef;$diagnostic=Get-TCDeployAccessDiagnostic $p.Code
  Check (-not $p.HasSession -and $diagnostic.Kind -ceq 'Connection' -and $diagnostic.RetryWithCredential -and $p.AccessDiagnostic.Category -ceq 'Connection') ($action+' real execution disconnect has a connection diagnostic: '+$p.Code)
  Check ($p.Status -ceq $(if($action -eq 'transport_apply'){'OutcomeUnknown'}else{'Failed'})) ($action+' preserves whether remote writes may have happened')
  Check (@($p.Events|Where-Object {$_.FailureStage -in @('CommandStart','SendPayload','WaitResult')}).Count -gt 0) ($action+' records the safe execution failure phase')
  $second=Start-TCDeploySession -Root (Join-Path $case 'state') -RunId $runId -Connection $connection -Credential $credential -PinnedFingerprint $target.Fingerprint;$sessions.Add($second.SessionRef)
  $p=AwaitSession $second.SessionRef;Check $p.HasSession ($action+' reconnects using the same in-memory credential and pin')
  # After an unknown write, query state rather than resubmitting the mutation.
  $null=Invoke-TCDeployOperation -SessionRef $second.SessionRef -Operation deployment_state -OperationInput @{}
  $p=AwaitSession $second.SessionRef
  Check ($p.Status -ceq 'Completed' -and $p.Data.SessionStats.AuthenticationCount -eq 2 -and $p.Data.SessionStats.CommandCount -eq 2) ($action+' resumes with a read-only state query and does not replay a mutation')
  foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $case 'state') -Recurse -File)){
   Check (-not [IO.File]::ReadAllText($file.FullName).Contains('TC_Isolated_Fixture_Only_91!')) ($action+' executor files exclude the fixture password')
  }
  foreach($ref in $sessions.ToArray()){try{$null=Stop-TCDeploySession $ref}catch{}};$sessions.Clear()
  if(-not $python.HasExited){$python.Kill();$null=$python.WaitForExit(3000)};$python.Dispose();$python=$null
 }
 $result=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();Runtime=$PSVersionTable.PSVersion.ToString();NetworkScope='127.0.0.1 only';RealRemoteServersTouched=$false}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))}
 $result|ConvertTo-Json -Depth 5
}finally{
 foreach($ref in $sessions.ToArray()){try{$null=Stop-TCDeploySession $ref -Cancel;$null=Stop-TCDeploySession $ref}catch{}}
 if($python){if(-not $python.HasExited){$python.Kill();$null=$python.WaitForExit(3000)};$python.Dispose()}
 $full=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-ReconnectSSH-[a-f0-9]{32}$'){throw 'Fixture cleanup rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
