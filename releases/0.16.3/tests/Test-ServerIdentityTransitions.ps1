#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$OutputPath)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Code,[string]$Name)
 $caught=$false;$actual='NoError'
 try{& $Action|Out-Null}catch{$actual=$_.FullyQualifiedErrorId;if($_.Exception.Message -match '\[TC:([A-Za-z0-9]+)\]'){$actual=$Matches[1]};$caught=$actual -like ($Code+'*')}
 if(-not $caught){throw ('FAILED: '+$Name+'; expected '+$Code+', actual '+$actual)};$checks.Add($Name)
}
function Copy-Public {param($Value)ConvertTo-Json -InputObject $Value -Depth 30 -Compress|ConvertFrom-Json}
function Wait-Session {param($Ref)
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$p=Get-TCDeploySession $Ref;if($p.Status -notin @('Connecting','Running')){return $p};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline)
 throw 'Local fixture session deadline exceeded.'
}
$taskRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-identity-transitions-'+[guid]::NewGuid().ToString('N'))
$fixturePackage=Join-Path $taskRoot 'package'
$python=$null;$liveRefs=New-Object 'Collections.Generic.List[object]'
$productionBinary=Join-Path $PackageRoot 'deployment\TradeChannelDeployHost.exe'
$productionHash=if([IO.File]::Exists($productionBinary)){(Get-FileHash $productionBinary).Hash}else{''}
try{
 Import-Module (Join-Path $PackageRoot 'DeploymentStore.psm1') -Force -DisableNameChecking
 $null=New-TCDDirectory $taskRoot
 foreach($relative in @('','deployment','assets','assets/lib','linux')){$null=New-TCDDirectory (Join-Path $fixturePackage $relative)}
 foreach($name in @('ServerRegistry.psm1','DraftDisposition.psm1','DeploymentTransport.psm1','DeploymentStore.psm1','DeploymentDependencies.psm1','DeploymentFlow.psm1','ProtocolSelection.psm1','LinuxServerSetup.psm1','LinuxJobManagement.ps1','NodeStore.psm1','NodeOperations.ps1')){Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination (Join-Path $fixturePackage $name)}
 Copy-Item -LiteralPath (Join-Path $PackageRoot 'deployment/dependencies.lock.json') -Destination (Join-Path $fixturePackage 'deployment/dependencies.lock.json')
 foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'assets/lib') -Filter '*.dll' -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $fixturePackage 'assets/lib')}
 foreach($name in @('transport_support.py','management_support.py','tradechannel_linux.py')){Copy-Item -LiteralPath (Join-Path $PackageRoot ('linux/'+$name)) -Destination (Join-Path $fixturePackage 'linux')}
 foreach($relative in @('ServerRegistry.psm1','DeploymentTransport.psm1','deployment/TradeChannelDeployHost.cs','tests/Test-ServerIdentityTransitions.ps1')){
  $bytes=[IO.File]::ReadAllBytes((Join-Path $PackageRoot $relative))
  Assert-Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM: '+$relative)
  if($relative -match '\.ps(m)?1$'){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot $relative),[ref]$tokens,[ref]$errors);Assert-Check (@($errors).Count -eq 0) ('PowerShell parse: '+$relative)}
 }
 Import-Module (Join-Path $fixturePackage 'DeploymentDependencies.psm1') -Force -DisableNameChecking
 Assert-Check (Test-TCDeploymentDependencies $fixturePackage).Ok 'Fixture dependencies match the official fixed-version lock'
 $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 $fixtureExe=Join-Path $fixturePackage 'deployment\TradeChannelDeployHost.exe'
 $build=@('/nologo','/target:exe','/platform:x64',('/out:'+$fixtureExe),'/reference:System.Web.Extensions.dll',('/reference:'+(Join-Path $fixturePackage 'assets/lib/Renci.SshNet.dll')),(Join-Path $PackageRoot 'deployment/TradeChannelDeployHost.cs'))
 $buildOutput=& $compiler @build 2>&1
 if($LASTEXITCODE -ne 0){throw ('Framework fixture compilation failed: '+($buildOutput -join ' '))}
 Assert-Check ([IO.File]::Exists($fixtureExe) -and $fixtureExe.StartsWith($taskRoot,[StringComparison]::OrdinalIgnoreCase)) 'Framework executable is compiled ONLY into this task fixture'
 Import-Module (Join-Path $fixturePackage 'DeploymentTransport.psm1') -Force -DisableNameChecking
 Import-Module (Join-Path $fixturePackage 'ServerRegistry.psm1') -Force -DisableNameChecking
 $registry=Get-Module ServerRegistry;$transport=Get-Module DeploymentTransport

 # The localhost endpoint never executes the uploaded backend. It verifies the
 # source hash and returns fixed public data for the exact read-only operations.
 $meta=Join-Path $taskRoot 'ssh.json';$statePath=Join-Path $taskRoot 'state.json';$log=Join-Path $taskRoot 'ssh-log.json'
 $emptyInfo=@{OwnershipState='NotInstalled';ManagementApiVersion=1;Node=$null;RemoteOwnerId=$null}
 $emptyInspection=@{Supported=$true;OwnedDeployment=$false;AlreadyDeployed=$false;DeployedStatus=$null;Issues=@()}
 Write-TCDJson $statePath @{ServerInfo=$emptyInfo;Inspection=$emptyInspection}
 $helper=Join-Path $PackageRoot 'tests/identity_ssh_fixture.py'
 $python=Start-Process -FilePath 'python.exe' -ArgumentList ('"'+$helper+'" "'+$meta+'" "'+$statePath+'" "'+$log+'"') -WindowStyle Hidden -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while(-not [IO.File]::Exists($meta)){if($python.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'Local SSH fixture did not start.'};Start-Sleep -Milliseconds 50}
 $ssh=Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json
 $connection=@{Host='127.0.0.1';Port=[int]$ssh.Port;User='root'}
 $credential=@{Kind='Password';Password=(ConvertTo-SecureString 'TC_Identity_Local_Fixture_Only!' -AsPlainText -Force)}
 $liveRoot=Join-Path $taskRoot 'live'
 $started=Start-TCDeploySession -Root $liveRoot -RunId ([guid]::NewGuid().ToString('D')) -Connection $connection -Credential $credential
 $ref=$started.SessionRef;$liveRefs.Add($ref);$poll=Wait-Session $ref
 Assert-Check ($poll.Code -ceq 'HostTrustRequired' -and -not $poll.HasSession -and $poll.ObservedFingerprint -ceq $ssh.Fingerprint -and $poll.HostKeyAlgorithm -match '^[A-Za-z0-9@._+-]+$' -and $poll.AccessDiagnostic.Category -ceq 'HostTrust') 'Unknown real localhost key is observed with algorithm but cannot authenticate'
 $wrong='SHA256:'+('X'*43)
 $null=Set-TCDeployCredential $ref $connection $credential $wrong;$poll=Wait-Session $ref
 Assert-Check ($poll.Code -ceq 'HostKeyChanged' -and -not $poll.HasSession) 'Changed localhost key is never silently trusted'
 $badCredential=@{Kind='Password';Password=(ConvertTo-SecureString 'LOCAL_SECRET_DO_NOT_PRINT' -AsPlainText -Force)}
 $null=Set-TCDeployCredential $ref $connection $badCredential $ssh.Fingerprint;$poll=Wait-Session $ref
 Assert-Check ($poll.Code -ceq 'AuthenticationFailed' -and $poll.AccessDiagnostic.Category -ceq 'Authentication' -and -not ((ConvertTo-Json $poll -Depth 20).Contains('LOCAL_SECRET_DO_NOT_PRINT'))) 'Actual SshAuthenticationException exposes only the safe authentication code'
 $null=Set-TCDeployCredential $ref $connection @{Kind='PrivateKey';PrivateKeyPem='-----BEGIN OPENSSH PRIVATE KEY-----INVALID_LOCAL_SECRET';Passphrase='LOCAL_SECRET_DO_NOT_PRINT'} $ssh.Fingerprint;$poll=Wait-Session $ref
 Assert-Check ($poll.Code -ceq 'PrivateKeyParseFailed' -and $poll.AccessDiagnostic.Category -ceq 'Credential' -and -not ((ConvertTo-Json $poll -Depth 20).Contains('INVALID_LOCAL_SECRET'))) 'Actual private-key parse failure is distinct and contains no secret exception text'
 $null=Set-TCDeployCredential $ref $connection $credential $ssh.Fingerprint;$poll=Wait-Session $ref
 Assert-Check ($poll.HasSession -and $poll.AcceptedFingerprint -ceq $ssh.Fingerprint -and $poll.Connection.Host -ceq '127.0.0.1' -and -not $poll.HasMutatingOperations) 'Actual executor proves endpoint accepted fingerprint and authentication generation'
 $hostRecord=Set-TCServerRecord -Root $liveRoot -Connection $connection -PinnedFingerprint $ssh.Fingerprint -SessionRef $ref
 Assert-Check ($hostRecord.HostTrustState -ceq 'Verified' -and $hostRecord.PinnedHostKey -ceq $ssh.Fingerprint -and $hostRecord.OwnershipState -ceq 'Unverified' -and $hostRecord.ManagementAccessState -ceq 'NeedsAuthentication' -and -not $hostRecord.RemoteOwnerId -and -not $hostRecord.NodeId -and -not $hostRecord.ServerPublicKey) 'First Ready/Authenticated login registers only proven SSH trust without requiring or inventing application server_info'
 $stats=Get-Content -LiteralPath $log -Raw|ConvertFrom-Json
 Assert-Check ($stats.Actions.Count -eq 0) 'First host-only pin registration performs no server_info inspect or Python command'
 Assert-Reject {Set-TCServerRecord -Root $liveRoot -Id $hostRecord.LocalRecordId -PinnedFingerprint $wrong -SessionRef $ref} HostChanged 'Host-only registration rejects a caller pin differing from the actual accepted fingerprint'
 Assert-Reject {Set-TCServerRecord -Root $liveRoot -Id $hostRecord.LocalRecordId -ServerInfo $emptyInfo -SessionRef $ref} IdentityReadRequired 'Authenticated poll alone cannot authenticate caller application fields'
 $wrongRef=Copy-Public $ref;$wrongRef.ProcessId++
 Assert-Reject {Set-TCDeployCredential $wrongRef $connection $badCredential $ssh.Fingerprint} SessionMismatch 'OS pipe-owner check rejects substituted PID before transmitting credential'
 $proof=Get-TCDeployServerIdentityEvidence -SessionRef $ref -TimeoutSeconds 15
 Assert-Check ($proof.ServerInfo.OwnershipState -ceq 'NotInstalled' -and $proof.Inspection.Supported -and $proof.ObservedFingerprint -ceq $ssh.Fingerprint) 'Actual SSH read-only evidence returns server_info and inspect in the verified session'
 $stats=Get-Content -LiteralPath $log -Raw|ConvertFrom-Json
 Assert-Check (($stats.Actions -join ',') -ceq 'server_info,inspect,server_info' -and $stats.Authenticated -eq 1 -and $stats.SourceDigestsVerified -eq 3) 'Coherent proof reads only empty-input server_info inspect server_info without repeated authentication'
 $checkedRecord=Set-TCServerRecord -Root $liveRoot -Id $hostRecord.LocalRecordId -ServerInfo $emptyInfo -SessionRef $ref
 Assert-Check ($checkedRecord.OwnershipState -ceq 'NotInstalled' -and -not $checkedRecord.RemoteOwnerId -and $checkedRecord.HostTrustState -ceq 'Verified') 'Actual completed NotInstalled server_info is supported independently of host trust'
 Write-TCDJson $statePath @{ServerInfo=$emptyInfo;Inspection=$emptyInspection;PrerequisiteMissing=$true}
 $null=Invoke-TCDeployOperation -SessionRef $ref -Operation inspect -Input @{};$poll=Wait-Session $ref
 Assert-Check ($poll.Code -ceq 'RemotePrerequisiteMissing' -and $poll.AccessDiagnostic.Category -ceq 'Prerequisite' -and $poll.Status -ceq 'Failed' -and $poll.HasSession -and $poll.AcceptedFingerprint -ceq $ssh.Fingerprint) 'Missing remote Python or command prerequisite is classified without changing SSH trust or installing anything'
 $checkedRecord=Set-TCServerRecord -Root $liveRoot -Id $hostRecord.LocalRecordId -PinnedFingerprint $ssh.Fingerprint -SessionRef $ref
 Assert-Check ($checkedRecord.HostTrustState -ceq 'Verified' -and $checkedRecord.OwnershipState -ceq 'NotInstalled') 'Host-only registration remains valid after a missing-prerequisite read failure and preserves prior app fields'
 Assert-Reject {Set-TCServerRecord -Root $liveRoot -Id $hostRecord.LocalRecordId -ServerInfo $emptyInfo -SessionRef $ref} IdentityReadRequired 'Missing-prerequisite failure supplies no application identity evidence'
 Write-TCDJson $statePath @{ServerInfo=$emptyInfo;Inspection=$emptyInspection}
 $null=Invoke-TCDeployOperation -SessionRef $ref -Operation apply -Input @{PlanId=[guid]::NewGuid().ToString('D')};$poll=Wait-Session $ref
 Assert-Check $poll.HasMutatingOperations 'Executor remembers any attempted mutation even if backend rejects it'
 Assert-Reject {Get-TCDeployServerIdentityEvidence $ref} IdentitySessionUsed 'A used mutation session cannot become identity-transition proof'
 $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$closedPort=$listener.LocalEndpoint.Port;$listener.Stop()
 $refused=Start-TCDeploySession -Root $liveRoot -RunId ([guid]::NewGuid().ToString('D')) -Connection @{Host='127.0.0.1';Port=$closedPort;User='root'} -Credential $credential -PinnedFingerprint $ssh.Fingerprint
 $liveRefs.Add($refused.SessionRef);$poll=Wait-Session $refused.SessionRef
 Assert-Check ($poll.Code -ceq 'ConnectionRefused' -and $poll.AccessDiagnostic.Category -ceq 'Connection') 'Actual localhost socket refusal is not mislabeled authentication failure'
 $leaks=@(Get-ChildItem -LiteralPath $liveRoot -Recurse -File|Where-Object {[IO.File]::ReadAllText($_.FullName).Contains('TC_Identity_Local_Fixture_Only!') -or [IO.File]::ReadAllText($_.FullName).Contains('LOCAL_SECRET_DO_NOT_PRINT')})
 Assert-Check ($leaks.Count -eq 0) 'Actual executor persisted receipts contain neither credentials nor exception secrets'
 foreach($r in $liveRefs){$null=Stop-TCDeploySession $r;$p=Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue;if($p){try{$null=$p.WaitForExit(5000)}finally{$p.Dispose()}}};$liveRefs.Clear()
 $python.Kill();$python.WaitForExit();$python.Dispose();$python=$null

 # Exercise the classifier with real library exception TYPES, including wrapped
 # socket errors and timeouts, without waiting on or contacting any remote host.
 $classifierSource=Join-Path $taskRoot 'AccessFixture.cs';$classifierExe=Join-Path $taskRoot 'AccessFixture.exe'
 [IO.File]::WriteAllText($classifierSource,@'
using System; using System.IO; using System.Net.Sockets; using Renci.SshNet.Common;
namespace TradeChannel.Deployment {
 public static class AccessFixture {
  public static int Main(string[] args) {
   AppDomain.CurrentDomain.AssemblyResolve += delegate(object sender, ResolveEventArgs e) {
    string name=new System.Reflection.AssemblyName(e.Name).Name;
    string path=Path.Combine(args[0],"assets","lib",name+".dll");
    return File.Exists(path)?System.Reflection.Assembly.LoadFrom(path):null;
   };
   try { Run(); Console.WriteLine("{\"Ok\":true,\"Checks\":10}"); return 0; }
   catch { Console.WriteLine("{\"Ok\":false}"); return 1; }
  }
  static void Check(Exception error,bool parsingKey,string code) {
   if(Host.ClassifyAccessFailure(error,parsingKey)!=code)throw new Exception("FixtureFailed");
  }
  [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
  static void Run() {
   Check(new SshAuthenticationException("SECRET_EXCEPTION_CONTENT"),false,"AuthenticationFailed");
   Check(new SshOperationTimeoutException("SECRET_EXCEPTION_CONTENT"),false,"ConnectionTimeout");
   Check(new TimeoutException("SECRET_EXCEPTION_CONTENT"),false,"ConnectionTimeout");
   Check(new IOException("SECRET_EXCEPTION_CONTENT",new SocketException(10061)),false,"ConnectionRefused");
   Check(new SocketException(10065),false,"HostUnreachable"); Check(new SocketException(10051),false,"NetworkUnreachable");
   Check(new SocketException(10060),false,"ConnectionTimeout");
   Check(new SshPassPhraseNullOrEmptyException("SECRET_EXCEPTION_CONTENT"),true,"PrivateKeyPassphraseRequired");
   Check(new FormatException("SECRET_EXCEPTION_CONTENT"),true,"PrivateKeyParseFailed");
   Check(new Exception("SECRET_EXCEPTION_CONTENT"),false,"ConnectionFailed");
  }
 }
}
'@,(New-Object Text.UTF8Encoding($true)))
 $classifierBuild=@('/nologo','/target:exe','/platform:x64','/main:TradeChannel.Deployment.AccessFixture',('/out:'+$classifierExe),'/reference:System.Web.Extensions.dll',('/reference:'+(Join-Path $fixturePackage 'assets/lib/Renci.SshNet.dll')),(Join-Path $PackageRoot 'deployment/TradeChannelDeployHost.cs'),$classifierSource)
 $buildOutput=& $compiler @classifierBuild 2>&1;if($LASTEXITCODE -ne 0){throw ('Classifier fixture compilation failed: '+($buildOutput -join ' '))}
 $classificationResult=& $classifierExe $fixturePackage
 Assert-Check ($LASTEXITCODE -eq 0 -and ($classificationResult|ConvertFrom-Json).Checks -eq 10) 'Ten real SSH/socket/timeout/key exception types produce only fixed safe codes'

 # All following tests mock ONLY the executor boundary. Registry, task files,
 # DPAPI, leases, comparison, ACL checks and atomic writes remain real.
 $templateInfo=[pscustomobject]@{RemoteOwnerId=[guid]::NewGuid().ToString('D');Node=[pscustomobject]@{NodeId=[guid]::NewGuid().ToString('D');ServerPublicKey=('D'*43+'=');PublicEndpoint='127.0.0.1:51820'};ManagementSigningPublicKey=[pscustomobject]@{kty='RSA';n=('A'*512);e='AQAB'};OwnershipState='Applied';ManagementApiVersion=2;Health=[pscustomobject]@{LocalConfiguration='Verified'};ConfigRevision=3;ActivePlanId=[guid]::NewGuid().ToString('D');PendingOperation=$null}
 $templateInspection=[pscustomobject]@{Supported=$true;OwnedDeployment=$true;AlreadyDeployed=$true;DeployedStatus='Applied';Issues=@()}
 $fixture=[pscustomobject]@{TaskRoot=$taskRoot;Sessions=@{};Fingerprint=('SHA256:'+('A'*43));Info=(Copy-Public $templateInfo);Inspection=(Copy-Public $templateInspection);DeploymentState=$null;Calls=(New-Object 'Collections.Generic.List[object]');OnRead=$null;FailRead=''}
 & $transport {
  param($Fixture)
  $script:IdentityFixture=$Fixture
  function script:Start-TCDeploySession {param($Root,$RunId,$Connection,$Credential,[string]$PinnedFingerprint='')
   $f=$script:IdentityFixture;if(-not ([IO.Path]::GetFullPath($Root)).StartsWith($f.TaskRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Mock rejects non-task roots.'}
   $instance=[guid]::NewGuid().ToString('D');$ref=[pscustomobject]@{PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'));RunId=$RunId;InstanceId=$instance;ProcessId=2147483600;StartTimeUtcTicks='1';Root=(Join-Path $Root ('deployments/hosts/'+$instance))}
   $ok=$PinnedFingerprint -ceq $f.Fingerprint
   $state=[pscustomobject]@{Ok=$ok;RunId=$RunId;InstanceId=$instance;Status=$(if($ok){'Ready'}else{'Failed'});Code=$(if($ok){'Authenticated'}elseif($PinnedFingerprint){'HostKeyChanged'}else{'HostTrustRequired'});ObservedFingerprint=$f.Fingerprint;HostKeyAlgorithm='ssh-ed25519';ObservedHostKeyAlgorithm='ssh-ed25519';AcceptedFingerprint=$(if($ok){$f.Fingerprint}else{''});Connection=[pscustomobject]@{Host=$Connection.Host;Port=[int]$Connection.Port;User=$Connection.User};AuthenticationGeneration=1;HasMutatingOperations=$false;HasSession=$ok;Operation='';OperationId='';Data=$null}
   $f.Sessions[$instance]=$state;$f.Calls.Add(@{Kind='Start';Pin=$PinnedFingerprint})
   return [pscustomobject]@{Ok=$true;SessionRef=$ref}
  }
  function script:Get-TCDeploySession {param($SessionRef)return $script:IdentityFixture.Sessions[$SessionRef.InstanceId]}
  function script:Set-TCDeployCredential {param($SessionRef,$Connection,$Credential,$PinnedFingerprint)
   $f=$script:IdentityFixture;$s=$f.Sessions[$SessionRef.InstanceId];$f.Calls.Add(@{Kind='Authenticate';Pin=$PinnedFingerprint});$s.AuthenticationGeneration++
   $s.HasSession=$s.ObservedFingerprint -ceq $PinnedFingerprint;$s.AcceptedFingerprint=$(if($s.HasSession){$PinnedFingerprint}else{''});$s.Status=$(if($s.HasSession){'Ready'}else{'Failed'});$s.Code=$(if($s.HasSession){'Authenticated'}else{'HostKeyChanged'});return [pscustomobject]@{Ok=$true}
  }
  function script:Invoke-TCDeployOperation {param($SessionRef,$Operation,$OperationInput,$OperationId)
   $f=$script:IdentityFixture;$s=$f.Sessions[$SessionRef.InstanceId]
   if($Operation -ceq 'deployment_state'){
    if($OperationInput.Count -ne 2 -or -not $OperationInput.ContainsKey('ClientPublicKey') -or -not $OperationInput.ContainsKey('ServerPublicKey')){throw 'Mock rejects unbound deployment_state input.'}
   }elseif($Operation -notin @('server_info','inspect') -or $OperationInput.Count -ne 0){throw 'Mock forbids mutation, probe, or arbitrary operation input.'}
   $f.Calls.Add(@{Kind='Read';Action=$Operation});if($f.OnRead){& $f.OnRead $f $Operation}
   $s.Operation=$Operation;$s.OperationId=$OperationId;$s.Status='Completed';$s.Code='Completed';$s.Ok=$true
   if($f.FailRead -ceq $Operation){$s.Status='Failed';$s.Code='OwnershipMismatch';$s.Ok=$false;$s.Data=@{Code='OwnershipMismatch'}}
   else{$source=if($Operation -ceq 'server_info'){$f.Info}elseif($Operation -ceq 'deployment_state'){$f.DeploymentState}else{$f.Inspection};$s.Data=ConvertTo-Json -InputObject $source -Depth 30 -Compress|ConvertFrom-Json}
   return [pscustomobject]@{Ok=$true;Status='Running';Operation=$Operation;OperationId=$OperationId}
  }
  function script:Stop-TCDeploySession {throw 'Identity tests forbid stopping an original session.'}
  Export-ModuleMember -Function Start-TCDeploySession,Set-TCDeployCredential,Get-TCDeploySession,Invoke-TCDeployOperation,Stop-TCDeploySession,Save-TCDeployCredential,Get-TCDeploySavedCredential,Get-TCDeployVerifiedHostIdentity,Get-TCDeployVerifiedServerInfo,Get-TCDeployServerIdentityEvidence
 } $fixture
 Import-Module (Join-Path $fixturePackage 'DeploymentTransport.psm1') -Global -DisableNameChecking
 $typedCredential=@{Kind='Password';Password=(ConvertTo-SecureString 'ISOLATED_NEW_INPUT' -AsPlainText -Force)}
 $oldFp='SHA256:'+('A'*43);$newFp='SHA256:'+('B'*43)
 function Write-PrivateFixture {param([string]$Path,[string]$Text)
  $null=New-TCDDirectory ([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true)))
  $nodeModule=@(Import-Module (Join-Path $fixturePackage 'NodeStore.psm1') -PassThru -DisableNameChecking)[0];& $nodeModule {param($P)Set-TCPrivateAcl $P} $Path
 }
 function Write-RequestFixture {param([string]$Directory,[string]$DeviceId)
  $private=('F'*43+'=');$request=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientRequest';RequestId=[guid]::NewGuid().ToString('D');DeviceId=$DeviceId;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');ClientPublicKey=('G'*43+'=');AddressFamilies=@('IPv4')}
  $privateHash=& $registry {param($K)Get-TCServerTextDigest $K} $private
  Write-TCDJson (Join-Path $Directory 'public.request.json') $request;Write-TCDJson (Join-Path $Directory 'client.state.json') @{SchemaVersion=1;Kind='TradeChannel.ClientPrivateState';RequestId=$request.RequestId;DeviceId=$request.DeviceId;ClientPublicKey=$request.ClientPublicKey;PrivateKeyHash=$privateHash}
  Write-PrivateFixture (Join-Path $Directory 'client.key') ($private+"`r`n")
  return $request
 }
 function New-Case {param([string]$Label)
  $fixture.Fingerprint=$oldFp;$fixture.Info=Copy-Public $templateInfo;$fixture.Inspection=Copy-Public $templateInspection;$fixture.OnRead=$null;$fixture.FailRead=''
  $root=Join-Path $taskRoot $Label;$null=New-TCDDirectory $root
  $c=@{Host='127.0.0.1';Port=2222;User='root';IdentityFile=(Join-Path $root 'old-ssh.key')}
  $seed=Start-TCDeploySession -Root $root -RunId ([guid]::NewGuid().ToString('D')) -Connection $c -Credential $typedCredential -PinnedFingerprint $oldFp
  $null=Invoke-TCDeployOperation -SessionRef $seed.SessionRef -Operation server_info -OperationInput @{} -OperationId ([guid]::NewGuid().ToString('D'))
  $job=[guid]::NewGuid().ToString('D');$device=[guid]::NewGuid().ToString('D');$runId=[guid]::NewGuid().ToString('D');$intentId=[guid]::NewGuid().ToString('D')
  $server=Set-TCServerRecord -Root $root -Connection $c -Name $Label -ServerInfo $fixture.Info -PinnedFingerprint $oldFp -CredentialRef ([guid]::NewGuid().ToString('D')) -SourceJobIds @($job) -SessionRef $seed.SessionRef
  $falseInfo=Copy-Public $fixture.Info;$falseInfo.RemoteOwnerId=[guid]::NewGuid().ToString('D')
  Assert-Reject {Set-TCServerRecord -Root $root -Id $server.LocalRecordId -ServerInfo $falseInfo -SessionRef $seed.SessionRef} IdentityObservationChanged 'Verified registration rejects substituted caller server_info'
  $server=Set-TCServerLink -Root $root -ServerId $server.LocalRecordId -NodeId $device -ObservedExitIPv4 '127.0.0.1' -EvidenceSource Fixture
  $runPath=Join-Path $root ('deployments/runs/'+$runId+'/state.json');$intentPath=Join-Path $root ('deployments/management-intents/'+$intentId+'.json');$jobPath=Join-Path $root ('linux-jobs/'+$job+'/job.json');$keyPath=Join-Path $root 'client-key.json';$productPath=Join-Path $root 'Product/active.json'
  $clientDirectory=Join-Path ([IO.Path]::GetDirectoryName($runPath)) 'client';$publicRequest=Write-RequestFixture $clientDirectory $device
  $run=[pscustomobject]@{SchemaVersion=1;RunId=$runId;ServerRecordId=$server.LocalRecordId;Revision=1;Status='WaitingUser';ApprovedChangeDigest=('c'*64);AllowDeviceAuthorize=$true;AllowManagementInitialize=$true;ClientRequest=$publicRequest;RequestDirectory=$clientDirectory;ServerInfo=(Copy-Public $templateInfo);ClientResponse=$null;RecoveryRequired=$false;LastRemoteMutation=$null;DispatchIntent=$null;ExistingDevice=$false}
  Write-TCDJson $runPath $run;Write-TCDJson $intentPath @{OperationId=$intentId;ServerRecordId=$server.LocalRecordId;State='OutcomeUnknown';Operation='authorize_external';Input=@{Marker='ORIGINAL_INTENT'}}
  Write-TCDJson $jobPath @{JobId=$job;Connection=$c;Name='Original';Status='Completed'};Write-TCDJson $keyPath @{Key='ORIGINAL_KEY'}
  $nodeModule=@(Import-Module (Join-Path $fixturePackage 'NodeStore.psm1') -PassThru -DisableNameChecking)[0];$null=& $nodeModule {param($P)Initialize-TCStore -Root $P} (Join-Path $root 'Product')
  Write-TCDJson $productPath @{ActiveDevice=$device;Marker='ORIGINAL_PRODUCT_STATE'}
  $paths=@($runPath,$intentPath,$jobPath,$keyPath,$productPath,(Join-Path $root 'Product/index.json'),(Join-Path $clientDirectory 'public.request.json'),(Join-Path $clientDirectory 'client.state.json'),(Join-Path $clientDirectory 'client.key'));$hashes=@{};foreach($path in $paths){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
  return [pscustomobject]@{Root=$root;Server=$server;Connection=$c;Run=$run;RunPath=$runPath;IntentId=$intentId;JobId=$job;DeviceId=$device;Paths=$paths;Hashes=$hashes;RegistryPath=(Join-Path $root 'servers/registry.json')}
 }
 function Assert-Kept {param($Case)
  foreach($path in $Case.Paths){Assert-Check ((Get-FileHash -LiteralPath $path).Hash -ceq $Case.Hashes[$path]) ($Case.Server.Name+' original file retained: '+[IO.Path]::GetFileName($path))}
 }
 function Mutate-Token {param([string]$Token,[scriptblock]$Change)
  Add-Type -AssemblyName System.Security;$bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),[Text.Encoding]::UTF8.GetBytes('TradeChannel.ServerReinstall.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
  try{$context=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json;& $Change $context;return & $registry {param($C)Protect-TCServerReinstallToken $C} $context}finally{[Array]::Clear($bytes,0,$bytes.Length)}
 }

 # Main workflow fixtures can replace this PRIVATE leaf with the Flow fixture
 # getter. Public host/app validation and registry mutation stay production-real.
 $seamCase=New-Case 'private-observation-seam';$seamSession=Start-TCDeploySession -Root $seamCase.Root -RunId ([guid]::NewGuid().ToString('D')) -Connection $seamCase.Connection -Credential $typedCredential -PinnedFingerprint $oldFp
 $null=Invoke-TCDeployOperation -SessionRef $seamSession.SessionRef -Operation server_info -OperationInput @{} -OperationId ([guid]::NewGuid().ToString('D'))
 $seamState=$fixture.Sessions[$seamSession.SessionRef.InstanceId]
 $originalReader=& $transport {${function:Read-TCDeployObservation}};$originalPoll=& $transport {${function:Get-TCDeploySession}}
 try{
  & $transport {
   param($Fixture)
   $script:ObservationFixture=$Fixture
   function script:Read-TCDeployObservation {param($SessionRef)
    if(-not ([IO.Path]::GetFullPath($SessionRef.Root)).StartsWith($script:ObservationFixture.TaskRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Private observation fixture rejects roots outside this task.'}
    return $script:ObservationFixture.Sessions[$SessionRef.InstanceId]
   }
   function script:Get-TCDeploySession {throw 'Private observation fixture must not read a real pipe or exported poll.'}
  } $fixture
  $seamRecord=Set-TCServerRecord -Root $seamCase.Root -Id $seamCase.Server.LocalRecordId -ServerInfo $fixture.Info -SessionRef $seamSession.SessionRef
  Assert-Check ($seamRecord.ManagementAccessState -ceq 'Authenticated') 'Private observation leaf enables a bound Flow fixture while real application and registry validators remain enabled'
  $seamState.AcceptedFingerprint=$newFp
  Assert-Reject {Set-TCServerRecord -Root $seamCase.Root -Id $seamCase.Server.LocalRecordId -PinnedFingerprint $oldFp -SessionRef $seamSession.SessionRef} IdentityAuthenticationRequired 'Private fixture observation cannot bypass accepted-fingerprint validation'
  $seamState.AcceptedFingerprint=$oldFp;$seamState.RunId=[guid]::NewGuid().ToString('D')
  Assert-Reject {Set-TCServerRecord -Root $seamCase.Root -Id $seamCase.Server.LocalRecordId -PinnedFingerprint $oldFp -SessionRef $seamSession.SessionRef} IdentitySessionMismatch 'Private fixture observation cannot bypass run and instance binding'
  $seamState.RunId=$seamSession.SessionRef.RunId;$seamState.Status='Ready';$seamState.Code='Authenticated'
  Assert-Reject {Set-TCServerRecord -Root $seamCase.Root -Id $seamCase.Server.LocalRecordId -ServerInfo $fixture.Info -SessionRef $seamSession.SessionRef} IdentityReadRequired 'Private fixture still requires completed server_info for application data'
  Assert-Check (Get-TCDeployVerifiedHostIdentity -SessionRef $seamSession.SessionRef).ObservedFingerprint.Equals($oldFp) 'Private fixture allows independently verified Ready host evidence without an app read'
 }finally{
  & $transport {param($Reader,$Poll)Set-Item -Path Function:script:Read-TCDeployObservation -Value $Reader;Set-Item -Path Function:script:Get-TCDeploySession -Value $Poll} $originalReader $originalPoll
 }

 $rawRoot=Join-Path $taskRoot 'raw';$raw=Set-TCServerRecord -Root $rawRoot -Connection @{Host='127.0.0.1';Port=2222;User='root'} -ServerInfo $templateInfo -PinnedFingerprint $oldFp
 Assert-Check ($raw.ManagementAccessState -ceq 'NeedsAuthentication' -and $raw.OwnershipState -ceq 'AwaitIdentityVerification' -and $raw.HostTrustState -ceq 'AwaitVerification') 'Arbitrary caller server_info and fingerprint create only an unverified provisional record'
 $case=New-Case 'host-update';$fixture.Fingerprint=$newFp
 $session=Start-TCDeploySession -Root $case.Root -RunId ([guid]::NewGuid().ToString('D')) -Connection $case.Connection -Credential $typedCredential -PinnedFingerprint $newFp
 $state=$fixture.Sessions[$session.SessionRef.InstanceId];$authBefore=@($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count
 $verify=Start-TCServerIdentityVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef
 Assert-Check ($verify.SessionRef.RunId -cne $case.Run.RunId -and @($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count -eq $authBefore) 'Inline verification reuses already-authenticated independent-run session without credentials'
 Assert-Reject {New-TCServerIdentityAssessment -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef -VerificationToken $verify.VerificationToken} IdentityTrustRequired 'Already authenticated changed fingerprint still needs fresh exact trust confirmation'
 $preview=New-TCServerIdentityTrustPreview -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef -VerificationToken $verify.VerificationToken
 Assert-Reject {Approve-TCServerIdentityFingerprint -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $oldFp} ReinstallConfirmationMismatch 'Fingerprint approval rejects substituted key'
 $approval=Approve-TCServerIdentityFingerprint -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $newFp
 Assert-Check (@($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count -eq $authBefore) 'Exact fingerprint confirmation on a live session does not reauthenticate'
 $assessment=New-TCServerIdentityAssessment -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $session.SessionRef -ApprovalToken $approval.ApprovalToken
 Assert-Check ($assessment.Classification -ceq 'HostKeyUpdate' -and $assessment.NewServerId -ceq $case.Server.LocalRecordId -and $assessment.PreservesApplicationIdentity -and $assessment.ChangeDigest -cne $preview.ChangeDigest) 'Changed SSH key with same actual app identity is a preserving host-key update with a new bound digest'
 $hashBefore=(Get-FileHash $case.RegistryPath).Hash
 $commit=@{Root=$case.Root;ServerId=$case.Server.LocalRecordId;SessionRef=$session.SessionRef;AssessmentToken=$assessment.AssessmentToken;ConfirmedFingerprint=$newFp;ApprovedChangeDigest=$assessment.ChangeDigest}
 $bad=$commit.Clone();$bad.AssessmentToken=$preview.PreviewToken;Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallBindingMismatch 'Trust preview alone cannot commit application identity'
 $bad=$commit.Clone();$bad.ApprovedChangeDigest=$preview.ChangeDigest;Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallConfirmationMismatch 'Host-trust digest cannot substitute for application assessment digest'
 $bad=$commit.Clone();$bad.ConfirmedFingerprint=$oldFp;Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallConfirmationMismatch 'Commit rejects substituted confirmed fingerprint'
 $bad=$commit.Clone();$bad.Root=Join-Path $taskRoot 'other-root';Assert-Reject {Confirm-TCServerIdentityTransition @bad} ServerMissing 'Different data root cannot use an assessment'
 $bad=$commit.Clone();$bad.SessionRef=Copy-Public $session.SessionRef;$bad.SessionRef.RunId=[guid]::NewGuid().ToString('D');Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallBindingMismatch 'Assessment cannot bind another run or session'
 $tampered=[Convert]::FromBase64String($assessment.AssessmentToken);$tampered[$tampered.Length-1]=$tampered[$tampered.Length-1] -bxor 1;$bad=$commit.Clone();$bad.AssessmentToken=[Convert]::ToBase64String($tampered);Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallTokenInvalid 'Tampered DPAPI assessment cannot commit'
 $bad=$commit.Clone();$bad.AssessmentToken=Mutate-Token $assessment.AssessmentToken {param($C)$C.ExpiresAtUtc=[DateTime]::UtcNow.AddSeconds(-1).ToString('o')};Assert-Reject {Confirm-TCServerIdentityTransition @bad} ReinstallPreviewExpired 'Expired assessment cannot commit'
 $state.AuthenticationGeneration++;Assert-Reject {Confirm-TCServerIdentityTransition @commit} IdentityObservationChanged 'Reauthentication invalidates old assessment';$state.AuthenticationGeneration--
 $state.HasMutatingOperations=$true;Assert-Reject {Confirm-TCServerIdentityTransition @commit} ReinstallSessionMismatch 'Any intervening mutation blocks assessment commit';$state.HasMutatingOperations=$false
 $fixture.Info.ConfigRevision++;Assert-Reject {Confirm-TCServerIdentityTransition @commit} IdentityEvidenceChanged 'Actual app state changing after preview blocks commit';$fixture.Info.ConfigRevision--
 $case.Run.Revision++;Write-TCDJson $case.RunPath $case.Run;Assert-Reject {Confirm-TCServerIdentityTransition @commit} ReinstallTasksChanged 'Original task changing invalidates assessment';$case.Run.Revision--;Write-TCDJson $case.RunPath $case.Run
 $case.Run.Status='Running';Write-TCDJson $case.RunPath $case.Run;Assert-Reject {Confirm-TCServerIdentityTransition @commit} ServerTaskBusy 'Running original task blocks transition without stopping it';$case.Run.Status='WaitingUser';Write-TCDJson $case.RunPath $case.Run
 $lease=Open-TCServerTaskLease $case.Root $case.Server.LocalRecordId
 try{Assert-Reject {Confirm-TCServerIdentityTransition @commit} Busy 'Per-server lease protects transition against concurrent dispatch'}finally{$lease.Dispose()}
 Assert-Check ((Get-FileHash $case.RegistryPath).Hash -ceq $hashBefore) 'Every rejected transition preserves the original registry bytes'
 $other=Set-TCServerRecord -Root $case.Root -Connection @{Host='127.0.0.2';Port=2222;User='root'} -Name 'Other';$otherDigest=Get-TCDDigest $other;$rev=(Read-TCDJson $case.RegistryPath).Revision
 $result=Confirm-TCServerIdentityTransition @commit;$updated=$result.Server
 Assert-Check ($result.Classification -ceq 'HostKeyUpdate' -and $updated.LocalRecordId -ceq $case.Server.LocalRecordId -and $updated.PinnedHostKey -ceq $newFp -and (Read-TCDJson $case.RegistryPath).Revision -eq $rev+1) 'Host-key update commits one revision without creating another app record'
 foreach($field in @('RemoteOwnerId','NodeId','ServerPublicKey','ManagementSigningPublicKey','LinkedNodeIds','SourceJobIds','CredentialRef','Endpoints','Connection')){Assert-Check ((Get-TCDDigest $updated.$field) -ceq (Get-TCDDigest $case.Server.$field)) ('Host-key update preserves '+$field)}
 Assert-Check ((Get-TCDDigest (Get-TCServer $case.Root $other.LocalRecordId)) -ceq $otherDigest) 'Other-server update is preserved and does not invalidate target assessment'
 $reused=Get-TCServerSameApplicationRequest -Root $case.Root -ServerId $updated.LocalRecordId -SourceRunId $case.Run.RunId -SessionRef $session.SessionRef -TargetToken $result.TargetToken
 Assert-Check ($reused.CanReuse -and $reused.RequestDirectory -ceq $case.Run.RequestDirectory -and (Get-TCDDigest $reused.ClientRequest) -ceq (Get-TCDDigest $case.Run.ClientRequest) -and $reused.RequiresFreshApproval) 'Committed same-app host-key update safely returns the original request and directory without generating another device'
 Assert-Check (-not $reused.PSObject.Properties['Plan'] -and -not $reused.PSObject.Properties['ClientResponse'] -and -not $reused.PSObject.Properties['ApprovedChangeDigest'] -and -not $reused.PSObject.Properties['PrivateKey']) 'Request reuse returns no old plan authorization approval or private key'
 # Exercise Main's actual constructor from a source snapshot in this fixture.
 # Only the transport boundary remains mocked; do not replace the constructor,
 # request helper, registry validation or local persistence implementation.
 $mainFlow=@(Import-Module (Join-Path $fixturePackage 'DeploymentFlow.psm1') -PassThru -DisableNameChecking)[0]
 $beforeLogins=@($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count
 $newRun=& $mainFlow {param($Root,$ServerId,$SourceRunId,$Ref,$Token)
  New-TCDeploymentRun -Root $Root -Intent Auto -ServerId $ServerId -Name 'Host-key transition integration' -ReuseSourceRunId $SourceRunId -IdentitySessionRef $Ref -IdentityTargetToken $Token -ClientInspection @{EngineStaged=$true;WgHelperStaged=$true;NinjaTraderPaths=@();DirectDnsIPv4=@('127.0.0.1')}
 } $case.Root $updated.LocalRecordId $case.Run.RunId $session.SessionRef $result.TargetToken
 $newRunDirectory=Join-Path $case.Root ('deployments/runs/'+$newRun.RunId)
 Assert-Check ($newRun.RunId -cne $case.Run.RunId -and $newRun.ReusedRequestSourceRunId -ceq $case.Run.RunId -and $newRun.RequestDirectory -ceq $case.Run.RequestDirectory -and (Get-TCDDigest $newRun.ClientRequest) -ceq (Get-TCDDigest $case.Run.ClientRequest)) 'Main New-TCDeploymentRun Auto consumes identity helper references with a new RunId and the exact original client identity'
 Assert-Check (-not [IO.Directory]::Exists((Join-Path $newRunDirectory 'client')) -and -not $newRun.ClientResponse -and -not $newRun.Plan -and -not $newRun.ApprovedChangeDigest -and -not $newRun.AllowDeviceAuthorize -and -not $newRun.AllowManagementInitialize -and -not $newRun.SessionRef -and @($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count -eq $beforeLogins) 'Main API creates no second client identity directory and copies no authorization approval or session'
 $persistedNewRun=Read-TCDJson (Join-Path $newRunDirectory 'state.json')
 Assert-Check ($persistedNewRun.RequestDirectory -ceq $case.Run.RequestDirectory -and (Get-TCDDigest $persistedNewRun.ClientRequest) -ceq (Get-TCDDigest $case.Run.ClientRequest)) 'Main API persists the original request references rather than generating a second client request'
 Assert-Reject {& $mainFlow {param($Root,$Id,$Ref)Set-TCDeploymentSession -Root $Root -RunId $Id -SessionRef $Ref} $case.Root $newRun.RunId $session.SessionRef} SessionMismatch 'New-run helper integration preserves the exact SessionRef.RunId constraint'
 $privatePath=Join-Path $case.Run.RequestDirectory 'client.key';$privateStatePath=Join-Path $case.Run.RequestDirectory 'client.state.json';$originalKey=[IO.File]::ReadAllText($privatePath);$originalState=Read-TCDJson $privateStatePath
 Write-PrivateFixture $privatePath ('H'*43+'=')
 Assert-Reject {Get-TCServerSameApplicationRequest -Root $case.Root -ServerId $updated.LocalRecordId -SourceRunId $case.Run.RunId -SessionRef $session.SessionRef -TargetToken $result.TargetToken} LocalRequestMismatch 'Same-app reuse rejects a changed private key'
 $changedState=Copy-Public $originalState;$changedState.PrivateKeyHash=& $registry {Get-TCServerTextDigest ('H'*43+'=')};Write-TCDJson $privateStatePath $changedState
 Assert-Reject {Get-TCServerSameApplicationRequest -Root $case.Root -ServerId $updated.LocalRecordId -SourceRunId $case.Run.RunId -SessionRef $session.SessionRef -TargetToken $result.TargetToken} SameApplicationSourceChanged 'Changing both private key and state cannot bypass the committed file checkpoint'
 Write-PrivateFixture $privatePath $originalKey;Write-TCDJson $privateStatePath $originalState
 Assert-Kept $case
 Assert-Reject {Assert-TCServerTaskActive -Root $case.Root -RunId $case.Run.RunId} ServerTaskIdentityChanged 'Original deployment cannot reuse old approved scope after host-key update'
 Assert-Reject {Assert-TCServerTaskActive -Root $case.Root -SourceJobId $case.JobId} ServerTaskIdentityChanged 'Original legacy task cannot inherit updated host trust'
 Assert-Reject {Assert-TCServerTaskActive -Root $case.Root -ManagementOperationId $case.IntentId} ServerTaskIdentityChanged 'Original management intent cannot inherit updated host trust'
 Assert-Check (Assert-TCServerIdentitySessionBinding -Root $case.Root -ServerId $updated.LocalRecordId -SessionRef $session.SessionRef -TargetToken $result.TargetToken).Code.Equals('ServerIdentitySessionVerified') 'Verified target token supports independent-run session attachment'
 $fixture.Info.ConfigRevision++;Assert-Reject {Assert-TCServerIdentitySessionBinding -Root $case.Root -ServerId $updated.LocalRecordId -SessionRef $session.SessionRef -TargetToken $result.TargetToken} IdentityEvidenceChanged 'Target token cannot attach a session after remote app changes';$fixture.Info.ConfigRevision--
 Assert-Reject {Confirm-TCServerIdentityTransition @commit} ReinstallRecordChanged 'Replayed host-key commit cannot reuse old assessment'
 $case.Run.ApprovedChangeDigest=$null;$case.Run.AllowDeviceAuthorize=$false;$case.Run.AllowManagementInitialize=$false;Write-TCDJson $case.RunPath $case.Run
 Assert-Reject {Get-TCServerSameApplicationRequest -Root $case.Root -ServerId $updated.LocalRecordId -SourceRunId $case.Run.RunId -SessionRef $session.SessionRef -TargetToken $result.TargetToken} SameApplicationSourceChanged 'Source request must be read before the old run is invalidated or edited'
 Assert-Check ((Assert-TCServerTaskActive -Root $case.Root -RunId $case.Run.RunId).LocalRecordId -ceq $updated.LocalRecordId) 'Same inline wizard task can recheck after clearing old approval flags'

 $checkpointCase=New-Case 'authorized-checkpoint-without-local-node'
 $r=$checkpointCase.Run.ClientRequest
 $oldResponse=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$r.RequestId;DeviceId=$r.DeviceId;ClientPublicKey=$r.ClientPublicKey;NodeId=$checkpointCase.Server.NodeId;ServerPublicKey=$checkpointCase.Server.ServerPublicKey;NodeName='Original';PublicEndpoint='127.0.0.1:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';ClientAddress='10.78.0.2/32';AddressFamilies=@('IPv4');AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;ConfigRevision=2}
 $checkpointCase.Run.ClientResponse=$oldResponse;$checkpointCase.Run|Add-Member NoteProperty CandidateNodeId $null;Write-TCDJson $checkpointCase.RunPath $checkpointCase.Run
 $fixture.Fingerprint=$newFp
 $s=Start-TCDeploySession -Root $checkpointCase.Root -RunId ([guid]::NewGuid().ToString('D')) -Connection $checkpointCase.Connection -Credential $typedCredential -PinnedFingerprint $newFp
 $v=Start-TCServerIdentityVerification -Root $checkpointCase.Root -ServerId $checkpointCase.Server.LocalRecordId -SessionRef $s.SessionRef
 $p=New-TCServerIdentityTrustPreview -Root $checkpointCase.Root -ServerId $checkpointCase.Server.LocalRecordId -SessionRef $s.SessionRef -VerificationToken $v.VerificationToken
 $a=Approve-TCServerIdentityFingerprint -Root $checkpointCase.Root -ServerId $checkpointCase.Server.LocalRecordId -SessionRef $s.SessionRef -PreviewToken $p.PreviewToken -ConfirmedFingerprint $newFp
 $assessment=New-TCServerIdentityAssessment -Root $checkpointCase.Root -ServerId $checkpointCase.Server.LocalRecordId -SessionRef $s.SessionRef -ApprovalToken $a.ApprovalToken
 $confirmed=Confirm-TCServerIdentityTransition -Root $checkpointCase.Root -ServerId $checkpointCase.Server.LocalRecordId -SessionRef $s.SessionRef -AssessmentToken $assessment.AssessmentToken -ConfirmedFingerprint $newFp -ApprovedChangeDigest $assessment.ChangeDigest
 $liveResponse=Copy-Public $oldResponse;$liveResponse.ConfigRevision=3
 $fixture.DeploymentState=[pscustomobject]@{Kind='TradeChannel.DeploymentState';Status='Settled';RemoteOwnerId=$checkpointCase.Server.RemoteOwnerId;NodeId=$checkpointCase.Server.NodeId;ServerPublicKey=$checkpointCase.Server.ServerPublicKey;ClientPublicKey=$r.ClientPublicKey;Transaction=$null;Udp=[pscustomobject]@{Status='Healthy';ClientAddress=$liveResponse.ClientAddress;ClientResponse=$liveResponse}}
 $reuseArgs=@{Root=$checkpointCase.Root;ServerId=$checkpointCase.Server.LocalRecordId;SourceRunId=$checkpointCase.Run.RunId;SessionRef=$s.SessionRef;TargetToken=$confirmed.TargetToken;IncludeAuthorizationCheckpoint=$true}
 $callStart=$fixture.Calls.Count;$loginStart=@($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count;$sourceHash=(Get-FileHash $checkpointCase.RunPath).Hash
 $reuse=Get-TCServerSameApplicationRequest @reuseArgs
 Assert-Check ($reuse.CanReuse -and $reuse.CanReuseAuthorization -and $reuse.AuthorizationState -ceq 'Verified' -and $reuse.ClientResponse.ConfigRevision -eq 3 -and $reuse.ClientRequest.RequestId -ceq $r.RequestId -and $reuse.ClientResponse.DeviceId -ceq $r.DeviceId -and -not $checkpointCase.Run.CandidateNodeId) 'No-local-node HostKeyUpdate returns the original request plus current read-only verified authorization instead of creating another Peer'
 Assert-Check (($fixture.Calls|Select-Object -Skip $callStart|Where-Object {$_.Kind -ceq 'Read'}|ForEach-Object {$_.Action}) -join ',' -ceq 'server_info,inspect,server_info,deployment_state') 'Authorization checkpoint reuse issues only app inspection and deployment_state reads'
 Assert-Check (@($fixture.Calls|Where-Object {$_.Kind -in @('Start','Authenticate')}).Count -eq $loginStart -and (Get-FileHash $checkpointCase.RunPath).Hash -ceq $sourceHash -and -not $reuse.PSObject.Properties['Plan'] -and -not $reuse.PSObject.Properties['ApprovedChangeDigest']) 'Checkpoint reuse performs no login source-task edit or transfer of old business approval'
 foreach($badState in @('RevokedPeer','OtherRequest','OtherApp','PendingTransaction')){
  $fixture.DeploymentState=Copy-Public ([pscustomobject]@{Kind='TradeChannel.DeploymentState';Status='Settled';RemoteOwnerId=$checkpointCase.Server.RemoteOwnerId;NodeId=$checkpointCase.Server.NodeId;ServerPublicKey=$checkpointCase.Server.ServerPublicKey;ClientPublicKey=$r.ClientPublicKey;Transaction=$null;Udp=@{Status='Healthy';ClientAddress=$liveResponse.ClientAddress;ClientResponse=$liveResponse}})
  switch($badState){
   'RevokedPeer'{$fixture.DeploymentState.Udp.Status='Failed'}
   'OtherRequest'{$fixture.DeploymentState.Udp.ClientResponse.DeviceId=[guid]::NewGuid().ToString('D')}
   'OtherApp'{$fixture.DeploymentState.RemoteOwnerId=[guid]::NewGuid().ToString('D')}
   'PendingTransaction'{$fixture.DeploymentState.Transaction=@{Action='authorize'};$fixture.DeploymentState.Status='NeedsRecovery'}
  }
  Assert-Reject {Get-TCServerSameApplicationRequest @reuseArgs} SameApplicationAuthorizationUnverified ('Authorization checkpoint blocks '+$badState+' without falling back to a new Peer')
 }
 $fixture.Info=Copy-Public $emptyInfo;$fixture.Inspection=Copy-Public $emptyInspection
 Assert-Reject {Get-TCServerSameApplicationRequest @reuseArgs} IdentityEvidenceChanged 'Actual NotInstalled app never reuses an old same-app authorization checkpoint'

 $case=New-Case 'unchanged'
 $verify=Start-TCServerIdentityVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -Credential $typedCredential
 $assessment=New-TCServerIdentityAssessment -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -VerificationToken $verify.VerificationToken
 Assert-Check ($assessment.Classification -ceq 'Unchanged' -and -not $assessment.RequiresFreshApproval) 'Same key and fully verified same app classify Unchanged'
 $result=Confirm-TCServerIdentityTransition -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -AssessmentToken $assessment.AssessmentToken -ConfirmedFingerprint $oldFp -ApprovedChangeDigest $assessment.ChangeDigest
 Assert-Check ($result.Server.LocalRecordId -ceq $case.Server.LocalRecordId -and -not $result.RequiresNewDeployment) 'Unchanged verification retains active application record'
 Assert-Kept $case

 $case=New-Case 'generic-reset-declaration';$fixture.Info=Copy-Public $emptyInfo;$fixture.Inspection=Copy-Public $emptyInspection
 $verify=Start-TCServerIdentityVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -Credential $typedCredential
 $assessment=New-TCServerIdentityAssessment -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -VerificationToken $verify.VerificationToken
 Assert-Check ($assessment.Classification -ceq 'ApplicationReset' -and $assessment.RequiresResetDeclaration) 'Observed app absence is assessed independently from reset declaration'
 $genericCommit=@{Root=$case.Root;ServerId=$case.Server.LocalRecordId;SessionRef=$verify.SessionRef;AssessmentToken=$assessment.AssessmentToken;ConfirmedFingerprint=$oldFp;ApprovedChangeDigest=$assessment.ChangeDigest}
 Assert-Reject {Confirm-TCServerIdentityTransition @genericCommit} ReinstallDeclarationRequired 'Actual absence still requires explicit reset-scope confirmation before archive'
 $result=Confirm-TCServerIdentityTransition @genericCommit -DeclaredApplicationReset
 Assert-Check ($result.Classification -ceq 'ApplicationReset' -and $result.RequiresFreshDeviceIdentity -and $result.RequiresFreshApproval) 'Generic confirmed reset requires new device identity and new business approval'
 Assert-Kept $case

 foreach($changedKey in @($false,$true)){
  $case=New-Case ('application-reset-'+$changedKey);$fixture.Fingerprint=$(if($changedKey){$newFp}else{$oldFp});$fixture.Info=Copy-Public $emptyInfo;$fixture.Inspection=Copy-Public $emptyInspection
  Assert-Reject {Start-TCServerReinstallVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -Credential $typedCredential} ReinstallDeclarationRequired 'Legacy declaration guard remains compatible'
  $verify=Start-TCServerReinstallVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -Credential $typedCredential -DeclaredReinstalled
  $preview=New-TCServerReinstallPreview -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -VerificationToken $verify.VerificationToken
  Assert-Check ($preview.Code -ceq 'ReinstallTrustRequired' -and $preview.NewFingerprint -ceq $fixture.Fingerprint) ('Legacy preview supports genuine reset with changed key='+$changedKey)
  $approval=Approve-TCServerReinstallFingerprint -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -PreviewToken $preview.PreviewToken -ConfirmedFingerprint $fixture.Fingerprint -Credential $typedCredential
  $before=(Get-FileHash $case.RegistryPath).Hash
  $assessment=Confirm-TCServerReinstallRecord -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -ApprovalToken $approval.ApprovalToken -ConfirmedFingerprint $fixture.Fingerprint -ApprovedChangeDigest $preview.ChangeDigest
  Assert-Check ($assessment.Code -ceq 'ServerIdentityAssessmentRequired' -and $assessment.Classification -ceq 'ApplicationReset' -and (Get-FileHash $case.RegistryPath).Hash -ceq $before) 'Legacy trust-only approval reads actual app evidence and returns bound assessment without committing'
  $rev=(Read-TCDJson $case.RegistryPath).Revision
  $result=Confirm-TCServerReinstallRecord -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -ApprovalToken $assessment.ApprovalToken -ConfirmedFingerprint $fixture.Fingerprint -ApprovedChangeDigest $assessment.ChangeDigest
  $new=$result.Server;$archived=Get-TCServer $case.Root $case.Server.LocalRecordId -IncludeArchived
  Assert-Check ($result.Code -ceq 'ServerReinstallConfirmed' -and $new.LocalRecordId -cne $case.Server.LocalRecordId -and $archived.RecordState -ceq 'Archived' -and $archived.ReplacedByServerId -ceq $new.LocalRecordId -and $archived.ArchivedTasks.Count -eq 3 -and (Read-TCDJson $case.RegistryPath).Revision -eq $rev+1) 'Reset archives old and publishes fresh record in a single atomic revision'
  Assert-Check (-not $new.RemoteOwnerId -and -not $new.NodeId -and -not $new.ServerPublicKey -and -not $new.ManagementSigningPublicKey -and -not $new.CredentialRef -and -not $new.Connection.IdentityFile -and $new.SourceJobIds.Count -eq 0 -and $new.LinkedNodeIds.Count -eq 0 -and $new.OwnershipState -ceq 'Unverified' -and $new.ManagementAccessState -ceq 'NeedsAuthentication' -and $new.Reinstall.FreshDeviceIdentityRequired) 'Reset inherits no app owner tunnel signing device authorization task or saved credential'
  Assert-Check ($new.HostTrustState -ceq 'Verified' -and $new.PinnedHostKey -ceq $fixture.Fingerprint) 'SSH trust is verified separately from fresh app ownership'
  Assert-Kept $case
  Assert-Reject {Assert-TCServerTaskActive -Root $case.Root -RunId $case.Run.RunId} ServerArchived 'Archived original deployment cannot resume old authorization'
  Assert-Reject {Set-TCServerRecord -Root $case.Root -Id $new.LocalRecordId -ServerInfo $templateInfo} ReinstallOldIdentity 'Fresh record cannot import archived app identity'
  Assert-Reject {Set-TCServerRecord -Root $case.Root -Id $new.LocalRecordId -CredentialRef $case.Server.CredentialRef} ReinstallOldCredential 'Fresh record cannot reuse old credential reference'
  Assert-Reject {Set-TCServerLink -Root $case.Root -ServerId $new.LocalRecordId -NodeId $case.DeviceId} ReinstallOldDevice 'Fresh record cannot associate archived device line'
  Assert-Check ((Assert-TCServerIdentitySessionBinding -Root $case.Root -ServerId $new.LocalRecordId -SessionRef $verify.SessionRef -TargetToken $result.TargetToken).Server.LocalRecordId -ceq $new.LocalRecordId) 'Reset can attach its verified live session to new target without another credential prompt'
  Assert-Reject {Get-TCServerSameApplicationRequest -Root $case.Root -ServerId $new.LocalRecordId -SourceRunId $case.Run.RunId -SessionRef $verify.SessionRef -TargetToken $result.TargetToken} SameApplicationReuseBlocked 'Reset-generation request can never be migrated through the same-app helper'
  Assert-Reject {& $mainFlow {param($Root,$ServerId,$SourceRunId,$Ref,$Token)
   New-TCDeploymentRun -Root $Root -Intent Auto -ServerId $ServerId -ReuseSourceRunId $SourceRunId -IdentitySessionRef $Ref -IdentityTargetToken $Token -ClientInspection @{EngineStaged=$true;WgHelperStaged=$true;NinjaTraderPaths=@();DirectDnsIPv4=@('127.0.0.1')}
  } $case.Root $new.LocalRecordId $case.Run.RunId $verify.SessionRef $result.TargetToken} SameApplicationReuseBlocked 'Main constructor cannot consume a reset-generation helper token or old request identity'
  Assert-Reject {Confirm-TCServerReinstallRecord -Root $case.Root -ServerId $case.Server.LocalRecordId -SessionRef $verify.SessionRef -ApprovalToken $assessment.ApprovalToken -ConfirmedFingerprint $fixture.Fingerprint -ApprovedChangeDigest $assessment.ChangeDigest} ServerArchived 'Replayed reset cannot create duplicate record'
 }

 $case=New-Case 'blocked-evidence'
 $verify=Start-TCServerIdentityVerification -Root $case.Root -ServerId $case.Server.LocalRecordId -Credential $typedCredential -DeclaredApplicationReset
 $assessmentArgs=@{Root=$case.Root;ServerId=$case.Server.LocalRecordId;SessionRef=$verify.SessionRef;VerificationToken=$verify.VerificationToken}
 $blockedCases=@(
  @{Name='Foreign owner';Change={param($F)$F.Info.RemoteOwnerId=[guid]::NewGuid().ToString('D')};Code='ApplicationIdentityMismatch'},
  @{Name='Different node';Change={param($F)$F.Info.Node.NodeId=[guid]::NewGuid().ToString('D')};Code='ApplicationIdentityMismatch'},
  @{Name='Different tunnel key';Change={param($F)$F.Info.Node.ServerPublicKey=('E'*43+'=')};Code='ApplicationIdentityMismatch'},
  @{Name='Different management signer';Change={param($F)$F.Info.ManagementSigningPublicKey.n=('B'*512)};Code='ManagementIdentityMismatch'},
  @{Name='Pending recovery';Change={param($F)$F.Info.PendingOperation=@{Action='apply'};$F.Info.OwnershipState='NeedsRecovery'};Code='NeedsRecovery'},
  @{Name='Foreign inspect resources';Change={param($F)$F.Inspection.Supported=$false;$F.Inspection.Issues=@(@{Code='ForeignFirewall'})};Code='IdentityInspectionBlocked'},
  @{Name='Failed configuration health';Change={param($F)$F.Info.Health.LocalConfiguration='Failed'};Code='IdentityEvidenceMismatch'},
  @{Name='Unknown ownership';Change={param($F)$F.Info.OwnershipState='Unknown'};Code='ApplicationIdentityUnknown'},
  @{Name='Partial ownership';Change={param($F)$F.Info.OwnershipState='OwnedNotInstalled'};Code='ApplicationIdentityUnknown'},
  @{Name='Missing inspection boolean';Change={param($F)$F.Inspection.PSObject.Properties.Remove('OwnedDeployment')};Code='IdentityEvidenceIncomplete'},
  @{Name='Unknown management API';Change={param($F)$F.Info.ManagementApiVersion=99};Code='IdentityEvidenceIncomplete'},
  @{Name='Missing actual owner field';Change={param($F)$F.Info.PSObject.Properties.Remove('RemoteOwnerId')};Code='IdentityEvidenceIncomplete'},
  @{Name='Declared reset with retained owner';Change={param($F)$F.Info=Copy-Public $emptyInfo;$F.Info.RemoteOwnerId=$templateInfo.RemoteOwnerId;$F.Inspection=Copy-Public $emptyInspection};Code='IdentityEvidenceMismatch'})
 $before=(Get-FileHash $case.RegistryPath).Hash
 foreach($item in $blockedCases){$fixture.Info=Copy-Public $templateInfo;$fixture.Inspection=Copy-Public $templateInspection;& $item.Change $fixture;$blocked=New-TCServerIdentityAssessment @assessmentArgs;Assert-Check ($blocked.Classification -ceq 'Blocked' -and -not $blocked.CanCommit -and $blocked.ReasonCode -ceq $item.Code -and -not $blocked.PSObject.Properties['AssessmentToken']) ('Block unproven app transition: '+$item.Name)}
 $fixture.Info=Copy-Public $templateInfo;$fixture.Inspection=Copy-Public $templateInspection;$fixture.FailRead='server_info';$blocked=New-TCServerIdentityAssessment @assessmentArgs
 Assert-Check ($blocked.Classification -ceq 'Blocked' -and -not $blocked.CanCommit) 'Actual read rejection cannot be replaced by declaration or caller data';$fixture.FailRead=''
 $fixture.OnRead={param($F,$Action)if($Action -ceq 'inspect'){$F.Info.ConfigRevision++}};$blocked=New-TCServerIdentityAssessment @assessmentArgs
 Assert-Check ($blocked.Classification -ceq 'Blocked' -and $blocked.ReasonCode -ceq 'IdentityObservationChanged') 'App changing between real read phases is blocked';$fixture.OnRead=$null
 Assert-Check ((Get-FileHash $case.RegistryPath).Hash -ceq $before) 'All foreign mismatch partial and unknown branches leave registry unchanged'
 Assert-Kept $case

 # Reinstall before the first apply is an empty application target, not an
 # invented prior application identity. Its old plan approvals still expire.
 function New-UndeployedCase {param([string]$Label)
  $root=Join-Path $taskRoot $Label;$null=New-TCDDirectory $root;$c=@{Host='127.0.0.1';Port=2222;User='root';IdentityFile=''}
  $server=Set-TCServerRecord -Root $root -Connection $c -Name $Label -PinnedFingerprint $oldFp
  $id=[guid]::NewGuid().ToString('D');$path=Join-Path $root ('deployments/runs/'+$id+'/state.json');$directory=Join-Path ([IO.Path]::GetDirectoryName($path)) 'client';$request=Write-RequestFixture $directory ([guid]::NewGuid().ToString('D'))
  $run=[pscustomobject]@{SchemaVersion=1;RunId=$id;ServerRecordId=$server.LocalRecordId;Status='WaitingUser';Stage='PlanReady';ClientRequest=$request;RequestDirectory=$directory;ClientResponse=$null;ServerInfo=$null;LastRemoteMutation=$null;DispatchIntent=$null;ApprovedChangeDigest=('e'*64);AllowManagementInitialize=$true;AllowDeviceAuthorize=$true;RecoveryRequired=$false;ExistingDevice=$false}
  Write-TCDJson $path $run
  return [pscustomobject]@{Root=$root;Server=$server;Run=$run;RunPath=$path;Connection=$c;RegistryPath=(Join-Path $root 'servers/registry.json')}
 }
 $fresh=New-UndeployedCase 'repeated-before-first-apply';$fixture.Info=Copy-Public $emptyInfo;$fixture.Inspection=Copy-Public $emptyInspection
 foreach($fingerprint in @($newFp,('SHA256:'+('C'*43)),('SHA256:'+('C'*43)))){
  $fixture.Fingerprint=$fingerprint
  $s=Start-TCDeploySession -Root $fresh.Root -RunId ([guid]::NewGuid().ToString('D')) -Connection $fresh.Connection -Credential $typedCredential -PinnedFingerprint $fresh.Server.PinnedHostKey
  $v=Start-TCServerIdentityVerification -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SessionRef $s.SessionRef
  $p=New-TCServerIdentityTrustPreview -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SessionRef $s.SessionRef -VerificationToken $v.VerificationToken
  $a=Approve-TCServerIdentityFingerprint -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SessionRef $s.SessionRef -PreviewToken $p.PreviewToken -ConfirmedFingerprint $fingerprint -Credential $typedCredential
  $assessment=New-TCServerIdentityAssessment -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SessionRef $s.SessionRef -ApprovalToken $a.ApprovalToken
  Assert-Check ($assessment.Classification -ceq 'UndeployedTarget' -and $assessment.CanCommit -and -not $assessment.RequiresResetDeclaration -and -not $assessment.PreservesApplicationIdentity) 'Actual clean app absence supports a never-deployed target without inventing prior app identity'
  $result=Confirm-TCServerIdentityTransition -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SessionRef $s.SessionRef -AssessmentToken $assessment.AssessmentToken -ConfirmedFingerprint $fingerprint -ApprovedChangeDigest $assessment.ChangeDigest
  Assert-Check ($result.Server.LocalRecordId -ceq $fresh.Server.LocalRecordId -and $result.Server.PinnedHostKey -ceq $fingerprint -and $result.RequiresNewDeployment -and $result.RequiresFreshDeviceIdentity -and $result.RequiresFreshApproval -and -not $result.Server.RemoteOwnerId -and -not $result.Server.NodeId -and -not $result.Server.ServerPublicKey -and $result.Server.OwnershipState -ceq 'Unverified' -and $result.Server.HostTrustState -ceq 'Verified' -and @(Get-TCServers $fresh.Root).Count -eq 1) 'Repeated reinstall before first apply preserves the empty card and requires fresh scoped preparation'
  Assert-Reject {Assert-TCServerTaskActive -Root $fresh.Root -RunId $fresh.Run.RunId} ServerTaskIdentityChanged 'Never-deployed target cannot reuse its earlier plan approval'
  Assert-Reject {Get-TCServerSameApplicationRequest -Root $fresh.Root -ServerId $fresh.Server.LocalRecordId -SourceRunId $fresh.Run.RunId -SessionRef $s.SessionRef -TargetToken $result.TargetToken} SameApplicationReuseBlocked 'Never-deployed transition cannot copy a prior generation request'
  $fresh.Server=$result.Server
 }
 $unverifiedCases=@(
  @{Name='linked';Change={param($C)$C.Server.LinkedNodeIds=@([guid]::NewGuid().ToString('D'))}},
  @{Name='saved-auth';Change={param($C)$C.Server.CredentialRef=[guid]::NewGuid().ToString('D')}},
  @{Name='partial-owner';Change={param($C)$C.Server.RemoteOwnerId=[guid]::NewGuid().ToString('D')}},
  @{Name='authorized-response';Change={param($C)$C.Run.ClientResponse=@{Kind='TradeChannel.ClientResponse';Status='Authorized'}}},
  @{Name='unresolved-dispatch';Change={param($C)$C.Run.DispatchIntent=@{Mutating=$true;State='Prepared';Operation='apply'}}},
  @{Name='old-mutation-receipt';Change={param($C)$C.Run.LastRemoteMutation=@{Operation='apply';State='Completed'}}},
  @{Name='unresolved-tcp';Change={param($C)$C.Run|Add-Member NoteProperty UnresolvedTcpMutation @{Operation='transport_apply'}}})
 foreach($item in $unverifiedCases){
  $c=New-UndeployedCase ('blocked-unverified-'+$item.Name);& $item.Change $c;Write-TCDJson $c.RunPath $c.Run;Write-TCDJson $c.RegistryPath @{SchemaVersion=1;Revision=2;Servers=@($c.Server)}
  $fixture.Fingerprint=$oldFp;$fixture.Info=Copy-Public $emptyInfo;$fixture.Inspection=Copy-Public $emptyInspection
  $v=Start-TCServerIdentityVerification -Root $c.Root -ServerId $c.Server.LocalRecordId -Credential $typedCredential
  $before=(Get-FileHash $c.RegistryPath).Hash;$blocked=New-TCServerIdentityAssessment -Root $c.Root -ServerId $c.Server.LocalRecordId -SessionRef $v.SessionRef -VerificationToken $v.VerificationToken
  Assert-Check ($blocked.Classification -ceq 'Blocked' -and -not $blocked.CanCommit -and (Get-FileHash $c.RegistryPath).Hash -ceq $before) ('Clean remote absence cannot discard unverified local references: '+$item.Name)
 }

 # Legacy import reads real bounded local checkpoints, never a live server.
 function New-LegacyFixture {param([string]$Root,[string]$NodeId,[string]$ServerKey)
  $planJobId=[guid]::NewGuid().ToString('D');$applyJobId=[guid]::NewGuid().ToString('D');$planId=[guid]::NewGuid().ToString('D');$jobs=Join-Path $Root 'linux-jobs';$planDir=Join-Path $jobs $planJobId;$applyDir=Join-Path $jobs $applyJobId
  $request=Write-RequestFixture (Join-Path $planDir 'client') ([guid]::NewGuid().ToString('D'));$hash=& $registry {param($R)Get-TCServerTextDigest (ConvertTo-Json -InputObject $R -Depth 8 -Compress)} $request
  $conn=@{Host='127.0.0.1';Port=2222;User='root';IdentityFile=''}
  $planJob=[pscustomobject]@{SchemaVersion=1;JobId=$planJobId;Operation='Plan';Connection=$conn;Name='Checkpoint';PublicEndpoint='127.0.0.1:51820';TunnelSubnet='10.78.0.0/24';ParentJobId='';PlanId='';RequestJobId=$planJobId;RequestId=$request.RequestId;RequestHash=$hash}
  $plan=[pscustomobject]@{Supported=$true;PlanId=$planId;Name=$planJob.Name;PublicEndpoint=$planJob.PublicEndpoint;TunnelSubnet=$planJob.TunnelSubnet;ServerAddress='10.78.0.1/24';ClientAddress='10.78.0.2/32';RequiresCloudFirewall=$true;PlanExpiresAt=[DateTime]::UtcNow.AddHours(1).ToString('o')}
  $applyJob=Copy-Public $planJob;$applyJob.JobId=$applyJobId;$applyJob.Operation='Apply';$applyJob.ParentJobId=$planJobId;$applyJob.PlanId=$planId
  $response=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$request.RequestId;DeviceId=$request.DeviceId;ClientPublicKey=$request.ClientPublicKey;NodeId=$NodeId;ServerPublicKey=$ServerKey;PublicEndpoint=$planJob.PublicEndpoint;TunnelSubnet=$planJob.TunnelSubnet;ClientAddress=$plan.ClientAddress;ServerAddress=$plan.ServerAddress;AddressFamilies=@('IPv4')}
  Write-TCDJson (Join-Path $planDir 'job.json') $planJob;Write-TCDJson (Join-Path $planDir 'result.json') @{SchemaVersion=1;JobId=$planJobId;Operation='Plan';Status='Completed';ExitCode=0;OutcomeUnknown=$false;Data=$plan}
  Write-TCDJson (Join-Path $applyDir 'job.json') $applyJob;Write-TCDJson (Join-Path $applyDir 'result.json') @{SchemaVersion=1;JobId=$applyJobId;Operation='Apply';Status='Completed';ExitCode=0;OutcomeUnknown=$false;Data=@{Node=@{NodeId=$NodeId;ServerPublicKey=$ServerKey;PublicEndpoint=$planJob.PublicEndpoint};ClientResponse=$response}}
  Write-TCDJson (Join-Path $applyDir 'public.response.json') $response
  $config=('[Interface]'+"`r`n"+'PrivateKey = '+('F'*43+'=')+"`r`n"+'Address = '+$plan.ClientAddress+"`r`n"+'[Peer]'+"`r`n"+'PublicKey = '+$ServerKey+"`r`n"+'Endpoint = '+$planJob.PublicEndpoint+"`r`n"+'AllowedIPs = 0.0.0.0/0'+"`r`n"+'PersistentKeepalive = 25'+"`r`n")
  Write-PrivateFixture (Join-Path $applyDir 'client.conf') $config
  return [pscustomobject]@{PlanJobId=$planJobId;ApplyJobId=$applyJobId;NodeId=$NodeId;PlanDir=$planDir;ApplyDir=$applyDir;Request=$request}
 }
 $onlyAttemptRoot=Join-Path $taskRoot 'legacy-attempt-only';$attemptId=[guid]::NewGuid().ToString('D')
 Write-TCDJson (Join-Path $onlyAttemptRoot ('linux-jobs/'+$attemptId+'/job.json')) @{SchemaVersion=1;JobId=$attemptId;Connection=@{Host='127.0.0.1';Port=2222;User='root'};Operation='Inspect'}
 $callsBefore=$fixture.Calls.Count;$index=Import-TCLegacyServerIndex $onlyAttemptRoot
 Assert-Check ($index.Imported -eq 0 -and @(Get-TCServers $onlyAttemptRoot).Count -eq 0) 'Schema plus Connection or failed inspect attempt is not a formal legacy checkpoint'
 $legacyRoot=Join-Path $taskRoot 'legacy-real-checkpoints';$checkpoint=New-LegacyFixture $legacyRoot ([guid]::NewGuid().ToString('D')) ('J'*43+'=')
 $index=Import-TCLegacyServerIndex $legacyRoot;$cards=@(Get-TCServers $legacyRoot)
 Assert-Check ($index.Imported -ge 1 -and $cards.Count -eq 1 -and $cards[0].SourceJobIds.Count -eq 2 -and $cards[0].NodeId -ceq $checkpoint.NodeId -and $cards[0].ManagementAccessState -ceq 'NeedsAuthentication' -and $cards[0].OwnershipState -ceq 'AwaitIdentityVerification' -and -not $cards[0].PinnedHostKey) 'Valid plan and authorized config lineage creates one unverified recovery card rather than SSH or app trust'
 Assert-Check (@($cards[0].LegacyCheckpoints|Where-Object {$_.Kind -ceq 'Config'}).Count -eq 1) 'A config checkpoint must match the real terminal authorization and original private request'
 $registryPath=Join-Path $legacyRoot 'servers/registry.json';$before=(Get-FileHash $registryPath).Hash;$index=Import-TCLegacyServerIndex $legacyRoot
 Assert-Check ($index.Imported -eq 0 -and (Get-FileHash $registryPath).Hash -ceq $before) 'Repeating legacy import does not duplicate checkpoints or rewrite the registry'
 Write-PrivateFixture (Join-Path $checkpoint.PlanDir 'client/client.key') ('K'*43+'=');$index=Import-TCLegacyServerIndex $legacyRoot
 Assert-Check ($index.Imported -eq 0 -and (Get-FileHash $registryPath).Hash -ceq $before) 'Contradictory or altered private checkpoint files cannot update recovery records'
 $archiveRoot=Join-Path $taskRoot 'legacy-archived-checkpoints';$checkpoint=New-LegacyFixture $archiveRoot ([guid]::NewGuid().ToString('D')) ('L'*43+'=')
 Write-TCDJson (Join-Path $checkpoint.PlanDir 'archive.json') @{SchemaVersion=1;JobId=$checkpoint.PlanJobId;Archived=$true}
 $index=Import-TCLegacyServerIndex $archiveRoot
 Assert-Check ($index.Imported -eq 0 -and @(Get-TCServers $archiveRoot).Count -eq 0) 'Archived plan lineage cannot return through a child authorization or config checkpoint'
 $existing=New-Case 'legacy-different-app-at-same-ip';$checkpoint=New-LegacyFixture $existing.Root ([guid]::NewGuid().ToString('D')) ('M'*43+'=');$before=(Get-FileHash $existing.RegistryPath).Hash
 $index=Import-TCLegacyServerIndex $existing.Root
 Assert-Check ($index.Imported -eq 0 -and (Get-FileHash $existing.RegistryPath).Hash -ceq $before -and $checkpoint.ApplyJobId -notin @((Get-TCServer $existing.Root $existing.Server.LocalRecordId).SourceJobIds)) 'Another application at the same IP is neither merged nor registered as a trusted existing server'
 $known=New-Case 'legacy-matching-app';$checkpoint=New-LegacyFixture $known.Root $known.Server.NodeId $known.Server.ServerPublicKey;$legacyCallsBefore=$fixture.Calls.Count;$index=Import-TCLegacyServerIndex $known.Root;$matched=Get-TCServer $known.Root $known.Server.LocalRecordId
 Assert-Check ($index.Imported -ge 1 -and $checkpoint.ApplyJobId -in @($matched.SourceJobIds) -and $matched.PinnedHostKey -ceq $known.Server.PinnedHostKey -and $matched.OwnershipState -ceq $known.Server.OwnershipState -and $matched.ManagementAccessState -ceq $known.Server.ManagementAccessState -and (Get-TCDDigest $matched.LinkedNodeIds) -ceq (Get-TCDDigest $known.Server.LinkedNodeIds)) 'Legacy association uses matching node and tunnel identity while preserving independently verified ownership links and SSH trust'
 Assert-Check ($fixture.Calls.Count -eq $legacyCallsBefore) 'Legacy importer itself performs no authentication or remote operation'

 # Source trust assertions supplement behavioral tests, including secret-safe
 # classification and the approved ownership boundary. No binaries are rebuilt
 # in the shared source tree by this test or either backend module.
 $cs=[IO.File]::ReadAllText((Join-Path $PackageRoot 'deployment/TradeChannelDeployHost.cs'))
 $registryText=[IO.File]::ReadAllText((Join-Path $PackageRoot 'ServerRegistry.psm1'))
 $transportText=[IO.File]::ReadAllText((Join-Path $PackageRoot 'DeploymentTransport.psm1'))
 Assert-Check ($cs.Contains('ClassifyAccessFailure(ex,false)') -and $cs.Contains('HostKeyAlgorithm=observedAlgorithm') -and $cs.Contains('e.CanTrust=pinned.Length>0&&fingerprint==pinned')) 'Source trust: real typed diagnostics and exact-pin host acceptance'
 $connect=$cs.Substring($cs.IndexOf('void Connect('),$cs.IndexOf('void Execute(')-$cs.IndexOf('void Connect('))
 Assert-Check (-not $connect.Contains('ex.Message') -and -not $connect.Contains('ex.ToString')) 'Source trust: SSH exception contents never leave Connect'
 Assert-Check ($transportText.Contains('GetNamedPipeServerProcessId') -and $transportText.Contains('Assert-TCDeployPipeOwner $pipe $SessionRef') -and $transportText.Contains("@('server_info','inspect','server_info')")) 'Source trust: OS executor binding and actual coherent read evidence'
 Assert-Check (-not $registryText.Contains('ReinstallIdentityUnchanged') -and $registryText.Contains('Get-TCDeployServerIdentityEvidence -SessionRef $SessionRef') -and $registryText.Contains("'VerifiedIdentityTransition.v2'")) 'Source trust: same-key reset branch and evidence-bound transition digest'
 $newAst=$null;$parseTokens=$null;$parseErrors=$null;$newAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot 'ServerRegistry.psm1'),[ref]$parseTokens,[ref]$parseErrors)
 foreach($name in @('Start-TCServerIdentityVerification','New-TCServerIdentityAssessment','Confirm-TCServerIdentityTransition')){
  $function=$newAst.Find({param($N)$N -is [Management.Automation.Language.FunctionDefinitionAst] -and $N.Name -ceq $name},$true)
  $parameters=@($function.Body.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
  Assert-Check (-not @($parameters|Where-Object {$_ -in @('ServerInfo','Inspection','Observation','ObservedFingerprint','Evidence')}).Count) ('Source trust: '+$name+' accepts no arbitrary remote evidence')
 }
 Assert-Check ((-not $productionHash -and -not [IO.File]::Exists($productionBinary)) -or ($productionHash -and (Get-FileHash $productionBinary).Hash -ceq $productionHash)) 'Shared source executable remains untouched'
 $result=[pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();Framework='net48';CheckCount=$checks.Count;Checks=$checks.ToArray();NetworkScope='127.0.0.1 and mock sessions only';RealNetworkChanged=$false;ProgramDataChanged=$false;SourceBinariesChanged=$false}
 $json=ConvertTo-Json -InputObject $result -Depth 6
 if($OutputPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,(New-Object Text.UTF8Encoding($true)))}
 $json
}catch{
 Write-Output ('TestFailure at line '+$_.InvocationInfo.ScriptLineNumber+': '+$_.Exception.Message+'; '+$_.ScriptStackTrace)
 throw
}finally{
 # Cleanup is confined to THIS verified temporary root and OUR new processes.
 foreach($r in $liveRefs){try{$null=Stop-TCDeploySession $r -Cancel;$null=Stop-TCDeploySession $r;$p=Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue;if($p){try{$null=$p.WaitForExit(5000)}finally{$p.Dispose()}}}catch{}}
 if($python){if(-not $python.HasExited){$python.Kill();$python.WaitForExit()};$python.Dispose()}
 foreach($process in @(Get-Process -Name TradeChannelDeployHost -ErrorAction SilentlyContinue)){
  try{if($process.Path -ieq (Join-Path $fixturePackage 'deployment\TradeChannelDeployHost.exe')){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}}}finally{$process.Dispose()}
 }
 $absolute=[IO.Path]::GetFullPath($taskRoot);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if($absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -cmatch '^tc-identity-transitions-[0-9a-f]{32}$' -and [IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction Continue}
}
