#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ServerRegistry.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'DeploymentTransport.psm1') -DisableNameChecking
function Get-TCDeploymentRunPath {param([string]$Root,[string]$RunId) return Join-Path (Join-Path (Get-TCDPath $Root deployments) 'runs') (Assert-TCDId $RunId)}
function Get-TCDeploymentRun {param([string]$Root,[string]$RunId)
 $run=Read-TCDJson (Join-Path (Get-TCDeploymentRunPath $Root $RunId) 'state.json')
 if($run.SchemaVersion -ne 1 -or $run.RunId -cne (Assert-TCDId $RunId)){throw '[TC:RunMismatch] 部署运行记录不匹配。'}
 foreach($item in @(@{Name='DispatchIntent';Value=$null},@{Name='LastRemoteMutation';Value=$null},@{Name='CandidateTransaction';Value=$null},@{Name='ProviderWarnings';Value=@()},@{Name='RequiredProviderIds';Value=@()},@{Name='AddressSelectionEvidence';Value=$null})){
  if(-not $run.PSObject.Properties[$item.Name]){$run|Add-Member NoteProperty $item.Name $item.Value}
 }
 return $run
}
function Save-TCDeploymentRun {param([string]$Root,$Run)
 $Run.Revision=[int]$Run.Revision+1;$Run.UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')
 Write-TCDJson (Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'state.json') $Run
 return $Run
}
function Get-TCDeploymentRuns {param([string]$Root)
 $base=Join-Path (Get-TCDPath $Root deployments) 'runs';if(-not [IO.Directory]::Exists($base)){return @()}
 return @(Get-ChildItem -LiteralPath $base -Directory|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 2000|ForEach-Object {try{Get-TCDeploymentRun $Root $_.Name}catch{}}|Sort-Object UpdatedAtUtc -Descending|Select-Object -First 200)
}
function Get-TCDeploymentDiscovery {param([string]$Root)
 $runs=@(Get-TCDeploymentRuns $Root);$servers=@(Get-TCServers $Root);$legacy=Join-Path (Assert-TCDPath $Root) 'linux-jobs'
 [pscustomobject]@{Servers=$servers;Runs=$runs;ContinueRuns=@($runs|Where-Object {$_.Status -notin @('Complete','Cancelled')});HasLegacyRecords=[IO.Directory]::Exists($legacy);NetworkChanged=$false}
}
function ConvertTo-TCDeploymentConnection {param([string]$Text,[string]$User='root',[int]$Port=22,[string]$IdentityFile='')
 $value=$Text.Trim()
 if($value -match '[;&|<>$]' -or $value.Contains([char]96) -or $value -match '[\r\n]'){throw '[TC:ConnectionInvalid] 只粘贴接入地址，不接受执行命令。'}
 if($value -match '^ssh\s+(?<user>[a-z_][a-z0-9_-]{0,31})@(?<host>(?:\d{1,3}\.){3}\d{1,3})(?:\s+-p\s+(?<port>\d{1,5}))?$'){$User=$Matches.user;$value=$Matches.host;if($Matches.port){$Port=[int]$Matches.port}}
 elseif($value -match '^(?<user>[a-z_][a-z0-9_-]{0,31})@(?<host>(?:\d{1,3}\.){3}\d{1,3})$'){$User=$Matches.user;$value=$Matches.host}
 $ip=$null;if($value -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or -not [Net.IPAddress]::TryParse($value,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $Port -lt 1 -or $Port -gt 65535 -or $User -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$'){throw '[TC:ConnectionInvalid] 请填写完整公网 IPv4、SSH 用户名和端口。'}
 return [pscustomobject]@{Host=$ip.ToString();Port=$Port;User=$User;IdentityFile=$IdentityFile}
}
function New-TCDeploymentRun {
 [CmdletBinding()]param([string]$Root,[ValidateSet('New','Add','Existing')][string]$Intent='New',[string]$ServerId,$Connection,[string]$Name='新的服务器线路',[string]$TemplateNodeId,[string]$Transport='Udp',[int]$TcpPort=443,[string]$ServerName='www.bing.com',[int]$VpnPort=51820,$ClientInspection)
 if($Transport -notin @('Auto','Udp','Tcp') -or $VpnPort -lt 1 -or $VpnPort -gt 65535 -or $TcpPort -lt 1 -or $TcpPort -gt 65535){throw '[TC:SettingsInvalid] 连接参数无效。'}
 if($ServerName -cnotmatch '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'){throw '[TC:SettingsInvalid] TLS 域名无效。'}
 if($ServerId){$server=Get-TCServer $Root $ServerId}else{$server=Set-TCServerRecord -Root $Root -Connection $Connection -Name $Name}
 if(-not $server.Connection){throw '[TC:AccessRequired] 此记录只有连接使用权；请使用邀请接入，或提供管理资料。'}
 $id=[guid]::NewGuid().ToString('D');$dir=Get-TCDeploymentRunPath $Root $id;$null=New-TCDDirectory $dir
 $programs=@(Get-TCDField $ClientInspection NinjaTraderPaths @());$dns=@(Get-TCDField $ClientInspection DirectDnsIPv4 @())|Select-Object -First 1
 $run=[pscustomobject][ordered]@{SchemaVersion=1;RunId=$id;Revision=0;Intent=$Intent;ServerRecordId=$server.LocalRecordId;Name=$Name;TemplateNodeId=$TemplateNodeId;Transport=$Transport;TcpPort=$TcpPort;ServerName=$ServerName;VpnPort=$VpnPort;TunnelSubnet=$null;Programs=$programs;DirectDns=$dns;Stage='PrepareAccess';Status='WaitingUser';SessionRef=$null;PendingOperationId=$null;PendingPurpose=$null;ClientRequest=$null;RequestDirectory=$null;Plan=$null;ManagementPlan=$null;Review=$null;ApprovedChangeDigest=$null;AllowManagementInitialize=$false;AllowDeviceAuthorize=$false;ClientResponse=$null;ServerInfo=$null;CandidateNodeId=$null;CandidateManifestPath=$null;ExpectedExitIPv4=$null;ExpectedExitSource=$null;Validation=$null;LastError=$null;UserActions=@('连接并检查');CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');NetworkChanged=$false}
 foreach($item in @(@{Name='DispatchIntent';Value=$null},@{Name='LastRemoteMutation';Value=$null},@{Name='CandidateTransaction';Value=$null},@{Name='ProviderWarnings';Value=@()},@{Name='RequiredProviderIds';Value=@()},@{Name='AddressSelectionEvidence';Value=$null})){$run|Add-Member NoteProperty $item.Name $item.Value}
 return Save-TCDeploymentRun $Root $run
}
function Set-TCDeploymentSession {param([string]$Root,[string]$RunId,$SessionRef)
 if([string](Get-TCDField $SessionRef RunId '') -cne $RunId){throw '[TC:SessionMismatch] 会话属于另一项部署。'}
 $run=Get-TCDeploymentRun $Root $RunId;$run.SessionRef=$SessionRef;$run.LastError=$null
 if($run.Status -in @('OutcomeUnknown','NeedsRecovery') -or ($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched'))){$run.Stage='Reconcile'}
 elseif($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'){$run.Stage='MaterializeCandidate'}
 elseif($run.ClientResponse){$run.Stage='ServerInfo'}
 elseif($run.Stage -ne 'PlanReady'){$run.Stage='Inspect'}
 if($run.Stage -ne 'Reconcile'){$run.PendingOperationId=$null;$run.PendingPurpose=$null}
 $run.Status='Idle';return Save-TCDeploymentRun $Root $run
}
function Initialize-TCDeploymentRequest {param([string]$Root,$Run)
 if($Run.ClientRequest){
  $state=Read-TCDJson (Join-Path $Run.RequestDirectory 'public.request.json')
  if((Get-TCDDigest $state) -cne (Get-TCDDigest $Run.ClientRequest) -or -not [IO.File]::Exists((Join-Path $Run.RequestDirectory 'client.key'))){throw '[TC:PrivateKeyMissing] 原申请或私钥缺失，请通过新身份申请处理，未重复授权。'}
  return
 }
 $client=Join-Path (Get-TCDeploymentRunPath $Root $Run.RunId) 'client'
 Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -DisableNameChecking
 if([IO.Directory]::Exists($client) -and @(Get-ChildItem -LiteralPath $client -Force).Count){
  foreach($leaf in @('public.request.json','client.state.json','client.key')){if(-not [IO.File]::Exists((Join-Path $client $leaf))){throw '[TC:LocalRequestIncomplete] 本机申请创建曾中断，唯一私钥仍保留；请处理原申请资料，未生成新设备。'}}
  $savedRequest=Read-TCDJson (Join-Path $client 'public.request.json');$savedState=Read-TCDJson (Join-Path $client 'client.state.json');$keyPath=Assert-TCDPath (Join-Path $client 'client.key')
  if((Get-Item -LiteralPath $keyPath).Length -gt 256){throw '[TC:PrivateKeyMissing] 原申请私钥资料超限。'}
  $keyText=[IO.File]::ReadAllText($keyPath).Trim();$serverModule=Get-Module ServerSetup;$keyHash=& $serverModule {param($Key) Assert-TCKey $Key;Get-TCHash $Key} $keyText;$keyText=$null
  if($savedRequest.Kind -cne 'TradeChannel.ClientRequest' -or $savedState.Kind -cne 'TradeChannel.ClientPrivateState' -or $savedRequest.RequestId -cne $savedState.RequestId -or $savedRequest.DeviceId -cne $savedState.DeviceId -or $savedRequest.ClientPublicKey -cne $savedState.ClientPublicKey -or $keyHash -cne $savedState.PrivateKeyHash){throw '[TC:PrivateKeyMissing] 原申请与私钥记录不匹配，请处理原身份。'}
 }else{$null=New-TCClientRequest -OutputDirectory $client -WgPath (Join-Path $PSScriptRoot 'assets\wg.exe')}
 $Run.ClientRequest=Read-TCDJson (Join-Path $client 'public.request.json');$Run.RequestDirectory=$client
}
function Start-TCDeploymentRemote {param([string]$Root,$Run,[string]$Operation,[string]$Purpose,$InputData=@{})
 if(-not $Run.SessionRef){throw '[TC:AuthenticationRequired] 请在程序内登录服务器。'}
 $mutating=$Operation -in @('apply','authorize','recover','finalize','management_apply','device_rename','invite_create','invite_cancel','authorize_external','revoke','uninstall','transport_apply') -or ($Operation -eq 'request_status' -and (Get-TCDField $InputData RefreshAuthorization $false))
 $intent=[pscustomobject]@{IntentId=[guid]::NewGuid().ToString();Operation=$Operation;Purpose=$Purpose;InputDigest=(Get-TCDDigest $InputData);State='Prepared';Mutating=$mutating;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
 $Run.DispatchIntent=$intent;$Run.PendingOperationId=$intent.IntentId;$Run.PendingPurpose=$Purpose;$Run.Status='Dispatching';$Run.Stage=$Purpose;$Run.LastError=$null;$Run.UserActions=@()
 if($mutating){$Run.LastRemoteMutation=$intent}
 # Publish durable intent before anything can execute remotely. The same operation ID is sent over the pipe.
 $null=Save-TCDeploymentRun $Root $Run
 try{$response=Invoke-TCDeployOperation -SessionRef $Run.SessionRef -Operation $Operation -Input $InputData -OperationId $intent.IntentId}catch{
  $Run.Status=if($mutating){'OutcomeUnknown'}else{'Failed'};$Run.LastError=[pscustomobject]@{Code='DispatchOutcomeUnknown';Message='执行器未返回接收结果，请查询原操作，不自动重新提交。'};$Run.UserActions=@('重新登录并检查原操作');$null=Save-TCDeploymentRun $Root $Run;throw '[TC:DispatchOutcomeUnknown] 请查询原操作结果后继续。'
 }
 if(-not (Get-TCDField $response Ok $false)){$intent.State='Rejected';$Run.Status='Failed';$Run.LastError=[pscustomobject]@{Code=[string](Get-TCDField $response Code 'RemoteRejected');Message='执行器未接受此操作，请保留原申请并处理提示。'};$null=Save-TCDeploymentRun $Root $Run;throw '[TC:RemoteRejected] 远程操作未接受。'}
 if([string](Get-TCDField $response OperationId '') -cne $intent.IntentId){$Run.Status=if($mutating){'OutcomeUnknown'}else{'Failed'};$null=Save-TCDeploymentRun $Root $Run;throw '[TC:OperationMismatch] 执行器未返回原操作标识。'}
 $intent.State='Dispatched';$Run.Status='Running'
}
function Set-TCDeploymentReview {param([string]$Root,$Run,[string]$Kind,$Plan,[string]$Title,[string]$Details)
 $server=Get-TCServer $Root $Run.ServerRecordId;$access=$null;if($server.Connection){$access=@{Host=$server.Connection.Host;Port=$server.Connection.Port;User=$server.Connection.User}}
 $identity=@{RemoteOwnerId=$server.RemoteOwnerId;NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey;PinnedHostKey=$server.PinnedHostKey;Connection=$access}
 $review=[ordered]@{Kind=$Kind;ServerRecordId=$Run.ServerRecordId;TargetIdentity=$identity;ServerBinding=$Run.ServerInfo;Plan=$Plan;ClientPublicKey=(Get-TCDField $Run.ClientRequest ClientPublicKey);Title=$Title;Details=$Details;IncludesManagementInitialize=$true;IncludesLocalDeviceAuthorize=$true;ChangesLocalNetwork=$false}
 $review.ChangeDigest=Get-TCDDigest $review;$Run.Review=[pscustomobject]$review;$Run.Stage='PlanReady';$Run.Status='WaitingUser';$Run.UserActions=@('核对变更并开始','稍后继续')
}
function ConvertTo-TCDeploymentRange {param([string]$Cidr)
 if($Cidr -cnotmatch '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})/(\d{1,2})$'){return $null};$ip=$null;$prefix=[int]$Matches[2]
 if($prefix -lt 1 -or $prefix -gt 32 -or -not [Net.IPAddress]::TryParse($Matches[1],[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){return $null}
 $parts=$ip.GetAddressBytes();if($parts[0] -eq 127 -or ($parts[0] -eq 169 -and $parts[1] -eq 254) -or $parts[0] -ge 224){return $null}
 [uint64]$number=0;foreach($part in $parts){$number=$number*256+$part};[uint64]$size=[math]::Pow(2,32-$prefix);[uint64]$start=$number-($number%$size)
 [pscustomobject]@{Start=$start;End=$start+$size-1;Cidr=$Cidr}
}
function Get-TCDeploymentLocalNetworks {
 # Read-only. A failed query cannot be treated as proof that no local network exists.
 $ranges=@();try{
  foreach($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)){$cidr=[string]$route.DestinationPrefix;if($cidr -ne '0.0.0.0/0'){$ranges+=$cidr}}
  foreach($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)){$ranges+=([string]$address.IPAddress+'/'+[string]$address.PrefixLength)}
 }catch{throw '[TC:LocalNetworkUnknown] 无法读取本机现有网段，请先处理系统查询权限；未猜测可用网段。'}
 return @($ranges|Select-Object -Unique)
}
function Select-TCDeploymentSubnet {param([string]$Root,$Run,$Inspection)
 $excluded=@(Get-TCDeploymentLocalNetworks)+@(Get-TCDField $Inspection ConflictNetworks @())
 Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
 foreach($node in @(Get-TCNodes -Root (Join-Path $Root 'Product'))){if($node.manifestPath){
  $m=Read-TCDJson $node.manifestPath
  foreach($field in @('TunnelSubnet','ServerAddress')){$sub=[string](Get-TCDField $m $field '');if($sub){$excluded+=$sub}}
  $client=[string](Get-TCDField $m ClientAddress '');if($client){$excluded+=($client+$(if($client.Contains('/')){''}else{'/32'}))}
 }}
 $ranges=@($excluded|Select-Object -Unique|ForEach-Object {ConvertTo-TCDeploymentRange ([string]$_)}|Where-Object {$null -ne $_})
 $candidates=@(foreach($index in 78..240){'10.'+$index+'.0.0/24'})+@(foreach($index in 20..29){foreach($part in 0..15){'172.'+$index+'.'+$part+'.0/24'}})
 foreach($candidate in $candidates){$range=ConvertTo-TCDeploymentRange $candidate;$overlap=@($ranges|Where-Object {$range.Start -le $_.End -and $_.Start -le $range.End});if(-not $overlap.Count){
  $Run.AddressSelectionEvidence=[pscustomobject]@{Selected=$candidate;CheckedAtUtc=[DateTime]::UtcNow.ToString('o');ExcludedNetworks=@($ranges|ForEach-Object {$_.Cidr});DefaultRouteExcluded=$true;NetworkChanged=$false};return $candidate
 }}
 throw '[TC:AddressConflict] 没有已知无冲突网段，请在高级设置检查现有地址。'
}
function Complete-TCDeploymentCandidate {param([string]$Root,$Run,[switch]$UseExistingConfig,[string]$SourceConfigPath)
 if(-not $Run.ClientResponse){throw '[TC:AuthorizationMissing] 尚未取得本机授权。'}
 if(-not $UseExistingConfig){Initialize-TCDeploymentRequest $Root $Run}
 $dir=Get-TCDeploymentRunPath $Root $Run.RunId;$responsePath=Join-Path $dir 'client-response.json';Write-TCDJson $responsePath $Run.ClientResponse
 $destination=if($UseExistingConfig){Assert-TCDPath $SourceConfigPath}else{Join-Path $dir 'client.conf'}
 if($UseExistingConfig -and -not [IO.File]::Exists($destination)){throw '[TC:ConfigMissing] 接收端授权合成资料缺失，未重新申请。'}
 Import-Module (Join-Path $PSScriptRoot 'ServerSetup.psm1') -DisableNameChecking
 if(-not $UseExistingConfig -and -not [IO.File]::Exists($destination)){$null=Complete-TCClientConfig -RequestDirectory $Run.RequestDirectory -ResponsePath $responsePath -Destination $destination}
 Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -DisableNameChecking
 $programs=@($Run.Programs|Where-Object {[IO.File]::Exists([string]$_)});$providers=@();$warnings=@();$sourceProviders=$null
 foreach($path in @($Run.Programs)){if(-not [IO.File]::Exists([string]$path)){$warnings+='程序路径暂不可用，已跳过：'+[string]$path}}
 if(-not $Run.DirectDns){$Run.DirectDns='1.1.1.1'}
 if($Run.TemplateNodeId){
  $source=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object {$_.id -eq $Run.TemplateNodeId})|Select-Object -First 1
  if($source -and $source.manifestPath){
   $manifest=Read-TCDJson $source.manifestPath
   $originalPrograms=@(Get-TCDField $manifest TradeProgramPaths $programs);$programs=@($originalPrograms|Where-Object {[IO.File]::Exists([string]$_)})
   foreach($path in $originalPrograms){if(-not [IO.File]::Exists([string]$path)){$warnings+='模板程序已不存在，已跳过：'+[string]$path}}
   if(Get-TCDField $manifest DirectDns){$Run.DirectDns=[string]$manifest.DirectDns}
   $sourceProviders=@(Get-TCDField $manifest Providers @()|ForEach-Object {[string](Get-TCDField $_ Id '')}|Where-Object {$_})
  }else{throw '[TC:TemplateMissing] 选择的来源线路已不存在，未改用其他线路设置。'}
 }
 Import-Module (Join-Path $PSScriptRoot 'ProviderBridge.psm1') -DisableNameChecking
 # A malformed provider store is a real error; only explicitly unavailable profiles may be skipped.
 $selection=Select-TCImportProviders -Root $Root -Programs $programs -SkipUnavailable
 $providers=@($selection.Providers);$warnings+=@($selection.Warnings)
 if($null -ne $sourceProviders){$providers=@($providers|Where-Object {[string](Get-TCDField $_ Id '') -in $sourceProviders});foreach($providerId in $sourceProviders){if($providerId -notin @($providers|ForEach-Object {[string](Get-TCDField $_ Id '')})){$warnings+='模板服务商未纳入候选，请刷新对应档案：'+$providerId}}}
 foreach($required in @($Run.RequiredProviderIds)){if($required -notin @($providers|ForEach-Object {[string](Get-TCDField $_ Id '')})){$Run.ProviderWarnings=@($warnings);$null=Save-TCDeploymentRun $Root $Run;throw '[TC:RequiredProviderUnavailable] 目标连接依赖的服务商不可用，请先修复对应档案。'}}
 $Run.ProviderWarnings=@($warnings|Select-Object -Unique)
 $nodes=@(Get-TCNodes -Root (Join-Path $Root 'Product'));$configHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
 if(-not $Run.CandidateTransaction){
  $Run.CandidateTransaction=[pscustomobject]@{State='Prepared';RequestId=$Run.ClientRequest.RequestId;ConfigHash=$configHash;BeforeNodeIds=@($nodes|ForEach-Object {$_.id});NodeId=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o')}
  $Run.Stage='MaterializeCandidate';$null=Save-TCDeploymentRun $Root $Run
 }elseif($Run.CandidateTransaction.RequestId -cne $Run.ClientRequest.RequestId -or $Run.CandidateTransaction.ConfigHash -cne $configHash){throw '[TC:CandidateTransactionMismatch] 原候选准备资料发生变化，请保留记录并核对。'}
 if(-not $Run.CandidateNodeId){
  # Reconcile a crash after node import and before publishing its ID to the run.
  $matches=@(foreach($node in $nodes){if($node.id -in @($Run.CandidateTransaction.BeforeNodeIds)){continue};$manifest=Read-TCDJson $node.manifestPath;if([string](Get-TCDField $manifest ExportSHA256 '') -ceq $configHash -and $manifest.ClientPublicKey -ceq $Run.ClientRequest.ClientPublicKey -and $manifest.ServerPublicKey -ceq $Run.ClientResponse.ServerPublicKey){$node}})
  if($matches.Count -gt 1){throw '[TC:CandidateAmbiguous] 发现多个相同申请候选，请核对记录；未新增线路。'}
  if($matches.Count -eq 1){$Run.CandidateNodeId=$matches[0].id;$Run.CandidateManifestPath=$matches[0].manifestPath}
  else{$imported=Import-TCWireGuard -Root (Join-Path $Root 'Product') -Path $destination -Name $Run.Name -EnginePath (Join-Path $PSScriptRoot 'assets\sing-box.exe') -WgPath (Join-Path $PSScriptRoot 'assets\wg.exe') -TradeProgramPaths $programs -DirectDnsIPv4 ([string]$Run.DirectDns) -Providers $providers;$Run.CandidateNodeId=$imported.Id;$Run.CandidateManifestPath=$imported.ManifestPath}
  $Run.CandidateTransaction.NodeId=$Run.CandidateNodeId;$Run.CandidateTransaction.State='Imported';$null=Save-TCDeploymentRun $Root $Run
 }
 $existing=@(Get-TCNodes -Root (Join-Path $Root 'Product')|Where-Object {$_.id -eq $Run.CandidateNodeId});if($existing.Count -ne 1){throw '[TC:CandidateMissing] 原候选记录缺失，未重复生成线路。'}
 $Run.CandidateManifestPath=$existing[0].manifestPath;$candidate=Read-TCDJson $Run.CandidateManifestPath
 if($Run.ClientResponse.PSObject.Properties['Transport'] -and (Get-TCDDigest (Get-TCDField $candidate Transport)) -cne (Get-TCDDigest $Run.ClientResponse.Transport)){
  $Run.CandidateTransaction.State='PreparingTransport';$Run.Stage='MaterializeCandidate';$null=Save-TCDeploymentRun $Root $Run
  $parameters=@{};foreach($property in $Run.ClientResponse.Transport.PSObject.Properties){$parameters[$property.Name]=$property.Value}
  $tcp=Set-TCTransportMode -Root (Join-Path $Root 'Product') -Id $Run.CandidateNodeId -Mode Tcp -TransportParams $parameters;$Run.CandidateManifestPath=$tcp.ManifestPath
  $Run.CandidateTransaction.State='TransportPrepared';$null=Save-TCDeploymentRun $Root $Run
 }
 $null=Set-TCServerLink -Root $Root -ServerId $Run.ServerRecordId -NodeId $Run.CandidateNodeId -ObservedExitIPv4 $Run.ExpectedExitIPv4 -EvidenceSource $Run.ExpectedExitSource
 $Run.CandidateTransaction.State='Completed';$Run.Stage='ReadyInactive';$Run.Status='WaitingUser';$Run.UserActions=@('独立验证候选','稍后启用','导出管理恢复资料');$Run.NetworkChanged=$false
}
function Complete-TCPairCandidate {
 [CmdletBinding()]param([string]$Root,[Parameter(Mandatory=$true)][string]$EnrollmentId,[string]$EncryptedAuthorization,[string]$Name='邀请接入的服务器')
 Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking
 $run=$null;$runId=Assert-TCDId $EnrollmentId;$dir=Get-TCDeploymentRunPath $Root $runId;$null=New-TCDDirectory $dir;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
 try{
  $completed=if($EncryptedAuthorization){Complete-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId -EncryptedAuthorization $EncryptedAuthorization}else{Resume-TCPairAuthorization -Root $Root -EnrollmentId $EnrollmentId}
  $enrollment=Get-TCPairEnrollment -Root $Root -EnrollmentId $EnrollmentId;$response=Read-TCDJson $completed.ResponsePath
  $info=@{RemoteOwnerId=$enrollment.ServerBinding.RemoteOwnerId;Node=@{NodeId=$response.NodeId;ServerPublicKey=$response.ServerPublicKey;PublicEndpoint=$response.PublicEndpoint};ManagementSigningPublicKey=$enrollment.ManagementSigningPublicKey;ManagementApiVersion=2;OwnershipState='InvitationPinned'}
  $server=Set-TCServerRecord -Root $Root -ServerInfo $info -Name $Name -ConnectorOnly
  $statePath=Join-Path $dir 'state.json'
  if([IO.File]::Exists($statePath)){
   $run=Get-TCDeploymentRun $Root $runId
   if($run.Intent -cne 'Pairing' -or $run.ServerRecordId -cne $server.LocalRecordId -or $run.ClientRequest.RequestId -cne $enrollment.ClientRequest.RequestId){throw '[TC:EnrollmentRunMismatch] 此接入申请已经绑定到另一项运行记录。'}
   $run.ClientResponse=$response
  }else{
   $run=[pscustomobject][ordered]@{SchemaVersion=1;RunId=$runId;Revision=0;Intent='Pairing';ServerRecordId=$server.LocalRecordId;Name=$Name;TemplateNodeId=$null;Transport=$(if($response.PSObject.Properties['Transport']){'Tcp'}else{'Udp'});Programs=@();DirectDns='1.1.1.1';Stage='MaterializeCandidate';Status='Idle';SessionRef=$null;PendingOperationId=$null;PendingPurpose=$null;ClientRequest=$enrollment.ClientRequest;RequestDirectory=$completed.RequestDirectory;ClientResponse=$response;CandidateNodeId=$null;CandidateManifestPath=$null;ExpectedExitIPv4=$null;ExpectedExitSource=$null;Validation=$null;LastError=$null;UserActions=@();DispatchIntent=$null;LastRemoteMutation=$null;CandidateTransaction=$null;ProviderWarnings=@();RequiredProviderIds=@();AddressSelectionEvidence=$null;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');UpdatedAtUtc=[DateTime]::UtcNow.ToString('o');NetworkChanged=$false}
   foreach($field in @(@{Name='TcpPort';Value=443},@{Name='ServerName';Value='www.bing.com'},@{Name='VpnPort';Value=51820},@{Name='TunnelSubnet';Value=$response.TunnelSubnet},@{Name='Plan';Value=$null},@{Name='ManagementPlan';Value=$null},@{Name='Review';Value=$null},@{Name='ApprovedChangeDigest';Value=$null},@{Name='AllowManagementInitialize';Value=$false},@{Name='AllowDeviceAuthorize';Value=$false},@{Name='ServerInfo';Value=$info})){$run|Add-Member NoteProperty $field.Name $field.Value}
   $null=Save-TCDeploymentRun $Root $run
  }
  Complete-TCDeploymentCandidate -Root $Root -Run $run -UseExistingConfig -SourceConfigPath $completed.ConfigPath
  $null=Save-TCDeploymentRun $Root $run
  [pscustomobject]@{Status='ReadyInactive';Id=$run.CandidateNodeId;NodeId=$run.CandidateNodeId;ManifestPath=$run.CandidateManifestPath;ServerRecordId=$server.LocalRecordId;EnrollmentId=$EnrollmentId;RunId=$run.RunId;ConfigPath=$completed.ConfigPath;ProviderWarnings=$run.ProviderWarnings;NetworkChanged=$false}
 }catch{
  if($run){$run.Status='Failed';$run.Stage='MaterializeCandidate';$run.LastError=[pscustomobject]@{Code='PairCandidateFailed';Message='候选尚未完成，原授权和事务已保留；重新提交相同返回可继续。'};$null=Save-TCDeploymentRun $Root $run};throw
 }finally{$lock.Dispose()}
}
function Invoke-TCDeploymentAdvance {
 [CmdletBinding()]param([string]$Root,[string]$RunId,[ValidateSet('Continue','Approve','Cancel','Recheck','Probe')][string]$Command='Continue',[string]$ApprovedChangeDigest)
 $dir=Get-TCDeploymentRunPath $Root $RunId;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
 try{
  $run=Get-TCDeploymentRun $Root $RunId
  if($Command -eq 'Cancel'){
   if($run.SessionRef){try{$null=Stop-TCDeploySession -SessionRef $run.SessionRef -Cancel}catch{}}
   if($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched')){$run.Status='OutcomeUnknown';$run.Stage='Reconcile'}else{$run.Status='Cancelled'}
   $run.UserActions=@('检查服务器实际结果');return Save-TCDeploymentRun $Root $run
  }
  if($run.Status -in @('Running','Dispatching')){return $run}
  if($Command -eq 'Probe'){
   if(-not $run.CandidateNodeId){throw '[TC:CandidateMissing] 请先准备候选线路。'}
   Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking
   $run.Validation=Test-TCCandidateProbe -Root $Root -NodeId $run.CandidateNodeId -ExpectedExitIPv4 $run.ExpectedExitIPv4 -ExpectedExitSource $run.ExpectedExitSource
   $run.Stage='ReadyInactive';$run.Status='WaitingUser';return Save-TCDeploymentRun $Root $run
  }
  if($Command -eq 'Approve'){
   if($run.Stage -ne 'PlanReady' -or -not $run.Review -or $ApprovedChangeDigest -cne $run.Review.ChangeDigest){throw '[TC:ApprovalMismatch] 变更确认与当前预览不匹配，请重新核对。'}
   $server=Get-TCServer $Root $run.ServerRecordId;$access=$null;if($server.Connection){$access=@{Host=$server.Connection.Host;Port=$server.Connection.Port;User=$server.Connection.User}}
   $identity=@{RemoteOwnerId=$server.RemoteOwnerId;NodeId=$server.NodeId;ServerPublicKey=$server.ServerPublicKey;PinnedHostKey=$server.PinnedHostKey;Connection=$access}
   if(-not (Get-TCDField $run.Review TargetIdentity) -or (Get-TCDDigest $identity) -cne (Get-TCDDigest $run.Review.TargetIdentity)){throw '[TC:ApprovalTargetChanged] 目标身份或接入资料在预览后发生变化，请重新检查并核对计划。'}
   $run.ApprovedChangeDigest=$ApprovedChangeDigest;$run.AllowManagementInitialize=$true;$run.AllowDeviceAuthorize=$true
   switch($run.Review.Kind){
    'Deploy'{
     if([DateTimeOffset]$run.Plan.PlanExpiresAt -le [DateTimeOffset]::UtcNow){$run.AllowManagementInitialize=$false;$run.AllowDeviceAuthorize=$false;$run.Stage='Inspect';$run.Status='Idle';Start-TCDeploymentRemote $Root $run inspect Inspect @{}}
     else{Start-TCDeploymentRemote $Root $run apply Apply @{PlanId=$run.Plan.PlanId}}
    }
    'Management'{Start-TCDeploymentRemote $Root $run management_apply ManagementApply @{PlanId=$run.ManagementPlan.PlanId;ApprovedChangeDigest=$run.ManagementPlan.ChangeDigest}}
    'Authorize'{Start-TCDeploymentRemote $Root $run authorize Authorize @{ClientRequest=$run.ClientRequest}}
    default{throw '[TC:ApprovalMismatch] 不支持此变更类型。'}
   }
   return Save-TCDeploymentRun $Root $run
  }
  if($run.Stage -eq 'ReadyInactive'){return $run}
  if($run.Status -in @('OutcomeUnknown','NeedsRecovery') -or $run.Stage -eq 'Reconcile'){
   Start-TCDeploymentRemote $Root $run status Reconcile @{};return Save-TCDeploymentRun $Root $run
  }
  if($run.Intent -eq 'Pairing' -and ($run.Stage -eq 'MaterializeCandidate' -or ($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'))){
   Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -DisableNameChecking
   $completed=Resume-TCPairAuthorization -Root $Root -EnrollmentId $run.RunId;$run.ClientResponse=Read-TCDJson $completed.ResponsePath
   Complete-TCDeploymentCandidate -Root $Root -Run $run -UseExistingConfig -SourceConfigPath $completed.ConfigPath;return Save-TCDeploymentRun $Root $run
  }
  if($run.CandidateTransaction -and $run.CandidateTransaction.State -ne 'Completed'){$run.Stage='MaterializeCandidate';Complete-TCDeploymentCandidate $Root $run;return Save-TCDeploymentRun $Root $run}
  if($run.ClientResponse -or $run.Stage -eq 'ServerInfo'){Start-TCDeploymentRemote $Root $run server_info ServerInfo @{};return Save-TCDeploymentRun $Root $run}
  if($run.Stage -in @('PrepareAccess','Inspect') -or $Command -eq 'Recheck'){Start-TCDeploymentRemote $Root $run inspect Inspect @{};return Save-TCDeploymentRun $Root $run}
  throw '[TC:StageMismatch] 请先完成当前阶段显示的操作。'
 }finally{$lock.Dispose()}
}
function Sync-TCDeploymentRun {
 [CmdletBinding()]param([string]$Root,[string]$RunId)
 $dir=Get-TCDeploymentRunPath $Root $RunId;$lock=Open-TCDLock (Join-Path $dir '.run.lock')
 try{
  $run=Get-TCDeploymentRun $Root $RunId
  if($run.Status -notin @('Running','Dispatching') -or -not $run.SessionRef){return $run}
  $poll=Get-TCDeploySession -SessionRef $run.SessionRef
  if($poll.Status -in @('Running','Connecting','AwaitingCredential','HostTrustRequired')){return $run}
  if($poll.OperationId -and $poll.OperationId -cne $run.PendingOperationId){
   if($run.Status -eq 'Dispatching'){$run.Status=if($run.DispatchIntent.Mutating){'OutcomeUnknown'}else{'Failed'};$run.Stage='Reconcile';return Save-TCDeploymentRun $Root $run}
   throw '[TC:OperationMismatch] 执行器结果不是当前操作。'
  }
  if($poll.Status -ne 'Completed'){
   $run.Status=if($poll.Status -eq 'OutcomeUnknown' -or ($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched'))){'OutcomeUnknown'}else{'Failed'}
   $run.LastError=[pscustomobject]@{Code=(Get-TCDField $poll Code 'RemoteFailed');Message=(Get-TCDField $poll Message '远程操作未完成，请核对实际结果。')};$run.UserActions=@('重新登录并检查结果');return Save-TCDeploymentRun $Root $run
  }
  $data=$poll.Data
  if($data -and (Get-TCDField $data Ok $null) -is [bool]){if(-not $data.Ok){throw '[TC:RemoteFailed] 服务器拒绝了操作。'};$data=$data.Data}
  $purpose=$run.PendingPurpose;if($run.DispatchIntent){$run.DispatchIntent.State='Completed';if($run.DispatchIntent.Mutating){$run.LastRemoteMutation=$run.DispatchIntent}};$run.PendingOperationId=$null;$run.PendingPurpose=$null;$run.Status='Idle'
  switch($purpose){
   'Inspect'{
    if(-not $data.Supported){
     $run.Status='Failed';$run.LastError=[pscustomobject]@{Code='PreflightRejected';Message=$data.Summary;Issues=$data.Issues};$run.UserActions=@('按检查结果处理','导入已有连接');break
    }
    Initialize-TCDeploymentRequest $Root $run
    if($data.AlreadyDeployed -or $data.OwnedDeployment){Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
    else{
     if(-not $run.TunnelSubnet){$run.TunnelSubnet=Select-TCDeploymentSubnet $Root $run $data}
     $server=Get-TCServer $Root $run.ServerRecordId
     $inputData=@{Name=$run.Name;PublicEndpoint=($server.Connection.Host+':'+$run.VpnPort);TunnelSubnet=$run.TunnelSubnet;ClientRequest=$run.ClientRequest}
     if($run.Transport -eq 'Tcp'){$inputData.Transport=@{Type='tcp-reality';Port=$run.TcpPort;ServerName=$run.ServerName}}
     Start-TCDeploymentRemote $Root $run plan Plan $inputData
    }
   }
   'Plan'{$run.Plan=$data;Set-TCDeploymentReview $Root $run Deploy $data '部署这台服务器并授权本机' '安装本次计划服务、首台设备授权，并初始化管理记录与邀请身份；云端端口按下方清单处理。本机网络不会切换。'}
   'Apply'{$run.ClientResponse=$data.ClientResponse;Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
   'ServerInfo'{
    $run.ServerInfo=$data;$null=Set-TCServerRecord -Root $Root -Id $run.ServerRecordId -ServerInfo $data
    if(-not (Get-TCDField $data ManagementSigningPublicKey)){
     Start-TCDeploymentRemote $Root $run management_plan ManagementPlan @{}
    }elseif($run.ClientResponse){Start-TCDeploymentRemote $Root $run status ServerExit @{NetworkProbe=$true}}
    elseif($run.AllowDeviceAuthorize){Start-TCDeploymentRemote $Root $run authorize Authorize @{ClientRequest=$run.ClientRequest}}
    else{Set-TCDeploymentReview $Root $run Authorize @{ClientPublicKey=$run.ClientRequest.ClientPublicKey;Node=$data.Node} '为这台电脑生成独立授权' '不重建服务器，保留其他设备。本机将生成候选线路，尚不切换网络。'}
   }
   'ManagementPlan'{
    $run.ManagementPlan=$data
    if($run.AllowManagementInitialize){Start-TCDeploymentRemote $Root $run management_apply ManagementApply @{PlanId=$data.PlanId;ApprovedChangeDigest=$data.ChangeDigest}}
    else{Set-TCDeploymentReview $Root $run Management $data '补齐管理能力并授权本机' '只新增管理记录与签名身份，保留隧道和现有设备；随后为这台电脑生成独立授权。'}
   }
   'ManagementApply'{Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
   'Authorize'{$run.ClientResponse=$data.ClientResponse;Start-TCDeploymentRemote $Root $run status ServerExit @{NetworkProbe=$true}}
   'ServerExit'{
    $probe=Get-TCDField $data NetworkProbe;$rows=@(Get-TCDField $probe ServerHttps @())
    $verified=@($rows|Where-Object {(Get-TCDField $_ ExitEvidence '') -eq 'VerifiedTlsTrace' -and (Get-TCDField $_ ObservedExitIPv4)})|Select-Object -First 1
    if($verified){$run.ExpectedExitIPv4=$verified.ObservedExitIPv4;$run.ExpectedExitSource='ServerVerifiedTlsTrace'}
    Complete-TCDeploymentCandidate $Root $run
   }
   'Reconcile'{
    if($data.Status -eq 'NeedsRecovery'){$run.Stage='NeedsRecovery';$run.Status='NeedsRecovery';$run.LastError=[pscustomobject]@{Code='NeedsRecovery';Message='服务器存在未完成事务，请先审阅恢复结果。'};$run.UserActions=@('服务器维护与恢复')}
    elseif($run.ClientRequest){Start-TCDeploymentRemote $Root $run request_status RequestStatus @{RequestId=$run.ClientRequest.RequestId}}
    else{$run.Stage='Inspect';$run.Status='Idle'}
   }
   'RequestStatus'{
    if($data.ClientResponse){$run.ClientResponse=$data.ClientResponse;Start-TCDeploymentRemote $Root $run server_info ServerInfo @{}}
    else{$run.Stage='Inspect';$run.Status='Idle'}
   }
   default{throw '[TC:StageMismatch] 未识别执行结果阶段。'}
  }
  return Save-TCDeploymentRun $Root $run
 }catch{
  if($run){
   if($run.Status -ne 'OutcomeUnknown'){$run.Status=if($run.DispatchIntent -and $run.DispatchIntent.Mutating -and $run.DispatchIntent.State -in @('Prepared','Dispatched')){'OutcomeUnknown'}else{'Failed'}}
   $message='流程未完成，原申请和操作记录已保留。';$errorCode='FlowFailed';if($_.Exception.Message -match '^\[TC:([A-Za-z0-9_]+)\] (.{1,500})$'){$errorCode=$Matches[1];$message=$Matches[2]}
   $run.LastError=[pscustomobject]@{Code=$errorCode;Message=$message};$run.UserActions=@('检查原操作结果','保留记录并重试');return Save-TCDeploymentRun $Root $run};throw
 }finally{$lock.Dispose()}
}
Export-ModuleMember -Function Get-TCDeploymentDiscovery,Get-TCDeploymentRuns,Get-TCDeploymentRun,New-TCDeploymentRun,Set-TCDeploymentSession,Invoke-TCDeploymentAdvance,Sync-TCDeploymentRun,ConvertTo-TCDeploymentConnection,Complete-TCPairCandidate
