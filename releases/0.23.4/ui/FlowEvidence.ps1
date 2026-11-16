# Exits are measured facts; AI routing is explicitly an inference from rules.
function CurrentExitCheck {Get-TCExitCheckView $script:Checks $script:Overview}
function RuntimeConnectionCheck {
 $o=$script:Overview;$v=ProfileUIField $o 'RuntimeValidation';$result=@{Status='NotTested';Time=''}
 if(-not $v -or -not (IsRunning)){return [pscustomobject]$result}
 foreach($pair in @(@('LineId','ActiveLineId'),@('ProfileId','ActiveProfileId'),@('SessionId','SessionId'),@('ConfigHash','ConfigHash'))){
  $actual=[string](ProfileUIField $o $pair[1] '');$saved=[string](ProfileUIField $v $pair[0] '')
  if(-not $actual -or $actual -cne $saved){return [pscustomobject]$result}
 }
 $result.Status=[string](ProfileUIField $v 'Status' 'NotTested')
 if($result.Status -eq 'Passed' -and -not (ProfileUIField $v 'ForwardingPassed' $false)){$result.Status='Inconclusive'}
 $when=ProfileUIField $v 'CheckedAtUtc' (ProfileUIField $v 'CheckedAt' '')
 try{if($when){$result.Time=([DateTimeOffset]::Parse([string]$when)).LocalDateTime.ToString('HH:mm:ss')}}catch{}
 [pscustomobject]$result
}
function FlowEvidence {param([string]$Lane)
 $view=CurrentExitCheck;$text='';$tone='idle';$o=$script:Overview
 if((StateKey) -eq 'Fault'){$text='当前流量走向待核对 · 请查看运行诊断';$tone='bad'}
 elseif(-not (IsRunning)){$text='连接后可检查实际出口'}
 elseif($Lane -eq 'Trade'){
  if($view.Current){$tone=if($view.TradePassed){'ok'}else{'bad'};$text=if($view.TradePassed){'实测出口 '+$view.TradeIP+' · '+$view.Time+' 检查通过'}else{'出口检查未通过 · '+$view.Time+' · 查看运行诊断'}}
  elseif($view.Status -eq 'Stale'){$text=$view.Reason;$tone='warn'}
  else{
   $runtime=RuntimeConnectionCheck
   switch($runtime.Status){
    'Passed'{$text='连接时网络检查通过'+$(if($runtime.Time){' · '+$runtime.Time}else{''})+' · 可检查当前出口';$tone='ok'}
    'Failed'{$text='连接检查未通过 · 查看运行诊断';$tone='bad'}
    {$_ -in @('Running','Checking')}{$text='正在检查连接';$tone='warn'}
    'Blocked'{$text='检查受限 · 当前线路正在使用，请查看诊断';$tone='warn'}
    default{$text='尚未完成出口检查 · 交易业务可用性需单独确认'}
   }
  }
 }elseif($Lane -eq 'Daily'){
  if($view.Current){$tone=if($view.DailyPassed){'ok'}else{'warn'};$text=if($view.DailyPassed){'实测出口 '+$view.DailyIP+' · '+$view.Time+' 检查通过'}else{'日常出口尚未验证 · 请检查服务商或本地网络'}}
  elseif($view.Status -eq 'Stale'){$text='出口检查需要更新 · '+$view.Time;$tone='warn'}
  else{$text='实际出口可通过「检查出口」获取'}
 }else{
  $trade=(AgentLaneValue) -eq 'Trade';$source=if($trade){'交易'}else{'日常'}
  $ip=if($trade){$view.TradeIP}else{$view.DailyIP}
  $text='按分流规则跟随'+$source+'出口'+$(if($view.Current -and $ip){' '+$ip+' · '+$view.Time}else{''})+' · AI 平台可用性未单独验证'
 }
 [pscustomobject]@{Text=$text;Tone=$tone;Source=$(if($Lane -eq 'Agents'){'RuleInference'}else{'MeasuredOnly'})}
}
function AddStatusDetails {param($Parent)
 $view=CurrentExitCheck;$o=$script:Overview;$pv=ProviderEntry
 $critical=((StateKey) -eq 'Fault' -or ($o -and $o.ForeignTunnel) -or ((IsRunning) -and [string]$o.GuardState -ne 'Protected') -or ($view.Current -and (-not $view.TradePassed)) -or (RuntimeConnectionCheck).Status -eq 'Failed' -or ($o -and $o.DailyReason) -or $script:ProviderReadError)
 $expander=ControlName (New-Object Windows.Controls.Expander) 'StatusDetails';$expander.Margin='0,16,0,0'
 $header=Stack 'Horizontal';AddC $header (T '状态详情' 12.5 $script:Ink 'SemiBold')
 $protection=if($o -and $o.GuardState -eq 'Protected'){'交易保护已核验'}elseif($o -and $o.GuardState -eq 'Unprotected'){'交易保护不完整'}else{'保护待核对'}
 AddC $header (Margin (Pill $protection $(if($o -and $o.GuardState -eq 'Protected'){'ok'}else{'warn'})) '12,0,0,0')
 AddC $header (Margin (Pill $(if($view.Current){$view.Reason}else{'出口检查：'+$(if($view.Status -eq 'Stale'){'需更新'}else{'尚未完成'})}) $(if($view.Current -and $view.TradePassed){'ok'}elseif($view.Status -eq 'Failed'){'bad'}else{'idle'})) '8,0,0,0')
 $expander.Header=$header;$body=Stack
 $cards=Grid @('*','16','*','16','*');Cell $cards (CheckCard) 0;Cell $cards (ProviderCard) 2;Cell $cards (GuardCard) 4;AddResponsiveLayout $cards 'Cards';AddC $body $cards
 AddRuntimeStatusCard $body;$expander.Content=$body;$expander.IsExpanded=($critical -or $script:StatusDetailsOpen)
 $expander.Add_Expanded({$script:StatusDetailsOpen=$true});$expander.Add_Collapsed({$script:StatusDetailsOpen=$false})
 AddC $Parent $expander
}
