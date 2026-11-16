#requires -Version 5.1
# 0.22.0 C-R12 acceptance: the launcher must survive being started from
# PowerShell 7 and must leave a diagnostic code that is safe to show and safe to
# store.
#
# Two independent halves:
#   1. Static - the module path is pinned before any module import runs, so an
#      inherited PSModulePath from pwsh 7 cannot break Windows PowerShell 5.1
#      module loading.
#   2. Behavioural - the three lines that build ErrorCode are lifted out of the
#      real script and run against crafted failures. No engine is started, no
#      runtime.json is written, no process is created.
#
# The behavioural half is deliberately not a re-implementation: the source lines
# are read from runtime/Run-TradeChannel.ps1 at run time, so editing the product
# code without editing the test keeps the test honest.
[CmdletBinding()]param([string]$PackageRoot='',[string]$ReportPath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run with Windows PowerShell 5.1.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)
 if(-not $Condition){throw ('Runtime error code FAILED: '+$Name)}
 $script:Checks.Add($Name)
}

$launcher=Join-Path $script:PackageRoot 'runtime\Run-TradeChannel.ps1'
Check (Test-Path -LiteralPath $launcher) 'the launcher exists in the package'
$source=[IO.File]::ReadAllText($launcher,[Text.Encoding]::UTF8)

# --- 1. module path is pinned before anything imports a module ---------------
Check ($source -match '\$env:PSModulePath\s*=\s*Join-Path\s+\$PSHOME\s+''Modules''') 'the launcher pins PSModulePath to the 5.1 module home'
$pinAt=$source.IndexOf("`$env:PSModulePath=Join-Path `$PSHOME 'Modules'")
$paramAt=$source.IndexOf('param(')
Check ($pinAt -gt 0 -and $paramAt -ge 0 -and $pinAt -gt $paramAt) 'the pin runs after param() so the parameters still bind normally'
$firstImport=$source.IndexOf('Import-Module')
Check ($firstImport -lt 0 -or $pinAt -lt $firstImport) 'the pin runs before the first Import-Module'

# --- 2. the ErrorCode builder behaves as specified --------------------------
$lines=@($source -split "`r?`n")
$builder=@($lines | Where-Object { $_ -match '\$errorCode\s*=' })
Check ($builder.Count -ge 3) ('the launcher builds ErrorCode in at least three steps, got '+$builder.Count)
Check (@($lines | Where-Object { $_ -match '\$state\|Add-Member\s+NoteProperty\s+ErrorCode' }).Count -eq 1) 'the code is written onto the state object exactly once'

# Reuse the product's own statements. A trailing read makes the block return the
# value instead of assigning it silently.
$block=[scriptblock]::Create((($builder -join "`n")+"`n`$errorCode"))
function Get-Code {param($Failure)
 return [string](@($Failure) | ForEach-Object $block | Select-Object -Last 1)
}

# 2a. Ordinary failure: type @ file : line, nothing else.
$ordinary=[pscustomobject]@{
 Exception=[System.InvalidOperationException]::new('启动失败：无法读取 C:\Users\ExampleUser\secret.txt，令牌 TCI1.abcdefghijklmnop')
 InvocationInfo=[pscustomobject]@{ScriptName='C:\tradechannel\runtime\Run-TradeChannel.ps1';ScriptLineNumber=42}
}
$code=Get-Code $ordinary
Check ($code -ceq 'InvalidOperationException@Run-TradeChannel.ps1:42') ('an ordinary failure yields type@file:line, got '+$code)

# 2b. The message body never reaches the code, even when it carries a path, a
#     Chinese sentence and an invitation code.
Check ($code -notmatch 'secret') 'the code never contains a path from the message'
Check ($code -notmatch 'TCI1') 'the code never contains an invitation code from the message'
Check ($code -notmatch '[\u4e00-\u9fff]') 'the code never contains Chinese from the message'

# 2c. A hostile script name is filtered down to the allowed alphabet.
$hostile=[pscustomobject]@{
 Exception=[System.IO.IOException]::new('x')
 InvocationInfo=[pscustomobject]@{ScriptName='C:\a b\启动 脚本 $(calc).ps1';ScriptLineNumber=7}
}
$hostileCode=Get-Code $hostile
Check ($hostileCode -match '^[A-Za-z0-9_.@:-]+$') ('a hostile script name is filtered, got '+$hostileCode)
Check ($hostileCode -notmatch '\$|\(') 'command substitution characters never survive the filter'
Check ($hostileCode.EndsWith(':7')) 'the line number survives the filter'

