#requires -Version 5.1
[CmdletBinding()]
param([string]$Url='https://1.1.1.1/cdn-cgi/trace',[ValidateSet('Trade','Daily')][string]$Lane='Trade',[ValidateRange(3,20)][int]$ConnectTimeoutSeconds=12,[ValidateRange(5,25)][int]$TimeoutSeconds=15)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TradeChannel.Diagnostics.ps1')
$uri=[Uri]$Url
if($uri.Scheme -ne 'https'){throw 'Only HTTPS diagnostics are accepted.'}
$d=Read-TCExitDiagnosticJson -Path (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\deployment.json')
$m=Read-TCExitDiagnosticJson -Path ([string]$d.ManifestPath)
$inputContext=Get-TCExitDiagnosticInput -Manifest $m -Lane $Lane -CheckInterfaces
$cfg=$inputContext.Config;$in=@($inputContext.Inbound);$user=@($inputContext.User);$inputContext=$null
$escapedUrl=$uri.AbsoluteUri.Replace('\','\\').Replace('"','\"')
$settings=@(
    ('proxy = "http://127.0.0.1:'+$in[0].listen_port+'"'),
    ('proxy-user = "'+$user[0].username+':'+$user[0].password+'"'),
    'noproxy = ".invalid"',
    'silent','show-error',('connect-timeout = '+$ConnectTimeoutSeconds),('max-time = '+$TimeoutSeconds),
    ('url = "'+$escapedUrl+'"'),
    'write-out = "\nTC_HTTP:%{http_code}"'
) -join "`n"
$si=New-Object Diagnostics.ProcessStartInfo
$si.FileName=Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
if(-not [IO.File]::Exists($si.FileName)){throw 'Bound Windows curl diagnostic executable is missing.'}
$si.Arguments='--config -'
$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
$p=New-Object Diagnostics.Process;$p.StartInfo=$si
$savedEncoding=[Console]::InputEncoding
try{
    [Console]::InputEncoding=[Text.Encoding]::ASCII
    $null=$p.Start();$bytes=[Text.Encoding]::UTF8.GetBytes($settings)
    $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$p.StandardInput.BaseStream.Close();[Array]::Clear($bytes,0,$bytes.Length)
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(($TimeoutSeconds+3)*1000)){$p.Kill();$null=$p.WaitForExit(3000);throw 'Diagnostic process exceeded its time budget.'}
    $body=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
    $ip=$null;if($uri.AbsolutePath -eq '/cdn-cgi/trace' -and $body -match '(?m)^ip=([^\r\n]+)'){$ip=$matches[1].Trim()}
    $http=$null;if($body -match '(?m)^TC_HTTP:(\d{3})'){$http=[int]$matches[1]}
    [pscustomobject]@{Url=$Url;Lane=$Lane;CurlExit=$p.ExitCode;HTTPStatus=$http;ObservedIP=$ip;Via=('Authenticated local diagnostic inlet -> '+$(if($Lane -eq 'Daily'){'selected daily exit'}else{'manually selected trade exit'}))}
}finally{if($p -and -not $p.HasExited){$p.Kill();$null=$p.WaitForExit(3000)};$p.Dispose();[Console]::InputEncoding=$savedEncoding;$settings=$null;$cfg=$null;$in=$null;$user=$null;$body=$null}
