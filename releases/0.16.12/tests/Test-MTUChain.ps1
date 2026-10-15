#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[switch]$ExpectLegacyBug)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Core'){$env:PSModulePath=Join-Path $PSHOME 'Modules'}
$package=[IO.Path]::GetFullPath($PackageRoot)
$server=Import-Module (Join-Path $package 'ServerSetup.psm1') -Force -PassThru -DisableNameChecking
$node=Import-Module (Join-Path $package 'NodeStore.psm1') -Force -PassThru -DisableNameChecking
$work=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('TC-MtuChain-'+[guid]::NewGuid().ToString('N'))))
if([IO.Path]::GetDirectoryName($work) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($work) -cnotmatch '^TC-MtuChain-[a-f0-9]{32}$'){throw 'Unsafe MTU fixture directory'}
$checks=New-Object Collections.Generic.List[string]
function Assert-Mtu([bool]$Condition,[string]$Description){if(-not $Condition){throw ('FAILED: '+$Description)};$checks.Add($Description)}
try{
    & $server {param($Path) New-TCPrivateDirectory $Path} $work
    $wg=Join-Path $package 'assets\wg.exe'
    $request=New-TCClientRequest -OutputDirectory (Join-Path $work 'client') -WgPath $wg
    $keys=& $server {param($Wg) New-TCKeyPair $Wg} $wg
    $response=[pscustomobject]@{SchemaVersion=1;Kind='TradeChannel.ClientResponse';Status='Authorized';RequestId=$request.RequestId;DeviceId=$request.DeviceId;NodeId=[guid]::NewGuid().ToString();NodeName='MTU isolated fixture';ClientPublicKey=$request.ClientPublicKey;ClientAddress='10.78.0.4/32';ServerPublicKey=$keys.Public;PublicEndpoint='203.0.113.10:51820';TunnelSubnet='10.78.0.0/24';ServerAddress='10.78.0.1/24';AllowedIPs=@('0.0.0.0/0');PersistentKeepalive=25;AddressFamilies=@('IPv4');ConfigRevision=1;MTU=1380;Validation=[pscustomobject]@{LocalAuthorization='Verified';ExternalConnectivity='NotTested'}}
    $keys=$null
    $responsePath=Join-Path $work 'response.json'
    & $server {param($Path,$Value) Write-TCJson $Path $Value} $responsePath $response
    $configPath=Join-Path $work 'client-mtu.conf'
    $completed=Complete-TCClientConfig -RequestDirectory $request.RequestDirectory -ResponsePath $responsePath -Destination $configPath
    $text=[IO.File]::ReadAllText($configPath)
    $exportHasMtu=$text -match '(?m)^MTU = 1380\r?$'
    $imported=Import-TCWireGuard -Root (Join-Path $work 'store') -Path $configPath -Name 'MTU isolated fixture' -EnginePath (Join-Path $package 'assets\sing-box.exe') -WgPath $wg -DirectDnsIPv4 '1.1.1.1'
    $manifest=Get-Content -LiteralPath $imported.manifestPath -Encoding UTF8 -Raw|ConvertFrom-Json
    $generated=Get-Content -LiteralPath $manifest.CandidatePath -Encoding UTF8 -Raw|ConvertFrom-Json
    $probe=Get-Content -LiteralPath $manifest.ProbePath -Encoding UTF8 -Raw|ConvertFrom-Json
    $tun=@($generated.inbounds|Where-Object {$_.type -eq 'tun'})[0]
    $endpoint=@($generated.endpoints|Where-Object {$_.tag -eq 'hk'})[0]
    $probeEndpoint=@($probe.endpoints|Where-Object {$_.tag -eq 'hk'})[0]
    $summary=[pscustomobject]@{ResponseMTU=1380;ExportHasMTU=$exportHasMtu;TunMTU=$tun.mtu;EndpointMTU=$endpoint.mtu;ProbeEndpointMTU=$probeEndpoint.mtu;SyntaxCheckPassed=$manifest.SyntaxValidated;NoTunnelStarted=$true;NoServerCalled=$true;RealDeviceIdentityUsed=$false}
    if($ExpectLegacyBug){
        Assert-Mtu (-not $exportHasMtu -and $tun.mtu -eq 1408 -and $endpoint.mtu -eq 1408 -and $probeEndpoint.mtu -eq 1408) 'Old exporter reproduces declared server MTU 1380 becoming 1408'
    }else{
        Assert-Mtu $exportHasMtu 'Authorized MTU is preserved in exported client.conf'
        Assert-Mtu ($tun.mtu -eq 1380 -and $endpoint.mtu -eq 1380 -and $probeEndpoint.mtu -eq 1380) 'Actual generated TUN, WireGuard endpoint and independent probe all inherit MTU 1380'
        $repeat=Complete-TCClientConfig -RequestDirectory $request.RequestDirectory -ResponsePath $responsePath -Destination $configPath
        Assert-Mtu ($repeat.Status -eq 'AlreadyCompleted') 'MTU-bearing client export remains idempotent'
        foreach($bad in @($null,$true,'1380',[double]1380.5,1279,1421)){
            $response.MTU=$bad
            & $server {param($Path,$Value) Write-TCJson $Path $Value} $responsePath $response
            $invalidPath=Join-Path $work ('invalid-'+[guid]::NewGuid().ToString('N')+'.conf')
            $rejected=$false
            try{$null=Complete-TCClientConfig -RequestDirectory $request.RequestDirectory -ResponsePath $responsePath -Destination $invalidPath}catch{if($_.Exception.Message -match 'InvalidResponseMTU'){$rejected=$true}else{throw}}
            Assert-Mtu ($rejected -and -not (Test-Path -LiteralPath $invalidPath)) ('Invalid MTU '+[string]$bad+' is rejected before any client configuration is created')
        }
        $response.PSObject.Properties.Remove('MTU')
        & $server {param($Path,$Value) Write-TCJson $Path $Value} $responsePath $response
        $legacyPath=Join-Path $work 'legacy.conf'
        $null=Complete-TCClientConfig -RequestDirectory $request.RequestDirectory -ResponsePath $responsePath -Destination $legacyPath
        $legacyText=[IO.File]::ReadAllText($legacyPath)
        $legacyMtu=& $node {param($Raw) (ConvertFrom-TCWireGuard $Raw).mtu} $legacyText
        Assert-Mtu ($legacyText -notmatch '(?m)^MTU' -and $legacyMtu -eq 1408) 'Legacy response preserves existing default instead of silently guessing another server MTU'
    }
    $filename=if($ExpectLegacyBug){'mtu-chain-baseline.json'}else{'mtu-chain-fixed-'+$PSVersionTable.PSEdition+'.json'}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $filename),([pscustomobject]@{Summary=$summary;Passed=$true;Checks=@($checks.ToArray());HostNetworkChanged=$false}|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{Passed=$true;Checks=$checks.Count;Summary=$summary;HostNetworkChanged=$false}|ConvertTo-Json -Depth 4
}finally{
    $text=$null;$response=$null;$keys=$null;$legacyText=$null
    if(Test-Path -LiteralPath $work){
        $resolved=[IO.Path]::GetFullPath((Resolve-Path -LiteralPath $work).Path)
        if($resolved -cne $work -or [IO.Path]::GetDirectoryName($resolved) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -cnotmatch '^TC-MtuChain-[a-f0-9]{32}$'){throw 'Unsafe MTU fixture cleanup target'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
