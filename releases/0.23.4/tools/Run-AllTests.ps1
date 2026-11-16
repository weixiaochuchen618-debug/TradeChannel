#requires -Version 5.1
# Aggregate runner for the 0.20 acceptance suites.
#
#   -Suite 020       the three-step pairing page: host message contract + headless UI
#   -Suite contract  the read-only projections and the quality store
#   -Suite all       every tests\*.ps1 that does not need a desktop session
#
# Every script is started in its own Windows PowerShell 5.1 process so a failing
# suite cannot leave state behind for the next one. Reports are written as JSON;
# the runner only counts a suite as passed when it emitted Passed=true.
[CmdletBinding()]
param(
 [ValidateSet('020','contract','all')][string]$Suite='020',
 [string]$PackageRoot='',
 [string]$ReportDirectory='',
 [switch]$IncludeUI,
 [switch]$IncludeTruth,
 [int]$TimeoutSeconds=900
)
$ErrorActionPreference='Stop'
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$root=[IO.Path]::GetFullPath($PackageRoot)
$tests=Join-Path $root 'tests'
if(-not $ReportDirectory){$ReportDirectory=Join-Path (Join-Path $root '..\reports') ('run-'+$Suite+'-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss'))}
$out=[IO.Path]::GetFullPath($ReportDirectory)
$null=[IO.Directory]::CreateDirectory($out)

# Tests that need an interactive desktop, a real WebView2 or a live network. They
# are reported as skipped instead of failed so the number stays honest.
$desktopBound=@('Test-WebShell.ps1','Test-ChromeDensity.ps1','Test-0187Interaction.ps1','Test-019StateTruth.py')

$scripts=switch($Suite){
 '020'{@('Test-020PairOnline.ps1')}
 'contract'{@('Test-019SnapshotProjection.ps1','Test-LineQualityHistory.ps1')}
 default{@(Get-ChildItem -LiteralPath $tests -Filter '*.ps1' -File|Sort-Object Name|ForEach-Object Name)}
}
$skipped=New-Object 'Collections.Generic.List[string]'
if($Suite -eq 'all'){$skipped.AddRange([string[]]@($scripts|Where-Object {$desktopBound -contains $_}));$scripts=@($scripts|Where-Object {$desktopBound -notcontains $_})}

function Get-ScriptParameters {
 param([string]$Path)
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 $names=@()
 if($ast.ParamBlock){foreach($parameter in $ast.ParamBlock.Parameters){$names+=$parameter.Name.VariablePath.UserPath}}
 return $names
}

$results=New-Object 'Collections.Generic.List[object]'
$watch=[Diagnostics.Stopwatch]::StartNew()
foreach($name in $scripts){
 $path=Join-Path $tests $name
 if(-not (Test-Path -LiteralPath $path)){$skipped.Add($name);continue}
 $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$path)
 $declared=Get-ScriptParameters $path
 if($declared -contains 'PackageRoot'){$arguments+=@('-PackageRoot',$root)}
 if($declared -contains 'ReportDirectory'){$arguments+=@('-ReportDirectory',$out)}
 $started=[DateTime]::UtcNow
 # The call operator keeps stdout and stderr in this process: no child shell
 # wrapper and no redirect files to clean up.
 $text=''
 try{$text=(& powershell.exe @arguments 2>&1 | Out-String)}catch{$text=''}
 $parsed=$null
 try{$parsed=$text|ConvertFrom-Json}catch{$parsed=$null}
 # A few older suites print a formatted object instead of JSON; read the two
 # fields the runner needs instead of silently counting them as failures.
 if($null -eq $parsed){
  $passedMatch=[regex]::Match($text,'Passed\s*:\s*(True|False)')
  if($passedMatch.Success){
   $checksMatch=[regex]::Match($text,'Checks\s*:\s*(\d+)')
   $parsed=[pscustomobject]@{Passed=($passedMatch.Groups[1].Value -eq 'True');Checks=$(if($checksMatch.Success){[int]$checksMatch.Groups[1].Value}else{0});Failure=[pscustomobject]@{Message=''}}
  }
 }
 $passed=($null -ne $parsed -and [bool]$parsed.Passed)
 $results.Add([pscustomobject]@{Script=$name;Passed=$passed;Checks=$(if($parsed){$parsed.Checks}else{0});Seconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1);Failure=$(if($parsed){$parsed.Failure.Message}else{'no JSON report'})})
}

# Headless UI suite (node + chrome-headless-shell). Included with 020 by default.
if($Suite -eq '020' -or $IncludeUI){
 $node=Join-Path $env:ProgramFiles 'nodejs\node.exe'
 if(-not (Test-Path -LiteralPath $node)){$node=(Get-Command node -ErrorAction SilentlyContinue).Source}
 if($node){
  $harness=Join-Path $tests 'harness\run-ui.js'
  $uiReport=Join-Path $out 'Test-020UI.json'
  $started=[DateTime]::UtcNow
  $uiReport=Join-Path $out 'Test-020UI.json'
  $uiErrFile=Join-Path $out 'Test-020UI.err'
  # The harness prints its progress on stderr; keep it in a file so the run log
  # stays readable and native stderr cannot trip $ErrorActionPreference='Stop'.
  $uiLog=(& $node $harness '--web' (Join-Path $root 'web') '--report' $uiReport 2>$uiErrFile | Out-String)
  $parsed=$null;if(Test-Path -LiteralPath $uiReport){try{$parsed=[IO.File]::ReadAllText($uiReport)|ConvertFrom-Json}catch{}}
  if(-not $parsed){$results.Add([pscustomobject]@{Script='Test-020UI.js';Passed=$false;Checks=0;Seconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1);Failure=$uiLog.Substring(0,[Math]::Min(400,$uiLog.Length))})}
  else{$results.Add([pscustomobject]@{Script='Test-020UI.js';Passed=([int]$parsed.Failed -eq 0);Checks=$parsed.Assertions;Seconds=[Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1);Failure=$(($parsed.Checks|Where-Object {-not $_.Passed}|ForEach-Object {$_.Name}) -join '; ')})}
 }else{$skipped.Add('Test-020UI.js (node not found)')}
}

if($IncludeTruth -and (Test-Path -LiteralPath (Join-Path $tests 'Test-019StateTruth.py'))){$skipped.Add('Test-019StateTruth.py (needs Python + Playwright + Edge; not available here)')}

$watch.Stop()
$failed=@($results|Where-Object {-not $_.Passed})
$scriptCount=[int]$scripts.Count
if($Suite -eq '020' -or $IncludeUI){$scriptCount=[int]$scriptCount+1}
$assertionTotal=0
foreach($entry in $results){$assertionTotal=[int]$assertionTotal+[int]$entry.Checks}
$summary=[pscustomobject]@{
 Suite=[string]$Suite; PackageRoot=[string]$root; Scripts=[int]$scriptCount
 Reports=[int]$results.Count; Skipped=[int]$skipped.Count
 Passed=[int]($results.Count-$failed.Count); Failed=[int]$failed.Count
 Assertions=[int]$assertionTotal; Seconds=[double][Math]::Round($watch.Elapsed.TotalSeconds,1)
 SkippedList=@($skipped); Results=$results.ToArray()
}
$json=$summary|ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $out 'summary.json'),$json,(New-Object Text.UTF8Encoding($false)))
Write-Output $json
if($failed.Count){exit 1}
