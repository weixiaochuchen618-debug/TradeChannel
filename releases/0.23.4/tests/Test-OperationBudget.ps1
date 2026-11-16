#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$ReportPath)
$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Net.Http
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
. (Join-Path $PackageRoot 'runtime\TradeChannel.OperationBudget.ps1')
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class TCBudgetFixtureHandler: HttpMessageHandler {
 public bool Block; public int Calls;
 protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage r,CancellationToken c) {
  if(r.Method==HttpMethod.Get && r.Content!=null) throw new InvalidOperationException("GET must not carry content");
  Calls++; if(Block) await Task.Delay(30000,c);
  return new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("{\"fixture\":true}")};
 }
}
'@
$handler=New-Object TCBudgetFixtureHandler;$client=New-Object Net.Http.HttpClient($handler);$client.Timeout=[TimeSpan]::FromSeconds(30);$checks=0
try{
 $budget=New-TCOperationBudget 2;$text=Send-TCBudgetController $client GET 'http://127.0.0.1/fixture-unused' $null $budget
 if(-not ($text|ConvertFrom-Json).fixture -or $handler.Calls -ne 1){throw 'Bounded controller success failed'};$checks++
 $handler.Block=$true;$budget=New-TCOperationBudget 1;$timer=[Diagnostics.Stopwatch]::StartNew();$rejected=$false
 try{$null=Send-TCBudgetController $client GET 'http://127.0.0.1/fixture-unused' $null $budget}catch{$rejected=$true}
 if(-not $rejected -or $timer.Elapsed.TotalSeconds -gt 3){throw 'Actual HttpClient cancellation did not obey remaining budget'};$checks++
 Start-Sleep -Milliseconds 30;$before=$handler.Calls;$rejected=$false
 try{$null=Send-TCBudgetController $client DELETE 'http://127.0.0.1/fixture-unused' $null $budget}catch{$rejected=$_.Exception.Message -like '*ConnectionTimeout*'}
 if(-not $rejected -or $handler.Calls -ne $before){throw 'Expired operation invoked another request'};$checks++
 $budget=New-TCOperationBudget 0;if((Get-TCOperationTimeout $budget 5) -ne 5){throw 'Legacy request timeout lost'};$checks++
 $result=[pscustomobject]@{Passed=$true;Assertions=$checks;ActualHttpClientCancellation=$true;DurationSeconds=[Math]::Round($timer.Elapsed.TotalSeconds,3);NetworkSocketsOpened=0;Handler='InMemoryOnly'}
 if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json
}finally{$client.Dispose();$handler.Dispose()}
