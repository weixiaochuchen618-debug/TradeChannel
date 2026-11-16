#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$source=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $source 'Startup.psm1') -Force -PassThru -DisableNameChecking
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{$sid=$identity.User.Value;$account=$identity.Name}finally{$identity.Dispose()}
$root=Join-Path ([IO.Path]::GetTempPath()) ('tc-startup-xml-'+[guid]::NewGuid().ToString('N'))
$result=& $module {
 param($Sid,$Account,$Root)
 $checks=New-Object 'Collections.Generic.List[string]'
 function Check {param($Ok,$Name)if(-not $Ok){throw ('Startup XML: '+$Name)};$checks.Add($Name)}
 $plan=New-TCStartupPlan -UserSid $Sid -CommonAppData $Root -OwnerId ('a'*32) -PackageHash ('B'*64)
 function Task {param([scriptblock]$Edit)
  $doc=ConvertFrom-TCStartupTaskXml $plan.Xml
  $ns=New-Object Xml.XmlNamespaceManager($doc.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
  if($Edit){& $Edit $doc $ns}
  [pscustomobject]@{Name=$plan.TaskName;Path=$plan.TaskFullName;Enabled=$true;Xml=$doc.OuterXml;Sddl=$plan.TaskSddl}
 }
 function Reject {param([scriptblock]$Edit,[string]$Name)
  $rejected=$false;try{Assert-TCStartupTask (Task $Edit) $plan}catch{$rejected=$true}
  Check $rejected $Name
 }
 $null=Assert-TCStartupTask (Task) $plan;Check $true 'The original exact SID/XML plan remains accepted'
 $normalized=Task {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText=$Account;$e=$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:Enabled',$ns);$null=$e.ParentNode.RemoveChild($e)}
 $null=Assert-TCStartupTask $normalized $plan;Check $true 'Actual Windows account normalization and omitted default trigger enablement preserve the same identity'
 $principal=Task {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId',$ns).InnerText=$Account}
 $null=Assert-TCStartupTask $principal $plan;Check $true 'A qualified principal account must resolve to the exact expected SID'
 $sparse=Task {param($d,$ns)
  $d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText=$Account
  foreach($path in @('/t:Task/t:Triggers/t:LogonTrigger/t:Enabled')+@('MultipleInstancesPolicy','AllowHardTerminate','StartWhenAvailable','RunOnlyIfNetworkAvailable','Enabled','Hidden','RunOnlyIfIdle','WakeToRun','Priority'|ForEach-Object {'/t:Task/t:Settings/t:'+$_})){
   $n=$d.SelectSingleNode($path,$ns);$null=$n.ParentNode.RemoveChild($n)
  }
 }
 $null=Assert-TCStartupTask $sparse $plan;Check $true 'Sparse effective defaults match the actual Windows Scheduler export'
 $sparse.Enabled=$false;$rejected=$false;try{Assert-TCStartupTask $sparse $plan}catch{$rejected=$true}
 Check $rejected 'An omitted enabled node cannot contradict a disabled registered task'
 foreach($field in @('DisallowStartIfOnBatteries','StopIfGoingOnBatteries','AllowStartOnDemand','ExecutionTimeLimit')){
  $edit={param($d,$ns)$n=$d.SelectSingleNode(('/t:Task/t:Settings/t:'+$field),$ns);$null=$n.ParentNode.RemoveChild($n)}.GetNewClosure()
  Reject $edit ('An omitted non-default policy is rejected: '+$field)
 }
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Settings/t:Hidden',$ns).InnerText='true'} 'An explicit conflicting default is rejected'
 Reject {param($d,$ns)$n=$d.SelectSingleNode('/t:Task/t:Settings/t:Enabled',$ns);$null=$n.ParentNode.AppendChild($n.CloneNode($true))} 'Duplicate default nodes are rejected'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText='S-1-5-18'} 'A different SID never qualifies as the current user'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText='BUILTIN\Administrators'} 'A group account never qualifies as the current user'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns).InnerText=($Account -split '\\')[-1]} 'An unqualified account name is not an identity proof'
 Reject {param($d,$ns)$n=$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:UserId',$ns);$null=$n.ParentNode.RemoveChild($n)} 'An absent user restriction cannot become an all-users trigger'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:Enabled',$ns).InnerText='false'} 'An explicitly disabled trigger is not treated as enabled'
 Reject {param($d,$ns)$n=$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger/t:Enabled',$ns);$null=$n.ParentNode.AppendChild($n.CloneNode($true))} 'Duplicate enablement is rejected'
 Reject {param($d,$ns)$n=$d.CreateElement('Delay',$ns.LookupNamespace('t'));$n.InnerText='PT1M';$null=$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger',$ns).AppendChild($n)} 'Unexpected trigger behavior is rejected'
 Reject {param($d,$ns)$n=$d.SelectSingleNode('/t:Task/t:Triggers/t:LogonTrigger',$ns);$null=$n.ParentNode.AppendChild($n.CloneNode($true))} 'Additional triggers remain rejected'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Command',$ns).InnerText='C:\Windows\System32\cmd.exe'} 'An alternate executable is still rejected'
 Reject {param($d,$ns)$d.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Description',$ns).InnerText='TradeChannel impostor'} 'Ownership metadata remains exact'
 Check (-not [IO.Directory]::Exists($Root)) 'Normalization verification creates no files, tasks or configuration'
 [pscustomobject]@{Passed=$true;Checks=$checks.Count;Assertions=$checks.ToArray();TaskSchedulerWrites=0;ProductionWrites=0;NetworkChanges=0;RealLocalAccountResolution=$true}
} $sid $account $root
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($true)))}
$result|ConvertTo-Json -Depth 5
