# Only the owning SelfTest harness may render these fixtures. Worker calls are captured.
if(-not $script:Smoke -or -not $SelfTest){throw 'P19 requires isolated SelfTest.'}
function NewUI019Line {param([string]$Id,[string]$Name,[string[]]$Modes=@('Udp','Tcp'),[string]$Default='Udp')
 $line=NewUI0120Line -NoSaved;$line.id=$Id;$line.LineId=$Id;$line.Name=$Name
 $line.Profiles=@($line.Profiles|Where-Object {$_.Id -in $Modes})
 foreach($p in $line.Profiles){
  $m=ReadUI0120Json $p.ManifestPath;$m.TCLineId=$Id;$m.node_id=$Id;$m.TCManagedNodeId=$Id
  $p.ManifestPath=Join-Path $script:Root ('019-'+$Id+'-'+$p.Id+'.manifest.json')
  [IO.File]::WriteAllText($p.ManifestPath,($m|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))
  $p.ManifestSHA256=(Get-FileHash -LiteralPath $p.ManifestPath -Algorithm SHA256).Hash
  $p.Validation=NewUI0120Evidence $p 'Passed'
 }
 $line.manifestPath=$line.Profiles[0].ManifestPath;$line.SourceManifestPath=$line.manifestPath
 $line.Recommendation=$null;SaveUI0120Default $line $Default -Manual
 $line|Add-Member NoteProperty DefaultVerified $true -Force
 $line
}
function ResetUI019 {
 Fixture0120;$script:LinePreferenceRequests=@{};$script:LineCheckRequests=@{};$script:LineCheckResults=@{}
 $script:Window.WindowState='Normal';$script:Window.Width=1280;$script:Window.Height=820
}
function AssertCardBounds019 {param([string]$Name)
 $script:Window.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $bounds=@()
 foreach($entry in $script:LineCardControls.GetEnumerator()){
  $card=$entry.Value.Card
  foreach($c in @($entry.Value.Identity,$entry.Value.Protocols,$entry.Value.Actions)){
   $point=$c.TranslatePoint((New-Object Windows.Point(0,0)),$card)
   AssertUI ($c.ActualWidth -gt 0 -and $point.X -ge 0 -and $point.X+$c.ActualWidth -le $card.ActualWidth+1 -and $point.Y+$c.ActualHeight -le $card.ActualHeight+1) ('019 '+$Name+' bounds '+$entry.Key)
   $bounds+=,[ordered]@{LineId=$entry.Key;X=$point.X;Y=$point.Y;Width=$c.ActualWidth;Height=$c.ActualHeight;CardWidth=$card.ActualWidth;CardHeight=$card.ActualHeight}
  }
  AssertUI ($entry.Value.Radios.Udp.ActualWidth -ge 80 -and $entry.Value.Radios.Tcp.ActualWidth -ge 80) ('019 '+$Name+' readable protocol hit areas')
  foreach($button in @($script:Controls['MoreNode'+$entry.Key.Replace('-','')],$entry.Value.Check)){
   if($button.Visibility -eq 'Visible'){
    $presenter=$button.Template.FindName('contentPresenter',$button)
    if(-not $presenter){$presenter=$button.Template.FindName('ContentPresenter',$button)}
    AssertUI ($button.ActualWidth-$button.Padding.Left-$button.Padding.Right -ge 20) ('019 '+$Name+' icon has a readable content area')
   }
  }
 }
 [IO.File]::WriteAllText((Join-Path $qa ('019-bounds-'+$Name+'.json')),($bounds|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
}
function InvokeUI019Tests {
 $before=$script:Assertions.Count;$third='33333333-3333-3333-3333-333333333333'
 ResetUI019
 $a=NewUI019Line $hk '香港主线' @('Udp')
 $b=NewUI019Line $us '测试线路 · 默认与当前独立' @('Udp','Tcp') 'Tcp'
 $c=NewUI019Line $third '第三条线路 · 较长名称用于检查省略与详情' @('Tcp') 'Tcp'
 $script:Nodes=@($a,$b,$c)
 $script:Overview.Running=$true;$script:Overview.StateKey='Connected';$script:Overview.Exit='hk';$script:Prefs.NodeId=$us
 foreach($pair in @(@('ActiveLineId',$us),@('ActiveProfileId','Tcp'),@('SessionId','019-session'),@('ConfigHash',('A'*64)))){$script:Overview|Add-Member NoteProperty $pair[0] $pair[1] -Force}
 $runtime=[pscustomobject]@{LineId=$us;ProfileId='Tcp';SessionId='019-session';ConfigHash=('A'*64);Status='Passed';ForwardingPassed=$true;ValidatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
 $script:Overview|Add-Member NoteProperty RuntimeValidation $runtime -Force
 ShowNodes
 AssertUI (@(Requests).Count -eq 0 -and $script:LineCardControls.Count -eq 3) '019 read-only rendering creates three cards without an actor'
 AssertUI ($script:LineCardControls[$hk].Healths.Tcp.Text -eq '未配置' -and $script:LineCardControls[$third].Healths.Udp.Text -eq '未配置') '019 UDP-only and TCP-only both show the unconfigured protocol'
 AssertUI (-not $script:LineCardControls[$us].Delete.IsEnabled -and $script:LineCardControls[$us].Delete.ToolTip -like '*使用中不可删除*') '019 actual active-line delete is disabled with reason'
 AssertCardBounds019 'wide';Snapshot '019-01-three-lines-wide'
 $bCard=$script:LineCardControls[$us].Card;$tcpRadio=$script:LineCardControls[$us].Radios.Tcp
 $script:LineCardControls[$us].Radios.Udp.IsChecked=$true
 $r=@(Requests)[0]
 AssertUI (@(Requests).Count -eq 1 -and $r.Request.Action -eq 'LinePreference' -and $r.Request.Id -ceq $us -and $r.Request.ProfileId -ceq 'Udp' -and $r.Request.ExpectedRevision -eq $b.Revision) '019 capsule sends one exact revision-bound save, no connection'
 SaveLineDefaultProfileForLineUI $us Udp $b.Revision 'Card'
 AssertUI (@(Requests).Count -eq 1 -and -not $script:LineCardControls[$us].Radios.Tcp.IsEnabled) '019 repeated capsule click is blocked while saving'
 SaveUI0120Default $b Udp -Manual;CompleteUI $b
 AssertUI ($script:Overview.ActiveProfileId -ceq 'Tcp' -and $script:LineCardControls[$us].Radios.Udp.IsChecked -and $script:LineCardControls[$us].Labels.Tcp.Text -like '*使用中*' -and $script:LineCardControls[$us].Primary.Content -eq '切换为 UDP') '019 UDP default does not move the running TCP session'
 AssertUI ([object]::ReferenceEquals($bCard,$script:LineCardControls[$us].Card) -and [object]::ReferenceEquals($tcpRadio,$script:LineCardControls[$us].Radios.Tcp)) '019 save updates controls without replacing the card'
 $script:Actions.Clear();$u=$script:LineCardControls[$third];$u.Menu.PlacementTarget=$script:Controls['MoreNode'+$third.Replace('-','')];$u.Menu.IsOpen=$true
 UpdateReadPresentation -DataChanged
 AssertUI ($u.Menu.IsOpen -and [object]::ReferenceEquals($u.Card,$script:LineCardControls[$third].Card)) '019 polling preserves the opened more menu'
 $u.Menu.UpdateLayout();$null=$script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
 $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$u.Menu.ActualWidth,[int]$u.Menu.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($u.Menu)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open((Join-Path $qa '019-05-more-menu.png'),[IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()}
 $u.Menu.IsOpen=$false;ClickUI ('Profiles'+$third.Replace('-',''))
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'LineProfiles' -and @(Requests)[0].Request.Id -ceq $third) '019 third-line menu reads exactly the third line'
 ShowNodes;$script:Actions.Clear();CheckLineCardProtocolUI $third;$old=@(Requests)[0]
 AssertUI ($old.Request.Action -eq 'LineProfileCheck' -and $old.Request.Id -ceq $third -and $old.Request.ProfileId -ceq 'Tcp') '019 check action targets the third line TCP, not the active line'
 $script:LineCheckRequests.Remove($third);$script:Nodes=@($a,$b);ShowNodes
 & $old.Complete ([pscustomobject]@{Check=$runtime;Message='late fixture'}) $old.CallbackContext
 AssertUI (-not $script:LineCardControls.ContainsKey($third) -and -not $script:LineCheckResults.ContainsKey($third)) '019 a late check cannot recreate a deleted card or its evidence'
 $script:Nodes=@($a,$b,$c);ShowNodes;$script:Actions.Clear();SaveLineDefaultProfileForLineUI $us Tcp $b.Revision 'Card';$old=@(Requests)[0]
 $script:LinePreferenceRequests[$us]=@{RequestId='new-generation';Kind='Preference'}
 & $old.Complete $b $old.CallbackContext
 AssertUI ($script:LinePreferenceRequests[$us].RequestId -ceq 'new-generation' -and $script:LineCardControls[$us].Radios.Udp.IsChecked) '019 old preference callback cannot replace a newer request or highlight'
 $script:LinePreferenceRequests=@{};$script:Actions.Clear();ShowNodes;ClickUI ('Node'+$us.Replace('-',''))
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'ConnectionDefaultPreview' -and @(Requests)[0].Request.LineId -ceq $us -and -not @(Requests)[0].Request.ContainsKey('ProfileId')) '019 actual switch starts the saved-default preview only'
 CompleteUI ([pscustomobject]@{CanSwitch=$true;LineId=$us;ProfileId='Udp';PreviewToken='019-inert-token';Message='fixture preview'})
 AssertUI ((DialogOpen) -and @(Requests|Where-Object Request.Action -eq 'ConnectionSwitchCommit').Count -eq 0) '019 default selection requires a separate confirmed switch'
 ClickDialog 'DialogCancel'
 $bad=$a|ConvertTo-Json -Depth 50|ConvertFrom-Json;$bad.DefaultVerified=$false
 $v=GetLineCardViewModel $bad $null $null
 AssertUI ($v.PrimaryAction -eq 'Repair' -and -not $v.Protocols[0].IsDefault) '019 invalid saved default is a repair, not an authorized connection'
 $bad.SavedConnectionPreference=$null;$v=GetLineCardViewModel $bad $null $null
 AssertUI ($v.PrimaryAction -eq 'Choose') '019 no saved default exposes a choice'
 $c.Profiles[0].Validation=NewUI0120Evidence $c.Profiles[0] 'Failed';ShowNodes
 AssertUI ($script:LineCardControls[$third].Healths.Tcp.Text -eq '最近检查失败') '019 failure remains visible in its own protocol capsule'
 $c.Profiles[0].Validation=NewUI0120Evidence $c.Profiles[0] 'Stale';ShowNodes
 AssertUI ($script:LineCardControls[$third].Healths.Tcp.Text -eq '检查已过期') '019 expired health does not invalidate the saved choice'
 $c|Add-Member NoteProperty ServerConnectionBlock 'HostKeyChanged' -Force;$c|Add-Member NoteProperty ServerConnectionMessage 'fixture identity changed' -Force;ShowNodes
 AssertUI (-not $script:LineCardControls[$third].Radios.Tcp.IsEnabled -and $script:LineCardControls[$third].Healths.Tcp.Text -eq '待处理' -and $script:LineCardControls[$third].Primary.Content -eq '处理线路问题') '019 identity conflict remains blocked and visible'
 $c.ServerConnectionBlock='';$script:Window.Width=1000;$script:Window.Height=720;ShowNodes
 AssertCardBounds019 'minimum';Snapshot '019-02-three-lines-minimum'
 # WPF layout transform + high-DPI RenderTargetBitmap. This is a scale fixture,
 # not a claim that the machine's native monitor DPI was changed.
 $script:Window.Width=1280;$script:HostPanel.LayoutTransform=New-Object Windows.Media.ScaleTransform(1.25,1.25)
 AssertCardBounds019 'scale125';Snapshot '019-03-layout-scale125'
 $content=$script:Window.Content;$bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]($content.ActualWidth*1.5),[int]($content.ActualHeight*1.5),144,144,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
 $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Open((Join-Path $qa '019-04-render-144dpi.png'),[IO.FileMode]::Create);try{$encoder.Save($stream)}finally{$stream.Dispose()}
 $script:HostPanel.LayoutTransform=[Windows.Media.Transform]::Identity
 $script:Nodes=@();ShowNodes;$script:Actions.Clear();ClickUI 'ManageLineServers'
 AssertUI ($script:Role -eq 'servers' -and @(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -eq 'DeploymentDiscover') '019 all servers remains accessible without a local line'
 AssertUI (@(Requests|Where-Object {$_.Request.ContainsKey('SessionAction') -or $_.Request.Action -in @('ConnectionSwitchCommit','ServerOperation','DeploymentAttach')}).Count -eq 0) '019 journey dispatched no connection or server mutation'
 ResetUI019
 $entry=@{RequestId=('a'*32);OperationId=('a'*32);Action='Session';ResourceScope=@{Kind='Global'};RunId='';TransactionId=$null}
 ShowUiReceiptDetail $entry
 AssertUI ($script:Controls.ContainsKey('ReceiptReconcileConnection')) '013hotfix ordinary session receipt has a reachable reconciliation control'
 Snapshot '013hotfix-session-recovery'
 $script:Actions.Clear();ClickUI 'ReceiptReconcileConnection'
 AssertUI (@(Requests).Count -eq 1 -and @(Requests)[0].Request.Action -ceq 'ConnectionTransactionReconcile') '013hotfix recovery button dispatches only reconciliation, never reconnects'
 $script:UncertainUiJobs.Clear();$script:UncertainUiJobs.Add($entry)
 ShowUiMutationBlocked @{Action='ConnectionSwitchCommit'} @{Kind='Global'}
 AssertUI ($script:Window.FindName('DialogNote').Text -like '*本次连接尚未开始*' -and $script:Window.FindName('DialogNote').Text -notlike '*新部署*') '013hotfix blocked connection does not ask for a new deployment'
 CloseDialog;$script:UncertainUiJobs.Clear()
 $result=[ordered]@{Passed=$true;Assertions=$script:Assertions.Count-$before;WpfRendered=$true;WorkerLaunched=$false;NativeMonitorDpiChanged=$false;LayoutScale=1.25;RenderDpi=144;FixtureRoot=$script:Root}
 [IO.File]::WriteAllText((Join-Path $qa 'ui-019-result.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
}
