#requires -Version 5.1
#requires -PSEdition Desktop
# The trade-program field is a drop target: the host fills it with the real path a
# browser cannot read. This checks the page wiring (input + browse + add), the
# host-side drop gate and the dropped-path validation without starting the app or
# a WebView2. It also pins the removal of the 撤销上次名单修改 button.
[CmdletBinding()]param([string]$SourceDirectory='',[string]$ReportPath)
$ErrorActionPreference='Stop'
if(-not $SourceDirectory){$SourceDirectory=Split-Path $PSScriptRoot -Parent}
$checks=New-Object 'Collections.Generic.List[string]'
function Check {param($Condition,[string]$Name)if(-not $Condition){throw $Name};$checks.Add($Name)}
try{
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
 $script:Ink='#111111';$script:Text2='#666666';$script:Text3='#777777';$script:Hair='#DDDDDD'
 $script:Controls=@{};$script:HostPanel=New-Object Windows.Controls.StackPanel
 $script:Window=New-Object Windows.Window
 foreach($name in @('Btn','Primary','Ghost','Danger')){$script:Window.Resources.Add($name,(New-Object Windows.Style([Windows.Controls.Button])))}
 function B {param([string]$Hex)$c=New-Object Windows.Media.BrushConverter;return $c.ConvertFromString($Hex)}
 function AddC {param($Parent,$Child)$null=$Parent.Children.Add($Child)}
 function T {param([string]$Text,[double]$Size=13,[string]$Color=$script:Ink,[string]$Weight='Normal')
  $t=New-Object Windows.Controls.TextBlock;$t.Text=$Text;$t.FontSize=$Size;$t.Foreground=B $Color;$t.FontWeight=$Weight;return $t}
 function Stack {param([string]$Orientation='Vertical')$s=New-Object Windows.Controls.StackPanel;$s.Orientation=$Orientation;return $s}
 function Card {param([string]$Padding='22,20')$b=New-Object Windows.Controls.Border;$b.Background=B '#FFFFFF';$b.BorderBrush=B $script:Hair;$b.BorderThickness='1';$b.CornerRadius='14';$b.Padding=[Windows.Thickness]$Padding;return $b}
 function Margin {param($Element,[string]$Value)$Element.Margin=[Windows.Thickness]$Value;return $Element}
 function Grid {param([string[]]$Columns)$g=New-Object Windows.Controls.Grid;foreach($w in $Columns){$c=New-Object Windows.Controls.ColumnDefinition;$c.Width=$w;$g.ColumnDefinitions.Add($c)};return $g}
 function Cell {param($Grid,$Child,[int]$Column=0)[Windows.Controls.Grid]::SetColumn($Child,$Column);AddC $Grid $Child}
 function ControlName {param($Control,[string]$Id)$Control.Name=$Id;$script:Controls[$Id]=$Control;return $Control}
 function Btn {param([string]$Text,[string]$Id,[scriptblock]$Click,[string]$Style='Btn')
  $b=New-Object Windows.Controls.Button;$b.Content=$Text;$b.Add_Click($Click);if($Id){$b=ControlName $b $Id};return $b}
 function Note {param([string]$Text,[string]$Tone='blue')$t=New-Object Windows.Controls.TextBlock;$t.Text=$Text;return $t}
 function PageHead {param([string]$Title,[string]$Description,[string]$Page)$script:HostPanel.Children.Clear();$script:Controls=@{};$script:Page=$Page}
 function IsBusy {return $false}
 function Toast {param([string]$Message)$script:LastToast=$Message}
 function ChooseFile {param($Title,$Filter,[switch]$Save,$Name)return ''}
 function OpenDialog {param([string]$Title,[string]$Body,[string]$Note,[string]$Confirm='确定',[scriptblock]$Action=$null,[string]$Cancel='取消',[string]$ConfirmStyle='Primary',$Context=$null,[switch]$SafeDefault)
  $script:LastDialog=[pscustomobject]@{Title=$Title;Body=$Body;Note=$Note;Confirm=$Confirm;Action=$Action;Context=$Context}}
 # ChangeTradeApplication is defined by the page itself; record what it dispatches.
 function StartJob {param($Request,$Complete,$Message)
  $script:LastChange=[pscustomobject]@{Kind=$Request.Kind;Operation=$Request.Operation;Value=$Request.Value;Revision=$Request.Revision}}

 . (Join-Path $SourceDirectory 'ui\TradeApplicationPages.ps1')

 $script:TradeApplicationState=[pscustomobject]@{
  Revision=3;SnapshotToken=('a'*64);Programs=@([pscustomobject]@{Path='C:\apps\terminal64.exe';Name='terminal64.exe';Missing=$false;Applied=$true})
  AppliedPrograms=@('C:\apps\terminal64.exe');Domains=@('tradingview.com');AppliedDomains=@('tradingview.com')
  HasLine=$true;NeedsPolicyUpdate=$false;HasUndo=$true;NetworkChanged=$false;Message='名单已在当前线路生效。'
 }
 ShowTradeApplicationManager

 $input=$script:Controls['TradeProgramInput']
 Check ($input -is [Windows.Controls.TextBox]) 'The trade-program page exposes a text input for the program path'
 Check ($input.Name -ceq 'TradeProgramInput') 'The input keeps a stable control name for the host drop handler'
 $add=$script:Controls['AddTradeProgram'];$browse=$script:Controls['BrowseTradeProgram']
 Check ($add -is [Windows.Controls.Button] -and $browse -is [Windows.Controls.Button]) 'The page offers both 浏览… and 添加程序 next to the input'

 $script:LastToast='';$script:LastChange=$null
 $add.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent,$add)))
 Check (-not $script:LastChange -and $script:LastToast -match '拖进输入框') 'An empty path is refused with a hint instead of submitting'

 $input.Text='  "C:\apps\terminal64.exe"  '
 $add.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent,$add)))
 Check ($script:LastChange -and $script:LastChange.Kind -ceq 'Program' -and $script:LastChange.Operation -ceq 'Add' -and $script:LastChange.Value -ceq 'C:\apps\terminal64.exe') 'A pasted or dropped path is trimmed, unquoted and submitted as a program add'

 # 未生效的程序在「移除」左侧直接给出「启用」，形成「添加 → 未生效 → 启用」的闭环，
 # 不必再滚回页面顶部去找「应用到当前线路」。
 $script:TradeApplicationState.Programs=@($script:TradeApplicationState.Programs)+[pscustomobject]@{Path='C:\apps\pending.exe';Name='pending.exe';Missing=$false;Applied=$false}
 $script:TradeApplicationState.NeedsPolicyUpdate=$true
 $script:LastDialog=$null
 ShowTradeApplicationManager
 Check (-not $script:Controls.ContainsKey('EnableTradeProgram0')) 'A program that is already in effect does not offer 启用'
 Check ($script:Controls.ContainsKey('EnableTradeProgram1')) 'A program that is not in effect offers 启用 next to 移除'
 $enable=$script:Controls['EnableTradeProgram1']
 Check ([string]$enable.Content -ceq '启用') 'The per-row action is labelled 启用'
 $enable.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent,$enable)))
 Check ($script:LastDialog -and [string]$script:LastDialog.Title -match '应用交易软件名单') '启用 opens the same apply confirmation as the page-level button'
 $pageSource=[IO.File]::ReadAllText((Join-Path $SourceDirectory 'ui\TradeApplicationPages.ps1'))
 Check ($pageSource -match '· 未生效' -and $pageSource -notmatch '· 待应用') 'The row status reads 未生效, matching the 已生效 wording'
 $input=$script:Controls['TradeProgramInput']

 # 撤销上次名单修改 is gone from the page; the three program controls stay.
 Check (-not $script:Controls.ContainsKey('UndoTradePrograms')) 'The page no longer offers 撤销上次名单修改'
 Check ($script:Controls.ContainsKey('TradeProgramInput') -and $script:Controls.ContainsKey('BrowseTradeProgram') -and $script:Controls.ContainsKey('AddTradeProgram')) 'Adding and browsing a program still have their own controls'

 # The host answers a drop only for this exact input, and only through the
 # form-view handle the browser echoes back (wf-<32 hex>).
 $script:PackageRoot=$SourceDirectory
 . (Join-Path $SourceDirectory 'ui\WebShell.ps1')

 $handles=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
 $goodId='wf-'+('0123456789abcdef'*2)
 $otherId='wf-'+('fedcba9876543210'*2)
 $buttonId='wf-'+('0011223344556677'*2)
 $missingId='wf-'+('89abcdef01234567'*2)
 $wrongName=New-Object Windows.Controls.TextBox;$wrongName.Name='TradeDomainInput'
 $button=New-Object Windows.Controls.Button;$button.Name='TradeProgramInput'
 $handles[$goodId]=[pscustomobject]@{Control=$input;Mode='input';Hidden=$false;Closed=$false;Enabled=$true;ReadOnly=$false;MaxLength=1024;Items=@()}
 $handles[$otherId]=[pscustomobject]@{Control=$wrongName;Mode='input';Hidden=$false;Closed=$false;Enabled=$true;ReadOnly=$false;MaxLength=1024;Items=@()}
 $handles[$buttonId]=[pscustomobject]@{Control=$button;Mode='button';Hidden=$false;Closed=$false;Enabled=$true;ReadOnly=$false;MaxLength=0;Items=@()}
 $script:TCWebFormView=[pscustomobject]@{Generation='g';Title='';Description='';Page='nodes';Handles=$handles}
 Check ($null -eq (GetTCWebFileDropControl 'TradeProgramInput')) 'A control name is not a form handle and is refused'
 Check ($null -eq (GetTCWebFileDropControl 'wf-nothex')) 'A malformed handle is refused'
 Check ($null -eq (GetTCWebFileDropControl $missingId)) 'A handle that the current form view never issued is refused'
 Check ($null -eq (GetTCWebFileDropControl $buttonId)) 'A non-text control is never a drop target'
 Check ($null -eq (GetTCWebFileDropControl $otherId)) 'A text box that is not the trade-program input is refused'
 Check ([object]::ReferenceEquals((GetTCWebFileDropControl $goodId),$input)) 'The trade-program input handle is the only accepted drop target'
 $script:TCWebFormView=$null
 Check ($null -eq (GetTCWebFileDropControl $goodId)) 'Without a rendered form view nothing is a drop target'

 # Dropped paths are validated before they reach the control.
 Check ([string](TestTCWebDroppedProgram '') -ceq '请拖入 .exe 程序文件。') 'An empty dropped path is refused'
 # 1024 是页面上输入框的 MaxLength：再长的路径会被输入框截断，显示的和提交的
 # 就不是同一个值，所以宿主必须拒绝而不是静默截断。
 $longPath='C:\'+('a'*1022)
 Check ($longPath.Length -eq 1025 -and [string](TestTCWebDroppedProgram $longPath) -ceq '程序路径过长，请把程序放到更短的目录下。') 'A path longer than the input limit is refused instead of being truncated'
 $limitPath='C:\'+('a'*1017)+'.exe'
 Check ($limitPath.Length -eq 1024 -and [string](TestTCWebDroppedProgram $limitPath) -ceq '') 'A path exactly at the input limit is still accepted'
 Check ([string](TestTCWebDroppedProgram $SourceDirectory) -ceq '请拖入 .exe 程序文件，而不是文件夹。') 'A dropped folder is refused'
 Check ([string](TestTCWebDroppedProgram 'C:\apps\notes.txt') -ceq '只能添加 .exe 程序文件，你拖入的是 .txt 文件。') 'A non-executable file is refused and the actual extension is named'
 Check ([string](TestTCWebDroppedProgram 'C:\apps\terminal64.exe') -ceq '') 'A lower-case .exe path is accepted'
 Check ([string](TestTCWebDroppedProgram 'C:\Apps\Terminal64.ExE') -ceq '') 'A mixed-case .EXE path is accepted'

 # 桌面和开始菜单上的程序几乎都是快捷方式（.lnk），Windows 又默认隐藏扩展名，用户看不出
 # 差别。拖入快捷方式必须解析到目标程序，否则桌面上的程序永远加不上。
 $linkRoot=Join-Path ([IO.Path]::GetTempPath()) ('tc-drop-'+[guid]::NewGuid().ToString('N'))
 $null=[IO.Directory]::CreateDirectory($linkRoot)
 $fakeExe=Join-Path $linkRoot 'fake-terminal.exe';[IO.File]::WriteAllText($fakeExe,'stub')
 function NewTestShortcut {param([string]$Path,[string]$Target)
  $shell=New-Object -ComObject WScript.Shell;$link=$null
  try{$link=$shell.CreateShortcut($Path);$link.TargetPath=$Target;$link.Save()}
  finally{if($link){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($link)};[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}}
 $lnk=Join-Path $linkRoot 'Terminal.lnk';NewTestShortcut $lnk $fakeExe
 Check ([string](ResolveTCWebShortcut $lnk) -ceq $fakeExe) 'A desktop shortcut resolves to the program it points at'
 Check ([string](ResolveTCWebShortcut $fakeExe) -ceq $fakeExe) 'A real .exe path passes through the resolver unchanged'
 $nested=Join-Path $linkRoot 'Nested.lnk';NewTestShortcut $nested $lnk
 Check ([string](ResolveTCWebShortcut $nested) -ceq $fakeExe) 'A shortcut to a shortcut still resolves to the program'
 Check ([string](ResolveTCWebShortcut '') -ceq '') 'An empty path has no shortcut to resolve'
 $broken=Join-Path $linkRoot 'Broken.lnk';NewTestShortcut $broken (Join-Path $linkRoot 'gone.exe')

 # The message gate validates the origin and the message type before any write.
 $badOrigin=[pscustomobject]@{Source='https://evil.example/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@()}
 Check ((ReceiveTCWebFileDrop $badOrigin) -eq $false) 'A drop from another origin is ignored'
 $notADrop=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"theme","Value":"dark"}';AdditionalObjects=@()}
 Check ((ReceiveTCWebFileDrop $notADrop) -eq $false) 'A normal web message is not treated as a drop'
 $unknownTarget=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"wf-nothex"}';AdditionalObjects=@()}
 Check ((ReceiveTCWebFileDrop $unknownTarget) -eq $false) 'A drop aimed at a non-target handle is ignored'

 # 恢复 form view 才能走到「目标合法、但没有附加对象」这一支。
 $script:TCWebFormView=[pscustomobject]@{Generation='g';Title='';Description='';Page='nodes';Handles=$handles}
 $script:Dialogs=New-Object 'Collections.Generic.List[string]'
 function ErrorDialog {param([string]$Message)$script:Dialogs.Add([string]$Message)}
 $noFiles=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@()}
 Check ((ReceiveTCWebFileDrop $noFiles) -eq $false -and $script:Dialogs.Count -eq 0) 'A fileDrop message with no attached file falls through without a dialog'
 $twoFiles=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@('a.exe','b.exe')}
 Check ((ReceiveTCWebFileDrop $twoFiles) -eq $true -and $script:Dialogs.Count -eq 1 -and $script:Dialogs[0] -match '一次只能拖入一个程序文件') 'Two dropped files are reported instead of silently picking one'

 # 快捷方式落到输入框：解析成功就填真实 .exe，解析失败就说清原因，绝不填一个死路径。
 $script:Dialogs.Clear()
 $brokenDrop=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@([pscustomobject]@{Path=$broken})}
 Check ((ReceiveTCWebFileDrop $brokenDrop) -eq $true -and $script:Dialogs.Count -eq 1 -and $script:Dialogs[0] -match '快捷方式') 'A shortcut whose target is gone is reported instead of filling a dead path'
 $script:Dialogs.Clear()
 $hostLnk=Join-Path $linkRoot 'Script.lnk';NewTestShortcut $hostLnk (Join-Path $env:SystemRoot 'System32\wscript.exe')
 $hostDrop=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@([pscustomobject]@{Path=$hostLnk})}
 Check ((ReceiveTCWebFileDrop $hostDrop) -eq $true -and $script:Dialogs.Count -eq 1 -and $script:Dialogs[0] -match '脚本') 'A shortcut that launches through a script host is refused instead of protecting the host'
 $input.Text='';$script:LastToast=''
 $lnkDrop=[pscustomobject]@{Source='https://tradechannel.local/index.html';WebMessageAsJson='{"Type":"fileDrop","Target":"'+$goodId+'"}';AdditionalObjects=@([pscustomobject]@{Path=$lnk})}
 Check ((ReceiveTCWebFileDrop $lnkDrop) -eq $true -and $input.Text -ceq $fakeExe) 'Dropping a shortcut fills the input with the real program path'
 Check ($script:LastToast -match '快捷方式') 'Filling from a shortcut tells the user which program was used'
 try{Remove-Item -LiteralPath $linkRoot -Recurse -Force}catch{}

 $result=[pscustomobject]@{Passed=$true;Checks=$checks.Count;Details=@($checks);NetworkChanges=0}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
 $result|Select-Object Passed,Checks,NetworkChanges
}catch{
 $failure=[pscustomobject]@{Passed=$false;Checks=$checks.Count;Error=$_.Exception.Message;Details=@($checks)}
 if($ReportPath){[IO.File]::WriteAllText($ReportPath,($failure|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))}
 throw
}
