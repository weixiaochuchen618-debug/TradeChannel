#requires -Version 5.1
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'RuntimeObservability.psm1') -DisableNameChecking
$script:TCProbePathModule=Import-Module (Join-Path $PSScriptRoot 'ProbePath.psm1') -PassThru -DisableNameChecking
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
function Test-TCCandidateEngineBinding {param($Manifest,[string]$PackageEngine,[string]$EngineSHA256,$NodeModule)
    try{
        $path=[string](Get-TCProbeField $Manifest 'EnginePath' '')
        if(-not [IO.Path]::IsPathRooted($path) -or -not [IO.File]::Exists($path)){return $false}
        & $NodeModule {param($p)Assert-TCNoReparse $p} $path
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $recorded=[string](Get-TCProbeField $Manifest 'EngineSHA256' '')
        if($Manifest.PSObject.Properties['EngineSHA256'] -and ($recorded -notmatch '^[A-Fa-f0-9]{64}$' -or $recorded -ine $actual)){return $false}
        $packageActual=if([IO.Path]::GetFullPath($path).Equals([IO.Path]::GetFullPath($PackageEngine),[StringComparison]::OrdinalIgnoreCase)){$actual}else{(Get-FileHash -LiteralPath $PackageEngine -Algorithm SHA256).Hash}
        [bool]($actual -ieq $EngineSHA256 -and $packageActual -ieq $EngineSHA256)
    }catch{$false}
}
function New-TCCandidateProbeConfig {
    param($Manifest,$Candidate,$StoredProbe,[int]$Port,[string]$User,[string]$Secret)
    $endpoints=@($Candidate.endpoints|Where-Object {$_.type -eq 'wireguard' -and $_.tag -eq 'hk'})
    if($endpoints.Count -ne 1 -or [bool](Get-TCProbeField $endpoints[0] 'system' $true) -or -not $endpoints[0].private_key){throw '候选缺少受支持的用户态 WireGuard 身份。'}
    $endpoint=$endpoints[0]|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $endpoint.PSObject.Properties.Remove('listen_port');$endpoint|Add-Member NoteProperty system $false -Force
    $outbounds=@();$detour=[string](Get-TCProbeField $endpoint 'detour' '')
    if($detour){
        if($detour -ne 'tc-transport'){throw '候选含未知外层传输，无法独立验证。'}
        $transport=@($Candidate.outbounds|Where-Object {$_.tag -eq $detour})
        if($transport.Count -ne 1 -or $transport[0].type -ne 'vless' -or -not $transport[0].tls.enabled -or -not $transport[0].tls.reality.enabled){throw '候选 TCP/Reality 结构无效。'}
        $transit=$transport[0]|ConvertTo-Json -Depth 30|ConvertFrom-Json
        if((Get-TCProbeField $transit 'detour' '') -or (Get-TCProbeField $transit 'transport')){throw '候选 TCP 外层存在不支持的 detour 或传输。'}
        if(-not (Get-TCProbeField $transit 'domain_resolver')){$transit|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'})}
        $outbounds=@($transit)
        # Detoured dial fields are ignored by sing-box. Remove them from the
        # inner endpoint; preserve the real outer transport's saved binding.
        foreach($field in @('bind_interface','inet4_bind_address','inet6_bind_address','domain_resolver')){$endpoint.PSObject.Properties.Remove($field)}
    }elseif(-not (Get-TCProbeField $endpoint 'domain_resolver')){
        $endpoint|Add-Member NoteProperty domain_resolver ([pscustomobject]@{server='dns-direct';strategy='ipv4_only'})
    }
    $direct=[string](Get-TCProbeField $Manifest 'DirectDns' '1.1.1.1');$dnsIp=$null;if(-not [Net.IPAddress]::TryParse($direct,[ref]$dnsIp)){throw '候选外层 DNS 地址无效。'}
    $savedDns=@((Get-TCProbeField (Get-TCProbeField $Candidate 'dns') 'servers' @())|Where-Object {(Get-TCProbeField $_ 'tag' '') -eq 'dns-direct'})
    $bootstrap=if($savedDns.Count -eq 1){$savedDns[0]|ConvertTo-Json -Depth 20|ConvertFrom-Json}else{[pscustomobject]@{type='udp';tag='dns-direct';server=$direct}}
    if((Get-TCProbeField $bootstrap 'detour' '') -or $bootstrap.type -ne 'udp'){throw 'bootstrap DNS 必须是明确外层，不能使用 detour。'}
    $dns=[ordered]@{servers=@($bootstrap,@{type='udp';tag='dns-hk';server='1.1.1.1';detour='hk'});final='dns-hk';strategy='ipv4_only'}
    $outer=$(if($detour){[string]$outbounds[0].server}else{[string]$endpoint.peers[0].address});$outerIp=$null;$localOuter=([Net.IPAddress]::TryParse($outer,[ref]$outerIp) -and [Net.IPAddress]::IsLoopback($outerIp))
    # Binding a loopback-only fixture to a physical interface makes UDP replies
    # unreachable on Windows. Public endpoints retain interface autodetection.
    $realOuter=if($detour){$outbounds[0]}else{$endpoint};$explicit=[bool](Get-TCProbeField $realOuter 'bind_interface' '')
    [pscustomobject][ordered]@{log=@{level='warn';timestamp=$true};dns=$dns;inbounds=@(@{type='mixed';tag='candidate-probe';listen='127.0.0.1';listen_port=$Port;users=@(@{username=$User;password=$Secret})});endpoints=@($endpoint);outbounds=$outbounds;route=@{final='hk';auto_detect_interface=(-not $localOuter -and -not $explicit);default_domain_resolver=@{server='dns-hk';strategy='ipv4_only'}}}
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
function Get-TCCandidateProbeProfile {param([string]$Root,[string]$NodeId,[string]$ProfileId)
    Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
    Get-TCLineProfile -Root $Root -Id $NodeId -ProfileId $ProfileId
}
function Get-TCCandidateNetworkContext {param($Binding) Get-TCProbeNetworkContext -Binding $Binding }
function Start-TCCandidateSocketWatch {param([int]$ProcessId,$Binding,[string]$TraceIdentity,[string]$RunDirectory)
    & $script:TCProbePathModule {param($id,$b,$trace,$dir)Start-TCProbeSocketObservation $id $b $trace $dir} $ProcessId $Binding $TraceIdentity $RunDirectory
}
function Stop-TCCandidateSocketWatch {param($Observer)
    & $script:TCProbePathModule {param($o)Stop-TCProbeSocketObservation $o} $Observer
}
function Stop-TCCandidateOwnedTrace {param([string]$Identity)
    & $script:TCProbePathModule {param($id)Stop-TCProbeOwnedTrace $id} $Identity
}
function Get-TCCandidatePathAssessment {param($Candidate,$Manifest,$Profile,$Contexts,$Observation,[bool]$Owned)
    & $script:TCProbePathModule {param($c,$m,$p,$ctx,$o,$owned)Get-TCProbePathAssessment $c $m $p $ctx $o $owned} $Candidate $Manifest $Profile $Contexts $Observation $Owned
}
function Get-TCCandidateProbeMetrics {param($Samples)
    $required=@($Samples|Where-Object {$_.Required});$attempted=@($required|Where-Object {$_.Attempted})
    $durations=@($attempted|ForEach-Object {[int]$_.DurationMs}|Sort-Object);$median=$null;$p95=$null;$spread=$null
    if($durations.Count){$n=$durations.Count;$median=if($n%2){$durations[[int][Math]::Floor($n/2)]}else{($durations[$n/2-1]+$durations[$n/2])/2.0};$p95=$durations[[int][Math]::Ceiling($n*0.95)-1];$spread=$durations[-1]-$durations[0]}
    [pscustomobject]@{SampleBudget=6;ApplicationBudget=1;MaxRequests=7;MaxResponseBytesPerRequest=65536;MaxResponseBytes=458752;Concurrency=1;RequestRetries=0;Planned=$required.Count;Attempted=$attempted.Count;Passed=@($required|Where-Object {$_.Status -eq 'Passed'}).Count;Failed=@($required|Where-Object {$_.Status -eq 'Failed'}).Count;Unverified=@($required|Where-Object {$_.Status -notin @('Passed','Failed','NotTested')}).Count;NotTested=@($required|Where-Object {$_.Status -eq 'NotTested'}).Count;MedianResponseMs=$median;P95ResponseMs=$p95;ResponseRangeMs=$spread;DurationPopulation='AllAttemptedIncludingFailures';Measurement='HTTPS headers and bounded body through a new authenticated HttpClient per request';ConnectionReuse='NotMeasured';ColdWarmComparison='NotSupported';PerformanceRanked=$false;PacketLossMeasured=$false;StabilityClaim=$false}
}
function Assert-TCCandidatePreviousCleanup {param([string]$Root,$NodeModule)
    $dir=Join-Path $Root 'probes'
    if(-not [IO.Directory]::Exists($dir)){return}
    & $NodeModule {param($p)Assert-TCNoReparse $p} $dir
    foreach($run in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop)){
        if($run.Name -notmatch '^[a-fA-F0-9-]{36}$'){continue}
        $marker=Join-Path $run.FullName 'ownership.json'
        if([IO.File]::Exists($marker)){
            $owner=Read-TCCandidateProbeJson $marker
            $trace=[string](Get-TCProbeField $owner 'TraceGuid' '')
            if($trace -and (Get-TCProbeField $owner 'TraceState' '') -ne 'Stopped'){
                if((Get-TCProbeField $owner 'RunId' '') -cne $run.Name -or (Get-TCProbeField $owner 'TraceName' '') -cne ('TCProbe-UDP-'+([guid]$trace).ToString('N'))){throw 'Trace receipt ownership mismatch'}
                Stop-TCCandidateOwnedTrace $trace
                $owner.TraceState='Stopped'
                & $NodeModule {param($p,$v)Write-TCAtomicJson $p $v} $marker $owner
                # The trace was ours; an orphan engine still requires independent
                # identity recovery. Trace cleanup never authorizes another engine.
                throw 'Previous owned trace recovered; probe ownership unresolved'
            }
            if((Get-TCProbeField $owner 'State' '') -ne 'Stopped'){throw 'Previous owned probe needs recovery'}
        }else{
            if([IO.File]::Exists((Join-Path $run.FullName 'candidate.private.json'))){throw 'Legacy probe ownership unknown'}
            $result=Join-Path $run.FullName 'result.json'
            if([IO.File]::Exists($result) -and -not [bool](Get-TCProbeField (Read-TCCandidateProbeJson $result) 'CleanupComplete' $false)){throw 'Legacy probe cleanup incomplete'}
        }
    }
}
function Set-TCCandidateOwnership {param($NodeModule,[string]$RunDirectory,[string]$State,$Process,$Metadata)
    $owner=[pscustomobject]@{SchemaVersion=1;State=$State;RunId=$Metadata.RunId;NodeId=$Metadata.NodeId;CandidateHash=$Metadata.CandidateHash;ConfigHash=$Metadata.ConfigHash;EnginePath=$Metadata.EnginePath;ProcessId=$(if($Process){$Process.Id}else{$Metadata.ProcessId});ProcessStartedAt=$(if($Process){$Process.StartTime.ToUniversalTime().ToString('o')}else{$Metadata.ProcessStartedAt});TraceGuid=(Get-TCProbeField $Metadata 'TraceGuid');TraceName=(Get-TCProbeField $Metadata 'TraceName');TraceState=(Get-TCProbeField $Metadata 'TraceState' 'NotStarted');UpdatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    $Metadata.ProcessId=$owner.ProcessId;$Metadata.ProcessStartedAt=$owner.ProcessStartedAt
    & $NodeModule {param($p,$v)Write-TCAtomicJson $p $v} (Join-Path $RunDirectory 'ownership.json') $owner
}
function Resolve-TCCandidateCancellation {param([string]$Root,[string]$Path,$NodeModule)
    if(-not $Path){return $null}
    if($Path -notmatch '^[A-Za-z]:[\\/]'){throw 'Cancellation path must be an absolute local path'}
    $full=& $NodeModule {param($p)Get-TCFullPath $p} $Path
    $prefix=[IO.Path]::GetFullPath((Join-Path $Root 'deployments\runs')).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Cancellation path outside this deployment root'}
    $relative=$full.Substring($prefix.Length)
    if($relative -notmatch '^(?<run>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\probe-cancel-(?<attempt>[0-9a-fA-F]{32})\.json$'){throw 'Cancellation path shape invalid'}
    $run=[guid]::ParseExact($Matches.run,'D');$attempt=[guid]::ParseExact($Matches.attempt,'N')
    if($run -eq [guid]::Empty -or $attempt -eq [guid]::Empty){throw 'Cancellation identity is empty'}
    & $NodeModule {param($p)Assert-TCNoReparse $p} $full
    [pscustomobject]@{Path=$full;AttemptId=$attempt.ToString('N')}
}
function Test-TCCandidateCancellation {param($Cancellation,$NodeModule)
    if(-not $Cancellation){return $false}
    # Recheck every ancestor each time; a valid path at entry is not a waiver
    # for a junction/symlink inserted while an HTTP request is in flight.
    try{& $NodeModule {param($p)Assert-TCNoReparse $p} $Cancellation.Path}
    catch{$errorRecord=New-Object InvalidOperationException('Cancellation path is no longer safe');$errorRecord.Data['TCProbeCancellationPathInvalid']=$true;throw $errorRecord}
    if(-not [IO.File]::Exists($Cancellation.Path)){return $false}
    $raw=$null;$marker=$null
    try{
        $raw=& $NodeModule {param($p)Read-TCBoundedText $p -Limit 4096} $Cancellation.Path
        $marker=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
        $attempt=[guid]::Empty
        $matched=([guid]::TryParse([string](Get-TCProbeField $marker 'AttemptId' ''),[ref]$attempt) -and $attempt.ToString('N') -ceq $Cancellation.AttemptId)
    }catch{
        # A stale, incomplete or malformed marker is not a cancellation request.
        # Flow should publish atomically; the next boundary retries a partial write.
        $matched=$false
    }finally{$raw=$null;$marker=$null}
    try{& $NodeModule {param($p)Assert-TCNoReparse $p} $Cancellation.Path}
    catch{$errorRecord=New-Object InvalidOperationException('Cancellation path is no longer safe');$errorRecord.Data['TCProbeCancellationPathInvalid']=$true;throw $errorRecord}
    [bool]$matched
}
function Assert-TCCandidateNotCancelled {param($Cancellation,$NodeModule)
    if(Test-TCCandidateCancellation $Cancellation $NodeModule){
        $errorRecord=New-Object OperationCanceledException('Candidate probe cancellation requested')
        $errorRecord.Data['TCProbeCancellationRequested']=$true;throw $errorRecord
    }
}
function Test-TCCandidateProbe {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$NodeId,[string]$ExpectedExitIPv4,[string]$ExpectedExitSource,[ValidateRange(5,60)][int]$TimeoutSeconds=45,[ValidateSet('Udp','Tcp')][string]$ProfileId,[string]$CancellationPath)
    $ErrorActionPreference='Stop'
    $checks=New-Object 'Collections.Generic.List[object]';$samples=New-Object 'Collections.Generic.List[object]';$contexts=New-Object 'Collections.Generic.List[object]'
    $process=$null;$observer=$null;$observation=$null;$runDirectory=$null;$config=$null;$candidate=$null;$candidateHash=$null;$manifestHash=$null;$manifestPath=$null;$manifest=$null;$profile=$null;$nodeModule=$null
    $active=$null;$secret=$null;$sessionLock=$null;$configHash=$null;$engineSHA256=$null;$observed=$null;$status='Inconclusive';$code='NotTested';$cleanup=$true;$transport='Unknown';$normalizedNodeId=$null;$owned=$false;$forward=$false;$exitVerified=$false;$hashesStable=$false;$ready=$false;$launchPending=$false;$ownershipMetadata=$null;$cancellation=$null;$cancelled=$false
    $pathEvidence=[pscustomobject]@{Kind='Unknown';Verified=$false;EligibleForRecommendation=$false;NetworkFingerprint=$null;Binding=$null;Reason='NotStarted'}
    $runId=[guid]::NewGuid().ToString('D');$watch=[Diagnostics.Stopwatch]::StartNew()
    if($ExpectedExitSource -and $ExpectedExitSource -notin @('ServerVerifiedTlsTrace','ConfiguredAddress','Unknown','Unavailable')){$ExpectedExitSource='Unknown'}
    try{
        $nodeModule=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
        $full=& $nodeModule {param($r)$p=Get-TCFullPath $r;Assert-TCNoReparse $p;$p} $Root
        $normalizedNodeId=& $nodeModule {param($id)ConvertTo-TCId $id} $NodeId
        try{$cancellation=Resolve-TCCandidateCancellation $full $CancellationPath $nodeModule}catch{$code='CancellationPathInvalid';throw}
        Assert-TCCandidateNotCancelled $cancellation $nodeModule
        $sessionLock=& $nodeModule {param($r)Open-TCNodeSessionLock (Join-Path $r 'Product')} $full
        Assert-TCCandidateNotCancelled $cancellation $nodeModule
        try{Assert-TCCandidatePreviousCleanup $full $nodeModule}catch{$code='ProbeCleanupFailed';$cleanup=$false;throw}
        if($ProfileId){$profile=Get-TCCandidateProbeProfile $full $normalizedNodeId $ProfileId;if(-not $profile -or [string]$profile.Id -cne $ProfileId){throw 'Stored profile missing or mismatched'}}
        $node=@(Get-TCCandidateProbeNodes $full|Where-Object {$_.id -eq $normalizedNodeId});if($node.Count -ne 1){throw 'Candidate missing'}
        $manifestPath=if($profile){$profile.ManifestPath}else{$node[0].manifestPath}
        $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        if($profile -and $manifestHash -ine $profile.ManifestSHA256){throw 'Profile manifest changed'}
        $manifest=Read-TCCandidateProbeJson $manifestPath;$candidate=Read-TCCandidateProbeJson $manifest.CandidatePath
        $candidateHash=(Get-FileHash -LiteralPath $manifest.CandidatePath -Algorithm SHA256).Hash
        if($candidateHash -cne $manifest.CandidateSHA256 -or ($profile -and $candidateHash -ine $profile.CandidateSHA256)){throw 'Candidate changed'}
        $stored=$null;$probePath=[string](Get-TCProbeField $manifest 'ProbePath' '')
        if($probePath){$stored=Read-TCCandidateProbeJson $probePath;if((Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash -cne (Get-TCProbeField $manifest 'ProbeSHA256' '')){throw 'Probe asset changed'}}
        $active=Get-TCProbeActiveIdentity $full
        $privateKeys=@($candidate.endpoints|Where-Object {$_.type -eq 'wireguard'}|ForEach-Object {[string]$_.private_key})
        $samePrivate=$false;if($active){foreach($candidateKey in $privateKeys){foreach($activeKey in @($active.PrivateKeys)){if(Test-TCProbeSamePrivateKey $candidateKey $activeKey){$samePrivate=$true}}}}
        if($active -and (($manifest.ClientPublicKey -and $manifest.ClientPublicKey -ceq $active.PublicKey) -or $samePrivate)){
            $code='ActiveIdentity';$checks.Add([pscustomobject]@{Name='IdentitySafety';Status='Failed';Code='ActiveIdentity';Message='该身份正在使用，独立探测会影响现有 Peer。'});throw 'Active identity'
        }
        if($ExpectedExitIPv4){$ip=$null;if(-not [Net.IPAddress]::TryParse($ExpectedExitIPv4,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){$ExpectedExitIPv4=$null;throw 'Expected exit invalid'};$ExpectedExitIPv4=$ip.ToString()}
        $contexts.Add((Get-TCCandidateNetworkContext (Get-TCProbeField $manifest 'ProbeBinding')))
        $engine=Get-TCCandidateProbeEngine;$engineSHA256=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash
        if(-not (Test-TCCandidateEngineBinding $manifest $engine $engineSHA256 $nodeModule)){$code='EngineMismatch';$pathEvidence.Reason='EngineMismatch';throw 'Engine binding mismatch'}
        $probes=Join-Path $full 'probes';$null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $probes;$runDirectory=Join-Path $probes $runId;$null=& $nodeModule {param($p)New-TCPrivateDirectory $p} $runDirectory
        $ownershipMetadata=[pscustomobject]@{RunId=$runId;NodeId=$normalizedNodeId;CandidateHash=$candidateHash;ConfigHash=$null;EnginePath=$engine;ProcessId=$null;ProcessStartedAt=$null;TraceGuid=$null;TraceName=$null;TraceState='NotStarted'}
        $configPath=Join-Path $runDirectory 'candidate.private.json';$user='candidate-'+[guid]::NewGuid().ToString('N');$random=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($random);$secret=[Convert]::ToBase64String($random)}finally{$rng.Dispose();[Array]::Clear($random,0,$random.Length)}
        for($attempt=0;$attempt -lt 3 -and $watch.Elapsed.TotalSeconds -lt ($TimeoutSeconds-3);$attempt++){
            Assert-TCCandidateNotCancelled $cancellation $nodeModule
            if(-not (Test-TCCandidateEngineBinding $manifest $engine $engineSHA256 $nodeModule)){$code='EngineMismatch';$pathEvidence.Reason='EngineMismatch';throw 'Engine binding changed before launch'}
            $port=Get-TCCandidateProbePort;$config=New-TCCandidateProbeConfig $manifest $candidate $stored $port $user $secret
            $checkBudget=[int][Math]::Max(1000,[Math]::Min(5000,($TimeoutSeconds-$watch.Elapsed.TotalSeconds)*1000))
            $null=& $nodeModule {param($p,$c,$e,$budget)Write-TCAtomicJson $p $c -NoBom;Test-TCCheckedConfiguration $e $p -TimeoutMilliseconds $budget} $configPath $config $engine $checkBudget
            Assert-TCCandidateNotCancelled $cancellation $nodeModule
            $configHash=(Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            $transport=$(if(@($config.endpoints|Where-Object {(Get-TCProbeField $_ 'detour' '') -eq 'tc-transport'}).Count){'WireGuardOverVlessReality'}else{'WireGuardUdp'})
            if(($ProfileId -eq 'Tcp' -and $transport -ne 'WireGuardOverVlessReality') -or ($ProfileId -eq 'Udp' -and $transport -ne 'WireGuardUdp')){throw 'Profile transport mismatch'}
            $ownershipMetadata.ConfigHash=$configHash;$ownershipMetadata.ProcessId=$null;$ownershipMetadata.ProcessStartedAt=$null
            Set-TCCandidateOwnership $nodeModule $runDirectory 'Starting' $null $ownershipMetadata
            $launchPending=$true
            $process=Start-TCBoundedEngineProcess -Root $runDirectory -Executable $engine -Arguments ('run -c "'+$configPath+'"') -SessionId ('candidate-'+$attempt) -MaxBytes 262144
            $launchPending=$false
            Set-TCCandidateOwnership $nodeModule $runDirectory 'Running' $process $ownershipMetadata
            $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Min(6,$TimeoutSeconds-$watch.Elapsed.TotalSeconds))
            do{Assert-TCCandidateNotCancelled $cancellation $nodeModule;if($process.HasExited){break};if(Test-TCCandidateProbeListener $port $process.Id){$ready=$true;break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
            if($ready){break}
            if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit(5000)){$code='ProbeCleanupFailed';$cleanup=$false;throw 'Owned probe stop timed out'}}
            $process.Dispose();$process=$null
        }
        if(-not $ready){throw 'Candidate engine unavailable'}
        Assert-TCCandidateNotCancelled $cancellation $nodeModule
        $checks.Add([pscustomobject]@{Name='IsolatedEngine';Status='Passed';Code='AuthenticatedLoopback';Source='OwnedProcessListener';NetworkChanged=$false})
        $binding=Get-TCProbeField $manifest 'ProbeBinding';$outerIp=$null
        if($binding -and $binding.Protocol -eq 'Udp' -and [Net.IPAddress]::TryParse([string]$binding.RemoteAddress,[ref]$outerIp) -and $outerIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork){
            $traceGuid=[guid]::NewGuid();$ownershipMetadata.TraceGuid=$traceGuid.ToString('D');$ownershipMetadata.TraceName='TCProbe-UDP-'+$traceGuid.ToString('N');$ownershipMetadata.TraceState='Starting'
            Set-TCCandidateOwnership $nodeModule $runDirectory 'Running' $process $ownershipMetadata
        }
        try{$observer=Start-TCCandidateSocketWatch $process.Id $binding $ownershipMetadata.TraceGuid $runDirectory}catch{$checks.Add([pscustomobject]@{Name='SocketObservation';Status='Inconclusive';Code='OwnedSocketObservationUnavailable'})}
        Assert-TCCandidateNotCancelled $cancellation $nodeModule
        $targets=@(Get-TCCandidateProbeTargets);$requiredTargets=@($targets|Where-Object {$_.Trace -and $_.Name -in @('AddressHttps','DomainDnsHttps')})
        if($requiredTargets.Count -ne 2){throw 'Fixed target contract changed'}
        $schedule=@(for($round=1;$round -le 3;$round++){foreach($target in $requiredTargets){[pscustomobject]@{Target=$target;Round=$round;Required=$true}}})
        $application=@($targets|Where-Object {$_.Name -eq 'ChatGPTWeb' -and -not $_.Trace})
        if($application.Count -eq 1){$schedule+=,[pscustomobject]@{Target=$application[0];Round=1;Required=$false}}
        foreach($item in $schedule){
            Assert-TCCandidateNotCancelled $cancellation $nodeModule
            $remaining=[Math]::Floor($TimeoutSeconds-$watch.Elapsed.TotalSeconds);$budget=[int][Math]::Min(6,$remaining);$target=$item.Target
            $row=if($budget -lt 1){[pscustomobject]@{Name=$target.Name;Status='NotTested';Code='TimeBudgetExhausted';HttpStatus=$null;TlsVerified=$false;ObservedExitIPv4=$null;DurationMs=0;TargetHost=([Uri]$target.Url).Host;Source='NotAttempted'}}
                elseif($process.HasExited){[pscustomobject]@{Name=$target.Name;Status='Failed';Code='OwnedProcessExited';HttpStatus=$null;TlsVerified=$false;ObservedExitIPv4=$null;DurationMs=0;TargetHost=([Uri]$target.Url).Host;Source='NotAttempted'}}
                else{Invoke-TCCandidateProbeHttp $port $user $secret $target $budget}
            foreach($pair in @(@{n='SampleIndex';v=($samples.Count+1)},@{n='Round';v=$item.Round},@{n='Required';v=$item.Required},@{n='Attempted';v=($row.Source -ne 'NotAttempted')},@{n='RequestBudgetSeconds';v=[Math]::Max(0,$budget)},@{n='Phase';v=$(if($item.Round -eq 1){'FirstTargetRequest'}else{'RepeatedNewHttpClient'})})){$row|Add-Member NoteProperty $pair.n $pair.v -Force}
            $samples.Add($row)
            Assert-TCCandidateNotCancelled $cancellation $nodeModule
            # Snapshot both between repeated requests and at completion. The
            # native observer additionally latches OS address/availability events.
            if($item.Required){$contexts.Add((Get-TCCandidateNetworkContext (Get-TCProbeField $manifest 'ProbeBinding')))}
        }
        foreach($target in $requiredTargets){
            $rows=@($samples|Where-Object {$_.Name -eq $target.Name -and $_.Required})
            $ok=($rows.Count -eq 3 -and @($rows|Where-Object {$_.Status -ne 'Passed' -or -not $_.TlsVerified -or -not $_.ObservedExitIPv4}).Count -eq 0)
            $summaryStatus=if($ok){'Passed'}elseif(@($rows|Where-Object {$_.Status -eq 'Failed'}).Count){'Failed'}else{'Inconclusive'}
            $checks.Add([pscustomobject]@{Name=$target.Name;Status=$summaryStatus;Code=$(if($ok){'RepeatedHttpsTraceVerified'}elseif($summaryStatus -eq 'Failed'){'RequiredSampleFailed'}else{'RequiredSamplesIncomplete'});SampleCount=$rows.Count;PassedCount=@($rows|Where-Object {$_.Status -eq 'Passed'}).Count;Source='AuthenticatedCandidateProxy'})
        }
        foreach($row in @($samples|Where-Object {-not $_.Required})){$checks.Add($row)}
        $ips=@($samples|Where-Object {$_.Required -and $_.TlsVerified -and $_.ObservedExitIPv4}|ForEach-Object {$_.ObservedExitIPv4}|Select-Object -Unique)
        if($ips.Count){$observed=$ips[0]}
        if($ips.Count -gt 1){$checks.Add([pscustomobject]@{Name='ExitConsistency';Status='Inconclusive';Code='ExitPoolChanged'})}
        $required=@($checks|Where-Object {$_.Name -in @('AddressHttps','DomainDnsHttps')})
        $forward=($required.Count -eq 2 -and @($required|Where-Object {$_.Status -ne 'Passed'}).Count -eq 0 -and $ips.Count -eq 1)
        $exitVerified=($forward -and $ExpectedExitIPv4 -and $ExpectedExitSource -eq 'ServerVerifiedTlsTrace' -and $observed -ceq $ExpectedExitIPv4)
        if(@($required|Where-Object {$_.Status -eq 'Failed'}).Count){$status='Failed';$code='CandidateForwardingFailed'}
        elseif(-not $forward){$status='Inconclusive';$code=if($ips.Count -gt 1){'ExitPoolChanged'}else{'CandidateForwardingUnverified'}}
        elseif(-not $ExpectedExitIPv4 -or $ExpectedExitSource -ne 'ServerVerifiedTlsTrace'){$status='Inconclusive';$code='ExpectedExitUnverified'}
        elseif(-not $exitVerified){$status='Failed';$code='ExitMismatch';$checks.Add([pscustomobject]@{Name='ExitBinding';Status='Failed';Code='ExitMismatch';ObservedExitIPv4=$observed;ExpectedExitIPv4=$ExpectedExitIPv4;Source=$ExpectedExitSource})}
        else{$status='Inconclusive';$code='ForwardingPassedPhysicalPathUnverified';$checks.Add([pscustomobject]@{Name='CandidateForwarding';Status='Passed';Code='VerifiedHttpsAndExit';Source='CandidateTlsTrace'})}
        $contexts.Add((Get-TCCandidateNetworkContext (Get-TCProbeField $manifest 'ProbeBinding')))
        if($observer){$observation=Stop-TCCandidateSocketWatch $observer;$observer=$null;if($ownershipMetadata.TraceGuid){$ownershipMetadata.TraceState='Stopped'}}
        $owned=($observation -and -not $process.HasExited -and $observation.ProcessId -eq $process.Id -and $observation.ProcessStartTicks -eq $process.StartTime.ToUniversalTime().Ticks -and (Test-TCCandidateProbeListener $port $process.Id))
        $hashesStable=((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ceq $manifestHash -and (Get-FileHash -LiteralPath $manifest.CandidatePath -Algorithm SHA256).Hash -ceq $candidateHash -and (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ceq $configHash)
        if($probePath){$hashesStable=($hashesStable -and (Get-FileHash -LiteralPath $probePath -Algorithm SHA256).Hash -ceq $manifest.ProbeSHA256)}
        $pathEvidence=Get-TCCandidatePathAssessment $candidate $manifest $profile $contexts.ToArray() $observation ([bool]$owned)
        # Also validate the actual temporary configuration, so a generator bug
        # cannot award the saved profile an unobserved effective binding.
        $effective=Get-TCCandidatePathAssessment $config $manifest $profile $contexts.ToArray() $observation ([bool]$owned)
        if($pathEvidence.Verified -and (-not $effective.Verified -or $effective.Kind -cne $pathEvidence.Kind)){$pathEvidence.Verified=$false;$pathEvidence.Reason='EffectiveProbeBindingMismatch'}
        if(-not $hashesStable){$pathEvidence.Verified=$false;$pathEvidence.Reason='ConfigurationChanged';$code='ConfigurationChanged';$status='Failed'}
        if(-not (Test-TCCandidateEngineBinding $manifest $engine $engineSHA256 $nodeModule)){$pathEvidence.Verified=$false;$pathEvidence.Reason='EngineMismatch';$code='EngineMismatch';$status='Failed'}
        Assert-TCCandidateNotCancelled $cancellation $nodeModule
    }catch{
        if($_.Exception.Data['TCProbeCancellationRequested']){$cancelled=$true;$code='ProbeCancelled'}
        elseif($_.Exception.Data['TCProbeCancellationPathInvalid']){$code='CancellationPathInvalid'}
        if($code -notin @('ActiveIdentity','ProbeCleanupFailed','ConfigurationChanged','EngineMismatch','ProbeCancelled','CancellationPathInvalid')){$code='ProbePreparationFailed'}
        $status=if($code -in @('ActiveIdentity','ProbeCancelled')){'Inconclusive'}else{'Failed'}
        $checks.Add([pscustomobject]@{Name='Probe';Status=$status;Code=$code;Message='候选验证未完成；原始异常未输出以保护秘密。'})
    }finally{
        if($launchPending){$cleanup=$false}
        if($observer){try{$null=Stop-TCCandidateSocketWatch $observer;$observer=$null}catch{$cleanup=$false}}
        if($ownershipMetadata -and $ownershipMetadata.TraceGuid -and $ownershipMetadata.TraceState -ne 'Stopped'){
            try{Stop-TCCandidateOwnedTrace $ownershipMetadata.TraceGuid;$ownershipMetadata.TraceState='Stopped'}catch{$cleanup=$false}
        }
        if($process){try{if(-not $process.HasExited){$process.Kill();if(-not $process.WaitForExit(5000)){throw 'Owned probe stop timed out'}};$process.Dispose()}catch{$cleanup=$false}}
        if($runDirectory){
            try{
                & $nodeModule {param($p)Assert-TCNoReparse $p} $runDirectory
                $plain=Join-Path $runDirectory 'candidate.private.json';if([IO.File]::Exists($plain)){[IO.File]::Delete($plain)}
                foreach($log in @(Get-ChildItem -LiteralPath (Join-Path $runDirectory 'logs') -File -ErrorAction SilentlyContinue)){& $nodeModule {param($p)Assert-TCNoReparse $p} $log.FullName;if($log.Name -match '^bounded-channel-candidate-[0-2]\.log(?:\.[12])?$'){[IO.File]::Delete($log.FullName)}}
            }catch{$cleanup=$false}
            try{Set-TCCandidateOwnership $nodeModule $runDirectory $(if($cleanup){'Stopped'}else{'NeedsRecovery'}) $null $ownershipMetadata}catch{$cleanup=$false}
        }
        if($sessionLock){try{$sessionLock.Dispose()}catch{$cleanup=$false}}
        $secret=$null;$candidate=$null;$config=$null;$active=$null;$privateKeys=$null
    }
    # A marker arriving during final cleanup must not leave a completed result
    # eligible. Cleanup errors below still take precedence over cancellation.
    if($cancellation -and -not $cancelled -and $code -ne 'CancellationPathInvalid'){
        try{$cancelled=Test-TCCandidateCancellation $cancellation $nodeModule}catch{$code='CancellationPathInvalid';$status='Failed'}
    }
    if($cancelled){
        $status='Inconclusive';$code='ProbeCancelled';$forward=$false;$exitVerified=$false
        $pathEvidence.Verified=$false;$pathEvidence.EligibleForRecommendation=$false;$pathEvidence.Reason='ProbeCancelled'
    }
    elseif($code -eq 'CancellationPathInvalid'){$forward=$false;$exitVerified=$false;$pathEvidence.Verified=$false;$pathEvidence.EligibleForRecommendation=$false;$pathEvidence.Reason=$code}
    if(-not $cleanup){$status='Failed';$code='ProbeCleanupFailed';$pathEvidence.EligibleForRecommendation=$false;$pathEvidence.Reason='ProbeCleanupFailed'}
    elseif($pathEvidence.Verified -and $pathEvidence.Kind -eq 'BoundInterfaceObserved' -and $forward -and $exitVerified -and $hashesStable -and $status -ne 'Failed'){$pathEvidence.EligibleForRecommendation=$true;$status='Passed';$code='CandidateReachabilityVerified'}
    if($pathEvidence.Verified -and -not $pathEvidence.EligibleForRecommendation -and $cleanup -and $pathEvidence.Kind -eq 'BoundInterfaceObserved'){
        $pathEvidence|Add-Member NoteProperty VerificationReason $pathEvidence.Reason
        $pathEvidence.Reason=if(-not $forward){'ForwardingSamplesUnverified'}elseif(-not $exitVerified){'TrustedExitNotVerified'}else{'ProbeDidNotComplete'}
    }
    $fingerprint=if($contexts.Count){$contexts[0].Fingerprint}else{$null}
    $result=[pscustomobject]@{SchemaVersion=2;Status=$status;Code=$code;NodeId=$normalizedNodeId;ProfileId=$ProfileId;Checks=$checks.ToArray();ForwardingPassed=[bool]$forward;ExitServerVerifiedTrace=[bool]$exitVerified;ObservedExitIPv4=$observed;ExpectedExitIPv4=$ExpectedExitIPv4;ExpectedExitSource=$ExpectedExitSource;Transport=$transport;TransportPath=$(if($pathEvidence.Verified){$pathEvidence.Kind}elseif($code -eq 'ActiveIdentity'){'NotStarted'}else{'ExistingSystemRoute'});PathStatus=$(if($pathEvidence.Verified){'Passed'}else{'Inconclusive'});PathEvidence=$pathEvidence;NetworkFingerprint=$fingerprint;NetworkChanged=$false;ContextChanged=[bool]($pathEvidence.Reason -in @('NetworkContextChanged','NetworkChangedDuringObservation'));ConfigHash=$configHash;CandidateHash=$candidateHash;ManifestHash=$manifestHash;RunId=$runId;CheckedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');DurationMs=[int]$watch.ElapsedMilliseconds;CleanupComplete=$cleanup;Samples=$samples.ToArray();Metrics=(Get-TCCandidateProbeMetrics $samples.ToArray());EvidencePath=$null}
    $result|Add-Member NoteProperty NetworkFingerprintScope $(if($contexts.Count){Get-TCProbeField $contexts[0] 'Scope'}else{$null})
    $result|Add-Member NoteProperty EngineSHA256 $engineSHA256
    $result|Add-Member NoteProperty CancellationRequested ([bool]$cancelled)
    $result|Add-Member NoteProperty CancellationAttemptId $(if($cancellation){$cancellation.AttemptId}else{$null})
    $result|Add-Member NoteProperty UnderlayFingerprint $(if($contexts.Count){Get-TCProbeField $contexts[0] 'UnderlayFingerprint'}else{$null})
    $result|Add-Member NoteProperty SnapshotFingerprint $(if($contexts.Count){Get-TCProbeField $contexts[0] 'SnapshotFingerprint'}else{$null})
    if($runDirectory){try{$result.EvidencePath=Join-Path $runDirectory 'result.json';& $nodeModule {param($p,$r)Write-TCAtomicJson $p $r -NewOnly} $result.EvidencePath $result}catch{$result|Add-Member NoteProperty EvidenceWarning '脱敏证据未能保存。'}}
    $result
}
Export-ModuleMember -Function Test-TCCandidateProbe
