#requires -Version 5.1
[CmdletBinding()]param([string]$ReportDirectory='')
$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Windows.Forms
$package=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $package 'ProductText.psm1') -Force -DisableNameChecking
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $package 'ui\WebShell.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'WebShell parse failed'}
foreach($name in @('WebField','RequestTCLineConnection','UpdateTCTrayLines','ContinueTCWebConnection')){
    $fn=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -ceq $name)[0]
    Invoke-Expression $fn.Extent.Text
}
$script:Checks=0;$script:Requests=New-Object 'Collections.Generic.List[string]';$script:Busy=$false;$script:ReadOnly=$false;$script:WebPendingConnection=$null
# ContinueTCWebConnection reads this budget from WebShell.ps1's script scope, which
# this harness does not load. Without it the pending choice is treated as expired
# on the first poll, so the deferral assertions below could never pass.
$script:WebPendingBudgetSeconds=300
function Check {param($Ok,[string]$Name)if(-not $Ok){throw $Name};$script:Checks++}
function IsBusy {$script:Busy}
function UILineId {param($Node)$Node.LineId}
function StartLineConnectionPreview {param($Id,$Profile)$script:Requests.Add($Id)}
function ShowExistingConsole {}
function SyncTCWebState {param([switch]$Force)}
function Toast {param($Text)$script:LastToast=$Text}
function StopLoginAutoConnectUI {}
function OnTrade {param($Value)$script:Requests.Add($Value)}
$script:Overlay=[pscustomobject]@{Visibility='Collapsed'}
$script:Window=New-Object PSObject;$script:Window|Add-Member ScriptMethod FindName {param($Name)$script:Overlay}
$script:TrayLineMenu=New-Object Windows.Forms.ToolStripMenuItem('选择线路');$script:TrayConnectItem=New-Object Windows.Forms.ToolStripMenuItem('连接')
$one='11111111-1111-1111-1111-111111111111';$two='22222222-2222-2222-2222-222222222222'
$script:Nodes=@([pscustomobject]@{LineId=$one;Name='Tokyo';ServerConnectionBlock=$false},[pscustomobject]@{LineId=$two;Name='Singapore';ServerConnectionBlock=$false})
$script:Overview=[pscustomobject]@{Running=$true;ReadState='Known';ActiveLineId=$one;Exit='hk';NinjaRunning=$false;SessionId='session-one'}
try{
    UpdateTCTrayLines
    Check ($script:TrayLineMenu.DropDownItems.Count -eq 2) 'Tray lists actual saved lines'
    Check ($script:TrayLineMenu.DropDownItems[0].Checked -and -not $script:TrayLineMenu.DropDownItems[0].Enabled) 'Current line is marked and cannot be redundantly selected'
    Check ($script:TrayConnectItem.Text -eq '断开连接') 'Tray action describes the actual action'
    $script:TrayLineMenu.DropDownItems[1].PerformClick()
    Check ($script:Requests.Count -eq 1 -and $script:Requests[0] -ceq $two) 'Tray uses the same guarded connection preview as the homepage'
    $script:Overview.NinjaRunning=$true;RequestTCLineConnection $two
    Check ($script:Requests.Count -eq 1 -and $script:WebPendingConnection.Id -ceq $two) 'Running trading app defers rather than restarts the connection'
    $script:Overview.NinjaRunning=$false;ContinueTCWebConnection
    Check ($script:Requests.Count -eq 2 -and -not $script:WebPendingConnection) 'App exit continues the pending choice exactly once'
    ContinueTCWebConnection;Check ($script:Requests.Count -eq 2) 'Polling cannot replay a completed choice'
    $script:Overview.NinjaRunning=$true;RequestTCLineConnection $two;$script:Overview.SessionId='session-two';ContinueTCWebConnection
    Check (-not $script:WebPendingConnection -and $script:Requests.Count -eq 2) 'A changed session invalidates a pending choice'
    $script:Overview.NinjaRunning=$false;$script:Overview.Exit='provider';RequestTCLineConnection $one
    Check ($script:Requests[2] -ceq ('node:'+$one)) 'Returning from a proxy keeps the existing hot-switch flow'
    $script:ReadOnly=$true;UpdateTCTrayLines
    Check (-not $script:TrayLineMenu.DropDownItems[1].Enabled -and -not $script:TrayConnectItem.Enabled) 'Read-only window cannot request a tray mutation'
    $script:ReadOnly=$false;$script:Busy=$true;RequestTCLineConnection $two
    Check ($script:Requests.Count -eq 3) 'Busy connection queue rejects a duplicate choice'
    $script:Busy=$false;$script:Nodes=@();UpdateTCTrayLines
    Check ($script:TrayLineMenu.DropDownItems.Count -eq 1 -and -not $script:TrayLineMenu.DropDownItems[0].Enabled) 'Empty list has one inert informative item'
    $result=[pscustomobject]@{Passed=$true;Checks=$script:Checks;RealNetworkChanges=0}
    if($ReportDirectory){$null=[IO.Directory]::CreateDirectory($ReportDirectory);[IO.File]::WriteAllText((Join-Path $ReportDirectory 'tray-lines.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))}
    $result
}finally{$script:TrayLineMenu.Dispose();$script:TrayConnectItem.Dispose()}
