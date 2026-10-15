#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ClientConfig,[Parameter(Mandatory=$true)][string]$OutputPath,[ValidateRange(1,12)][int]$TraceAttempts=1,[ValidateRange(576,1420)][int]$Mtu=1380,[string]$BindInterface,[ValidateRange(0,65535)][int]$ListenPort=0,[ValidateRange(0,65535)][int]$LocalRelayPort=0,[switch]$ViaCurrentTrade,[ValidateSet(0,443)][int]$ProbeRelayPort=0,[ValidateRange(0,120)][int]$WaitForHandshakeSeconds=0,[ValidateSet('Auto','Trace','TradingView','Tradovate')][string]$Target='Auto',[string]$ResolveIPv4)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$package=Join-Path (Split-Path $PSScriptRoot -Parent) 'product'
$module=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -DisableNameChecking -PassThru
$root=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'
$deployment=Get-Content -LiteralPath (Join-Path $root 'deployment.json') -Raw -Encoding UTF8|ConvertFrom-Json
$active=Get-Content -LiteralPath $deployment.ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
$before=Get-Content -LiteralPath (Join-Path $root 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json
$hash=(Get-FileHash -LiteralPath $active.CandidatePath).Hash
$wg=& $module {param($path)ConvertFrom-TCWireGuard ([IO.File]::ReadAllText($path))} ((Resolve-Path -LiteralPath $ClientConfig).Path)
$dir=Join-Path $root ('linux-probes\'+[guid]::NewGuid().ToString('N'))
& $module {param($parent,$p)if(-not(Test-Path -LiteralPath $parent)){New-TCPrivateDirectory $parent};New-TCPrivateDirectory $p} (Split-Path $dir -Parent) $dir
$proc=$null;$results=@();$passed=$false
try{
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 $password=[guid]::NewGuid().ToString('N')
 $peer=@{address=$wg.endpoint.address;port=$wg.endpoint.port;public_key=$wg.peer.PublicKey;allowed_ips=@('0.0.0.0/0');persistent_keepalive_interval=25}
 if($wg.peer.PresharedKey){$peer.pre_shared_key=$wg.peer.PresharedKey}
 $cfg=@{
  log=@{level='debug';timestamp=$true}
  dns=@{servers=@(@{type='https';tag='candidate-dns';server='1.1.1.1';server_port=443;path='/dns-query';detour='candidate'});final='candidate-dns';strategy='ipv4_only'}
  inbounds=@(@{type='mixed';tag='candidate-probe';listen='127.0.0.1';listen_port=$port;users=@(@{username='candidate';password=$password})})
  endpoints=@(@{type='wireguard';tag='candidate';system=$false;mtu=$Mtu;address=@($wg.clientIPv4+'/32');private_key=$wg.interface.PrivateKey;peers=@($peer)})
  route=@{final='candidate';auto_detect_interface=$true;default_domain_resolver='candidate-dns'}
 }
 if($ListenPort -gt 0){$cfg.endpoints[0].listen_port=$ListenPort}
 if($ProbeRelayPort){$cfg.endpoints[0].peers[0].port=$ProbeRelayPort}
 if($BindInterface){
  $adapter=Get-NetAdapter -Name $BindInterface -ErrorAction Stop
  if($adapter.Status -ne 'Up' -or $adapter.InterfaceDescription -match 'WireGuard|Wintun|sing-tun|VMware|Hyper-V|Bluetooth'){throw 'Probe binding requires an active physical interface'}
  $cfg.endpoints[0].bind_interface=$adapter.Name
 }
 if($LocalRelayPort -gt 0){
  $cfg.endpoints[0].peers[0].address='127.0.0.1';$cfg.endpoints[0].peers[0].port=$LocalRelayPort
  $cfg.endpoints[0].bind_interface='Loopback Pseudo-Interface 1'
 }
 if($ViaCurrentTrade){
  if($LocalRelayPort -or $BindInterface){throw 'Use one explicit outer transport per diagnostic'}
  $liveConfig=Get-Content -LiteralPath $active.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
  $liveProbe=@($liveConfig.inbounds|Where-Object {$_.tag -eq 'egress-probe' -and $_.listen -eq '127.0.0.1'})[0]
  $liveUser=@($liveProbe.users|Where-Object {$_.username -eq 'tradechannel-probe'})[0]
  if(-not $liveUser.password -or -not $liveProbe.listen_port){throw 'Authenticated current-trade diagnostic transport unavailable'}
  $outerSecret=[string]$liveUser.password
  $cfg.outbounds=@(@{type='socks';tag='outer-trade';server='127.0.0.1';server_port=[int]$liveProbe.listen_port;version='5';username=$liveUser.username;password=$outerSecret})
  $cfg.endpoints[0].detour='outer-trade'
  $liveConfig=$null;$liveUser=$null;$liveProbe=$null
 }
 $config=Join-Path $dir 'probe.json';[IO.File]::WriteAllText($config,($cfg|ConvertTo-Json -Depth 16),(New-Object Text.UTF8Encoding($false)))
 $diagnostics=Join-Path $root 'diagnostics';$null=New-Item -ItemType Directory -Path $diagnostics -Force
 $engine=Join-Path $diagnostics 'tc-linux-probe.exe';Copy-Item -LiteralPath (Join-Path $package 'assets\sing-box.exe') -Destination $engine -Force
 $check=Start-Process -FilePath $engine -ArgumentList @('check','-c',('"'+$config+'"')) -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput (Join-Path $dir 'check.out') -RedirectStandardError (Join-Path $dir 'check.err')
 if($check.ExitCode -ne 0){throw 'Candidate probe syntax rejected; live network unchanged'};$check.Dispose()
 $proc=Start-Process -FilePath $engine -ArgumentList @('run','-c',('"'+$config+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dir 'run.out') -RedirectStandardError (Join-Path $dir 'run.err')
 $ready=$false
 for($i=0;$i -lt 30;$i++){
  if($proc.HasExited){throw 'Candidate probe exited; live channel untouched'}
  $socket=[Net.Sockets.TcpClient]::new();try{if($socket.ConnectAsync('127.0.0.1',$port).Wait(150)){$ready=$socket.Connected}}catch{}finally{$socket.Dispose()};if($ready){break};Start-Sleep -Milliseconds 150
 };if(-not $ready){throw 'Candidate diagnostic listener not ready'}
 if($WaitForHandshakeSeconds){
  $handshakeWatch=[Diagnostics.Stopwatch]::StartNew();$handshakeSeen=$false
  while($handshakeWatch.Elapsed.TotalSeconds -lt $WaitForHandshakeSeconds){
   if($proc.HasExited){throw 'Candidate exited before WireGuard handshake'}
   $sharedLog=[IO.File]::Open((Join-Path $dir 'run.err'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
   $sharedReader=New-Object IO.StreamReader($sharedLog)
   try{$currentLog=$sharedReader.ReadToEnd()}finally{$sharedReader.Dispose();$sharedLog.Dispose()}
   if($currentLog -match 'received handshake response'){$handshakeSeen=$true;break}
   Start-Sleep -Milliseconds 250
  }
  $handshakeWatch.Stop();if(-not $handshakeSeen){throw 'No WireGuard handshake within the diagnostic window; HTTPS was not tested'}
 }
 $urls=switch($Target){
  'Trace' {@(1..$TraceAttempts|ForEach-Object {'https://1.1.1.1/cdn-cgi/trace'})}
  'TradingView' {@('https://www.tradingview.com/')}
  'Tradovate' {@('https://trader.tradovate.com/')}
  default {if($TraceAttempts -gt 1){@(1..$TraceAttempts|ForEach-Object {'https://1.1.1.1/cdn-cgi/trace'})}else{@('https://1.1.1.1/cdn-cgi/trace','https://www.tradingview.com/','https://trader.tradovate.com/')}}
 }
 foreach($url in $urls){
  $requestStarted=[DateTime]::UtcNow.ToString('o')
  $settingsLines=@(('proxy = "http://127.0.0.1:'+$port+'"'),('proxy-user = "candidate:'+$password+'"'),'noproxy = ".invalid"','silent','show-error','connect-timeout = 8','max-time = 20')
  if($ResolveIPv4 -and $url -match '^https://www\.tradingview\.com/'){$settingsLines+=('resolve = "www.tradingview.com:443:'+$ResolveIPv4+'"')}
  $settingsLines+=@(('url = "'+$url+'"'),'write-out = "\nTC_HTTP:%{http_code}\nTC_TIMES:%{time_connect},%{time_appconnect},%{time_starttransfer},%{time_total},%{size_download}"')
  $settings=$settingsLines -join "`n"
  $si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=(Get-Command curl.exe).Source;$si.Arguments='--config -';$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
  $curl=New-Object Diagnostics.Process;$curl.StartInfo=$si;$old=[Console]::InputEncoding
  try{
   [Console]::InputEncoding=[Text.Encoding]::ASCII;$null=$curl.Start();$bytes=[Text.Encoding]::UTF8.GetBytes($settings);$curl.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$curl.StandardInput.Close()
   $out=$curl.StandardOutput.ReadToEndAsync();$err=$curl.StandardError.ReadToEndAsync();if(-not $curl.WaitForExit(25000)){$curl.Kill();throw 'Candidate HTTPS probe timed out'}
   $body=$out.GetAwaiter().GetResult();$errorText=$err.GetAwaiter().GetResult();$ip=$null;$status=0
   if($body -match '(?m)^ip=([^\r\n]+)'){$ip=$matches[1]};if($body -match '(?m)^TC_HTTP:(\d{3})'){$status=[int]$matches[1]}
   $safeError=$errorText.Replace($password,'<hidden>');if($safeError.Length -gt 1000){$safeError=$safeError.Substring(0,1000)}
   $timings=$null;if($body -match '(?m)^TC_TIMES:([^\r\n]+)'){$timings=$matches[1]}
   $results+=[pscustomobject]@{StartedAtUtc=$requestStarted;Url=$url;ExitCode=$curl.ExitCode;HttpStatus=$status;ObservedIP=$ip;TimingConnectTlsFirstByteTotalBytes=$timings;Error=$safeError}
  }finally{[Console]::InputEncoding=$old;$curl.Dispose();$settings=$null}
 }
 $passed=(@($results|Where-Object {$_.ExitCode -ne 0 -or $_.HttpStatus -lt 200 -or $_.HttpStatus -ge 400 -or ($_.Url -eq 'https://1.1.1.1/cdn-cgi/trace' -and $_.ObservedIP -ne $wg.endpoint.address)}).Count -eq 0)
}finally{
 if($proc){try{if(-not $proc.HasExited){$proc.Kill();$null=$proc.WaitForExit(5000)}}finally{$proc.Dispose()}}
 $after=Get-Content -LiteralPath (Join-Path $root 'runtime.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if(Test-Path -LiteralPath (Join-Path $dir 'run.err')){
  $log=[IO.File]::ReadAllText((Join-Path $dir 'run.err'))
  foreach($secret in @($password,$outerSecret,$wg.interface.PrivateKey,$wg.peer.PresharedKey)){if($secret){$log=$log.Replace([string]$secret,'<hidden>')}}
  if($log.Length -gt 40000){$log=$log.Substring($log.Length-40000)}
  [IO.File]::WriteAllText(([IO.Path]::GetFullPath($OutputPath)+'.log'),$log,(New-Object Text.UTF8Encoding($false)))
 }
 $unchanged=($before.EnginePid -eq $after.EnginePid -and $before.EngineStartedAt -eq $after.EngineStartedAt -and (Get-FileHash -LiteralPath $active.CandidatePath).Hash -eq $hash)
 $report=[ordered]@{At=(Get-Date).ToString('o');Passed=($passed -and $unchanged);Endpoint=$wg.endpoint.text;Mtu=$Mtu;BindInterface=$BindInterface;ListenPort=$ListenPort;LocalRelayPort=$LocalRelayPort;ViaCurrentTrade=[bool]$ViaCurrentTrade;ProbeRelayPort=$ProbeRelayPort;Results=$results;ExistingChannelUnchanged=$unchanged;TunCreated=$false;LocalRoutesChanged=$false;TemporaryProcessStopped=$true}
 [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($report|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
 $full=[IO.Path]::GetFullPath($dir);$prefix=[IO.Path]::GetFullPath((Join-Path $root 'linux-probes')).TrimEnd('\')+'\'
 if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
 $cfg=$null;$wg=$null
}
$report|ConvertTo-Json -Depth 5
