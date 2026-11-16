#requires -Version 5.1
#requires -PSEdition Desktop
[CmdletBinding()]
param([string]$PackageRoot='',[string]$ReportDirectory='')
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run Test-WebForms.ps1 with Windows PowerShell -Sta.'}
if(-not $PackageRoot){$PackageRoot=Split-Path $PSScriptRoot -Parent}
$script:PackageRoot=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
# Release packages omit tests; inspect the running harness independently of the package.
$checkedFiles=[ordered]@{'ui\WebForms.ps1'=(Join-Path $script:PackageRoot 'ui\WebForms.ps1');'tests\Test-WebForms.ps1'=$PSCommandPath}
if(-not $ReportDirectory){$ReportDirectory=Join-Path (Split-Path (Split-Path $script:PackageRoot -Parent) -Parent) 'reports\ux-feedback-20261016\adapter-tests'}
$report=[IO.Path]::GetFullPath($ReportDirectory).TrimEnd('\')
if($report -notmatch '^[A-Za-z]:\\' -or $report -like 'C:\tradechannel*'){throw 'Reports require an isolated local directory.'}
$cursor=$report
while($cursor){
 if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Report paths cannot cross reparse points.'}}
 $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
}
$null=[IO.Directory]::CreateDirectory($report)
$encoding=New-Object Text.UTF8Encoding($true)
$script:Checks=New-Object 'Collections.Generic.List[string]'
$script:LoadedSources=New-Object 'Collections.Generic.List[object]'
$script:DeniedActors=New-Object 'Collections.Generic.List[string]'
$script:CapturedRequests=New-Object 'Collections.Generic.List[object]'
$script:Window=$null;$passed=$false;$failure='';$failureAt=''
function Check {param([bool]$Condition,[string]$Message)
 if(-not $Condition){throw ('WebForms assertion failed: '+$Message)};$script:Checks.Add($Message)
}
function ImportPresentationFunctions {param([string]$File,[string[]]$Names)
 $path=Join-Path $script:PackageRoot $File;$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw ('Parser errors in '+$File)}
 $script:LoadedSources.Add([pscustomobject]@{File=$File;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Functions=$Names})
 foreach($name in $Names){
  $matches=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -ceq $name)
  if($matches.Count -ne 1){throw ('Missing fixture presentation function: '+$name)}
  $body=$matches[0].Body.Extent.Text
  Set-Item -Path ('Function:script:'+$name) -Value ([scriptblock]::Create($body.Substring(1,$body.Length-2)))
 }
}
function IsBusy {return [bool]$script:FixtureBusy}
function StartJob {param([hashtable]$Request,[scriptblock]$Complete,[string]$Message='',[string]$Transition='',[switch]$Silent,[scriptblock]$Failed=$null,$CallbackContext=$null)
 # Capture only. No Worker.ps1, process, pipe, network API or deployment module
 # is imported. Model the foreground queue behind an already-running silent job.
 $entry=[pscustomobject]@{Request=$Request;Silent=[bool]$Silent;Complete=$Complete}
 $script:CapturedRequests.Add($entry)
 if($script:Job){$script:JobQueue.Enqueue($entry)}else{$script:Job=$entry}
}
function StartProductDeployment {
 $script:SubmitCalls++
 StartJob @{Action='FixtureDeployment';Host=$script:Controls.DeployConnectionText.Text} {}
}
function PageHead {param([string]$Title,[string]$Description,[string]$Page)
 $script:HostPanel.Children.Clear();$script:Controls=@{};$script:Page=$Page
 StartTCWebFormView -Title $Title -Description $Description -Page $Page
 if($Title){AddC $script:HostPanel (T $Title 24 $script:Ink 'SemiBold')}
 if($Description){AddC $script:HostPanel (T $Description 13 $script:Text3)}
}
function ResetFixture {param([string]$Title='适配器夹具',[string]$Description='本地控件，不启动业务 worker。',[string]$Page='fixture')
 $script:FixtureBusy=$false;$script:ReadOnly=$false;$script:Smoke=$true;$script:Job=$null
 $script:JobQueue=New-Object 'Collections.Generic.Queue[object]';$script:CapturedRequests.Clear()
 $script:Role='fixture';$script:DeployUI=@{Intent='Auto';Screen='connect';Run=$null;Reauth=$false;FormDraft=@{};HistoryLoaded=$true;HistoryRecords=@();HistorySelectedIds=@()}
 $script:Window.FindName('DeploymentActionHost').Children.Clear()
 $script:Window.FindName('PageActionHost').Children.Clear()
 $script:Window.FindName('PageActionBar').Visibility='Collapsed'
 $script:HostPanel.IsEnabled=$true;$script:HostPanel.Visibility='Visible'
 PageHead $Title $Description $Page
}
function FlattenNodes {param($Nodes)
 foreach($node in $Nodes){$node;if($node.Children){FlattenNodes $node.Children}}
}
function FindNode {param($Snapshot,[string]$Name)
 $matches=@(FlattenNodes (@($Snapshot.Nodes)+@($Snapshot.Actions))|Where-Object Name -ceq $Name)
 if($matches.Count -ne 1){throw ('Expected one node named '+$Name+'; found '+$matches.Count)}
 return $matches[0]
}
function InvokeNamed {param([string]$Name,[string]$Event,$Value=$null)
 $snapshot=GetTCWebFormSnapshot;$node=FindNode $snapshot $Name
 InvokeTCWebFormAction -Generation $snapshot.Generation -Id $node.Id -Event $Event -Value $Value
}
function CheckCode {param($Result,[string]$Expected,[string]$Message)
 Check ($Result.Code -ceq $Expected -and $Result.Ok -eq ($Expected -ceq 'Applied')) ($Message+' ['+$Expected+']')
}
function SaveSnapshot {param([string]$Name,$Snapshot)
 $json=$Snapshot|ConvertTo-Json -Depth 48
 Check ($json -notmatch 'FIXTURE_SECRET|PRIVATE_TAG|PRIVATE_OBJECT|PasswordPlainText|PasswordReveal|SecureString|System.Windows') ('Sanitized serialized snapshot '+$Name)
 [IO.File]::WriteAllText((Join-Path $report ($Name+'.json')),$json,$encoding)
}
try{
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 foreach($name in @('Start-Process','Start-Job','Invoke-WebRequest','Invoke-RestMethod','RunWorker','PollJob','StartUiCommand','Invoke-TCDeployPipe','Start-TCDeploySession','Set-TCDeployCredential','Start-TCConnection','Stop-TCConnection','ChooseFile','ChooseSave')){
  Set-Item -Path ('Function:script:'+$name) -Value {$script:DeniedActors.Add($MyInvocation.MyCommand.Name);throw ('Forbidden real actor: '+$MyInvocation.MyCommand.Name)}
 }
 $script:Window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:PackageRoot 'ui\Shell.xaml')))
 $script:HostPanel=$script:Window.FindName('ContentHost')
 $script:Window.FindName('Scroll').Parent.Visibility='Collapsed'
 $script:Ink='#15181D';$script:Text2='#4B5360';$script:Text3='#858C97';$script:Hair='#E6E8EB'
 $script:Tone=@{ok=@{Fg='#15803D';Bg='#ECF8F0'};warn=@{Fg='#A15C07';Bg='#FDF5E8'};bad=@{Fg='#B42318';Bg='#FEF1F0'};info=@{Fg='#1D4ED8';Bg='#EEF3FE'};idle=@{Fg='#4B5360';Bg='#F2F3F5'}}
 ImportPresentationFunctions 'TradeChannel.ps1' @('B','AddC','T','Stack','Card','Margin','Grid','Cell','ControlName','Btn','Icon','IconTile','Rule','HelpTip','HintIcon','TitleWithHint','Pill','SectionLabel')
 ImportPresentationFunctions 'ui\ConnectionProfilePages.ps1' @('ProfileUIField')
 ImportPresentationFunctions 'ui\Pages.ps1' @('Head','Note','Tx')
 ImportPresentationFunctions 'ui\SetupPages.ps1' @('SetupCardHeader')
 ImportPresentationFunctions 'ui\DeploymentPages.ps1' @('GetDeploymentCredentialDraftUI','GetDeploymentPasswordSelectionUI','SetDeploymentPasswordVisibilityUI','ClearDeploymentCredentialDraftUI','ClearDeploymentCredentialUI','AddDeploymentPasswordEditorUI','DeploymentField','DeploymentActions','AddDeploymentCredentialNoticeUI','AddDeploymentTaskCredentialReadNoticeUI','AddDeploymentAbandonActionUI','ShowProductDeployment')
 ImportPresentationFunctions 'ui\OperationHistoryPages.ps1' @('RecordIsDeleted','RecordCanDelete','GetFilteredOperationHistoryUI','UpdateHistorySelectionUI','SelectAllOperationHistoryUI','ShowUnifiedOperationHistory','ShowDiscardedDraftHistoryUI')
 . (Join-Path $script:PackageRoot 'ui\WebForms.ps1')
 foreach($file in $checkedFiles.Keys){
  $bytes=[IO.File]::ReadAllBytes($checkedFiles[$file]);Check ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF-8 BOM '+$file)
  $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($checkedFiles[$file],[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) ('Windows PowerShell 5.1 parser '+$file)
 }
 Check ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSEdition -eq 'Desktop') 'Runs on Windows PowerShell 5.1 Desktop'
 Check ($null -eq (GetTCWebFormSnapshot)) 'No snapshot before a view starts'
 ResetFixture
 Check (-not $script:HostPanel.IsVisible -and $script:HostPanel.Visibility -eq 'Visible') 'Native shell is hidden while business host local Visibility stays Visible'
 $pageBefore=$script:Page;StartTCWebFormView '适配器夹具' '本地控件，不启动业务 worker。' 'different-projection-page'
 Check ($script:Page -ceq $pageBefore) 'Starting an adapter view preserves script:Page'
 ResetFixture
 $card=ControlName (Card) 'FixtureCard';$panel=Stack;$card.Child=$panel;AddC $script:HostPanel $card
 AddC $panel (ControlName (T '业务区标题' 20 $script:Ink 'SemiBold') 'BodyHeading')
 foreach($color in @('4B5360','858C97','657189')){AddC $panel (ControlName (T '辅助说明' 13 ('#'+$color)) ('Muted'+$color))}
 AddC $panel (ControlName (T '错误说明' 13 '#B42318') 'ErrorText')
 $script:ButtonClicks=0;$button=Btn '执行现有事件' 'OriginalButton' {$script:ButtonClicks++};$button.Tag=@{Secret='PRIVATE_TAG_button'}
 $button.Foreground=B '#4B5360'
 $button|Add-Member NoteProperty PrivateObject 'PRIVATE_OBJECT_button';AddC $panel $button
 AddC $panel (T '输入标签');$input=ControlName (New-Object Windows.Controls.TextBox) 'Input';$input.Text='initial';$input.MaxLength=16;$input.Tag='PRIVATE_TAG_input';AddC $panel $input
 $script:TextChanges=0;$input.Add_TextChanged({$script:TextChanges++;$script:ChangedText=$this.Text})
 $read=ControlName (New-Object Windows.Controls.TextBox) 'ReadOnlyText';$read.Text="第一行`r`n第二行";$read.IsReadOnly=$true;$read.AcceptsReturn=$true;AddC $panel $read
 AddC $panel (T '服务器密码');AddDeploymentPasswordEditorUI $panel
 $password=$script:Controls.DeployPassword;$password.Password='FIXTURE_SECRET_  密码 $ ! '
 $plain=$script:Controls.DeployPasswordPlainText;$plain.Visibility='Visible';$plain.Text='FIXTURE_SECRET_visible_mirror'
 $script:Controls.DeployPasswordReveal.Visibility='Visible'
 $combo=ControlName (New-Object Windows.Controls.ComboBox) 'Select';$combo.IsEditable=$true;$combo.IsReadOnly=$true
 $null=$combo.Items.Add('第一个');$enabledItem=New-Object Windows.Controls.ComboBoxItem;$enabledItem.Content='第二个';$enabledItem.Tag='PRIVATE_TAG_option';$null=$combo.Items.Add($enabledItem)
 $disabledItem=New-Object Windows.Controls.ComboBoxItem;$disabledItem.Content='禁用';$disabledItem.IsEnabled=$false;$null=$combo.Items.Add($disabledItem)
 $hiddenItem=New-Object Windows.Controls.ComboBoxItem;$hiddenItem.Content='隐藏';$hiddenItem.Visibility='Collapsed';$null=$combo.Items.Add($hiddenItem)
 $null=$combo.Items.Add([pscustomobject]@{Private='PRIVATE_OBJECT_option'});$combo.SelectedIndex=0;AddC $panel $combo
 $script:Selections=0;$combo.Add_SelectionChanged({$script:Selections++;$script:Selected=$this.SelectedIndex})
 $check=ControlName (New-Object Windows.Controls.CheckBox) 'Check';$check.Content='记住选择';$check.IsChecked=$false;AddC $panel $check
 [Windows.Automation.AutomationProperties]::SetName($check,'记住登录选择（辅助标签）')
 $script:CheckClicks=0;$script:CheckedEvents=0;$check.Add_Click({$script:CheckClicks++;$script:ClickObservedState=$this.IsChecked});$check.Add_Checked({$script:CheckedEvents++})
 $captionGroup=Stack;AddC $captionGroup (T '桌面程序')
 $bareCheck=ControlName (New-Object Windows.Controls.CheckBox) 'CaptionlessCheck';AddC $captionGroup $bareCheck
 $namedCheck=ControlName (New-Object Windows.Controls.CheckBox) 'NamedCaptionlessCheck';[Windows.Automation.AutomationProperties]::SetName($namedCheck,'Claude');AddC $captionGroup $namedCheck;AddC $panel $captionGroup
 $radio1=ControlName (New-Object Windows.Controls.RadioButton) 'RadioOne';$radio1.Content='UDP';$radio1.GroupName='fixture';$radio1.IsChecked=$true;AddC $panel $radio1
 $radio2=ControlName (New-Object Windows.Controls.RadioButton) 'RadioTwo';$radio2.Content='TCP';$radio2.GroupName='fixture';AddC $panel $radio2;$script:RadioChecked=0;$radio2.Add_Checked({$script:RadioChecked++})
 $scroll=ControlName (New-Object Windows.Controls.ScrollViewer) 'NestedScroll';$wrap=ControlName (New-Object Windows.Controls.WrapPanel) 'Wrapped';$scroll.Content=$wrap
 $grid=ControlName (Grid @('*','*')) 'NestedGrid';AddC $wrap $grid;Cell $grid (ControlName (T '网格内容') 'GridText') 1;AddC $panel $scroll
 AddC $panel (ControlName (Rule) 'Divider')
 $progress=ControlName (New-Object Windows.Controls.ProgressBar) 'Progress';$progress.Minimum=20;$progress.Maximum=220;$progress.Value=120;AddC $panel $progress
 $indeterminate=ControlName (New-Object Windows.Controls.ProgressBar) 'Indeterminate';$indeterminate.IsIndeterminate=$true;AddC $panel $indeterminate
 $unsupported=ControlName (New-Object Windows.Controls.Slider) 'Unsupported';AddC $panel $unsupported
 $snapshot=GetTCWebFormSnapshot;$all=@(FlattenNodes $snapshot.Nodes)
 Check ($snapshot -is [pscustomobject] -and $snapshot.Generation -cmatch '^[0-9a-f]{32}$') 'Snapshot is a PSCustomObject with random generation'
 $snapshot|Add-Member NoteProperty ParentPage 'home';$snapshot|Add-Member NoteProperty ViewKey 'fixture'
 Check ($snapshot.ParentPage -ceq 'home' -and $snapshot.ViewKey -ceq 'fixture') 'Bridge can attach ParentPage and ViewKey'
 Check (@($snapshot.Nodes).Count -eq 1 -and $snapshot.Nodes[0].Kind -ceq 'card') 'Page heading and description are skipped, not duplicated'
 Check ((FindNode $snapshot 'BodyHeading').Level -eq 2) 'Business headings retain a semantic level'
 Check ((FindNode $snapshot 'BodyHeading').Tone -ceq 'idle') 'Normal ink text keeps its existing tone'
 foreach($color in @('4B5360','858C97','657189')){Check ((FindNode $snapshot ('Muted'+$color)).Tone -ceq 'muted') ('Secondary TextBlock color maps to muted #'+$color)}
 Check ((FindNode $snapshot 'ErrorText').Tone -ceq 'bad') 'Semantic error text retains its bad tone'
 Check ((FindNode $snapshot 'OriginalButton').Tone -ceq 'idle') 'Muted text color mapping does not change non-TextBlock control tones'
 Check ((FindNode $snapshot 'OriginalButton').Text -ceq '执行现有事件') 'Original button text is projected'
 Check ((FindNode $snapshot 'Input').Label -ceq '输入标签') 'Adjacent text labels an input'
 $passwordNode=FindNode $snapshot 'DeployPassword'
 Check ($passwordNode.Kind -ceq 'password' -and $passwordNode.SecretPresent -and -not $passwordNode.PSObject.Properties['Value']) 'Password snapshot exposes only presence, never a Value'
 Check (@($all|Where-Object {$_.Name -in @('DeployPasswordPlainText','DeployPasswordReveal')}).Count -eq 0) 'Visible plaintext mirror and legacy reveal button are excluded'
 Check ((FindNode $snapshot 'ReadOnlyText').ReadOnly -and (FindNode $snapshot 'ReadOnlyText').Multiline) 'Readonly multiline text remains readable'
 Check ((FindNode $snapshot 'Select').Items.Count -eq 5 -and (FindNode $snapshot 'Select').Items[1].Index -eq 1 -and (FindNode $snapshot 'Select').Items[1].Label -ceq '第二个') 'Select exports stable indices and explicit labels'
 Check ((FindNode $snapshot 'Select').Items[2].Disabled -and (FindNode $snapshot 'Select').Items[3].Disabled -and (FindNode $snapshot 'Select').Items[4].Disabled) 'Disabled, hidden and unsupported select items cannot be selected'
 Check (-not (FindNode $snapshot 'Select').ReadOnly) 'Readonly combo text still permits WPF index selection'
 $captionless=FindNode $snapshot 'CaptionlessCheck';$namedCaptionless=FindNode $snapshot 'NamedCaptionlessCheck';$captioned=FindNode $snapshot 'Check'
 Check ($captionless.HasCaption -is [bool] -and -not $captionless.HasCaption -and $captionless.Text -ceq '' -and $captionless.Label -ceq '桌面程序') 'Captionless checkbox keeps its accessible fallback without repeating the group title as visible text'
 Check (-not $namedCaptionless.HasCaption -and $namedCaptionless.Text -ceq '' -and $namedCaptionless.Label -ceq 'Claude') 'Captionless checkbox uses AutomationName only as its accessible label'
 Check ($captioned.HasCaption -eq $true -and $captioned.Text -ceq '记住选择' -and $captioned.Label -ceq '记住登录选择（辅助标签）') 'Captioned checkbox separates its actual Content from its accessible label'
 Check ((FindNode $snapshot 'NestedScroll').Kind -ceq 'panel' -and (FindNode $snapshot 'Wrapped').Kind -ceq 'row' -and (FindNode $snapshot 'NestedGrid').Kind -ceq 'grid') 'ScrollViewer, WrapPanel and Grid preserve content structure'
 Check ((FindNode $snapshot 'GridText').Column -eq 1 -and (FindNode $snapshot 'NestedGrid').Columns -eq 2) 'Grid exposes only bounded layout coordinates'
 Check ((FindNode $snapshot 'Divider').Kind -ceq 'rule') 'Rules are represented explicitly'
 Check ((FindNode $snapshot 'Progress').Value -eq 50 -and (FindNode $snapshot 'Indeterminate').Indeterminate -and $null -eq (FindNode $snapshot 'Indeterminate').Value) 'Determinate and indeterminate progress are represented'
 Check ((FindNode $snapshot 'Unsupported').Kind -ceq 'text' -and (FindNode $snapshot 'Unsupported').Text -match '暂不支持') 'Unsupported controls are reported instead of empty controls'
 $allowed=@('Kind','Id','Name','Text','Label','Value','Disabled','ReadOnly','Items','Children','Open','Tone','Level','Multiline','MaxLength','SecretPresent','HasCaption','Radio','Columns','Row','Column','RowSpan','ColumnSpan','Indeterminate','Cols','Role','Size','Align','Icon')
 foreach($node in $all){Check (@($node.PSObject.Properties.Name|Where-Object {$_ -cnotin $allowed}).Count -eq 0) ('Whitelisted properties '+$node.Kind+' '+$node.Name)}
 SaveSnapshot '01-structured-controls' $snapshot
 $again=GetTCWebFormSnapshot
 Check ($again.Generation -ceq $snapshot.Generation -and (FindNode $again 'OriginalButton').Id -ceq (FindNode $snapshot 'OriginalButton').Id) 'Live control IDs stay stable within a generation'
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'Applied' 'Button raises its existing routed Click event'
 Check ($script:ButtonClicks -eq 1) 'One click invokes the original handler once'
 CheckCode (InvokeNamed 'Input' 'change' '  中文 $ !  ') 'Applied' 'Text input uses the existing TextChanged path'
 Check ($script:TextChanges -eq 1 -and $script:ChangedText -ceq '  中文 $ !  ') 'TextChanged receives exact whitespace and Unicode'
 CheckCode (InvokeNamed 'Select' 'change' ([long]1)) 'Applied' 'Combo selection uses SelectedIndex'
 Check ($combo.SelectedIndex -eq 1 -and $script:Selections -eq 1 -and $script:Selected -eq 1) 'SelectionChanged observes the selected original item'
 CheckCode (InvokeNamed 'Check' 'change' $true) 'Applied' 'Checkbox change applies the explicit boolean'
 Check ($check.IsChecked -and $script:CheckClicks -eq 1 -and $script:CheckedEvents -eq 1 -and $script:ClickObservedState) 'Checkbox sets IsChecked before raising exactly one Click'
 CheckCode (InvokeNamed 'RadioTwo' 'change' $true) 'Applied' 'Radio selection uses the original group and Checked event'
 Check ($radio2.IsChecked -and -not $radio1.IsChecked -and $script:RadioChecked -eq 1 -and (FindNode (GetTCWebFormSnapshot) 'RadioTwo').Radio) 'Radio exclusivity is retained and declared'
 CheckCode (InvokeNamed 'RadioTwo' 'change' $false) 'InvalidValue' 'A selected radio cannot be unchecked through a forged change'
 CheckCode (InvokeNamed 'DeployPassword' 'change' 'FIXTURE_SECRET_new  密码$!') 'Applied' 'Password sets the existing PasswordBox'
 Check ($password.Password -ceq 'FIXTURE_SECRET_new  密码$!' -and $script:DeployUI.CredentialDraft.Secret.Length -eq $password.SecurePassword.Length) 'PasswordChanged maintains the original secure credential draft'
 SaveSnapshot '02-after-events' (GetTCWebFormSnapshot)

 # Every wire type is checked before coercion or mutation.
 foreach($value in @($true,12,1.5,@('array'),@{Text='object'},[pscustomobject]@{Text='object'})){
  CheckCode (InvokeNamed 'Input' 'change' $value) 'InvalidValue' ('Text rejects wire type '+$value.GetType().Name)
  CheckCode (InvokeNamed 'DeployPassword' 'change' $value) 'InvalidValue' ('Password rejects wire type '+$value.GetType().Name)
 }
 CheckCode (InvokeNamed 'Input' 'change' $null) 'InvalidValue' 'Text rejects null instead of silently clearing'
 CheckCode (InvokeNamed 'DeployPassword' 'change' $null) 'InvalidValue' 'Password rejects null instead of silently clearing'
 foreach($value in @('true',1,@($true),@{Value=$true})) {CheckCode (InvokeNamed 'Check' 'change' $value) 'InvalidValue' ('Checkbox rejects wire type '+$value.GetType().Name)}
 foreach($value in @('1',1.0,$true,-1,2,3,4,5,[long]::MaxValue,@(1))){CheckCode (InvokeNamed 'Select' 'change' $value) 'InvalidValue' ('Select rejects non-index or unavailable item '+$value.GetType().Name)}
 CheckCode (InvokeNamed 'Input' 'change' ('x'*17)) 'ValueTooLarge' 'Text respects its smaller WPF MaxLength'
 CheckCode (InvokeNamed 'Input' 'change' ('x'*16)) 'Applied' 'Text accepts its exact MaxLength'
 CheckCode (InvokeNamed 'DeployPassword' 'change' ('x'*4097)) 'ValueTooLarge' 'Password rejects more than 4096 UTF-16 characters'
 CheckCode (InvokeNamed 'DeployPassword' 'change' ('密'*4096)) 'Applied' 'Password accepts the exact bounded Unicode limit'
 $password.MaxLength=8
 CheckCode (InvokeNamed 'DeployPassword' 'change' ('x'*9)) 'ValueTooLarge' 'Password also honors a smaller WPF MaxLength'
 CheckCode (InvokeNamed 'DeployPassword' 'change' '') 'Applied' 'Explicit empty password clears the existing secure draft'
 Check (-not (FindNode (GetTCWebFormSnapshot) 'DeployPassword').SecretPresent) 'An empty password only changes SecretPresent'
 CheckCode (InvokeNamed 'ReadOnlyText' 'change' 'replace') 'ReadOnly' 'Readonly text refuses writes'
 CheckCode (InvokeNamed 'OriginalButton' 'click' 'unexpected') 'InvalidValue' 'Button clicks cannot carry a value'
 CheckCode (InvokeNamed 'OriginalButton' 'change' 'replace') 'UnsupportedEvent' 'Button cannot be changed as an input'
 $valid=GetTCWebFormSnapshot;$buttonId=(FindNode $valid 'OriginalButton').Id
 foreach($event in @('Click','execute','',@('click'),@{Event='click'})){CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId $event) 'InvalidEvent' 'Only exact lowercase event names are accepted'}
 CheckCode (InvokeTCWebFormAction @{Generation=$valid.Generation} $buttonId 'click') 'InvalidGeneration' 'Generation objects cannot stringify'
 CheckCode (InvokeTCWebFormAction ('g'*5000) $buttonId 'click') 'InvalidGeneration' 'Oversized generation is rejected'
 CheckCode (InvokeTCWebFormAction $valid.Generation @($buttonId) 'click') 'InvalidId' 'Handle arrays cannot stringify'
 CheckCode (InvokeTCWebFormAction $valid.Generation ('x'*5000) 'click') 'InvalidId' 'Oversized handle is rejected'
 CheckCode (InvokeTCWebFormAction $valid.Generation ('wf-'+[guid]::NewGuid().ToString('N')) 'click') 'UnknownId' 'Unissued IDs cannot dispatch'

 # Visibility is checked across the business tree, but not through its hidden shell.
 $panel.Visibility='Hidden'
 CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId 'click') 'Hidden' 'A newly hidden ancestor blocks a previously issued handle'
 Check (@((GetTCWebFormSnapshot).Nodes).Count -eq 0) 'Hidden subtrees do not appear in snapshots'
 $panel.Visibility='Visible'
 Check ((FindNode (GetTCWebFormSnapshot) 'OriginalButton').Id -ceq $buttonId) 'Hiding and revealing the same attached control preserves its ID'
 $button.Visibility='Collapsed'
 CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId 'click') 'Hidden' 'A control own Collapsed visibility blocks events'
 $button.Visibility='Visible';$panel.IsEnabled=$false
 CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId 'click') 'Disabled' 'Disabled ancestors block events'
 $panel.IsEnabled=$true;$button.IsEnabled=$false
 CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId 'click') 'Disabled' 'Disabled controls block events'
 $button.IsEnabled=$true;$script:FixtureBusy=$true
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'Busy' 'IsBusy prevents button dispatch'
 CheckCode (InvokeNamed 'Input' 'change' 'busy') 'Busy' 'IsBusy prevents input changes'
 $script:FixtureBusy=$false;$script:ReadOnly=$true
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'ReadOnly' 'Readonly launch prevents business button dispatch'
 CheckCode (InvokeNamed 'Input' 'change' 'read only') 'ReadOnly' 'Readonly launch prevents input changes'
 CheckCode (InvokeNamed 'Select' 'change' 0) 'ReadOnly' 'Readonly launch prevents selections'
 $script:ReadOnly=$false
 $script:JobQueue.Enqueue([pscustomobject]@{Silent=$false})
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'Queued' 'A queued foreground request blocks repeated buttons even when IsBusy is false'
 CheckCode (InvokeNamed 'Check' 'change' $false) 'Queued' 'Queued foreground work also blocks checkbox Click handlers'
 Check ((FindNode (GetTCWebFormSnapshot) 'OriginalButton').Disabled) 'Queued foreground work is reflected in button Disabled'
 $script:JobQueue.Clear();$script:JobQueue.Enqueue(@{})
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'Queued' 'A queue entry without Silent fails closed'
 $script:JobQueue.Clear();$script:JobQueue.Enqueue(@{Silent=$true})
 CheckCode (InvokeNamed 'OriginalButton' 'click') 'Applied' 'A purely silent queue does not block ordinary buttons'
 $script:JobQueue.Clear()
 $panel.Children.Remove($button)
 CheckCode (InvokeTCWebFormAction $valid.Generation $buttonId 'click') 'UnknownId' 'Detached handles are pruned at dispatch without waiting for polling'
 Check (-not $script:TCWebFormView.Handles.ContainsKey($buttonId) -and -not $script:TCWebFormView.ObjectIds.ContainsKey($button)) 'Detached controls leave both handle maps'
 $replacement=Btn '替换后的按钮' 'OriginalButton' {$script:ButtonClicks++};AddC $panel $replacement
 Check ((FindNode (GetTCWebFormSnapshot) 'OriginalButton').Id -cne $buttonId) 'A replacement with the same Name receives a different ID'
 $oldGeneration=$valid.Generation;$oldId=(FindNode (GetTCWebFormSnapshot) 'OriginalButton').Id
 ResetFixture
 Check ($script:TCWebFormView.Generation -cne $oldGeneration -and $script:TCWebFormView.Handles.Count -eq 0) 'A new view creates a new generation and clears all handles'
 CheckCode (InvokeTCWebFormAction $oldGeneration $oldId 'click') 'StaleGeneration' 'Old generations cannot invoke a replacement view'

 $outer=ControlName (New-Object Windows.Controls.Expander) 'OuterDetails';$outer.Header='外层详情';$inside=Stack;$outer.Content=$inside;AddC $script:HostPanel $outer
 $inner=ControlName (New-Object Windows.Controls.Expander) 'InnerDetails';$inner.Header='内层详情';$inner.IsExpanded=$true;AddC $inside $inner
 $script:NestedClicks=0;$nested=Btn '嵌套动作' 'NestedButton' {$script:NestedClicks++};$inner.Content=$nested
 $script:ExpandedEvents=0;$script:CollapsedEvents=0
 $outer.Add_Expanded({param($sender,$eventArgs)if([object]::ReferenceEquals($sender,$eventArgs.OriginalSource)){$script:ExpandedEvents++}})
 $outer.Add_Collapsed({param($sender,$eventArgs)if([object]::ReferenceEquals($sender,$eventArgs.OriginalSource)){$script:CollapsedEvents++}})
 Check ((FindNode (GetTCWebFormSnapshot) 'NestedButton').Disabled) 'Controls below a collapsed Expander are marked disabled'
 CheckCode (InvokeNamed 'NestedButton' 'click') 'Collapsed' 'A collapsed outer ancestor blocks nested actions'
 CheckCode (InvokeNamed 'InnerDetails' 'expand' $false) 'Collapsed' 'Collapsed ancestors also block nested expand events'
 foreach($value in @('true',1,$null,@($true))){CheckCode (InvokeNamed 'OuterDetails' 'expand' $value) 'InvalidValue' 'Expansion requires a boolean'}
 $script:ReadOnly=$true
 CheckCode (InvokeNamed 'OuterDetails' 'expand' $true) 'Applied' 'Readonly mode still allows local details expansion'
 Check ($outer.IsExpanded -and $script:ExpandedEvents -eq 1) 'Expansion raises the original Expanded event once'
 CheckCode (InvokeNamed 'NestedButton' 'click') 'ReadOnly' 'Readonly expansion does not grant business action permission'
 $script:ReadOnly=$false
 CheckCode (InvokeNamed 'NestedButton' 'click') 'Applied' 'A fully expanded subtree dispatches original actions'
 CheckCode (InvokeNamed 'InnerDetails' 'expand' $false) 'Applied' 'Nested details can be collapsed locally'
 CheckCode (InvokeNamed 'NestedButton' 'click') 'Collapsed' 'Collapsing a parent immediately revokes child events'
 CheckCode (InvokeNamed 'OuterDetails' 'expand' $false) 'Applied' 'Collapse uses the original Expander property'
 Check ($script:CollapsedEvents -eq 1) 'Collapse raises the existing Collapsed event once'
 SaveSnapshot '03-nested-details' (GetTCWebFormSnapshot)

 ResetFixture
 $script:MenuPopupClicks=0;$script:MenuClicks=0
 $more=Btn '⋯' 'More' {$script:MenuPopupClicks++;$this.ContextMenu.IsOpen=$true};$more.ToolTip='更多操作';$menu=New-Object Windows.Controls.ContextMenu;$more.ContextMenu=$menu;AddC $script:HostPanel $more
 $leaf=ControlName (New-Object Windows.Controls.MenuItem) 'MenuLeaf';$leaf.Header='查看记录';$leaf.Tag='PRIVATE_TAG_menu';$leaf.Add_Click({$script:MenuClicks++});$null=$menu.Items.Add($leaf)
 $null=$menu.Items.Add((New-Object Windows.Controls.Separator));$null=$menu.Items.Add([pscustomobject]@{Password='PRIVATE_OBJECT_menu'})
 $menuEditor=ControlName (New-Object Windows.Controls.TextBox) 'UnsupportedMenuEditor';$menuEditor.Text='PRIVATE_OBJECT_menu_editor';$null=$menu.Items.Add($menuEditor)
 $submenu=ControlName (New-Object Windows.Controls.MenuItem) 'Submenu';$submenu.Header='子菜单';$subleaf=ControlName (New-Object Windows.Controls.MenuItem) 'SubLeaf';$subleaf.Header='子操作';$subleaf.Add_Click({$script:MenuClicks++});$null=$submenu.Items.Add($subleaf);$null=$menu.Items.Add($submenu)
 Check ((FindNode (GetTCWebFormSnapshot) 'More').Kind -ceq 'details' -and (FindNode (GetTCWebFormSnapshot) 'More').Label -ceq '更多操作') 'Context menu owners become labeled local details'
 CheckCode (InvokeNamed 'MenuLeaf' 'click') 'Collapsed' 'Closed menus do not grant child actions'
 CheckCode (InvokeNamed 'More' 'expand' $true) 'Applied' 'Menu expansion stays in the web view'
 Check (-not $menu.IsOpen -and $script:MenuPopupClicks -eq 0) 'Adapter never opens the old WPF context menu or clicks its opener'
 CheckCode (InvokeNamed 'MenuLeaf' 'click') 'Applied' 'Menu leaf raises its existing MenuItem Click event'
 Check ($script:MenuClicks -eq 1) 'Menu handler is dispatched exactly once'
 CheckCode (InvokeNamed 'SubLeaf' 'click') 'Collapsed' 'A nested menu remains closed independently'
 CheckCode (InvokeNamed 'Submenu' 'expand' $true) 'Applied' 'Explicit submenu expansion is supported'
 CheckCode (InvokeNamed 'SubLeaf' 'click') 'Applied' 'Expanded nested menu leaf dispatches'
 $menuSnapshot=GetTCWebFormSnapshot
 Check (@(FlattenNodes $menuSnapshot.Nodes|Where-Object {$_.Kind -eq 'text' -and $_.Text -match '暂不支持'}).Count -ge 1) 'Unsupported explicit menu items have a visible explanation'
 Check (@(FlattenNodes $menuSnapshot.Nodes|Where-Object {$_.Kind -eq 'button' -and -not $_.Text}).Count -eq 0) 'Menus never leave empty actionable buttons'
 Check (@(FlattenNodes $menuSnapshot.Nodes|Where-Object Name -ceq 'UnsupportedMenuEditor').Count -eq 0) 'Only explicit MenuItem and Separator children become menu controls'
 SaveSnapshot '04-explicit-menus' $menuSnapshot
 $leafId=(FindNode $menuSnapshot 'MenuLeaf').Id;$menu.Items.Remove($leaf)
 CheckCode (InvokeTCWebFormAction $menuSnapshot.Generation $leafId 'click') 'UnknownId' 'Removing a menu item revokes its handle'
 $more.Visibility='Collapsed';$subId=(FindNode $menuSnapshot 'SubLeaf').Id
 CheckCode (InvokeTCWebFormAction $menuSnapshot.Generation $subId 'click') 'Hidden' 'Hidden menu owners block nested actions'

 # Build the actual deployment form, with real password/input/button wiring.
 ResetFixture;$script:SubmitCalls=0;ShowProductDeployment
 $deployment=GetTCWebFormSnapshot
 Check ($deployment.Title -ceq $script:HostPanel.Children[0].Text -and $deployment.Page -ceq 'setup' -and $script:Page -ceq 'setup') 'Actual deployment form keeps its native page semantics'
 Check ($script:Window.FindName('DeploymentActionBar').Visibility -eq 'Collapsed') 'Real sticky action bar is collapsed behind the hidden native shell'
 Check (@($deployment.Actions).Count -eq 2 -and @($deployment.Actions.Name) -contains 'ProductDeployInspect' -and @($deployment.Actions.Name) -contains 'ProductServers') 'Current deployment buttons are still exported separately in Actions'
 Check ((FindNode $deployment 'DeployPassword').Kind -ceq 'password' -and (FindNode $deployment 'DeployConnectionText').Kind -ceq 'input') 'Actual deployment credentials and address remain web form controls'
 CheckCode (InvokeNamed 'DeployConnectionText' 'change' '192.0.2.10') 'Applied' 'Actual deployment address accepts web input'
 CheckCode (InvokeNamed 'DeployPassword' 'change' 'FIXTURE_SECRET_actual_form') 'Applied' 'Actual deployment password stays in the original secure draft'
 CheckCode (InvokeNamed 'DeploymentAdvanced' 'expand' $true) 'Applied' 'Actual advanced deployment details expand'
 CheckCode (InvokeNamed 'DeployTcpPort' 'change' 1) 'Applied' 'Actual readonly-edit combo still selects TCP port by index'
 Check ($script:Controls.DeployTcpPort.Text -ceq '8443') 'Original TCP port control receives the selected item'
 SaveSnapshot '05-real-deployment-form' (GetTCWebFormSnapshot)
 $script:Job=[pscustomobject]@{Silent=$true};$script:FixtureBusy=$false
 CheckCode (InvokeNamed 'ProductDeployInspect' 'click') 'Applied' 'Actual submit button reuses its original handler'
 Check ($script:SubmitCalls -eq 1 -and $script:JobQueue.Count -eq 1 -and $script:CapturedRequests[0].Request.Host -ceq '192.0.2.10') 'One foreground submission is captured behind an existing silent job'
 CheckCode (InvokeNamed 'ProductDeployInspect' 'click') 'Queued' 'A second submit cannot duplicate queued foreground work'
 Check ($script:SubmitCalls -eq 1 -and $script:CapturedRequests.Count -eq 1) 'Queued duplicate protection happens before the original handler'
 $script:Job=$null;$script:JobQueue.Clear();$submitted=GetTCWebFormSnapshot;$submitId=(FindNode $submitted 'ProductDeployInspect').Id
 $formCard=@($script:HostPanel.Children|Where-Object {$_ -is [Windows.Controls.Border]})[-1]
 $formCard.Visibility='Hidden'
 CheckCode (InvokeTCWebFormAction $submitted.Generation $submitId 'click') 'Hidden' 'A genuinely hidden deployment card also blocks sticky actions outside that card'
 Check (@((GetTCWebFormSnapshot).Actions).Count -eq 0) 'Hidden current deployment forms expose no sticky actions'
 $formCard.Visibility='Visible'
 Check ((FindNode (GetTCWebFormSnapshot) 'ProductDeployInspect').Id -ceq $submitId) 'Revealing the same deployment card preserves its sticky action IDs'
 $actionHost=$script:Window.FindName('DeploymentActionHost');$actionHost.Visibility='Collapsed'
 CheckCode (InvokeTCWebFormAction $submitted.Generation $submitId 'click') 'Hidden' 'An action host own Collapsed visibility blocks sticky actions'
 $actionHost.Visibility='Visible'
 $script:DeployUI.Run=[pscustomobject]@{RunId='fixture-run'};$script:DeployUI.Reauth=$false
 Check (@((GetTCWebFormSnapshot).Actions).Count -eq 0) 'A running flow without Reauth cannot expose stale deployment form actions'
 CheckCode (InvokeTCWebFormAction $submitted.Generation $submitId 'click') 'UnknownId' 'Leaving the editable deployment stage revokes stale sticky actions'
 $script:DeployUI.Reauth=$true
 Check (@((GetTCWebFormSnapshot).Actions).Count -eq 2) 'Reauth enables current deployment form actions'
 $script:Role='operation-history';Check (@((GetTCWebFormSnapshot).Actions).Count -eq 0) 'Other roles cannot inherit deployment action buttons'
 $script:Role='deployment';$script:Page='nodes';Check (@((GetTCWebFormSnapshot).Actions).Count -eq 0) 'Other pages cannot inherit deployment action buttons'
 $script:Page='setup';$script:Controls.Remove('ProductDeployInspect')
 Check (@((GetTCWebFormSnapshot).Actions|Where-Object Name -ceq 'ProductDeployInspect').Count -eq 0) 'Unregistered stale sticky buttons are not exported'

 # Exercise actual history controls without loading history modules or workers.
 ResetFixture;ShowUnifiedOperationHistory
 $history=GetTCWebFormSnapshot
 Check ($history.Title -ceq $script:HostPanel.Children[0].Text -and (FindNode $history 'HistorySearch').Kind -ceq 'input' -and (FindNode $history 'HistorySourceFilter').Items.Count -eq 5) 'Actual history filters project as structured inputs and selects'
 CheckCode (InvokeNamed 'HistorySearch' 'change' '测试筛选') 'Applied' 'Actual history search accepts edits'
 CheckCode (InvokeNamed 'HistorySourceFilter' 'change' 1) 'Applied' 'Actual history source uses index selection'
 $beforeHistory=GetTCWebFormSnapshot;$beforeApply=(FindNode $beforeHistory 'ApplyHistoryFilters').Id
 CheckCode (InvokeNamed 'ApplyHistoryFilters' 'click') 'Applied' 'Actual history filter applies through its original button callback'
 Check ($script:DeployUI.HistorySearchText -ceq '测试筛选' -and $script:DeployUI.HistorySourceKind -ceq 'DeploymentRun' -and (GetTCWebFormSnapshot).Generation -cne $beforeHistory.Generation) 'Original history callback consumes WPF values and rebuilds a new generation'
 CheckCode (InvokeTCWebFormAction $beforeHistory.Generation $beforeApply 'click') 'StaleGeneration' 'Rebuilt actual pages reject old filter actions'
 CheckCode (InvokeNamed 'ShowClearedHistory' 'change' $true) 'Applied' 'Actual history checkbox receives IsChecked and Click'
 Check ($script:DeployUI.HistoryIncludeHidden) 'History checkbox runs the existing business callback'
 SaveSnapshot '06-real-operation-history' (GetTCWebFormSnapshot)

 ResetFixture
 $large=ControlName (New-Object Windows.Controls.TextBox) 'LargeInput';$large.AcceptsReturn=$true;$large.MaxLength=128KB;AddC $script:HostPanel $large
 CheckCode (InvokeNamed 'LargeInput' 'change' ('z'*131072)) 'Applied' 'Pairing-sized input accepts exactly 128 KiB UTF-16 characters'
 CheckCode (InvokeNamed 'LargeInput' 'change' ('z'*131073)) 'ValueTooLarge' 'Pairing-sized input rejects one character beyond its cap'
 $large.MaxLength=0
 CheckCode (InvokeNamed 'LargeInput' 'change' ('z'*131073)) 'ValueTooLarge' 'Unbounded WPF input still has the adapter hard limit'
 $large.Text='z'*131073;$oversize=FindNode (GetTCWebFormSnapshot) 'LargeInput'
 Check ($oversize.ReadOnly -and $oversize.Value.Length -eq 131072) 'Oversized existing input is bounded and made readonly instead of silently overwritable'
 CheckCode (InvokeNamed 'LargeInput' 'change' 'truncated replacement') 'ReadOnly' 'An oversized existing value cannot be overwritten through its truncated projection'
 ResetFixture
 $many=ControlName (New-Object Windows.Controls.ComboBox) 'ManyItems';for($i=0;$i -lt 1030;$i++){$null=$many.Items.Add(('Option '+$i))};AddC $script:HostPanel $many
 Check ((FindNode (GetTCWebFormSnapshot) 'ManyItems').Items.Count -eq 1024) 'Select option projection is bounded at 1024 items'
 CheckCode (InvokeNamed 'ManyItems' 'change' 1024) 'InvalidValue' 'Unexported select items cannot be chosen'
 ResetFixture
 $manyMenu=Btn '大量菜单项' 'ManyMenu' {};$manyMenu.ContextMenu=New-Object Windows.Controls.ContextMenu
 for($i=0;$i -lt 2060;$i++){$null=$manyMenu.ContextMenu.Items.Add([pscustomobject]@{Unknown=$i})};AddC $script:HostPanel $manyMenu
 $bounded=GetTCWebFormSnapshot
 Check (@(FlattenNodes $bounded.Nodes).Count -le 2049 -and ($bounded|ConvertTo-Json -Depth 48 -Compress) -match '部分内容已省略') 'Unsupported menu entries share the node budget instead of growing unbounded'
 ResetFixture
 $chain=Stack;AddC $script:HostPanel $chain
 for($i=0;$i -lt 25;$i++){$next=Stack;AddC $chain $next;$chain=$next}
 AddC $chain (Btn '深层动作' 'TooDeep' {})
 $bounded=GetTCWebFormSnapshot;$boundedJson=$bounded|ConvertTo-Json -Depth 48
 Check (@(FlattenNodes $bounded.Nodes|Where-Object Name -ceq 'TooDeep').Count -eq 0 -and $boundedJson -match '部分内容已省略') 'Depth is bounded below bridge JSON depth and truncation is explained'
 ResetFixture
 for($i=0;$i -lt 2060;$i++){AddC $script:HostPanel (T ('节点 '+$i))}
 $bounded=GetTCWebFormSnapshot
 Check (@(FlattenNodes $bounded.Nodes).Count -le 2049 -and $script:TCWebFormView.Handles.Count -le 2048) 'Node and live-handle counts are bounded'
 ResetFixture
 for($i=0;$i -lt 12;$i++){AddC $script:HostPanel (T ('t'*131072))}
 $bounded=GetTCWebFormSnapshot;$boundedJson=$bounded|ConvertTo-Json -Depth 48 -Compress
 Check ($boundedJson.Length -lt 1100000 -and $boundedJson -match '部分内容已省略') 'Total snapshot text is bounded and truncation is explicit'
 ResetFixture
 $throws=Btn '异常处理' 'ThrowingButton' {throw 'FIXTURE_SECRET_handler_exception'};AddC $script:HostPanel $throws
 $exception=InvokeNamed 'ThrowingButton' 'click'
 CheckCode $exception 'ActionFailed' 'Handler failures become a fixed error code'
 Check (($exception|ConvertTo-Json) -notmatch 'FIXTURE_SECRET') 'Handler exception details cannot leak input values to the bridge'
 Check ($script:DeniedActors.Count -eq 0) 'No real process, worker, pipe, network or file picker actor was called'
 # ---- 0.22.0 B2：说明通道（HelpText → Hint / Tag.TCHint → hint 节点）----
 ResetFixture
 $hinted=New-Object Windows.Controls.TextBox
 $hinted.Text='10.0.0.9'
 $null=HelpTip $hinted '填这台电脑能连到的地址；不会自动探测。'
 $null=ControlName $hinted 'HintedAddress'
 AddC $script:HostPanel $hinted
 $b2=GetTCWebFormSnapshot;$hintedNode=FindNode $b2 'HintedAddress'
 Check ($hintedNode.Hint -ceq '填这台电脑能连到的地址；不会自动探测。') 'HelpText becomes node Hint'
 Check ($hintedNode.Label -ne $hintedNode.Hint) 'A HelpTip explanation is never used as the control label'
 ResetFixture
 $icon=HintIcon '只测 TCP 建连，不代表交易延迟。' 'HintedIcon'
 AddC $script:HostPanel $icon
 $b2=GetTCWebFormSnapshot;$hintNode=FindNode $b2 'HintedIcon'
 Check ($hintNode.Kind -eq 'hint' -and $hintNode.Text -ceq '只测 TCP 建连，不代表交易延迟。') 'Tag.TCHint becomes a hint node carrying its text'
 Check (-not $hintNode.Id -and -not $script:TCWebFormView.Handles.ContainsKey($hintNode.Id)) 'A hint node registers no live handle'
 Check (@($b2.Actions|Where-Object {$_.Name -ceq 'HintedIcon'}).Count -eq 0) 'A hint node is not an actionable control'
 Check ($icon.Tag.TCHint -ceq '只测 TCP 建连，不代表交易延迟。' -and $icon.ToolTip -ceq $icon.Tag.TCHint) 'HintIcon keeps the same text in Tag and ToolTip for the degraded shell'
 # B-10: keyboard activation must open a Popup whose rendered text is the same hint.
 $peer=New-Object Windows.Automation.Peers.ButtonAutomationPeer($icon)
 $provider=$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke)
 Check ($null -ne $provider) 'HintIcon exposes the Invoke automation pattern used by keyboard activation'
 $icon.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
 Check ($null -ne $icon.HintPopup -and [bool]$icon.HintPopup.IsOpen) 'Keyboard activation opens the WPF hint Popup'
 $popupBorder=$icon.HintPopup.Child
 Check ($null -ne $popupBorder -and [string]$popupBorder.Child.Text -ceq '只测 TCP 建连，不代表交易延迟。') 'The Popup shows the exact hint text, not just a tooltip'
 $icon.HintPopup.IsOpen=$false
 ResetFixture
 $title=TitleWithHint '服务器与设备' '连接请到线路页操作；这里用于服务器维护。' 18
 AddC $script:HostPanel $title
 $b2=GetTCWebFormSnapshot
 Check (@(FlattenNodes $b2.Nodes|Where-Object Kind -eq 'hint').Count -eq 1) 'TitleWithHint emits exactly one hint beside its title'
 Check (@(FlattenNodes $b2.Nodes|Where-Object {$_.Kind -eq 'text' -and $_.Text -ceq '服务器与设备'}).Count -eq 1) 'TitleWithHint keeps the title as its own text node'
 # ---- 0.23.0 布局投影保真：列宽 / 角色 / 尺寸 / 对齐 / 图标 ----
 ResetFixture
 $specGrid=ControlName (Grid @('*','Auto','Auto')) 'SpecGrid'
 Cell $specGrid (ControlName (New-Object Windows.Controls.TextBox) 'SpecInput') 0
 Cell $specGrid (Btn '添加网址' 'SpecSite' {}) 1
 Cell $specGrid (Btn '添加程序' 'SpecApp' {}) 2
 AddC $script:HostPanel $specGrid
 $fixedGrid=ControlName (Grid @('128','*')) 'FixedGrid'
 Cell $fixedGrid (T '标签') 0;Cell $fixedGrid (T '值') 1;AddC $script:HostPanel $fixedGrid
 $rowGrid=ControlName (Grid @('Auto','*','Auto')) 'RowGrid'
 $mark=New-Object Windows.Controls.Border;$mark.Width=38;$mark.Tag=[pscustomobject]@{TCRole='tile'}
 $mark.Child=Icon 'laptop' 16 $script:Text3;Cell $rowGrid $mark 0
 Cell $rowGrid (T '自定义程序') 1;Cell $rowGrid (Btn '移除' 'RowRemove' {}) 2;AddC $script:HostPanel $rowGrid
 $plainBorder=ControlName (Card) 'PlainCard';$plainBorder.Child=(T '卡片正文');AddC $script:HostPanel $plainBorder
 $chipNode=ControlName (Pill '运行中' 'ok') 'ChipNode';AddC $script:HostPanel $chipNode
 $stepBorder=ControlName (New-Object Windows.Controls.Border) 'StepNumber'
 $stepBorder.Width=26;$stepBorder.Height=26;$stepBorder.Tag=[pscustomobject]@{TCRole='tile'}
 $stepBorder.Child=(T '1' 13);AddC $script:HostPanel $stepBorder
 $alignGrid=ControlName (Grid @('*','Auto')) 'AlignGrid'
 Cell $alignGrid (T 'AI 工具名单' 12) 0
 $aligned=T '名单当前跟随日常上网' 12;$aligned.HorizontalAlignment='Right';Cell $alignGrid $aligned 1
 AddC $script:HostPanel $alignGrid
 $layoutSnap=GetTCWebFormSnapshot
 Check (((FindNode $layoutSnap 'SpecGrid').Cols -join '|') -ceq '*|Auto|Auto') 'Grid 投影列宽序列'
 Check ((FindNode $layoutSnap 'SpecGrid').Cols.Count -eq (FindNode $layoutSnap 'SpecGrid').Columns) 'Cols 与 Columns 同源'
 Check (((FindNode $layoutSnap 'FixedGrid').Cols -join '|') -ceq '128px|*') '固定像素列保留像素值'
 Check (((FindNode $layoutSnap 'RowGrid').Cols -join '|') -ceq 'Auto|*|Auto') 'Auto 列保留 Auto'
 Check ((FindNode $layoutSnap 'RowGrid').Children[0].Role -ceq 'tile' -and (FindNode $layoutSnap 'RowGrid').Children[0].Size -eq 38) '图标位标注 tile 且带边长'
 Check ((FindNode $layoutSnap 'RowGrid').Children[0].Children[0].Kind -ceq 'icon' -and (FindNode $layoutSnap 'RowGrid').Children[0].Children[0].Icon -ceq 'laptop') '图标按白名单名字还原成 icon 节点'
 Check ((FindNode $layoutSnap 'ChipNode').Role -ceq 'chip') 'Pill 标注为 chip'
 Check ((FindNode $layoutSnap 'StepNumber').Role -ceq 'tile' -and (FindNode $layoutSnap 'StepNumber').Size -eq 26) '定宽 26 的序号位标注 tile'
 Check (-not (FindNode $layoutSnap 'PlainCard').PSObject.Properties['Role']) '未标注 Border 不发送 Role（保持现状）'
 Check ((FindNode $layoutSnap 'AlignGrid').Children[1].Align -ceq 'end') 'HorizontalAlignment=Right 投影为 Align=end'
 $layoutJson=$layoutSnap|ConvertTo-Json -Depth 24 -Compress
 Check ($layoutJson -notmatch 'TCRole|TCHint|TCIcon') 'Tag 保留键不进入 wire'
 Check ($layoutJson.Length -lt 1100000) '新字段不突破 1MB 上限'
 # 标注 × 宿主属性交叉校验：推断只出现在测试里，生产只认标注（改内边距越过阈值会红）
 foreach($roleNode in @(FlattenNodes $layoutSnap.Nodes|Where-Object Role -ceq 'chip')){
  $hostControl=$script:TCWebFormView.Handles[$roleNode.Id].Control;$pad=$hostControl.Padding
  Check (($pad.Left+$pad.Top+$pad.Right+$pad.Bottom) -le 30 -and $hostControl.Child -is [Windows.Controls.TextBlock]) 'chip 标注与宿主属性一致'
 }
 foreach($roleNode in @(FlattenNodes $layoutSnap.Nodes|Where-Object Role -ceq 'tile')){
  $hostControl=$script:TCWebFormView.Handles[$roleNode.Id].Control
  Check ($hostControl.Width -gt 0 -or $hostControl.Height -gt 0) 'tile 标注的宿主必须有定宽或定高'
 }

 # ---- 0.23.0 页面操作条：独立字段 PageActions，不污染部署专用的 Actions ----
 ResetFixture
 Check (@((GetTCWebFormSnapshot).PageActions).Count -eq 0) 'PageActionHost 为空时不产出 PageActions'
 $pageBar=$script:Window.FindName('PageActionBar');$pageBar.Visibility='Visible'
 AddC $script:Window.FindName('PageActionHost') (Btn '保存' 'FixturePageSave' {})
 $pageSnap=GetTCWebFormSnapshot
 Check (@($pageSnap.PageActions).Count -eq 1 -and $pageSnap.PageActions[0].Name -ceq 'FixturePageSave') 'PageActions 携带已注册按钮'
 Check (@($pageSnap.Actions).Count -eq 0) 'PageActions 不污染部署专用的 Actions'
 $pageBar.Visibility='Collapsed'
 Check (@((GetTCWebFormSnapshot).PageActions).Count -eq 0) 'PageActionBar 折叠时不产出 PageActions'
 $pageBar.Visibility='Visible'
 AddC $script:Window.FindName('PageActionHost') (New-Object Windows.Controls.Button)
 Check (@((GetTCWebFormSnapshot).PageActions).Count -eq 1) '未注册按钮不被暴露成吸底操作'
 $script:Window.FindName('PageActionHost').Children.Clear();$pageBar.Visibility='Collapsed'

 # ---- 静态对照：宿主列宽形态 / forms.css 规则 / app.js 白名单必须三份一致 ----
 # 防复发核心：新页面写了未登记的列宽形态，构建期就红，而不是等用户发现错位。
 # 只扫描字面量数组；手工逐条 Add 的 ColumnDefinition（DeploymentPages 的 '*' + 'Auto'）无法由
 # 数组识别，因此用显式清单补上，并在「僵尸规则」断言里一并豁免。
 $manualSpecs=@('*|Auto')
 $hostText=@()
 foreach($file in @(Get-ChildItem (Join-Path $script:PackageRoot 'ui') -Filter *.ps1|Sort-Object Name)){
  $hostText+=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
 }
 $hostText+=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'TradeChannel.ps1') -Raw -Encoding UTF8
 $hostSpecs=New-Object 'Collections.Generic.List[string]'
 # 只认三种真实来源：Grid 帮助函数、SetupPages 的 foreach 列宽、响应式布局的 $widths 分支。
 # 不用「任意数组字面量」，否则端口号数组之类会被误当成列宽。
 $widthPatterns=@(
  "Grid @\(([^)\r\n]*)\)",
  "foreach\(\`$width in @\(([^)\r\n]*)\)",
  "\`$widths=if\(\`$compact\)\{@\(([^)\r\n]*)\)\}else\{@\(([^)\r\n]*)\)\}"
 )
 foreach($text in $hostText){
  foreach($pattern in $widthPatterns){
   foreach($match in [regex]::Matches($text,$pattern)){
    for($group=1;$group -lt $match.Groups.Count;$group++){
     $raw=$match.Groups[$group].Value
     if(-not $raw){continue}
     # TwoColumns 的形态是 Grid @($Ratio,'16','*')：变量位按默认值 '*' 计（两个调用点都传 '*'）。
     $raw=$raw -replace '\$[A-Za-z_][A-Za-z0-9_]*','''*'''
     $tokens=@([regex]::Matches($raw,"'([^']*)'")|ForEach-Object {$_.Groups[1].Value})
     if($tokens.Count -lt 1){continue}
     $spec=@(foreach($token in $tokens){if($token -eq '*'){'*'}elseif($token -ieq 'Auto'){'Auto'}elseif($token -match '^\d+$'){$token+'px'}else{'?'}})
     if($spec -contains '?'){continue}
     $key=$spec -join '|'
     if(-not $hostSpecs.Contains($key)){$hostSpecs.Add($key)}
    }
   }
  }
 }
 $cssText=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'web\forms.css') -Raw -Encoding UTF8
 $cssSpecs=@([regex]::Matches($cssText,'\[data-colspec="([^"]+)"\]')|ForEach-Object {$_.Groups[1].Value}|Select-Object -Unique)
 $jsText=Get-Content -LiteralPath (Join-Path $script:PackageRoot 'web\app.js') -Raw -Encoding UTF8
 $jsStart=$jsText.IndexOf('const COLSPEC');$jsEnd=$jsText.IndexOf(']);',$jsStart)
 Check ($jsStart -gt 0 -and $jsEnd -gt $jsStart) 'app.js 保留 COLSPEC 白名单'
 $jsSpecs=@([regex]::Matches($jsText.Substring($jsStart,$jsEnd-$jsStart),"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})
 Check (@($hostSpecs|Where-Object {$_ -notin $cssSpecs}).Count -eq 0) ('每个宿主 Grid 形态都有 CSS 规则: '+(@($hostSpecs|Where-Object {$_ -notin $cssSpecs}) -join ','))
 Check (@($cssSpecs|Where-Object {$_ -notin $hostSpecs -and $_ -notin $manualSpecs}).Count -eq 0) ('没有僵尸 CSS 规则: '+(@($cssSpecs|Where-Object {$_ -notin $hostSpecs -and $_ -notin $manualSpecs}) -join ','))
 Check (@($jsSpecs|Where-Object {$_ -notin $cssSpecs}).Count -eq 0) ('app.js 白名单都有 CSS 规则: '+(@($jsSpecs|Where-Object {$_ -notin $cssSpecs}) -join ','))
 Check (@($cssSpecs|Where-Object {$_ -notin $jsSpecs}).Count -eq 0) ('CSS 规则都进了 app.js 白名单: '+(@($cssSpecs|Where-Object {$_ -notin $jsSpecs}) -join ','))
 Check ($script:DeniedActors.Count -eq 0) 'No real process, worker, pipe, network or file picker actor was called'
 $passed=$true
}catch{
 $failure=$_.Exception.Message;$failureAt=$_.ScriptStackTrace
}finally{
 if($script:Window){$script:Window.Close()}
 $result=[pscustomobject][ordered]@{
  Passed=$passed;Checks=$script:Checks.Count;Assertions=$script:Checks.ToArray();Failure=$failure;FailureAt=$failureAt
  PowerShell=$PSVersionTable.PSVersion.ToString();PSEdition=$PSVersionTable.PSEdition;Apartment=[string][Threading.Thread]::CurrentThread.ApartmentState
  NetworkChanged=$false;NetworkRequests=0;WorkersStarted=0;DeniedActors=$script:DeniedActors.ToArray();SourceFunctions=$script:LoadedSources.ToArray()
  Files=@(foreach($name in $checkedFiles.Keys){[pscustomobject]@{File=$name;SHA256=(Get-FileHash -LiteralPath $checkedFiles[$name] -Algorithm SHA256).Hash}})
 }
 [IO.File]::WriteAllText((Join-Path $report 'result.json'),($result|ConvertTo-Json -Depth 12),$encoding)
}
$result|Select-Object Passed,Checks,Failure,FailureAt,PowerShell,WorkersStarted,NetworkRequests|ConvertTo-Json -Depth 8
if(-not $passed){exit 1}
