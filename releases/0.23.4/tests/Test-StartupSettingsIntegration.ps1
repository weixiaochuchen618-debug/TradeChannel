#requires -Version 5.1
<#
Run in elevated Windows PowerShell 5.1. Import the actual Startup/UserSettings
modules; replace only the OS context and Task Scheduler COM-folder boundary.
Get/Set-TCStartup, ownership, ACL, manifest, file persistence and rollback all
execute unchanged. All files are disposable fixtures; executables are inert.
#>
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1 -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use Windows PowerShell 5.1 / .NET Framework.'}
$package=Split-Path $PSScriptRoot -Parent
$workspace=Join-Path ([IO.Path]::GetTempPath()) ('TC-StartupSettings-'+[guid]::NewGuid().ToString('N'))
$startup=$null;$user=$null
$checks=New-Object 'Collections.Generic.List[string]'
$states=New-Object 'Collections.Generic.List[object]'
$failures=New-Object 'Collections.Generic.List[object]'
function Check([bool]$Condition,[string]$Label){if(-not $Condition){throw ('Assertion failed: '+$Label)};$checks.Add($Label)}
function Check-State($Status,[bool]$Enabled,[bool]$Verified,[string]$Label){
 Check ($null -ne $Status -and $null -ne $Status.PSObject.Properties['Enabled'] -and $null -ne $Status.PSObject.Properties['Verified'] -and $null -ne $Status.PSObject.Properties['Detail']) ($Label+': complete startup contract')
 Check ($Status.Enabled -is [bool] -and $Status.Verified -is [bool] -and $Status.Detail -is [string] -and $Status.Enabled -eq $Enabled -and $Status.Verified -eq $Verified) ($Label+': exact boolean state')
 $states.Add([pscustomobject]@{Scenario=$Label;Enabled=$Status.Enabled;Verified=$Status.Verified;Detail=$Status.Detail})
}
function Reject([scriptblock]$Action,[string]$Code,[string]$Label){
 $failure=$null
 try{$null=& $Action}catch{$failure=$_}
 Check ($null -ne $failure -and $failure.Exception.Message -match ('^\[TC:'+([regex]::Escape($Code))+'\]')) ($Label+': '+$Code)
 $failures.Add([pscustomobject]@{Scenario=$Label;Code=$Code;Message=$failure.Exception.Message})
}
try{
 $startup=Import-Module (Join-Path $package 'Startup.psm1') -Force -PassThru -DisableNameChecking
 $user=Import-Module (Join-Path $package 'UserSettings.psm1') -Force -PassThru -DisableNameChecking
 $originalDefinitions=& $startup { @((Get-Command Get-TCStartup).Definition,(Get-Command Set-TCStartup).Definition) }
 $fixture=[pscustomobject]@{
  Context=[pscustomobject]@{UserSid='S-1-5-21-201-202-203-1001';IsAdministrator=$true;IsInteractive=$true;CommonAppData=(Join-Path $workspace 'common data')}
  TaskName='';Tasks=@{};Calls=(New-Object 'Collections.Generic.List[object]');Reads=0
  ReadFailure=$false;RegisterFailure=$false;FailRegistrationReadback=$false;PendingReadFailures=0;BadReadback=$false
 }
 $layout=& $startup {
  param($State,$TestRoot)
  $script:Fixture=$State
  $script:Folder=[pscustomobject]@{}
  $script:Folder|Add-Member ScriptMethod GetTask {
   param($Name)
   if($Name -cne $script:Fixture.TaskName){throw 'Unexpected task identity.'}
   $script:Fixture.Reads++
   if($script:Fixture.ReadFailure){throw [UnauthorizedAccessException]::new('fixture scheduler access denied')}
   if($script:Fixture.PendingReadFailures -gt 0){$script:Fixture.PendingReadFailures--;throw [UnauthorizedAccessException]::new('fixture registration readback denied')}
   if(-not $script:Fixture.Tasks.ContainsKey($Name)){throw [Runtime.InteropServices.COMException]::new('fixture task not found',-2147024894)}
   return $script:Fixture.Tasks[$Name]
  }
  $script:Folder|Add-Member ScriptMethod RegisterTask {
   param($Name,$Xml,$Flags,$UserId,$Password,$LogonType,$Sddl)
   if($Name -cne $script:Fixture.TaskName -or $UserId -cne $script:Fixture.Context.UserSid -or $null -ne $Password -or $LogonType -ne 3 -or $Flags -notin @(18,20)){throw 'Unexpected registration contract.'}
   $script:Fixture.Calls.Add([pscustomobject]@{Operation='Register';Name=$Name;Flags=$Flags;Xml=$Xml})
   if($script:Fixture.RegisterFailure){throw 'fixture registration failed'}
   if($Flags -eq 18 -and $script:Fixture.Tasks.ContainsKey($Name)){throw 'Create refused existing task.'}
   if($Flags -eq 20 -and -not $script:Fixture.Tasks.ContainsKey($Name)){throw 'Update refused missing task.'}
   $task=[pscustomobject]@{Name=$Name;Path=('\'+$Name);Enabled=$true;Xml=$Xml;Sddl=$Sddl}
   $task|Add-Member ScriptMethod GetSecurityDescriptor {param($Flags) if($Flags -ne 7){throw 'Unexpected security read.'};return $this.Sddl}
   $task|Add-Member ScriptMethod Run {throw 'Task execution forbidden.'}
   if($script:Fixture.BadReadback){$doc=[xml]$task.Xml;$doc.Task.Principals.Principal.LogonType='S4U';$task.Xml=$doc.OuterXml}
   $script:Fixture.Tasks[$Name]=$task
   if($script:Fixture.FailRegistrationReadback){$script:Fixture.PendingReadFailures=1}
   return $task
  }
  $script:Folder|Add-Member ScriptMethod DeleteTask {
   param($Name,$Flags)
   if($Name -cne $script:Fixture.TaskName -or $Flags -ne 0){throw 'Unexpected deletion contract.'}
   $script:Fixture.Calls.Add([pscustomobject]@{Operation='Delete';Name=$Name;Flags=$Flags;Xml=''})
   $script:Fixture.Tasks.Remove($Name)
  }
  function script:Get-TCStartupTaskFolder {return $script:Folder}
  function script:Get-TCStartupContext {return $script:Fixture.Context}
  $null=[IO.Directory]::CreateDirectory($TestRoot,(New-TCStartupAcl -Directory))
  New-TCStartupDirectory $script:Fixture.Context.CommonAppData
  Get-TCStartupLayout $script:Fixture.Context.UserSid $script:Fixture.Context.CommonAppData
 } $fixture $workspace
 $fixture.TaskName=$layout.TaskName
 $bindings=& $user { @((Get-Command Get-TCStartup).Module.Path,(Get-Command Set-TCStartup).Module.Path) }
 Check ($bindings.Count -eq 2 -and $bindings[0] -ceq $startup.Path -and $bindings[1] -ceq $startup.Path) 'UserSettings resolves both real Startup exports'
 Check ($fixture.Reads -eq 0 -and $fixture.Calls.Count -eq 0) 'Module imports do not read or mutate tasks'

 $source=Join-Path $workspace '安装包 source [fixture]'
 $settingsRoot=Join-Path $workspace 'settings'
 $null=[IO.Directory]::CreateDirectory($source);$null=[IO.Directory]::CreateDirectory($settingsRoot)
 $settingsPath=Join-Path $settingsRoot 'ui-settings.json'
 $utf8=New-Object Text.UTF8Encoding($true)
 $files=@('TradeChannel.exe','TradeChannel.ps1','Worker.ps1','RuntimeBridge.psm1','ProviderBridge.psm1','NodeStore.psm1','ServerSetup.psm1','Startup.psm1','ui\Shell.xaml','assets\sing-box.exe','assets\wg.exe',
  'runtime\Invoke-TradeChannel.ps1','runtime\Run-TradeChannel.ps1','runtime\Set-TradeChannelExit.ps1','runtime\Set-TradeChannelMode.ps1','runtime\Test-SelectedTradeExit.ps1','runtime\TradeChannel.Proxy.ps1','runtime\TradeChannel.Provider.ps1','runtime\TradeChannel.Providers.ps1','runtime\TradeChannel.ProviderSetup.ps1','runtime\Set-TradeChannelDaily.ps1','runtime\TradeChannel.Agents.ps1','runtime\Set-TradeChannelAgents.ps1','runtime\TradeChannel.State.ps1','runtime\TradeChannelGuard.cs',
  'LinuxServerSetup.psm1','linux\tradechannel_linux.py','linux\Invoke-LinuxConsole.ps1','ui\LinuxPages.ps1','runtime\TradeChannelGuard.dll','runtime\TCDevicePath.dll','runtime\TradeChannel.Components.ps1','runtime\TradeChannel.Diagnostics.ps1','runtime\Read-TradeChannel.ps1','ui\BackgroundJobs.ps1','WorkerContracts.psm1','WorkerErrors.psm1','ui\MemoryJobs.ps1','UserSettings.psm1','AutoConnect.psm1','runtime\TradeChannel.ProxyJournal.ps1')
 # 0.20.9 起网页层五个文件是 Get-TCStartupPackage 的必需校验项，夹具需包含它们。
 $files+=@('web\index.html','web\app.css','web\forms.css','web\app.js','web\tokens.css')
 # 0.22.0 起邀请页宿主与 0.20.11 起会话收尾脚本也在必需项里；夹具漏项会让
 # Get-TCStartup 直接报「产品包缺少必需校验项」，把功能问题误报成打包问题。
 $files+=@('ui\WebInvite.ps1','runtime\TradeChannel.SessionCleanup.ps1')
 foreach($relative in $files){
  $path=Join-Path $source $relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  if($relative -in @('Startup.psm1','UserSettings.psm1')){[IO.File]::Copy((Join-Path $package $relative),$path,$false)}
  else{[IO.File]::WriteAllText($path,('inert fixture: '+$relative),$utf8)}
 }
 $rows=@(foreach($relative in ($files|Sort-Object)){(Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256).Hash+'|'+$relative})
 [IO.File]::WriteAllLines((Join-Path $source 'package.sha256'),$rows,$utf8)

 $defaults=Get-TCUserSettings -Root $settingsRoot
 Check ($defaults.Source -ceq 'Default' -and -not $defaults.AutoConnectOnLogin) 'Absent settings default to manual connection'
 Check-State (Get-TCStartup) $false $true 'Default missing task'
 Check-State (Set-TCStartup -Enabled $false -SourceDirectory (Join-Path $workspace 'absent source')) $false $true 'Disable missing task'
 Check (-not [IO.File]::Exists($settingsPath) -and -not [IO.Directory]::Exists($layout.ProductRoot) -and $fixture.Calls.Count -eq 0) 'Default reads and absent disable create no settings, staging or task'

 $fixture.ReadFailure=$true
 Check-State (Get-TCStartup) $false $false 'Unreadable scheduler before first opt-in'
 Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupUnverified' 'Unreadable task blocks opt-in before writes'
 Check (-not [IO.File]::Exists($settingsPath) -and -not [IO.Directory]::Exists($layout.ProductRoot) -and $fixture.Calls.Count -eq 0) 'Read failure has no settings, staging or task writes'
 $fixture.ReadFailure=$false

 $foreignPlan=New-TCStartupPlan -UserSid $layout.UserSid -CommonAppData $layout.CommonAppData -OwnerId ('b'*32) -PackageHash ((Get-FileHash -LiteralPath (Join-Path $source 'package.sha256')).Hash)
 $foreign=[pscustomobject]@{Name=$layout.TaskName;Path=$layout.TaskFullName;Enabled=$true;Xml=$foreignPlan.Xml;Sddl=$foreignPlan.TaskSddl}
 $foreign|Add-Member ScriptMethod GetSecurityDescriptor {param($Flags) return $this.Sddl}
 $fixture.Tasks[$layout.TaskName]=$foreign
 Check-State (Get-TCStartup) $false $false 'Same-name task without ownership receipt'
 Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupUnverified' 'Foreign task without receipt blocks opt-in'
 Check ($fixture.Tasks[$layout.TaskName].Xml -ceq $foreignPlan.Xml -and $fixture.Calls.Count -eq 0 -and -not [IO.File]::Exists($settingsPath) -and -not [IO.Directory]::Exists($layout.ProductRoot)) 'Foreign task is neither adopted nor changed'
 $fixture.Tasks.Clear()

 $enabled=Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source
 Check ($enabled.Source -ceq 'Saved' -and $enabled.AutoConnectOnLogin) 'Real opt-in persists only after task verification'
 Check-State (Get-TCStartup) $true $true 'Enabled owned task'
 Check ($fixture.Calls.Count -eq 1 -and $fixture.Calls[0].Operation -ceq 'Register' -and $fixture.Calls[0].Flags -eq 18) 'Opt-in creates one interactive task through the real adapter'
 $null=Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source
 Check ($fixture.Calls.Count -eq 1) 'Already-enabled opt-in is idempotent'
 $reads=$fixture.Reads;$taskXml=$fixture.Tasks[$layout.TaskName].Xml
 $disabled=Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $false -SourceDirectory $source
 Check (-not $disabled.AutoConnectOnLogin -and $fixture.Reads -eq $reads -and $fixture.Calls.Count -eq 1 -and $fixture.Tasks[$layout.TaskName].Xml -ceq $taskXml) 'Disabling auto-connect leaves UI startup unchanged and requires no scheduler read'
 $settingsHash=(Get-FileHash -LiteralPath $settingsPath).Hash

 $fixture.ReadFailure=$true
 Check-State (Get-TCStartup) $false $false 'Unreadable scheduler with saved settings'
 Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupUnverified' 'Read error preserves saved settings'
 Check ((Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash -and $fixture.Calls.Count -eq 1) 'Read error preserves settings bytes and existing task'
 $fixture.ReadFailure=$false

 $task=$fixture.Tasks[$layout.TaskName];$doc=[xml]$task.Xml;$doc.Task.RegistrationInfo.Description=$foreignPlan.Description;$task.Xml=$doc.OuterXml
 Check-State (Get-TCStartup) $false $false 'Foreign owner marker with a local receipt'
 Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupUnverified' 'Ownership mismatch blocks opt-in'
 Check ((Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash -and $fixture.Calls.Count -eq 1 -and $task.Xml -ceq $doc.OuterXml) 'Foreign ownership is not replaced or deleted'
 $task.Xml=$taskXml
 $plan=& $startup {param($Layout) Get-TCStartupOwnedPlan (Read-TCStartupTask $Layout) $Layout} $layout
 $stagePayload=Join-Path $plan.PackageDirectory 'UserSettings.psm1';$payloadBytes=[IO.File]::ReadAllBytes($stagePayload)
 [IO.File]::WriteAllText($stagePayload,'tampered fixture payload',$utf8)
 Check-State (Get-TCStartup) $false $false 'Corrupt staged package'
 Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupUnverified' 'Manifest hash mismatch blocks opt-in'
 Check ((Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash -and $fixture.Calls.Count -eq 1) 'Package failure cannot rewrite settings or silently replace startup'
 [IO.File]::WriteAllBytes($stagePayload,$payloadBytes)

 $doc=[xml]$task.Xml;$doc.Task.Settings.Enabled='false';$task.Xml=$doc.OuterXml;$task.Enabled=$false
 Check-State (Get-TCStartup) $false $true 'Disabled owned task'
 $enabled=Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source
 Check ($enabled.AutoConnectOnLogin -and $fixture.Calls.Count -eq 2 -and $fixture.Calls[1].Flags -eq 20) 'Opt-in re-enables a verified disabled task through an owned update'
 Check-State (Get-TCStartup) $true $true 'Re-enabled owned task'
 $null=Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $false -SourceDirectory $source
 $settingsHash=(Get-FileHash -LiteralPath $settingsPath).Hash

 $calls=$fixture.Calls.Count;$taskXml=$fixture.Tasks[$layout.TaskName].Xml
 $held=[IO.File]::Open($settingsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 try{Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupSettingFailed' 'Save failure with previously enabled UI'}finally{$held.Dispose()}
 Check-State (Get-TCStartup) $true $true 'Previously enabled UI survives save failure'
 Check ($fixture.Calls.Count -eq $calls -and $fixture.Tasks[$layout.TaskName].Xml -ceq $taskXml -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) 'Save failure preserves previous enabled task and settings bytes'

 Check-State (Set-TCStartup -Enabled $false -SourceDirectory $source) $false $true 'Explicit startup disable'
 Check-State (Get-TCStartup) $false $true 'Confirmed absence after disable'
 $calls=$fixture.Calls.Count;$fixture.RegisterFailure=$true
 try{Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupSettingFailed' 'Registration failure before preference save'}finally{$fixture.RegisterFailure=$false}
 Check-State (Get-TCStartup) $false $true 'Registration failure leaves task absent'
 Check ($fixture.Calls.Count -eq ($calls+1) -and $fixture.Calls[$calls].Operation -ceq 'Register' -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) 'Failed registration never persists opt-in'

 foreach($prior in @('Absent','Disabled')){
  if($prior -ceq 'Disabled'){
   $null=Set-TCStartup -Enabled $true -SourceDirectory $source
   $task=$fixture.Tasks[$layout.TaskName];$doc=[xml]$task.Xml;$doc.Task.Settings.Enabled='false';$task.Xml=$doc.OuterXml;$task.Enabled=$false
  }
  Check-State (Get-TCStartup) $false $true ($prior+' before failed save')
  $calls=$fixture.Calls.Count
  $held=[IO.File]::Open($settingsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try{Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupSettingFailed' ($prior+': file save failure rolls back task')}finally{$held.Dispose()}
  Check-State (Get-TCStartup) $false $true ($prior+': rollback restores disabled UI startup')
  Check ($fixture.Calls.Count -eq ($calls+2) -and $fixture.Calls[$calls].Operation -ceq 'Register' -and $fixture.Calls[$calls+1].Operation -ceq 'Delete' -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) ($prior+': rollback verifies ownership and preserves settings bytes')
 }

 $calls=$fixture.Calls.Count;$fixture.FailRegistrationReadback=$true
 try{Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupSettingFailed' 'Registration readback failure invokes real rollback'}finally{$fixture.FailRegistrationReadback=$false}
 Check-State (Get-TCStartup) $false $true 'Owned task removed after transient readback failure'
 Check ($fixture.Calls.Count -eq ($calls+2) -and $fixture.Calls[$calls].Operation -ceq 'Register' -and $fixture.Calls[$calls+1].Operation -ceq 'Delete' -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) 'Readback failure preserves disabled preference after verified rollback'

 $calls=$fixture.Calls.Count;$fixture.BadReadback=$true
 try{Reject {Set-TCLoginAutoConnect -Root $settingsRoot -Enabled $true -SourceDirectory $source} 'StartupRollbackFailed' 'Changed task contract refuses unsafe rollback'}finally{$fixture.BadReadback=$false}
 Check-State (Get-TCStartup) $false $false 'Unowned readback cannot be reported as restored'
 Check ($fixture.Calls.Count -eq ($calls+1) -and $fixture.Tasks.ContainsKey($layout.TaskName) -and (Get-FileHash -LiteralPath $settingsPath).Hash -ceq $settingsHash) 'Rollback failure leaves mismatched task intact and never saves opt-in'
 Check (@(Get-ChildItem -LiteralPath $settingsRoot -File -Force|Where-Object {$_.Name -like '*.tmp'}).Count -eq 0) 'Failed preference writes leave no temporary files'
 Check (-not (Get-TCUserSettings -Root $settingsRoot).AutoConnectOnLogin) 'Final saved preference remains disabled'
 $definitions=& $startup { @((Get-Command Get-TCStartup).Definition,(Get-Command Set-TCStartup).Definition) }
 Check ($definitions[0] -ceq $originalDefinitions[0] -and $definitions[1] -ceq $originalDefinitions[1]) 'Get/Set-TCStartup implementations are unchanged throughout integration'
 Check (@($fixture.Calls|Where-Object {$_.Name -cne $layout.TaskName -or $_.Operation -notin @('Register','Delete')}).Count -eq 0) 'Only the fixture SID task is registered/deleted; nothing is run'
 $result=[pscustomobject]@{
  Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();States=$states.ToArray();ExpectedFailures=$failures.ToArray()
  PowerShell=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;CLR=[Runtime.InteropServices.RuntimeEnvironment]::GetSystemVersion()
  Modules=@([pscustomobject]@{Name='Startup';Path=$startup.Path;SHA256=(Get-FileHash -LiteralPath $startup.Path).Hash},[pscustomobject]@{Name='UserSettings';Path=$user.Path;SHA256=(Get-FileHash -LiteralPath $user.Path).Hash})
  MockedAdapters=@('Get-TCStartupContext','Get-TCStartupTaskFolder');RealLogic=@('Get-TCStartup','Set-TCStartup','Set-TCLoginAutoConnect','ACL checks','Ownership checks','Manifest checks','Settings persistence','Rollback')
  MockTaskReads=$fixture.Reads;MockTaskMutationAttempts=$fixture.Calls.Count;RealTaskReads=0;RealTaskChanges=0;RealNetworkChanges=0
 }
 if($ReportPath){$report=[IO.Path]::GetFullPath($ReportPath);$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($report));[IO.File]::WriteAllText($report,($result|ConvertTo-Json -Depth 10),$utf8)}
 $result|ConvertTo-Json -Depth 10
}finally{
 if($user){Remove-Module $user -ErrorAction SilentlyContinue}
 if($startup){Remove-Module $startup -ErrorAction SilentlyContinue}
 $full=[IO.Path]::GetFullPath($workspace).TrimEnd('\');$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-StartupSettings-[a-f0-9]{32}$'){throw 'Cleanup guard rejected fixture path.'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
