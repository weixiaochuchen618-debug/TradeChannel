#requires -Version 5.1
# Disposable keys/configs; fake engine and HTTP replies; real syntax check only.
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$package=Split-Path $PSScriptRoot -Parent;$nodes=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
$probe=Import-Module (Join-Path $package 'CandidateProbe.psm1') -Force -PassThru -DisableNameChecking
$work=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('TC-CandidateProbe-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$script:Checks=0
function Check {param([bool]$Ok,[string]$Label)if(-not $Ok){throw ('Candidate probe regression: '+$Label)};$script:Checks++}
function ReadJson {param($p)[IO.File]::ReadAllText($p)|ConvertFrom-Json}
function WriteJson {param($p,$v)[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))}
try{
    & $nodes {$script:ProbeNative=${function:Invoke-TCProcess};$script:TCNativeRunner={param($FilePath,$ArgumentList,$InputText,$TimeoutMilliseconds)if($ArgumentList[0] -notin @('check','pubkey')){throw 'Actual engine launch forbidden.'};& $script:ProbeNative -FilePath $FilePath -ArgumentList $ArgumentList -InputText $InputText -TimeoutMilliseconds $TimeoutMilliseconds}}
    & $probe {
        $script:Starts=0;$script:PortRetry=$false;$script:HttpFailure=$false;$script:ReplyIP='192.0.2.20';$script:Configs=@();$script:Kills=0
        function script:Get-CimInstance {param($ClassName,$Filter,$ErrorAction)@()}
        function script:Get-TCCandidateProbePort {41001+$script:Starts}
        function script:Start-TCBoundedEngineProcess {
            param($Root,$Executable,$Arguments,$SessionId,$MaxBytes)
            $script:Starts++;$path=($Arguments -replace '^run -c "','' -replace '"$','');$script:Configs+=,(Read-TCCandidateProbeJson $path)
            $p=[pscustomobject]@{Id=9876;HasExited=($script:PortRetry -and $script:Starts -eq 1);LogPath='fixture'}
            $p|Add-Member ScriptMethod Kill {$script:Kills++;$this.HasExited=$true};$p|Add-Member ScriptMethod WaitForExit {param($ms)$this.HasExited};$p|Add-Member ScriptMethod Dispose {};return $p
        }
        function script:Test-TCCandidateProbeListener {param($Port,$ProcessId)$true}
        function script:Invoke-TCCandidateProbeHttp {
            param($Port,$User,$Secret,$Target,$TimeoutSeconds)
            [pscustomobject]@{Name=$Target.Name;Status=$(if($script:HttpFailure){'Failed'}elseif($Target.Name -eq 'ChatGPTWeb'){'UserVerificationRequired'}else{'Passed'});Code=$(if($Target.Name -eq 'ChatGPTWeb'){'BrowserChallenge'}else{'HttpsReached'});HttpStatus=$(if($Target.Name -eq 'ChatGPTWeb'){403}else{200});TlsVerified=(-not $script:HttpFailure);ObservedExitIPv4=$(if($Target.Trace){$script:ReplyIP}else{$null});DurationMs=1;TargetHost=([Uri]$Target.Url).Host;Source='AuthenticatedCandidateProxy'}
        }
    }
    $wg=Join-Path $package 'assets\wg.exe';$engine=Join-Path $package 'assets\sing-box.exe';$private=(& $wg genkey).Trim();$serverPrivate=(& $wg genkey).Trim();$pub=& $nodes {param($e,$k)Invoke-TCNative -FilePath $e -ArgumentList @('pubkey') -InputText $k} $wg $serverPrivate
    $conf=Join-Path $work 'client.conf';[IO.File]::WriteAllText($conf,("[Interface]`nPrivateKey = $private`nAddress = 10.99.0.2/24`n[Peer]`nPublicKey = $($pub.StandardOutput.Trim())`nEndpoint = 192.0.2.10:51820`nAllowedIPs = 0.0.0.0/0`n"),(New-Object Text.UTF8Encoding($false)))
    $node=Import-TCWireGuard -Root (Join-Path $work 'Product') -Path $conf -Name 'Candidate fixture' -EnginePath $engine -WgPath $wg -TradeProgramPaths @() -DirectDnsIPv4 '192.168.100.1';$manifest=ReadJson $node.manifestPath;$hash=(Get-FileHash -LiteralPath $manifest.CandidatePath).Hash
    WriteJson (Join-Path $work 'runtime.json') @{State='Running';ManifestPath=$node.manifestPath;CleanupError=$false}
    $active=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($active.Code -eq 'ActiveIdentity' -and $active.Status -eq 'Inconclusive' -and (& $probe {$script:Starts}) -eq 0) 'active identity is rejected before any probe process or request'
    $activeCopy=ReadJson $node.manifestPath;$activeConfig=ReadJson $manifest.CandidatePath;$activeConfig.endpoints[0].private_key=" `n"+$activeConfig.endpoints[0].private_key+" `n";$activeCopy.ClientPublicKey=$pub.StandardOutput.Trim();$activeCopy.CandidatePath=Join-Path $work 'active-copy.private.json';WriteJson $activeCopy.CandidatePath $activeConfig;$activeCopyPath=Join-Path $work 'active-copy.manifest.json';WriteJson $activeCopyPath $activeCopy
    WriteJson (Join-Path $work 'runtime.json') @{State='Running';ManifestPath=$activeCopyPath;CleanupError=$false}
    $equivalent=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($equivalent.Code -eq 'ActiveIdentity' -and (& $probe {$script:Starts}) -eq 0) 'decoded private identity comparison rejects formatting variants even when public metadata differs'
    [IO.File]::Delete((Join-Path $work 'runtime.json'))
    & $probe {$script:PortRetry=$true}
    $result=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace'
    Check ($result.Status -eq 'Inconclusive' -and $result.Code -eq 'ForwardingPassedPhysicalPathUnverified' -and $result.TransportPath -eq 'ExistingSystemRoute') 'verified candidate forwarding never proves physical-direct routing'
    Check ((& $probe {$script:Starts}) -eq 2 -and $result.CleanupComplete) 'bind/startup race retries and kills only owned fixture processes'
    Check (@($result.Checks|Where-Object {$_.Name -eq 'ChatGPTWeb' -and $_.Code -eq 'BrowserChallenge'}).Count -eq 1) 'browser challenge is separate from network forwarding failure'
    $configs=& $probe {$script:Configs};$cfg=$configs[-1]
    Check ($cfg.inbounds.Count -eq 1 -and $cfg.inbounds[0].type -eq 'mixed' -and $cfg.inbounds[0].listen -eq '127.0.0.1' -and -not $cfg.PSObject.Properties['experimental']) 'candidate has no TUN/controller or system proxy configuration'
    Check ($cfg.inbounds[0].users[0].password.Length -ge 32 -and $cfg.inbounds[0].users[0].password -cne (ReadJson $manifest.CandidatePath).experimental.clash_api.secret) 'ephemeral loopback credentials are new random values'
    Check ($cfg.dns.final -eq 'dns-hk' -and @($cfg.dns.servers|Where-Object {$_.tag -eq 'dns-hk' -and $_.detour -eq 'hk'}).Count -eq 1) 'target DNS explicitly traverses candidate WireGuard'
    Check (-not [IO.File]::Exists((Join-Path (Split-Path $result.EvidencePath -Parent) 'candidate.private.json')) -and [IO.File]::Exists($result.EvidencePath)) 'ephemeral plaintext deleted and only public evidence kept'
    Check (-not [IO.File]::ReadAllText($result.EvidencePath).Contains($private) -and -not [IO.File]::ReadAllText($result.EvidencePath).Contains($cfg.inbounds[0].users[0].password)) 'evidence contains no tunnel or loopback secret'
    & $probe {$script:ReplyIP='192.0.2.21'}
    $mismatch=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ServerVerifiedTlsTrace';Check ($mismatch.Status -eq 'Failed' -and $mismatch.Code -eq 'ExitMismatch') 'wrong exit cannot pass using current production exit'
    & $probe {$script:ReplyIP='192.0.2.20'}
    $unknown=Test-TCCandidateProbe -Root $work -NodeId $node.id -ExpectedExitIPv4 '192.0.2.20' -ExpectedExitSource 'ConfiguredAddress';Check ($unknown.Code -eq 'ExpectedExitUnverified' -and $unknown.Status -eq 'Inconclusive') 'configured expected address is not observed server evidence'
    & $probe {$script:HttpFailure=$true};$fail=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($fail.Code -eq 'CandidateForwardingFailed' -and $fail.Status -eq 'Failed') 'DNS/TCP/TLS failure is explicit failed forwarding'
    [IO.File]::AppendAllText($manifest.CandidatePath,' ');$drift=Test-TCCandidateProbe -Root $work -NodeId $node.id;Check ($drift.Code -eq 'ProbePreparationFailed' -and $drift.Status -eq 'Failed') 'candidate hash drift rejected before launch'
    [pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0;RealEngineRun=0;ActiveIdentityProtected=$true;SourceAwareExit=$true;SecretCleanup=$true;NativeScope='pubkey/check only'}
}finally{
    $full=[IO.Path]::GetFullPath($work);$parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^TC-CandidateProbe-[0-9a-f]{32}$'){throw 'Cleanup rejected.'};Remove-Item -LiteralPath $full -Recurse -Force
}
