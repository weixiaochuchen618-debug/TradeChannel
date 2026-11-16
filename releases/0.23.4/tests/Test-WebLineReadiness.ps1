#requires -Version 5.1
# 0.22.0 C-R3 / C-R8 acceptance for GetTCWebLineReadiness.
#
# The browser only renders what the host decides, so the interesting rules live
# here: which evidence makes a disconnected line say 「上次连接正常」 instead of
# 「未测试」, when a changed configuration has to fall back to 「未测试」, and when
# a running line is really not in use because the trading exit sits on the
# provider. run-ui.js proves the rendering of these states; this fixture proves
# the states themselves.
#
# It loads the real ui/WebShell.ps1 and replaces only the two boundaries that need
# a file on disk and the eligibility engine. No directory, worker or network call
# is created.
[CmdletBinding()]param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$script:Root=Join-Path ([IO.Path]::GetTempPath()) ('tc-web-readiness-'+[guid]::NewGuid().ToString('N'))
$script:Checks=New-Object 'Collections.Generic.List[string]'
function Check {param([bool]$Condition,[string]$Name)if(-not $Condition){throw ('FAILED: '+$Name)};$script:Checks.Add($Name)}

. (Join-Path $script:PackageRoot 'ui\WebShell.ps1')

# ---- boundaries -----------------------------------------------------------------
# UILineId lives in ui/ConnectionProfilePages.ps1; the readiness projection only
# needs the same three-field lookup.
function UILineId {param($Line) return [string](WebField $Line LineId (WebField $Line id ''))}
function Get-TCConnectionEligibility {param($Line,$Profile) return [pscustomobject]@{CanConnect=$true;Message=''} }
# The success record is a file on disk in production. Counting the reads also
# proves the 30 second cache (C-R3 第 4 条).
$script:SuccessRecord=$null
$script:SuccessReads=0
function Get-TCLastSuccessfulConnection {param([string]$Root) $script:SuccessReads=$script:SuccessReads+1;return $script:SuccessRecord }
function Reset-Cache { $script:WebLastSuccessCache=$null }

# ---- fixture --------------------------------------------------------------------
$script:Candidate='a'*64
$script:Manifest='b'*64
function NewProfile {
 param([string]$Id='Tcp',[string]$Validation='',[string]$Candidate=$script:Candidate,[string]$Manifest=$script:Manifest)
 return [pscustomobject]@{Id=$Id;PreparationState='Ready';CandidateSHA256=$Candidate;ManifestSHA256=$Manifest;Revision=3;Validation=[pscustomobject]@{Status=$Validation}}
}
function NewLine {
 param($Profile,[string]$SavedProfile='Tcp',[string]$Source='UserChoice',[string[]]$Aliases=@())
 return [pscustomobject]@{LineId='L1';AliasIds=$Aliases;Profiles=@($Profile);SavedConnectionPreference=[pscustomobject]@{ProfileId=$SavedProfile;Source=$Source};Recommendation=[pscustomobject]@{Status=''}}
}
function NewOverview {
 param([bool]$Running=$false,[string]$Exit='hk',[string]$Active='')
 return [pscustomobject]@{Running=$Running;Exit=$Exit;ActiveLineId=$Active;NodeId=''}
}
function NewRecord {
 param([string]$NodeId='L1',[string]$ProfileId='Tcp',[string]$Candidate=$script:Candidate,[string]$Manifest=$script:Manifest,[string]$At='')
 if(-not $At){$At=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o')}
 return [pscustomobject]@{SchemaVersion=1;SucceededAtUtc=$At;NodeId=$NodeId;ProfileId=$ProfileId
  Binding=[pscustomobject]@{CandidateSHA256=$Candidate;ManifestSHA256=$Manifest}}
}

# ---- C3-02: nothing to go on ---------------------------------------------------
Reset-Cache;$script:SuccessRecord=$null
$line=NewLine (NewProfile);$overview=NewOverview
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'Untested') 'C3-02 从未连接也从未测试的线路是「未测试」'
Check ($r.Label -eq '未测试') 'C3-02 标签是「未测试」'

# ---- C3-01: a matching success record is evidence -------------------------------
Reset-Cache;$script:SuccessRecord=NewRecord
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'LastConnected') 'C3-01 有匹配的成功记录时是 LastConnected'
Check ($r.Label -eq '上次连接正常') 'C3-01 标签是「上次连接正常」'
Check ($r.Reason -match '^上次连接于 \d{2}-\d{2} \d{2}:\d{2}$') ('C3-01 原因带上次连接时间：'+$r.Reason)
Check ($r.State -notin @('Untested','TestFailed')) 'C3-01 不再退回「未测试」'

# 别名同样算数（线路改过 ID 但别名还在）。
Reset-Cache
$r=GetTCWebLineReadiness (NewLine (NewProfile) -Aliases @('OLD')) $overview 'Tcp'
Check ($r.State -eq 'LastConnected') 'C3-01 别名命中也算成功证据'

