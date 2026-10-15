#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DraftDisposition.psm1') -DisableNameChecking
function Read-TCServerRegistry {param([string]$Root)
 $data=Read-TCDJson (Join-Path (Get-TCDPath $Root servers) 'registry.json') -AllowMissing
 if(-not $data){return [pscustomobject]@{SchemaVersion=1;Revision=0;Servers=@()}}
 if($data.SchemaVersion -ne 1){throw '[TC:RegistryVersion] 不支持此服务器台账版本。'}
 return $data
}
function Get-TCServers {param([string]$Root)
 $registry=Read-TCServerRegistry $Root
 return @($registry.Servers)
}
function Get-TCServer {param([string]$Root,[string]$Id,[switch]$IncludeArchived)
 Assert-TCLocalCleanupReady $Root
 $id=Assert-TCDId $Id;$found=@(Get-TCServers $Root|Where-Object {$_.LocalRecordId -eq $id})
 if($found.Count -ne 1){throw '[TC:ServerMissing] 服务器记录不存在，请重新选择。'}
 Assert-TCDraftActive -Root $Root -Id ('ServerRecord:'+$id)
 if(-not $IncludeArchived -and (Get-TCDField $found[0] RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 此服务器身份已归档，旧任务和授权不能续接。请使用重装后新建的记录。'}
 return $found[0]
}
function Assert-TCManagementSigningPublicKey {param($Signing)
 Assert-TCDFields $Signing @('kty','n','e') @('kty','n','e')
 if($Signing.kty -cne 'RSA' -or $Signing.e -cne 'AQAB' -or $Signing.n -cnotmatch '^[A-Za-z0-9_-]{512}$'){throw '[TC:ManagementIdentityInvalid] 管理签名身份不是受支持的 RSA-3072 公钥。'}
}
function Set-TCServerRecord {
 [CmdletBinding()]param([string]$Root,[string]$Id,$Connection,$ServerInfo,[string]$Name,[string]$PinnedFingerprint,[string[]]$SourceJobIds=@(),[string]$CredentialRef,[switch]$UnverifiedRecovery,[switch]$ConnectorOnly,$SessionRef,$LegacyCheckpoint)
 $verified=$null
 Assert-TCLocalCleanupReady $Root
 if($SessionRef){
  Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
  if($null -ne $ServerInfo){
   $verified=Get-TCDeployVerifiedServerInfo -SessionRef $SessionRef
   if((Get-TCDDigest $ServerInfo) -cne (Get-TCDDigest $verified.ServerInfo)){throw '[TC:IdentityObservationChanged] 调用方资料与实际会话 server_info 不一致。'}
   $ServerInfo=$verified.ServerInfo
  }else{
   # Host trust is independent of the Python/backend/application prerequisites.
   # Do not infer, fetch, clear or authenticate any application fields here.
   $verified=Get-TCDeployVerifiedHostIdentity -SessionRef $SessionRef
  }
  if($UnverifiedRecovery -or $ConnectorOnly){throw '[TC:InvalidRequest] 恢复或接收端登记不能声明 SSH 核验。'}
 }
 $dir=Get-TCDPath $Root servers;$lock=Open-TCDLock (Join-Path $dir '.registry.lock')
 try{
  $registry=Read-TCServerRegistry $Root;$records=@($registry.Servers)
  $old=$null
  if($Id){$Id=Assert-TCDId $Id;Assert-TCDraftActive -Root $Root -Id ('ServerRecord:'+$Id);$old=@($records|Where-Object {$_.LocalRecordId -eq $Id})|Select-Object -First 1}
  if($old -and (Get-TCDField $old RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 原服务器身份已归档，不能更新或重新授权。'}
  if($Id -and -not $old){
   if(-not $Connection){throw '[TC:ServerMissing] 原服务器记录已不存在，请重新打开准备入口。'}
   $cleanupRoot=Join-Path $Root 'local-cleanup'
   if([IO.Directory]::Exists($cleanupRoot)){foreach($cleanup in @(Get-ChildItem -LiteralPath $cleanupRoot -Directory)){
    $receipt=Read-TCDJson (Join-Path $cleanup.FullName 'journal.json') -AllowMissing
    if($receipt -and (Get-TCDField $receipt Status '') -eq 'Completed' -and ('ServerRecord:'+$Id) -in @(Get-TCDField (Get-TCDField $receipt Result) DeletedIds @())){throw '[TC:ServerMissing] 原服务器记录已清理，过期回调不能重新登记；请创建新准备。'}
   }}
  }
  if($ServerInfo -and -not $old){
   $owner=[string](Get-TCDField $ServerInfo RemoteOwnerId '')
   $public=[string](Get-TCDField (Get-TCDField $ServerInfo Node) ServerPublicKey '')
   if($owner -and @($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -ceq 'Archived' -and $_.RemoteOwnerId -ceq $owner}).Count){throw '[TC:ServerArchived] 旧归属的授权资料已归档，不能重新导入。'}
   if($owner){$old=@($records|Where-Object {$_.RemoteOwnerId -eq $owner -and (-not $public -or $_.ServerPublicKey -eq $public)})|Select-Object -First 1;if($old){if((Get-TCDField $old RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 旧归属的授权资料已归档，不能导入新服务器。'};$Id=$old.LocalRecordId}}
  }
  if($Connection -and -not $old -and -not $Id){
   # Reuse an endpoint's provisional card; its pinned remote identity is still checked below.
   $candidateHost=[string](Get-TCDField $Connection Host '');$candidatePort=[int](Get-TCDField $Connection Port 22);$candidateUser=[string](Get-TCDField $Connection User 'root')
   $same=@($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -cne 'Archived' -and -not (Test-TCDraftDiscarded -Root $Root -Id ('ServerRecord:'+$_.LocalRecordId)) -and $_.Connection -and $_.Connection.Host -ceq $candidateHost -and [int]$_.Connection.Port -eq $candidatePort -and $_.Connection.User -ceq $candidateUser})
   if($same.Count -gt 1){throw '[TC:RegistryAmbiguous] 此接入地址已有多个历史记录，请先选择已有服务器并核验身份。'}
   if($same.Count -eq 1){$old=$same[0];$Id=$old.LocalRecordId}
  }
  # A pin alone is not a server. Stale asynchronous callbacks must not create
  # anonymous records when their original target has disappeared.
  if(-not $old -and -not $Connection -and -not ((Get-TCDField $ServerInfo RemoteOwnerId '') -and (Get-TCDField (Get-TCDField $ServerInfo Node) NodeId '') -and (Get-TCDField (Get-TCDField $ServerInfo Node) ServerPublicKey ''))){throw '[TC:ServerTargetMissing] 服务器目标已失效，请重新打开原准备记录。未创建空白服务器。'}
  if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
  $entry=[ordered]@{LocalRecordId=$Id;Name='服务器';Endpoints=@();Connection=$null;RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;ManagementSigningPublicKey=$null;OwnershipState='Unverified';ManagementAccessState='NeedsAuthentication';CapabilityVersion=0;CredentialRef=$null;LinkedNodeIds=@();SourceJobIds=@();ExpectedExitIPv4=$null;ExpectedExitSource=$null;LastCheckedUtc=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $entry.RecordState='Active';$entry.Reinstall=$null;$entry.ArchivedAtUtc=$null;$entry.ReplacedByServerId=$null;$entry.ArchivedTasks=@();$entry.HostTrustState='AwaitVerification';$entry.ObservedHostKeyAlgorithm=$null;$entry.IdentityTransitionRevision=0;$entry.IdentityTransitionTasks=@();$entry.LegacyCheckpoints=@()
  if($old){foreach($key in @($entry.Keys)){if($old.PSObject.Properties[$key]){$entry[$key]=$old.$key}}}
  $previous=$null
  if($entry.Reinstall){$previous=@($records|Where-Object {$_.LocalRecordId -ceq [string](Get-TCDField $entry.Reinstall PreviousServerId '')})|Select-Object -First 1}
  if($previous){
   if($CredentialRef -and $CredentialRef -ceq [string]$previous.CredentialRef){throw '[TC:ReinstallOldCredential] 新记录不能引用重装前保存的管理凭据。'}
   $previousTasks=@($previous.SourceJobIds)+@(Get-TCDField $previous ArchivedTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id})
   if(@($SourceJobIds|Where-Object {$_ -in $previousTasks}).Count){throw '[TC:ServerArchived] 原任务不能并入重装后的新记录。'}
   if($ServerInfo){
    $incomingOwner=[string](Get-TCDField $ServerInfo RemoteOwnerId '');$incomingPublic=[string](Get-TCDField (Get-TCDField $ServerInfo Node) ServerPublicKey '');$incomingSigning=Get-TCDField $ServerInfo ManagementSigningPublicKey
    if(($incomingOwner -and $previous.RemoteOwnerId -and $incomingOwner -ceq [string]$previous.RemoteOwnerId) -or ($incomingPublic -and $previous.ServerPublicKey -and $incomingPublic -ceq [string]$previous.ServerPublicKey) -or ($incomingSigning -and $previous.ManagementSigningPublicKey -and (Get-TCDDigest $incomingSigning) -ceq (Get-TCDDigest $previous.ManagementSigningPublicKey))){throw '[TC:ReinstallOldIdentity] 新记录不能导入重装前的归属、隧道身份或管理签名身份。'}
   }
  }
  if($Connection){
   Assert-TCDFields $Connection @('Host','Port','User','IdentityFile') @('Host','User')
   $hostAddress=[string](Get-TCDField $Connection Host '');$port=[int](Get-TCDField $Connection Port 22);$user=[string](Get-TCDField $Connection User '')
   $address=$null
   if($hostAddress -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or -not [Net.IPAddress]::TryParse($hostAddress,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $port -lt 1 -or $port -gt 65535 -or $user -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){throw '[TC:ConnectionInvalid] 请填写有效 IPv4、SSH 端口和用户名。'}
   $entry.Connection=[ordered]@{Host=$address.ToString();Port=$port;User=$user;IdentityFile=[string](Get-TCDField $Connection IdentityFile '')}
  }
  if($Name){if($Name.Length -gt 80 -or $Name -match '[\x00-\x1f]'){throw '[TC:NameInvalid] 名称需为 1–80 个可显示字符。'};$entry.Name=$Name}
  if($verified){
   if(-not $entry.Connection -or $entry.Connection.Host -cne $verified.Connection.Host -or [int]$entry.Connection.Port -ne [int]$verified.Connection.Port -or $entry.Connection.User -cne $verified.Connection.User -or ($PinnedFingerprint -and $PinnedFingerprint.TrimEnd('=') -cne $verified.ObservedFingerprint) -or ($entry.PinnedHostKey -and ([string]$entry.PinnedHostKey).TrimEnd('=') -cne $verified.ObservedFingerprint)){throw '[TC:HostChanged] 实际 SSH 会话未证明登记地址和固定指纹。'}
   $PinnedFingerprint=$verified.ObservedFingerprint;$entry.HostTrustState='Verified';$entry.ObservedHostKeyAlgorithm=$verified.ObservedHostKeyAlgorithm
  }
  if($PinnedFingerprint){if($PinnedFingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){throw '[TC:FingerprintInvalid] SSH 主机指纹无效。'};if($entry.PinnedHostKey -and $entry.PinnedHostKey -cne $PinnedFingerprint){throw '[TC:HostChanged] 已知 SSH 主机身份变化，请先核验。'};$entry.PinnedHostKey=$PinnedFingerprint}
  if($CredentialRef){$entry.CredentialRef=$CredentialRef}
  $entry.SourceJobIds=@(@($entry.SourceJobIds)+@($SourceJobIds)|Select-Object -Unique)
  if($LegacyCheckpoint){
   Assert-TCDFields $LegacyCheckpoint @('Kind','JobId','PlanId','BindingDigest','CheckpointDigest') @('Kind','JobId','BindingDigest','CheckpointDigest')
   $null=Assert-TCDId ([string]$LegacyCheckpoint.JobId)
   if($LegacyCheckpoint.Kind -notin @('Plan','Authorized','Config') -or $LegacyCheckpoint.BindingDigest -cnotmatch '^[a-f0-9]{64}$' -or $LegacyCheckpoint.CheckpointDigest -cnotmatch '^[a-f0-9]{64}$'){throw '[TC:LegacyCheckpointInvalid] 历史检查点索引格式无效。'}
   $entry.LegacyCheckpoints=@($entry.LegacyCheckpoints|Where-Object {$_.JobId -cne $LegacyCheckpoint.JobId})+@($LegacyCheckpoint)
  }
  if($ServerInfo){
   $node=Get-TCDField $ServerInfo Node
   $owner=[string](Get-TCDField $ServerInfo RemoteOwnerId '')
   $nodeId=[string](Get-TCDField $node NodeId '')
   $public=[string](Get-TCDField $node ServerPublicKey '')
   if($entry.RemoteOwnerId -and $owner -and $entry.RemoteOwnerId -cne $owner){throw '[TC:ServerChanged] 此地址的服务器归属已经变化。'}
   if($entry.NodeId -and $nodeId -and $entry.NodeId -cne $nodeId){throw '[TC:ServerChanged] 此服务器的应用节点身份已经变化。'}
   if($entry.ServerPublicKey -and $public -and $entry.ServerPublicKey -cne $public){throw '[TC:ServerChanged] 此服务器的隧道身份已经变化。'}
   if($owner){$entry.RemoteOwnerId=$owner};if($nodeId){$entry.NodeId=$nodeId};if($public){$entry.ServerPublicKey=$public}
   $endpoint=[string](Get-TCDField $node PublicEndpoint '');if($endpoint){$entry.Endpoints=@(@($entry.Endpoints)+@($endpoint)|Select-Object -Unique)}
   $signing=Get-TCDField $ServerInfo ManagementSigningPublicKey
   if($signing){
    Assert-TCManagementSigningPublicKey $signing
    if($entry.ManagementSigningPublicKey -and (Get-TCDDigest $entry.ManagementSigningPublicKey) -cne (Get-TCDDigest $signing)){throw '[TC:ManagementIdentityChanged] 已固定的服务器管理签名身份发生变化，请核验服务器恢复或重装情况。'}
    $entry.ManagementSigningPublicKey=$signing
   }
   $entry.OwnershipState=Get-TCDField $ServerInfo OwnershipState 'Managed'
   $entry.CapabilityVersion=[int](Get-TCDField $ServerInfo ManagementApiVersion 0)
   if($ConnectorOnly){
    if(-not $entry.Connection){$entry.ManagementAccessState='ConnectorOnly';$entry.OwnershipState='InvitationPinned';$entry.LastCheckedUtc=$null}
    elseif($old){$entry.ManagementAccessState=$old.ManagementAccessState;$entry.OwnershipState=$old.OwnershipState;$entry.LastCheckedUtc=$old.LastCheckedUtc}
   }
   elseif($UnverifiedRecovery){$entry.ManagementAccessState='NeedsAuthentication';$entry.OwnershipState='AwaitIdentityVerification';$entry.LastCheckedUtc=$null}
   elseif($verified){$entry.ManagementAccessState='Authenticated';$entry.LastCheckedUtc=[DateTime]::UtcNow.ToString('o')}
   else{$entry.ManagementAccessState='NeedsAuthentication';$entry.OwnershipState='AwaitIdentityVerification';$entry.LastCheckedUtc=$null}
  }
  $next=@($records|Where-Object {$_.LocalRecordId -ne $Id})+@([pscustomobject]$entry)
  Write-TCDJson (Join-Path $dir 'registry.json') ([ordered]@{SchemaVersion=1;Revision=[int]$registry.Revision+1;Servers=$next})
  return [pscustomobject]$entry
 }finally{$lock.Dispose()}
}
function Import-TCServerRecoveryRecord {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)]$ServerRecord)
 Assert-TCDFields $ServerRecord @('RemoteOwnerId','NodeId','ServerPublicKey','Name','Endpoints','Connection','PinnedHostKey','ManagementSigningPublicKey','Protocols','CapabilityVersion') @('Connection')
 $node=@{NodeId=(Get-TCDField $ServerRecord NodeId);ServerPublicKey=(Get-TCDField $ServerRecord ServerPublicKey)}
 $info=@{RemoteOwnerId=(Get-TCDField $ServerRecord RemoteOwnerId);Node=$node;ManagementSigningPublicKey=(Get-TCDField $ServerRecord ManagementSigningPublicKey);ManagementApiVersion=(Get-TCDField $ServerRecord CapabilityVersion 0);OwnershipState='AwaitIdentityVerification'}
 Set-TCServerRecord -Root $Root -Connection $ServerRecord.Connection -Name ([string](Get-TCDField $ServerRecord Name '恢复的服务器')) -PinnedFingerprint ([string](Get-TCDField $ServerRecord PinnedHostKey '')) -ServerInfo $info -UnverifiedRecovery
}
function Set-TCServerLink {param([string]$Root,[string]$ServerId,[string]$NodeId,[string]$ObservedExitIPv4,[string]$EvidenceSource)
 $nodeId=Assert-TCDId $NodeId;$dir=Get-TCDPath $Root servers;$lock=Open-TCDLock (Join-Path $dir '.registry.lock')
 try{
  $registry=Read-TCServerRegistry $Root;$server=Get-TCServer $Root $ServerId
  $reinstall=Get-TCDField $server Reinstall
  if($reinstall){$previous=Get-TCServer -Root $Root -Id ([string]$reinstall.PreviousServerId) -IncludeArchived;if($nodeId -in @($previous.LinkedNodeIds)){throw '[TC:ReinstallOldDevice] 新记录不能关联重装前的设备线路。'}}
  $server.LinkedNodeIds=@(@($server.LinkedNodeIds)+@($nodeId)|Select-Object -Unique)
  if($ObservedExitIPv4){$address=$null;if(-not [Net.IPAddress]::TryParse($ObservedExitIPv4,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw '[TC:ExitInvalid] 出口观测结果无效。'};$server.ExpectedExitIPv4=$address.ToString();$server.ExpectedExitSource=$EvidenceSource}
  $server.LastCheckedUtc=[DateTime]::UtcNow.ToString('o')
  Write-TCDJson (Join-Path $dir 'registry.json') ([ordered]@{SchemaVersion=1;Revision=[int]$registry.Revision+1;Servers=@($registry.Servers|ForEach-Object {if($_.LocalRecordId -eq $ServerId){$server}else{$_}})})
  return $server
 }finally{$lock.Dispose()}
}
function Read-TCServerLegacyCheckpoint {param([string]$JobsRoot,[string]$JobId)
 $id=Assert-TCDId $JobId;$directory=Join-Path (Assert-TCDPath $JobsRoot) $id
 $job=Read-TCDJson (Join-Path $directory 'job.json');$result=Read-TCDJson (Join-Path $directory 'result.json') -AllowMissing
 if($job.SchemaVersion -ne 1 -or $job.JobId -cne $id -or $job.Operation -notin @('Plan','Apply','Authorize','Finalize') -or -not $result){return $null}
 if((Get-TCDField $result SchemaVersion 0) -ne 1 -or (Get-TCDField $result JobId '') -cne $id -or (Get-TCDField $result Operation '') -cne $job.Operation -or (Get-TCDField $result Status '') -cne 'Completed' -or (Get-TCDField $result OutcomeUnknown $true) -isnot [bool] -or $result.OutcomeUnknown -or (Get-TCDField $result ExitCode -1) -ne 0){return $null}
 $requestId=Assert-TCDId ([string](Get-TCDField $job RequestJobId ''));$requestDirectory=Join-Path (Join-Path $JobsRoot $requestId) 'client'
 $requestJob=Read-TCDJson (Join-Path (Join-Path $JobsRoot $requestId) 'job.json');$local=Read-TCServerLocalRequest $requestDirectory;$request=$local.Request
 if($requestJob.SchemaVersion -ne 1 -or $requestJob.JobId -cne $requestId -or $requestJob.Operation -notin @('Plan','Authorize') -or $requestJob.RequestJobId -cne $requestId -or $job.RequestId -cne $request.RequestId -or $requestJob.RequestId -cne $request.RequestId -or $job.RequestHash -cne $requestJob.RequestHash -or $job.RequestHash -cne (Get-TCServerTextDigest (ConvertTo-Json -InputObject $request -Depth 8 -Compress))){throw '[TC:LegacyCheckpointInvalid] 历史任务没有绑定原始本机申请。'}
 $connection=Get-TCDField $job Connection;Assert-TCDFields $connection @('Host','Port','User','IdentityFile') @('Host','Port','User')
 if((Get-TCDDigest $connection) -cne (Get-TCDDigest $requestJob.Connection)){throw '[TC:LegacyCheckpointInvalid] 历史请求与任务接入地址不一致。'}
 $data=$result.Data;$kind='Plan';$nodeId='';$public='';$owner='';$planId='';$related=@($id,$requestId);$response=$null
 if($job.Operation -ceq 'Plan'){
  if($requestId -cne $id -or (Get-TCDField $data Supported $false) -cne $true -or (Get-TCDField $data Name '') -cne $job.Name -or (Get-TCDField $data PublicEndpoint '') -cne $job.PublicEndpoint -or (Get-TCDField $data TunnelSubnet '') -cne $job.TunnelSubnet -or -not (Get-TCDField $data ServerAddress '') -or -not (Get-TCDField $data ClientAddress '') -or (Get-TCDField $data RequiresCloudFirewall $false) -cne $true){throw '[TC:LegacyCheckpointInvalid] 历史 Plan 未形成匹配的公开检查点。'}
  $planId=Assert-TCDId ([string](Get-TCDField $data PlanId ''))
  $null=[DateTimeOffset]::Parse([string]$data.PlanExpiresAt,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  $bindingDigest=Get-TCDDigest @{Kind='Plan';PlanId=$planId;RequestHash=$job.RequestHash;Connection=$connection}
 }else{
  $kind='Authorized';$response=Read-TCDJson (Join-Path $directory 'public.response.json') -MaxBytes 32768
  if((Get-TCDDigest $response) -cne (Get-TCDDigest (Get-TCDField $data ClientResponse)) -or (Get-TCDField $response SchemaVersion 0) -ne 1 -or (Get-TCDField $response Kind '') -cne 'TradeChannel.ClientResponse' -or (Get-TCDField $response Status '') -cne 'Authorized' -or $response.RequestId -cne $request.RequestId -or $response.DeviceId -cne $request.DeviceId -or $response.ClientPublicKey -cne $request.ClientPublicKey -or (@($response.AddressFamilies) -join ',') -cne 'IPv4'){throw '[TC:LegacyCheckpointInvalid] 历史授权响应与原申请或成功结果不一致。'}
  $nodeId=Assert-TCDId ([string]$response.NodeId);$public=[string]$response.ServerPublicKey;$node=Get-TCDField $data Node;$owner=[string](Get-TCDField $data RemoteOwnerId '')
  if($public -cnotmatch '^[A-Za-z0-9+/]{43}=$' -or (Get-TCDField $node NodeId '') -cne $nodeId -or (Get-TCDField $node ServerPublicKey '') -cne $public -or (Get-TCDField $node PublicEndpoint '') -cne $response.PublicEndpoint){throw '[TC:LegacyCheckpointInvalid] 历史应用身份与授权检查点不一致。'}
  if($owner){$null=Assert-TCDId $owner}
  if($job.Operation -in @('Apply','Finalize')){
   $parentId=Assert-TCDId ([string]$job.ParentJobId)
   if($parentId -cne $requestId -or $requestJob.Operation -cne 'Plan'){throw '[TC:LegacyCheckpointInvalid] 历史 Apply 的父检查点不是原始 Plan，拒绝循环或替代引用。'}
   $related+=,$parentId;$parent=Read-TCServerLegacyCheckpoint $JobsRoot $parentId
   if(-not $parent -or $parent.Checkpoint.Kind -cne 'Plan' -or $parent.Job.RequestJobId -cne $requestId -or $parent.Checkpoint.PlanId -cne $job.PlanId -or $parent.Job.PublicEndpoint -cne $response.PublicEndpoint -or $parent.Job.TunnelSubnet -cne $response.TunnelSubnet -or (Get-TCDDigest $parent.Job.Connection) -cne (Get-TCDDigest $connection)){throw '[TC:LegacyCheckpointInvalid] 历史 Apply 未绑定原 Plan。'}
   $planId=$parent.Checkpoint.PlanId
  }elseif($requestId -cne $id){throw '[TC:LegacyCheckpointInvalid] 历史 Authorize 未绑定本次原申请。'}
  $bindingDigest=Get-TCDDigest @{NodeId=$nodeId;ServerPublicKey=$public}
  $config=Join-Path $directory 'client.conf'
  if([IO.File]::Exists($config)){
   $text=$null;$private=$null
   try{
    $text=Read-TCServerPrivateText $config 65536;$private=(Read-TCServerPrivateText (Join-Path $requestDirectory 'client.key') 256).Trim()
    if($text -notmatch '(?m)^PrivateKey\s*=\s*(\S+)\s*$' -or $Matches[1] -cne $private -or $text -notmatch '(?m)^PublicKey\s*=\s*(\S+)\s*$' -or $Matches[1] -cne $public -or $text -notmatch '(?m)^Endpoint\s*=\s*(\S+)\s*$' -or $Matches[1] -cne $response.PublicEndpoint){throw '[TC:LegacyCheckpointInvalid] 历史配置与原始授权身份不一致。'}
    foreach($field in @('PrivateKey','PublicKey','Endpoint','Address','AllowedIPs','PersistentKeepalive')){if([regex]::Matches($text,('(?m)^'+$field+'\s*=')).Count -ne 1){throw '[TC:LegacyCheckpointInvalid] 历史配置字段缺失或存在重复。'}}
    if([regex]::Matches($text,'(?m)^\[Interface\]\s*$').Count -ne 1 -or [regex]::Matches($text,'(?m)^\[Peer\]\s*$').Count -ne 1 -or $text -notmatch '(?m)^Address\s*=\s*(\S+)\s*$' -or $Matches[1] -cne $response.ClientAddress -or $text -notmatch '(?m)^AllowedIPs\s*=\s*(\S+)\s*$' -or $Matches[1] -cne '0.0.0.0/0' -or $text -notmatch '(?m)^PersistentKeepalive\s*=\s*25\s*$'){throw '[TC:LegacyCheckpointInvalid] 历史配置不属于原授权 IPv4 线路。'}
    $kind='Config'
   }finally{$text=$null;$private=$null;$Matches=$null}
  }
 }
 return [pscustomobject]@{Job=$job;RelatedJobIds=@($related|Select-Object -Unique);NodeId=$nodeId;ServerPublicKey=$public;RemoteOwnerId=$owner;Checkpoint=[pscustomobject]@{Kind=$kind;JobId=$id;PlanId=$planId;BindingDigest=$bindingDigest;CheckpointDigest=(Get-TCDDigest @{Job=$job;Result=$result;Request=$local.FilesDigest;Response=$response})}}
}
function Import-TCLegacyServerIndex {param([string]$Root)
 $jobs=Join-Path (Assert-TCDPath $Root) 'linux-jobs';if(-not [IO.Directory]::Exists($jobs)){return [pscustomobject]@{Imported=0;Servers=@();Skipped=0}}
 $count=0;$results=@();$skipped=0
 foreach($directory in @(Get-ChildItem -LiteralPath $jobs -Directory|Where-Object {$_.Name -cmatch '^[0-9a-f-]{36}$'}|Select-Object -First 500)){
  try{
   $checkpoint=Read-TCServerLegacyCheckpoint $jobs $directory.Name
   if(-not $checkpoint){$skipped++;continue}
   $records=@(Get-TCServers $Root);$archived=@($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -ceq 'Archived'})
   $blocked=@($archived|ForEach-Object {@($_.SourceJobIds);@(Get-TCDField $_ ArchivedTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id})})+@($records|ForEach-Object {Get-TCDField $_ IdentityTransitionTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id}})
   $archiveFlag=$false
   foreach($related in $checkpoint.RelatedJobIds){$mark=Read-TCDJson (Join-Path (Join-Path $jobs $related) 'archive.json') -AllowMissing;if($mark){if((Get-TCDField $mark SchemaVersion 0) -ne 1 -or (Get-TCDField $mark JobId '') -cne $related -or (Get-TCDField $mark Archived) -isnot [bool]){throw '[TC:LegacyCheckpointInvalid] 历史归档标记无效。'};if($mark.Archived){$archiveFlag=$true}}}
   if($archiveFlag -or @($checkpoint.RelatedJobIds|Where-Object {$_ -in $blocked}).Count -or ($checkpoint.NodeId -and @($archived|Where-Object {$_.NodeId -ceq $checkpoint.NodeId -or $_.ServerPublicKey -ceq $checkpoint.ServerPublicKey -or ($checkpoint.RemoteOwnerId -and $_.RemoteOwnerId -ceq $checkpoint.RemoteOwnerId)}).Count)){$skipped++;continue}
   $active=@($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -cne 'Archived' -and -not (Test-TCDraftDiscarded -Root $Root -Id ('ServerRecord:'+$_.LocalRecordId))})
   if($checkpoint.NodeId){
    $matches=@($active|Where-Object {$_.NodeId -ceq $checkpoint.NodeId -and $_.ServerPublicKey -ceq $checkpoint.ServerPublicKey -and (-not $checkpoint.RemoteOwnerId -or -not $_.RemoteOwnerId -or $_.RemoteOwnerId -ceq $checkpoint.RemoteOwnerId)})
    if(-not $matches.Count -and $checkpoint.Checkpoint.PlanId){$matches=@($active|Where-Object {-not $_.NodeId -and -not $_.ServerPublicKey -and @(Get-TCDField $_ LegacyCheckpoints @()|Where-Object {$_.Kind -ceq 'Plan' -and $_.PlanId -ceq $checkpoint.Checkpoint.PlanId}).Count})}
    if(-not $matches.Count -and @($active|Where-Object {$_.NodeId -ceq $checkpoint.NodeId -or $_.ServerPublicKey -ceq $checkpoint.ServerPublicKey}).Count){$skipped++;continue}
   }
   else{
    $matches=@()
    foreach($candidate in $active){
     $known=@(Get-TCDField $candidate LegacyCheckpoints @()|Where-Object {$_.PlanId -ceq $checkpoint.Checkpoint.PlanId})
     if($known.Count -and (@($known|Where-Object {$_.BindingDigest -ceq $checkpoint.Checkpoint.BindingDigest}).Count -or $checkpoint.Job.JobId -in @($candidate.SourceJobIds))){$matches+=,$candidate}
    }
   }
   if($matches.Count -gt 1){$skipped++;continue}
   $match=if($matches.Count -eq 1){$matches[0]}else{$null}
   if(-not $match){
    # An IP address is never an application identity. An already registered
    # endpoint without a matching checkpoint/binding requires explicit review.
    $sameEndpoint=@($active|Where-Object {$_.Connection -and $_.Connection.Host -ceq $checkpoint.Job.Connection.Host -and [int]$_.Connection.Port -eq [int]$checkpoint.Job.Connection.Port -and $_.Connection.User -ceq $checkpoint.Job.Connection.User})
    if($sameEndpoint.Count){$skipped++;continue}
   }
   if($match -and $checkpoint.Job.JobId -in @($match.SourceJobIds) -and @(Get-TCDField $match LegacyCheckpoints @()|Where-Object {$_.CheckpointDigest -ceq $checkpoint.Checkpoint.CheckpointDigest}).Count){continue}
   $params=@{Root=$Root;Id=$(if($match){$match.LocalRecordId}else{[guid]::NewGuid().ToString('D')});SourceJobIds=@($checkpoint.RelatedJobIds);LegacyCheckpoint=$checkpoint.Checkpoint}
   if(-not $match){$params.Connection=$checkpoint.Job.Connection;$params.Name=[string](Get-TCDField $checkpoint.Job Name '历史检查点')}
   if($checkpoint.NodeId -and (-not $match -or (-not $match.NodeId -and -not $match.ServerPublicKey))){$params.ServerInfo=@{RemoteOwnerId=$checkpoint.RemoteOwnerId;Node=@{NodeId=$checkpoint.NodeId;ServerPublicKey=$checkpoint.ServerPublicKey};OwnershipState='AwaitIdentityVerification';ManagementApiVersion=0};$params.UnverifiedRecovery=$true}
   $results+=Set-TCServerRecord @params;$count++
  }catch{$skipped++;continue} # malformed, foreign ACL, partial or contradictory checkpoint
 }
 return [pscustomobject]@{Imported=$count;Servers=$results;Skipped=$skipped;Message='仅导入匹配的历史计划、授权或配置检查点；接入信任和应用归属仍需实际登录核验。'}
}
function Assert-TCServerTaskActive {
 [CmdletBinding(DefaultParameterSetName='Run')]param([string]$Root,[Parameter(Mandatory=$true,ParameterSetName='Run')][string]$RunId,[Parameter(Mandatory=$true,ParameterSetName='Legacy')][string]$SourceJobId,[Parameter(Mandatory=$true,ParameterSetName='Management')][string]$ManagementOperationId)
 if($PSCmdlet.ParameterSetName -ceq 'Management'){
  $id=Assert-TCDId $ManagementOperationId;$intent=Read-TCDJson (Join-Path (Join-Path (Get-TCDPath $Root deployments) 'management-intents') ($id+'.json'))
  $server=Get-TCServer -Root $Root -Id ([string](Get-TCDField $intent ServerRecordId ''))
  if(@(Get-TCDField $server IdentityTransitionTasks @()|Where-Object {$_.Kind -ceq 'Management' -and $_.Id -ceq $id}).Count){throw '[TC:ServerTaskIdentityChanged] SSH 身份核验后旧管理意图不能复用批准，请创建新操作。'}
  return $server
 }
 if($PSCmdlet.ParameterSetName -ceq 'Run'){
  $id=Assert-TCDId $RunId;$run=Read-TCDJson (Join-Path (Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') $id) 'state.json')
  Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$id)
  $server=Get-TCServer -Root $Root -Id ([string](Get-TCDField $run ServerRecordId ''))
  if(@(Get-TCDField $server IdentityTransitionTasks @()|Where-Object {$_.Kind -ceq 'Deployment' -and $_.Id -ceq $id}).Count -and ((Get-TCDField $run ApprovedChangeDigest '') -or (Get-TCDField $run AllowDeviceAuthorize $false) -or (Get-TCDField $run AllowManagementInitialize $false))){throw '[TC:ServerTaskIdentityChanged] 原任务的身份批准已经失效，请重新检查并核对计划。'}
  return $server
 }
 $id=Assert-TCDId $SourceJobId
 foreach($server in @(Get-TCServers $Root)){
  if($id -in @($server.SourceJobIds) -or $id -in @(Get-TCDField $server ArchivedTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id})){
   $active=Get-TCServer -Root $Root -Id $server.LocalRecordId
   if(@(Get-TCDField $active IdentityTransitionTasks @()|Where-Object {$_.Kind -ceq 'Legacy' -and $_.Id -ceq $id}).Count){throw '[TC:ServerTaskIdentityChanged] 旧任务不能继承新的 SSH 身份批准。'}
   return $active
  }
 }
 return $null # An unregistered legacy job has no registry authorization to inherit.
}
function Open-TCServerTaskLease {param([string]$Root,[string]$ServerId)
 $id=Assert-TCDId $ServerId;$lease=Open-TCDLock (Join-Path (Get-TCDPath $Root servers) ('.task-'+$id+'.lock'))
 try{$null=Get-TCServer -Root $Root -Id $id;return $lease}catch{$lease.Dispose();throw}
}
function Get-TCServerReinstallTasks {param([string]$Root,$Server)
 # Keep original task files, keys and receipts intact. The registry is the
 # authoritative archive/deny-resume boundary; never copy them into a new record.
 $tasks=@();$runs=Join-Path (Get-TCDPath $Root deployments) 'runs'
 if([IO.Directory]::Exists($runs)){
  foreach($dir in @(Get-ChildItem -LiteralPath $runs -Directory)){
   $path=Join-Path $dir.FullName 'state.json';if(-not [IO.File]::Exists($path)){continue};$run=Read-TCDJson $path
   if((Get-TCDField $run ServerRecordId '') -ceq $Server.LocalRecordId){
    $requestFilesDigest=$null;$requestDirectory=[string](Get-TCDField $run RequestDirectory '')
    if($requestDirectory -and -not (Get-TCDField $run ExistingDevice $false)){
     try{
      $expected=Assert-TCDPath (Join-Path $dir.FullName 'client')
      if((Assert-TCDPath $requestDirectory).TrimEnd('\') -ieq $expected.TrimEnd('\')){$local=Read-TCServerLocalRequest $expected;if((Get-TCDDigest $local.Request) -ceq (Get-TCDDigest (Get-TCDField $run ClientRequest))){$requestFilesDigest=$local.FilesDigest}}
     }catch{} # Preserve incomplete original files; they are not reusable proof.
    }
    $tasks+=[pscustomobject]@{Kind='Deployment';Id=(Assert-TCDId ([string]$run.RunId));State=[string]$run.Status;Digest=(Get-TCDDigest $run);RequestFilesDigest=$requestFilesDigest}
   }
  }
 }
 $intents=Join-Path (Get-TCDPath $Root deployments) 'management-intents'
 if([IO.Directory]::Exists($intents)){
  foreach($file in @(Get-ChildItem -LiteralPath $intents -Filter '*.json' -File)){
   $intent=Read-TCDJson $file.FullName
   if((Get-TCDField $intent ServerRecordId '') -ceq $Server.LocalRecordId){$tasks+=[pscustomobject]@{Kind='Management';Id=(Assert-TCDId ([string]$intent.OperationId));State=[string]$intent.State;Digest=(Get-TCDDigest $intent)}}
  }
 }
 $legacy=Join-Path (Assert-TCDPath $Root) 'linux-jobs'
 if([IO.Directory]::Exists($legacy)){
  foreach($dir in @(Get-ChildItem -LiteralPath $legacy -Directory)){
   $path=Join-Path $dir.FullName 'job.json';if(-not [IO.File]::Exists($path)){continue};$job=Read-TCDJson $path;$c=Get-TCDField $job Connection
   if((Get-TCDField $job JobId '') -in @($Server.SourceJobIds) -or ($c -and $c.Host -ceq $Server.Connection.Host -and [int]$c.Port -eq [int]$Server.Connection.Port -and $c.User -ceq $Server.Connection.User)){$tasks+=[pscustomobject]@{Kind='Legacy';Id=(Assert-TCDId ([string]$job.JobId));State=[string](Get-TCDField $job Status 'Unknown');Digest=(Get-TCDDigest $job)}}
  }
 }
 if(@($tasks|Where-Object {$_.State -in @('Running','Dispatching','Connecting','Pending','Prepared','Dispatched')}).Count){throw '[TC:ServerTaskBusy] 这台服务器仍有进行中的任务，请先核对结果；未停止进程或归档记录。'}
 return @($tasks|Sort-Object Kind,Id)
}
function Protect-TCServerReinstallToken {param($Context)
 Add-Type -AssemblyName System.Security
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Context -Depth 12 -Compress))
 try{return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('TradeChannel.ServerReinstall.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function Read-TCServerReinstallToken {param([string]$Root,[string]$ServerId,$SessionRef,[string]$Token,[string]$Kind)
 $plain=$null
 try{
  if(-not $Token -or $Token.Length -gt 16384){throw 'Invalid token'}
  Add-Type -AssemblyName System.Security
  $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),[Text.Encoding]::UTF8.GetBytes('TradeChannel.ServerReinstall.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $context=[Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json -ErrorAction Stop
 }catch{throw '[TC:ReinstallTokenInvalid] 重装核验令牌无效，请重新核验。'}finally{if($plain){[Array]::Clear($plain,0,$plain.Length)}}
 $rootPath=(Assert-TCDPath $Root).TrimEnd('\');$id=Assert-TCDId $ServerId
 if($context.Kind -cne $Kind -or $context.SchemaVersion -ne 1 -or $context.Root -ine $rootPath -or $context.ServerId -cne $id -or $context.SessionDigest -cne (Get-TCDDigest $SessionRef)){throw '[TC:ReinstallBindingMismatch] 令牌不属于当前目标、数据根或 SSH 会话。'}
 # PowerShell 7 may deserialize JSON timestamps as DateTime. Preserve its UTC
 # kind rather than parsing a culture-formatted string as local time.
 $expiry=if($context.ExpiresAtUtc -is [DateTime]){[DateTimeOffset]$context.ExpiresAtUtc}else{[DateTimeOffset]::Parse([string]$context.ExpiresAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}
 if($expiry -le [DateTimeOffset]::UtcNow){throw '[TC:ReinstallPreviewExpired] 重装核验预览已过期，请重新核验。'}
 $server=Get-TCServer -Root $Root -Id $id
 if($context.RecordDigest -cne (Get-TCDDigest $server)){throw '[TC:ReinstallRecordChanged] 原记录已变化，请重新核验；没有建立新记录。'}
 return $context
}
function Get-TCServerReinstallPoll {param($SessionRef)
 $poll=Get-TCDeploySession -SessionRef $SessionRef
 if((Get-TCDField $poll RunId '') -cne [string]$SessionRef.RunId -or (Get-TCDField $poll InstanceId '') -cne [string]$SessionRef.InstanceId -or (Get-TCDField $poll HasMutatingOperations) -isnot [bool] -or $poll.HasMutatingOperations){throw '[TC:ReinstallSessionMismatch] 核验仅接受绑定的实际只读 SSH 会话。'}
 return $poll
}
function Get-TCServerIdentityConnection {param($Server)
 return [ordered]@{Host=[string]$Server.Connection.Host;Port=[int]$Server.Connection.Port;User=[string]$Server.Connection.User}
}
function Assert-TCServerIdentityPoll {param($Server,$Context,$SessionRef,[switch]$Authenticated,[switch]$AllowRunning)
 $poll=Get-TCServerReinstallPoll $SessionRef;$connection=Get-TCDField $poll Connection
 if(-not $connection -or (Get-TCDDigest $connection) -cne (Get-TCDDigest (Get-TCServerIdentityConnection $Server))){throw '[TC:IdentityTargetMismatch] 实际 SSH 接入地址与原记录不一致。'}
 if($Authenticated){
  $fingerprint=[string](Get-TCDField $poll ObservedFingerprint '')
  $statuses=@('Ready','Completed','Failed');if($AllowRunning){$statuses+=,'Running'}
  if(-not (Get-TCDField $poll HasSession $false) -or $poll.Status -notin $statuses -or $fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or (Get-TCDField $poll AcceptedFingerprint '') -cne $fingerprint -or [int](Get-TCDField $poll AuthenticationGeneration 0) -le 0){throw '[TC:ReinstallAuthenticationRequired] 尚未取得固定指纹的实际登录会话。'}
  if($fingerprint -cne [string]$Context.NewFingerprint -or ([int](Get-TCDField $Context AuthenticationGeneration 0) -gt 0 -and [int]$poll.AuthenticationGeneration -ne [int]$Context.AuthenticationGeneration)){throw '[TC:IdentityObservationChanged] 已批准的主机密钥或登录代次发生变化。'}
 }
 return $poll
}
function Assert-TCServerIdentityContext {param($Context)
 if((Get-TCDField $Context FlowVersion 0) -ne 2){throw '[TC:IdentityReassessmentRequired] 旧版核验令牌不能用于应用身份提交，请重新核验。'}
}
function Start-TCServerIdentityVerification {
 [CmdletBinding(DefaultParameterSetName='Credential')]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true,ParameterSetName='Credential')]$Credential,[Parameter(Mandatory=$true,ParameterSetName='Session')]$SessionRef,[switch]$DeclaredApplicationReset)
 return Start-TCServerIdentityVerificationCore -Root $Root -ServerId $ServerId -Credential $Credential -SessionRef $SessionRef -DeclaredApplicationReset:$DeclaredApplicationReset
}
function Start-TCServerIdentityVerificationCore {param([string]$Root,[string]$ServerId,$Credential,$SessionRef,[switch]$DeclaredApplicationReset,[switch]$DiscoverHostKey)
 $rootPath=(Assert-TCDPath $Root).TrimEnd('\');$lease=Open-TCServerTaskLease -Root $rootPath -ServerId $ServerId
 try{
  $server=Get-TCServer -Root $rootPath -Id $ServerId
  if(-not $server.Connection -or [string]$server.PinnedHostKey -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){throw '[TC:ReinstallIdentityRequired] 身份核验需要原接入地址和固定指纹。'}
  $tasks=@(Get-TCServerReinstallTasks $rootPath $server)
  Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
  $authGeneration=0
  if($SessionRef){
   $poll=Assert-TCServerIdentityPoll $server $null $SessionRef
   if($poll.Status -notin @('Ready','Completed','Failed','AwaitingTrust')){throw '[TC:IdentitySessionBusy] 请等待当前只读操作完成。'}
   $authGeneration=[int](Get-TCDField $poll AuthenticationGeneration 0)
   if($authGeneration -le 0){throw '[TC:IdentityAuthenticationRequired] 会话尚未观察到服务器身份。'}
  }else{
   $connection=Get-TCServerIdentityConnection $server;$connection.IdentityFile=''
   $pin=if($DiscoverHostKey){''}else{([string]$server.PinnedHostKey).TrimEnd('=')}
   $started=Start-TCDeploySession -Root $rootPath -RunId ([guid]::NewGuid().ToString('D')) -Connection $connection -Credential $Credential -PinnedFingerprint $pin
   if(-not $started.Ok -or -not $started.SessionRef){throw '[TC:ReinstallSessionRejected] 核验会话未建立，原记录保留。'}
   $SessionRef=$started.SessionRef
  }
  $context=[ordered]@{SchemaVersion=1;FlowVersion=2;Kind='Verification';Root=$rootPath;ServerId=$server.LocalRecordId;NewServerId=[guid]::NewGuid().ToString('D');RecordDigest=(Get-TCDDigest $server);TasksDigest=(Get-TCDDigest $tasks);SessionDigest=(Get-TCDDigest $SessionRef);AuthenticationGeneration=$authGeneration;ExpiresAtUtc=[DateTime]::UtcNow.AddMinutes(10).ToString('o');NewFingerprint=([string]$server.PinnedHostKey).TrimEnd('=');ChangeDigest=$null;DeclaredApplicationReset=[bool]$DeclaredApplicationReset;Classification=$null;EvidenceDigest=$null}
  return [pscustomobject]@{Code='ServerIdentityVerificationStarted';SessionRef=$SessionRef;VerificationToken=(Protect-TCServerReinstallToken $context);NetworkChanged=$false;RemoteChanges=$false}
 }finally{$lease.Dispose()}
}
function New-TCServerIdentityTrustPreview {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$VerificationToken)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $VerificationToken Verification;Assert-TCServerIdentityContext $context
 $server=Get-TCServer $Root $ServerId;$tasks=@(Get-TCServerReinstallTasks $Root $server)
 if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在核验期间已变化。'}
 $poll=Assert-TCServerIdentityPoll $server $context $SessionRef;$fingerprint=[string](Get-TCDField $poll ObservedFingerprint '')
 if($fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$' -or [int](Get-TCDField $poll AuthenticationGeneration 0) -le 0 -or $poll.Status -notin @('Ready','Completed','Failed','AwaitingTrust') -or (-not $poll.HasSession -and $poll.Code -notin @('HostTrustRequired','HostKeyChanged')) -or ($poll.HasSession -and (Get-TCDField $poll AcceptedFingerprint '') -cne $fingerprint)){throw '[TC:ReinstallObservationRequired] 尚未取得实际 SSH 指纹观测，原记录保留。'}
 if([int]$context.AuthenticationGeneration -gt 0 -and [int]$context.AuthenticationGeneration -ne [int]$poll.AuthenticationGeneration){throw '[TC:IdentityObservationChanged] 核验登录代次发生变化。'}
 $context.Kind='Preview';$context.NewFingerprint=$fingerprint;$context.AuthenticationGeneration=[int]$poll.AuthenticationGeneration
 $context.ChangeDigest=Get-TCDDigest @{ServerId=$ServerId;RecordDigest=$context.RecordDigest;TasksDigest=$context.TasksDigest;SessionDigest=$context.SessionDigest;AuthenticationGeneration=$context.AuthenticationGeneration;NewFingerprint=$fingerprint;ExpiresAtUtc=$context.ExpiresAtUtc;Policy='ConfirmHostTrustOnly.v2'}
 return [pscustomobject]@{Code='ServerIdentityTrustRequired';ServerId=$ServerId;NewServerId=$context.NewServerId;Name=$server.Name;Connection=(Get-TCServerIdentityConnection $server);PreviousFingerprint=$server.PinnedHostKey;NewFingerprint=$fingerprint;HostKeyAlgorithm=[string](Get-TCDField $poll HostKeyAlgorithm (Get-TCDField $poll ObservedHostKeyAlgorithm ''));ExpiresAtUtc=$context.ExpiresAtUtc;ChangeDigest=$context.ChangeDigest;PreviewToken=(Protect-TCServerReinstallToken $context);ArchivedTasks=$tasks;RequiresAssessment=$true;NetworkChanged=$false;RemoteChanges=$false}
}
function Approve-TCServerIdentityFingerprint {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$PreviewToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,$Credential)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $PreviewToken Preview;Assert-TCServerIdentityContext $context
 if($ConfirmedFingerprint -cne $context.NewFingerprint){throw '[TC:ReinstallConfirmationMismatch] 确认指纹与本次预览不一致。'}
 $server=Get-TCServer $Root $ServerId;$tasks=@(Get-TCServerReinstallTasks $Root $server)
 if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在指纹确认前已变化。'}
 $poll=Assert-TCServerIdentityPoll $server $context $SessionRef
 if($poll.ObservedFingerprint -cne $context.NewFingerprint -or [int]$poll.AuthenticationGeneration -ne [int]$context.AuthenticationGeneration){throw '[TC:ReinstallObservationChanged] 实际指纹或登录代次已变化。'}
 if($poll.HasSession){
  $null=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
 }else{
  if($poll.Code -notin @('HostTrustRequired','HostKeyChanged')){throw '[TC:ReinstallObservationChanged] 此会话不在主机信任确认阶段。'}
  if(-not $Credential){throw '[TC:ReinstallAuthenticationRequired] 会话尚未登录，请提供本次认证凭据。'}
  $connection=Get-TCServerIdentityConnection $server;$connection.IdentityFile=''
  $result=Set-TCDeployCredential -SessionRef $SessionRef -Connection $connection -Credential $Credential -PinnedFingerprint $context.NewFingerprint
  if(-not $result.Ok){throw '[TC:ReinstallAuthenticationRejected] 核验会话未接受认证。'}
  $context.AuthenticationGeneration=[int]$context.AuthenticationGeneration+1
 }
 $context.Kind='Approval'
 return [pscustomobject]@{Code=$(if($poll.HasSession){'ServerIdentityTrustApproved'}else{'ServerIdentityAuthenticating'});ApprovalToken=(Protect-TCServerReinstallToken $context);SessionRef=$SessionRef;NetworkChanged=$false;RemoteChanges=$false}
}
function Test-TCServerUndeployedReferences {param([string]$Root,$Server)
 # A missing remote app is not proof that an unverified local authorization or
 # unresolved mutation may be discarded. Pending public REQUESTS are allowed;
 # authorized responses, devices, ownership and mutation receipts are not.
 if($Server.CredentialRef -or @($Server.LinkedNodeIds).Count -or @($Server.Endpoints).Count -or $Server.ExpectedExitIPv4 -or $Server.ManagementSigningPublicKey -or $Server.OwnershipState -notin @('Unverified','NotInstalled','AwaitIdentityVerification')){return $false}
 try{
  foreach($task in @(Get-TCServerReinstallTasks $Root $Server)){
   if($task.Kind -ceq 'Deployment'){
    $run=Read-TCDJson (Join-Path (Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') $task.Id) 'state.json')
    $binding=Get-TCDField $run ServerInfo;$node=Get-TCDField $binding Node;$intent=Get-TCDField $run DispatchIntent
    if((Get-TCDField $run ClientResponse) -or (Get-TCDField $run LastRemoteMutation) -or (Get-TCDField $run UnresolvedTcpMutation) -or (Get-TCDField $run RecoveryRequired $false) -or (Get-TCDField $run ExistingDevice $false) -or (Get-TCDField $run CandidateNodeId) -or (Get-TCDField $run CandidateManifestPath) -or (Get-TCDField $run ManagementPlan) -or (Get-TCDField $run Status '') -in @('OutcomeUnknown','NeedsRecovery') -or (Get-TCDField $intent Mutating $false) -or (Get-TCDField $binding RemoteOwnerId) -or (Get-TCDField $node NodeId) -or (Get-TCDField $node ServerPublicKey) -or (Get-TCDField $binding ManagementSigningPublicKey)){return $false}
   }elseif($task.Kind -ceq 'Management'){return $false}
   elseif($task.Kind -ceq 'Legacy'){
    $directory=Join-Path (Join-Path (Assert-TCDPath $Root) 'linux-jobs') $task.Id;$job=Read-TCDJson (Join-Path $directory 'job.json');$result=Read-TCDJson (Join-Path $directory 'result.json') -AllowMissing
    if((Get-TCDField $job Operation '') -in @('Apply','Authorize','Recover','Finalize') -and (-not $result -or (Get-TCDField $result OutcomeUnknown $true) -or (Get-TCDField $result Status '') -notin @('Completed','Failed'))){return $false}
    if($task.Id -in @($Server.SourceJobIds)){
     $data=Get-TCDField $result Data
     if((Get-TCDField $data ClientResponse) -or (Get-TCDField $data Node) -or (Get-TCDField $job Operation '') -in @('Apply','Authorize','Recover','Finalize')){return $false}
    }
   }
  }
 }catch{return $false}
 return $true
}
function Get-TCServerIdentityEvaluation {param($Server,$Observation,[string]$Root)
 # Only data returned by Get-TCDeployServerIdentityEvidence reaches this helper.
 $info=$Observation.ServerInfo;$inspection=$Observation.Inspection;$node=Get-TCDField $info Node
 $owner=[string](Get-TCDField $info RemoteOwnerId '');$nodeId=[string](Get-TCDField $node NodeId '');$public=[string](Get-TCDField $node ServerPublicKey '');$signing=Get-TCDField $info ManagementSigningPublicKey
 $state=[string](Get-TCDField $info OwnershipState '');$health=[string](Get-TCDField (Get-TCDField $info Health) LocalConfiguration '')
 $supported=Get-TCDField $inspection Supported;$owned=Get-TCDField $inspection OwnedDeployment;$deployed=Get-TCDField $inspection AlreadyDeployed;$issues=@(Get-TCDField $inspection Issues)
 $hasIssues=if($inspection -is [Collections.IDictionary]){$inspection.Contains('Issues')}else{$null -ne $inspection.PSObject.Properties['Issues']}
 $version=Get-TCDField $info ManagementApiVersion
 $hasIdentityFields=if($info -is [Collections.IDictionary]){$info.Contains('Node') -and $info.Contains('RemoteOwnerId')}else{$null -ne $info.PSObject.Properties['Node'] -and $null -ne $info.PSObject.Properties['RemoteOwnerId']}
 $snapshot=[ordered]@{RemoteOwnerId=$owner;NodeId=$nodeId;ServerPublicKey=$public;ManagementSigningPublicKey=$signing;OwnershipState=$state;ManagementApiVersion=(Get-TCDField $info ManagementApiVersion);Health=$health;PendingOperation=[bool](Get-TCDField $info PendingOperation);ConfigRevision=(Get-TCDField $info ConfigRevision);ActivePlanId=(Get-TCDField $info ActivePlanId);Supported=$supported;OwnedDeployment=$owned;AlreadyDeployed=$deployed;DeployedStatus=(Get-TCDField $inspection DeployedStatus);IssueCount=@($issues).Count}
 $reason='IdentityEvidenceIncomplete';$classification='Blocked'
 if($supported -is [bool] -and $owned -is [bool] -and $deployed -is [bool] -and $hasIssues -and $hasIdentityFields -and ($version -is [int] -or $version -is [long]) -and $version -in @(1,2)){
  if(-not $supported -or @($issues).Count -ne 0){$reason='IdentityInspectionBlocked'}
  elseif($snapshot.PendingOperation -or $state -ceq 'NeedsRecovery'){$reason='NeedsRecovery'}
  elseif($state -ceq 'NotInstalled'){
   if($owner -or $node -or $signing -or $owned -or $deployed -or $snapshot.DeployedStatus -or $health -or $snapshot.ManagementApiVersion -ne 1){$reason='IdentityEvidenceMismatch'}
   elseif(-not $Server.RemoteOwnerId -and -not $Server.NodeId -and -not $Server.ServerPublicKey -and -not $Server.ManagementSigningPublicKey){
    if(Test-TCServerUndeployedReferences $Root $Server){$classification='UndeployedTarget';$reason=$null}else{$reason='UndeployedReferencesUnverified'}
   }
   elseif(-not $Server.RemoteOwnerId -or -not $Server.NodeId -or -not $Server.ServerPublicKey -or $Server.OwnershipState -in @('Unverified','AwaitIdentityVerification')){$reason='IdentityBaselineRequired'}
   else{$classification='ApplicationReset';$reason=$null}
  }
  elseif($state -ceq 'Applied'){
   $ownerGuid=[guid]::Empty;$nodeGuid=[guid]::Empty
   if(-not [guid]::TryParseExact($owner,'D',[ref]$ownerGuid) -or $ownerGuid -eq [guid]::Empty -or -not [guid]::TryParseExact($nodeId,'D',[ref]$nodeGuid) -or $nodeGuid -eq [guid]::Empty -or $public -cnotmatch '^[A-Za-z0-9+/]{43}=$'){$reason='IdentityEvidenceIncomplete'}
   elseif($owner -cne [string]$Server.RemoteOwnerId -or $nodeId -cne [string]$Server.NodeId -or $public -cne [string]$Server.ServerPublicKey){$reason='ApplicationIdentityMismatch'}
   elseif((Get-TCDDigest $signing) -cne (Get-TCDDigest $Server.ManagementSigningPublicKey)){$reason='ManagementIdentityMismatch'}
   elseif($version -eq 2 -and (-not $signing -or (Get-TCDField $signing kty '') -cne 'RSA' -or (Get-TCDField $signing e '') -cne 'AQAB' -or [string](Get-TCDField $signing n '') -cnotmatch '^[A-Za-z0-9_-]{512}$')){$reason='IdentityEvidenceIncomplete'}
   elseif(-not $owned -or -not $deployed -or $snapshot.DeployedStatus -cne 'Applied' -or $health -cne 'Verified'){$reason='IdentityEvidenceMismatch'}
   else{$classification=if($Observation.ObservedFingerprint -ceq ([string]$Server.PinnedHostKey).TrimEnd('=')){'Unchanged'}else{'HostKeyUpdate'};$reason=$null}
  }else{$reason='ApplicationIdentityUnknown'}
 }
 return [pscustomobject]@{Classification=$classification;ReasonCode=$reason;EvidenceDigest=(Get-TCDDigest $snapshot);Evidence=$snapshot}
}
function New-TCServerIdentityAssessment {
 [CmdletBinding(DefaultParameterSetName='Verification')]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true,ParameterSetName='Verification')][string]$VerificationToken,[Parameter(Mandatory=$true,ParameterSetName='Approval')][string]$ApprovalToken)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $token=if($PSCmdlet.ParameterSetName -ceq 'Approval'){$ApprovalToken}else{$VerificationToken};$kind=$PSCmdlet.ParameterSetName
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $ServerId
 try{
  $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $token $kind;Assert-TCServerIdentityContext $context
  $server=Get-TCServer $Root $ServerId;$tasks=@(Get-TCServerReinstallTasks $Root $server)
  if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在核验期间已变化。'}
  $poll=Assert-TCServerIdentityPoll $server $context $SessionRef
  if($kind -ceq 'Verification' -and $poll.ObservedFingerprint -cne ([string]$server.PinnedHostKey).TrimEnd('=')){throw '[TC:IdentityTrustRequired] 主机密钥变化必须先精确确认本次指纹。'}
  $poll=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
  try{$observation=Get-TCDeployServerIdentityEvidence -SessionRef $SessionRef}catch{
   $reason='IdentityReadRejected';if($_.Exception.Message -match '^\[TC:(Identity[A-Za-z]+)\]'){$reason=$Matches[1]}
   return [pscustomobject]@{Code='ServerIdentityBlocked';Classification='Blocked';ReasonCode=$reason;CanCommit=$false;ServerId=$ServerId;NetworkChanged=$false;RemoteChanges=$false}
  }
  $null=Read-TCServerReinstallToken $Root $ServerId $SessionRef $token $kind
  $tasks=@(Get-TCServerReinstallTasks $Root $server);if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在只读检查期间已变化。'}
  $poll=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
  if($observation.AuthenticationGeneration -ne $poll.AuthenticationGeneration -or $observation.ObservedFingerprint -cne $poll.ObservedFingerprint){throw '[TC:IdentityObservationChanged] 会话在检查后发生变化。'}
  $evaluation=Get-TCServerIdentityEvaluation $server $observation $Root
  if($evaluation.Classification -ceq 'Blocked'){return [pscustomobject]@{Code='ServerIdentityBlocked';Classification='Blocked';ReasonCode=$evaluation.ReasonCode;CanCommit=$false;ServerId=$ServerId;NetworkChanged=$false;RemoteChanges=$false}}
  $context.Kind='Assessment';$context.Classification=$evaluation.Classification;$context.EvidenceDigest=$evaluation.EvidenceDigest;$context.AuthenticationGeneration=[int]$poll.AuthenticationGeneration
  $context.NewFingerprint=$poll.ObservedFingerprint
  if($context.Classification -cne 'ApplicationReset'){$context.NewServerId=$ServerId}
  $context.ChangeDigest=Get-TCDDigest @{ServerId=$ServerId;NewServerId=$context.NewServerId;RecordDigest=$context.RecordDigest;TasksDigest=$context.TasksDigest;SessionDigest=$context.SessionDigest;AuthenticationGeneration=$context.AuthenticationGeneration;NewFingerprint=$context.NewFingerprint;Classification=$context.Classification;EvidenceDigest=$context.EvidenceDigest;ExpiresAtUtc=$context.ExpiresAtUtc;Policy='VerifiedIdentityTransition.v2'}
  return [pscustomobject]@{Code='ServerIdentityAssessed';Classification=$context.Classification;ReasonCode=$null;CanCommit=$true;ServerId=$ServerId;NewServerId=$context.NewServerId;PreviousFingerprint=$server.PinnedHostKey;NewFingerprint=$context.NewFingerprint;HostKeyAlgorithm=$observation.ObservedHostKeyAlgorithm;ChangeDigest=$context.ChangeDigest;AssessmentToken=(Protect-TCServerReinstallToken $context);ExpiresAtUtc=$context.ExpiresAtUtc;PreservesApplicationIdentity=($context.Classification -in @('Unchanged','HostKeyUpdate'));RequiresResetDeclaration=($context.Classification -ceq 'ApplicationReset' -and -not $context.DeclaredApplicationReset);RequiresFreshApproval=($context.Classification -cne 'Unchanged');ArchivedTasks=$(if($context.Classification -ceq 'ApplicationReset'){$tasks}else{@()});NetworkChanged=$false;RemoteChanges=$false}
 }finally{$lease.Dispose()}
}
function New-TCServerIdentityTargetToken {param([string]$Root,$Server,$SessionRef,$Poll,[string]$EvidenceDigest,[string]$Classification)
 $context=[ordered]@{SchemaVersion=1;FlowVersion=2;Kind='Target';TransitionClassification=$Classification;Root=(Assert-TCDPath $Root).TrimEnd('\');ServerId=$Server.LocalRecordId;RecordDigest=(Get-TCDDigest $Server);SessionDigest=(Get-TCDDigest $SessionRef);NewFingerprint=$Poll.ObservedFingerprint;AuthenticationGeneration=[int]$Poll.AuthenticationGeneration;EvidenceDigest=$EvidenceDigest;ExpiresAtUtc=[DateTime]::UtcNow.AddMinutes(10).ToString('o')}
 return Protect-TCServerReinstallToken $context
}
function Assert-TCServerIdentitySessionBinding {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$TargetToken)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $TargetToken Target;Assert-TCServerIdentityContext $context
 $server=Get-TCServer $Root $ServerId;$null=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
 $observation=Get-TCDeployServerIdentityEvidence -SessionRef $SessionRef
 $evaluation=Get-TCServerIdentityEvaluation $server $observation $Root
 if([string](Get-TCDField $context EvidenceDigest '') -cnotmatch '^[a-f0-9]{64}$' -or $evaluation.EvidenceDigest -cne $context.EvidenceDigest){throw '[TC:IdentityEvidenceChanged] 会话接到新任务前应用状态已变化，请重新核验。'}
 $null=Read-TCServerReinstallToken $Root $ServerId $SessionRef $TargetToken Target
 $null=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
 return [pscustomobject]@{Code='ServerIdentitySessionVerified';Server=$server;SessionRef=$SessionRef;NetworkChanged=$false;RemoteChanges=$false}
}
function Get-TCServerTextDigest {param([string]$Text)
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Read-TCServerPrivateText {param([string]$Path,[int]$MaxBytes)
 $full=Assert-TCDPath $Path
 if(-not [IO.File]::Exists($full) -or (Get-Item -LiteralPath $full).Length -gt $MaxBytes){throw '[TC:LocalRequestIncomplete] 本机原始申请资料缺失或超限。'}
 $acl=Get-Acl -LiteralPath $full;$allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
 if(-not $acl.AreAccessRulesProtected){throw '[TC:UnsafeAcl] 原始申请私有文件权限未受保护。'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed){throw '[TC:UnsafeAcl] 原始申请文件向其他账户开放。'}}
 return [IO.File]::ReadAllText($full,[Text.Encoding]::UTF8)
}
function Read-TCServerLocalRequest {param([string]$Directory)
 $directory=Assert-TCDPath $Directory;$request=Read-TCDJson (Join-Path $directory 'public.request.json') -MaxBytes 16384;$state=Read-TCDJson (Join-Path $directory 'client.state.json') -MaxBytes 16384
 Assert-TCDFields $request @('SchemaVersion','Kind','RequestId','DeviceId','CreatedAtUtc','ClientPublicKey','AddressFamilies') @('SchemaVersion','Kind','RequestId','DeviceId','ClientPublicKey','AddressFamilies')
 $null=Assert-TCDId ([string]$request.RequestId);$null=Assert-TCDId ([string]$request.DeviceId)
 if($request.SchemaVersion -ne 1 -or $request.Kind -cne 'TradeChannel.ClientRequest' -or (@($request.AddressFamilies) -join ',') -cne 'IPv4' -or [string]$request.ClientPublicKey -cnotmatch '^[A-Za-z0-9+/]{43}=$' -or (Get-TCDField $state SchemaVersion 0) -ne 1 -or (Get-TCDField $state Kind '') -cne 'TradeChannel.ClientPrivateState' -or (Get-TCDField $state RequestId '') -cne $request.RequestId -or (Get-TCDField $state DeviceId '') -cne $request.DeviceId -or (Get-TCDField $state ClientPublicKey '') -cne $request.ClientPublicKey){throw '[TC:LocalRequestMismatch] 本机申请与原始私有状态不匹配。'}
 $private=$null
 try{
  $private=(Read-TCServerPrivateText (Join-Path $directory 'client.key') 256).Trim()
  if($private -cnotmatch '^[A-Za-z0-9+/]{43}=$' -or (Get-TCDField $state PrivateKeyHash '') -cne (Get-TCServerTextDigest $private)){throw '[TC:LocalRequestMismatch] 原始私钥与申请状态不匹配，未生成替代设备。'}
 }finally{$private=$null}
 return [pscustomobject]@{Request=$request;FilesDigest=(Get-TCDDigest @{Request=$request;State=$state})}
}
function Read-TCServerSameApplicationAuthorization {
 param($Server,$Context,$SessionRef,$Request)
 $null=Assert-TCServerIdentityPoll $Server $Context $SessionRef -Authenticated
 $id=[guid]::NewGuid().ToString('D');$action='deployment_state'
 $started=Invoke-TCDeployOperation -SessionRef $SessionRef -Operation $action -OperationInput @{ClientPublicKey=$Request.ClientPublicKey;ServerPublicKey=$Server.ServerPublicKey} -OperationId $id
 if(-not (Get-TCDField $started Ok $false) -or (Get-TCDField $started OperationId '') -cne $id -or (Get-TCDField $started Operation '') -cne $action){throw '[TC:SameApplicationAuthorizationUnverified] 原设备只读核验未被接受，未新增或授权任何 Peer。'}
 $deadline=[DateTime]::UtcNow.AddSeconds(180)
 do{
  $poll=Assert-TCServerIdentityPoll $Server $Context $SessionRef -Authenticated -AllowRunning
  if((Get-TCDField $poll OperationId '') -cne $id -or (Get-TCDField $poll Operation '') -cne $action){throw '[TC:IdentityObservationChanged] 原设备核验的会话或操作已变化。'}
  if($poll.Status -cne 'Running'){break}
  if([DateTime]::UtcNow -ge $deadline){throw '[TC:SameApplicationAuthorizationUnverified] 原设备只读核验超时，未新增或授权任何 Peer。'}
  Start-Sleep -Milliseconds 100
 }while($true)
 if($poll.Status -cne 'Completed' -or $poll.Code -cne 'Completed' -or -not (Get-TCDField $poll Ok $false)){throw '[TC:SameApplicationAuthorizationUnverified] 当前服务器未证明原设备授权，未回退到新增 Peer。'}
 $state=Get-TCDField $poll Data;$udp=Get-TCDField $state Udp;$response=Get-TCDField $udp ClientResponse
 if((Get-TCDField $state Kind '') -cne 'TradeChannel.DeploymentState' -or (Get-TCDField $state Status '') -cne 'Settled' -or (Get-TCDField $state Transaction) -or (Get-TCDField $state RemoteOwnerId '') -cne $Server.RemoteOwnerId -or (Get-TCDField $state NodeId '') -cne $Server.NodeId -or (Get-TCDField $state ServerPublicKey '') -cne $Server.ServerPublicKey -or (Get-TCDField $state ClientPublicKey '') -cne $Request.ClientPublicKey -or (Get-TCDField $udp Status '') -cne 'Healthy'){throw '[TC:SameApplicationAuthorizationUnverified] 原应用、原设备或 UDP 状态未通过只读核验，未新增 Peer。'}
 if((Get-TCDField $response SchemaVersion 0) -ne 1 -or (Get-TCDField $response Kind '') -cne 'TradeChannel.ClientResponse' -or (Get-TCDField $response Status '') -cne 'Authorized' -or (Get-TCDField $response NodeId '') -cne $Server.NodeId -or (Get-TCDField $response ServerPublicKey '') -cne $Server.ServerPublicKey -or (Get-TCDField $response RequestId '') -cne $Request.RequestId -or (Get-TCDField $response DeviceId '') -cne $Request.DeviceId -or (Get-TCDField $response ClientPublicKey '') -cne $Request.ClientPublicKey -or (Get-TCDField $response ClientAddress '') -cne (Get-TCDField $udp ClientAddress '') -or (@(Get-TCDField $response AddressFamilies @()) -join ',') -cne 'IPv4'){throw '[TC:SameApplicationAuthorizationUnverified] 当前授权响应不属于原申请和设备，未复用。'}
 return $response
}
function Get-TCServerSameApplicationRequest {
 # Call immediately after HostKeyUpdate, before clearing or editing the source
 # run. This reads the exact task snapshot frozen by the committed transition.
 # Default returns the original request references only. Optional authorization
 # is read from a CURRENT verified deployment_state, never copied from old data.
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)][string]$SourceRunId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$TargetToken,[switch]$IncludeAuthorizationCheckpoint)
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $TargetToken Target;Assert-TCServerIdentityContext $context
 if((Get-TCDField $context TransitionClassification '') -cne 'HostKeyUpdate'){throw '[TC:SameApplicationReuseBlocked] 只有已确认的同应用 SSH 密钥更新允许复用原请求；重置和未部署目标必须重新准备。'}
 $verified=Assert-TCServerIdentitySessionBinding -Root $Root -ServerId $ServerId -SessionRef $SessionRef -TargetToken $TargetToken;$server=$verified.Server
 $id=Assert-TCDId $SourceRunId;Assert-TCDraftActive -Root $Root -Id ('DeploymentRun:'+$id);$path=Join-Path (Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') $id) 'state.json';$run=Read-TCDJson $path
 $frozen=@(Get-TCDField $server IdentityTransitionTasks @()|Where-Object {$_.Kind -ceq 'Deployment' -and $_.Id -ceq $id})
 if($frozen.Count -ne 1 -or $run.RunId -cne $id -or $run.ServerRecordId -cne $ServerId -or $frozen[0].Digest -cne (Get-TCDDigest $run)){throw '[TC:SameApplicationSourceChanged] 原任务不属于本次同应用核验，或已被修改。请在清除原任务批准之前读取原请求。'}
 $info=Get-TCDField $run ServerInfo;$node=Get-TCDField $info Node
 if((Get-TCDField $info RemoteOwnerId '') -cne [string]$server.RemoteOwnerId -or (Get-TCDField $node NodeId '') -cne [string]$server.NodeId -or (Get-TCDField $node ServerPublicKey '') -cne [string]$server.ServerPublicKey -or (Get-TCDDigest (Get-TCDField $info ManagementSigningPublicKey)) -cne (Get-TCDDigest $server.ManagementSigningPublicKey)){throw '[TC:SameApplicationBindingMismatch] 原请求未绑定已验证的当前应用身份。'}
 $dispatch=Get-TCDField $run DispatchIntent
 if((Get-TCDField $run RecoveryRequired $false) -or (Get-TCDField $run Status '') -in @('OutcomeUnknown','NeedsRecovery') -or (Get-TCDField $run UnresolvedTcpMutation) -or ((Get-TCDField $dispatch Mutating $false) -and (Get-TCDField $dispatch State '') -notin @('Completed','Rejected'))){throw '[TC:SameApplicationOutcomeUnknown] 原任务仍有未决结果，不能把请求迁入另一项准备。'}
 $request=Get-TCDField $run ClientRequest;$directory=[string](Get-TCDField $run RequestDirectory '')
 if(-not $request -and -not $directory){return [pscustomobject]@{Code='ServerRequestNotCreated';CanReuse=$false;SourceRunId=$id;RequestDirectory=$null;ClientRequest=$null;NetworkChanged=$false;RemoteChanges=$false}}
 if(Get-TCDField $run ExistingDevice $false){throw '[TC:SameApplicationExistingDevice] 原任务使用已导入的设备，请按原 CandidateNodeId 调用 Existing 入口，保持设备私钥与线路不变。'}
 $expected=Assert-TCDPath (Join-Path ([IO.Path]::GetDirectoryName($path)) 'client')
 if(-not $directory -or (Assert-TCDPath $directory).TrimEnd('\') -ine $expected.TrimEnd('\')){throw '[TC:SameApplicationRequestPath] 原请求目录未绑定本次原任务，不能迁移其他生成代次的申请。'}
 $local=Read-TCServerLocalRequest $expected
 if((Get-TCDDigest $request) -cne (Get-TCDDigest $local.Request)){throw '[TC:LocalRequestMismatch] 原任务中的公开请求与原申请目录不一致。'}
 if((Get-TCDField $frozen[0] RequestFilesDigest '') -cne $local.FilesDigest){throw '[TC:SameApplicationSourceChanged] 原申请文件不属于本次提交的检查点，或在提交后发生变化。'}
 $response=Get-TCDField $run ClientResponse
 if($response -and ((Get-TCDField $response NodeId '') -cne $server.NodeId -or (Get-TCDField $response ServerPublicKey '') -cne $server.ServerPublicKey -or (Get-TCDField $response RequestId '') -cne $request.RequestId -or (Get-TCDField $response DeviceId '') -cne $request.DeviceId -or (Get-TCDField $response ClientPublicKey '') -cne $request.ClientPublicKey)){throw '[TC:SameApplicationBindingMismatch] 原授权响应属于另一应用或设备，未复用。'}
 $liveResponse=$null
 if($IncludeAuthorizationCheckpoint -and $response){$liveResponse=Read-TCServerSameApplicationAuthorization $server $context $SessionRef $local.Request}
 $null=Read-TCServerReinstallToken $Root $ServerId $SessionRef $TargetToken Target
 if($frozen[0].Digest -cne (Get-TCDDigest (Read-TCDJson $path)) -or $local.FilesDigest -cne (Read-TCServerLocalRequest $expected).FilesDigest){throw '[TC:SameApplicationSourceChanged] 原任务或原请求在核验期间发生变化。'}
 $result=[pscustomobject]@{Code='ServerSameApplicationRequestVerified';CanReuse=$true;ServerId=$ServerId;SourceRunId=$id;RequestDirectory=$expected;ClientRequest=$local.Request;HasAuthorizationCheckpoint=[bool]$response;CanReuseAuthorization=[bool]$liveResponse;RequiresFreshApproval=$true;NetworkChanged=$false;RemoteChanges=$false}
 if($IncludeAuthorizationCheckpoint){$result|Add-Member NoteProperty ClientResponse $liveResponse;$result|Add-Member NoteProperty AuthorizationState $(if($liveResponse){'Verified'}else{'RequestOnly'})}
 return $result
}
function Confirm-TCServerIdentityTransition {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$AssessmentToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[Parameter(Mandatory=$true)][string]$ApprovedChangeDigest,[switch]$DeclaredApplicationReset)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $ServerId;$lock=$null
 try{
  $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $AssessmentToken Assessment;Assert-TCServerIdentityContext $context
  if($ConfirmedFingerprint -cne $context.NewFingerprint -or $ApprovedChangeDigest -cne $context.ChangeDigest){throw '[TC:ReinstallConfirmationMismatch] 确认指纹或变更摘要与本次应用核验不一致。'}
  if($context.Classification -ceq 'ApplicationReset' -and -not ($context.DeclaredApplicationReset -or $DeclaredApplicationReset)){throw '[TC:ReinstallDeclarationRequired] 请明确确认应用环境已重置及原记录归档范围。'}
  $server=Get-TCServer $Root $ServerId;$tasks=@(Get-TCServerReinstallTasks $Root $server)
  if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务已变化，未归档或续接。'}
  $null=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
  $observation=Get-TCDeployServerIdentityEvidence -SessionRef $SessionRef
  $evaluation=Get-TCServerIdentityEvaluation $server $observation $Root
  if($evaluation.Classification -ceq 'Blocked' -or $evaluation.Classification -cne $context.Classification -or $evaluation.EvidenceDigest -cne $context.EvidenceDigest){throw '[TC:IdentityEvidenceChanged] 实际应用身份或环境与预览不一致，原记录保留。'}
  $lock=Open-TCDLock (Join-Path (Get-TCDPath $Root servers) '.registry.lock')
  $null=Read-TCServerReinstallToken $Root $ServerId $SessionRef $AssessmentToken Assessment
  $tasks=@(Get-TCServerReinstallTasks $Root $server);if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在提交前发生变化。'}
  $poll=Assert-TCServerIdentityPoll $server $context $SessionRef -Authenticated
  if($poll.AuthenticationGeneration -ne $observation.AuthenticationGeneration){throw '[TC:IdentityObservationChanged] 提交前登录代次发生变化。'}
  $now=[DateTime]::UtcNow.ToString('o');$registry=Read-TCServerRegistry $Root;$newId=Assert-TCDId $context.NewServerId
  if($context.Classification -ceq 'ApplicationReset'){
   if(@($registry.Servers|Where-Object {$_.LocalRecordId -ceq $newId}).Count){throw '[TC:IdentityRecordCollision] 新身份标识已存在，未覆盖任何记录。'}
   $new=[pscustomobject][ordered]@{LocalRecordId=$newId;Name=$server.Name;Endpoints=@();Connection=@{Host=$server.Connection.Host;Port=[int]$server.Connection.Port;User=$server.Connection.User;IdentityFile=''};RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$context.NewFingerprint;HostTrustState='Verified';ObservedHostKeyAlgorithm=$observation.ObservedHostKeyAlgorithm;ManagementSigningPublicKey=$null;OwnershipState='Unverified';ManagementAccessState='NeedsAuthentication';CapabilityVersion=0;CredentialRef=$null;LinkedNodeIds=@();SourceJobIds=@();ExpectedExitIPv4=$null;ExpectedExitSource=$null;LastCheckedUtc=$null;CreatedAtUtc=$now;RecordState='Active';Reinstall=@{PreviousServerId=$ServerId;ConfirmedAtUtc=$now;ChangeDigest=$context.ChangeDigest;EvidenceDigest=$context.EvidenceDigest;FreshDeviceIdentityRequired=$true};IdentityTransitionRevision=1;IdentityTransitionTasks=@();ArchivedAtUtc=$null;ReplacedByServerId=$null;ArchivedTasks=@()}
   $server|Add-Member NoteProperty RecordState 'Archived' -Force;$server|Add-Member NoteProperty ArchivedAtUtc $now -Force;$server|Add-Member NoteProperty ReplacedByServerId $newId -Force;$server|Add-Member NoteProperty ArchivedTasks $tasks -Force
   $records=@($registry.Servers|ForEach-Object {if($_.LocalRecordId -ceq $ServerId){$server}else{$_}})+@($new)
  }else{
   $server.PinnedHostKey=$context.NewFingerprint;$server.LastCheckedUtc=$now;$server.ManagementAccessState='Authenticated';$server.OwnershipState='Applied'
   if($context.Classification -ceq 'UndeployedTarget'){$server.OwnershipState='Unverified';$server.ManagementAccessState='NeedsAuthentication';$server.CredentialRef=$null;$server.SourceJobIds=@();$server|Add-Member NoteProperty LegacyCheckpoints @() -Force;$server.Connection.IdentityFile=''}
   $server|Add-Member NoteProperty HostTrustState 'Verified' -Force;$server|Add-Member NoteProperty ObservedHostKeyAlgorithm $observation.ObservedHostKeyAlgorithm -Force
   $server|Add-Member NoteProperty IdentityTransitionRevision ([int](Get-TCDField $server IdentityTransitionRevision 0)+1) -Force
   if($context.Classification -in @('HostKeyUpdate','UndeployedTarget')){
    $barrier=@($tasks)
    foreach($previousTask in @(Get-TCDField $server IdentityTransitionTasks @())){if(-not @($barrier|Where-Object {$_.Kind -ceq $previousTask.Kind -and $_.Id -ceq $previousTask.Id}).Count){$barrier+=,$previousTask}}
    $server|Add-Member NoteProperty IdentityTransitionTasks @($barrier|Sort-Object Kind,Id) -Force
   }
   $new=$server;$records=@($registry.Servers|ForEach-Object {if($_.LocalRecordId -ceq $ServerId){$server}else{$_}})
  }
  # One atomic registry replacement. Original tasks, credentials and local
  # product files are never rewritten, stopped, deleted or imported into reset.
  Write-TCDJson (Join-Path (Get-TCDPath $Root servers) 'registry.json') ([ordered]@{SchemaVersion=1;Revision=[int]$registry.Revision+1;Servers=$records})
  return [pscustomobject]@{Code='ServerIdentityTransitionConfirmed';Classification=$context.Classification;PreviousServerId=$ServerId;Server=$new;SessionRef=$SessionRef;TargetToken=(New-TCServerIdentityTargetToken $Root $new $SessionRef $poll $context.EvidenceDigest $context.Classification);ArchivedTasks=$(if($context.Classification -ceq 'ApplicationReset'){$tasks}else{@()});InvalidatedTasks=$(if($context.Classification -in @('HostKeyUpdate','UndeployedTarget')){$tasks}else{@()});RequiresFreshApproval=($context.Classification -cne 'Unchanged');RequiresNewDeployment=($context.Classification -in @('ApplicationReset','UndeployedTarget'));RequiresFreshDeviceIdentity=($context.Classification -in @('ApplicationReset','UndeployedTarget'));NetworkChanged=$false;RemoteChanges=$false}
 }finally{if($lock){$lock.Dispose()};$lease.Dispose()}
}
function Start-TCServerReinstallVerification {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$Credential,[switch]$DeclaredReinstalled)
 if(-not $DeclaredReinstalled){throw '[TC:ReinstallDeclarationRequired] 请明确选择“服务器已重装”，再重新核验。'}
 $result=Start-TCServerIdentityVerificationCore -Root $Root -ServerId $ServerId -Credential $Credential -DeclaredApplicationReset -DiscoverHostKey
 $result.Code='ReinstallVerificationStarted';return $result
}
function New-TCServerReinstallPreview {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$VerificationToken)
 # Same SSH key is supported. It proves host continuity, not app continuity.
 $result=New-TCServerIdentityTrustPreview @PSBoundParameters
 $result.Code='ReinstallTrustRequired';return $result
}
function Approve-TCServerReinstallFingerprint {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$PreviewToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[Parameter(Mandatory=$true)]$Credential)
 $result=Approve-TCServerIdentityFingerprint @PSBoundParameters
 $result.Code='ReinstallAuthenticating';return $result
}
function Confirm-TCServerReinstallRecord {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$ApprovalToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[Parameter(Mandatory=$true)][string]$ApprovedChangeDigest)
 # The old parameter contract remains accepted. A host-trust-only approval may
 # request assessment, but may NEVER commit an application reset by itself.
 $plain=$null
 try{
  Add-Type -AssemblyName System.Security
  $plain=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($ApprovalToken),[Text.Encoding]::UTF8.GetBytes('TradeChannel.ServerReinstall.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
  $kind=[string](Get-TCDField ([Text.Encoding]::UTF8.GetString($plain)|ConvertFrom-Json) Kind '')
 }catch{throw '[TC:ReinstallTokenInvalid] 重装核验令牌无效。'}finally{if($plain){[Array]::Clear($plain,0,$plain.Length)}}
 if($kind -ceq 'Assessment'){
  $result=Confirm-TCServerIdentityTransition -Root $Root -ServerId $ServerId -SessionRef $SessionRef -AssessmentToken $ApprovalToken -ConfirmedFingerprint $ConfirmedFingerprint -ApprovedChangeDigest $ApprovedChangeDigest -DeclaredApplicationReset
  if($result.Classification -ceq 'ApplicationReset'){$result.Code='ServerReinstallConfirmed'}
  return $result
 }
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $ApprovalToken Approval
 if($ConfirmedFingerprint -cne $context.NewFingerprint -or $ApprovedChangeDigest -cne $context.ChangeDigest){throw '[TC:ReinstallConfirmationMismatch] 确认指纹或摘要与本次预览不一致。'}
 $assessment=New-TCServerIdentityAssessment -Root $Root -ServerId $ServerId -SessionRef $SessionRef -ApprovalToken $ApprovalToken
 if($assessment.CanCommit){$assessment.Code='ServerIdentityAssessmentRequired';$assessment|Add-Member NoteProperty ApprovalToken $assessment.AssessmentToken}
 return $assessment
}
Export-ModuleMember -Function Assert-TCManagementSigningPublicKey,Get-TCServers,Get-TCServer,Set-TCServerRecord,Set-TCServerLink,Import-TCLegacyServerIndex,Import-TCServerRecoveryRecord,Assert-TCServerTaskActive,Open-TCServerTaskLease,Start-TCServerReinstallVerification,New-TCServerReinstallPreview,Approve-TCServerReinstallFingerprint,Confirm-TCServerReinstallRecord,Start-TCServerIdentityVerification,New-TCServerIdentityTrustPreview,Approve-TCServerIdentityFingerprint,New-TCServerIdentityAssessment,Confirm-TCServerIdentityTransition,Assert-TCServerIdentitySessionBinding,Get-TCServerSameApplicationRequest
