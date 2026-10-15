#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
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
 $id=Assert-TCDId $Id;$found=@(Get-TCServers $Root|Where-Object {$_.LocalRecordId -eq $id})
 if($found.Count -ne 1){throw '[TC:ServerMissing] 服务器记录不存在，请重新选择。'}
 if(-not $IncludeArchived -and (Get-TCDField $found[0] RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 此服务器身份已归档，旧任务和授权不能续接。请使用重装后新建的记录。'}
 return $found[0]
}
function Set-TCServerRecord {
 [CmdletBinding()]param([string]$Root,[string]$Id,$Connection,$ServerInfo,[string]$Name,[string]$PinnedFingerprint,[string[]]$SourceJobIds=@(),[string]$CredentialRef,[switch]$UnverifiedRecovery,[switch]$ConnectorOnly)
 $dir=Get-TCDPath $Root servers;$lock=Open-TCDLock (Join-Path $dir '.registry.lock')
 try{
  $registry=Read-TCServerRegistry $Root;$records=@($registry.Servers)
  $old=$null
  if($Id){$Id=Assert-TCDId $Id;$old=@($records|Where-Object {$_.LocalRecordId -eq $Id})|Select-Object -First 1}
  if($old -and (Get-TCDField $old RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 原服务器身份已归档，不能更新或重新授权。'}
  if($ServerInfo -and -not $old){
   $owner=[string](Get-TCDField $ServerInfo RemoteOwnerId '')
   $public=[string](Get-TCDField (Get-TCDField $ServerInfo Node) ServerPublicKey '')
   if($owner -and @($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -ceq 'Archived' -and $_.RemoteOwnerId -ceq $owner}).Count){throw '[TC:ServerArchived] 旧归属的授权资料已归档，不能重新导入。'}
   if($owner){$old=@($records|Where-Object {$_.RemoteOwnerId -eq $owner -and (-not $public -or $_.ServerPublicKey -eq $public)})|Select-Object -First 1;if($old){if((Get-TCDField $old RecordState 'Active') -ceq 'Archived'){throw '[TC:ServerArchived] 旧归属的授权资料已归档，不能导入新服务器。'};$Id=$old.LocalRecordId}}
  }
  if($Connection -and -not $old -and -not $Id){
   # Reuse an endpoint's provisional card; its pinned remote identity is still checked below.
   $candidateHost=[string](Get-TCDField $Connection Host '');$candidatePort=[int](Get-TCDField $Connection Port 22);$candidateUser=[string](Get-TCDField $Connection User 'root')
   $same=@($records|Where-Object {(Get-TCDField $_ RecordState 'Active') -cne 'Archived' -and $_.Connection -and $_.Connection.Host -ceq $candidateHost -and [int]$_.Connection.Port -eq $candidatePort -and $_.Connection.User -ceq $candidateUser})
   if($same.Count -gt 1){throw '[TC:RegistryAmbiguous] 此接入地址已有多个历史记录，请先选择已有服务器并核验身份。'}
   if($same.Count -eq 1){$old=$same[0];$Id=$old.LocalRecordId}
  }
  if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
  $entry=[ordered]@{LocalRecordId=$Id;Name='服务器';Endpoints=@();Connection=$null;RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;ManagementSigningPublicKey=$null;OwnershipState='Unverified';ManagementAccessState='NeedsAuthentication';CapabilityVersion=0;CredentialRef=$null;LinkedNodeIds=@();SourceJobIds=@();ExpectedExitIPv4=$null;ExpectedExitSource=$null;LastCheckedUtc=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $entry.RecordState='Active';$entry.Reinstall=$null;$entry.ArchivedAtUtc=$null;$entry.ReplacedByServerId=$null;$entry.ArchivedTasks=@()
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
  if($PinnedFingerprint){if($PinnedFingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){throw '[TC:FingerprintInvalid] SSH 主机指纹无效。'};if($entry.PinnedHostKey -and $entry.PinnedHostKey -cne $PinnedFingerprint){throw '[TC:HostChanged] 已知 SSH 主机身份变化，请先核验。'};$entry.PinnedHostKey=$PinnedFingerprint}
  if($CredentialRef){$entry.CredentialRef=$CredentialRef}
  $entry.SourceJobIds=@(@($entry.SourceJobIds)+@($SourceJobIds)|Select-Object -Unique)
  if($ServerInfo){
   $node=Get-TCDField $ServerInfo Node
   $owner=[string](Get-TCDField $ServerInfo RemoteOwnerId '')
   $nodeId=[string](Get-TCDField $node NodeId '')
   $public=[string](Get-TCDField $node ServerPublicKey '')
   if($entry.RemoteOwnerId -and $owner -and $entry.RemoteOwnerId -cne $owner){throw '[TC:ServerChanged] 此地址的服务器归属已经变化。'}
   if($entry.ServerPublicKey -and $public -and $entry.ServerPublicKey -cne $public){throw '[TC:ServerChanged] 此服务器的隧道身份已经变化。'}
   if($owner){$entry.RemoteOwnerId=$owner};if($nodeId){$entry.NodeId=$nodeId};if($public){$entry.ServerPublicKey=$public}
   $endpoint=[string](Get-TCDField $node PublicEndpoint '');if($endpoint){$entry.Endpoints=@(@($entry.Endpoints)+@($endpoint)|Select-Object -Unique)}
   $signing=Get-TCDField $ServerInfo ManagementSigningPublicKey
   if($signing){
    Assert-TCDFields $signing @('kty','n','e') @('kty','n','e')
    if($signing.kty -cne 'RSA' -or $signing.e -cne 'AQAB' -or $signing.n -cnotmatch '^[A-Za-z0-9_-]{512}$'){throw '[TC:ManagementIdentityInvalid] 管理签名身份不是受支持的 RSA-3072 公钥。'}
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
   else{$entry.ManagementAccessState='Authenticated';$entry.LastCheckedUtc=[DateTime]::UtcNow.ToString('o')}
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
function Import-TCLegacyServerIndex {param([string]$Root)
 $jobs=Join-Path (Assert-TCDPath $Root) 'linux-jobs';if(-not [IO.Directory]::Exists($jobs)){return [pscustomobject]@{Imported=0;Servers=@()}}
 $count=0;$results=@()
 foreach($group in @(Get-ChildItem -LiteralPath $jobs -Directory|Select-Object -First 500|ForEach-Object {
  $path=Join-Path $_.FullName 'job.json';if([IO.File]::Exists($path)){
   $job=Read-TCDJson $path
   if((Get-TCDField $job SchemaVersion) -eq 1 -and (Get-TCDField $job Connection)){
    [pscustomobject]@{GroupKey=([string]$job.Connection.Host+':'+[string]$job.Connection.Port+'/'+[string]$job.Connection.User);Job=$job}
   }
  }
 }|Group-Object GroupKey)){
  $blocked=@(Get-TCServers $Root|Where-Object {(Get-TCDField $_ RecordState 'Active') -ceq 'Archived'}|ForEach-Object {@($_.SourceJobIds);@(Get-TCDField $_ ArchivedTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id})})
  $remaining=@($group.Group|Where-Object {$_.Job.JobId -notin $blocked});if(-not $remaining.Count){continue}
  $first=$remaining[0].Job;$match=@(Get-TCServers $Root|Where-Object {(Get-TCDField $_ RecordState 'Active') -cne 'Archived' -and $_.Connection -and ([string]$_.Connection.Host+':'+[string]$_.Connection.Port+'/'+[string]$_.Connection.User) -eq $group.Name})|Select-Object -First 1
  $params=@{Root=$Root;Connection=$first.Connection;Name=$first.Name;SourceJobIds=@($remaining|ForEach-Object {$_.Job.JobId})};if($match){$params.Id=$match.LocalRecordId}
  $results+=Set-TCServerRecord @params;$count++
 }
 return [pscustomobject]@{Imported=$count;Servers=$results;Message='历史记录已登记，服务器身份和管理权限仍需登录核验。'}
}
function Assert-TCServerTaskActive {
 [CmdletBinding(DefaultParameterSetName='Run')]param([string]$Root,[Parameter(Mandatory=$true,ParameterSetName='Run')][string]$RunId,[Parameter(Mandatory=$true,ParameterSetName='Legacy')][string]$SourceJobId)
 if($PSCmdlet.ParameterSetName -ceq 'Run'){
  $id=Assert-TCDId $RunId;$run=Read-TCDJson (Join-Path (Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') $id) 'state.json')
  return Get-TCServer -Root $Root -Id ([string](Get-TCDField $run ServerRecordId ''))
 }
 $id=Assert-TCDId $SourceJobId
 foreach($server in @(Get-TCServers $Root)){
  if($id -in @($server.SourceJobIds) -or $id -in @(Get-TCDField $server ArchivedTasks @()|Where-Object {$_.Kind -ceq 'Legacy'}|ForEach-Object {$_.Id})){return Get-TCServer -Root $Root -Id $server.LocalRecordId}
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
   if((Get-TCDField $run ServerRecordId '') -ceq $Server.LocalRecordId){$tasks+=[pscustomobject]@{Kind='Deployment';Id=(Assert-TCDId ([string]$run.RunId));State=[string]$run.Status;Digest=(Get-TCDDigest $run)}}
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
 if((Get-TCDField $poll RunId '') -cne [string]$SessionRef.RunId -or (Get-TCDField $poll InstanceId '') -cne [string]$SessionRef.InstanceId -or (Get-TCDField $poll OperationId '') -or (Get-TCDField $poll Operation '')){throw '[TC:ReinstallSessionMismatch] 重装核验仅接受独立、未执行远端操作的 SSH 会话。'}
 return $poll
}
function Start-TCServerReinstallVerification {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$Credential,[switch]$DeclaredReinstalled)
 if(-not $DeclaredReinstalled){throw '[TC:ReinstallDeclarationRequired] 请明确选择“服务器已重装”，再重新核验。'}
 $rootPath=(Assert-TCDPath $Root).TrimEnd('\');$lease=Open-TCServerTaskLease -Root $rootPath -ServerId $ServerId
 try{
  $server=Get-TCServer -Root $rootPath -Id $ServerId
  if(-not $server.Connection -or [string]$server.PinnedHostKey -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}=?$'){throw '[TC:ReinstallIdentityRequired] 重装核验需要已登记的 SSH 地址和原指纹。'}
  $tasks=@(Get-TCServerReinstallTasks $rootPath $server)
  Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
  # No old saved credential, client key, authorization or service operation is read.
  # An empty pin here is discovery in a NEW session: the existing executor refuses
  # authentication until an exact fingerprint is explicitly supplied.
  $connection=@{Host=$server.Connection.Host;Port=[int]$server.Connection.Port;User=$server.Connection.User;IdentityFile=''}
  $started=Start-TCDeploySession -Root $rootPath -RunId ([guid]::NewGuid().ToString('D')) -Connection $connection -Credential $Credential
  if(-not $started.Ok -or -not $started.SessionRef){throw '[TC:ReinstallSessionRejected] 独立核验会话未建立，原记录保留。'}
  $context=[ordered]@{SchemaVersion=1;Kind='Verification';Root=$rootPath;ServerId=$server.LocalRecordId;NewServerId=[guid]::NewGuid().ToString('D');RecordDigest=(Get-TCDDigest $server);TasksDigest=(Get-TCDDigest $tasks);SessionDigest=(Get-TCDDigest $started.SessionRef);ExpiresAtUtc=[DateTime]::UtcNow.AddMinutes(10).ToString('o');NewFingerprint=$null;ChangeDigest=$null}
  return [pscustomobject]@{Code='ReinstallVerificationStarted';SessionRef=$started.SessionRef;VerificationToken=(Protect-TCServerReinstallToken $context);NetworkChanged=$false;RemoteChanges=$false}
 }finally{$lease.Dispose()}
}
function New-TCServerReinstallPreview {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$VerificationToken)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $VerificationToken Verification;$server=Get-TCServer $Root $ServerId
 $tasks=@(Get-TCServerReinstallTasks $Root $server)
 if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务在核验期间已变化，请重新核验。'}
 $poll=Get-TCServerReinstallPoll $SessionRef;$fingerprint=[string](Get-TCDField $poll ObservedFingerprint '')
 if($poll.Code -cne 'HostTrustRequired' -or $poll.HasSession -or $fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw '[TC:ReinstallObservationRequired] 尚未取得待确认的新 SSH 指纹，未建立新记录。'}
 if($fingerprint.TrimEnd('=') -ceq ([string]$server.PinnedHostKey).TrimEnd('=')){throw '[TC:ReinstallIdentityUnchanged] SSH 指纹未变化，请使用原记录核验；未创建重复身份。'}
 $context.Kind='Preview';$context.NewFingerprint=$fingerprint
 $context.ChangeDigest=Get-TCDDigest @{ServerId=$ServerId;NewServerId=$context.NewServerId;RecordDigest=$context.RecordDigest;TasksDigest=$context.TasksDigest;SessionDigest=$context.SessionDigest;NewFingerprint=$fingerprint;ExpiresAtUtc=$context.ExpiresAtUtc;Policy='ArchiveOldAndRequireFreshDeviceIdentity'}
 return [pscustomobject]@{Code='ReinstallTrustRequired';ServerId=$ServerId;NewServerId=$context.NewServerId;Name=$server.Name;Connection=@{Host=$server.Connection.Host;Port=[int]$server.Connection.Port;User=$server.Connection.User};PreviousFingerprint=$server.PinnedHostKey;NewFingerprint=$fingerprint;ExpiresAtUtc=$context.ExpiresAtUtc;ChangeDigest=$context.ChangeDigest;PreviewToken=(Protect-TCServerReinstallToken $context);ArchivedTasks=$tasks;NetworkChanged=$false;RemoteChanges=$false}
}
function Approve-TCServerReinstallFingerprint {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$PreviewToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[Parameter(Mandatory=$true)]$Credential)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $PreviewToken Preview
 if($ConfirmedFingerprint -cne $context.NewFingerprint){throw '[TC:ReinstallConfirmationMismatch] 明确确认的指纹与本次预览不一致。'}
 $poll=Get-TCServerReinstallPoll $SessionRef
 if($poll.HasSession -or $poll.Code -cne 'HostTrustRequired' -or $poll.ObservedFingerprint -cne $context.NewFingerprint){throw '[TC:ReinstallObservationChanged] 新指纹或会话状态已变化，请重新核验。'}
 $server=Get-TCServer $Root $ServerId
 $result=Set-TCDeployCredential -SessionRef $SessionRef -Connection @{Host=$server.Connection.Host;Port=[int]$server.Connection.Port;User=$server.Connection.User;IdentityFile=''} -Credential $Credential -PinnedFingerprint $context.NewFingerprint
 if(-not $result.Ok){throw '[TC:ReinstallAuthenticationRejected] 独立核验会话未接受认证。'}
 $context.Kind='Approval'
 return [pscustomobject]@{Code='ReinstallAuthenticating';ApprovalToken=(Protect-TCServerReinstallToken $context);NetworkChanged=$false;RemoteChanges=$false}
}
function Confirm-TCServerReinstallRecord {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$ServerId,[Parameter(Mandatory=$true)]$SessionRef,[Parameter(Mandatory=$true)][string]$ApprovalToken,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint,[Parameter(Mandatory=$true)][string]$ApprovedChangeDigest)
 Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
 $lease=Open-TCServerTaskLease -Root $Root -ServerId $ServerId;$lock=$null
 try{
  $lock=Open-TCDLock (Join-Path (Get-TCDPath $Root servers) '.registry.lock')
  $context=Read-TCServerReinstallToken $Root $ServerId $SessionRef $ApprovalToken Approval
  if($ConfirmedFingerprint -cne $context.NewFingerprint -or $ApprovedChangeDigest -cne $context.ChangeDigest){throw '[TC:ReinstallConfirmationMismatch] 确认指纹或变更摘要与本次预览不一致。'}
  $server=Get-TCServer $Root $ServerId;$tasks=@(Get-TCServerReinstallTasks $Root $server)
  if($context.TasksDigest -cne (Get-TCDDigest $tasks)){throw '[TC:ReinstallTasksChanged] 原任务已变化，请重新核验，未归档或续接。'}
  $poll=Get-TCServerReinstallPoll $SessionRef
  if($poll.Code -cne 'Authenticated' -or $poll.Status -cne 'Ready' -or -not $poll.HasSession -or $poll.ObservedFingerprint -cne $context.NewFingerprint){throw '[TC:ReinstallAuthenticationRequired] 新指纹认证尚未通过或已变化，原记录保留。'}
  $now=[DateTime]::UtcNow.ToString('o');$newId=Assert-TCDId $context.NewServerId
  $new=[pscustomobject][ordered]@{LocalRecordId=$newId;Name=$server.Name;Endpoints=@();Connection=@{Host=$server.Connection.Host;Port=[int]$server.Connection.Port;User=$server.Connection.User;IdentityFile=''};RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$context.NewFingerprint;ManagementSigningPublicKey=$null;OwnershipState='Unverified';ManagementAccessState='NeedsAuthentication';CapabilityVersion=0;CredentialRef=$null;LinkedNodeIds=@();SourceJobIds=@();ExpectedExitIPv4=$null;ExpectedExitSource=$null;LastCheckedUtc=$null;CreatedAtUtc=$now;RecordState='Active';Reinstall=@{PreviousServerId=$ServerId;ConfirmedAtUtc=$now;ChangeDigest=$context.ChangeDigest;FreshDeviceIdentityRequired=$true};ArchivedAtUtc=$null;ReplacedByServerId=$null;ArchivedTasks=@()}
  $server|Add-Member NoteProperty RecordState 'Archived' -Force
  $server|Add-Member NoteProperty ArchivedAtUtc $now -Force
  $server|Add-Member NoteProperty ReplacedByServerId $newId -Force
  $server|Add-Member NoteProperty ArchivedTasks $tasks -Force
  $registry=Read-TCServerRegistry $Root
  $records=@($registry.Servers|ForEach-Object {if($_.LocalRecordId -ceq $ServerId){$server}else{$_}})+@($new)
  # One atomic registry commit archives the old identity and publishes the new.
  Write-TCDJson (Join-Path (Get-TCDPath $Root servers) 'registry.json') ([ordered]@{SchemaVersion=1;Revision=[int]$registry.Revision+1;Servers=$records})
  return [pscustomobject]@{Code='ServerReinstallConfirmed';PreviousServerId=$ServerId;Server=$new;ArchivedTasks=$tasks;NetworkChanged=$false;RemoteChanges=$false;RequiresNewDeployment=$true;RequiresFreshDeviceIdentity=$true}
 }finally{if($lock){$lock.Dispose()};$lease.Dispose()}
}
Export-ModuleMember -Function Get-TCServers,Get-TCServer,Set-TCServerRecord,Set-TCServerLink,Import-TCLegacyServerIndex,Import-TCServerRecoveryRecord,Assert-TCServerTaskActive,Open-TCServerTaskLease,Start-TCServerReinstallVerification,New-TCServerReinstallPreview,Approve-TCServerReinstallFingerprint,Confirm-TCServerReinstallRecord