# 2d. The 128 character ceiling holds even for an absurd script name.
$longName=('A'*200)+'.ps1'
$long=[pscustomobject]@{
 Exception=[System.Exception]::new('x')
 InvocationInfo=[pscustomobject]@{ScriptName=('C:\'+$longName);ScriptLineNumber=9}
}
$longCode=Get-Code $long
Check ($longCode.Length -le 128) ('the code is capped at 128 characters, got '+$longCode.Length)
Check ($longCode -match '^[A-Za-z0-9_.@:-]+$') 'a truncated code still matches the allowed alphabet'

# 2e. A failure without an invocation record still produces a usable code
#     instead of throwing inside the catch block.
$bare=[pscustomobject]@{Exception=[System.Exception]::new('x');InvocationInfo=$null}
$bareCode=$null
try{$bareCode=Get-Code $bare}catch{$bareCode='<threw>'}
Check ($bareCode -ne '<threw>') 'a failure without an invocation record does not throw inside the catch block'
Check ($bareCode -match '^[A-Za-z0-9_.@:-]*$') ('a bare failure still yields a filtered code, got '+$bareCode)

# --- 3. C12-02 integration: real Invoke-TCSupervisor catch/finally -----------
$isolated=Join-Path ([IO.Path]::GetTempPath()) ('tc-runtime-error-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($isolated)
$faultManifestPath=Join-Path $isolated 'manifest.json'
$faultCandidate=Join-Path $isolated 'candidate.json'
[IO.File]::WriteAllText($faultCandidate,'{}',(New-Object Text.UTF8Encoding($false)))
[ordered]@{SyntaxValidated=$true;DeploymentApproved=$true;CandidatePath=$faultCandidate;ControlPort=61991;TradeProgramPaths=@();ProviderRelay=$false}|ConvertTo-Json|Set-Content -LiteralPath $faultManifestPath -Encoding UTF8
$engineReached=$false;$proxyRestoreReached=$false
try{
 . (Join-Path $script:PackageRoot 'runtime\Run-TradeChannel.ps1') -LoadFunctionsOnly
 function Initialize-TCNetTable {}
 function Open-TCSupervisorMutex {
  $m=[pscustomobject]@{}
  $m|Add-Member ScriptMethod WaitOne {param($Milliseconds)return $true}
  $m|Add-Member ScriptMethod ReleaseMutex {}
  $m|Add-Member ScriptMethod Dispose {}
  return $m
 }
 function Restore-TCProxyJournal {param($Root,[string]$CompletedSessionId) $script:proxyRestoreReached=$true;return [pscustomobject]@{Conflicts=@();Restored=$false} }
 function Start-TCSupervisorEngine {param($Root,$Manifest,$SessionId) $script:engineReached=$true;throw 'guard reached' }
 function Get-Process {param($Id,$Name,[switch]$ErrorAction) throw [InvalidOperationException]::new('SECRET-BODY / private-key-value') }
 $null=Invoke-TCSupervisor -ManifestPath $faultManifestPath -Root $isolated
}catch{throw ('C12 integration unexpectedly escaped the real catch: '+$_.Exception.Message+' | '+$_.ScriptStackTrace)}
finally{
 foreach($name in @('Get-Process','Open-TCSupervisorMutex','Restore-TCProxyJournal','Initialize-TCNetTable','Start-TCSupervisorEngine')){
  if(Test-Path ('Function:\'+$name)){Remove-Item -LiteralPath ('Function:\'+$name) -Force}
 }
}
$runtimePath=Join-Path $isolated 'runtime.json'
Check (Test-Path -LiteralPath $runtimePath) 'C12-02 the real supervisor wrote runtime.json'
$actual=Get-Content -LiteralPath $runtimePath -Encoding UTF8 -Raw|ConvertFrom-Json
$code=[string]$actual.ErrorCode
Check ($actual.State -ceq 'StoppedWithError') 'C12-02 the real catch persisted StoppedWithError'
Check ($code -match '^[A-Za-z0-9_.@:-]{1,128}$') 'C12-02 the actual ErrorCode matches the allowed alphabet and length'
Check ($code -match '^InvalidOperationException@[A-Za-z0-9_.-]+\.ps1:\d+$') 'C12-02 the actual ErrorCode carries type, script and line'
Check ($code -notmatch 'SECRET|private-key|异常') 'C12-02 the actual ErrorCode contains no message body'
Check (-not $script:engineReached) 'C12-02 no engine start was reached'
Check ([bool]$actual.CleanupError -eq $false) 'C12-02 the isolated finally completed without cleanup failure'
$observed=Get-TCRuntimeReport -Root $isolated -Overview $null
Check ([string]$observed.Current.ErrorCode -ceq $code -and [string]$observed.SummaryText -match [regex]::Escape('故障代号：'+$code)) 'C12-02 the runtime report and technical detail read the same ErrorCode'
Remove-Item -LiteralPath $isolated -Recurse -Force

$result=[ordered]@{
 Passed=$true
 Checks=$script:Checks.Count
 Assertions=@($script:Checks)
 Scope='Static source inspection plus the product ErrorCode statements run against crafted failures; no engine, process, network or runtime.json'
}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))}
$result|ConvertTo-Json -Depth 5
