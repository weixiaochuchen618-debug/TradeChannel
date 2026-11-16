# Loaded inside OperationHistory.psm1. No remote actor is used by this module.
# A cleanup is an explicit server/endpoint family operation, not display hiding.
function LCFail {param([string]$Code,[string]$Message) throw ('[TC:Cleanup'+$Code+'] '+$Message)}
function LCEndpoint {param($Connection)
 $address=$null;$port=0;$user=[string](OHField $Connection User '')
 if([Net.IPAddress]::TryParse([string](OHField $Connection Host ''),[ref]$address) -and [int]::TryParse([string](OHField $Connection Port ''),[ref]$port) -and $port -ge 1 -and $port -le 65535 -and $user -cmatch '^[a-z_][a-z0-9_-]{0,31}$'){return $address.ToString()+':'+$port+':'+$user};return ''
}
function LCAdd {param($Set,$Value) if($Value -is [string] -and $Value){$Set[$Value]=$true}}
function LCSeed {param($Plan,$Doc)
 OHWalk $Doc {param($name,$v,$parent)
  switch($name){
   {$_ -in @('ServerRecordId','LocalRecordId','ServerId')} {LCAdd $Plan.ServerIds $v}
   {$_ -in @('RunId','JobId','OperationId','SourceJobId','RequestJobId','ParentJobId','ReusedRequestSourceRunId')} {LCAdd $Plan.RunIds $v}
   {$_ -in @('CandidateNodeId','LineId','TCLineId','TCManagedNodeId')} {LCAdd $Plan.LineIds $v}
   {$_ -in @('RemoteOwnerId','ServerPublicKey','ClientPublicKey','RequestId','EnrollmentId')} {LCAdd $Plan.Bindings ($name+':'+$v)}
  }
 } -Names @('ServerRecordId','LocalRecordId','ServerId','RunId','JobId','OperationId','SourceJobId','RequestJobId','ParentJobId','ReusedRequestSourceRunId','CandidateNodeId','LineId','TCLineId','TCManagedNodeId','RemoteOwnerId','ServerPublicKey','ClientPublicKey','RequestId','EnrollmentId')
 # NodeId inside ServerInfo is remote identity. Only the explicit local
 # candidate transaction owns a node folder before CandidateNodeId is saved.
 $candidateId=[string](OHField (OHField $Doc CandidateTransaction) NodeId '')
 if($candidateId){LCAdd $Plan.LineIds (OHId $candidateId)}
}
function LCBound {param($Plan,$Doc,[switch]$Endpoint)
 if(-not $Doc){return $false};$hit=@{Value=$false}
 if($Endpoint){$key=LCEndpoint (OHField $Doc Connection);if($key -and $Plan.Endpoints.ContainsKey($key)){return $true}}
 OHWalk $Doc {param($name,$v,$parent)
  if($v -isnot [string] -or -not $v){return}
  if(($name -in @('ServerRecordId','LocalRecordId','ServerId') -and $Plan.ServerIds.ContainsKey($v)) -or ($name -in @('RunId','JobId','OperationId','SourceJobId','RequestJobId','ParentJobId','ReusedRequestSourceRunId') -and $Plan.RunIds.ContainsKey($v)) -or ($name -in @('CandidateNodeId','LineId','TCLineId','TCManagedNodeId','NodeId','SourceNodeId') -and $Plan.LineIds.ContainsKey($v)) -or ($name -in @('public_key','server_public_key') -and $Plan.Bindings.ContainsKey('ServerPublicKey:'+$v)) -or $Plan.Bindings.ContainsKey($name+':'+$v)){$hit.Value=$true}
 } -Names @('ServerRecordId','LocalRecordId','ServerId','RunId','JobId','OperationId','SourceJobId','RequestJobId','ParentJobId','ReusedRequestSourceRunId','CandidateNodeId','LineId','TCLineId','TCManagedNodeId','NodeId','SourceNodeId','RemoteOwnerId','ServerPublicKey','ClientPublicKey','RequestId','EnrollmentId','public_key','server_public_key')
 return $hit.Value
}
function LCBlock {param($Plan,[string]$Code,[string]$Message) if(-not @($Plan.Blocked|Where-Object Code -ceq $Code).Count){$Plan.Blocked.Add([pscustomobject]@{Code=$Code;Message=$Message})}}
function LCWarn {param($Plan,[string]$Code,[string]$Message) if(-not @($Plan.Warnings|Where-Object Code -ceq $Code).Count){$Plan.Warnings.Add([pscustomobject]@{Code=$Code;Message=$Message})}}
function LCUnresolved {param($Plan,[string]$Code,[string]$Message)
 $Plan.RemoteOutcomeUnverified=$true
 if($Plan.AbandonLocalTracking){LCWarn $Plan RemoteOutcomeUnverified '将只放弃本机跟踪并清理本机资料；服务器上的执行结果尚未核对，不能据此认定服务器已回滚或恢复空白。再次接入必须重新检查服务器实际状态。'}
 else{LCBlock $Plan $Code $Message}
}
function LCProcessAlive {param($Doc,[string]$IdField='ProcessId',[string]$TickField='StartTimeUtcTicks')
 $number=0;$ticks=0L;$process=$null
 if(-not [int]::TryParse([string](OHField $Doc $IdField ''),[ref]$number) -or $number -le 0){return $false}
 if(-not [long]::TryParse([string](OHField $Doc $TickField ''),[ref]$ticks) -or $ticks -le 0){return $true}
 try{$process=[Diagnostics.Process]::GetProcessById($number);return (-not $process.HasExited -and $process.StartTime.ToUniversalTime().Ticks -eq $ticks)}catch [ArgumentException]{return $false}catch{return $true}finally{if($process){$process.Dispose()}}
}
function LCSession {param($Plan,$Session,[string]$RunId)
 if(-not $Session -or -not (LCProcessAlive $Session)){return}
 LCBlock $Plan ExecutorActive '关联本机执行器仍在运行。请先结束原会话；界面最多等待 5 秒，超时后保留资料并明确报告结果。'
 # A saved reference is only a candidate for a live idle check. The cleanup
 # module never contacts, closes or kills an executor based on stale metadata.
 try{
  $instance=OHId ([string](OHField $Session InstanceId ''));$run=OHId $RunId
  $ticks=0L;$number=0
  if((OHField $Session RunId '') -cne $run -or [string](OHField $Session PipeName '') -cnotmatch '^TCDeploy-[a-f0-9]{32}$' -or -not [int]::TryParse([string](OHField $Session ProcessId ''),[ref]$number) -or $number -le 0 -or -not [long]::TryParse([string](OHField $Session StartTimeUtcTicks ''),[ref]$ticks) -or $ticks -le 0){throw 'identity'}
  $expected=OHPath $Plan.Root (Join-Path $Plan.Root ('deployments\hosts\'+$instance))
  if((OHPath $Plan.Root ([string](OHField $Session Root ''))) -ine $expected){throw 'root'}
  $Plan.Executors[$instance]=[pscustomobject]@{RunId=$run;SessionRef=[pscustomobject]@{RunId=$run;InstanceId=$instance;ProcessId=$number;StartTimeUtcTicks=[string]$ticks;Root=$expected;PipeName=[string]$Session.PipeName};RequiresLiveIdleCheck=$true}
 }catch{LCBlock $Plan ExecutorIdentityUnknown '关联执行器的身份资料不完整，无法受控关闭；本机资料仍保留，请核对原进程后重新预览。'}
}
function LCRisk {param($Plan,$Doc,[string]$Kind,[switch]$Retired)
 if(-not $Doc){return}
 foreach($field in @('SessionRef','AttemptSessionRef')){LCSession $Plan (OHField $Doc $field) ([string](OHField $Doc RunId ''))}
 OHWalk $Doc {param($name,$value,$parent) if(($name -in @('ProbeRecoveryRequired','CleanupError') -and $value) -or ($name -eq 'CleanupComplete' -and $null -ne $value -and $value -ne $true)){LCBlock $Plan ProbeCleanup '本机检测或网络清理尚未完成，请先恢复。'}} -Names @('ProbeRecoveryRequired','CleanupError','CleanupComplete')
 if(-not $Retired -and ((OHField $Doc RecoveryRequired $false) -or (OHField $Doc UnresolvedTcpMutation) -or (OHField $Doc OutcomeUnknown $false) -or (OHField $Doc Status (OHField $Doc State '')) -in @('OutcomeUnknown','NeedsRecovery','RecoveryRequired','AuthorizedReturnPending'))){LCUnresolved $Plan Unresolved '关联操作的实际结果尚未核对。可先核对原操作，或明确选择只放弃本机跟踪；删除本机资料不会回滚服务器。'}
 foreach($field in @('LastRemoteMutation','DispatchIntent','StopTransaction')){
  $v=OHField $Doc $field
  if(-not $Retired -and (OHField $v State '') -in @('Prepared','Dispatched','Running','OutcomeUnknown','NeedsRecovery')){LCUnresolved $Plan Unresolved '关联远端操作存在未核对的事务。可先核对原结果，或明确选择只放弃本机跟踪。'}
 }
 $candidate=OHField $Doc CandidateTransaction
 if($candidate -and (OHField $candidate State '') -notin @('Completed','RolledBack')){
  $Plan.LocalCandidateAbandonment=$true
  LCWarn $Plan LocalCandidateAbandonment '本机候选准备尚未完成；确认后将清理该候选事务和未使用的本机产物，服务器上已有的部署或授权保持原状。'
 }
 if((OHField $Doc ProfileProbeState '') -in @('Running','Checking','Preparing')){LCBlock $Plan ProbeCleanup '本机线路检测尚未确认结束，请先完成检测资源清理。'}
 $localStage=(OHField $Doc Stage '') -in @('MaterializeCandidate','MaterializeTcp')
 if(-not $Retired -and ((OHField $Doc PendingOperationId) -or (-not $localStage -and (OHField $Doc Status (OHField $Doc State '')) -in @('Running','Pending','Dispatching','Prepared','Dispatched')))){LCUnresolved $Plan Unresolved '原任务记录仍在等待结果；只有精确执行器和本机锁均已释放后，才可明确放弃本机跟踪。'}
 if($Kind -eq 'Probe' -and (((OHField $Doc CleanupComplete $true) -ne $true) -or (OHField $Doc State 'Stopped') -ne 'Stopped' -or ((OHField $Doc TraceGuid) -and (OHField $Doc TraceState '') -ne 'Stopped'))){LCBlock $Plan ProbeCleanup '检测资源尚未释放，请先完成检测恢复。'}
}
function LCRetiredLegacy {param($Plan,$Record)
 if($Record.SourceKind -cne 'LegacyLinuxJob'){return $false}
 foreach($s in $Plan.Context.Servers){
  if((OHField $s RecordState '') -cne 'Archived' -or -not (OHTime (OHField $s ArchivedAtUtc))){continue}
  $replacement=$Plan.Context.ServersById[[string](OHField $s ReplacedByServerId '')];$proof=OHField $replacement Reinstall
  if(-not $proof -or (OHField $proof PreviousServerId '') -cne $s.LocalRecordId -or (OHTime (OHField $proof ConfirmedAtUtc)) -cne (OHTime (OHField $s ArchivedAtUtc)) -or (OHField $proof ChangeDigest '') -cnotmatch '^[a-f0-9]{64}$'){continue}
  $binding=@((OHField $s ArchivedTasks @())|Where-Object {$_.Kind -ceq 'Legacy' -and $_.Id -ceq $Record.SourceId -and $_.Digest -ceq (Get-TCDDigest $Record.Doc)})
  $finished=OHTime (OHField $Record.Result FinishedAtUtc)
  if($binding.Count -eq 1 -and $finished -and [DateTimeOffset]$finished -le [DateTimeOffset]$s.ArchivedAtUtc){return $true}
 }
 return $false
}
function LCFiles {param([string]$Root,[string]$Path)
 $path=OHPath $Root $Path
 if([IO.File]::Exists($path)){Get-Item -LiteralPath $path -Force;return}
 if(-not [IO.Directory]::Exists($path)){return}
 # Check each child before descending; never follow a junction even temporarily.
 foreach($child in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)){
  $null=OHPath $Root $child.FullName
  if($child.PSIsContainer){LCFiles $Root $child.FullName}else{$child}
 }
}
function LCAddPath {param($Plan,[string]$Path,[string]$Kind)
 $path=OHPath $Plan.Root $Path
 if(-not [IO.File]::Exists($path) -and -not [IO.Directory]::Exists($path)){return}
 $Plan.Paths[$path]=$Kind
}
function LCRead {param([string]$Root,[string]$Path,[ref]$Snapshot,[int]$MaxBytes=4194304)
 $full=OHPath $Root $Path
 if(-not $Snapshot){return (Read-TCDJson $full -AllowMissing -MaxBytes $MaxBytes)}
 # Quality replacements must be computed from exactly the bytes whose hash
 # enters the preview. Do not re-read JSON after calculating its file hash.
 $Snapshot.Value=$null;if(-not [IO.File]::Exists($full)){return $null}
 $stream=$null;$sha=$null
 try{
  $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  # This byte-bound reader must enforce the same account ACL as Read-TCDJson.
  $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
  foreach($rule in $stream.GetAccessControl().GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){LCFail QualityCacheInvalid '线路质量缓存对其他账户开放，原资料已保留。'}}
  if($stream.Length -gt $MaxBytes){LCFail QualityCacheInvalid '线路质量缓存超出大小限制，原资料已保留。'}
  $bytes=New-Object byte[] ([int]$stream.Length);$offset=0
  while($offset -lt $bytes.Length){$read=$stream.Read($bytes,$offset,$bytes.Length-$offset);if($read -le 0){LCFail Changed '线路质量缓存读取期间发生变化，请重新预览。'};$offset+=$read}
  if($stream.ReadByte() -ne -1){LCFail Changed '线路质量缓存读取期间发生变化，请重新预览。'}
  $sha=[Security.Cryptography.SHA256]::Create();$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
  $text=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes).TrimStart([char]0xfeff)
  $doc=ConvertFrom-Json -InputObject $text -ErrorAction Stop
  $Snapshot.Value=[pscustomobject]@{Hash=$hash;Bytes=$bytes.Length}
  return $doc
 }finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
}
function LCQualityShape {param($Value,[string[]]$Names)
 if($Value -isnot [pscustomobject] -or @($Value.PSObject.Properties).Count -ne $Names.Count){return $false}
 return -not @($Value.PSObject.Properties|Where-Object {$_.Name -cnotin $Names}).Count
}
function LCQualityIntent {param($Doc,[string]$Name,$Ids)
 # Only exact, validated current schemas may rebase telemetry. Unknown fields,
 # legacy shapes and future versions retain the original full-byte contract.
 $bindingFields=@('NodeId','SessionId','ProfileId','Exit','ConfigHash','EnginePid','EngineStartedAtUtc','ManifestPath','Mode')
 if($Name -ceq 'line-quality'){
  if((OHField $Doc SchemaVersion 0) -ne 2 -or -not (LCQualityShape $Doc @('SchemaVersion','Owner','Revision','SeriesId','ArchivedSeries','BindingKey','Binding','Samples','LastAttemptAtUtc','BadCount','RecoveryCount','AlertLatched','LastAlert'))){return $null}
  if($Doc.LastAlert -and -not (LCQualityShape $Doc.LastAlert @('Id','Reason','Message','AtUtc'))){return $null}
  foreach($series in @($Doc)+@($Doc.ArchivedSeries)){
   if($series -ne $Doc -and -not (LCQualityShape $series @('SeriesId','BindingKey','Binding','Samples'))){return $null}
   if($series.Binding -and -not (LCQualityShape $series.Binding $bindingFields)){return $null}
   foreach($sample in @($series.Samples)){if(-not (LCQualityShape $sample @('AtUtc','LatencyMs','Quality','Reason','Source'))){return $null}}
  }
  $targets=@(@($Doc)+@($Doc.ArchivedSeries)|Where-Object {$Ids.ContainsKey([string](OHField $_.Binding NodeId ''))}|ForEach-Object {[pscustomobject]@{Binding=$_.Binding;BindingKey=$_.BindingKey}}|Sort-Object BindingKey)
 }elseif($Name -ceq 'standby-quality'){
  if((OHField $Doc SchemaVersion 0) -ne 1 -or -not (LCQualityShape $Doc @('SchemaVersion','Owner','Revision','BindingKey','Binding','CandidateSetKey','LastAttemptAtUtc','Entries'))){return $null}
  if($Doc.Binding){
   if(-not (LCQualityShape $Doc.Binding $bindingFields)){return $null}
   $quality=Import-Module (Join-Path $PSScriptRoot 'LineQuality.psm1') -PassThru -DisableNameChecking
   try{& $quality {param($b,$k)LQAssertBinding $b $k} $Doc.Binding $Doc.BindingKey}catch{return $null}
  }
  foreach($entry in @($Doc.Entries)){
   if(-not (LCQualityShape $entry @('CandidateKey','Binding','LastAttemptAtUtc','AtUtc','LatencyMs','Source','Reason')) -or -not (LCQualityShape $entry.Binding @('NodeId','ProfileId','Exit','Host','Port','ConfigHash','Underlay'))){return $null}
   if($entry.Binding.Underlay -and -not (LCQualityShape $entry.Binding.Underlay @('InterfaceIndex','LocalAddress','InterfaceId','NetworkFingerprint'))){return $null}
  }
  $targets=@($Doc.Entries|Where-Object {$Ids.ContainsKey([string]$_.Binding.NodeId)}|ForEach-Object {[pscustomobject]@{Binding=$_.Binding;CandidateKey=$_.CandidateKey}}|Sort-Object CandidateKey)
 }else{return $null}
 # Seal actual owner bindings and the exact target family, not sample values,
 # revision tickets, debounce counters or other lines' measurement history.
 return Get-TCDDigest @{Contract='TargetQualityOwnership.v1';Owner=$Doc.Owner;SchemaVersion=$Doc.SchemaVersion;Binding=$Doc.Binding;BindingKey=$Doc.BindingKey;Targets=$targets}
}
function LCQualityCaches {param($Plan)
 if(-not $Plan.LineIds.Count){return}
 foreach($cache in @(
  @{Name='line-quality';Owner='TradeChannel.LineQuality';Module='LineQuality.psm1';Function='Remove-TCLineQualityOwnedState';MaxBytes=1048576},
  @{Name='standby-quality';Owner='TradeChannel.StandbyQuality';Module='StandbyQuality.psm1';Function='Remove-TCStandbyQualityOwnedState';MaxBytes=131072}
 )){
  $path=OHPath $Plan.Root (Join-Path $Plan.Root ('Product\'+$cache.Name+'.json'))
  if([IO.Directory]::Exists($path)){LCBlock $Plan QualityCacheInvalid '线路质量缓存路径不是普通文件，原资料已保留。';continue}
  if(-not [IO.File]::Exists($path)){continue}
  try{
   $snapshot=$null;$doc=LCRead $Plan.Root $path -Snapshot ([ref]$snapshot) -MaxBytes $cache.MaxBytes
   if((OHField $doc Owner '') -cne $cache.Owner){$Plan.Preserved.Add('归属无法核验的线路质量缓存');continue}
   $module=Import-Module (Join-Path $PSScriptRoot $cache.Module) -PassThru -DisableNameChecking
   $change=& $module {param($Name,$State,$Ids) & $Name -State $State -NodeId $Ids} $cache.Function $doc @($Plan.LineIds.Keys)
   if(-not $change.Changed){continue}
   $intent=LCQualityIntent $doc $cache.Name $Plan.LineIds
   if($intent){$Plan.QualityIntents[$path]=$intent}
   $Plan.QualitySnapshots[$path]=$snapshot
   if($change.Empty){LCAddPath $Plan $path 'LineCache'}
   else{$Plan.Replacements[$path]=$change.Value;$Plan.Preserved.Add('其他线路的质量历史与备用测量缓存')}
  }catch{LCBlock $Plan QualityCacheInvalid '线路质量缓存的内容或归属无法核验，原资料已保留。'}
 }
}
function LCTransactionBound {param($Plan,$Doc,[int]$Depth=0)
 if(-not $Doc){return $false}
 if($Depth -gt 36){LCFail TransactionMetadataInvalid '连接事务引用过深，保留原资料，请先核对。'}
 if(LCBound $Plan $Doc){return $true}
 $hit=@{Value=$false}
 # Older transactions may contain only paths or byte snapshots rather than
 # the newer explicit References section. Those rollback dependencies count.
 OHWalk $Doc {param($name,$value,$parent)
  if($name -eq 'Bytes' -and (OHField $parent Exists) -eq $true -and (OHField $parent Path)){
   $bytes=$null;$sha=$null
   try{
    if($value -isnot [string] -or $value.Length -gt 5592408){throw 'snapshot'}
    $bytes=[Convert]::FromBase64String($value);$sha=[Security.Cryptography.SHA256]::Create()
    $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
    if($hash -ine [string](OHField $parent SHA256 '')){throw 'hash'}
    $snapshot=([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)|ConvertFrom-Json)
    if(LCTransactionBound $Plan $snapshot ($Depth+1)){$hit.Value=$true}
   }catch{LCFail TransactionMetadataInvalid '连接事务快照不能核验，保留原资料，请先核对。'}
   finally{if($sha){$sha.Dispose()};if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
  }elseif($value -is [string] -and [IO.Path]::IsPathRooted($value)){
   $path=OHPath $Plan.Root $value
   foreach($owned in $Plan.Paths.Keys){if($path -ieq $owned -or $path.StartsWith($owned+'\',[StringComparison]::OrdinalIgnoreCase)){$hit.Value=$true}}
  }
 } -Names @('Bytes','Path','ManifestPath','ConfigPath','ProfileManifestPath','CandidateManifestPath','SourceManifestPath','TCSourceManifestPath','TCProfileManifestPath','PreviousManifestPath','RollbackManifestPath','OriginalManifestPath','ActiveManifestPath','CandidatePath')
 return $hit.Value
}
function LCMetadata {param([string]$Root,[string]$Directory)
 foreach($leaf in @('receipt.json','probe.json','ownership.json','result.json','enrollment.json','public.request.json','client.state.json','line.json','manifest.json','state.json','job.json')){
  $path=Join-Path $Directory $leaf
  if([IO.File]::Exists($path)){$doc=LCRead $Root $path;if($doc){$doc}}
 }
}
function LCReferencedLineIds {param($Doc)
 $set=@{}
 foreach($key in @('CandidateNodeId','LineId','TCLineId','TCManagedNodeId')){LCAdd $set (OHField $Doc $key)}
 LCAdd $set (OHField (OHField $Doc CandidateTransaction) NodeId)
 $relations=OHField $Doc ResourceRelations
 if((OHField $relations Version 0) -eq 1){foreach($key in @('InputLineIds','OwnedCandidateIds','PublishedLineIds')){foreach($id in @(OHField $relations $key @())){LCAdd $set $id}}}
 return @($set.Keys)
}
function LCLineFamily {param($Context,[string]$Id)
 $set=@{};LCAdd $set $Id
 foreach($line in $Context.Lines.Values){if((OHField $line LineId '') -ceq $Id -or $Id -in @(OHField $line AliasIds @())){LCAdd $set (OHField $line LineId);foreach($alias in @(OHField $line AliasIds @())){LCAdd $set $alias}}}
 return @($set.Keys)
}
function LCInputLine {param($Doc,[string]$Id)
 return ((OHField $Doc Intent '') -eq 'Existing' -or (OHField $Doc ExistingDevice $false) -or $Id -in @(OHField (OHField $Doc ResourceRelations) InputLineIds @()))
}
function LCPublishedLine {param($Context,$Doc,[string]$Id)
 # A completed candidate has been handed to line management even if its later
 # check failed. A task reference never withdraws that publication.
 $exists=@((OHField $Context.Index nodes @())|Where-Object id -ceq $Id).Count -gt 0 -or $Context.Lines.ContainsKey($Id)
 return ($exists -and ((OHField $Doc Stage '') -eq 'ReadyInactive' -or (OHField (OHField $Doc CandidateTransaction) State '') -eq 'Completed' -or $Id -in @(OHField (OHField $Doc ResourceRelations) PublishedLineIds @())))
}
function LCCandidateProof {param($Plan,$Doc,[string]$Id,$Manifest)
 $tx=OHField $Doc CandidateTransaction;$request=OHField $Doc ClientRequest;$response=OHField $Doc ClientResponse
 if((LCInputLine $Doc $Id) -or (LCPublishedLine $Plan.Context $Doc $Id) -or (OHField $tx State '') -notin @('Prepared','Imported','ProfilesPending') -or $Id -in @(OHField $tx BeforeNodeIds @())){return $false}
 $hash=[string](OHField $tx ConfigHash '');$requestId=[string](OHField $request RequestId '');$client=[string](OHField $request ClientPublicKey '');$server=[string](OHField $response ServerPublicKey '');$node=[string](OHField $tx NodeId '')
 if(-not $requestId -or (OHField $tx RequestId '') -cne $requestId -or $hash -notmatch '^[a-fA-F0-9]{64}$' -or -not $client -or -not $server -or ($node -and $node -cne $Id)){return $false}
 return ($Manifest -and (OHField $Manifest ExportSHA256 '') -ieq $hash -and (OHField $Manifest ClientPublicKey '') -ceq $client -and (OHField $Manifest ServerPublicKey '') -ceq $server)
}
function LCExclusiveCandidate {param($Plan,$Record,[string]$Id,$Manifest)
 if(-not (LCCandidateProof $Plan $Record.Doc $Id $Manifest)){return $false}
 $family=@(LCLineFamily $Plan.Context $Id)
 foreach($other in $Plan.Context.Records){
  if($other.Id -ceq $Record.Id){continue}
  if(@(LCReferencedLineIds $other.Doc|Where-Object {$_ -in $family}).Count -and (-not $Plan.SelectedIds.Contains($other.Id) -or (LCPublishedLine $Plan.Context $other.Doc $Id) -or (LCInputLine $other.Doc $Id))){return $false}
 }
 return $true
}
function LCOwnedUnpublishedLineIds {param($Plan,$Record)
 foreach($id in @(LCReferencedLineIds $Record.Doc)){
  $null=OHId $id;$manifest=LCRead $Plan.Root (Join-Path $Plan.Root ('Product\nodes\'+$id+'\manifest.json'))
  if(LCExclusiveCandidate $Plan $Record $id $manifest){$id}
  else{
   LCAdd $Plan.RetainedLineIds $id
   $reason=if(LCInputLine $Record.Doc $id){'输入线路'}elseif(LCPublishedLine $Plan.Context $Record.Doc $id){'已发布线路'}else{'缺少独占未发布产物证明的线路'}
   $Plan.Preserved.Add(('保留'+$reason+' '+$id+' 及其配置；任务清理不删除该线路。'))
  }
 }
}
function LCStoppedReferenceValue {param($Original,[string]$Relative)
 $value=$Original|ConvertTo-Json -Depth 80|ConvertFrom-Json
 # These are current-dependency fields only. Preserve the stopped session's
 # process identities, cleanup result, timestamps and protection information.
 foreach($name in @('ManifestPath','ConfigPath','ProfileManifestPath','LineId','ProfileId','TransactionId','CandidateSHA256')){
  if($value.PSObject.Properties[$name]){$value.$name=$null}
 }
 if($Relative -ceq 'deployment.json'){$value|Add-Member NoteProperty Stage 'Unconfigured' -Force}
 $value|Add-Member NoteProperty ReferenceDisposition ([pscustomobject]@{SchemaVersion=1;State='ReleasedAfterVerifiedStop';Reason='LocalLineDeletion'}) -Force
 return $value
}
function LCSnapshotMatches {param($Plan,$Snapshot,[string]$Relative)
 if(-not $Snapshot -or (OHField $Snapshot Path '') -ine (Join-Path $Plan.Root $Relative)){return $false}
 $path=OHPath $Plan.Root ([string]$Snapshot.Path)
 if((OHField $Snapshot Exists) -eq $false){return -not [IO.File]::Exists($path)}
 return ((OHField $Snapshot Exists) -eq $true -and (OHField $Snapshot SHA256 '') -cmatch '^[A-Fa-f0-9]{64}$' -and [IO.File]::Exists($path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ceq $Snapshot.SHA256)
}
function LCReleaseStoppedReference {param($Plan,[string]$Relative,$Doc,$Manifest)
 if(-not $Plan.UsageEvidence){
  Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -DisableNameChecking
  $Plan.UsageEvidence=Get-TCConnectionUsageEvidence -Root $Plan.Root
 }
 $proof=$Plan.UsageEvidence
 if((OHField $proof ProofVersion 0) -ne 1 -or (OHField $proof State '') -cne 'Stopped' -or (OHField $proof OwnershipKnown $false) -ne $true -or (OHField $proof SessionPresent $true) -ne $false){LCBlock $Plan StopUnverified '上次连接结束后的清理还需要核对。线路尚未删除。';return $false}
 $id=[string](OHField $Manifest TCTransactionId (OHField $Doc TransactionId ''))
 if($id -cnotmatch '^[a-f0-9]{32}$'){LCBlock $Plan StopUnverified '上次连接的归属资料不完整，线路尚未删除。';return $false}
 $txPath=OHPath $Plan.Root (Join-Path $Plan.Root ('connection-transactions\'+$id+'.json'));$tx=LCRead $Plan.Root $txPath
 $status=[string](OHField $tx Status '')
 if((OHField $tx SchemaVersion 0) -ne 1 -or (OHField $tx Id '') -cne $id -or (OHField $tx Root '') -ine $Plan.Root -or (OHField $tx JournalPath '') -ine $txPath -or $status -notin @('Completed','RolledBack','ResolvedStopped','Aborted') -or (OHField $tx Phase '') -cne $status){LCBlock $Plan CurrentTransaction '上次连接的结果还需要核对。线路尚未删除。';return $false}
 $manifestPath=[string](OHField $Doc ManifestPath '')
 if(-not $manifestPath -or (OHField $tx ActiveManifestPath '') -ine $manifestPath -or (OHField $tx ActiveManifestSHA256 '') -cne (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash){LCBlock $Plan StopUnverified '上次连接的配置归属发生变化，线路尚未删除。';return $false}
 if($status -eq 'RolledBack'){
  $configuration=OHField $tx ConfigurationRestored;$connection=OHField $tx ConnectionRestored
  $original=OHField $tx Original;$originalManifest=OHField $original Manifest;$originalPath=[string](OHField $originalManifest Path '')
  $manifestRestored=($originalPath -and $originalPath.StartsWith($Plan.Root+'\',[StringComparison]::OrdinalIgnoreCase) -and (LCSnapshotMatches $Plan $originalManifest $originalPath.Substring($Plan.Root.Length+1)))
  if($configuration -isnot [bool] -or $configuration -ne $true -or $connection -isnot [bool] -or $connection -ne $true -or -not (LCSnapshotMatches $Plan (OHField $original Deployment) 'deployment.json') -or -not $manifestRestored){LCBlock $Plan RecoveryUnverified '上次连接尚未完成恢复核对。线路尚未删除。';return $false}
 }
 if($status -in @('ResolvedStopped','Aborted')){
  # Their resolution contracts do not establish ownership of an approved
  # candidate snapshot. Keep these unusual references for explicit recovery.
  LCBlock $Plan StopUnverified '上次连接还需要核对原记录。线路尚未删除。';return $false
 }
 if($Relative -ceq 'runtime.json'){
  $identity=OHField $tx CandidateIdentity
  foreach($name in @('SessionId','EnginePid','EngineStartedAt','SupervisorPid','SupervisorStartedAt')){
   if(-not (OHField $identity $name) -or [string](OHField $identity $name '') -cne [string](OHField $Doc $name '')){LCBlock $Plan StopUnverified '上次连接的进程身份还需要核对。线路尚未删除。';return $false}
  }
  if((OHField $identity ManifestPath '') -ine $manifestPath -or (OHField $Doc ConfigPath '') -ine (OHField $Manifest CandidatePath '')){LCBlock $Plan StopUnverified '上次连接的配置与停止记录不一致。线路尚未删除。';return $false}
 }
 # Unresolved local proxy recovery is never erased or treated as a clean stop.
 $recoveryRoot=OHPath $Plan.Root (Join-Path $Plan.Root 'proxy-recovery')
 if([IO.Directory]::Exists($recoveryRoot)){
  foreach($file in @(Get-ChildItem -LiteralPath $recoveryRoot -File -Filter '*.json')){
   $entry=LCRead $Plan.Root $file.FullName
   if((OHField $entry SchemaVersion 0) -ne 1 -or (OHField $entry Stage '') -notin @('Restored','Unchanged','UserRestored','UserKeptCurrent')){LCBlock $Plan RecoveryUnverified '普通网络设置还有待核对，线路尚未删除。';return $false}
   $Plan.EvidenceSnapshots[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
  }
 }
 $path=OHPath $Plan.Root (Join-Path $Plan.Root $Relative)
 $replacement=LCStoppedReferenceValue $Doc $Relative
 if(LCTransactionBound $Plan $replacement){LCBlock $Plan StopUnverified '停止记录还有其他配置依赖，线路尚未删除。';return $false}
 $release=[pscustomobject]@{SchemaVersion=1;Operation='ReleaseStoppedConnectionReference';RootDigest=(Get-TCDDigest $Plan.Root.ToLowerInvariant());UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;SourceSHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;TransactionId=$id;TransactionSHA256=(Get-FileHash -LiteralPath $txPath -Algorithm SHA256).Hash;StopEvidence=$proof}
 $Plan.ReferenceReleases[$path]=$release;$Plan.Replacements[$path]=$replacement
 $Plan.Preserved.Add('保留已停止会话的身份、清理及保护记录，仅解除经核实的历史配置引用。')
 return $true
}
function LCPlan {param([string]$Root,[string[]]$Ids,[string[]]$OwnedLocks=@(),[bool]$AbandonLocalTracking=$false,[string]$Scope='')
 $clock=[Diagnostics.Stopwatch]::StartNew();$c=OHSnapshot $Root $OwnedLocks;$snapshotMs=$clock.ElapsedMilliseconds
 $p=[pscustomobject]@{PlanVersion=3;Scope=$Scope;Root=$c.Root;Context=$c;SelectedIds=@($Ids|Sort-Object -Unique);ServerIds=@{};ReferencedServerIds=@{};RunIds=@{};LineIds=@{};RetainedLineIds=@{};Bindings=@{};Endpoints=@{};Paths=@{};Records=@{};Files=@();Replacements=@{};QualitySnapshots=@{};QualityIntents=@{};ReferenceReleases=@{};UsageEvidence=$null;EvidenceSnapshots=@{};TargetTransactionIds=@{};Timings=@{};ProtectedFiles=@{};RetentionLocks=@{};RetainedLocks=@{};RetireLocks=@{};RetainedItems=@();Blocked=(New-Object 'Collections.Generic.List[object]');Warnings=(New-Object 'Collections.Generic.List[object]');Executors=@{};AbandonLocalTracking=$AbandonLocalTracking;RemoteOutcomeUnverified=$false;LocalCandidateAbandonment=$false;Preserved=(New-Object 'Collections.Generic.List[string]');Targets=@();Digest=''}
 if(-not $p.SelectedIds.Count){LCFail SelectionEmpty '请先选择要清理的记录。'}
 $scopes=@($p.SelectedIds|ForEach-Object {if($_ -clike 'Line:*'){'Line'}elseif($_ -clike 'ServerRecord:*'){'Server'}else{'DeploymentTask'}}|Sort-Object -Unique)
 if($scopes.Count -ne 1 -or ($Scope -and $Scope -cne $scopes[0])){LCFail ScopeMismatch '一次只清理明确选择的线路、部署任务或服务器范围。'}
 $p.Scope=$scopes[0]
 foreach($id in $p.SelectedIds){
  if($id -cnotmatch '^(ServerRecord|DeploymentRun|LegacyLinuxJob|ManagementIntent|Line):([0-9a-f-]{36})$'){LCFail InvalidId '所选记录标识无效。'}
  $kind=$matches[1];$key=OHId $matches[2]
  if($kind -eq 'Line'){
   if(-not @((OHField $c.Index nodes @())|Where-Object id -ceq $key).Count){LCFail RecordMissing '线路已变化，请刷新后重新选择。'}
   foreach($lineId in @(LCLineFamily $c $key)){LCAdd $p.LineIds $lineId}
   foreach($s in $c.Servers){if($key -in @(OHField $s LinkedNodeIds @())){LCAdd $p.ReferencedServerIds $s.LocalRecordId}}
  }elseif($kind -eq 'ServerRecord'){
   if(-not $c.ServersById.ContainsKey($key)){LCFail RecordMissing '服务器记录已变化，请刷新。'};LCAdd $p.ServerIds $key
  }else{
   if(-not $c.ById.ContainsKey($id)){LCFail RecordMissing '部署记录已变化，请刷新。'}
   $p.Records[$id]=$c.ById[$id];LCAdd $p.RunIds $key
   foreach($sid in $c.ById[$id].ServerIds){LCAdd $p.ReferencedServerIds $sid}
   foreach($line in @(LCOwnedUnpublishedLineIds $p $c.ById[$id])){LCAdd $p.LineIds $line}
  }
 }
 # Ownership closure uses explicit IDs, never endpoint or shared server keys.
 if($p.Scope -eq 'Server'){
  foreach($sid in @($p.ServerIds.Keys)){
   $s=$c.ServersById[$sid];$proof=OHField $s Reinstall;$oldId=[string](OHField $proof PreviousServerId '');$old=$c.ServersById[$oldId]
   if($old -and (OHField $old ReplacedByServerId '') -ceq $sid -and (OHField $proof ChangeDigest '') -cmatch '^[a-f0-9]{64}$' -and (OHTime (OHField $proof ConfirmedAtUtc)) -ceq (OHTime (OHField $old ArchivedAtUtc))){LCAdd $p.ServerIds $oldId}
  }
  foreach($s in $c.Servers){
   if($p.ServerIds.ContainsKey($s.LocalRecordId)){
    foreach($id in @(OHField $s SourceJobIds @())){LCAdd $p.RunIds $id};foreach($id in @(OHField $s LinkedNodeIds @())){LCAdd $p.LineIds $id}
   }
  }
 }
 foreach($r in $c.Records){
  $outputs=@(LCReferencedLineIds $r.Doc)
  $ownsOutput=($outputs.Count -gt 0 -and @($outputs|Where-Object {-not $p.LineIds.ContainsKey($_)}).Count -eq 0)
  if($p.Records.ContainsKey($r.Id) -or ($p.Scope -eq 'Server' -and ($p.RunIds.ContainsKey($r.SourceId) -or @($r.ServerIds|Where-Object {$p.ServerIds.ContainsKey($_)}).Count)) -or ($p.Scope -eq 'Line' -and $ownsOutput)){
   $p.Records[$r.Id]=$r;LCAdd $p.RunIds $r.SourceId
   foreach($sid in $r.ServerIds){LCAdd $p.ReferencedServerIds $sid}
   if($p.Scope -eq 'Server'){foreach($line in $outputs){LCAdd $p.LineIds $line}}
  }
 }
 # Alias outputs belong to the selected logical line; unrelated server siblings do not.
 foreach($id in @($p.LineIds.Keys)){$line=$c.Lines[$id];foreach($alias in @(OHField $line AliasIds @())){LCAdd $p.LineIds $alias}}
 # Drop only a registry record whose last local line/task reference is gone.
 if($p.Scope -ne 'Server'){
  foreach($sid in @($p.ReferencedServerIds.Keys)){
   $s=$c.ServersById[$sid];if(-not $s){continue}
   $otherLines=@((OHField $s LinkedNodeIds @())|Where-Object {-not $p.LineIds.ContainsKey($_)})
   $otherTasks=@($c.Records|Where-Object {$_.ServerIds -contains $sid -and -not $p.Records.ContainsKey($_.Id)})
   if(-not $otherLines.Count -and -not $otherTasks.Count -and -not $p.RetainedLineIds.Count){LCAdd $p.ServerIds $sid}else{$p.Preserved.Add('仍被其他线路或任务引用的服务器登记与共享登录资料')}
  }
 }
 foreach($r in $p.Records.Values){
  OHWalk $r.Doc {param($name,$value,$parent)
   if($name -in @('RequestId','EnrollmentId') -and $value -is [string]){LCAdd $p.Bindings ($name+':'+$value)}
  } -Names @('RequestId','EnrollmentId')
 }
 if($p.Scope -eq 'Server'){
  foreach($sid in $p.ServerIds.Keys){$s=$c.ServersById[$sid];foreach($field in @('RemoteOwnerId','ServerPublicKey')){LCAdd $p.Bindings ($field+':'+[string](OHField $s $field ''))}}
 }
 foreach($s in $c.Servers){if($p.ServerIds.ContainsKey($s.LocalRecordId)){$p.Targets+=,[pscustomobject]@{Id=$s.LocalRecordId;Name=(OHText (OHField $s Name) '服务器');Endpoint=(LCEndpoint (OHField $s Connection));Archived=((OHField $s RecordState 'Active') -eq 'Archived')}}}
 foreach($r in $p.Records.Values){if(-not $r.ServerIds.Count){$p.Targets+=,[pscustomobject]@{Id=$r.Id;Name=(OHText (OHField $r.Doc Name) ('未关联记录 '+$r.SourceId.Substring(0,8)));Endpoint=(LCEndpoint (OHField $r.Doc Connection));Archived=$false}}}
 foreach($r in $p.Records.Values){
  if(@($r.Reasons|Where-Object {$_ -in @('SourceMetadataInvalid','SourceIdentityMismatch','UnknownState')}).Count){LCBlock $p InvalidSource '关联记录格式或归属不完整，无法安全确定清理范围。'}
  $retired=LCRetiredLegacy $p $r
  # An exact, digest-bound task retired by a confirmed server identity reset
  # cannot be reconciled against the new OS. Removing its local files does not
  # claim that its old authorization succeeded or was rolled back.
  LCRisk $p $r.Doc $r.SourceKind -Retired:$retired;LCRisk $p $r.Result $r.SourceKind -Retired:$retired
  if($r.SourceKind -eq 'LegacyLinuxJob' -and -not $retired -and $r.Operation -in @('Apply','Authorize','Finalize','Recover','Uninstall') -and (OHField $r.Result OutcomeUnknown) -isnot [bool]){LCUnresolved $p Unresolved '旧版变更缺少明确的执行结果；可先核对原操作，或明确只放弃本机跟踪。'}
  LCAddPath $p $r.Directory $r.SourceKind
 }
 # Import may finish immediately before the run/index publication is interrupted.
 # Identify that unique local artifact by all original public bindings and the
 # source config digest; never claim an old node from BeforeNodeIds as its output.
 foreach($r in $p.Records.Values){
  $transaction=OHField $r.Doc CandidateTransaction;$configHash=[string](OHField $transaction ConfigHash '')
  $clientKey=[string](OHField (OHField $r.Doc ClientRequest) ClientPublicKey '');$serverKey=[string](OHField (OHField $r.Doc ClientResponse) ServerPublicKey '')
  if($configHash -notmatch '^[a-fA-F0-9]{64}$' -or -not $clientKey -or -not $serverKey){continue}
  if($p.Scope -eq 'DeploymentTask' -and ((OHField $r.Doc Intent '') -eq 'Existing' -or (OHField $r.Doc ExistingDevice $false) -or (OHField $transaction State '') -eq 'Completed' -or (OHField $r.Doc Stage '') -eq 'ReadyInactive')){continue}
  $matches=@()
  foreach($area in @('Product\nodes','Product\.staging')){
   $base=OHPath $p.Root (Join-Path $p.Root $area);if(-not [IO.Directory]::Exists($base)){continue}
   foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory -Force)){
    $null=OHPath $p.Root $dir.FullName;if($dir.Name -in @(OHField $transaction BeforeNodeIds @())){continue}
    $manifest=LCRead $p.Root (Join-Path $dir.FullName 'manifest.json')
    if($manifest -and (OHField $manifest ExportSHA256 '') -ieq $configHash -and (OHField $manifest ClientPublicKey '') -ceq $clientKey -and (OHField $manifest ServerPublicKey '') -ceq $serverKey){
     $node=OHId $dir.Name
     if($p.Scope -ne 'DeploymentTask' -or (LCExclusiveCandidate $p $r $node $manifest)){$matches+=,[pscustomobject]@{Id=$node;Path=$dir.FullName;Area=$area}}
    }
   }
  }
  if(@($matches|ForEach-Object Id|Sort-Object -Unique).Count -gt 1){$p.Preserved.Add('候选归属不唯一，保留相关产物以供核对。');continue}
  foreach($match in $matches){LCAddPath $p $match.Path CandidateArtifact;if($match.Area -eq 'Product\nodes'){LCAdd $p.LineIds $match.Id}}
 }
 foreach($id in @($p.LineIds.Keys)){
  $null=OHId $id
  foreach($area in @('Product\nodes','Product\lines')){LCAddPath $p (Join-Path $p.Root ($area+'\'+$id)) Line}
 }
 LCQualityCaches $p
 foreach($cache in @(@{Relative='last-successful-connection.json';Owner='';Field=''})){
  $cachePath=Join-Path $p.Root $cache.Relative
  if([IO.File]::Exists($cachePath)){
   $doc=LCRead $p.Root $cachePath
   if((OHField $doc SchemaVersion 0) -eq 1 -and (-not $cache.Owner -or (OHField $doc Owner '') -ceq $cache.Owner)){
    $binding=if($cache.Field){OHField $doc $cache.Field}else{$doc};$nodeId=[string](OHField $binding NodeId '')
    if($nodeId -and $p.LineIds.ContainsKey($nodeId)){LCAddPath $p $cachePath 'LineCache'}
   }
  }
 }
 # A dangling linked ID that also belongs to another server is not permission
 # to erase that other server's client material.
 if($p.Scope -eq 'Server'){foreach($s in $c.Servers){if(-not $p.ServerIds.ContainsKey($s.LocalRecordId) -and @((OHField $s LinkedNodeIds @())|Where-Object {$p.LineIds.ContainsKey($_)}).Count){LCBlock $p SharedLine '所选服务器与另一台服务器共用线路，需要先核对归属。'}}}
 foreach($area in @('deployments\hosts','probes','linux-probes','identities','pairing','Product\.staging','import')){
  $base=OHPath $p.Root (Join-Path $p.Root $area)
  if(-not [IO.Directory]::Exists($base)){continue}
  foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory -Force)){
   $null=OHPath $p.Root $dir.FullName;$docs=@(LCMetadata $p.Root $dir.FullName)
   $matched=$p.RunIds.ContainsKey($dir.Name) -or @($docs|Where-Object {LCBound $p $_}).Count -gt 0
   # Session references bind an executor directory even if its receipt is absent.
   foreach($r in $p.Records.Values){foreach($f in @('SessionRef','AttemptSessionRef')){if((OHField (OHField $r.Doc $f) InstanceId '') -ceq $dir.Name){$matched=$true}}}
   if($matched){
    foreach($doc in $docs){
     if($area -eq 'probes'){LCRisk $p $doc Probe}
     elseif($area -eq 'deployments\hosts'){
      if((OHField $doc Mutating $false) -and (OHField $doc Status '') -in @('Running','OutcomeUnknown')){LCUnresolved $p Unresolved '部署执行器仍有未核对的远端变更；可先核对结果，或明确只放弃本机跟踪。'}
      if(LCProcessAlive $doc){LCBlock $p ExecutorActive '关联部署执行器仍在运行。'}
     }
    }
    LCAddPath $p $dir.FullName $area
   }
  }
 }
 # Keep current runtime and unresolved rollback references alive. A successful
 # A -> B transaction no longer needs A's rollback snapshot, while B may still
 # depend on its approved manifest. Retire only Original in the same journaled
 # cleanup; never remove the whole current transaction family to delete A.
 $current=LCRead $p.Root (Join-Path $p.Root 'deployment.json');$runtime=LCRead $p.Root (Join-Path $p.Root 'runtime.json')
 $currentTransactions=@{};$currentManifests=@{}
 foreach($reference in @(@{Relative='deployment.json';Doc=$current},@{Relative='runtime.json';Doc=$runtime})){
  $doc=$reference.Doc;if(-not $doc){continue}
  $manifest=[string](OHField $doc ManifestPath '');$m=if($manifest){LCRead $p.Root $manifest}else{$null}
  $affected=(LCTransactionBound $p $doc) -or (LCBound $p $m)
  if($affected){foreach($transactionId in @([string](OHField $m TCTransactionId ''),[string](OHField $doc TransactionId ''))){if($transactionId -cmatch '^[a-f0-9]{32}$'){$p.TargetTransactionIds[$transactionId]=$true}}}
  if($affected -and (LCReleaseStoppedReference $p $reference.Relative $doc $m)){continue}
  $id=[string](OHField $doc TransactionId '');if($id){$currentTransactions[$id]=$true}
  if($affected){LCBlock $p CurrentLine '此线路仍被连接或待核对的恢复资料引用。线路尚未删除。'}
  if($manifest){$currentManifests[(OHPath $p.Root $manifest)]=$true;$id=[string](OHField $m TCTransactionId '');if($id){$currentTransactions[$id]=$true}}
 }
 $ownershipMs=$clock.ElapsedMilliseconds
 $txRoot=Join-Path $p.Root 'connection-transactions'
 if([IO.Directory]::Exists($txRoot)){foreach($file in @(Get-ChildItem -LiteralPath $txRoot -File -Filter '*.json')){
  $doc=LCRead $p.Root $file.FullName
  if(LCTransactionBound $p $doc){
   if((OHField $doc Id '') -cmatch '^[a-f0-9]{32}$'){$p.TargetTransactionIds[$doc.Id]=$true}
   $successful=((OHField $doc SchemaVersion 0) -eq 1 -and (OHField $doc Status '') -ceq 'Completed' -and (OHField $doc Phase '') -ceq 'Completed' -and (OHField $doc Id '') -ceq $file.BaseName)
   if($successful -and (OHField $doc Original)){
    $remaining=$doc|ConvertTo-Json -Depth 80|ConvertFrom-Json
    $remaining.Original=$null
    if(-not (LCTransactionBound $p $remaining)){
     $remaining|Add-Member NoteProperty OriginalRetention ([pscustomobject]@{State='RemovedByLocalCleanup';Reason='CompletedRollbackNoLongerRequired'}) -Force
     $p.Replacements[$file.FullName]=$remaining
     $p.Preserved.Add('保留其他线路的已完成连接事务及当前配置，仅清理不再需要的旧回退快照。')
     continue
    }
   }
   if((OHField $doc Status '') -notin @('Completed','RolledBack','ResolvedStopped','Aborted') -or $currentTransactions.ContainsKey([string](OHField $doc Id '')) -or $currentManifests.ContainsKey([string](OHField $doc ActiveManifestPath ''))){LCBlock $p CurrentTransaction '所选线路仍被当前连接事务或未完成的回退资料引用，请先核对原连接结果。'}
   else{
    LCAddPath $p $file.FullName ConnectionHistory
    $stem=$file.BaseName
    foreach($artifact in @(Get-ChildItem -LiteralPath $txRoot -File|Where-Object {$_.Name.StartsWith($stem+'-',[StringComparison]::Ordinal)})){LCAddPath $p $artifact.FullName ConnectionHistory}
   }
  }
 }}
 # Receipts are removed by exact request family; unrelated unknown jobs remain.
 $jobRoot=Join-Path $p.Root 'Product\jobs';$families=@{}
 if([IO.Directory]::Exists($jobRoot)){foreach($file in @(Get-ChildItem -LiteralPath $jobRoot -File -Filter '*.json')){
  if($file.Name -cnotmatch '^([a-f0-9]{32})\.(request|result|receipt)\.json$'){continue};$key=$matches[1]
  $doc=LCRead $p.Root $file.FullName
  if(LCBound $p $doc -Endpoint){$families[$key]=$true}
 }}
 foreach($id in $families.Keys){
  $receipt=LCRead $p.Root (Join-Path $jobRoot ($id+'.receipt.json'))
  if($receipt){
   if(LCProcessAlive $receipt ProcessId ProcessStartedTicks){LCBlock $p ExecutorActive '关联后台操作仍在运行。'}
   if((OHField $receipt Status '') -in @('Dispatched','OutcomeUnknown')){LCUnresolved $p ReceiptUnresolved '关联后台回执尚未核对；可先核对原操作，或明确只放弃本机跟踪。'}
  }
  foreach($leaf in @('request.json','result.json','receipt.json','request.json.partial','result.json.partial','receipt.json.partial')){LCAddPath $p (Join-Path $jobRoot ($id+'.'+$leaf)) BackgroundJob}
 }
 # Credentials shared by an unselected server must survive and are disclosed.
 # 0.23.0: the long-term envelope is referenced by SavedLoginRef; CredentialRef is
 # a remote-authorization fact and is never a local file name (Q7: no v1 file was
 # ever produced in production, so reading it here would only leak orphans).
 foreach($s in $c.Servers|Where-Object {$p.ServerIds.ContainsKey($_.LocalRecordId)}){
  $credential=[string](OHField $s SavedLoginRef '')
  if($credential){
   $null=OHId $credential
   if(@($c.Servers|Where-Object {-not $p.ServerIds.ContainsKey($_.LocalRecordId) -and (OHField $_ SavedLoginRef '') -ceq $credential}).Count){$p.Preserved.Add('另一台服务器仍引用的共享登录凭据')}
   else{LCAddPath $p (Join-Path $p.Root ('credentials\'+$credential+'.json')) Credential}
  }
  if(OHField (OHField $s Connection) IdentityFile ''){$p.Preserved.Add('用户自行提供的外部 SSH 私钥文件')}
 }
 # Task credentials are separate DPAPI envelopes owned by a canonical RunId.
 # Do not decrypt them and do not scan/delete unrelated credential files.
 foreach($runId in @($p.RunIds.Keys)){
  if($runId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){continue}
  $credentialPath=OHPath $p.Root (Join-Path $p.Root ('deployments\credentials\'+$runId+'.json'))
  if([IO.Directory]::Exists($credentialPath)){LCBlock $p InvalidSource '任务凭据路径类型不正确，未清理异常目录。'}else{LCAddPath $p $credentialPath TaskCredential}
 }
 # External source manifests are retained; only app-owned node/profile folders
 # can be removed. Removing an index entry never grants filesystem ownership.
 foreach($n in @(OHField $c.Index nodes @())){if($p.LineIds.ContainsKey([string]$n.id)){
  $manifest=[string](OHField $n manifestPath '')
  if($manifest -and -not $manifest.StartsWith((Join-Path $p.Root 'Product\nodes\'),[StringComparison]::OrdinalIgnoreCase) -and -not $manifest.StartsWith((Join-Path $p.Root 'Product\lines\'),[StringComparison]::OrdinalIgnoreCase)){$p.Preserved.Add('用户导入的外部配置源文件')}
 }}
 if([IO.Directory]::Exists((Join-Path $p.Root 'backup')) -or [IO.Directory]::Exists((Join-Path $p.Root 'diagnostics'))){$p.Preserved.Add('历史人工备份与诊断归档（不用于新建部署或自动续接）')}
 foreach($l in $c.Locks.Values){
  $affected=($l.ServerId -and $p.ServerIds.ContainsKey($l.ServerId)) -or ($l.RecordId -and $p.Records.ContainsKey($l.RecordId))
  foreach($path in $p.Paths.Keys){if($l.Path.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){$affected=$true}}
  if($affected -and (OHBusy $c $l.Path)){LCBlock $p ExecutorActive '关联资料正被另一个操作占用。'}
 }
 # Covers an executor created just before its SessionRef is saved and legacy
 # probe processes that have no structured ownership record.
 try{
  foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='TradeChannelDeployHost.exe' OR Name='sing-box.exe' OR Name='ssh.exe'" -ErrorAction Stop)){
   $command=[string]$process.CommandLine;if(-not $command){LCBlock $p ProcessUnknown '无法核对部署或检测进程的归属，请结束相关任务后再清理。';continue}
   foreach($path in $p.Paths.Keys){if($command.IndexOf($path,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or $command.IndexOf($path.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase) -ge 0){LCBlock $p ExecutorActive '关联执行器或检测进程仍在使用这些资料。'}}
   if($process.Name -ieq 'TradeChannelDeployHost.exe'){foreach($id in $p.RunIds.Keys){if($command.Contains($id)){LCBlock $p ExecutorActive '关联服务器执行器仍在运行。'}}}
  }
 }catch{LCBlock $p ProcessUnknown '无法读取执行器状态，本次清理尚未允许。'}
 $registry=LCRead $p.Root (Join-Path $p.Root 'servers\registry.json')
 if($registry){
  $oldDigest=Get-TCDDigest $registry
  $registry.Servers=@($registry.Servers|Where-Object {-not $p.ServerIds.ContainsKey($_.LocalRecordId)})
  foreach($s in $registry.Servers){
   if($s.PSObject.Properties['LinkedNodeIds']){$s.LinkedNodeIds=@($s.LinkedNodeIds|Where-Object {-not $p.LineIds.ContainsKey($_)})}
   if($s.PSObject.Properties['SourceJobIds']){$s.SourceJobIds=@($s.SourceJobIds|Where-Object {-not $p.RunIds.ContainsKey($_)})}
  }
  if((Get-TCDDigest $registry) -cne $oldDigest){$registry.Revision=[long]$registry.Revision+1;$p.Replacements[(Join-Path $p.Root 'servers\registry.json')]=$registry}
 }
 if($c.Index -and @((OHField $c.Index nodes @())|Where-Object {$p.LineIds.ContainsKey([string]$_.id)}).Count){$index=$c.Index|ConvertTo-Json -Depth 40|ConvertFrom-Json;$index.nodes=@($index.nodes|Where-Object {-not $p.LineIds.ContainsKey([string]$_.id)});$p.Replacements[(Join-Path $p.Root 'Product\index.json')]=$index}
 $preference=LCRead $p.Root (Join-Path $p.Root 'ui-preferences.json')
 if($preference -and $p.LineIds.ContainsKey([string](OHField $preference NodeId ''))){$preference.NodeId='';if($preference.PSObject.Properties['ProfileId']){$preference.ProfileId=''};$p.Replacements[(Join-Path $p.Root 'ui-preferences.json')]=$preference}
 $keys=@($p.Records.Keys)+@($p.ServerIds.Keys|ForEach-Object {'ServerRecord:'+$_})
 foreach($rel in @('operation-history\removed-records.json','operation-history\visibility.json','deployments\draft-dispositions.json')){
  $path=Join-Path $p.Root $rel;$doc=LCRead $p.Root $path;if(-not $doc){continue}
  $oldDigest=Get-TCDDigest $doc
  if($doc.PSObject.Properties['Entries']){$doc.Entries=@($doc.Entries|Where-Object {(OHField $_ Id '') -notin $keys})}
  if($doc.PSObject.Properties['Commits']){$doc.Commits=@($doc.Commits|Where-Object {@(@(OHField $_ SelectedIds @())+@(OHField $_ DeletedIds @())+@(OHField $_ CandidateIds @())|Where-Object {$_ -in $keys}).Count -eq 0})}
  if((Get-TCDDigest $doc) -cne $oldDigest){if($doc.PSObject.Properties['Revision']){$doc.Revision=[long]$doc.Revision+1};$p.Replacements[$path]=$doc}
 }
 # Keep immutable sources still referenced by unselected lines/tasks.
 $outside=@($c.Lines.Values|Where-Object {-not $p.LineIds.ContainsKey([string]$_.LineId)}|ForEach-Object {[pscustomobject]@{Id=('Line:'+ $_.LineId);Doc=$_;Path=(Join-Path $p.Root ('Product\lines\'+$_.LineId+'\line.json'));Lock=(Join-Path $p.Root ('Product\lines\'+$_.LineId+'\.line.lock'))}})+@($c.Records|Where-Object {-not $p.Records.ContainsKey($_.Id)}|ForEach-Object {[pscustomobject]@{Id=$_.Id;Doc=$_.Doc;Path=$(if($_.SourceKind -eq 'ManagementIntent'){$_.Directory}else{Join-Path $_.Directory $(if($_.SourceKind -eq 'DeploymentRun'){'state.json'}else{'job.json'})});Lock=$(if($_.SourceKind -eq 'ManagementIntent'){Join-Path $p.Root 'servers\.registry.lock'}else{Join-Path $_.Directory $(if($_.SourceKind -eq 'DeploymentRun'){'.run.lock'}else{'.execution.lock'})})}})
 foreach($reference in $outside){
  OHWalk $reference.Doc {param($name,$value,$parent)
   if($value -isnot [string] -or -not [IO.Path]::IsPathRooted($value)){return}
   if(-not $value.StartsWith($p.Root+'\',[StringComparison]::OrdinalIgnoreCase)){return}
   $full=OHPath $p.Root $value
   foreach($path in @($p.Paths.Keys)){
    if($full -ieq $path -or $full.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){
     $keep=if([IO.Directory]::Exists($full)){$full}else{Split-Path $full -Parent}
     foreach($file in @(LCFiles $p.Root $keep)){
      if(-not $p.ProtectedFiles.ContainsKey($file.FullName)){$p.ProtectedFiles[$file.FullName]=@{}}
      $p.ProtectedFiles[$file.FullName][$reference.Id]=[pscustomobject]@{Id=$reference.Id;Path=$reference.Path;Digest=(Get-TCDDigest $reference.Doc);Field=$name}
     }
     $p.RetentionLocks[$reference.Lock]=$true
     $p.Preserved.Add('其他线路或任务仍引用的不可变来源资料')
    }
   }
  } -Names @('RequestDirectory','CandidateManifestPath','ManifestPath','SourceManifestPath','SourceCandidateManifestPath','IdentityFile')
 }
 # Preserve precisely known shared sources and the leases for their surviving
 # directories. Unknown lock-named files are data, not permission to retire a lock.
 foreach($path in @($p.Paths.Keys)){foreach($file in @(LCFiles $p.Root $path)){
  if($file.Name -like '*.lock' -and -not $c.Locks.ContainsKey($file.FullName) -and -not $p.ProtectedFiles.ContainsKey($file.FullName)){
   $p.ProtectedFiles[$file.FullName]=@{};$p.Preserved.Add('归属未登记的锁文件保持原位，不按扩展名删除。')
  }
 }}
 foreach($lock in $c.Locks.Values){
  if(-not @($p.Paths.Keys|Where-Object {$lock.Path.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){continue}
  $parent=Split-Path $lock.Path -Parent
  if(@($p.ProtectedFiles.Keys|Where-Object {$_ -ine $lock.Path -and $_.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -or $p.ProtectedFiles.ContainsKey($lock.Path)){$p.RetainedLocks[$lock.Path]=$true}else{$p.RetireLocks[$lock.Path]=$true}
 }
 $retained=@()
 foreach($path in @($p.ProtectedFiles.Keys|Sort-Object)){
  if($c.Locks.ContainsKey($path)){continue}
  $file=Get-Item -LiteralPath (OHPath $p.Root $path) -Force
  $retained+=,[pscustomobject]@{Path=$path;Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=$file.Length;Reason='SharedSourceOrUnownedLock';References=@($p.ProtectedFiles[$path].Values|Sort-Object Id)}
 }
 $p.RetainedItems=$retained
 $files=@{}
 foreach($path in $p.Paths.Keys){foreach($file in @(LCFiles $p.Root $path)){
  if($file.Name -like '*.lock' -or $p.ProtectedFiles.ContainsKey($file.FullName)){continue}
  $snapshot=$p.QualitySnapshots[$file.FullName]
  $files[$file.FullName]=[pscustomobject]@{Path=$file.FullName;Hash=$(if($snapshot){$snapshot.Hash}else{(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash});Kind=$p.Paths[$path];Bytes=$(if($snapshot){$snapshot.Bytes}else{$file.Length});Replace=$false}
 }}
 foreach($path in $p.Replacements.Keys){$file=Get-Item -LiteralPath (OHPath $p.Root $path);$snapshot=$p.QualitySnapshots[$path];$files[$path]=[pscustomobject]@{Path=$path;Hash=$(if($snapshot){$snapshot.Hash}else{(Get-FileHash -LiteralPath $path).Hash});Kind=$(if($p.ReferenceReleases.ContainsKey($path)){'StoppedReference'}elseif($snapshot){'LineCache'}else{'Index'});Bytes=$(if($snapshot){$snapshot.Bytes}else{$file.Length});Replace=$true}}
 foreach($path in $p.QualitySnapshots.Keys){
  # Unlocked plans only publish ownership intent. The executable byte hashes
  # and replacements are rebuilt and verified under the real store lock.
  if($p.QualityIntents.ContainsKey($path) -and (Join-Path $p.Root 'Product\.store.lock') -notin $OwnedLocks){continue}
  if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $p.QualitySnapshots[$path].Hash){LCFail Changed '线路质量缓存已更新，请重新预览后清理。'}
 }
 # Release historical pointers first; rollback restores their targets first.
 $p.Files=@($files.Values|Sort-Object @{Expression={if($_.Kind -ceq 'StoppedReference'){0}else{1}}},Path)
 foreach($path in $p.EvidenceSnapshots.Keys){if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $p.EvidenceSnapshots[$path]){LCFail Changed '恢复资料已变化，请重新检查后删除。'}}
 $sealedReplacements=@{};foreach($path in $p.Replacements.Keys){if(-not $p.QualityIntents.ContainsKey($path)){$sealedReplacements[$path]=$p.Replacements[$path]}}
 $sealedFiles=@($p.Files|Where-Object {-not $p.QualityIntents.ContainsKey($_.Path)})
 $p.Digest=Get-TCDDigest @{PlanVersion=3;Scope=$p.Scope;Ids=$p.SelectedIds;Servers=@($p.ServerIds.Keys|Sort-Object);ReferencedServers=@($p.ReferencedServerIds.Keys|Sort-Object);Runs=@($p.RunIds.Keys|Sort-Object);Lines=@($p.LineIds.Keys|Sort-Object);RetainedLines=@($p.RetainedLineIds.Keys|Sort-Object);OwnershipRevision=$c.Digest;Files=$sealedFiles;QualityIntents=$p.QualityIntents;RetainedItems=$p.RetainedItems;RetainedLocks=@($p.RetainedLocks.Keys|Sort-Object);RetireLocks=@($p.RetireLocks.Keys|Sort-Object);Replacements=$sealedReplacements;ReferenceReleases=$p.ReferenceReleases;EvidenceSnapshots=$p.EvidenceSnapshots;Blocked=@($p.Blocked.ToArray());Warnings=@($p.Warnings.ToArray());AbandonLocalTracking=$p.AbandonLocalTracking;RemoteOutcomeUnverified=$p.RemoteOutcomeUnverified;LocalCandidateAbandonment=$p.LocalCandidateAbandonment;Preserved=@($p.Preserved|Sort-Object -Unique)}
 $p.Timings=@{SnapshotMs=$snapshotMs;OwnershipAndSelectionMs=($ownershipMs-$snapshotMs);RemainingPlanMs=($clock.ElapsedMilliseconds-$ownershipMs);TotalMs=$clock.ElapsedMilliseconds}
 return $p
}
function LCToken {param($Value,[string]$Root,[string]$Token)
 Add-Type -AssemblyName System.Security;$bytes=$null;$entropy=[Text.Encoding]::UTF8.GetBytes('TradeChannel.LocalCleanup.v1')
 try{
  if($PSBoundParameters.ContainsKey('Value')){$bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 8 -Compress));return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser))}
  if(-not $Token -or $Token.Length -gt 262144){throw 'size'}
  $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser);$v=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
  if($v.Kind -cne 'LocalDeploymentCleanup' -or $v.RootDigest -cne (Get-TCDDigest $Root.ToLowerInvariant()) -or $v.Ids -isnot [array] -or $v.Digest -cnotmatch '^[a-f0-9]{64}$'){throw 'binding'}
  if($v.PSObject.Properties['AbandonLocalTracking'] -and $v.AbandonLocalTracking -isnot [bool]){throw 'intent'}
  $null=OHId $v.Id;return $v
 }catch{LCFail PreviewInvalid '清理确认已失效，请重新预览。'}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function Get-TCLocalCleanupPending {param([string]$Root)
 $base=OHPath (OHRoot $Root) (Join-Path $Root 'local-cleanup')
 if([IO.Directory]::Exists($base)){foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory)){
  $null=OHId $dir.Name;$journal=LCRead $Root (Join-Path $dir.FullName 'journal.json')
  if($journal -and $journal.Status -notin @('Completed','RolledBack')){$journal.Id}
 }}
}
function New-TCLocalDeploymentCleanupPreview {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string[]]$Ids,[switch]$AbandonLocalTracking,[ValidateSet('','Line','DeploymentTask','Server')][string]$Scope='')
 $ErrorActionPreference='Stop'
 if(@(Get-TCLocalCleanupPending $Root).Count){LCFail RecoveryRequired '上次本机清理被中断，请先完成本机恢复。'}
 $p=LCPlan $Root $Ids -AbandonLocalTracking ([bool]$AbandonLocalTracking) -Scope $Scope;$expiry=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds();$token=''
 if(-not $p.Blocked.Count){$token=LCToken -Value @{Kind='LocalDeploymentCleanup';PlanVersion=3;Scope=$p.Scope;RootDigest=(Get-TCDDigest $p.Root.ToLowerInvariant());Id=[guid]::NewGuid().ToString('D');Ids=$p.SelectedIds;Digest=$p.Digest;ExpiresAt=$expiry;AbandonLocalTracking=$p.AbandonLocalTracking}}
 $canAbandon=($p.RemoteOutcomeUnverified -and -not $p.AbandonLocalTracking -and $p.Blocked.Count -gt 0 -and -not @($p.Blocked|Where-Object {$_.Code -notin @('Unresolved','ReceiptUnresolved')}).Count)
 [pscustomobject]@{BusinessState=$(if($p.Blocked.Count){'PreviewBlocked'}else{'PreviewReady'});ReferenceReleaseCount=$p.ReferenceReleases.Count;TransactionIds=@($p.TargetTransactionIds.Keys|Sort-Object);Timings=$p.Timings;PlanVersion=3;Scope=$p.Scope;ReferencedServerIds=@($p.ReferencedServerIds.Keys);PreviewToken=$token;SelectedIds=$p.SelectedIds;Targets=$p.Targets;ServerCount=$p.ServerIds.Count;OperationCount=$p.Records.Count;LineCount=$p.LineIds.Count;RetainedLineIds=@($p.RetainedLineIds.Keys|Sort-Object);RetainedItems=@($p.RetainedItems|ForEach-Object {[pscustomobject]@{Path=$_.Path.Substring($p.Root.Length+1);Hash=$_.Hash;Reason=$_.Reason;ReferenceIds=@($_.References|ForEach-Object Id)}});FileCount=$p.Files.Count;Bytes=($p.Files|Measure-Object Bytes -Sum).Sum;EligibleCount=$(if($p.Blocked.Count){0}else{$p.SelectedIds.Count});ProtectedCount=$p.Blocked.Count;Blocked=@($p.Blocked.ToArray());Warnings=@($p.Warnings.ToArray());AbandonLocalTracking=$p.AbandonLocalTracking;CanAbandonLocalTracking=$canAbandon;RemoteOutcomeUnverified=$p.RemoteOutcomeUnverified;LocalCandidateAbandonment=$p.LocalCandidateAbandonment;Executors=@($p.Executors.Values|Sort-Object RunId);ExecutorWaitSeconds=5;Preserved=@($p.Preserved|Sort-Object -Unique);Files=@($p.Files|ForEach-Object {[pscustomobject]@{Path=$_.Path.Substring($p.Root.Length+1);Kind=$_.Kind}});DisplayOnly=$false;RemoteChanges=$false;NetworkChanged=$false}
}
function LCJournalPath {param([string]$Root,[string]$Id) Join-Path (Join-Path (OHPath $Root (Join-Path $Root 'local-cleanup')) (OHId $Id)) 'journal.json'}
# A journal must never inline replacement documents: their size is unbounded and
# one oversized write would leave the confirmation permanently unapplicable.
# Replacements live beside the stash and the journal keeps only their digest.
function LCValueStashPath {param([string]$Root,[string]$Id,[string]$Name) Join-Path (Join-Path (Split-Path (LCJournalPath $Root $Id) -Parent) 'stash') $Name}
function LCWriteValue {param([string]$Root,[string]$Id,[string]$Name,$Value)
 $path=OHPath $Root (LCValueStashPath $Root $Id $Name)
 Write-TCDJson $path $Value -Compact
 return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function LCReadValue {param([string]$Root,$Item,[string]$Id)
 $name=[string](OHField $Item ValueStash '')
 # Legacy journals kept the replacement inline; they stay readable.
 if(-not $name){return (OHField $Item Value)}
 if($name -cnotmatch '^[0-9]{6}\.value\.json$'){LCFail JournalInvalid '本机清理日志格式无效。'}
 $path=OHPath $Root (LCValueStashPath $Root $Id $name)
 if(-not [IO.File]::Exists($path)){LCFail JournalInvalid '本机清理替换内容缺失，原资料已保留。'}
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string](OHField $Item ValueDigest '')){LCFail JournalInvalid '本机清理替换内容已变化，原资料已保留。'}
 return (LCRead $Root $path)
}
function LCMove {param([string]$From,[string]$To) [IO.File]::Move($From,$To)}
function LCOpenLocks {param($Plan)
 $scope=[pscustomobject]@{Root=$Plan.Root;Locks=@{}}
 foreach($lock in $Plan.Context.Locks.Values){
  $lineLock=$lock.Path.StartsWith((Join-Path $Plan.Root 'Product\lines\'),[StringComparison]::OrdinalIgnoreCase)
  $include=(-not $lock.RecordId -and -not $lock.ServerId -and -not $lineLock) -or ($lock.RecordId -and $Plan.Records.ContainsKey($lock.RecordId)) -or ($lock.ServerId -and $Plan.ServerIds.ContainsKey($lock.ServerId)) -or $Plan.RetentionLocks.ContainsKey($lock.Path)
  foreach($path in $Plan.Paths.Keys){if($lock.Path.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){$include=$true}}
  if($include){$scope.Locks[$lock.Path]=$lock}
 }
 if($Plan.ReferenceReleases.Count){
  $scope.Locks[(Join-Path $Plan.Root '.runtime-command.lock')]=$true
  if([IO.Directory]::Exists((Join-Path $Plan.Root 'proxy-recovery'))){$scope.Locks[(Join-Path $Plan.Root 'proxy-recovery\.recovery.lock')]=$true}
 }
 # Global indexes still serialize with their writers; unrelated per-run and
 # per-server leases do not make deletion of this exact target permanently busy.
 return OHOpenLocks $scope
}
function LCAssertQualityLock {param($Plan,$Locks)
 if(-not $Plan.QualitySnapshots.Count){return}
 $expected=Join-Path $Plan.Root 'Product\.store.lock'
 for($i=0;$i -lt $Locks.Paths.Count;$i++){
  $handle=$Locks.Handles[$i]
  if($Locks.Paths[$i] -ieq $expected -and $handle -is [IO.FileStream] -and $handle.CanRead -and $handle.CanWrite -and -not $handle.SafeFileHandle.IsClosed -and $handle.Name -ieq $expected){return}
 }
 LCFail Changed '线路质量缓存的排他锁无法核验，原资料已保留。'
}
function LCAllowedPath {param([string]$Root,[string]$Path)
 $full=OHPath $Root $Path;$relative=$full.Substring($Root.Length+1)
 if($relative -cnotmatch '^(?:(?:deployments\\(?:runs|hosts|management-intents)|linux-jobs|linux-probes|probes|identities|pairing|import|credentials|Product\\(?:nodes|lines|jobs|\.staging)|connection-transactions)\\.+|deployments\\credentials\\[a-f0-9-]{36}\.json|servers\\registry\.json|Product\\(?:index|line-quality|standby-quality)\.json|last-successful-connection\.json|ui-preferences\.json|operation-history\\(?:removed-records|visibility)\.json|deployments\\draft-dispositions\.json)$'){LCFail UnsafePath '清理日志包含不受支持的数据路径。'}
 return $full
}
function LCItemPath {param([string]$Root,$Item)
 $full=OHPath $Root ([string](OHField $Item Path ''));$relative=$full.Substring($Root.Length+1)
 if($relative -cnotin @('runtime.json','deployment.json')){return LCAllowedPath $Root $full}
 $proof=OHField $Item ReferenceRelease;$stop=OHField $proof StopEvidence
 if((OHField $Item Replace $false) -ne $true -or (OHField $proof SchemaVersion 0) -ne 1 -or (OHField $proof Operation '') -cne 'ReleaseStoppedConnectionReference' -or (OHField $proof RootDigest '') -cne (Get-TCDDigest $Root.ToLowerInvariant()) -or (OHField $proof UserSid '') -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or (OHField $proof SourceSHA256 '') -cne (OHField $Item Hash '') -or (OHField $proof TransactionId '') -cnotmatch '^[a-f0-9]{32}$' -or (OHField $proof TransactionSHA256 '') -cnotmatch '^[A-Fa-f0-9]{64}$' -or (OHField $stop State '') -cne 'Stopped' -or (OHField $stop OwnershipKnown $false) -ne $true -or (OHField $stop SessionPresent $true) -ne $false){LCFail JournalInvalid '历史引用解除日志无法核验，保留原资料。'}
 return $full
}
function LCValidateJournal {param([string]$Root,$Journal)
 if($Journal.SchemaVersion -ne 1 -or $Journal.RootDigest -cne (Get-TCDDigest $Root.ToLowerInvariant()) -or $Journal.UserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Journal.Status -notin @('Preparing','Committed','Completed','RolledBack')){LCFail JournalInvalid '本机清理日志的账户或根目录不匹配。'}
 $null=OHId $Journal.Id
 if($Journal.Status -in @('Completed','RolledBack')){return}
 $seen=@{}
 foreach($item in $Journal.Items){
  $source=LCItemPath $Root $item
  if($seen.ContainsKey($item.Path) -or $item.Hash -cnotmatch '^[A-Fa-f0-9]{64}$' -or $item.Stash -cnotmatch '^[0-9]{6}\.stash$'){LCFail JournalInvalid '本机清理日志格式无效。'};$seen[$item.Path]=$true
  if((OHField $item Replace $false) -eq $true -and [string](OHField $item ValueStash '')){
   $valueName=[string](OHField $item ValueStash)
   if($valueName -cnotmatch '^[0-9]{6}\.value\.json$' -or [string](OHField $item ValueDigest '') -cnotmatch '^[A-Fa-f0-9]{64}$'){LCFail JournalInvalid '本机清理日志格式无效。'}
   $valuePath=OHPath $Root (LCValueStashPath $Root $Journal.Id $valueName)
   if(-not [IO.File]::Exists($valuePath) -or (Get-FileHash -LiteralPath $valuePath -Algorithm SHA256).Hash -cne [string](OHField $item ValueDigest)){LCFail JournalInvalid '本机清理替换内容无法核验，原资料已保留。'}
  }
  if(OHField $item ReferenceRelease){
   $stash=OHPath $Root (Join-Path (Split-Path (LCJournalPath $Root $Journal.Id) -Parent) ('stash\'+$item.Stash))
   $originalPath=if([IO.File]::Exists($stash)){$stash}else{$source}
   if(-not [IO.File]::Exists($originalPath) -or (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash -cne $item.Hash){LCFail JournalInvalid '历史引用的原始记录无法核验。'}
   $expected=LCStoppedReferenceValue (LCRead $Root $originalPath) $source.Substring($Root.Length+1)
   if((Get-TCDDigest $expected) -cne (Get-TCDDigest (LCReadValue $Root $item $Journal.Id))){LCFail JournalInvalid '历史引用日志包含超出范围的修改。'}
  }
 }
}
function LCPurge {param([string]$Root,[string]$Id)
 $directory=OHPath $Root (Join-Path (Split-Path (LCJournalPath $Root $Id) -Parent) 'stash')
 if(-not [IO.Directory]::Exists($directory)){return}
 foreach($file in @(Get-ChildItem -LiteralPath $directory -Force)){
  $null=OHPath $Root $file.FullName
  if($file.PSIsContainer -or $file.Name -cnotmatch '^[0-9]{6}\.(?:stash|value\.json)$'){LCFail JournalInvalid '本机清理暂存区存在意外文件。'}
  [IO.File]::Delete($file.FullName)
 }
 [IO.Directory]::Delete($directory,$false)
}
function LCRollback {param([string]$Root,$Journal)
 LCValidateJournal $Root $Journal;$base=Split-Path (LCJournalPath $Root $Journal.Id) -Parent
 foreach($item in @($Journal.Items|Sort-Object Stash -Descending)){
  $source=LCItemPath $Root $item;$stash=OHPath $Root (Join-Path (Join-Path $base 'stash') $item.Stash)
  if(-not [IO.File]::Exists($stash)){continue}
  if((Get-FileHash -LiteralPath $stash).Hash -cne $item.Hash){LCFail JournalInvalid '暂存资料已变化，保留现场以供核对。'}
  if([IO.File]::Exists($source)){
   $same=(Get-FileHash -LiteralPath $source).Hash -ceq $item.Hash
   if(-not $same -and (OHField $item Replace $false)){$same=(Get-TCDDigest (LCRead $Root $source)) -ceq (Get-TCDDigest (LCReadValue $Root $item $Journal.Id))}
   if(-not $same){LCFail RecoveryConflict '原资料在中断后被其他操作修改，未覆盖新内容。'}
   [IO.File]::Delete($source)
  }
  $null=New-TCDDirectory (Split-Path $source -Parent);LCMove $stash $source
 }
 LCPurge $Root $Journal.Id
 Write-TCDJson (LCJournalPath $Root $Journal.Id) @{SchemaVersion=1;Id=$Journal.Id;RootDigest=$Journal.RootDigest;UserSid=$Journal.UserSid;Status='RolledBack';TokenDigest=$Journal.TokenDigest;UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');Result=$Journal.Result}
}
function LCAssertReferenceStop {param($Plan)
 if($Plan.ReferenceReleases.Count){
  $actual=Get-TCConnectionUsageEvidence -Root $Plan.Root
  if((OHField $actual State '') -cne 'Stopped' -or (OHField $actual OwnershipKnown $false) -ne $true -or (OHField $actual SessionPresent $true) -ne $false){LCFail Changed '停止状态已变化，已停止删除并恢复原资料。'}
  foreach($name in @('SessionId','EnginePid','EngineStartedAt','SupervisorPid','SupervisorStartedAt')){if([string](OHField $actual $name '') -cne [string](OHField $Plan.UsageEvidence $name '')){LCFail Changed '会话身份已变化，已停止删除并恢复原资料。'}}
 }
}
function LCAssertRetained {param($Plan)
 LCAssertReferenceStop $Plan
 foreach($item in $Plan.RetainedItems){
  $path=OHPath $Plan.Root $item.Path
  if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $item.Hash){LCFail Changed '需要保留的共享资料已变化，已停止并恢复原记录。'}
  foreach($reference in $item.References){if((Get-TCDDigest (LCRead $Plan.Root $reference.Path)) -cne $reference.Digest){LCFail Changed '共享资料的引用已变化，已停止并恢复原记录。'}}
 }
}
function LCTrim {param([string]$Root,[string]$Directory,$Plan)
 $directory=LCAllowedPath $Root $Directory
 if(-not [IO.Directory]::Exists($directory)){return}
 foreach($child in @(Get-ChildItem -LiteralPath $directory -Force)){
  $null=OHPath $Root $child.FullName
  if($child.PSIsContainer){LCTrim $Root $child.FullName $Plan}
  elseif($Plan.RetainedLocks.ContainsKey($child.FullName)){continue}
  elseif($Plan.RetireLocks.ContainsKey($child.FullName)){[IO.File]::Delete($child.FullName)}
  elseif($Plan.ProtectedFiles.ContainsKey($child.FullName)){
   $item=@($Plan.RetainedItems|Where-Object Path -ieq $child.FullName)
   if($item.Count -ne 1 -or (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash -cne $item[0].Hash){LCFail Changed '需要保留的共享资料已变化，已停止并恢复原记录。'}
  }
  else{LCFail Changed '清理目录出现新资料，已停止并恢复原记录。'}
 }
 if(-not @(Get-ChildItem -LiteralPath $directory -Force).Count){[IO.Directory]::Delete($directory,$false)}
}
function LCFinish {param([string]$Root,$Journal)
 LCValidateJournal $Root $Journal;LCPurge $Root $Journal.Id
 $receipt=@{SchemaVersion=1;Id=$Journal.Id;RootDigest=$Journal.RootDigest;UserSid=$Journal.UserSid;Status='Completed';TokenDigest=$Journal.TokenDigest;UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');Result=$Journal.Result}
 Write-TCDJson (LCJournalPath $Root $Journal.Id) $receipt
 return $Journal.Result
}
function Repair-TCLocalDeploymentCleanup {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
 $ErrorActionPreference='Stop';$rootPath=OHRoot $Root;$gate=Open-TCDLock (Join-Path $rootPath '.local-cleanup.lock') -TimeoutMs 0;$locks=$null;$count=0;$completed=New-Object 'Collections.Generic.List[object]'
 try{
  foreach($id in @(Get-TCLocalCleanupPending $rootPath)){
   $journal=LCRead $rootPath (LCJournalPath $rootPath $id);LCValidateJournal $rootPath $journal
   # Nonwaiting global locks block every normal deployment/index writer while
   # restoring the original data. No remote or runtime operation is invoked.
   $dummy=[pscustomobject]@{Root=$rootPath;Locks=@{}}
   foreach($rel in @('servers\.registry.lock','deployments\.draft-disposition.lock','deployments\.credentials.lock','linux-jobs\.bridge.lock','.runtime-command.lock','proxy-recovery\.recovery.lock')){$dummy.Locks[(Join-Path $rootPath $rel)]=$true}
   $locks=OHOpenLocks $dummy
   try{if($journal.Status -eq 'Committed'){$completed.Add((LCFinish $rootPath $journal))}else{LCRollback $rootPath $journal};$count++}finally{OHCloseLocks $locks;$locks=$null}
  }
  [pscustomobject]@{RecoveredCount=$count;CompletedResults=@($completed.ToArray());RemoteChanges=$false;NetworkChanged=$false}
 }finally{OHCloseLocks $locks;$gate.Dispose()}
}
function Get-TCLocalDeploymentCleanupOutcome {
 [CmdletBinding(DefaultParameterSetName='Commit')]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true,ParameterSetName='Commit')][string]$PreviewToken,[Parameter(Mandatory=$true,ParameterSetName='Recovery')][switch]$Recovery)
 $ErrorActionPreference='Stop';$rootPath=OHRoot $Root;$gate=Open-TCDLock (Join-Path $rootPath '.local-cleanup.lock') -TimeoutMs 0
 try{
  if($Recovery){if(@(Get-TCLocalCleanupPending $rootPath).Count){return $null};return [pscustomobject]@{Outcome='NoPendingCleanup';DataDeleted=$false;RemoteChanges=$false;NetworkChanged=$false}}
  $token=LCToken -Root $rootPath -Token $PreviewToken;$journal=LCRead $rootPath (LCJournalPath $rootPath $token.Id)
  if(-not $journal){
   # Files cannot move before a durable journal exists. Absence alone is not
   # proof: every original source and index must still match the signed plan.
   if((OHField $token PlanVersion 0) -ne 3){return $null}
   $plan=LCPlan $rootPath $token.Ids -AbandonLocalTracking ([bool](OHField $token AbandonLocalTracking $false))
   if($plan.Blocked.Count -or $plan.Digest -cne $token.Digest){return $null}
   return [pscustomobject]@{Outcome='NotApplied';CleanupId=$token.Id;DataDeleted=$false;RemoteChanges=$false;NetworkChanged=$false}
  }
  LCValidateJournal $rootPath $journal
  if($journal.Id -cne $token.Id -or $journal.TokenDigest -cne (Get-TCDDigest $PreviewToken) -or (Get-TCDDigest @(OHField $journal.Result SelectedIds @())) -cne (Get-TCDDigest @($token.Ids))){LCFail JournalInvalid '原删除确认与清理日志不匹配，未解除待核对状态。'}
  if($journal.Status -notin @('Completed','RolledBack')){return $null}
  [pscustomobject]@{Outcome=$journal.Status;CleanupId=$journal.Id;DataDeleted=($journal.Status -eq 'Completed');RemoteChanges=$false;NetworkChanged=$false}
 }finally{$gate.Dispose()}
}
function Remove-TCLocalDeploymentData {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$PreviewToken)
 $ErrorActionPreference='Stop';$rootPath=OHRoot $Root;$token=LCToken -Root $rootPath -Token $PreviewToken
 $gate=Open-TCDLock (Join-Path $rootPath '.local-cleanup.lock') -TimeoutMs 0;$locks=$null;$journal=$null;$committed=$false
 try{
  $journalPath=LCJournalPath $rootPath $token.Id;$previous=LCRead $rootPath $journalPath
  if($previous){
   LCValidateJournal $rootPath $previous
   if($previous.TokenDigest -cne (Get-TCDDigest $PreviewToken)){LCFail PreviewInvalid '清理回执不属于这次确认。'}
   if($previous.Status -eq 'Completed'){$result=$previous.Result;$result|Add-Member NoteProperty AlreadyApplied $true -Force;return $result}
   if($previous.Status -eq 'Committed'){$result=LCFinish $rootPath $previous;$result|Add-Member NoteProperty AlreadyApplied $true -Force;return $result}
   LCFail RecoveryRequired '上次本机清理未完成，请先恢复后重新预览。'
  }
  if((OHField $token PlanVersion 0) -ne 3 -or (OHField $token Scope '') -notin @('Line','DeploymentTask','Server')){LCFail PreviewInvalid '旧清理预览需要按新的范围重新预览。'};if(@(Get-TCLocalCleanupPending $rootPath).Count){LCFail RecoveryRequired '上次本机清理未完成，请先恢复。'}
  if($token.ExpiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $token.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(11).ToUnixTimeSeconds()){LCFail PreviewStale '清理预览已过期，请重新预览。'}
  $before=LCPlan $rootPath $token.Ids -AbandonLocalTracking ([bool](OHField $token AbandonLocalTracking $false));$locks=LCOpenLocks $before
  $plan=LCPlan $rootPath $token.Ids $locks.Paths -AbandonLocalTracking ([bool](OHField $token AbandonLocalTracking $false))
  LCAssertQualityLock $plan $locks
  if($plan.Blocked.Count -or $plan.Digest -cne $token.Digest){LCFail PreviewStale '确认前资料或运行状态已变化，请重新预览。'}
  $result=[pscustomobject]@{BusinessState='Deleted';ReferenceReleaseCount=$plan.ReferenceReleases.Count;DeletedCount=$plan.SelectedIds.Count;ServerCount=$plan.ServerIds.Count;OperationCount=$plan.Records.Count;LineCount=$plan.LineIds.Count;RetainedLineIds=@($plan.RetainedLineIds.Keys|Sort-Object);RetainedItems=@($plan.RetainedItems|ForEach-Object {[pscustomobject]@{Path=$_.Path.Substring($rootPath.Length+1);Hash=$_.Hash;Reason=$_.Reason;ReferenceIds=@($_.References|ForEach-Object Id)}});FileCount=$plan.Files.Count;DeletedIds=@($plan.Records.Keys)+@($plan.ServerIds.Keys|ForEach-Object {'ServerRecord:'+$_});DeletedLineIds=@($plan.LineIds.Keys);SelectedIds=$plan.SelectedIds;DataDeleted=$true;DisplayOnly=$false;NetworkChanged=$false;RemoteChanges=$false;AlreadyApplied=$false;AbandonedLocalTracking=$plan.AbandonLocalTracking;RemoteOutcomeUnverified=$plan.RemoteOutcomeUnverified;RemoteRollbackConfirmed=$false;LocalCandidateAbandoned=$plan.LocalCandidateAbandonment;TaskCredentialsDeletedCount=@($plan.Files|Where-Object Kind -ceq 'TaskCredential').Count;Warnings=@($plan.Warnings.ToArray());Preserved=@($plan.Preserved|Sort-Object -Unique)}
  $base=Split-Path $journalPath -Parent;$stashRoot=New-TCDDirectory (Join-Path $base 'stash');$items=@();$number=0
  LCAssertReferenceStop $plan
  foreach($file in $plan.Files){
   # Replacement bytes are written first so the journal stays small and a crash
   # can still verify or restore every rewritten record.
   $valueName=$null;$valueDigest=$null
   if($file.Replace){$valueName=('{0:D6}.value.json' -f $number);$valueDigest=LCWriteValue $rootPath $token.Id $valueName $plan.Replacements[$file.Path]}
   $items+=,[pscustomobject]@{Path=$file.Path;Hash=$file.Hash;Stash=('{0:D6}.stash' -f $number);Replace=$file.Replace;ValueStash=$valueName;ValueDigest=$valueDigest;ReferenceRelease=$plan.ReferenceReleases[$file.Path]};$number++
  }
  $journal=[pscustomobject]@{SchemaVersion=1;Id=$token.Id;RootDigest=$token.RootDigest;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Status='Preparing';TokenDigest=(Get-TCDDigest $PreviewToken);Items=$items;Result=$result}
  Write-TCDJson $journalPath $journal -Compact
  foreach($item in $items){
   $source=LCItemPath $rootPath $item
   if((Get-FileHash -LiteralPath $source).Hash -cne $item.Hash){LCFail Changed '清理前资料发生变化，已停止并恢复原记录。'}
   LCMove $source (OHPath $rootPath (Join-Path $stashRoot $item.Stash))
   if($item.Replace){$qualityCache=$source.Substring($rootPath.Length+1) -cmatch '^Product\\(?:line-quality|standby-quality)\.json$';Write-TCDJson $source (LCReadValue $rootPath $item $token.Id) -Compact:$qualityCache}
  }
  # Retire per-object lock files only after the registry/index has been updated,
  # while the global registry/store/session locks still exclude new writers.
  LCAssertRetained $plan
  foreach($path in @($plan.Paths.Keys|Sort-Object Length -Descending)){
   if(-not [IO.Directory]::Exists($path)){continue}
   for($i=0;$i -lt $locks.Paths.Count;$i++){if($plan.RetireLocks.ContainsKey($locks.Paths[$i]) -and $locks.Paths[$i].StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)){$locks.Handles[$i].Dispose()}}
   LCTrim $rootPath $path $plan
  }
  LCAssertRetained $plan
  $journal.Status='Committed';Write-TCDJson $journalPath $journal -Compact;$committed=$true
  return LCFinish $rootPath $journal
 }catch{
  $original=$_
  if($journal -and -not $committed){try{LCRollback $rootPath $journal}catch{LCFail RecoveryRequired '清理中断且回退未完成，原资料保存在本机暂存区。请点击完成本机恢复。'};LCFail RolledBack '本机清理未完成，原资料已完整恢复。请重新预览后重试。'}
  throw $original
 }finally{OHCloseLocks $locks;$gate.Dispose()}
}
