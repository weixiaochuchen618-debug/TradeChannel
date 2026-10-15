#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
. (Join-Path $PackageDirectory 'runtime\TradeChannel.Components.ps1')
Initialize-TCRuntimeComponent -Name TCDevicePath -PackageRoot $PackageDirectory
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
foreach($address in @([Net.IPAddress]::Loopback,[Net.IPAddress]::IPv6Loopback)){
 $listener=New-Object Net.Sockets.TcpListener($address,0)
 try{
  $listener.Start();$port=$listener.LocalEndpoint.Port
  Check (@([TCNetTable]::ListenerOwners($port)) -contains $PID) 'native IPv4/IPv6 listener identifies its actual owner'
 }finally{$listener.Stop()}
 Check (@([TCNetTable]::ListenerOwners($port)) -notcontains $PID) 'closed listener is absent on the next native read'
}
Check ([string]::Equals([TCNetTable]::ImagePath($PID),[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName,[StringComparison]::OrdinalIgnoreCase)) 'native image lookup preserves process path identity'
$name='tc-read-helper-'+[guid]::NewGuid().ToString('N');$server=[IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
$client=[IO.Pipes.NamedPipeClientStream]::new('.',$name,[IO.Pipes.PipeDirection]::InOut)
try{
 $wait=$server.WaitForConnectionAsync();$client.Connect(2000);Check ($wait.Wait(2000)) 'local identity fixture pipe connected'
 [uint32]$serverId=0
 Check ([TCProviderPipeIdentity]::GetNamedPipeServerProcessId($client.SafePipeHandle,[ref]$serverId) -and $serverId -eq $PID) 'precompiled pipe helper authenticates the real server PID'
}finally{$client.Dispose();$server.Dispose()}
$result=[pscustomobject]@{Passed=$true;Checks=$checks;LoopbackOnly=$true;RemoteNetworkChanges=0;AssemblyPath=[TCDevicePath].Assembly.Location;AssemblySHA256=(Get-FileHash -LiteralPath ([TCDevicePath].Assembly.Location)).Hash}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json
