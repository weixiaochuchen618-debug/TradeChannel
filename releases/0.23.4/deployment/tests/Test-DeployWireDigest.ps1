#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Web.Extensions
$null=[Reflection.Assembly]::LoadFrom((Join-Path $PackageRoot 'assets/lib/Renci.SshNet.dll'))
$assembly=[Reflection.Assembly]::LoadFrom((Join-Path $PackageRoot 'deployment/TradeChannelDeployHost.exe'))
$hostType=$assembly.GetType('TradeChannel.Deployment.Host')
if(-not $hostType){$hostType=@($assembly.GetTypes()|Where-Object Name -eq 'Host')[0]}
$flags=[Reflection.BindingFlags]'Static,NonPublic';$hashMethod=$hostType.GetMethod('WireDigest',$flags);$canonical=$hostType.GetMethod('Canonical',$flags)
if(-not $hashMethod -or -not $canonical){throw 'New wire digest implementation missing'}
$serializer=New-Object Web.Script.Serialization.JavaScriptSerializer
$inputs=@('{"Name":"香港中文","Null":null,"Ports":[2443,443,8443],"Enabled":false}', '{"Name":"quote\" slash\\","A":1.25,"B":0,"C":1e-6,"D":-2}', '{"Nested":{"z":null,"a":[{"Name":"\u9999\u6e2f"},true,1]},"Empty":[]}')
$vectors=@(foreach($inputJson in $inputs){
 $inputData=$serializer.DeserializeObject($inputJson);$normalized=$canonical.Invoke($null,@($inputData));$wire=$serializer.Serialize($normalized);$digest=$hashMethod.Invoke($null,@($wire))
 [pscustomobject]@{Input=$inputData;WireInput=$wire;InputDigest=$digest;SchemaVersion=1;Operation='apply';IntentId=[guid]::NewGuid().ToString()}
})
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($vectors|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($true))
