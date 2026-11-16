#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath,[switch]$ExpectLegacyDefect)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$module=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-pipe-failure-'+[guid]::NewGuid().ToString('N'))
$ref=[pscustomobject]@{RunId=[guid]::NewGuid().ToString('D');InstanceId=[guid]::NewGuid().ToString('D');PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));ProcessId=2147483646;StartTimeUtcTicks='1';Root=$root}
$body=@{Command='Authenticate';Credential=@{Kind='Password';Password='FAKE_PIPE_FAILURE_ONLY'}}
$checks=0;$errorId='';$errorType='';$failure=''
function Check {param([bool]$Value,[string]$Message)if(-not $Value){throw $Message};$script:checks++}
try{
 try{& $module {param($r,$b)Invoke-TCDeployPipe -SessionRef $r -Body $b -ConnectTimeout 20 -TotalTimeoutMs 100} $ref $body;throw 'Missing pipe unexpectedly connected'}catch{$errorId=$_.FullyQualifiedErrorId;$errorType=$_.Exception.GetType().FullName}
 if($ExpectLegacyDefect){Check ($errorId -match 'VariableIsUndefined') 'Old finally must mask the original pipe failure with an uninitialized bytes variable'}
 else{
  Check ($errorId -notmatch 'VariableIsUndefined' -and ($errorType -match 'MethodInvocationException|TimeoutException' -or $errorId -match '^\[TC:PipeTimeout\]')) 'Pipe failure retains the original bounded timeout instead of a finally variable error'
  Check (-not $body.ContainsKey('Credential')) 'Failure before serialization still clears the private credential body'
  $valid=@{TrustDecisionId=[guid]::NewGuid().ToString('D');TrustOrigin='ExplicitUserConfirmation';RetryReason='ConnectionTimeout';RetryCount=2;PriorInstanceId=[guid]::NewGuid().ToString('D')}
  $copy=& $module {param($v)ConvertTo-TCDeployAccessContext $v} $valid
  Check ($copy.TrustDecisionId -ceq $valid.TrustDecisionId -and $copy.Count -eq 5) 'Diagnostic metadata preserves only the complete whitelist'
  foreach($mutation in @('Secret','BadId','BadReason','ExcessRetries','WrongOrigin')){
   $bad=$valid.Clone()
   switch($mutation){'Secret'{$bad.Password='FAKE_METADATA_ONLY'}'BadId'{$bad.TrustDecisionId='not-an-id'}'BadReason'{$bad.RetryReason="raw text`n"}'ExcessRetries'{$bad.RetryCount=3}'WrongOrigin'{$bad.TrustOrigin='AuthenticatedPin'}}
   $rejected=$false;try{$null=& $module {param($v)ConvertTo-TCDeployAccessContext $v} $bad}catch{$rejected=$true}
   Check $rejected ('Diagnostic metadata rejects '+$mutation+' before a process or credential submission')
  }
 }
}catch{$failure=$_.Exception.Message}
$result=[pscustomobject]@{Passed=(-not $failure);Checks=$checks;ExpectedLegacyDefect=[bool]$ExpectLegacyDefect;ErrorId=$errorId;ErrorType=$errorType;Failure=$failure;PackageRoot=$PackageRoot;SourceSHA256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'DeploymentTransport.psm1')).Hash;Boundary='random nonexistent local named pipe, bounded 100ms; no process launch, no SSH, no production data'}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
$result|ConvertTo-Json -Depth 6
if($failure){exit 1}
