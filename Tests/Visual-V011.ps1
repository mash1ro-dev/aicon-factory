param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $script:VisualResults=[Collections.Generic.List[object]]::new()
 function Require([bool]$ok,[string]$why){if(-not $ok){throw $why}}
 function Check($name,$body){try{&$body;$script:VisualResults.Add(@{Name=$name;Passed=$true});Write-Host ('PASS '+$name)}catch{$script:VisualResults.Add(@{Name=$name;Passed=$false;Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 function Capture($w,$name){$w.UpdateLayout();$w.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render);$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($w);$b=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($w.ActualWidth*$dpi.DpiScaleX),[int]($w.ActualHeight*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32);$b.Render($w);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($b));$s=[IO.File]::Create((Join-Path $run.Results ($name+'.png')));try{$enc.Save($s)}finally{$s.Dispose()}}
 Add-Type -AssemblyName System.Drawing
 $paths=@();for($n=1;$n -le 30;$n++){$p=Join-Path $run.Root ('長い画像名を確認するための日本語ファイル名-'+$n+'.png');$b=[Drawing.Bitmap]::new(100,80);$g=[Drawing.Graphics]::FromImage($b);try{$g.Clear([Drawing.Color]::Transparent);$g.FillEllipse([Drawing.Brushes]::CornflowerBlue,10,10,80,60);$b.Save($p,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()};$paths+=$p}
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $run.Root -UserDataRoot $run.Root -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work {$end=[DateTime]::UtcNow.AddSeconds(90);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy) 'Worker timeout'}
  $window.Show();$window.UpdateLayout();Capture $window 'initial-150'
  Check '12 thirty long filenames and scrollable numbers at actual DPI' {
   &$actions.Add $paths;Click $ui.GenerateButton;Wait-Work;Require ($state.Succeeded -eq 30 -and $ui.NumberPanel.Children.Count -eq 30) 'Missing item'
   Click $ui.NumberPanel.Children[29];$ui.InputList.ScrollIntoView($state.Items[29]);$window.UpdateLayout()
   Require ($state.CurrentId -eq $state.Items[29].Id -and $ui.CurrentLabel.Text.Contains($state.Items[29].FileName)) 'Last item linkage'
   $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window);Require ([Math]::Abs($ui.Preview256.Width*$dpi.DpiScaleX-256) -lt 0.01) 'Preview physical pixel size'
   Require ($ui.BodyScroller.ExtentWidth -le $ui.BodyScroller.ViewportWidth+1 -and $ui.NumberScroller.HorizontalOffset -gt 0) 'Body overflow/current number offscreen'
   $state.Items[29].SaveChecked=$true;&$actions.Refresh;Capture $window 'thirty-150'
  }
  Check '11 category and shortcut combo popup open/select/close' {
   $ui.ShortcutPanel.Visibility='Visible';$ui.ShortcutSettings.IsExpanded=$true;$window.UpdateLayout()
   foreach($c in @($ui.CategoryBox,$ui.DestinationBox)){$c.ApplyTemplate()|Out-Null;$c.IsDropDownOpen=$true;$window.UpdateLayout();$popup=$c.Template.FindName('PART_Popup',$c);Require ($popup.IsOpen) 'Popup did not open';$c.SelectedIndex=1;Require ($c.SelectedIndex -eq 1) 'Selection failed';$c.IsDropDownOpen=$false;Require (-not $popup.IsOpen) 'Popup did not close';$c.SelectedIndex=0}
  }
  Check '12 compact and wide windows keep footer and allow body scroll' {
   foreach($width in @(840,1200)){$window.Width=$width;$window.Height=680;$window.UpdateLayout();$ui.BodyScroller.ScrollToBottom();$window.UpdateLayout();Require ($ui.BodyScroller.ScrollableHeight -gt 0 -and $ui.OpenLocationButton.IsVisible) 'Footer/scroll missing';Capture $window ('width-'+$width+'-bottom')}
  }
  Check '9 actual confirmation dialog cancel is default; exact folder wording' {
   $inspect=[Windows.Threading.DispatcherTimer]::new();$inspect.Interval=[TimeSpan]::FromMilliseconds(200)
   $script:DialogChecked=$false;$script:DialogError=''
   $inspect.Add_Tick({$inspect.Stop();try{$dialog=$window.OwnedWindows[0];$buttons=$dialog.Content.Children[$dialog.Content.Children.Count-1].Children;Require ($buttons[0].Content -eq 'やめる' -and $buttons[0].IsDefault -and $buttons[1].Content -eq 'このアイコンにする') 'Dialog buttons';Capture $dialog 'folder-confirm';$script:DialogChecked=$true}catch{$script:DialogError=$_.ToString()}finally{$window.OwnedWindows[0].DialogResult=$false}})
   $inspect.Start();$answer=Show-AiconChoice $window "このフォルダのアイコンを『image-2.ico』に変えるよ。`n中に入っているファイルはそのままです。" 'このアイコンにする' 'やめる'
   Require ($script:DialogChecked -and -not $answer.Accepted) ('Dialog inspection '+$script:DialogError)
  }
  Check '10 type menu has exact folder and file choices with cancel default' {
   $inspect=[Windows.Threading.DispatcherTimer]::new();$inspect.Interval=[TimeSpan]::FromMilliseconds(200);$script:PickerChecked=$false;$script:DialogError=''
   $inspect.Add_Tick({$inspect.Stop();try{$dialog=$window.OwnedWindows[0];$children=$dialog.Content.Children;Require ($children.Count -eq 3 -and $children[0].Content.Children[0].Text -eq 'フォルダを選ぶ' -and $children[0].Content.Children[1].Text -eq 'フォルダの見た目を変えるよ。' -and $children[1].Content.Children[0].Text -eq 'ファイル・ショートカットを選ぶ' -and $children[1].Content.Children[1].Text -eq 'ファイルからショートカットを作ったり、今あるショートカットの見た目を変えられるよ。' -and $children[2].IsDefault) 'Menu choices';Capture $dialog 'target-kind-menu';$script:PickerChecked=$true}catch{$script:DialogError=$_.ToString()}finally{$window.OwnedWindows[0].DialogResult=$false}})
   $inspect.Start();$picked=Show-AiconTargetKindMenu $window;Require ($script:PickerChecked -and -not $picked) ('Picker inspection '+$script:DialogError)
  }
  Check '10 actual menu buttons return Folder and File respectively' {
   foreach($pick in @('Folder','File')){
    $script:MenuPick=$pick;$inspect=[Windows.Threading.DispatcherTimer]::new();$inspect.Interval=[TimeSpan]::FromMilliseconds(150)
    $inspect.Add_Tick({$inspect.Stop();$dialog=$window.OwnedWindows[0];$button=$dialog.Content.Children|Where-Object Tag -eq $script:MenuPick;Click $button})
    $inspect.Start();Require ((Show-AiconTargetKindMenu $window) -eq $pick) 'Menu selection returned wrong kind'
   }
  }
  Check '9 multiple-image warning renders exact controls and number' {
   $prompt=Get-AiconApplyPrompt @{CheckedCount=3;Number=2;IconName='image-2.ico'} 'Multiple'
   $inspect=[Windows.Threading.DispatcherTimer]::new();$inspect.Interval=[TimeSpan]::FromMilliseconds(150);$script:DialogChecked=$false;$script:DialogError=''
   $inspect.Add_Tick({$inspect.Stop();try{$dialog=$window.OwnedWindows[0];$buttons=$dialog.Content.Children[$dialog.Content.Children.Count-1].Children;Require ($buttons[0].Content -eq 'プレビューに戻る' -and $buttons[0].IsDefault -and $buttons[1].Content -eq 'この1枚を設定する' -and $dialog.Content.Children[0].Text.Contains('2番：image-2.ico')) 'Multiple controls';Capture $dialog 'multiple-confirm';$script:DialogChecked=$true}catch{$script:DialogError=$_.ToString()}finally{$window.OwnedWindows[0].DialogResult=$false}})
   $inspect.Start();$answer=Show-AiconChoice $window $prompt.Message $prompt.Accept $prompt.Cancel;Require ($script:DialogChecked -and -not $answer.Accepted) $script:DialogError
  }
  Check '9 shortcut explanation checkbox exact and cancel default' {
   $prompt=Get-AiconApplyPrompt @{Destination='Desktop'} 'Explain'
   $inspect=[Windows.Threading.DispatcherTimer]::new();$inspect.Interval=[TimeSpan]::FromMilliseconds(150);$script:DialogChecked=$false;$script:DialogError=''
   $inspect.Add_Tick({$inspect.Stop();try{$dialog=$window.OwnedWindows[0];$buttons=$dialog.Content.Children[2].Children;Require ($dialog.Content.Children[1].Content -eq '次からこの説明を表示しない' -and $buttons[0].Content -eq 'やめる' -and $buttons[0].IsDefault -and $buttons[1].Content -eq 'ショートカットを作る') 'Explanation controls';Capture $dialog 'shortcut-explanation';$script:DialogChecked=$true}catch{$script:DialogError=$_.ToString()}finally{$window.OwnedWindows[0].DialogResult=$false}})
   $inspect.Start();$answer=Show-AiconChoice $window $prompt.Message $prompt.Accept $prompt.Cancel -Remember;Require ($script:DialogChecked -and -not $answer.Accepted) $script:DialogError
  }
  Check '5 close during conversion waits for current item and stops queue' {
   foreach($item in $state.Items){$item.Result=$null;$item.SavedPath='';$item.Status='未変換'};&$actions.Refresh;Click $ui.GenerateButton;$state.DialogResponder={@{Accepted=$true;Remember=$false}};$window.Close();Wait-Work
   Require ($state.Closed -and $state.Succeeded -le 1 -and @(Get-ChildItem $run.Root -Filter '*.ico' -Recurse).Count -eq 0) 'Close safety'
  }
 }
 $script:VisualResults|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'visual.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:VisualResults|Where-Object Passed).Count+' PASS; '+$run.Results)
 if(@($script:VisualResults|Where-Object {-not $_.Passed}).Count){exit 1}
} $app $run
