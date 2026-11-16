#requires -Version 5.1
# Source-level guards for the 0.20.6 performance work.
#
# These are contract assertions, not behavioural ones: they lock the two invariants
# that are easy to break by accident and expensive to notice in the field.
#
#   1. The 250 ms tick must gate SyncTCWebState on real window visibility.
#   2. UpdateTCLineQuality must stay OUTSIDE that gate - it owns the tray balloon
#      that tells the user a line degraded while the console was hidden.
#
# They also pin the read-worker reuse policy and the static snapshot projection.
param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent),[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0
function Check {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function Get-ParsedAst {param([string]$Path)
 $errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$null,[ref]$errors)
 if($errors -and $errors.Count){throw ('Syntax errors in '+$Path+': '+$errors[0].Message)}
 $ast
}
function Get-FunctionText {param($Ast,[string]$Name)
 $fn=$Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)|Select-Object -First 1
 if(-not $fn){throw ('Function not found: '+$Name)}
 $fn.Extent.Text
}

$main=Get-ParsedAst (Join-Path $PackageRoot 'TradeChannel.ps1')
$shell=Get-ParsedAst (Join-Path $PackageRoot 'ui\WebShell.ps1')
$jobs=Get-ParsedAst (Join-Path $PackageRoot 'ui\BackgroundJobs.ps1')

# --- 1. tick 快照门控 -------------------------------------------------------
$tickCalls=@($main.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member.Value -ceq 'Add_Tick'},$true))
Check ($tickCalls.Count -ge 1) 'TradeChannel.ps1 no longer registers a DispatcherTimer tick'
# 文件里还有一个 Toast 定时器，按内容挑出 250 ms 主 tick，而不是按出现顺序。
$tickCall=@($tickCalls|Where-Object {$_.Extent.Text -match 'ContinueTCWebConnection'})|Select-Object -First 1
Check ([bool]$tickCall) 'main tick (ContinueTCWebConnection) not found'
$tickBlock=$tickCall.Arguments|Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]}|Select-Object -First 1
Check ([bool]$tickBlock) 'tick handler is not a scriptblock'
$tickStatements=@($tickBlock.ScriptBlock.EndBlock.Statements|ForEach-Object {$_.Extent.Text})
$directSync=@($tickStatements|Where-Object {$_ -match '^\s*SyncTCWebState'})
Check ($directSync.Count -eq 0) 'SyncTCWebState is called unconditionally in the tick; the hidden-state gate was removed'
$gate=@($tickStatements|Where-Object {$_ -match 'IsVisible'})
Check ($gate.Count -ge 1) 'tick no longer reads Window.IsVisible'
Check ($gate[0] -match 'Minimized') 'tick gate ignores WindowState=Minimized; a minimized window still reports IsVisible=true'
Check ($gate[0] -match 'SyncTCWebState') 'the visibility gate no longer wraps SyncTCWebState'
Check ($gate[0] -match 'WebSyncTick' -and $gate[0] -match '-band\s+1') 'snapshot is not throttled through WebSyncTick/-band 1'
Check ($gate[0] -match 'WebSyncTick\s*=\s*0' -or $gate[0] -match 'else\{\s*\$script:WebSyncTick\s*=\s*0') 'the tick counter is not reset while hidden; restore would wait a full period'
$checks+=5

# --- 2. 托盘提醒必须留在门控之外 ---------------------------------------------
$directQuality=@($tickStatements|Where-Object {$_ -match '^\s*UpdateTCLineQuality\s*$'})
Check ($directQuality.Count -eq 1) 'UpdateTCLineQuality is no longer a direct tick statement; hiding the window would silence tray line warnings'
$qualityText=Get-FunctionText $shell 'UpdateTCLineQuality'
Check ($qualityText -match 'ShowBalloonTip') 'UpdateTCLineQuality lost the tray balloon that depends on hidden-state sampling'
Check ($qualityText -match '\$qualityInterval\s*=\s*if\([^)]*IsVisible[^)]*\)\s*\{\s*30\s*\}\s*else\s*\{\s*60\s*\}') 'quality sampling is not tiered 30s visible / 60s hidden'
$checks+=3

