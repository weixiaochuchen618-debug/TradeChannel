#requires -Version 5.1
[CmdletBinding()]param([string]$SourceDirectory,[string]$ReportPath,[switch]$ExpectLegacyDefect)
$ErrorActionPreference='Stop';$checks=0;$failure=$null
if(-not $SourceDirectory){$SourceDirectory=Split-Path $PSScriptRoot -Parent}
$work=Join-Path ([IO.Path]::GetTempPath()) ('tc-scope-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
Import-Module (Join-Path $SourceDirectory 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'OperationHistory.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $SourceDirectory 'ServerRegistry.psm1') -DisableNameChecking
function Check {param($Ok,$Name)if(-not $Ok){throw $Name};$script:checks++}
function Put {param($Path,$Value)if(-not [IO.Path]::GetFullPath($Path).StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture rejected external write'};Write-TCDJson $Path $Value}
try{
 $server=Set-TCServerRecord -Root $work -Connection @{Host='192.0.2.10';Port=22;User='root';IdentityFile=''} -ServerInfo @{RemoteOwnerId=[guid]::NewGuid().ToString();Node=@{NodeId=[guid]::NewGuid().ToString();ServerPublicKey=('S'*43+'=')}} -Name 'shared fixture'
 $lineA=[guid]::NewGuid().ToString();$lineB=[guid]::NewGuid().ToString();$nodes=@();$runs=@()
 foreach($line in @($lineA,$lineB)){
  $path=Join-Path $work ('Product\nodes\'+$line+'\manifest.json');Put $path @{TCLineId=$line;TCManagedNodeId=$line;ServerPublicKey=('S'*43+'=');ClientPublicKey=($line+'-fixture-key')}
  Put (Join-Path $work ('Product\lines\'+$line+'\line.json')) @{SchemaVersion=2;LineId=$line;Profiles=@();SourceManifestPath=$path;ServerPublicKey=('S'*43+'=')}
  $nodes+=,@{id=$line;name='fixture';manifestPath=$path};$run=[guid]::NewGuid().ToString();$runs+=,$run
  Put (Join-Path $work ('deployments\runs\'+$run+'\state.json')) @{SchemaVersion=1;RunId=$run;ServerRecordId=$server.LocalRecordId;Intent='New';Revision=1;Status='Complete';Stage='ReadyInactive';CandidateNodeId=$line;CandidateManifestPath=$path;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $null=Set-TCServerLink -Root $work -ServerId $server.LocalRecordId -NodeId $line
 }
 Put (Join-Path $work 'Product\index.json') @{schemaVersion=1;nodes=$nodes}
 Put (Join-Path $work 'deployment.json') @{LineId=$lineB;ManifestPath=$nodes[1].manifestPath}
 $hashB=(Get-FileHash -LiteralPath $nodes[1].manifestPath).Hash
 $preview=New-TCLocalDeploymentCleanupPreview -Root $work -Ids @('Line:'+$lineA)
 if($ExpectLegacyDefect){Check ($preview.LineCount -eq 2 -and @($preview.Blocked|Where-Object Code -eq CurrentLine).Count -gt 0) '0.16.11 expands A to B and blocks deletion because B is active'}
 else{
  Check ($preview.LineCount -eq 1 -and $preview.PreviewToken) 'Line A scope must be deletable with same-server B active'
  $result=Remove-TCLocalDeploymentData -Root $work -PreviewToken $preview.PreviewToken
  Check $result.DataDeleted 'A deletion committed'
  Check ((Get-FileHash -LiteralPath $nodes[1].manifestPath).Hash -ceq $hashB) 'B manifest bytes preserved'
  Check (Test-Path (Join-Path $work ('deployments\runs\'+$runs[1]+'\state.json'))) 'B task preserved'
  Check (-not (Test-Path (Join-Path $work ('Product\nodes\'+$lineA)))) 'A exclusive node removed'
  Check ((Get-TCServer -Root $work -Id $server.LocalRecordId).LinkedNodeIds -contains $lineB) 'shared server and B link preserved'
 }
}catch{$failure=$_.Exception.Message}
$report=[pscustomobject]@{Passed=(-not $failure);Checks=$checks;ExpectedLegacyDefect=[bool]$ExpectLegacyDefect;Error=$failure;SourceDirectory=$SourceDirectory;Scope='real cleanup planner and journal on bounded synthetic root';FixtureRoot=$work;PreviewLineCount=$preview.LineCount;Blocked=@($preview.Blocked)}
if($ReportPath){$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$report|ConvertTo-Json -Depth 8 -Compress
# Preserve fixture on failure for diagnosis; remove only our verified temp subtree.
if(-not $failure -and [IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($work) -match '^tc-scope-[a-f0-9]{32}$'){Remove-Item -LiteralPath $work -Recurse -Force}
if($failure){exit 1}
