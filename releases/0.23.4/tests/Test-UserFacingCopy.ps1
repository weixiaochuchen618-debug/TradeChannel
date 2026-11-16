#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$PackageRoot='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run explicitly with Windows PowerShell 5.1.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$checks=New-Object 'Collections.Generic.List[string]'
$asts=@{}
function Check {param([bool]$Condition,[string]$Name)
 if(-not $Condition){throw ('User-facing copy FAILED: '+$Name)}
 $checks.Add($Name)
}
function CopyFunction {param([string]$Path,[string]$Name)
 $matches=@($asts[$Path].FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
 if($matches.Count -ne 1){throw ('Expected one source function: '+$Name)}
 return $matches[0]
}
function ImportCopyFunction {param([string]$Path,[string]$Name)
 $body=(CopyFunction $Path $Name).Body.Extent.Text
 Set-Item -LiteralPath ('Function:script:'+$Name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
}

# Read source only. Never initialize the app, a Worker, a store or live state.
$paths=@('ProductText.psm1','ui/DeploymentPages.ps1','ui/DeploymentCenterPages.ps1','ui/RuntimePages.ps1','ui/ManagementPages.ps1','ui/ServerPages.ps1','ui/PairingPages.ps1','ui/OperationHistoryPages.ps1','ui/WebTools.ps1')
$optional='ui/ConnectionPreviewPages.ps1'
if(Test-Path -LiteralPath (Join-Path $PackageRoot $optional)){$paths+=,$optional}
$copyIssues=New-Object 'Collections.Generic.List[string]'
foreach($relative in $paths){
 $path=Join-Path $PackageRoot $relative
 $bytes=[IO.File]::ReadAllBytes($path)
 Check ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ($relative+' keeps UTF-8 BOM')
 $tokens=$null;$errors=$null
 $asts[$relative]=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 Check (@($errors).Count -eq 0) ($relative+' parses with PowerShell 5.1')
 $strings=@($asts[$relative].FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -or $node -is [Management.Automation.Language.ExpandableStringExpressionAst]},$true))
 foreach($literal in $strings){
  if($literal.Value -notmatch '[\u4e00-\u9fff]' -or $literal.Value -notmatch '核对|候选|事务|摘要'){continue}
  # Exported diagnostics and coded identity errors retain their technical text.
  $technical=$false;$parent=$literal.Parent
  while($parent){
   if($parent -is [Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -ceq 'DeploymentDiagnosticSummary'){$technical=$true;break}
   if($parent -is [Management.Automation.Language.ThrowStatementAst] -and $literal.Value -match '^\[TC:'){$technical=$true;break}
   $parent=$parent.Parent
  }
  if(-not $technical){$copyIssues.Add($relative+':'+$literal.Extent.StartLineNumber+' '+$literal.Value)}
 }
}
Check ($copyIssues.Count -eq 0) ('Everyday copy uses concrete actions: '+($copyIssues -join '; '))
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
Check (@($errors).Count -eq 0) 'The regression script parses with PowerShell 5.1'

$catalog=Import-Module (Join-Path $PackageRoot 'ProductText.psm1') -Force -PassThru -DisableNameChecking
$copy=Get-TCTextCatalog
Check ($copy.GuardRetained -match '断开后仍阻止.*交易软件直连') 'Disconnect copy retains the trading direct-access guard'
Check ($copy.QualityNote -match '加密.*备用.*服务器响应.*不能直接比较') 'Quality copy explains why current and standby timings differ'
Check ((Get-TCText History) -ceq '操作记录' -and (Get-TCText Maintenance) -ceq '维护与恢复') 'Shared navigation uses everyday wording'
Remove-Module $catalog

$firstTrust=(CopyFunction 'ui/DeploymentPages.ps1' 'ShowDeploymentFirstTrustUI').Body.Extent.Text
Check ($firstTrust -match '云控制台.*可信来源.*指纹' -and $firstTrust -match '没有可信来源.*首次信任' -and $firstTrust -match '关闭窗口不会登录') 'First trust still requires a source decision and explains closing the dialog'
$reinstall=(CopyFunction 'ui/ServerPages.ps1' 'BeginServerReinstallUI').Body.Extent.Text
Check ($reinstall -match '重新输入登录资料' -and $reinstall -match '可信来源.*SSH 指纹' -and $reinstall -match '设备密钥、授权和已保存密码不继承') 'Reinstall copy preserves fresh credentials, trusted fingerprint and non-inherited authorization'
$reinstallTrust=(CopyFunction 'ui/ServerPages.ps1' 'ShowServerReinstallTrustUI').Body.Extent.Text
Check ($reinstallTrust -match '旧授权不能继续使用' -and $reinstallTrust -match '不会自动部署、重启服务或切换线路') 'New server identity cannot inherit old grants or trigger deployment'
$rollback=(CopyFunction 'ui/RuntimePages.ps1' 'ShowConfigurationRollbackResult').Body.Extent.Text
Check ($rollback -match '退出交易软件.*断开连接.*还原' -and $rollback -match '当前连接保持') 'Rollback still explains the maintenance boundary and preparation behavior'
$pairing=(CopyFunction 'ui/PairingPages.ps1' 'ShowProductPairing').Body.Extent.Text
Check ($pairing -match '设备名称和识别码.*完整资料' -and $pairing -match '签名有效不代表首次邀请来源可信') 'Pairing keeps manual identity comparison and source verification'
$serverSource=$asts['ui/ServerPages.ps1'].Extent.Text
Check ($serverSource -match 'TCP 外层 UUID 当前共享，不会自动轮换。撤销不能通过旧申请恢复。') 'Device revocation still explains the shared TCP credential limitation'
Check ($serverSource -match '卸载不会退订云服务器.*仍会计费') 'Server uninstall still explains ongoing cloud charges'

# Render the maintenance page against in-memory presentation boundaries only.
$script:Rows=New-Object 'Collections.Generic.List[object]'
$script:Controls=@{};$script:HostPanel=[pscustomobject]@{}
$script:Ink='#111111';$script:Overview=@{UpgradeAvailable=$true};$script:Providers=@{RequiresUpgrade=$false}
$script:Dialog=$null;$script:Jobs=0
function PageHead {param($Title,$Description,$Page)$script:Rows.Clear();$script:Controls=@{}}
function Card {return [pscustomobject]@{Child=$null}}
function Stack {return [pscustomobject]@{}}
function T {param($Text,$Size,$Color,$Weight)return [string]$Text}
function Rule {return 'rule'}
function AddC {param($Parent,$Child)}
function SectionLabel {param($Parent,$Text)}
function Btn {param($Text,$Id,$Action,$Style)
 $button=[pscustomobject]@{Content=[string]$Text;Action=$Action;IsEnabled=$true}
 if($Id){$script:Controls[$Id]=$button};return $button
}
function SettingRow {param($Parent,$Title,$Description,$Button)
 $script:Rows.Add([pscustomobject]@{Title=[string]$Title;Description=[string]$Description;Button=$Button})
}
function OpenDialog {param($Title,$Body,$Note,$Confirm,$Action,$Cancel,$Style)
 $script:Dialog=[pscustomobject]@{Title=$Title;Body=$Body;Note=$Note;Confirm=$Confirm;Action=$Action}
}
function StartJob {$script:Jobs++;throw 'Copy tests must not dispatch jobs.'}
ImportCopyFunction 'ui/WebTools.ps1' 'ShowTCWebMaintenance'
ShowTCWebMaintenance
Check ($script:Rows.Count -eq 7) 'Maintenance keeps all seven existing actions'
foreach($row in $script:Rows){
 Check ($row.Description.Length -le 55 -and $row.Button.Content.Length -le 20) ($row.Title+' uses a short explanation and action')
 Check ($row.Description -cne $row.Title -and $row.Description -cne $row.Button.Content) ($row.Title+' does not repeat its title or button')
}
& $script:Controls.WebRepairState.Action
Check ($script:Dialog.Body -match '断开连接' -and $script:Dialog.Body -match '交易保护保留' -and $script:Dialog.Body -match '重新连接' -and $script:Dialog.Note -match '退出交易软件') 'Repair dialog preserves disconnection, protection and trading-exit consequences'
& $script:Controls.WebRemoveProtection.Action
Check ($script:Dialog.Body -match '停止连接.*允许交易软件直接使用本地网络' -and $script:Dialog.Note -match '退出交易软件.*日常断开无需解除保护') 'Protection removal explains direct access and preserves the normal-disconnect distinction'
$script:Overview.UpgradeAvailable=$false
ShowTCWebMaintenance
Check (-not $script:Controls.WebUpgradeConfiguration.IsEnabled) 'Configuration update remains unavailable when no update is needed'
Check ($script:Jobs -eq 0) 'Viewing maintenance and confirmation copy dispatches no work'
[pscustomobject]@{Passed=$true;Suite='UserFacingCopy';Runtime=$PSVersionTable.PSVersion.ToString();Checks=$checks.Count;SourceFiles=$paths.Count;NetworkRequests=0;ProductionStateRead=$false;WorkerLaunched=$false;Assertions=$checks.ToArray()} | ConvertTo-Json -Depth 5
