#requires -Version 5.1
# A display-only projection of the existing WPF business controls. This file
# never starts a worker, changes Page, opens a native menu, or serializes Tag.
# PageHead calls StartTCWebFormView immediately after clearing ContentHost.
$script:TCWebFormView=$null

function GetTCWebFormVariable {param([string]$Name)
 Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
}
function TestTCWebFormBusy {
 $command=Get-Command IsBusy -CommandType Function -ErrorAction SilentlyContinue
 if($command){return [bool](& $command)}
 return $false
}
function TestTCWebFormQueued {
 $queue=GetTCWebFormVariable 'JobQueue'
 foreach($entry in $queue){
  # A missing Silent flag is a foreground request, not permission to submit twice.
  $silent=$false
  if($entry -is [Collections.IDictionary]){$silent=($entry.Contains('Silent') -and $entry['Silent'] -eq $true)}
  elseif($null -ne $entry -and $entry.PSObject.Properties['Silent']){$silent=($entry.Silent -eq $true)}
  if(-not $silent){return $true}
 }
 return $false
}
function LimitTCWebFormText {param($Value,[int]$Limit=131072,$Context=$null)
 if($Value -isnot [string]){return ''}
 $size=$Limit
 if($null -ne $Context){$size=[Math]::Min($size,[Math]::Max(0,$Context.TextLeft))}
 if($Value.Length -gt $size){
  if($null -ne $Context){$Context.Truncated=$true}
  if($size -gt 0){$Value=$Value.Substring(0,$size)}else{$Value=''}
 }
 if($null -ne $Context){$Context.TextLeft-=$Value.Length}
 return $Value
}
function StartTCWebFormView {param([string]$Title='',[string]$Description='',[string]$Page='')
 $script:TCWebFormView=[pscustomobject]@{
  Generation=[guid]::NewGuid().ToString('N')
  Title=(LimitTCWebFormText $Title 1024);Description=(LimitTCWebFormText $Description 8192);Page=(LimitTCWebFormText $Page 128)
  Handles=(New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal))
  ObjectIds=(New-Object 'Collections.Generic.Dictionary[object,string]')
  OpenMenus=(New-Object 'Collections.Generic.Dictionary[string,bool]' ([StringComparer]::Ordinal))
 }
}
function TestTCWebFormExcluded {param($Control)
 if($Control -is [Windows.FrameworkElement]){
  if($Control.Name -cin @('DeployLater','DeployLeaveRunning') -and (Get-Command TestDeploymentBackgroundAvailableUI -ErrorAction SilentlyContinue) -and (TestDeploymentBackgroundAvailableUI)){return $true}
  # These are the legacy clear-text mirror and reveal button. The web input's
  # show/hide switch stays entirely in the browser; PasswordBox remains live.
  return ($Control.Name -ceq 'DeployPasswordPlainText' -or $Control.Name -clike 'DeployPasswordReveal*')
 }
 return $false
}
function GetTCWebFormControlText {param($Control,[int]$Depth=0)
 if($null -eq $Control -or $Depth -gt 12 -or (TestTCWebFormExcluded $Control)){return ''}
 if($Control -is [string]){return (LimitTCWebFormText $Control)}
 if($Control -is [Windows.UIElement] -and $Control.Visibility -ne [Windows.Visibility]::Visible){return ''}
 if($Control -is [Windows.Controls.TextBlock] -or $Control -is [Windows.Controls.AccessText] -or $Control -is [Windows.Documents.Run]){return (LimitTCWebFormText $Control.Text)}
 if($Control -is [Windows.Controls.PasswordBox] -or $Control -is [Windows.Controls.TextBox]){return ''}
 if($Control -is [Windows.Controls.Panel]){
  $parts=New-Object 'Collections.Generic.List[string]';$length=0
  foreach($child in $Control.Children){
   $part=GetTCWebFormControlText $child ($Depth+1)
   if($part){$part=LimitTCWebFormText $part ([Math]::Max(0,2048-$length));$parts.Add($part);$length+=$part.Length+1}
   if($parts.Count -ge 32 -or $length -ge 2048){break}
  }
  return ($parts.ToArray() -join ' ')
 }
 if($Control -is [Windows.Controls.Decorator] -or $Control -is [Windows.Controls.Viewbox]){return (GetTCWebFormControlText $Control.Child ($Depth+1))}
 if($Control -is [Windows.Controls.HeaderedContentControl] -or $Control -is [Windows.Controls.HeaderedItemsControl]){return (GetTCWebFormControlText $Control.Header ($Depth+1))}
 if($Control -is [Windows.Controls.ContentControl]){return (GetTCWebFormControlText $Control.Content ($Depth+1))}
 # In particular, never call ToString() on an arbitrary Content/Items object.
 return ''
}
function GetTCWebFormLabel {param($Control,[string]$Fallback='')
 if($Control -is [Windows.DependencyObject]){
  $label=[Windows.Automation.AutomationProperties]::GetName($Control)
  if($label){return (LimitTCWebFormText $label 2048)}
 }
 if($Fallback){return (LimitTCWebFormText $Fallback 2048)}
 if($Control -is [Windows.FrameworkElement]){
  if($Control.ToolTip -is [string] -and $Control.ToolTip){
   # 0.22.0 B2：HelpTip 会把同一段说明同时写进 ToolTip 与 HelpText。说明不是控件名称，
   # 命中这种情况时不再拿 ToolTip 当标签兜底（否则标签会变成一整段解释）。
   $help=[Windows.Automation.AutomationProperties]::GetHelpText($Control)
   if(-not ($help -and $help -ceq [string]$Control.ToolTip)){return (LimitTCWebFormText $Control.ToolTip 2048)}
  }
  return (LimitTCWebFormText $Control.Name 128)
 }
 return ''
}
function GetTCWebFormTone {param($Control)
 $brush=$null
 if($Control -is [Windows.Controls.TextBlock] -or $Control -is [Windows.Controls.Control]){$brush=$Control.Foreground}
 elseif($Control -is [Windows.Controls.Border]){$brush=$Control.Background}
 if($brush -is [Windows.Media.SolidColorBrush]){
  $color=$brush.Color.ToString().ToUpperInvariant()
  if($Control -is [Windows.Controls.TextBlock] -and $color -in @('#FF4B5360','#FF858C97','#FF657189')){return 'muted'}
  switch($color){
   {$_ -in @('#FF15803D','#FFECF8F0','#FF22A55B')}{return 'ok'}
   {$_ -in @('#FFA15C07','#FFFDF5E8','#FFE19A1D')}{return 'warn'}
   {$_ -in @('#FFB42318','#FFFEF1F0','#FFE5484D','#FFF87171')}{return 'bad'}
   {$_ -in @('#FF1D4ED8','#FFEEF3FE','#FF3B6FF6')}{return 'info'}
  }
 }
 if($Control -is [Windows.Controls.Button]){
  $window=GetTCWebFormVariable 'Window'
  if($window -is [Windows.FrameworkElement]){
   foreach($style in @('Danger','Primary')){
    $resource=$window.TryFindResource($style)
    if($resource -and [object]::ReferenceEquals($Control.Style,$resource)){if($style -eq 'Danger'){return 'bad'};return 'primary'}
   }
  }
 }
 return 'idle'
}
function RegisterTCWebFormControl {param($Control,$Context,[string]$Mode,[bool]$Hidden,[bool]$Closed,[bool]$Enabled)
 $view=$script:TCWebFormView;$id=''
 if(-not $view.ObjectIds.TryGetValue($Control,[ref]$id)){$id='wf-'+[guid]::NewGuid().ToString('N');$view.ObjectIds.Add($Control,$id)}
 $null=$Context.Seen.Add($id)
 $record=[pscustomobject]@{Control=$Control;Mode=$Mode;Hidden=$Hidden;Closed=$Closed;Enabled=$Enabled;ReadOnly=$false;MaxLength=0;Items=@()}
 $view.Handles[$id]=$record
 return $id
}
function NewTCWebFormNote {param([string]$Text,[string]$Tone='warn')
 [pscustomobject][ordered]@{Kind='text';Id='';Name='';Text=$Text;Label='';Disabled=$true;ReadOnly=$true;Tone=$Tone;Level=0;Children=@()}
}
# 0.23.0：图标位/序号位是定宽定高的小方块。只接受「正方形或只给一边」且 ≤96px，
# 其余一律不发 Size，前端回落到 38px 默认值。
function GetTCWebFormTileSize {param($Control)
 $width=0.0;$height=0.0
 try{$width=[double]$Control.Width}catch{$width=0}
 try{$height=[double]$Control.Height}catch{$height=0}
 if([double]::IsNaN($width) -or [double]::IsInfinity($width)){$width=0}
 if([double]::IsNaN($height) -or [double]::IsInfinity($height)){$height=0}
 if($width -gt 0 -and ($height -le 0 -or [Math]::Abs($width-$height) -le 2) -and $width -le 96){return [int][Math]::Round($width)}
 if($height -gt 0 -and $width -le 0 -and $height -le 96){return [int][Math]::Round($height)}
 return 0
}
function ConvertTCWebFormControl {
 param($Control,$Context,[int]$Depth=0,[bool]$Hidden=$false,[bool]$Closed=$false,[bool]$Enabled=$true,[string]$Label='',[switch]$Actions)
 if($null -eq $Control -or (TestTCWebFormExcluded $Control)){return}
 if($Depth -gt 18 -or $Context.Count -ge 2048){$Context.Truncated=$true;return}
 if($Control -is [string]){
  if(-not $Hidden){$Context.Count++;return (NewTCWebFormNote (LimitTCWebFormText $Control 131072 $Context) 'idle')}
  return
 }
 if($Control -isnot [Windows.FrameworkElement]){
  if(-not $Hidden){$Context.Count++;return (NewTCWebFormNote '此内容暂不支持在网页中显示。')};return
 }
 if(-not $Context.Objects.Add($Control)){return}
 $Context.Count++
 # IsVisible reflects the intentionally hidden native shell. Only walk local
 # Visibility, stopping at ContentHost / DeploymentActionHost, never above it.
 $Hidden=($Hidden -or $Control.Visibility -ne [Windows.Visibility]::Visible)
 $Enabled=($Enabled -and $Control.IsEnabled)
 $kind='';$mode='none';$children=@();$nextHidden=$Hidden;$nextClosed=$Closed;$nextEnabled=$Enabled
 $open=$false;$menu=$null;$borderRole='';$iconName=''
 # 0.22.0 B2：HintIcon 生成的 ⓘ 只承载说明文字，不注册句柄、不可执行、不参与业务分发。
 if($Control -is [Windows.Controls.Button] -and $Control.Tag -and $Control.Tag.PSObject.Properties['TCHint']){
  if($Hidden){return}
  $Context.Count++
  return [pscustomobject][ordered]@{Kind='hint';Id='';Name=(LimitTCWebFormText $Control.Name 128 $Context);Text=(LimitTCWebFormText ([string]$Control.Tag.TCHint) 512 $Context);Label='';Disabled=$false;ReadOnly=$true;Tone='idle';Children=@()}
 }
 if($Control -is [Windows.Controls.PasswordBox]){$kind='password';$mode='password'}
 elseif($Control -is [Windows.Controls.TextBox]){$kind='input';$mode='input'}
 elseif($Control -is [Windows.Controls.ComboBox]){$kind='select';$mode='select'}
 elseif($Control -is [Windows.Controls.Primitives.ToggleButton]){$kind='check';$mode='toggle'}
 elseif($Control -is [Windows.Controls.Button]){
  if($Control.ContextMenu){$kind='details';$mode='menudetails';$menu=$Control.ContextMenu;$children=@($menu.Items)}
  else{$kind='button';$mode='button'}
 }
 elseif($Control -is [Windows.Controls.MenuItem]){
  if($Control.Items.Count){$kind='details';$mode='menudetails';$children=@($Control.Items)}
  elseif($Control.IsCheckable){$kind='check';$mode='menucheck'}else{$kind='button';$mode='menuitem'}
 }
 elseif($Control -is [Windows.Controls.Expander]){$kind='details';$mode='expander';$open=[bool]$Control.IsExpanded;$children=@($Control.Content)}
 elseif($Control -is [Windows.Controls.ProgressBar]){$kind='progress'}
 elseif($Control -is [Windows.Controls.TextBlock] -or $Control -is [Windows.Controls.AccessText] -or $Control -is [Windows.Controls.Label]){$kind='text'}
 elseif($Control -is [Windows.Controls.Separator]){$kind='rule'}
 elseif($Control -is [Windows.Controls.Border]){
  # 0.23.0：Border 在 WPF 属性空间里无法区分「卡片 / 图标位 / 标签 / 分组框」。
  # 只认构造点写下的 Tag.TCRole 保留键（与 Tag.TCHint 同构）；未标注 = 现状 card。
  $tag=$Control.Tag
  if($null -ne $tag -and $tag -isnot [string] -and $tag.PSObject.Properties['TCRole']){
   $roleText=[string]$tag.TCRole
   if($roleText -in @('tile','chip','group','card')){$borderRole=$roleText}
  }
  if($Control.Child){$kind='card';$children=@($Control.Child)}elseif($Control.Height -gt 0 -and $Control.Height -le 2){$kind='rule'}else{return}
 }
 elseif($Control -is [Windows.Controls.Grid] -or $Control -is [Windows.Controls.Primitives.UniformGrid]){$kind='grid';$children=@($Control.Children)}
 elseif($Control -is [Windows.Controls.WrapPanel]){
  # 0.22.0 B4：Tag='TCTabs' 的分段按钮组渲染成 role=tablist，而不是普通横排。
  if($Control.Tag -is [string] -and $Control.Tag -eq 'TCTabs'){$kind='tabs';$children=@($Control.Children)}
  else{$kind='row';$children=@($Control.Children)}
 }
 elseif($Control -is [Windows.Controls.StackPanel]){$kind=if($Control.Orientation -eq 'Horizontal'){'row'}else{'panel'};$children=@($Control.Children)}
 elseif($Control -is [Windows.Controls.Panel]){$kind='panel';$children=@($Control.Children)}
 elseif($Control -is [Windows.Controls.ScrollViewer]){$kind='panel';$children=@($Control.Content)}
 elseif($Control -is [Windows.Controls.Viewbox] -and $null -ne $Control.Tag -and $Control.Tag -isnot [string] -and $Control.Tag.PSObject.Properties['TCIcon']){
  # 0.23.0：Icon() 在 Viewbox 上挂 Tag.TCIcon。图形本体是 Canvas→Path，Path 是
  # Shape，会被下面的分支丢弃；只有名字能安全过线，前端按白名单还原同一份几何。
  $kind='icon';$iconName=[string]$Control.Tag.TCIcon
 }
elseif($Control -is [Windows.Controls.Decorator] -or $Control -is [Windows.Controls.Viewbox]){$kind='panel';$children=@($Control.Child)}
 elseif($Control -is [Windows.Controls.GroupBox]){$kind='card';$children=@($Control.Content)}
 elseif($Control -is [Windows.Controls.ContentControl]){$kind='panel';$children=@($Control.Content)}
 elseif($Control -is [Windows.Shapes.Shape] -or $Control -is [Windows.Controls.Image]){return}
 else{$kind='unsupported'}

 if($Actions -and $mode -in @('button','menuitem','toggle','menucheck','menudetails')){
  $controls=GetTCWebFormVariable 'Controls'
  if(-not $Control.Name -or $controls -isnot [Collections.IDictionary] -or -not $controls.Contains($Control.Name) -or -not [object]::ReferenceEquals($controls[$Control.Name],$Control)){return}
 }
 $id=RegisterTCWebFormControl $Control $Context $mode $Hidden $Closed $Enabled
 $record=$script:TCWebFormView.Handles[$id]
 if($mode -eq 'menudetails'){
  if($script:TCWebFormView.OpenMenus.ContainsKey($id)){$open=$script:TCWebFormView.OpenMenus[$id]}
  if($menu){$nextHidden=($Hidden -or $menu.Visibility -ne [Windows.Visibility]::Visible);$nextEnabled=($Enabled -and $menu.IsEnabled)}
 }
 if($kind -eq 'details'){$nextClosed=($Closed -or -not $open)}
 $childNodes=New-Object 'Collections.Generic.List[object]';$childLabel=$Label
 foreach($child in $children){
  if($Context.Count -ge 2048){$Context.Truncated=$true;break}
  if($mode -eq 'menudetails' -and $child -isnot [Windows.Controls.MenuItem] -and $child -isnot [Windows.Controls.Separator]){
   $Context.Count++
   if(-not $nextHidden){$childNodes.Add((NewTCWebFormNote '此菜单项暂不支持在网页中操作。'))};continue
  }
  $projected=ConvertTCWebFormControl $child $Context ($Depth+1) $nextHidden $nextClosed $nextEnabled $childLabel -Actions:$Actions
  if($null -ne $projected){
   $childNodes.Add($projected)
   if($projected.Kind -eq 'text' -and $projected.Text){$childLabel=$projected.Text}
   elseif($projected.Kind -in @('panel','row') -and -not $childLabel){$childLabel=GetTCWebFormControlText $child}
  }
 }
 if($Hidden){return}
 if($kind -in @('panel','row','grid','card') -and -not $childNodes.Count){return}
 $interactive=($mode -ne 'none')
 $readonly=($interactive -and $mode -notin @('expander','menudetails') -and $Context.ReadOnly)
 $queued=($Context.Queued -and $mode -in @('button','menuitem','toggle','menucheck'))
 $node=[ordered]@{
  Kind=$kind;Id=$id;Name=(LimitTCWebFormText $Control.Name 128 $Context);Text='';Label=''
  Disabled=[bool](-not $Enabled -or $Closed -or ($interactive -and $Context.Busy) -or $readonly -or $queued)
  ReadOnly=[bool]$readonly;Tone=(GetTCWebFormTone $Control);Children=$childNodes.ToArray()
 }
 switch($kind){
  'input'{
   $max=131072;if($Control.MaxLength -gt 0){$max=[Math]::Min($max,$Control.MaxLength)}
   $record.MaxLength=$max;$record.ReadOnly=([bool]$Control.IsReadOnly -or $Control.Text.Length -gt $max)
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $Label) 2048 $Context
   $node.Value=LimitTCWebFormText $Control.Text 131072 $Context
   if($node.Value.Length -lt $Control.Text.Length){$record.ReadOnly=$true}
   $node.ReadOnly=($node.ReadOnly -or $record.ReadOnly);$node.Multiline=[bool]$Control.AcceptsReturn;$node.MaxLength=$max
  }
  'password'{
   $max=4096;if($Control.MaxLength -gt 0){$max=[Math]::Min($max,$Control.MaxLength)};$record.MaxLength=$max
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $Label) 2048 $Context;$node.MaxLength=$max
   $secret=$Control.SecurePassword
   try{$node.SecretPresent=($secret.Length -gt 0)}finally{if($secret){$secret.Dispose()}}
   # Deliberately no Value, Password, length, draft, mirror, or credential data.
  }
  'select'{
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $Label) 2048 $Context
   $node.Value=[int]$Control.SelectedIndex;$items=New-Object 'Collections.Generic.List[object]'
   for($i=0;$i -lt [Math]::Min($Control.Items.Count,1024);$i++){
    $item=$Control.Items[$i];$itemText=GetTCWebFormControlText $item;$disabled=$false
    if($item -is [Windows.UIElement]){$disabled=(-not $item.IsEnabled -or $item.Visibility -ne [Windows.Visibility]::Visible)}
    if(-not $itemText){$itemText='此选项暂不支持';$disabled=$true}
    $items.Add([pscustomobject]@{Index=$i;Label=(LimitTCWebFormText $itemText 2048 $Context);Disabled=[bool]$disabled})
   }
   if($Control.Items.Count -gt 1024){$Context.Truncated=$true}
   $node.Items=$items.ToArray();$record.Items=$node.Items
   # ComboBox.IsReadOnly controls its optional text editor, not index selection.
   # Only explicit items are exposed; neither Text entry nor SelectedValue is accepted.
  }
  'check'{
   $caption=GetTCWebFormControlText $Control
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $(if($caption){$caption}else{$Label})) 2048 $Context
   if(-not $node.Label){$node.Label='选项'}
   $node.HasCaption=[bool]$caption;$node.Text=LimitTCWebFormText $caption 2048 $Context
   $node.Value=[bool]$Control.IsChecked;$node.Radio=($Control -is [Windows.Controls.RadioButton])
  }
  'button'{
   $caption=GetTCWebFormControlText $Control;$node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $caption) 2048 $Context
   $node.Text=if($caption){LimitTCWebFormText $caption 2048 $Context}else{$node.Label}
   if(-not $node.Text){$node.Kind='text';$node.Text='此操作缺少显示名称，暂不可用。';$node.Disabled=$true;$node.Tone='warn';$record.Mode='none'}
  }
  'details'{
   $caption=GetTCWebFormControlText $Control
   if($mode -eq 'menudetails' -and $caption -match '^[\s\u2026\u22ef.]+$'){$caption=''}
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $caption) 2048 $Context
   if(-not $node.Label){$node.Label='详情'};$node.Text=$node.Label;$node.Open=[bool]$open
   if(-not $childNodes.Count){$node.Children=@(NewTCWebFormNote '此处暂无可显示的内容或可用操作。')}
  }
  'text'{
   $node.Text=LimitTCWebFormText (GetTCWebFormControlText $Control) 131072 $Context;$node.Level=0
   if($Control -is [Windows.Controls.TextBlock]){
    if($Control.FontSize -ge 20){$node.Level=2}elseif($Control.FontSize -ge 15 -and $Control.FontWeight.ToOpenTypeWeight() -ge 600){$node.Level=3}
   }
  }
  'grid'{
   if($Control -is [Windows.Controls.Grid]){
    $columns=[Math]::Min(12,[Math]::Max(1,$Control.ColumnDefinitions.Count));$node.Columns=$columns
    # 0.23.0：列宽语义（* / Auto / 固定像素）是布局意图本身，只发列数会退化成
    # 「按列数猜」。响应式布局会改写 ColumnDefinitions，所以每次都直读当前值。
    $specs=New-Object 'Collections.Generic.List[string]'
    for($index=0;$index -lt $columns;$index++){
     $width=$Control.ColumnDefinitions[$index].Width
     if($width.IsStar){$specs.Add('*')}
     elseif($width.IsAuto){$specs.Add('Auto')}
     elseif($width.IsAbsolute){$specs.Add(([string][int][Math]::Round([Math]::Min(512,[Math]::Max(1,$width.Value))))+'px')}
     else{$specs.Add('Auto')}
    }
    $node.Cols=$specs.ToArray()
   }
   else{$node.Columns=[Math]::Min(12,[Math]::Max(1,$Control.Columns))}
  }
  'card'{
   if($borderRole){
    $node.Role=$borderRole
    if($borderRole -eq 'tile'){
     $edge=GetTCWebFormTileSize $Control
     if($edge -gt 0){$node.Size=$edge}
    }
   }
  }
  'icon'{$node.Icon=$iconName}
  'progress'{
   $node.Label=LimitTCWebFormText (GetTCWebFormLabel $Control $Label) 2048 $Context;$node.Indeterminate=[bool]$Control.IsIndeterminate;$node.Value=$null
   if(-not $Control.IsIndeterminate){$range=$Control.Maximum-$Control.Minimum;$node.Value=if($range -gt 0){[Math]::Round([Math]::Min(100,[Math]::Max(0,100*($Control.Value-$Control.Minimum)/$range)),2)}else{0}}
  }
  'unsupported'{$node.Kind='text';$node.Text='此控件暂不支持在网页中操作。';$node.Tone='warn';$node.Disabled=$true;$node.ReadOnly=$true;$node.Level=0}
 }
 if($Control.Parent -is [Windows.Controls.Grid]){
  $node.Row=[Math]::Min(64,[Windows.Controls.Grid]::GetRow($Control));$node.Column=[Math]::Min(12,[Windows.Controls.Grid]::GetColumn($Control))
  $node.RowSpan=[Math]::Min(64,[Windows.Controls.Grid]::GetRowSpan($Control));$node.ColumnSpan=[Math]::Min(12,[Windows.Controls.Grid]::GetColumnSpan($Control))
 }
 # 0.23.0：HorizontalAlignment 默认是 Stretch，只有显式 Left/Right/Center 才是意图。
 # 不发 Stretch，避免把「未设置」写成一条覆盖 CSS 的强断言。
 $align=switch([string]$Control.HorizontalAlignment){'Right'{'end'}'Center'{'center'}'Left'{'start'}default{''}}
 if($align){$node.Align=$align}
 # 0.22.0 B2：HelpText → Hint（≤512 字）。ToolTip 单独存在时不转，避免把鼠标提示当说明。
 $help=[Windows.Automation.AutomationProperties]::GetHelpText($Control)
 if($help){$node.Hint=(LimitTCWebFormText $help 512 $Context)}
 return [pscustomobject]$node
}
function AddTCWebFormActionHost {
 param($Window,[string]$HostName,$Context,$Target,[bool]$Enabled=$true)
 # 页面操作条：宿主自身的 Visibility 就是显示开关，页面不需要额外的「是否显示」变量。
 # 复用部署路径的 -Actions 过滤（只放行已注册且引用相等的按钮），避免把偶然放进
 # 宿主里的普通控件暴露成吸底操作。
 $panel=$null
 if($Window -is [Windows.FrameworkElement]){$panel=$Window.FindName($HostName)}
 if($panel -isnot [Windows.Controls.Panel]){return}
 # 折叠判断看宿主自身和它的直接父级：调用方折叠的是外层 Border（PageActionBar），宿主是
 # 它的子 WrapPanel。再往上就是被 WebView2 遮住的原生外壳，那一层折叠是常态，不能当开关。
 $hostHidden=($panel.Visibility -ne [Windows.Visibility]::Visible)
 if(-not $hostHidden -and $panel.Parent -is [Windows.FrameworkElement]){$hostHidden=($panel.Parent.Visibility -ne [Windows.Visibility]::Visible)}
 $hostEnabled=($Enabled -and $panel.IsEnabled)
 foreach($child in $panel.Children){
  $node=ConvertTCWebFormControl $child $Context 0 $hostHidden $false $hostEnabled '' -Actions
  if($null -ne $node){$Target.Add($node)}
 }
}
function GetTCWebFormSnapshot {
 $view=$script:TCWebFormView;if(-not $view){return $null}
 $context=@{
  Seen=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal));Objects=(New-Object 'Collections.Generic.HashSet[object]')
  Count=0;TextLeft=1048576;Truncated=$false;Busy=(TestTCWebFormBusy);Queued=(TestTCWebFormQueued);ReadOnly=[bool](GetTCWebFormVariable 'ReadOnly')
 }
 $nodes=New-Object 'Collections.Generic.List[object]';$actions=New-Object 'Collections.Generic.List[object]';$pageActions=New-Object 'Collections.Generic.List[object]'
 $hostPanel=GetTCWebFormVariable 'HostPanel'
 if($hostPanel -is [Windows.Controls.Panel]){
  $children=@($hostPanel.Children);$skip=0
  foreach($heading in @($view.Title,$view.Description)){
   if($heading -and $skip -lt $children.Count -and $children[$skip] -is [Windows.Controls.TextBlock] -and -not $children[$skip].Name -and $children[$skip].Text -ceq $heading){$skip++}
  }
  for($i=$skip;$i -lt $children.Count;$i++){
   $node=ConvertTCWebFormControl $children[$i] $context 0 ($hostPanel.Visibility -ne [Windows.Visibility]::Visible) $false ([bool]$hostPanel.IsEnabled)
   if($null -ne $node){$nodes.Add($node)}
  }
 }
 $flow=GetTCWebFormVariable 'DeployUI';$controls=GetTCWebFormVariable 'Controls';$formId=''
 $isForm=([string](GetTCWebFormVariable 'Page') -ceq 'setup' -and [string](GetTCWebFormVariable 'Role') -ceq 'deployment' -and $flow -and (-not $flow.Run -or $flow.Reauth))
 if($isForm -and $controls -is [Collections.IDictionary] -and $controls.Contains('DeployConnectionText') -and $view.ObjectIds.TryGetValue($controls['DeployConnectionText'],[ref]$formId) -and $context.Seen.Contains($formId)){
  $form=$view.Handles[$formId];$window=GetTCWebFormVariable 'Window';$actionHost=$null
  if($window -is [Windows.FrameworkElement]){$actionHost=$window.FindName('DeploymentActionHost')}
  if($actionHost -is [Windows.Controls.Panel]){
   foreach($child in $actionHost.Children){
    # DeploymentActionBar.Visibility binds to card.IsVisible and is Collapsed
    # behind the web shell. Current flow + registered form controls are the gate.
    $node=ConvertTCWebFormControl $child $context 0 ($form.Hidden -or $actionHost.Visibility -ne [Windows.Visibility]::Visible) $form.Closed ($form.Enabled -and $actionHost.IsEnabled) '' -Actions
    if($null -ne $node){$actions.Add($node)}
   }
  }
 }
 # 页面操作条（例如名单页的「保存 / 放弃修改」）走独立字段，Actions 保持部署专用。
 # 必须先投影再回收：它不在 HostPanel 里，放在回收之后会让它每一帧都被判成「已消失」，
 # 句柄和对象映射一起删掉、下一帧重新发一个新 Id。浏览器点的是上一帧的 Id，宿主永远
 # 查不到（UnknownId），前端又没有这个错误码的提示，表现就是「点了没反应」。
 $window=GetTCWebFormVariable 'Window'
 AddTCWebFormActionHost -Window $window -HostName 'PageActionHost' -Context $context -Target $pageActions -Enabled ([bool]$hostPanel.IsEnabled)
 foreach($id in @($view.Handles.Keys)){
  if(-not $context.Seen.Contains($id)){
   $control=$view.Handles[$id].Control;$null=$view.Handles.Remove($id);$null=$view.ObjectIds.Remove($control);$null=$view.OpenMenus.Remove($id)
  }
 }
 if($context.Truncated){$nodes.Add((NewTCWebFormNote '页面内容较多，部分内容已省略；请使用筛选缩小范围。'))}
 # PSCustomObject is intentional: the web shell adds ParentPage / ViewKey.
 return [pscustomobject][ordered]@{Generation=$view.Generation;Title=$view.Title;Description=$view.Description;Page=$view.Page;Nodes=$nodes.ToArray();Actions=$actions.ToArray();PageActions=$pageActions.ToArray()}
}
function NewTCWebFormResult {param([bool]$Ok,[string]$Code) [pscustomobject]@{Ok=$Ok;Code=$Code}}
function InvokeTCWebFormAction {
 # Untyped wire arguments are intentional: validation precedes every cast, so
 # objects, arrays, strings-as-booleans and fractional indices cannot coerce.
 param($Generation,$Id,$Event,$Value)
 if($Generation -isnot [string] -or $Generation.Length -ne 32 -or $Generation -cnotmatch '^[0-9a-f]{32}$'){return (NewTCWebFormResult $false 'InvalidGeneration')}
 if(-not $script:TCWebFormView -or $Generation -cne $script:TCWebFormView.Generation){return (NewTCWebFormResult $false 'StaleGeneration')}
 if($Id -isnot [string] -or $Id.Length -ne 35 -or $Id -cnotmatch '^wf-[0-9a-f]{32}$'){return (NewTCWebFormResult $false 'InvalidId')}
 if($Event -isnot [string] -or $Event -cnotin @('click','change','expand')){return (NewTCWebFormResult $false 'InvalidEvent')}
 try{
  # Rebuild membership and effective state at dispatch time, even if no timer
  # snapshot has run since a worker updated, hid, disabled or removed a control.
  $null=GetTCWebFormSnapshot;$view=$script:TCWebFormView
  if(-not $view.Handles.ContainsKey($Id)){return (NewTCWebFormResult $false 'UnknownId')}
  $record=$view.Handles[$Id];$control=$record.Control
  if($record.Hidden){return (NewTCWebFormResult $false 'Hidden')}
  if($record.Closed){return (NewTCWebFormResult $false 'Collapsed')}
  if(-not $record.Enabled){return (NewTCWebFormResult $false 'Disabled')}
  if(TestTCWebFormBusy){return (NewTCWebFormResult $false 'Busy')}
  $allowed=switch($record.Mode){
   'button'{'click'};'menuitem'{'click'};'toggle'{'change'};'menucheck'{'change'};'input'{'change'};'password'{'change'};'select'{'change'};'expander'{'expand'};'menudetails'{'expand'};default{''}
  }
  if($Event -cne $allowed){return (NewTCWebFormResult $false 'UnsupportedEvent')}
  if($Event -ne 'expand' -and ((GetTCWebFormVariable 'ReadOnly') -or $record.ReadOnly)){return (NewTCWebFormResult $false 'ReadOnly')}
  if($record.Mode -in @('button','menuitem','toggle','menucheck') -and (TestTCWebFormQueued)){return (NewTCWebFormResult $false 'Queued')}
  switch($record.Mode){
   {$_ -in @('button','menuitem')}{
    if($null -ne $Value){return (NewTCWebFormResult $false 'InvalidValue')}
    $routed=if($record.Mode -eq 'menuitem'){[Windows.Controls.MenuItem]::ClickEvent}else{[Windows.Controls.Primitives.ButtonBase]::ClickEvent}
    $control.RaiseEvent((New-Object Windows.RoutedEventArgs($routed,$control)))
   }
   {$_ -in @('input','password')}{
    if($Value -isnot [string]){return (NewTCWebFormResult $false 'InvalidValue')}
    if($Value.Length -gt $record.MaxLength){return (NewTCWebFormResult $false 'ValueTooLarge')}
    if($record.Mode -eq 'password'){$control.Password=$Value}else{$control.Text=$Value}
   }
   'select'{
    if($Value -isnot [int] -and $Value -isnot [long]){return (NewTCWebFormResult $false 'InvalidValue')}
    if($Value -lt 0 -or $Value -ge $record.Items.Count -or $record.Items[[int]$Value].Disabled){return (NewTCWebFormResult $false 'InvalidValue')}
    $control.SelectedIndex=[int]$Value
   }
   {$_ -in @('toggle','menucheck')}{
    if($Value -isnot [bool] -or ($control -is [Windows.Controls.RadioButton] -and -not $Value)){return (NewTCWebFormResult $false 'InvalidValue')}
    $control.IsChecked=$Value
    $routed=if($record.Mode -eq 'menucheck'){[Windows.Controls.MenuItem]::ClickEvent}else{[Windows.Controls.Primitives.ButtonBase]::ClickEvent}
    $control.RaiseEvent((New-Object Windows.RoutedEventArgs($routed,$control)))
   }
   'expander'{if($Value -isnot [bool]){return (NewTCWebFormResult $false 'InvalidValue')};$control.IsExpanded=$Value}
   'menudetails'{if($Value -isnot [bool]){return (NewTCWebFormResult $false 'InvalidValue')};$view.OpenMenus[$Id]=$Value}
  }
  return (NewTCWebFormResult $true 'Applied')
 }catch{
  # WPF event exceptions may quote an input value. Do not send them to JS.
  return (NewTCWebFormResult $false 'ActionFailed')
 }finally{$Value=$null}
}
