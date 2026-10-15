#requires -Version 5.1
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'RuntimeObservability.psm1') -DisableNameChecking
function Get-TCProbeField {param($Object,[string]$Name,$Default=$null)if($null -ne $Object -and $Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}}
function Get-TCCandidateProbeNodes {param([string]$Root)Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking;@(Get-TCNodes -Root (Join-Path $Root 'Product'))}
function Read-TCCandidateProbeJson {param([string]$Path)$module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking;& $module {param($p)Assert-TCNoReparse $p;Read-TCJson $p} $Path}
function Get-TCProbeActiveIdentity {
    param([string]$Root)
    $runtimePath=Join-Path $Root 'runtime.json';$deployment=Join-Path $Root 'deployment.json';$rt=$null;$manifestPath=$null;$active=$false
    if([IO.File]::Exists($runtimePath)){$rt=Read-TCCandidateProbeJson $runtimePath;$state=[string](Get-TCProbeField $rt 'State' 'Unknown');$active=($state -notin @('Disconnected','Stopped','StoppedWithError') -or [bool](Get-TCProbeField $rt 'CleanupError' $false));$manifestPath=[string](Get-TCProbeField $rt 'ManifestPath' '')}
    if(-not $manifestPath -and [IO.File]::Exists($deployment)){$manifestPath=[string](Read-TCCandidateProbeJson $deployment).ManifestPath}
    if(-not $manifestPath){if($active){throw '无法核对活动身份。'};return $null}
    $m=Read-TCCandidateProbeJson $manifestPath
    if(-not $active){
        foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction Stop)){
            if($process.CommandLine -and $process.ExecutablePath -and [IO.Path]::GetFullPath([string]$process.ExecutablePath).Equals([IO.Path]::GetFullPath([string]$m.EnginePath),[StringComparison]::OrdinalIgnoreCase) -and [string]$process.CommandLine -like ('*'+[string]$m.CandidatePath+'*')){$active=$true;break}
        }
    }
    if(-not $active){return $null}
    $cfg=Read-TCCandidateProbeJson $m.CandidatePath;$keys=@($cfg.endpoints|Where-Object {$_.type -eq 'wireguard'}|ForEach-Object {[string]$_.private_key})
    [pscustomobject]@{PublicKey=[string](Get-TCProbeField $m 'ClientPublicKey' '');PrivateKeys=$keys}
}
function Test-TCProbeSamePrivateKey {
    param([string]$First,[string]$Second)
    $left=$null;$right=$null
    try{
        $left=[Convert]::FromBase64String($First);$right=[Convert]::FromBase64String($Second)
        if($left.Length -ne 32 -or $right.Length -ne 32){throw '候选身份编码无效。'}
        $difference=0;for($i=0;$i -lt 32;$i++){$difference=$difference -bor ($left[$i] -bxor $right[$i])};$difference -eq 0
    }catch{throw '无法安全比较候选与活动身份，未开始网络探测。'}
    finally{if($left){[Array]::Clear($left,0,$left.Length)};if($right){[Array]::Clear($right,0,$right.Length)}}
}
function Get-TCCandidateProbeEngine {
    $engine=Join-Path $PSScriptRoot 'assets\sing-box.exe';$receipt=Join-Path $PSScriptRoot 'package.sha256'
    $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
    & $nodeModule {param($p)Assert-TCNoReparse $p} $engine
    if(-not [IO.File]::Exists($engine) -or -not [IO.File]::Exists($receipt) -or (Get-Item -LiteralPath $receipt).Length -gt 1048576){throw '缺少完整安装包的引擎及校验清单。'}
    $rows=@([IO.File]::ReadAllLines($receipt)|Where-Object {$_ -match '^[a-fA-F0-9]{64}\|assets\\sing-box\.exe$'})
    if($rows.Count -ne 1 -or (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash -ine ($rows[0] -split '\|')[0]){throw '随包引擎完整性核验失败。'};$engine
}
function New-TCCandidateProbeConfig {
    param($Manifest,$Candidate,$StoredProbe,[int]$Port,[string]$User,[string]$Secret)
    $endpoints=@($Candidate.endpoints|Where-Object {$_.type -eq 'wireguard' -and $_.tag -eq 'hk'})
    if($endpoints.Count -ne 1 -or [bool](Get-TCProbeField $endpoints[0] 'system' $true) -or -not $endpoints[0].private_key){throw '候选缺少受支持的用户态 WireGuard 身份。'}
    $endpoint=$endpoints[0]|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $endpoint.PSObject.Properties.Remove('listen_port');$endpoint|Add-Member NoteProperty system $false -Force
    $endpoint|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='prefer_ipv4'}) -Force
    $outbounds=@();$detour=[string](Get-TCProbeField $endpoint 'detour' '')
    if($detour){
        if($detour -ne 'tc-transport'){throw '候选含未知外层传输，无法独立验证。'}
        $transport=@($Candidate.outbounds|Where-Object {$_.tag -eq $detour})
        if($transport.Count -ne 1 -or $transport[0].type -ne 'vless' -or -not $transport[0].tls.enabled -or -not $transport[0].tls.reality.enabled){throw '候选 TCP/Reality 结构无效。'}
        $transit=$transport[0]|ConvertTo-Json -Depth 30|ConvertFrom-Json;$transit|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='prefer_ipv4'}) -Force;$outbounds=@($transit)
    }
    $direct=[string](Get-TCProbeField $Manifest 'DirectDns' '1.1.1.1');$dnsIp=$null;if(-not [Net.IPAddress]::TryParse($direct,[ref]$dnsIp)){throw '候选外层 DNS 地址无效。'}
    $dns=[ordered]@{servers=@(@{type='udp';tag='dns-direct';server=$direct},@{type='udp';tag='dns-hk';server='1.1.1.1';detour='hk'});final='dns-hk';strategy='ipv4_only'}
    $outer=$(if($detour){[string]$outbounds[0].server}else{[string]$endpoint.peers[0].address});$outerIp=$null;$localOuter=([Net.IPAddress]::TryParse($outer,[ref]$outerIp) -and [Net.IPAddress]::IsLoopback($outerIp))
    # Binding a loopback-only fixture to a physical interface makes UDP replies
    # unreachable on Windows. Public endpoints retain interface autodetection.
    [pscustomobject][ordered]@{log=@{level='warn';timestamp=$true};dns=$dns;inbounds=@(@{type='mixed';tag='candidate-probe';listen='127.0.0.1';listen_port=$Port;users=@(@{username=$User;password=$Secret})});endpoints=@($endpoint);outbounds=$outbounds;route=@{final='hk';auto_detect_interface=(-not $localOuter);default_domain_resolver=@{server='dns-hk';strategy='prefer_ipv4'}}}
}
function Get-TCCandidateProbePort {
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    try{$listener.Start();[int]$listener.LocalEndpoint.Port}finally{$listener.Stop()}
}
function Test-TCCandidateProbeListener {
    param([int]$Port,[int]$ProcessId)
    if(-not ('TCNetTable' -as [type])){. (Join-Path $PSScriptRoot 'runtime\TradeChannel.Provider.ps1');Initialize-TCNetTable}
    @([TCNetTable]::ListenerOwners($Port)|Where-Object {$_ -eq $ProcessId}).Count -eq 1
}
function Get-TCCandidateProbeTargets {
    @([pscustomobject]@{Name='AddressHttps';Url='https://1.1.1.1/cdn-cgi/trace';Trace=$true},[pscustomobject]@{Name='DomainDnsHttps';Url='https://www.cloudflare.com/cdn-cgi/trace';Trace=$true},[pscustomobject]@{Name='ChatGPTWeb';Url='https://chatgpt.com/';Trace=$false})
}
function Get-TCProbeFailureCode {
    param([Exception]$Exception,[bool]$TimedOut)
    if($TimedOut){return 'ProbeTimeout'}
    $current=$Exception;$depth=0
    while($current -and $depth -lt 8){
        if($current -is [Security.Authentication.AuthenticationException]){return 'TlsFailed'}
        if($current -is [Net.WebException]){if($current.Status -in @([Net.WebExceptionStatus]::TrustFailure,[Net.WebExceptionStatus]::SecureChannelFailure)){return 'TlsFailed'};if($current.Status -eq [Net.WebExceptionStatus]::NameResolutionFailure){return 'DnsFailed'}}
        if($current -is [Net.Sockets.SocketException]){if($current.SocketErrorCode -in @([Net.Sockets.SocketError]::HostNotFound,[Net.Sockets.SocketError]::TryAgain,[Net.Sockets.SocketError]::NoData)){return 'DnsFailed'};return 'TcpConnectionFailed'}
        $current=$current.InnerException;$depth++
    };'DnsTcpOrTlsFailed'
}
function Invoke-TCCandidateProbeHttp {
    param([int]$Port,[string]$User,[string]$Secret,$Target,[int]$TimeoutSeconds)
    $uri=[Uri]$Target.Url;if($uri.Scheme -ne 'https'){throw '候选网络验证仅接受 HTTPS。'}
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object Net.Http.HttpClientHandler;$handler.UseProxy=$true;$handler.Proxy=New-Object Net.WebProxy('http://127.0.0.1:'+$Port);$handler.Proxy.Credentials=New-Object Net.NetworkCredential($User,$Secret);$handler.UseCookies=$false;$handler.AllowAutoRedirect=$false;$handler.SslProtocols=[Security.Authentication.SslProtocols]::Tls12
    $client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds);$client.DefaultRequestHeaders.UserAgent.ParseAdd('TradeChannel-Candidate-Diagnostics/0.10.0')
    $response=$null;$stream=$null;$cancel=New-Object Threading.CancellationTokenSource;$cancel.CancelAfter($TimeoutSeconds*1000);$body=''
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $response=$client.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$cancel.Token).GetAwaiter().GetResult()
        $status=[int]$response.StatusCode;$stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$buffer=New-Object byte[] 4096;$memory=New-Object IO.MemoryStream
        try{while($memory.Length -lt 65536){$read=$stream.ReadAsync($buffer,0,[Math]::Min($buffer.Length,65536-[int]$memory.Length),$cancel.Token).GetAwaiter().GetResult();if($read -eq 0){break};$memory.Write($buffer,0,$read)};$body=[Text.Encoding]::UTF8.GetString($memory.ToArray())}finally{$memory.Dispose();[Array]::Clear($buffer,0,$buffer.Length)}
        $challenge=($response.Headers.Contains('cf-mitigated') -or $body -match '(?i)cf-chl-|challenge-platform|just a moment');$ip=$null
        if([bool]$Target.Trace -and $status -eq 200 -and $body -match '(?m)^ip=([^\r\n]+)'){$address=$null;if([Net.IPAddress]::TryParse($Matches[1].Trim(),[ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){$ip=$address.ToString()}}
        $category=$(if($challenge){'BrowserChallenge'}elseif($status -eq 403){'HttpForbidden'}elseif($status -in @(401,407)){'AuthenticationRequired'}elseif($status -ge 300 -and $status -lt 400){'HttpRedirect'}elseif($status -ge 200 -and $status -lt 300){'HttpsReached'}else{'HttpError'})
        [pscustomobject]@{Name=$Target.Name;Status=$(if($category -eq 'HttpsReached'){'Passed'}elseif($category -in @('BrowserChallenge','HttpForbidden','AuthenticationRequired','HttpRedirect')){'UserVerificationRequired'}else{'Failed'});Code=$category;HttpStatus=$status;TlsVerified=$true;ObservedExitIPv4=$ip;DurationMs=[int]$watch.ElapsedMilliseconds;TargetHost=$uri.Host;Source='AuthenticatedCandidateProxy'}
    }catch{
        # Exception messages can echo proxy credentials or response payloads.
        [pscustomobject]@{Name=$Target.Name;Status='Failed';Code=(Get-TCProbeFailureCode $_.Exception $cancel.IsCancellationRequested);HttpStatus=$null;TlsVerified=$false;ObservedExitIPv4=$null;DurationMs=[int]$watch.ElapsedMilliseconds;TargetHost=$uri.Host;Source='AuthenticatedCandidateProxy'}
    }finally{if($stream){$stream.Dispose()};if($response){$response.Dispose()};$client.Dispose();$handler.Dispose();$cancel.Dispose();$body=$null;$Secret=$null}
}
function Test-TCCandidateProbe {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId,[string]$ExpectedExitIPv4,[string]$ExpectedExitSource,[ValidateRange(5,60)][int]$TimeoutSeconds=45)
    $ErrorActionPreference='Stop';$checks=New-Object 'Collections.Generic.List[object]';$process=$null;$runDirectory=$null;$config=$null;$candidate=$null;$candidateHash=$null;$active=$null;$secret=$null;$sessionLock=$null;$configHash=$null;$observed=$null;$status='Inconclusive';$code='NotTested';$cleanup=$true;$evidencePath=$null;$transport='Unknown';$normalizedNodeId=$null;$runId=[guid]::NewGuid().ToString('D');$watch=[Diagnostics.Stopwatch]::StartNew()
    if($ExpectedExitSource -and $ExpectedExitSource -notin @('ServerVerifiedTlsTrace','ConfiguredAddress','Unknown','Unavailable')){$ExpectedExitSource='Unknown'}
    try{
        $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
        $full=& $nodeModule {param($r)$p=Get-TCFullPath $r;Assert-TCNoReparse $p;$p} $Root
        $normalizedNodeId=& $nodeModule {param($id)ConvertTo-TCId $id} $NodeId
        $sessionLock=& $nodeModule {param($r)Open-TCNodeSessionLock (Join-Path $r 'Product')} $full
        $node=@(Get-TCCandidateProbeNodes $full|Where-Object {$_.id -eq $normalizedNodeId});if($node.Count -ne 1){throw '候选线路不存在。'}
        $manifest=Read-TCCandidateProbeJson $node[0].manifestPath;$candidate=Read-TCCandidateProbeJson $manifest.CandidatePath
        $candidateHash=(Get-FileHash -LiteralPath $manifest.CandidatePath -Algorithm SHA256).Hash
        if($candidateHash -cne $manifest.CandidateSHA256){throw '候选配置完整性变化。'}
        $stored=$null;$probePath=[string](Get-TCProbeField $manifest 'ProbePath' '')
        if($probePath){$stored=Read-TCCandidateProbeJson $probePath;if((Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash -cne (Get-TCProbeField $manifest 'ProbeSHA256' '')){throw '候选探测资产完整性变化。'}}
        $active=Get-TCProbeActiveIdentity $full
        $privateKeys=@($candidate.endpoints|Where-Object {$_.type -eq 'wireguard'}|ForEach-Object {[string]$_.private_key})
        $samePrivate=$false;if($active){foreach($candidateKey in $privateKeys){foreach($activeKey in @($active.PrivateKeys)){if(Test-TCProbeSamePrivateKey $candidateKey $activeKey){$samePrivate=$true}}}}
        if($active -and (($manifest.ClientPublicKey -and $manifest.ClientPublicKey -ceq $active.PublicKey) -or $samePrivate)){
            $code='ActiveIdentity';$checks.Add([pscustomobject]@{Name='IdentitySafety';Status='Failed';Code='ActiveIdentity';Message='该身份正在使用，独立探测会影响现有 Peer。请使用当前连接诊断或新增独立诊断身份。'});return [pscustomobject]@{Status='Inconclusive';Code=$code;NodeId=$normalizedNodeId;Checks=$checks.ToArray();ObservedExitIPv4=$null;ExpectedExitSource=$ExpectedExitSource;TransportPath='NotStarted';NetworkChanged=$false;ConfigHash=$candidateHash;CleanupComplete=$true;EvidencePath=$null}
        }
        if($ExpectedExitIPv4){$ip=$null;if(-not [Net.IPAddress]::TryParse($ExpectedExitIPv4,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){$ExpectedExitIPv4=$null;throw '预期出口地址无效。'};$ExpectedExitIPv4=$ip.ToString()}
        $engine=Get-TCCandidateProbeEngine;$probes=Join-Path $full 'probes';$null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $probes;$runDirectory=Join-Path $probes $runId;$null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $runDirectory
        $configPath=Join-Path $runDirectory 'candidate.private.json';$user='candidate-'+[guid]::NewGuid().ToString('N');$random=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($random);$secret=[Convert]::ToBase64String($random)}finally{$rng.Dispose();[Array]::Clear($random,0,$random.Length)}
        $ready=$false
        for($attempt=0;$attempt -lt 3 -and $watch.Elapsed.TotalSeconds -lt ($TimeoutSeconds-3);$attempt++){
            $port=Get-TCCandidateProbePort;$config=New-TCCandidateProbeConfig $manifest $candidate $stored $port $user $secret
            $checkBudget=[int][Math]::Max(1000,[Math]::Min(5000,($TimeoutSeconds-$watch.Elapsed.TotalSeconds)*1000))
            $null=& $nodeModule {param($p,$c,$e,$budget)Write-TCAtomicJson $p $c -NoBom;Test-TCCheckedConfiguration $e $p -TimeoutMilliseconds $budget} $configPath $config $engine $checkBudget
            $configHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            $transport=$(if(@($config.endpoints|Where-Object {(Get-TCProbeField $_ 'detour' '') -eq 'tc-transport'}).Count){'WireGuardOverVlessReality'}else{'WireGuardUdp'})
            $process=Start-TCBoundedEngineProcess -Root $runDirectory -Executable $engine -Arguments ('run -c "'+$configPath+'"') -SessionId ('candidate-'+$attempt) -MaxBytes 262144
            $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Min(6,$TimeoutSeconds-$watch.Elapsed.TotalSeconds))
            do{if($process.HasExited){break};if(Test-TCCandidateProbeListener $port $process.Id){$ready=$true;break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
            if($ready){break};if(-not $process.HasExited){$process.Kill();$null=$process.WaitForExit(5000)};$process.Dispose();$process=$null
        }
        if(-not $ready){throw '候选引擎未就绪。'}
        $checks.Add([pscustomobject]@{Name='IsolatedEngine';Status='Passed';Code='AuthenticatedLoopback';Source='OwnedProcessListener';NetworkChanged=$false})
        foreach($target in @(Get-TCCandidateProbeTargets)){
            $remaining=[Math]::Floor($TimeoutSeconds-$watch.Elapsed.TotalSeconds)
            if($remaining -lt 2){$checks.Add([pscustomobject]@{Name=$target.Name;Status='NotTested';Code='TimeBudgetExhausted'});continue}
            $row=Invoke-TCCandidateProbeHttp $port $user $secret $target ([int][Math]::Min(12,$remaining));$checks.Add($row)
            if($target.Trace -and $row.TlsVerified -and $row.ObservedExitIPv4){if(-not $observed){$observed=$row.ObservedExitIPv4}elseif($observed -ne $row.ObservedExitIPv4){$checks.Add([pscustomobject]@{Name='ExitConsistency';Status='Inconclusive';Code='ExitPoolChanged'})}}
        }
        $required=@($checks|Where-Object {$_.Name -in @('AddressHttps','DomainDnsHttps')})
        if(@($required|Where-Object {$_.Status -eq 'Failed'}).Count){$status='Failed';$code='CandidateForwardingFailed'}
        elseif($required.Count -ne 2 -or @($required|Where-Object {$_.Status -ne 'Passed'}).Count){$status='Inconclusive';$code='CandidateForwardingUnverified'}
        elseif(-not $observed -or -not $ExpectedExitIPv4 -or $ExpectedExitSource -ne 'ServerVerifiedTlsTrace'){$status='Inconclusive';$code='ExpectedExitUnverified'}
        elseif($observed -ne $ExpectedExitIPv4){$status='Failed';$code='ExitMismatch';$checks.Add([pscustomobject]@{Name='ExitBinding';Status='Failed';Code='ExitMismatch';ObservedExitIPv4=$observed;ExpectedExitIPv4=$ExpectedExitIPv4;Source=$ExpectedExitSource})}
        else{$status='Inconclusive';$code='ForwardingPassedPhysicalPathUnverified';$checks.Add([pscustomobject]@{Name='CandidateForwarding';Status='Passed';Code='VerifiedHttpsAndExit';Source='CandidateTlsTrace'});$checks.Add([pscustomobject]@{Name='PhysicalOuterPath';Status='Inconclusive';Code='ExistingSystemRoute';Message='候选转发通过；外层沿系统当前路由，尚未证明从本地物理网络直接接入。'})}
    }catch{if($code -eq 'NotTested'){$code='ProbePreparationFailed'};$status='Failed';$checks.Add([pscustomobject]@{Name='Probe';Status='Failed';Code=$code;Message='候选验证未完成，请检查候选完整性、引擎和授权；原始异常未输出以保护秘密。'})}
    finally{
        if($process){try{if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit(5000)){throw 'Owned probe stop timed out'}};$process.Dispose()}catch{$cleanup=$false;$status='Failed';$code='ProbeCleanupFailed'}}
        if($runDirectory){
            try{$module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking;& $module {param($p)Assert-TCNoReparse $p} $runDirectory;$plain=Join-Path $runDirectory 'candidate.private.json';if([IO.File]::Exists($plain)){[IO.File]::Delete($plain)}
                foreach($log in @(Get-ChildItem -LiteralPath (Join-Path $runDirectory 'logs') -File -ErrorAction SilentlyContinue)){& $module {param($p)Assert-TCNoReparse $p} $log.FullName;if($log.Name -match '^bounded-channel-candidate-[0-2]\.log(?:\.[12])?$'){[IO.File]::Delete($log.FullName)}}
            }catch{$cleanup=$false;$status='Failed';$code='ProbeCleanupFailed'}
        }
        if($sessionLock){$sessionLock.Dispose()};$secret=$null;$candidate=$null;$config=$null;$active=$null;$privateKeys=$null
    }
    $result=[pscustomobject]@{Status=$status;Code=$code;NodeId=$normalizedNodeId;Checks=$checks.ToArray();ObservedExitIPv4=$observed;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;Transport=$transport;TransportPath='ExistingSystemRoute';PathStatus='Inconclusive';NetworkChanged=$false;ConfigHash=$configHash;CandidateHash=$candidateHash;RunId=$runId;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');DurationMs=[int]$watch.ElapsedMilliseconds;CleanupComplete=$cleanup;EvidencePath=$null}
    if($runDirectory){try{$evidencePath=Join-Path $runDirectory 'result.json';$result.EvidencePath=$evidencePath;$module=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking;& $module {param($p,$r)Write-TCAtomicJson $p $r -NewOnly} $evidencePath $result}catch{$result|Add-Member NoteProperty EvidenceWarning '脱敏证据未能保存。'}}
    $result
}
Export-ModuleMember -Function Test-TCCandidateProbe
