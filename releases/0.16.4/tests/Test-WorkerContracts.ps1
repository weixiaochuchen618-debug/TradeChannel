#requires -Version 5.1
param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent),[string]$ReportPath)
$ErrorActionPreference='Stop';$checks=0;$rows=@()
Import-Module (Join-Path $PackageRoot 'WorkerContracts.psm1') -DisableNameChecking
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageRoot 'Worker.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Worker syntax invalid'}
$switch=$ast.FindAll({param($n)$n -is [Management.Automation.Language.SwitchStatementAst]},$true)|Select-Object -First 1
foreach($clause in $switch.Clauses){
 $names=@($clause.Item1.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object Value)
 $commands=@($clause.Item2.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_ -match '-TC'}|Select-Object -Unique)
 foreach($name in $names){$contract=Get-TCWorkerActionContract $name;if(-not $contract.Known){throw ('Unregistered action '+$name)};$rows+=,[pscustomobject]@{Action=$name;Modules=$contract.Modules;Commands=$commands};$checks++}
}
if(@(Compare-Object @(Get-TCWorkerActionNames) @($rows.Action)).Count){throw 'Contract and dispatcher actions differ'};$checks++
foreach($row in $rows){
 $ps=[PowerShell]::Create()
 try{
  $null=$ps.AddScript({param($root,$modules,$commands,$action)
   $ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
   foreach($module in $modules){Import-Module (Join-Path $root $module) -DisableNameChecking}
   if($action -like 'ProxyRecovery*'){. (Join-Path $root 'runtime\TradeChannel.ProxyJournal.ps1')}
   foreach($command in $commands){$null=Get-Command $command -ErrorAction Stop}
   'Resolved'
  }).AddArgument($PackageRoot).AddArgument($row.Modules).AddArgument($row.Commands).AddArgument($row.Action)
  $result=@($ps.Invoke())
  if($ps.HadErrors -or $result[-1] -ne 'Resolved'){throw ('Action dependency missing: '+$row.Action+' / '+($ps.Streams.Error|ForEach-Object {$_.ToString()}))};$checks++
 }finally{$ps.Dispose()}
}
if((Get-TCWorkerActionContract Overview).Modules -contains 'ServerSetup.psm1' -or (Get-TCWorkerActionContract Overview).Modules -contains 'Startup.psm1'){throw 'Overview loaded unrelated deployment modules'};$checks++
foreach($action in @('ConnectionSwitchCommit','DeploymentProceed','ServerApply','LineNetworkUpdate','RemoveProtection')){if((Get-TCWorkerActionContract $action).ReadOnly -or (Get-TCWorkerActionContract $action).ReuseReadProcess){throw 'Mutation assigned to read termination policy'};$checks++}
$result=[pscustomobject]@{Passed=$true;Actions=$rows.Count;Checks=$checks;FreshRunspaces=$rows.Count;ActionsExecuted=0;NetworkChanges=0}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$result|ConvertTo-Json
