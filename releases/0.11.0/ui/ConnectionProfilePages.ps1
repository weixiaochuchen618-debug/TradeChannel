# One logical line contains multiple immutable connection profiles. Preparation
# only changes metadata; switching uses a separately approved runtime transaction.
$script:LineProfileUI=$null
function ProfileUIField {param($Object,[string]$Key,$Default=$null)if($Object -is [Collections.IDictionary]){if($Object.Contains($Key)){return $Object[$Key]}}elseif($Object -and $Object.PSObject.Properties[$Key]){return $Object.$Key};$Default}
function NodeProfileItems {param($Node)
 $profiles=@(ProfileUIField $Node 'Profiles' @()|Where-Object {$_})
 if($profiles.Count){return $profiles}
 $m=$null;try{if($Node.manifestPath){$m=Get-Content -LiteralPath $Node.manifestPath -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
 if($m){[pscustomobject]@{Id=$(if($m.Transport){'Tcp'}else{'Udp'});Mode=$(if($m.Transport){'Tcp'}else{'Udp'});ManifestPath=$Node.manifestPath;PreparationState='Ready';Validation=$null}}
}
function NodeHasActiveProfile {param($Node)
 if(-not (IsRunning) -or -not $script:Overview.ManifestPath){return $false}
 if([string]$Node.manifestPath -ieq [string]$script:Overview.ManifestPath){return $true}
 if($script:Overview.PSObject.Properties['ProfileManifestPath'] -and $script:Overview.ProfileManifestPath){
  if([string]$Node.manifestPath -ieq [string]$script:Overview.ProfileManifestPath){return $true}
  if(@((NodeProfileItems $Node)|Where-Object {[string]$_.ManifestPath -ieq [string]$script:Overview.ProfileManifestPath}).Count -gt 0){return $true}
 }
 @((NodeProfileItems $Node)|Where-Object {[string]$_.ManifestPath -ieq [string]$script:Overview.ManifestPath}).Count -gt 0
}
function ConnectionProfileStatus {param($Profile)
 $state=[string](ProfileUIField $Profile 'PreparationState' 'Missing')
 if($state -in @('Missing','NotConfigured')){return '未准备'}
 if($state -in @('Failed','Invalid')){return '准备未完成'}
 if($state -in @('OutcomeUnknown','NeedsRecovery')){return '状态待核对'}
 $validation=ProfileUIField $Profile 'Validation'
 if($validation){
  $path=[string](ProfileUIField $validation 'TransportPath' '')
  $code=[string](ProfileUIField $validation 'Code' '')
  if($path -eq 'PhysicalDirect' -and (ProfileUIField $validation 'Status' '') -eq 'Passed'){return '本地直连验证通过'}
  if($code -eq 'ForwardingPassedPhysicalPathUnverified'){return '当前环境转发通过，直连待核对'}
  if((ProfileUIField $validation 'Status' '') -eq 'Failed'){return '最近检查未通过'}
 }
 '配置已准备，连通性待验证'
}
function LineConnectionsSummary {param($Node)
 $profiles=@(NodeProfileItems $Node);$labels=@()
 foreach($id in @('Udp','Tcp')){
  $profile=@($profiles|Where-Object {$_.Id -eq $id})|Select-Object -First 1
  $name=if($id -eq 'Udp'){'UDP'}else{'TCP 备用'}
  $labels+=($name+'：'+$(if($profile){ConnectionProfileStatus $profile}else{'未准备'}))
 }
 $labels -join '  ·  '
}
function LoadLineConnections {param([string]$Id)
 if(IsBusy){return}
 $script:LineProfileUI=@{Id=$Id;Line=$null;Preview=$null;Error='';SwitchResult=$null}
 StartJob @{Action='LineRegister';Id=$Id} {param($d)
  if(ProfileUIField $d 'Profiles'){$script:LineProfileUI.Line=$d;ShowLineConnections}
  else{StartJob @{Action='LineProfiles';Id=$script:LineProfileUI.Id} {param($line)$script:LineProfileUI.Line=$line;ShowLineConnections} '读取连接方式…'}
 } '整理这条线路的连接资料，当前会话保持…' -Failed {param($message)$script:LineProfileUI.Error=$message;ShowLineConnections}
}
function ShowLineConnections {
 $u=$script:LineProfileUI;PageHead '线路连接方式' '两种方式属于同一条线路。准备不影响现有连接，切换需要单独确认。' 'line-profiles'
 if(-not $u){ShowNodes;return}
 $card=Card '24,20';$p=Stack;$card.Child=$p;$line=$u.Line
 AddC $p (T ([string](ProfileUIField $line 'Name' '线路')) 17 $script:Ink 'SemiBold')
 AddC $p (Margin (T ([string](ProfileUIField $line 'Endpoint' '')) 12.5 $script:Text3) '0,5,0,10')
 foreach($id in @('Udp','Tcp')){
  $profile=@(ProfileUIField $line 'Profiles' @()|Where-Object {$_.Id -eq $id})|Select-Object -First 1
  $name=if($id -eq 'Udp'){'UDP 主要连接'}else{'TCP 备用连接'}
  $status=if($profile){ConnectionProfileStatus $profile}else{'未准备'}
  $row=Grid @('*','Auto');$row.Margin='0,12,0,12';$copy=Stack;AddC $copy (T $name 14 $script:Ink 'SemiBold');AddC $copy (Margin (T $status 12.5 $script:Text3) '0,4,16,0');Cell $row $copy 0
  if($profile -and (ProfileUIField $profile 'PreparationState' 'Ready') -notin @('Missing','Failed','Invalid','OutcomeUnknown','NeedsRecovery')){
   $button=Btn '切换并验证…' ('SwitchProfile'+$id) {PreviewLineConnectionSwitch ([string]$this.Tag)} 'Btn';$button.Tag=$id;$button.IsEnabled=(-not (IsBusy));Cell $row $button 1
  }elseif($id -eq 'Tcp'){$button=Btn '补齐备用方式' 'PrepareMissingTcp' {OpenAutomaticTransport $script:LineProfileUI.Id} 'Btn';Cell $row $button 1}
  AddC $p $row
 }
 if($script:Overview.NinjaRunning){AddC $p (Note '交易软件正在运行。连接方式切换会中断通道，请先退出整个 NinjaTrader，再核对切换计划。' 'amber')}
 if($u.Error){AddC $p (Margin (Notice 'warn' '需要处理' $u.Error) '0,12,0,0')}
 if($u.SwitchResult){AddC $p (Margin (T ([string](ProfileUIField $u.SwitchResult 'Message' '操作结果已记录，请核对实际运行状态。')) 13 $script:Text2) '0,12,0,0')}
 $null=DeploymentActions $p '返回线路' 'LineProfilesBack' {ShowNodes;FetchNodes} 'Ghost'
 AddC $script:HostPanel $card
}
function PreviewLineConnectionSwitch {param([string]$ProfileId)
 if(IsBusy){return}
 if($script:Overview.NinjaRunning){ErrorDialog '请先退出整个 NinjaTrader，再切换连接方式。当前连接保持。';return}
 StartJob @{Action='ConnectionSwitchPreview';LineId=$script:LineProfileUI.Id;ProfileId=$ProfileId} {param($preview)
  $script:LineProfileUI.Preview=$preview
  if((ProfileUIField $preview 'CanSwitch' $true) -eq $false){$script:LineProfileUI.Error=[string](ProfileUIField $preview 'Message' '当前状态不能安全切换。');ShowLineConnections;return}
  OpenDialog '切换这条线路的连接方式？' ('目标方式：'+[string](ProfileUIField $preview 'ProfileId' $ProfileId)+'。将短暂停止原通道，交易出口使用这条自建线路，再验证目标方式；日常和 AI 的选择保持。') '失败时恢复原配置、原出口与原运行状态并复测；恢复未完成会明确报告。行情、登录和订单需在交易软件中核对。' '切换并验证' {
   $p=$script:LineProfileUI.Preview
   StartJob @{Action='ConnectionSwitchCommit';LineId=$script:LineProfileUI.Id;ProfileId=[string]$p.ProfileId;PreviewToken=[string]$p.PreviewToken} {param($d)
    $script:LineProfileUI.SwitchResult=$d
    RefreshOverview -Silent
    StartJob @{Action='LineProfiles';Id=$script:LineProfileUI.Id} {param($line)$script:LineProfileUI.Line=$line;ShowLineConnections} '读取切换结果…'
   } '切换连接方式并核对外网出口…' 'Applying' -Failed {param($message)$script:LineProfileUI.Error=$message;ShowLineConnections;RefreshOverview -Silent}
  } '保持原方式'
 } '只读核对切换计划…' -Failed {param($message)$script:LineProfileUI.Error=$message;ShowLineConnections}
}
