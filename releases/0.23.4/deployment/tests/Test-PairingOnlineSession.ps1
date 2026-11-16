#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$TestDependencyRoot,[switch]$Inner,[string]$IsolatedRoot)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
if(-not $Inner){
    $ownedRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-online-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $ownedRoot
    try{
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-PackageRoot',$PackageRoot,'-Inner','-IsolatedRoot',$ownedRoot)
        if($TestDependencyRoot){$arguments+=@('-TestDependencyRoot',[IO.Path]::GetFullPath($TestDependencyRoot))}
        & (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments
        $resultCode=$LASTEXITCODE
    }finally{
        $absolute=[IO.Path]::GetFullPath($ownedRoot);$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -match '^tc-online-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
    }
    exit $resultCode
}
$checks=New-Object 'Collections.Generic.List[string]'
function Assert-Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$checks.Add($Name)}
function Assert-Reject {param([scriptblock]$Action,[string]$Code,[string]$Name)$matched=$false;try{& $Action|Out-Null}catch{$matched=$_.Exception.Message.Contains('[TC:'+$Code+']');if(-not $matched){throw ('Unexpected error for '+$Name+': '+$_.Exception.Message)}};Assert-Check $matched $Name}
$root=[IO.Path]::GetFullPath($IsolatedRoot)
$allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
if(-not $root.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -notmatch '^tc-online-[0-9a-f]{32}$'){throw 'An isolated owned temporary root is required.'}
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')){
    $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
