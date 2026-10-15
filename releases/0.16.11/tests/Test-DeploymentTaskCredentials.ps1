#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-task-cred-'+[guid]::NewGuid().ToString('N'))
$flow=Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -PassThru -DisableNameChecking
$registry=Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -PassThru -DisableNameChecking
$store=Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -PassThru -DisableNameChecking
$transport=Import-Module (Join-Path $PackageRoot 'DeploymentTransport.psm1') -PassThru -DisableNameChecking
$checks=New-Object 'Collections.Generic.List[string]';$passed=$false;$failure=''
function Check {param([bool]$Ok,[string]$Message)if(-not $Ok){throw $Message};$checks.Add($Message)}
function SaveFixture {param($Run)& $flow {param($Root,$Run)Save-TCDeploymentRun $Root $Run} $root $Run}
function PinFixture {param($ServerId,[string]$Fingerprint=('SHA256:'+('A'*43)),[string]$User='root')
 & $registry {param($Root,$Id,$Fingerprint,$User)
  $reg=Read-TCServerRegistry $Root;$server=@($reg.Servers|Where-Object LocalRecordId -eq $Id)[0]
  $server.PinnedHostKey=$Fingerprint;$server.Connection.User=$User;$server.RecordState='Active'
  Write-TCDJson (Join-Path (Get-TCDPath $Root servers) 'registry.json') $reg
 } $root $ServerId $Fingerprint $User
}
function FixtureSecret {param([string]$Text='  FAKE_TaskPassword_密码!  ')@{Kind='Password';Password=(ConvertTo-SecureString $Text -AsPlainText -Force)}}
function SecretEquals {param($Secure,[string]$Expected)$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure);try{return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) -ceq $Expected)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}}
try{
 $run=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -Name 'Task credential fixture'
 PinFixture $run.ServerRecordId
 $revision=[guid]::NewGuid().ToString();$secret=FixtureSecret
 $saved=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $revision
 $path=Join-Path $root ('deployments\credentials\'+$run.RunId+'.json')
 $json=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
 Check ($saved.Saved -and $saved.Protection -ceq 'DPAPI.CurrentUser' -and $json -notmatch 'FAKE_TaskPassword|密码!|PrivateKeyPem') 'The envelope is DPAPI-protected and contains no plaintext credential'
 $info=Get-TCDeployTaskCredential -Root $root -RunId $run.RunId -InfoOnly
 Check ($info.Available -and -not $info.Credential -and $info.Binding.RunId -ceq $run.RunId) 'Listing task availability never returns a credential'
 $reloaded=Get-TCDeployTaskCredential -Root $root -RunId $run.RunId
 Check (SecretEquals $reloaded.Credential.Password '  FAKE_TaskPassword_密码!  ') 'Password characters and whitespace survive encrypted reload'
 $savedAgain=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $revision
 Check ([DateTimeOffset]$savedAgain.ExpiresAtUtc -eq [DateTimeOffset]$saved.ExpiresAtUtc) 'Reconnecting the same credential revision cannot extend its lifetime'
 $replacement=[guid]::NewGuid().ToString()
 $null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential (FixtureSecret 'FAKE_REPLACEMENT') -CredentialRevision $replacement
 $removed=Remove-TCDeployTaskCredential -Root $root -RunId $run.RunId -CredentialRevision $revision
 Check (-not $removed -and [IO.File]::Exists($path)) 'A late failure cannot remove a newer submitted credential revision'
 $loaded=Get-TCDeployTaskCredential -Root $root -RunId $run.RunId
 Check (SecretEquals $loaded.Credential.Password 'FAKE_REPLACEMENT') 'A new explicitly submitted credential supersedes the old one'
 $otherRun=New-TCDeploymentRun -Root $root -Connection @{Host='192.0.2.11';Port=22;User='root';IdentityFile=''} -Name 'Other task'
 PinFixture $otherRun.ServerRecordId
 Copy-Item -LiteralPath $path -Destination (Join-Path $root ('deployments\credentials\'+$otherRun.RunId+'.json'))
 Check (-not (Get-TCDeployTaskCredential -Root $root -RunId $otherRun.RunId)) 'Copying an envelope to a different run cannot borrow its credential'
 PinFixture $run.ServerRecordId ('SHA256:'+('B'*43))
 Check (-not (Get-TCDeployTaskCredential -Root $root -RunId $run.RunId) -and -not [IO.File]::Exists($path)) 'A changed SSH fingerprint invalidates and removes task credentials'
 $null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $replacement
 PinFixture $run.ServerRecordId ('SHA256:'+('B'*43)) 'another'
 Check (-not (Get-TCDeployTaskCredential -Root $root -RunId $run.RunId)) 'A changed account cannot reuse the previous task credential'
 PinFixture $run.ServerRecordId
 $null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $replacement
 $envelope=Read-TCDJson $path;$envelope.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o');Write-TCDJson $path $envelope
 Check (-not (Get-TCDeployTaskCredential -Root $root -RunId $run.RunId) -and -not [IO.File]::Exists($path)) 'Expired credentials are removed instead of being submitted'
 $null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $replacement
 $envelope=Read-TCDJson $path;$envelope.ExpiresAtUtc=[DateTimeOffset]::UtcNow.AddHours(1).ToString('o');Write-TCDJson $path $envelope
 $rejected=$false;try{$null=Get-TCDeployTaskCredential -Root $root -RunId $run.RunId}catch{$rejected=$_.Exception.Message -match 'CredentialUnavailable'}
 Check ($rejected -and -not [IO.File]::Exists($path)) 'Editing expiry metadata cannot change the encrypted expiration contract'
 $key=@{Kind='PrivateKey';PrivateKeyPem=(ConvertTo-SecureString "-----BEGIN FAKE TEST PRIVATE KEY-----`nFIXTURE`n-----END FAKE TEST PRIVATE KEY-----" -AsPlainText -Force);Passphrase=(New-Object Security.SecureString)}
 $null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $key -CredentialRevision ([guid]::NewGuid().ToString())
 $loaded=Get-TCDeployTaskCredential -Root $root -RunId $run.RunId
 Check ($loaded.Credential.Kind -ceq 'PrivateKey' -and $loaded.Credential.Passphrase.Length -eq 0) 'An unencrypted private key reloads without inventing or requiring a passphrase'
 $legacy=Save-TCDeployCredential -Root $root -Credential $key
 $legacyLoaded=Get-TCDeploySavedCredential -Root $root -CredentialRef $legacy.CredentialRef
 Check ($legacyLoaded.Kind -ceq 'PrivateKey' -and $legacyLoaded.Passphrase.Length -eq 0) 'Existing saved management keys also reload an empty passphrase correctly'
 $run|Add-Member NoteProperty CredentialCleanupPending $true
 $run.Status='Cancelled';$null=SaveFixture $run
 Check (-not [IO.File]::Exists($path)) 'Terminal run persistence removes credentials even when the UI is closed'
 Check (-not $run.CredentialCleanupPending -and -not (Get-TCDeploymentRun -Root $root -RunId $run.RunId).CredentialCleanupPending) 'Successful terminal cleanup clears any earlier pending-cleanup indication'
 $blocked=$false;try{$null=Save-TCDeployTaskCredential -Root $root -RunId $run.RunId -Credential $secret -CredentialRevision $replacement}catch{$blocked=$_.Exception.Message -match 'CredentialTaskEnded'}
 Check $blocked 'A late callback cannot recreate credentials for a completed or cancelled task'
 $unsafe=$false;try{$null=Remove-TCDeployTaskCredential -Root $root -RunId '..\outside'}catch{$unsafe=$_.Exception.Message -match 'InvalidId'}
 Check $unsafe 'Credential cleanup rejects noncanonical task identifiers'
 $passed=$true
}catch{$failure=$_.Exception.Message;throw}
finally{
 $result=[pscustomobject]@{Passed=$passed;Count=$checks.Count;Checks=@($checks.ToArray());Failure=$failure;PowerShellVersion=$PSVersionTable.PSVersion.ToString();RealCredentialsRead=0;RemoteOperations=0}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))}
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^tc-task-cred-[0-9a-f]{32}$'){throw 'Fixture cleanup scope changed'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
 $result|Select-Object Passed,Count,Failure,PowerShellVersion|ConvertTo-Json
}
