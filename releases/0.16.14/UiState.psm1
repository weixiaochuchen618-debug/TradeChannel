#requires -Version 5.1
# Pure presentation contracts. No process, controller or filesystem operations.
Set-StrictMode -Version 2.0
function Get-TCUiField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name}
 $Default
}
function Get-TCVisualState {param([string]$State,[bool]$Running,[string]$LineName,[string]$ProfileId)
 $icon='idle';$title='状态待核对';$tone='idle';$alert=$false
 switch($State){
  'Connected'{if($Running){$icon='connected';$title='通道运行中';$tone='ok'}}
  'Connecting'{$icon='busy';$title='正在连接';$tone='warn'}
  'Applying'{$icon='busy';$title='正在切换';$tone='warn'}
  'Disconnecting'{$icon='busy';$title='正在断开';$tone='warn'}
  'Disconnected'{$title='未连接'}
  'Unconfigured'{$title='尚未配置'}
  'Loading'{$title='正在核对状态'}
  'Fault'{$icon='fault';$title='连接状态需要处理';$tone='bad';$alert=$true}
 }
 $protocol=if($ProfileId -in @('Udp','Tcp')){$ProfileId.ToUpperInvariant()}else{''}
 $text=@($title,$LineName,$protocol)|Where-Object {$_}
 [pscustomobject]@{Icon=$icon;Title=$title;Tone=$tone;Alert=$alert;Summary=($text -join ' · ');Scope='TradingChannel'}
}
function Get-TCExitCheckContext {param($Overview)
 $fields=[ordered]@{}
 foreach($key in @('SessionId','ConfigHash','EnginePid','ManifestPath','ActiveLineId','ActiveProfileId','Mode','Exit','Daily','Agents','ProviderId','TradeProviderId','DesiredDaily','AgentsSupported','DailySupported')){
  $fields[$key]=Get-TCUiField $Overview $key
 }
 $fields.AgentIds=@(Get-TCUiField $Overview 'AgentIds' @()|Sort-Object)
 $fields.AgentCustom=@(Get-TCUiField $Overview 'AgentCustom' @()|ForEach-Object {([string](Get-TCUiField $_ 'Kind'))+':'+([string](Get-TCUiField $_ 'Value'))}|Sort-Object)
 $eligible=[bool](Get-TCUiField $Overview 'Running' $false) -and [string](Get-TCUiField $Overview 'StateKey') -eq 'Connected' -and
  -not [string]::IsNullOrEmpty([string]$fields.SessionId) -and [string]$fields.ConfigHash -match '^[A-Fa-f0-9]{64}$' -and
  [long]$fields.EnginePid -gt 0 -and -not [string]::IsNullOrEmpty([string]$fields.ManifestPath) -and -not [string]::IsNullOrEmpty([string]$fields.Exit) -and $fields.Mode -in @('rule','global')
 [pscustomobject]@{SchemaVersion=2;Eligible=$eligible;Key=($fields|ConvertTo-Json -Depth 5 -Compress);Fields=[pscustomobject]$fields}
}
function Test-TCLineCheckBinding {param($Check,$Context,[string]$LineId,[string]$ProfileId,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 if(-not $Check -or (Get-TCUiField $Check ProofVersion 0) -ne 2 -or (Get-TCUiField $Check ContextChanged $true)){return $false}
 $measured=Get-TCUiField $Check MeasuredContext;$fields=Get-TCUiField $measured Fields
 if(-not (Get-TCUiField $Context Eligible $false) -or -not (Get-TCUiField $measured Eligible $false) -or (Get-TCUiField $measured SchemaVersion 0) -ne 2 -or [string](Get-TCUiField $measured Key '') -cne [string](Get-TCUiField $Context Key '')){return $false}
 # The full measured fields must accompany the key; a copied key plus an old
 # line/profile tuple is insufficient. Empty provider/AI fields are meaningful.
 foreach($key in @('SessionId','ConfigHash','EnginePid','ManifestPath','ActiveLineId','ActiveProfileId','Mode','Exit','Daily','Agents','ProviderId','TradeProviderId','DesiredDaily','AgentsSupported','DailySupported','AgentIds','AgentCustom')){
  if(($fields -is [Collections.IDictionary] -and -not $fields.Contains($key)) -or ($fields -isnot [Collections.IDictionary] -and (-not $fields -or -not $fields.PSObject.Properties[$key]))){return $false}
  if((ConvertTo-Json -InputObject (Get-TCUiField $fields $key) -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject (Get-TCUiField $Context.Fields $key) -Depth 5 -Compress)){return $false}
 }
 if(-not $LineId -or $ProfileId -notin @('Udp','Tcp') -or [string]$fields.ActiveLineId -cne $LineId -or [string]$fields.ActiveProfileId -cne $ProfileId -or [string]$fields.Exit -cne 'hk'){return $false}
 $stamp=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string](Get-TCUiField $Check Time ''),[ref]$stamp) -or $stamp -gt $Now.AddSeconds(30) -or ($Now-$stamp).TotalMinutes -gt 10){return $false}
 return $true
}
function Get-TCExitCheckView {param($Check,$Overview,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
 $view=[ordered]@{Current=$false;Status='NotTested';Reason='尚未完成出口检查';Time='';TradeIP='';DailyIP='';TradePassed=$false;DailyPassed=$false;LatencyMs=$null;AgentSource='RuleInference'}
 if(-not $Check){return [pscustomobject]$view}
 $data=Get-TCUiField $Check 'Data';$binding=Get-TCUiField $data 'CheckContext';$context=Get-TCExitCheckContext $Overview
 $when=Get-TCUiField $data 'Time';$stamp=[DateTimeOffset]::MinValue
 if(-not $when -or -not [DateTimeOffset]::TryParse([string]$when,[ref]$stamp)){$view.Status='Stale';$view.Reason='历史检查缺少时间，请重新检查';return [pscustomobject]$view}
 $view.Time=$stamp.LocalDateTime.ToString('HH:mm:ss')
 if(-not $context.Eligible -or -not $binding -or -not (Get-TCUiField $binding 'Eligible' $false) -or [string](Get-TCUiField $binding 'Key') -cne $context.Key -or (Get-TCUiField $data 'ContextChanged' $false)){
  $view.Status='Stale';$view.Reason='线路、会话或分流已变化，请重新检查';return [pscustomobject]$view
 }
 if($stamp -gt $Now.AddSeconds(30) -or ($Now-$stamp).TotalMinutes -gt 10){$view.Status='Stale';$view.Reason='上次检查已过期，请重新检查';return [pscustomobject]$view}
 $view.Current=$true
 $ip=$null;$trade=[string](Get-TCUiField $data 'ObservedIP' '')
 $view.TradePassed=[bool](Get-TCUiField $data 'ExitHttp' $false) -and [Net.IPAddress]::TryParse($trade,[ref]$ip)
 if($view.TradePassed){$view.TradeIP=$trade}
 $daily=[string](Get-TCUiField $data 'DailyIP' '');$ip=$null
 $view.DailyPassed=[bool](Get-TCUiField $data 'DailyHttp' $false) -and [Net.IPAddress]::TryParse($daily,[ref]$ip)
 if([string](Get-TCUiField $data 'DailyLane') -eq 'trade'){$view.DailyPassed=$view.TradePassed;$daily=$view.TradeIP}
 if($view.DailyPassed){$view.DailyIP=$daily}
 $view.LatencyMs=Get-TCUiField $data 'TradeLatencyMs'
 $view.Status=if($view.TradePassed){'Passed'}else{'Failed'}
 $view.Reason=if($view.TradePassed){'出口检查通过'}else{'出口检查未通过；请查看诊断'}
 [pscustomobject]$view
}
Export-ModuleMember -Function Get-TCVisualState,Get-TCExitCheckContext,Get-TCExitCheckView,Test-TCLineCheckBinding