# ---- C3-03: configuration changed ----------------------------------------------
Reset-Cache;$script:SuccessRecord=NewRecord -Candidate ('c'*64)
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'Untested') 'C3-03 候选哈希变了就回到「未测试」'
Reset-Cache;$script:SuccessRecord=NewRecord -Manifest ('d'*64)
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'Untested') 'C3-03 清单哈希变了就回到「未测试」'
Reset-Cache;$script:SuccessRecord=NewRecord -ProfileId='Udp'
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'Untested') 'C3-03 换了一套连接方式就不算这条方式的证据'
Reset-Cache;$script:SuccessRecord=NewRecord -NodeId='L2'
$r=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($r.State -eq 'Untested') 'C3-03 别的线路的成功记录不算数'

# ---- C3-04: a later failed test wins -------------------------------------------
Reset-Cache;$script:SuccessRecord=NewRecord
$r=GetTCWebLineReadiness (NewLine (NewProfile -Validation 'Failed')) $overview 'Tcp'
Check ($r.State -eq 'TestFailed') 'C3-04 成功之后又测试失败，显示「上次测试未通过」'
Check ($r.Label -eq '上次测试未通过') 'C3-04 标签是「上次测试未通过」'

# 通过过的测试仍然优先于「上次连接正常」（它是更强的证据）。
Reset-Cache;$script:SuccessRecord=NewRecord
$r=GetTCWebLineReadiness (NewLine (NewProfile -Validation 'Passed')) $overview 'Tcp'
Check ($r.State -eq 'Verified') 'C3-04 已通过的测试优先于上次连接记录'

# ---- C-R3 第 4 条：30 秒缓存 ----------------------------------------------------
Reset-Cache;$script:SuccessRecord=NewRecord;$script:SuccessReads=0
$null=GetTCWebLineReadiness $line $overview 'Tcp'
$null=GetTCWebLineReadiness $line $overview 'Tcp'
$null=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($script:SuccessReads -eq 1) ('30 秒内只读一次成功记录，实际 '+$script:SuccessReads+' 次')
# 缓存过期后重新读（把时间戳往前拨 31 秒，不 sleep）。
$script:WebLastSuccessCache.At=$script:WebLastSuccessCache.At.AddSeconds(-31)
$null=GetTCWebLineReadiness $line $overview 'Tcp'
Check ($script:SuccessReads -eq 2) '缓存过期后会重新读一次'

# ---- C-R8：交易走代理软件时不算在用 ---------------------------------------------
Reset-Cache;$script:SuccessRecord=NewRecord
$script:Nodes=@($line)
$backup=NewOverview -Running $true -Exit 'Provider' -Active 'L1'
$r=GetTCWebLineReadiness $line $backup 'Tcp'
Check ($r.State -eq 'ProviderBackup') 'C8-01 交易出口不是自建线路时是 ProviderBackup'
Check ($r.Label -eq '交易暂走代理软件') 'C8-01 标签是「交易暂走代理软件」'
Check (-not (TestTCWebLineInUse 'L1')) 'C8-01 这种状态下不算在用'
$inUse=NewOverview -Running $true -Exit 'hk' -Active 'L1'
$script:Overview=$inUse
$r=GetTCWebLineReadiness $line $inUse 'Tcp'
Check ($r.State -eq 'InUse') 'C8-01 交易出口回到自建线路时才是「使用中」'
Check (TestTCWebLineInUse 'L1') 'C8-01 在用判定为真'
Check (-not (TestTCWebLineInUse 'L2')) 'C8-01 别的线路不算在用'

# ---- C-R8：connect 是否走「只切 selector」的路径 ---------------------------------
$script:Overview=$backup
function CanReturnHongKong { return $true }
Check (TestTCWebProviderBackupReturn 'L1') 'C8-02 交易走代理软件且可以切回时走 QuickHongKong'
function CanReturnHongKong { return $false }
Check (-not (TestTCWebProviderBackupReturn 'L1')) 'C8-02 不能切回时走普通连接流程'
function CanReturnHongKong { return $true }
$script:Overview=$inUse
Check (-not (TestTCWebProviderBackupReturn 'L1')) 'C8-02 交易已在自建线路上时不需要切回'
$script:Overview=NewOverview
Check (-not (TestTCWebProviderBackupReturn 'L1')) 'C8-02 未连接时不走切回路径'

# ---- C-R7：在用线路的测速在宿主侧就被挡住 ---------------------------------------
$script:Overview=$inUse
Check (TestTCWebLineInUse 'L1') 'C7-02 在用线路的 testLine 会被宿主直接拒绝'
$script:Overview=NewOverview
Check (-not (TestTCWebLineInUse 'L1')) 'C7-02 未连接时 testLine 正常执行'

$result=[pscustomobject]@{Passed=$true;Checks=$script:Checks.Count;Names=$script:Checks.ToArray();Failure=$null}
$result|ConvertTo-Json -Depth 4 -Compress