# --- 3. 静态投影缓存 ---------------------------------------------------------
# 缓存初始化块里本来就会调用 Get-TCTextCatalog，所以要精确检查"下发给前端的
# 快照哈希表"里这两个键的值，而不是整段函数文本。
$snapshotFn=$shell.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'GetTCWebSnapshot'},$true)|Select-Object -First 1
Check ([bool]$snapshotFn) 'GetTCWebSnapshot not found'
$snapshotTable=$snapshotFn.FindAll({param($n)
 if($n -isnot [Management.Automation.Language.HashtableAst]){return $false}
 $keys=@($n.KeyValuePairs|ForEach-Object {[string]$_.Item1.Value})
 ($keys -contains 'Text') -and ($keys -contains 'Version')
},$true)|Select-Object -Last 1
Check ([bool]$snapshotTable) 'snapshot hashtable (Text+Version) not found'
$textEntry=@($snapshotTable.KeyValuePairs|Where-Object {[string]$_.Item1.Value -ceq 'Text'})[0]
$cmEntry=@($snapshotTable.KeyValuePairs|Where-Object {[string]$_.Item1.Value -ceq 'ConnectionMethods'})[0]
Check ([string]$textEntry.Item2.Extent.Text -match 'WebStaticProjection\.Text') 'snapshot Text still rebuilt instead of using the cached projection'
Check ([string]$cmEntry.Item2.Extent.Text -match 'WebStaticProjection\.ConnectionMethods') 'snapshot ConnectionMethods still rebuilt instead of using the cached projection'
Check ($shell.Extent.Text -match '\$script:WebStaticProjection\s*=\s*\$null') 'WebStaticProjection has no initialiser, so the cache would leak between shell resets'
$checks+=3

# --- 4. 读 worker 复用与回收 -------------------------------------------------
Import-Module (Join-Path $PackageRoot 'WorkerContracts.psm1') -DisableNameChecking
foreach($action in @('Overview','Providers','Agents','LineQuality','StandbyQuality','Nodes')){
 Check ((Get-TCWorkerActionContract $action).ReuseReadProcess) ('read action not reused by the shared reader: '+$action)
}
foreach($action in @('DeploymentPoll','DeploymentSessionSnapshot','ConnectionSwitchCommit','ServerApply')){
 Check (-not (Get-TCWorkerActionContract $action).ReuseReadProcess) ('non-read or lease-bound action must not share the reader: '+$action)
}
$checks+=2
$startText=Get-FunctionText $jobs 'StartUiReadRequest'
Check ($startText -match 'Requests') 'StartUiReadRequest does not count requests, so the reader can never be recycled'
Check ($startText -match 'Started') 'StartUiReadRequest does not record a start time, so lifetime recycling is impossible'
Check ($startText -match '-ge\s+400' -and $startText -match '-ge\s+90') 'reader recycle thresholds (400 requests / 90 minutes) are missing'
$checks+=3

# --- 5. 读会话白名单必须与复用白名单同步 -------------------------------------
# Worker.ps1 里还有一份独立的 ReadSession 动作白名单。只改 ReuseReadProcess 而不
# 改它，动作会被路由到共享读进程然后以 ReadActionNotAllowed 失败——这是 0.20.6
# 实施时真实踩到的坑，所以用断言钉死两份名单的一致性。
$workerText=[IO.File]::ReadAllText((Join-Path $PackageRoot 'Worker.ps1'))
$allow=[regex]::Match($workerText,"-notin @\('Overview'[^)]*\)")
Check ($allow.Success) 'Worker.ps1 read-session action allowlist not found'
foreach($action in @('LineQuality','StandbyQuality','Nodes')){
 Check ($allow.Value -match ("'"+$action+"'")) ('Worker.ps1 read-session allowlist is missing '+$action+'; the shared reader will reject it with ReadActionNotAllowed')
}
$checks+=1

$result=[pscustomobject]@{Passed=$true;Checks=$checks;Suite='PerfGuards'}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$result|ConvertTo-Json
