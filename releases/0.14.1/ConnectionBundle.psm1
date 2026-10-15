#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking
# A local versioned projection of the exact, verified V1 signed authorization.
# It is never inserted into V1 invitation/request/authorization wire objects.
# Persist the full projection only in the pairing DPAPI envelope.
function New-TCConnectionBundle {
 [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$SignedAuthorization,[Parameter(Mandatory=$true)][string]$PairRequest,
  [Parameter(Mandatory=$true)]$ServerBinding,[Parameter(Mandatory=$true)]$ManagementSigningPublicKey,[Parameter(Mandatory=$true)][string]$ConfirmedFingerprint)
 $pair=Import-Module (Join-Path $PSScriptRoot 'DeploymentPairing.psm1') -PassThru -DisableNameChecking
 $authorization=& $pair {
  param($Signed,$RequestText,$Binding,$SigningKey,$Fingerprint)
  Initialize-TCPairCrypto;Assert-TCPairBinding $Binding
  $jwk=ConvertTo-TCPairJson $SigningKey
  if([TradeChannel.Deployment.PairCrypto]::Fingerprint($jwk) -cne $Fingerprint){Stop-TCPair InviteTrustChanged '本地 bundle 的签名身份与已确认服务器不匹配。'}
  try{$body=ConvertFrom-TCPairJson ([TradeChannel.Deployment.PairCrypto]::Verify($Signed,$jwk))}catch{Stop-TCPair InvalidAuthorization 'bundle 原始服务器授权验签失败。'}
  $request=(Get-TCPairRequestInfo $RequestText).Payload
  Assert-TCPairAuthorization $body $request @{ServerBinding=$Binding}
  return $body
 } $SignedAuthorization $PairRequest $ServerBinding $ManagementSigningPublicKey $ConfirmedFingerprint
 $response=$authorization.ClientResponse
 $profiles=[ordered]@{Udp=[pscustomobject]@{Id='Udp';Protocol='udp';PublicEndpoint=$response.PublicEndpoint}}
 $transport=Get-TCDField $response Transport
 if($transport){
  $node=Import-Module (Join-Path $PSScriptRoot 'NodeStore.psm1') -PassThru -DisableNameChecking
  $validated=& $node {param($Value) ConvertTo-TCTransport $Value} $transport
  if($validated.Server -cne $response.PublicEndpoint.Split(':')[0]){throw '[TC:BundleBindingMismatch] bundle TCP endpoint 与原授权服务器不匹配。'}
  $profiles.Tcp=[pscustomobject]@{Id='Tcp';Protocol='tcp-reality';Transport=$validated}
 }
 [pscustomobject][ordered]@{SchemaVersion=1;Kind='TradeChannel.ConnectionBundle';ContractVersion=1;SignatureProtocol='TradeChannel.PairAuthorization.V1';
  Binding=[pscustomobject]@{NodeId=$authorization.NodeId;RemoteOwnerId=$authorization.RemoteOwnerId;ServerPublicKey=$response.ServerPublicKey;
   DeviceId=$authorization.DeviceId;ClientPublicKey=$authorization.ClientPublicKey;ClientAddress=$authorization.ClientAddress};
  ConfigRevision=[int]$authorization.ConfigRevision;Profiles=[pscustomobject]$profiles;
  Source=[pscustomobject]@{SignedAuthorization=$SignedAuthorization;PairRequest=$PairRequest;ServerBinding=$ServerBinding;ManagementSigningPublicKey=$ManagementSigningPublicKey;ConfirmedFingerprint=$ConfirmedFingerprint}}
}
function Assert-TCConnectionBundle {
 [CmdletBinding()]param([Parameter(Mandatory=$true)]$Bundle)
 Assert-TCDFields $Bundle @('SchemaVersion','Kind','ContractVersion','SignatureProtocol','Binding','ConfigRevision','Profiles','Source') @('SchemaVersion','Kind','ContractVersion','SignatureProtocol','Binding','ConfigRevision','Profiles','Source')
 if($Bundle.SchemaVersion -ne 1 -or $Bundle.ContractVersion -ne 1 -or $Bundle.Kind -cne 'TradeChannel.ConnectionBundle' -or $Bundle.SignatureProtocol -cne 'TradeChannel.PairAuthorization.V1'){throw '[TC:BundleVersionUnsupported] 未支持此本地 bundle 版本。'}
 Assert-TCDFields $Bundle.Source @('SignedAuthorization','PairRequest','ServerBinding','ManagementSigningPublicKey','ConfirmedFingerprint') @('SignedAuthorization','PairRequest','ServerBinding','ManagementSigningPublicKey','ConfirmedFingerprint')
 $expected=New-TCConnectionBundle -SignedAuthorization $Bundle.Source.SignedAuthorization -PairRequest $Bundle.Source.PairRequest -ServerBinding $Bundle.Source.ServerBinding -ManagementSigningPublicKey $Bundle.Source.ManagementSigningPublicKey -ConfirmedFingerprint $Bundle.Source.ConfirmedFingerprint
 if((Get-TCDDigest $Bundle) -cne (Get-TCDDigest $expected)){throw '[TC:BundleBindingMismatch] 本地 bundle 与真实验签的原授权资料不一致。'}
 return $expected
}
Export-ModuleMember -Function New-TCConnectionBundle,Assert-TCConnectionBundle
