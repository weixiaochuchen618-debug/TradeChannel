#requires -Version 5.1
param([string]$PackageRoot=(Split-Path $PSScriptRoot -Parent),[string]$ReportPath)
$ErrorActionPreference='Stop';$env:PSModulePath=Join-Path $PSHOME 'Modules'
$root=Join-Path ([IO.Path]::GetTempPath()) ('TradeChannel-worker-fixture-'+[guid]::NewGuid().ToString('N'))
$jobs=Join-Path $root 'Product\jobs';$null=[IO.Directory]::CreateDirectory($jobs)
$checks=New-Object 'Collections.Generic.List[string]';$rows=New-Object 'Collections.Generic.List[object]'
function Check {param($Ok,$Label)if(-not $Ok){throw $Label};$checks.Add($Label)}
function RunWorker {param([hashtable]$Request,[switch]$ReadSession,[switch]$Legacy)
 $id=[guid]::NewGuid().ToString('N');$Request=$Request.Clone();$Request.RequestId=$id;$Request.PageGeneration=1
 if(-not $Legacy -and -not $Request.ContainsKey('UiRequestId')){$Request.UiRequestId=[guid]::NewGuid().ToString('N')}
 $req=Join-Path $jobs ($id+'.request.json');$res=Join-Path $jobs ($id+'.result.json')
 [IO.File]::WriteAllText($req,($Request|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($true))
 & (Join-Path $PackageRoot 'Worker.ps1') -RequestPath $req -ResultPath $res -IsolatedTest -TestRoot $root -ReadSession:$ReadSession
 $r=Get-Content -LiteralPath $res -Raw -Encoding UTF8|ConvertFrom-Json
 $rows.Add([pscustomobject]@{Action=$r.Action;Ok=$r.Ok;Code=$r.Code;Phase=$r.Phase;Legacy=[bool]$Legacy})
 Check ($r.RequestId -ceq $id) 'Worker result binds RequestId'
 return $r
}
try{
 $old=RunWorker @{Action='Overview'} -ReadSession -Legacy;Check $old.Ok 'Legacy read envelope remains compatible'
 $new=RunWorker @{Action='Overview'} -ReadSession;Check ($new.Ok -and $new.UiRequestId -cmatch '^[a-f0-9]{32}$') 'Current UI envelope reaches actual overview and returns UiRequestId'
 $bad=RunWorker @{Action='Overview';UiRequestId='invalid'} -ReadSession;Check (-not $bad.Ok -and $bad.Code -ceq 'InvalidRequest' -and $bad.Phase -ceq 'BeforeDispatch') 'Malformed UI identity is rejected before dispatch'
 $extra=RunWorker @{Action='Overview';Command='Disconnect'} -ReadSession;Check (-not $extra.Ok -and $extra.Code -ceq 'ReadActionNotAllowed') 'Unexpected business fields remain rejected by read worker'
 $mutation=RunWorker @{Action='Session';SessionAction='Disconnect'} -ReadSession;Check (-not $mutation.Ok -and $mutation.Code -ceq 'ReadActionNotAllowed' -and -not $mutation.OutcomeUnknown) 'Valid UI identity never permits mutation in a read process'
 $create=@{Action='DeploymentCreate';Intent='New';Connection=@{Host='192.0.2.151';Port=22;User='root';IdentityFile=''};Name='Envelope fixture';Transport='Auto';TcpPort=443;ServerName='www.bing.com'}
 $draft=RunWorker $create;Check ($draft.Ok -and $draft.Data.Stage -ceq 'PrepareAccess' -and -not $draft.Data.NetworkChanged) 'Actual deployment field allowlist accepts UI envelope and creates only local draft'
 $unexpected=$create.Clone();$unexpected.UnexpectedField='fixture'
 $denied=RunWorker $unexpected;Check (-not $denied.Ok) 'Deployment business allowlist still rejects unknown fields'
 Check (-not [IO.File]::Exists((Join-Path $root 'deployment.json'))) 'Envelope regression performs no actual session operation'
 $proof=[pscustomobject]@{Passed=$true;Count=$checks.Count;Checks=@($checks.ToArray());Results=@($rows.ToArray());RealNetworkChanges=0}
 [IO.File]::WriteAllText($ReportPath,($proof|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true));$proof|ConvertTo-Json -Depth 6
}finally{
 $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
