#requires -Version 5.1
Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'UiState.psm1') -DisableNameChecking
function LCheckField {param($v,[string]$n,$default=$null)if($v -is [Collections.IDictionary]){if($v.Contains($n)){return $v[$n]}}elseif($v -and $v.PSObject.Properties[$n]){return $v.$n};$default}
function Get-TCLineCheckPlan {param($Line,$Runtime,[string]$ProfileId)
 $lineId=[string](LCheckField $Line LineId '');$p=@((LCheckField $Line Profiles @())|Where-Object {(LCheckField $_ Id '') -ceq $ProfileId})|Select-Object -First 1
 $result=[pscustomobject]@{LineId=$lineId;ProfileId=$ProfileId;Mode='Blocked';Code='ProfileConfigurationMissing';Message='所选协议配置未完成，请在线路管理中处理。';SessionId=(LCheckField $Runtime SessionId '');ConfigHash=(LCheckField $Runtime ConfigHash '')}
 $prepState=[string](LCheckField $p PreparationState '')
 if(-not $p -or $prepState -notin @('Ready','Prepared','SyntaxValidated')){return $result}
 $serverBlock=[string](LCheckField $Line ServerConnectionBlock '')
 if($serverBlock){$result.Code='ServerBindingChanged';$result.Message='服务器身份需要核对，当前连接保持。';return $result}
 if(LCheckField $Runtime Running $false){
  if((LCheckField $Runtime ActiveLineId '') -ceq $lineId -and (LCheckField $Runtime ActiveProfileId '') -ceq $ProfileId){
   if([string](LCheckField $Runtime Exit '') -cne 'hk'){$result.Code='TargetNotSelectedExit';$result.Message='当前交易出口没有使用这条自建线路；未对备用或直连出口执行本线路检查。';return $result}
   if(-not (Get-TCExitCheckContext $Runtime).Eligible){$result.Code='RuntimeContextUnavailable';$result.Message='当前会话身份或运行状态尚不可核验，本次未执行检查。';return $result}
   $result.Mode='Active';$result.Code='CheckCurrentSession';$result.Message='检查本次运行会话。';return $result
  }
  if((LCheckField $Runtime ActiveLineId '') -ceq $lineId){$result.Code='ActiveIdentityInUse';$result.Message='另一协议正在使用此设备身份，无法并行检测；可点击切换后核对目标协议，当前连接保持。';return $result}
 }
 $result.Mode='Candidate';$result.Code='CheckSelectedCandidate';$result.Message='仅检查所选线路和协议，保留当前连接。';return $result
}
function Invoke-TCLineProfileCheck {
 [CmdletBinding()]param([string]$Root,[string]$Id,[ValidateSet('Udp','Tcp')][string]$ProfileId,[long]$ExpectedRevision=-1)
 Import-Module (Join-Path $PSScriptRoot 'LineStore.psm1') -DisableNameChecking
 Import-Module (Join-Path $PSScriptRoot 'RuntimeBridge.psm1') -DisableNameChecking
 $line=Get-TCLine -Root $Root -Id $Id
 if($ExpectedRevision -ge 0 -and [long]$line.Revision -ne $ExpectedRevision){throw '[TC:LineRevisionChanged] 线路资料已变化，请刷新后重新检查。'}
 $Id=[string]$line.LineId;$runtime=Get-TCOverview;$plan=Get-TCLineCheckPlan $line $runtime $ProfileId
 $target=[pscustomobject]@{LineId=$Id;ProfileId=$ProfileId;ExpectedRevision=$line.Revision}
 if($plan.Mode -eq 'Blocked'){return [pscustomobject]@{LineId=$Id;ProfileId=$ProfileId;RequestedTarget=$target;Status='Blocked';Code=$plan.Code;Message=$plan.Message;NetworkChanged=$false}}
 if($plan.Mode -eq 'Active'){
  $expectedContext=Get-TCExitCheckContext $runtime
  $check=Test-TCActiveConnection
  # Preserve the measured identity. Never stamp the old plan over what the
  # network check actually observed (which may have changed before dispatch).
  $current=Get-TCExitCheckContext (Get-TCOverview)
  if($expectedContext.Key -cne $current.Key -or -not (Test-TCLineCheckBinding $check $current $Id $ProfileId)){
   $check|Add-Member NoteProperty Status 'Inconclusive' -Force;$check|Add-Member NoteProperty Code 'RequestedContextChanged' -Force;$check|Add-Member NoteProperty ForwardingPassed $false -Force
  }
  return [pscustomobject]@{LineId=$Id;ProfileId=$ProfileId;RequestedTarget=$target;MeasuredContext=(LCheckField $check MeasuredContext);Status=$check.Status;Code=$check.Code;Message=$(if($check.ForwardingPassed){'所选协议的本次会话转发检查通过。'}else{'本次会话检查未通过或测量归属已变化，请查看线路详情。'});Check=$check;NetworkChanged=$false}
 }
 Import-Module (Join-Path $PSScriptRoot 'CandidateProbe.psm1') -DisableNameChecking
 Import-Module (Join-Path $PSScriptRoot 'ProtocolSelection.psm1') -DisableNameChecking
 $profile=@($line.Profiles|Where-Object Id -ceq $ProfileId)[0];$origin=LCheckField $profile.Validation Result
 $raw=Test-TCCandidateProbe -Root $Root -NodeId $Id -ProfileId $ProfileId -TimeoutSeconds 45 -ExpectedExitIPv4 ([string](LCheckField $origin ExpectedExitIPv4 '')) -ExpectedExitSource ([string](LCheckField $origin ExpectedExitSource 'Unknown'))
 $e=ConvertTo-TCProtocolEvidence -Result $raw -Profile $profile -NetworkContext ([pscustomobject]@{Fingerprint=(LCheckField $raw NetworkFingerprint '')})
 # Store only that target's result; this action never saves a recommendation or default.
 $latest=Get-TCLine -Root $Root -Id $Id
 if($latest.Revision -ne $line.Revision){throw '[TC:LineRevisionChanged] 检查期间线路资料已变化，结果未贴到新配置。'}
 $null=Set-TCLineProfileValidation -Root $Root -Id $Id -ProfileId $ProfileId -Validation $e -ExpectedRevision $line.Revision
 [pscustomobject]@{LineId=$Id;ProfileId=$ProfileId;Status=$raw.Status;Code=$raw.Code;Message=$(if($raw.ForwardingPassed){'所选线路 '+$ProfileId.ToUpperInvariant()+' 转发检查通过。'}else{'所选协议检查结果：'+$raw.Code+'；当前连接保持。'});Check=$e;NetworkChanged=$false}
}
Export-ModuleMember -Function Get-TCLineCheckPlan,Invoke-TCLineProfileCheck
