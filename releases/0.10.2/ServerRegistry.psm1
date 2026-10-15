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
function Get-TCServer {param([string]$Root,[string]$Id)
 $id=Assert-TCDId $Id;$found=@(Get-TCServers $Root|Where-Object {$_.LocalRecordId -eq $id})
 if($found.Count -ne 1){throw '[TC:ServerMissing] 服务器记录不存在，请重新选择。'}
 return $found[0]
}
function Set-TCServerRecord {
 [CmdletBinding()]param([string]$Root,[string]$Id,$Connection,$ServerInfo,[string]$Name,[string]$PinnedFingerprint,[string[]]$SourceJobIds=@(),[string]$CredentialRef,[switch]$UnverifiedRecovery,[switch]$ConnectorOnly)
 $dir=Get-TCDPath $Root servers;$lock=Open-TCDLock (Join-Path $dir '.registry.lock')
 try{
  $registry=Read-TCServerRegistry $Root;$records=@($registry.Servers)
  $old=$null
  if($Id){$Id=Assert-TCDId $Id;$old=@($records|Where-Object {$_.LocalRecordId -eq $Id})|Select-Object -First 1}
  if($ServerInfo -and -not $old){
   $owner=[string](Get-TCDField $ServerInfo RemoteOwnerId '')
   $public=[string](Get-TCDField (Get-TCDField $ServerInfo Node) ServerPublicKey '')
   if($owner){$old=@($records|Where-Object {$_.RemoteOwnerId -eq $owner -and (-not $public -or $_.ServerPublicKey -eq $public)})|Select-Object -First 1;if($old){$Id=$old.LocalRecordId}}
  }
  if($Connection -and -not $old -and -not $Id){
   # Reuse an endpoint's provisional card; its pinned remote identity is still checked below.
   $candidateHost=[string](Get-TCDField $Connection Host '');$candidatePort=[int](Get-TCDField $Connection Port 22);$candidateUser=[string](Get-TCDField $Connection User 'root')
   $same=@($records|Where-Object {$_.Connection -and $_.Connection.Host -ceq $candidateHost -and [int]$_.Connection.Port -eq $candidatePort -and $_.Connection.User -ceq $candidateUser})
   if($same.Count -gt 1){throw '[TC:RegistryAmbiguous] 此接入地址已有多个历史记录，请先选择已有服务器并核验身份。'}
   if($same.Count -eq 1){$old=$same[0];$Id=$old.LocalRecordId}
  }
  if(-not $Id){$Id=[guid]::NewGuid().ToString('D')}
  $entry=[ordered]@{LocalRecordId=$Id;Name='服务器';Endpoints=@();Connection=$null;RemoteOwnerId=$null;NodeId=$null;ServerPublicKey=$null;PinnedHostKey=$null;ManagementSigningPublicKey=$null;OwnershipState='Unverified';ManagementAccessState='NeedsAuthentication';CapabilityVersion=0;CredentialRef=$null;LinkedNodeIds=@();SourceJobIds=@();ExpectedExitIPv4=$null;ExpectedExitSource=$null;LastCheckedUtc=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  if($old){foreach($key in @($entry.Keys)){if($old.PSObject.Properties[$key]){$entry[$key]=$old.$key}}}
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
  $first=$group.Group[0].Job;$match=@(Get-TCServers $Root|Where-Object {$_.Connection -and ([string]$_.Connection.Host+':'+[string]$_.Connection.Port+'/'+[string]$_.Connection.User) -eq $group.Name})|Select-Object -First 1
  $params=@{Root=$Root;Connection=$first.Connection;Name=$first.Name;SourceJobIds=@($group.Group|ForEach-Object {$_.Job.JobId})};if($match){$params.Id=$match.LocalRecordId}
  $results+=Set-TCServerRecord @params;$count++
 }
 return [pscustomobject]@{Imported=$count;Servers=$results;Message='历史记录已登记，服务器身份和管理权限仍需登录核验。'}
}
Export-ModuleMember -Function Get-TCServers,Get-TCServer,Set-TCServerRecord,Set-TCServerLink,Import-TCLegacyServerIndex,Import-TCServerRecoveryRecord
