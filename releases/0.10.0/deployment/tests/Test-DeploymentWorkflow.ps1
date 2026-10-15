#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot)
$ErrorActionPreference='Stop';if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
Import-Module (Join-Path $PackageRoot 'DeploymentFlow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PackageRoot 'NodeStore.psm1') -DisableNameChecking
$flow=Get-Module DeploymentFlow;$registry=Get-Module ServerRegistry;$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Name)$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Assert-Check $rejected $Name}
$root=Join-Path $PackageRoot ('deployment\test-runs\workflow-'+[guid]::NewGuid().ToString('N'))
try{
 $connection=@{Host='1.1.1.1';Port=22;User='root';IdentityFile=''}
 $a=Set-TCServerRecord -Root $root -Connection $connection -Name 'First';$b=Set-TCServerRecord -Root $root -Connection $connection -Name 'Second'
 Assert-Check ($a.LocalRecordId -ceq $b.LocalRecordId -and @(Get-TCServers $root).Count -eq 1) 'Repeated endpoint preparation keeps one provisional card'
 $jwk=@{kty='RSA';n=('A'*512);e='AQAB'};$owner=[guid]::NewGuid().ToString();$node=[guid]::NewGuid().ToString();$public=[Convert]::ToBase64String((New-Object byte[] 32))
 $info=@{RemoteOwnerId=$owner;Node=@{NodeId=$node;ServerPublicKey=$public};ManagementSigningPublicKey=$jwk;OwnershipState='Applied';ManagementApiVersion=2}
 $null=Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $info
 $changed=@{RemoteOwnerId=$owner;Node=@{NodeId=$node;ServerPublicKey=$public};ManagementSigningPublicKey=@{kty='RSA';n=('B'*512);e='AQAB'};OwnershipState='Applied';ManagementApiVersion=2}
 Assert-Reject {Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $changed} 'Pinned management signing identity cannot be replaced'
 $info.ManagementSigningPublicKey=$null;$null=Set-TCServerRecord -Root $root -Id $a.LocalRecordId -ServerInfo $info
 Assert-Check ((Get-TCServer $root $a.LocalRecordId).ManagementSigningPublicKey.n -ceq ('A'*512)) 'Null management response does not erase existing pin'
 $run=New-TCDeploymentRun -Root $root -Connection $connection -Name 'Workflow candidate'
 # Private test seam replaces only a read-only local inventory, never calls network setters.
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0','10.0.0.0/8','172.20.0.0/16','192.168.20.0/24') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('172.21.0.0/16')}} $root $run
 Assert-Check ($subnet -ceq '172.22.0.0/24') 'Remote/local supernet overlap excluded with 172 fallback'
 & $flow {function script:Get-TCDeploymentLocalNetworks { @('0.0.0.0/0') }}
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@('10.78.0.0/24')}} $root $run
 Assert-Check ($subnet -ceq '10.79.0.0/24') 'Remote inspection networks participate in selection; default route ignored'
 $ref=@{RunId=$run.RunId;PipeName='TCDeploy-'+('A'*32);InstanceId=[guid]::NewGuid().ToString();ProcessId=0;StartTimeUtcTicks='0';Root=$root};$run.SessionRef=$ref
 & $flow {
  $script:TestDispatchRoot=$null;$script:TestDispatchRun=$null
  function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,$Input,[string]$OperationId)
   $saved=Get-TCDeploymentRun $script:TestDispatchRoot $script:TestDispatchRun
   if($saved.Status -ne 'Dispatching' -or $saved.DispatchIntent.IntentId -cne $OperationId){throw 'Intent was not durable before transport call.'}
   throw 'Injected lost pipe response after accepted mutation'
  }
 } 
 & $flow {param($Root,$Run) $script:TestDispatchRoot=$Root;$script:TestDispatchRun=$Run.RunId} $root $run
 Assert-Reject {& $flow {param($Root,$Run) Start-TCDeploymentRemote $Root $Run authorize Authorize @{ClientRequest=@{}}} $root $run} 'Lost dispatch response is not retried blindly'
 $unknown=Get-TCDeploymentRun $root $run.RunId
 Assert-Check ($unknown.Status -ceq 'OutcomeUnknown' -and $unknown.DispatchIntent.Mutating -and $unknown.PendingOperationId -ceq $unknown.DispatchIntent.IntentId) 'Mutation intent is persisted before dispatch and retained unknown'
 $resumed=Set-TCDeploymentSession -Root $root -RunId $run.RunId -SessionRef $ref
 Assert-Check ($resumed.Stage -ceq 'Reconcile') 'Reauthentication preserves mutation reconciliation'
 # Use real wg.exe and real sing-box check to prepare candidate files without running a tunnel.
 $run=New-TCDeploymentRun -Root $root -Connection $connection -Name 'Actual isolated candidate'
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 $originalId=$run.ClientRequest.RequestId;$run.ClientRequest=$null;$run.RequestDirectory=$null
 & $flow {param($Root,$Run) Initialize-TCDeploymentRequest $Root $Run} $root $run
 Assert-Check ($run.ClientRequest.RequestId -ceq $originalId) 'Local request created before run-save crash is recovered without new identity'
 $server=Import-Module (Join-Path $PackageRoot 'ServerSetup.psm1') -PassThru -DisableNameChecking;$pair=& $server {param($Wg) New-TCKeyPair $Wg} (Join-Path $PackageRoot 'assets\wg.exe')
 $response=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$run.ClientRequest.RequestId;DeviceId=$run.ClientRequest.DeviceId;NodeId=[guid]::NewGuid().ToString();NodeName='Actual isolated candidate';ClientPublicKey=$run.ClientRequest.ClientPublicKey;ClientAddress='10.78.0.2/32';ServerPublicKey=$pair.Public;PublicEndpoint='1.1.1.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1}
 $pair=$null;$run.ClientResponse=$response;$null=& $flow {param($Root,$Run) Save-TCDeploymentRun $Root $Run} $root $run
 & $flow {
  $script:OriginalWorkflowSave=${function:Save-TCDeploymentRun};$script:CrashAfterImport=$true
  function script:Save-TCDeploymentRun {param($Root,$Run)
   if($script:CrashAfterImport -and $Run.CandidateTransaction -and $Run.CandidateTransaction.State -eq 'Imported'){$script:CrashAfterImport=$false;throw 'Injected process crash after importer commit'}
   & $script:OriginalWorkflowSave $Root $Run
  }
 }
 Assert-Reject {& $flow {param($Root,$Run) Complete-TCDeploymentCandidate $Root $Run} $root $run} 'Crash injected after real import before run ID commit'
 $disk=Get-TCDeploymentRun $root $run.RunId
 Assert-Check (-not $disk.CandidateNodeId -and $disk.CandidateTransaction.State -ceq 'Prepared' -and @(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1) 'Candidate transaction identifies unrecorded importer result'
 & $flow {param($Root,$Run) Complete-TCDeploymentCandidate $Root $Run;$null=Save-TCDeploymentRun $Root $Run} $root $disk
 $done=Get-TCDeploymentRun $root $run.RunId
 Assert-Check (@(Get-TCNodes (Join-Path $root 'Product')).Count -eq 1 -and $done.Stage -ceq 'ReadyInactive' -and $done.CandidateTransaction.State -ceq 'Completed') 'Import recovery adopts original candidate without duplicate'
 Assert-Check ((Get-TCServer $root $done.ServerRecordId).LinkedNodeIds -contains $done.CandidateNodeId) 'Ready candidate has durable server association'
 $templateManifest=Read-TCDJson $done.CandidateManifestPath;Assert-Check ($templateManifest.DirectDns -ceq '1.1.1.1') 'Actual candidate DNS is stored under DirectDns'
 $subnet=& $flow {param($Root,$Run) Select-TCDeploymentSubnet $Root $Run @{ConflictNetworks=@()}} $root $done
 Assert-Check ($subnet -ceq '10.79.0.0/24') 'Existing manifest ClientAddress /32 protects its enclosing /24'
 Assert-Check (-not $done.NetworkChanged) 'Preparation never activates candidate or changes current network'
 [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='Read-only inventories, temporary files, engine check only'}|ConvertTo-Json -Depth 8
}finally{
 $absolute=[IO.Path]::GetFullPath($root);$allowed=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'deployment\test-runs'))+'\';if((Test-Path -LiteralPath $absolute) -and $absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
