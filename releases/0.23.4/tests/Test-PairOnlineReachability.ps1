#requires -Version 5.1
# 0.22.0 A4: Test-TCPairOnlineReachability against loopback fixtures only.
# Every fixture is a local listener; nothing here touches a real network.
param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop';$script:checks=0;$script:fixtures=@()
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
Import-Module (Join-Path $PackageDirectory 'PairingOnline.psm1') -Force -DisableNameChecking
function Get-DerDigest {param($Certificate)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ((($sha.ComputeHash($Certificate.GetRawCertData()))|ForEach-Object {$_.ToString('x2')}) -join '')}finally{$sha.Dispose()}
}
function New-PfxCertificate {
    $rsa=[Security.Cryptography.RSA]::Create(2048)
    $request=New-Object Security.Cryptography.X509Certificates.CertificateRequest('CN=TradeChannel Online Pairing',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(1))
    return [pscustomobject]@{
        Pfx=$certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx,'tc-reachability')
        Digest=(Get-DerDigest $certificate)}
}
function Get-FreePort {
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    try{return [int]$listener.LocalEndpoint.Port}finally{$listener.Stop()}
}
# A loopback server on its own runspace: 'Tls' completes the handshake and then
# counts the application bytes it received, 'Stall' accepts TCP and never
# answers the handshake.
function Start-LoopbackFixture {param([int]$Port,[byte[]]$Pfx,[string]$Mode)
    $body={
        param([int]$Port,[byte[]]$Pfx,[string]$Mode)
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
        $listener.Start()
        $client=$null;$stream=$null
        try{
            $client=$listener.AcceptTcpClient()
            if($Mode -eq 'Stall'){Start-Sleep -Milliseconds 3000;return 'stalled'}
            $certificate=New-Object Security.Cryptography.X509Certificates.X509Certificate2($Pfx,'tc-reachability')
            $stream=New-Object Net.Security.SslStream($client.GetStream(),$false)
            $stream.AuthenticateAsServer($certificate,$false,[Security.Authentication.SslProtocols]::Tls12,$false)
            $stream.ReadTimeout=1500
            $buffer=New-Object byte[] 256
            $read=0
            try{$read=$stream.Read($buffer,0,$buffer.Length)}catch{$read=0}
            return ('served:'+$read)
        }finally{
            if($stream){$stream.Dispose()}
            if($client){$client.Close()}
            $listener.Stop()
        }
    }
    $runspace=[runspacefactory]::CreateRunspace();$runspace.Open()
    $shell=[powershell]::Create();$shell.Runspace=$runspace
    $null=$shell.AddScript($body).AddArgument($Port).AddArgument($Pfx).AddArgument($Mode)
    $fixture=[pscustomobject]@{Port=$Port;Shell=$shell;Runspace=$runspace;Handle=$shell.BeginInvoke()}
    $script:fixtures=@($script:fixtures)+@($fixture)
    Start-Sleep -Milliseconds 350
    return $fixture
}
function Complete-LoopbackFixture {param($Fixture)
    try{return (@($Fixture.Shell.EndInvoke($Fixture.Handle)) -join '')}catch{return ''}
    finally{try{$Fixture.Shell.Dispose()}catch{};try{$Fixture.Runspace.Close()}catch{}}
}
try{
    $certificate=New-PfxCertificate
    # 1. Reachable: the pinned digest matches and nothing is written after the handshake.
    $served=Start-LoopbackFixture -Port (Get-FreePort) -Pfx $certificate.Pfx -Mode 'Tls'
    $reachable=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port $served.Port -TlsSha256 $certificate.Digest -TimeoutSeconds 5
    $serverText=Complete-LoopbackFixture $served
    Check ($reachable.Status -eq 'Reachable') 'loopback handshake with the pinned digest reports Reachable'
    Check ($serverText -eq 'served:0') 'the check sends no application data after the handshake'
    Check ([int]$reachable.ElapsedMs -ge 0 -and [int]$reachable.ElapsedMs -lt 30000) 'ElapsedMs is a bounded duration'
    $stamp=[DateTimeOffset]::MinValue
    Check ([DateTimeOffset]::TryParse([string]$reachable.CheckedAtUtc,[ref]$stamp)) 'CheckedAtUtc is an ISO timestamp'
    # 2. TlsMismatch: a different certificate digest is reported, not accepted.
    $mismatch=Start-LoopbackFixture -Port (Get-FreePort) -Pfx $certificate.Pfx -Mode 'Tls'
    $other=New-PfxCertificate
    $mismatched=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port $mismatch.Port -TlsSha256 $other.Digest -TimeoutSeconds 5
    $null=Complete-LoopbackFixture $mismatch
    Check ($mismatched.Status -eq 'TlsMismatch') 'a pinned digest that differs from the served leaf reports TlsMismatch'
    # 3. Refused: nothing is listening on that loopback port.
    $refused=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port (Get-FreePort) -TlsSha256 $certificate.Digest -TimeoutSeconds 5
    Check ($refused.Status -eq 'Refused') 'a closed loopback port reports Refused'
    # 4. Timeout: TCP completes but the peer never finishes the handshake.
    $stalled=Start-LoopbackFixture -Port (Get-FreePort) -Pfx $certificate.Pfx -Mode 'Stall'
    $timed=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port $stalled.Port -TlsSha256 $certificate.Digest -TimeoutSeconds 1
    $null=Complete-LoopbackFixture $stalled
    Check ($timed.Status -eq 'Timeout') 'a peer that never answers the handshake reports Timeout'
    Check ([int]$timed.ElapsedMs -ge 900 -and [int]$timed.ElapsedMs -lt 15000) 'Timeout honours the one second budget'
    # 5. Input validation keeps the invite-side error codes.
    $rejected=$null
    try{$null=Test-TCPairOnlineReachability -PublicHost 'server.example.com' -Port 18443 -TlsSha256 $certificate.Digest}catch{$rejected=$_.Exception.Message}
    Check ($rejected -like '*InvalidOnlineHost*') 'a host name instead of an IPv4 address is rejected'
    $rejected=$null
    try{$null=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port 18443 -TlsSha256 'not-a-digest'}catch{$rejected=$_.Exception.Message}
    Check ($rejected -like '*InvalidOnlineTls*') 'a missing certificate digest is rejected before any connection'
    $rejected=$null
    try{$null=Test-TCPairOnlineReachability -PublicHost '127.0.0.1' -Port 70000 -TlsSha256 $certificate.Digest}catch{$rejected=$_.Exception.Message}
    Check ($rejected -like '*InvalidOnlinePort*') 'a port outside 1..65535 is rejected'
    $result=[pscustomobject]@{Passed=$true;Checks=$script:checks;LoopbackOnly=$true;RemoteNetworkChanges=0}
}catch{
    $result=[pscustomobject]@{Passed=$false;Checks=$script:checks;Error=$_.Exception.Message;LoopbackOnly=$true;RemoteNetworkChanges=0}
}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$result|ConvertTo-Json
if(-not $result.Passed){exit 1}
