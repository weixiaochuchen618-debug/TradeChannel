#requires -Version 5.1
Set-StrictMode -Version 2
function Get-TCFirstTrustTarget {
 param($Connection)
 $address=$null;$hostName=[string]$Connection.Host
 if([Net.IPAddress]::TryParse($hostName,[ref]$address)){$hostName=$address.ToString()}else{$hostName=$hostName.TrimEnd('.').ToLowerInvariant()}
 [pscustomobject]@{Host=$hostName;Port=[int]$Connection.Port;User=[string]$Connection.User}
}
function New-TCFirstTrustDecision {
 [CmdletBinding()]param([string]$RunId,[string]$ServerRecordId,$Connection,[string]$Fingerprint,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $RunId -or -not $ServerRecordId -or -not $Connection -or $Fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw '[TC:TrustContextInvalid] 首次身份确认缺少完整目标。'}
 $target=Get-TCFirstTrustTarget $Connection
 if(-not $target.Host -or -not $target.User -or $target.Port -lt 1 -or $target.Port -gt 65535){throw '[TC:TrustContextInvalid] 登录目标无效。'}
 [pscustomobject]@{TrustDecisionId=[guid]::NewGuid().ToString('D');RunId=$RunId;ServerRecordId=$ServerRecordId;CanonicalTarget=$target;Fingerprint=$Fingerprint;ConfirmedAtUtc=$Now.ToString('o');ExpiresAtUtc=$Now.AddMinutes(30).ToString('o');Origin='ExplicitUserConfirmation'}
}
function Test-TCFirstTrustDecision {
 [CmdletBinding()]param($Decision,[string]$RunId,[string]$ServerRecordId,$Connection,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 try{
  if(-not $Decision -or $Decision.Origin -cne 'ExplicitUserConfirmation' -or $Decision.RunId -cne $RunId -or $Decision.ServerRecordId -cne $ServerRecordId -or $Decision.Fingerprint -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){return $false}
  $at=[DateTimeOffset]::Parse($Decision.ConfirmedAtUtc);$until=[DateTimeOffset]::Parse($Decision.ExpiresAtUtc)
  if($at -gt $Now -or $until -ne $at.AddMinutes(30) -or $until -le $Now){return $false}
  $target=Get-TCFirstTrustTarget $Connection
  foreach($key in @('Host','Port','User')){if([string]$target.$key -cne [string]$Decision.CanonicalTarget.$key){return $false}}
  return $true
 }catch{return $false}
}
function Resolve-TCDeploymentPinnedFingerprint {
 [CmdletBinding()]param([string]$SavedPin,$Decision,[string]$RunId,[string]$ServerRecordId,$Connection,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if($SavedPin -and $SavedPin -cnotmatch '^SHA256:[A-Za-z0-9+/]{43}$'){throw '[TC:TrustPinInvalid] 已保存的服务器身份无效，请核对原记录。'}
 $valid=Test-TCFirstTrustDecision $Decision $RunId $ServerRecordId $Connection -Now $Now
 if($SavedPin){if($valid -and $SavedPin -cne $Decision.Fingerprint){throw '[TC:TrustIdentityConflict] 本次确认与已保存服务器身份冲突，请核对原身份。'};return $SavedPin}
 if($valid){return [string]$Decision.Fingerprint};return ''
}
Export-ModuleMember -Function New-TCFirstTrustDecision,Test-TCFirstTrustDecision,Resolve-TCDeploymentPinnedFingerprint
