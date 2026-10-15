# Pure projection. No disk/network IO, persistence, or deployment decisions.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'UiState.psm1') -DisableNameChecking
function LineCardField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}elseif($Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function GetLineCardViewModel {param($Line,$Runtime,$Pending,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 $id=[string](LineCardField $Line LineId (LineCardField $Line id ''));$name=[string](LineCardField $Line Name (LineCardField $Line name '线路'))
 $endpoint=[string](LineCardField $Line Endpoint (LineCardField $Line endpoint ''));$hostName=$endpoint
 $uri=$null;if([Uri]::TryCreate(('tc://'+$endpoint),[UriKind]::Absolute,[ref]$uri)){$hostName=$uri.Host.Trim('[',']')}
 $active=([bool](LineCardField $Runtime Running $false) -and [string](LineCardField $Runtime LineId '') -ceq $id)
 $activeProfile=if($active){[string](LineCardField $Runtime ProfileId '')}else{''}
 $saved=LineCardField $Line SavedConnectionPreference;$defaultId=if(LineCardField $Line DefaultVerified $false){[string](LineCardField $saved ProfileId '')}else{''}
 $block=[string](LineCardField $Line ServerConnectionBlock '');$profiles=@(LineCardField $Line Profiles @());$items=@()
 foreach($mode in @('Udp','Tcp')){
  $p=@($profiles|Where-Object {(LineCardField $_ Id '') -ceq $mode})|Select-Object -First 1
  $prepared=($p -and (LineCardField $p PreparationState '') -in @('Ready','Prepared','SyntaxValidated') -and (LineCardField $p SyntaxValidated $true) -ne $false)
  $e=LineCardField $p Validation;$isActive=($activeProfile -ceq $mode);$health='待检查';$tone='idle';$reason='配置已准备，实际连接后仍会核对出口、DNS 和 HTTPS。'
  if($isActive){
   $check=LineCardField $Runtime Validation
   $bound=(Test-TCLineCheckBinding $check (LineCardField $Runtime CheckContext) $id $mode $Now)
   $e=if($bound){$check}else{$null}
  }
  $status=[string](LineCardField $e Status 'NotTested');$code=[string](LineCardField $e Code '');$at=LineCardField $e ValidatedAt (LineCardField $e CheckedAtUtc);$until=LineCardField $e ExpiresAt
  $expired=$false;if($until){try{$expired=[DateTimeOffset]::Parse([string]$until) -le $Now}catch{$expired=$true}}
  switch($status){
   'Passed'{if(LineCardField $e ForwardingPassed $false){$health='检查通过';$tone='ok'}else{$health='检查结论不足'}}
   'Failed'{$health=if($isActive){'检查失败'}else{'最近检查失败'};$tone='warn'}
   {$_ -in @('Blocked','NeedsRecovery','OutcomeUnknown')}{$health='待处理';$tone='warn'}
   {$_ -in @('Checking','Running')}{$health='检查中';$tone='info'}
   {$_ -in @('Inconclusive','Unknown')}{$health='检查结论不足';$tone='warn'}
   'Stale'{$health='检查已过期'}
  }
  if($expired -and $status -eq 'Passed'){$health='检查已过期';$tone='idle'}
  $unsafe=($block -or (LineCardField $p PreparationState '') -in @('NeedsRecovery','OutcomeUnknown','Invalid') -or $code -match 'CleanupFailed|CleanupIncomplete|IdentityUnknown|OwnershipUnknown|NeedsRecovery|IdentityMismatch|HashMismatch|ConfigInvalid')
  if(-not $prepared){$health='未配置';$reason='可在本线路的服务器与设备管理中补齐配置。'}
  if($unsafe){$health='待处理';$reason=if($block){[string](LineCardField $Line ServerConnectionMessage '服务器身份需要核对。')}else{'配置身份或上次清理需要核对，请打开线路详情。'}}
  elseif($code){$reason+=' 最近检查代码：'+$code}
  $label=$mode.ToUpperInvariant()+$(if($defaultId -ceq $mode){' 默认'}else{''})+$(if($isActive){' · 使用中'}else{''})
  $items+=,[pscustomobject]@{Id=$mode;Label=$label;Health=$health;Tone=$tone;IsDefault=($defaultId -ceq $mode);IsActive=$isActive;CanSelect=($prepared -and -not $unsafe -and -not $Pending);CanCheck=($prepared -and -not $unsafe -and -not $Pending);BlockReason=$reason;CheckedAt=$at;Profile=$p}
 }
 $badge=if($active){if(LineCardField $Runtime TradeInUse $false){'当前交易使用中'}else{'通道运行中 · 交易走备用'}}else{''}
 $action='Choose';$label='选择连接协议'
 if($block){$action='Details';$label='处理线路问题'}
 elseif($defaultId){if($active -and $activeProfile -ceq $defaultId){$action='Check';$label='重新检测'}elseif($active){$action='Connect';$label='切换为 '+$defaultId.ToUpperInvariant()}else{$action='Connect';$label=if(LineCardField $Runtime Running $false){'切换到此线路'}else{'连接线路'}}}
 elseif($saved){$action='Repair';$label='核对旧默认'}
 $selected=@($items|Where-Object {$_.Id -ceq $defaultId})|Select-Object -First 1
 if($selected -and -not $Pending -and -not $selected.CanCheck){$action='Details';$label='处理线路问题'}
 if($Pending){$label=if((LineCardField $Pending Kind '') -eq 'Check'){'检查中…'}else{'保存默认中…'}}
 [pscustomobject]@{LineId=$id;Name=$name;ServerHost=$hostName;RuntimeBadge=$badge;ActiveProfileId=$activeProfile;SavedDefaultProfileId=$defaultId;Protocols=$items;PrimaryAction=$action;PrimaryLabel=$label;CheckProfileId=$(if($selected -and $selected.CanCheck){$defaultId}else{''});CanDelete=(-not $active -and -not $Pending);DeleteReason=$(if($active){'使用中不可删除，请先断开或切换到其他线路。'}elseif($Pending){'本线路操作尚未结束。'}else{'删除此线路及其独占本机资料。'});Revision=(LineCardField $Line Revision 0);Pending=$Pending}
}