$process=$null;$session=$null
try{
    # A source checkout intentionally has no built runtime DLL/package receipt.
    # Build a private minimal test package instead of modifying shared binaries.
    $package=Join-Path $root 'package';$null=New-Item -ItemType Directory -Path $package
    foreach($file in @(Get-ChildItem -LiteralPath $PackageRoot -File|Where-Object {$_.Extension -in @('.ps1','.psm1')})){
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package $file.Name)
    }
    foreach($name in @('version.json','ConnectionMethods.json')){Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination (Join-Path $package $name)}
    foreach($folder in @('deployment','runtime','assets','assets\lib','linux')){$null=New-Item -ItemType Directory -Path (Join-Path $package $folder)}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'assets\lib') -File -Filter '*.dll')){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package ('assets\lib\'+$file.Name))}
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'assets\wg.exe') -Destination (Join-Path $package 'assets\wg.exe')
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'linux') -File -Filter '*.py')){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package ('linux\'+$file.Name))}
    foreach($name in @('dependencies.lock.json','TradeChannelPairCrypto.dll','PairingOnlineTransport.cs','TradeChannelDeployHost.cs')){Copy-Item -LiteralPath (Join-Path $PackageRoot ('deployment\'+$name)) -Destination (Join-Path $package ('deployment\'+$name))}
    foreach($name in @('TradeChannel.Components.ps1','TCDevicePath.cs','TCNetTable.cs')){Copy-Item -LiteralPath (Join-Path $PackageRoot ('runtime\'+$name)) -Destination (Join-Path $package ('runtime\'+$name))}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $PackageRoot 'runtime') -File|Where-Object {$_.Extension -in @('.ps1','.cs','.json')})){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $package ('runtime\'+$file.Name)) -Force}
    $version=([IO.File]::ReadAllText((Join-Path $package 'version.json'))|ConvertFrom-Json).Version
    $assembly=Join-Path $package 'deployment\SessionTest.AssemblyInfo.cs'
    [IO.File]::WriteAllText($assembly,('[assembly:System.Reflection.AssemblyVersion("'+$version+'.0")][assembly:System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]'),(New-Object Text.UTF8Encoding($false)))
    $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /platform:x64 ('/out:'+(Join-Path $package 'deployment\TradeChannelDeployHost.exe')) /reference:System.Web.Extensions.dll ('/reference:'+(Join-Path $package 'assets\lib\Renci.SshNet.dll')) (Join-Path $package 'deployment\TradeChannelDeployHost.cs') $assembly
    if($LASTEXITCODE -ne 0){throw 'Isolated Host compilation failed.'}
    & $compiler /nologo /target:library /platform:x64 ('/out:'+(Join-Path $package 'runtime\TCDevicePath.dll')) (Join-Path $package 'runtime\TCDevicePath.cs') (Join-Path $package 'runtime\TCNetTable.cs') $assembly
    if($LASTEXITCODE -ne 0){throw 'Isolated pipe identity component compilation failed.'}
    [IO.File]::WriteAllText((Join-Path $package 'package.sha256'),((Get-FileHash -LiteralPath (Join-Path $package 'runtime\TCDevicePath.dll') -Algorithm SHA256).Hash+'|runtime\TCDevicePath.dll'),(New-Object Text.UTF8Encoding($false)))
    Import-Module (Join-Path $package 'PairingOnline.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $package 'DeploymentTransport.psm1') -Force -DisableNameChecking
    $start=New-Object Diagnostics.ProcessStartInfo
    $fixtureSource=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests\pairing_online_loopback.py'
    $start.FileName='python.exe';$start.Arguments='-B "'+$fixtureSource+'" "'+$root+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false);$start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    if($TestDependencyRoot){$start.EnvironmentVariables['TC_PAIR_ONLINE_TEST_DEPS']=[IO.Path]::GetFullPath($TestDependencyRoot)}
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$null=$process.Start();$stderr=$process.StandardError.ReadToEndAsync()
    function Read-FixtureLine {$pending=$process.StandardOutput.ReadLineAsync();if(-not $pending.Wait(30000)){throw 'Fixture timeout.'};if(-not $pending.Result){throw ('Fixture stopped: '+$stderr.Result)};$pending.Result|ConvertFrom-Json}
    function Invoke-Fixture {param([string]$Action)$bytes=[Text.Encoding]::UTF8.GetBytes(('{"Action":"'+$Action+'"}')+"`n");$stream=$process.StandardInput.BaseStream;$stream.Write($bytes,0,$bytes.Length);$stream.Flush();Read-FixtureLine}
    function Await-Operation {param($Ref,[string]$Id)
        $end=[DateTime]::UtcNow.AddSeconds(45)
        do{$state=Get-TCDeploySession -SessionRef $Ref;if($state.Status -notin @('Running','Connecting')){if($Id -and $state.OperationId -cne $Id){throw 'Operation ID changed while polling.'};return $state};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $end)
        throw 'Host operation timed out.'
    }
    $target=Read-FixtureLine
    $createdSession=Start-TCDeploySession -Root (Join-Path $root 'state') -RunId ([guid]::NewGuid().ToString())
    $session=$createdSession.SessionRef
    $credential=@{Kind='Password';Password=(ConvertTo-SecureString 'TC_Online_Loopback_Only!' -AsPlainText -Force)}
    $connection=@{Host='127.0.0.1';Port=[int]$target.SshPort;User='root'}
    $null=Set-TCDeployCredential -SessionRef $session -Connection $connection -Credential $credential -PinnedFingerprint $target.SshFingerprint
    $authenticated=Await-Operation $session ''
    Assert-Check ($authenticated.Status -ceq 'Ready' -and $authenticated.HasSession) 'Existing DeployHost authenticates the fixed loopback SSH identity once'
    $credential=$null # Matches management UI behavior after authentication.
    $inputData=@{InviteId=[guid]::NewGuid().ToString();DeviceName='Session only client';ExpiresInSeconds=600;PublicHost='127.0.0.1';Port=[int]$target.Port;ExpectedServerBinding=$target.ExpectedServerBinding;ExpectedManagementFingerprint=$target.ExpectedManagementFingerprint}
    $operationId=[guid]::NewGuid().ToString()
    $started=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $inputData -OperationId $operationId
    Assert-Check ($started.Status -ceq 'Running' -and $started.Operation -ceq 'pair_online_create') 'Public API starts a fixed async online operation using SessionRef only'
    $done=Await-Operation $session $operationId
    Assert-Check ($done.Status -ceq 'Completed' -and $done.HasSession -and $done.AuthenticationGeneration -eq $authenticated.AuthenticationGeneration) ('Create completes without reauthentication: '+$done.Code)
    $invite=Get-TCPairOnlineSessionResult -SessionRef $session -Action create -OperationId $operationId
    $stats=(Invoke-Fixture stats).Data
    Assert-Check ($stats.AuthenticationCount -eq 1 -and $stats.SshCommands -eq 1 -and $stats.EmbeddedMethodsVerified) 'Cleared UI credential is never requested and the uploaded registry is self-contained'
    $same=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $inputData -OperationId $operationId
    Assert-Check ($same.Status -ceq 'Completed' -and $same.Data.InvitationCode -ceq $invite.InvitationCode -and (Invoke-Fixture stats).Data.SshCommands -eq 1) 'Repeated OperationId returns the original in-memory result without another SSH dispatch'
    $changed=@{};foreach($key in $inputData.Keys){$changed[$key]=$inputData[$key]};$changed.DeviceName='Changed intent'
    $reject=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $changed -OperationId $operationId
    Assert-Check ($reject.Code -ceq 'OperationMismatch') 'A reused OperationId cannot change invitation parameters'
    $injected=@{};foreach($key in $inputData.Keys){$injected[$key]=$inputData[$key]};$injected.Command='arbitrary code is forbidden'
    Assert-Reject {Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $injected -OperationId ([guid]::NewGuid().ToString())} InvalidRequest 'Public business input never accepts a remote Command or Source'
    $transport=Get-Module DeploymentTransport
    $packagePayload=(New-TCPairOnlineSshPayload -Action create -InputData $inputData).Stdin|ConvertFrom-Json
    $poll=Get-TCDeploySession $session
    $expected=@{AuthenticationGeneration=$poll.AuthenticationGeneration;HostFingerprint=$poll.AcceptedFingerprint;Connection=$poll.Connection}
    $body=@{Command='PairOnline';Action='create';Input=$inputData;OperationId=[guid]::NewGuid().ToString();Retry=$false;ExpectedSession=$expected;Sources=@{SourcesJson=$packagePayload.SourcesJson;SourcesSHA256=$packagePayload.SourcesSHA256}}
    $expected.AuthenticationGeneration++
    $rejected=& $transport {param($Ref,$Body)Invoke-TCDeployPipe $Ref $Body} $session $body
    Assert-Check ($rejected.Code -ceq 'OnlineSessionBindingMismatch') 'Host rejects a mismatched authentication generation'
    $expected.AuthenticationGeneration--
    $expected.Connection=@{Host='127.0.0.2';Port=[int]$target.SshPort;User='root'}
    $rejected=& $transport {param($Ref,$Body)Invoke-TCDeployPipe $Ref $Body} $session $body
    Assert-Check ($rejected.Code -ceq 'OnlineSessionBindingMismatch') 'Host rejects a different target connection even with the same run and operation request'
    $expected.Connection=$poll.Connection
    $tampered=$packagePayload.SourcesJson|ConvertFrom-Json
    $tampered.'pairing_online.py'+="`n# unexpected uploaded code"
    $badSources=$tampered|ConvertTo-Json -Depth 4 -Compress
    $sha=[Security.Cryptography.SHA256]::Create();try{$badHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($badSources)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $body.Sources=@{SourcesJson=$badSources;SourcesSHA256=$badHash}
    $rejected=& $transport {param($Ref,$Body)Invoke-TCDeployPipe $Ref $Body} $session $body
    Assert-Check ($rejected.Code -ceq 'OnlineSourcePackageMismatch') 'Host rejects arbitrary source even when the caller supplies its matching SHA256'
    $lookup=@{InviteId=$invite.InviteId;ExpectedServerBinding=$inputData.ExpectedServerBinding;ExpectedManagementFingerprint=$inputData.ExpectedManagementFingerprint}
    $statusId=[guid]::NewGuid().ToString();$null=Invoke-TCPairOnlineSession -SessionRef $session -Action status -InputData $lookup -OperationId $statusId
    $status=Await-Operation $session $statusId
    Assert-Check ($status.Status -ceq 'Completed' -and $status.Data.State -ceq 'Open') 'Read-only online status uses the same authenticated SSH session'
    $same=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $inputData -OperationId $operationId
    Assert-Check ($same.Status -ceq 'Completed' -and $same.Data.InvitationCode -ceq $invite.InvitationCode -and (Invoke-Fixture stats).Data.SshCommands -eq 2) 'Old OperationId binding remains cached after another operation'
    $newInput=@{};foreach($key in $inputData.Keys){$newInput[$key]=$inputData[$key]};$newInput.InviteId=[guid]::NewGuid().ToString()
    $lostId=[guid]::NewGuid().ToString();$null=Invoke-Fixture drop_ssh
    $null=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $newInput -OperationId $lostId
    $lost=Await-Operation $session $lostId
    Assert-Check ($lost.Status -ceq 'OutcomeUnknown' -and $lost.HasSession) 'Lost SSH reply keeps the original operation binding and authenticated session'
    $commands=(Invoke-Fixture stats).Data.SshCommands
    $unknown=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $newInput -OperationId $lostId
    Assert-Check ($unknown.Status -ceq 'OutcomeUnknown' -and (Invoke-Fixture stats).Data.SshCommands -eq $commands) 'Polling an unknown outcome does not silently redispatch a mutation'
    $null=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $newInput -OperationId $lostId -Retry
    $recovered=Await-Operation $session $lostId
    Assert-Check ($recovered.Status -ceq 'Completed' -and $recovered.OnlineBinding.Attempts -eq 2 -and $recovered.Data.InviteId -ceq $newInput.InviteId) 'Explicit retry keeps OperationId and InviteId and retrieves the original creation'
    $badId=[guid]::NewGuid().ToString();$null=Invoke-Fixture bad_binding
    $null=Invoke-TCPairOnlineSession -SessionRef $session -Action status -InputData $lookup -OperationId $badId
    $bad=Await-Operation $session $badId
    Assert-Check ($bad.Status -ceq 'Failed' -and $bad.Code -ceq 'OperationBindingMismatch') 'A valid SSH reply with another operation proof is rejected'
    $cancelId=[guid]::NewGuid().ToString();$null=Invoke-TCPairOnlineSession -SessionRef $session -Action cancel -InputData $lookup -OperationId $cancelId
    $cancelled=Await-Operation $session $cancelId
    Assert-Check ($cancelled.Status -ceq 'Completed' -and $cancelled.Data.State -ceq 'Cancelled') 'Cancel runs through the same authenticated session without credentials'
    $legacyId=[guid]::NewGuid().ToString();$null=Invoke-TCDeployOperation -SessionRef $session -Operation server_info -OperationInput @{} -OperationId $legacyId
    $legacy=Await-Operation $session $legacyId
    Assert-Check ($legacy.Status -ceq 'Completed' -and $legacy.Data.ManagementSigningPublicKey) 'Existing management actions continue after online operations'
    $stats=(Invoke-Fixture stats).Data
    Assert-Check ($stats.AuthenticationCount -eq 1 -and $stats.PeerCount -eq 1) 'All management operations share exactly one SSH authentication and add no device'
    $receipt=[IO.File]::ReadAllText((Join-Path $session.Root 'receipt.json'))
    $saved=$receipt|ConvertFrom-Json
    $row=@($saved.OnlineOperations|Where-Object {$_.OperationId -ceq $operationId})[0]
    Assert-Check ($row.InputDigest -cmatch '^[0-9a-f]{64}$' -and $row.SourcesSHA256 -cmatch '^[0-9a-f]{64}$' -and $row.TargetDigest -cmatch '^[0-9a-f]{64}$') 'Durable private receipt records input/source/target digests and operation identity'
    Assert-Check (-not $receipt.Contains($invite.InvitationCode) -and -not $receipt.Contains('TC_Online_Loopback_Only!') -and -not $receipt.Contains('SourcesJson') -and -not $receipt.Contains('DeviceName')) 'Receipt and events contain no invitation code credential source or raw input'
    # 0.22.0 A1: the deploy host accepts 60..86400 seconds and nothing outside it.
    foreach($seconds in @(59,86401)){
        $outOfRange=@{};foreach($key in $inputData.Keys){$outOfRange[$key]=$inputData[$key]}
        $outOfRange.InviteId=[guid]::NewGuid().ToString();$outOfRange.ExpiresInSeconds=$seconds
        $refused=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $outOfRange -OperationId ([guid]::NewGuid().ToString())
        Assert-Check ($refused.Code -ceq 'InvalidRequest') ('Deploy host refuses an invitation lifetime of '+$seconds+' seconds: '+$refused.Code)
    }
    foreach($seconds in @(60,86400)){
        $inRange=@{};foreach($key in $inputData.Keys){$inRange[$key]=$inputData[$key]}
        $inRange.InviteId=[guid]::NewGuid().ToString();$inRange.ExpiresInSeconds=$seconds
        $rangeId=[guid]::NewGuid().ToString()
        $null=Invoke-TCPairOnlineSession -SessionRef $session -Action create -InputData $inRange -OperationId $rangeId
        $range=Await-Operation $session $rangeId
        $granted=[int]([DateTimeOffset]::Parse([string]$range.Data.ExpiresAtUtc)-[DateTimeOffset]::UtcNow).TotalSeconds
        Assert-Check ($range.Status -ceq 'Completed' -and [Math]::Abs($granted-$seconds) -le 5) ('The deploy host accepts and the server grants '+$seconds+' seconds: '+$range.Code)
    }
    [pscustomobject]@{Ok=$true;Runtime=$PSVersionTable.PSVersion.ToString();CheckCount=$checks.Count;Checks=$checks.ToArray();AuthenticationCount=$stats.AuthenticationCount;SshCommands=$stats.SshCommands;PackageScope='Private temporary compiled Host/runtime package';NetworkScope='127.0.0.1 only';RealVps=$false}|ConvertTo-Json -Depth 6
}finally{
    if($session){try{$null=Stop-TCDeploySession -SessionRef $session}catch{try{$null=Stop-TCDeploySession -SessionRef $session -Cancel;$null=Stop-TCDeploySession -SessionRef $session}catch{}}}
    if($process){if(-not $process.HasExited){$process.StandardInput.Close();if(-not $process.WaitForExit(10000)){$process.Kill()}};$process.Dispose()}
    # Loaded .NET assemblies cannot be removed until this child exits. The
    # outer PS process owns cleanup and verifies the exact temporary root.
}
