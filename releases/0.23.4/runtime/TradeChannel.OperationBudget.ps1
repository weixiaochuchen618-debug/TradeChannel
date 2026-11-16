# Shared bounded controller calls. A zero operation budget preserves legacy
# standalone callers while retaining each request's finite timeout.
function New-TCOperationBudget {param([int]$Seconds=0)
 @{Seconds=$Seconds;Watch=[Diagnostics.Stopwatch]::StartNew()}
}
function Get-TCOperationRemaining {param($Budget)
 if($Budget -and $Budget.Seconds -gt 0){return [Math]::Max(0.0,$Budget.Seconds-$Budget.Watch.Elapsed.TotalSeconds)}
 [double]::PositiveInfinity
}
function Assert-TCOperationBudget {param($Budget)
 if((Get-TCOperationRemaining $Budget) -le 0){throw '[TC:ConnectionTimeout] Connection stage exhausted its execution budget; reconcile the original transaction.'}
}
function Get-TCOperationTimeout {param($Budget,[double]$Maximum=5)
 Assert-TCOperationBudget $Budget
 [Math]::Min($Maximum,(Get-TCOperationRemaining $Budget))
}
function Send-TCBudgetController {param($Client,[string]$Method,[string]$Url,[string]$Body,$Budget,[double]$Maximum=5)
 $seconds=Get-TCOperationTimeout $Budget $Maximum
 $cancel=New-Object Threading.CancellationTokenSource
 $cancel.CancelAfter([int][Math]::Max(1,[Math]::Floor($seconds*1000)))
 $request=New-Object Net.Http.HttpRequestMessage((New-Object Net.Http.HttpMethod($Method)),$Url)
 # PowerShell casts null string arguments to empty strings. GET/HEAD must never
 # receive an empty StringContent body through that cast.
 if($Body -and $Method -notin @('GET','HEAD')){$request.Content=New-Object Net.Http.StringContent($Body,[Text.Encoding]::UTF8,'application/json')}
 try{
  $response=$Client.SendAsync($request,$cancel.Token).GetAwaiter().GetResult()
  try{$null=$response.EnsureSuccessStatusCode();$text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();Assert-TCOperationBudget $Budget;return $text}finally{$response.Dispose()}
 }catch{Assert-TCOperationBudget $Budget;throw}finally{$request.Dispose();$cancel.Dispose()}
}
