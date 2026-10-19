param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $script:RepeatCases=[Collections.Generic.List[object]]::new();$script:ConfirmCount=0;$script:Accept=$true
 function Require($ok,$why){if(-not $ok){throw $why}}
 function Check($name,$expectation,$body){try{&$body;$script:RepeatCases.Add(@{Name=$name;Expectation=$expectation;Status='PASS';Method='SameSessionWpfHarness'});Write-Host ('PASS '+$name)}catch{$script:RepeatCases.Add(@{Name=$name;Expectation=$expectation;Status='FAIL';Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 function Snapshot{return (@(Get-ChildItem -LiteralPath $run.Root -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join "`n")}
 Add-Type -AssemblyName System.Drawing
 $paths=@();$hashes=@{};for($n=1;$n -le 4;$n++){$p=Join-Path $run.Root ('image-'+$n+'.png');$im=[Drawing.Bitmap]::new(60,60);$g=[Drawing.Graphics]::FromImage($im);try{$g.Clear([Drawing.Color]::FromArgb(255,45*$n,50,160));$im.Save($p,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$im.Dispose()};$paths+=$p;$hashes[$p]=(Get-FileHash $p).Hash}
 $folders=@{};foreach($name in @('A','B','C','Retry','Out')){$p=Join-Path $run.Root $name;[void][IO.Directory]::CreateDirectory($p);$folders[$name]=$p}
 $dummy=Join-Path $run.Root 'never-execute.exe';[IO.File]::WriteAllText($dummy,'owned only');$hashes[$dummy]=(Get-FileHash $dummy).Hash
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $run.Root -UserDataRoot (Join-Path $run.Root 'Data') -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work($allowFailure=$false){$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and ($allowFailure -or $state.Failed -eq 0)) $ui.StatusText.Text}
  function Apply-To($path){$ui.TargetBox.Text=$path;Require $ui.ApplyButton.IsEnabled 'Apply should be enabled';Click $ui.ApplyButton;Wait-Work}
  function Folder-Uses($folder,$ico){return [IO.File]::ReadAllText((Join-Path $folder 'desktop.ini')).Contains($ico)}
  function Ico-Count{return @(Get-ChildItem $run.Root -Recurse -File -Filter *.ico).Count}
  function Capture($name){$ui.BodyScroller.ScrollToBottom();$window.UpdateLayout();$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window);$bmp=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($window.ActualWidth*$dpi.DpiScaleX),[int]($window.ActualHeight*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32);$bmp.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp));$f=[IO.File]::Create((Join-Path $run.Results ($name+'.png')));try{$encoder.Save($f)}finally{$f.Dispose()}}
  $state.DialogResponder={param($message,$accept,$cancel,$remember) $script:ConfirmCount++;@{Accepted=$script:Accept;Remember=$false}};$window.Show();$window.UpdateLayout()
  Check 'A one saved ICO applies A then B then C using More in the same session' 'NormalSuccessAndPreservation' {
   &$actions.Add @($paths[0]);Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work;$id=$state.CurrentId;$ico=$state.Items[0].SavedPath;$checks=@($state.Items|ForEach-Object SaveChecked)
   foreach($target in @('A','B','C')){
    Apply-To $folders[$target];Require ((Folder-Uses $folders[$target] $ico) -and $ui.StatusText.Text.StartsWith('アイコンを設定したよ。見た目が変わらないときは、少し待ってみてね。') -and $ui.ApplyMoreButton.Visibility -eq 'Visible') 'Success/More missing'
    if($target -eq 'A'){Capture 'after-success-more'}
    $before=Snapshot;$dest=$ui.DestinationBox.SelectedIndex;$output=$ui.OutputDirectoryBox.Text;$name=$ui.ShortcutNameBox.Text;Click $ui.ApplyMoreButton
    Require ($ui.TargetBox.Text -eq '' -and $state.CurrentId -eq $id -and $state.Items[0].SavedPath -eq $ico -and $state.Items[0].SaveChecked -eq $checks[0] -and $ui.DestinationBox.SelectedIndex -eq $dest -and $ui.OutputDirectoryBox.Text -eq $output -and $ui.ShortcutNameBox.Text -eq $name -and (Snapshot) -ceq $before) 'More changed data or selection'
   };Require ((Ico-Count) -eq 1) 'Repeated apply generated ICOs'
  }
  Check 'Same ICO on previously completed target remains blocked after More and other targets' 'SafeDuplicateRejection' {
   $ui.TargetBox.Text=$folders.A;&$actions.Refresh;Require (-not $ui.ApplyButton.IsEnabled) 'Duplicate enabled';$before=Snapshot;$prompts=$script:ConfirmCount;Click $ui.ApplyButton;Require (-not $state.Busy -and (Snapshot) -ceq $before -and $script:ConfirmCount -eq $prompts) 'Duplicate applied'
  }
  Check 'B three saved ICOs: current one to A, switch to two and apply B in same session' 'NormalSuccessAndPreservation' {
   Click $ui.ClearButton;&$actions.Add @($paths[0],$paths[1],$paths[2]);Click $ui.GenerateButton;Wait-Work;Click $ui.CheckAllButton;Click $ui.SaveButton;Wait-Work
   Click $ui.NumberPanel.Children[0];Apply-To $folders.A;Require (Folder-Uses $folders.A $state.Items[0].SavedPath) 'A wrong ICO'
   Click $ui.NumberPanel.Children[1];Require ($ui.ApplyButton.IsEnabled) 'ICO switch left disabled';Apply-To $folders.B
   Require ((Folder-Uses $folders.B $state.Items[1].SavedPath) -and @($state.Items|Where-Object SaveChecked).Count -eq 3 -and (Ico-Count) -eq 4) 'B wrong ICO/checks/save count'
  }
  Check 'Different saved ICO can replace same target and later switch back' 'NormalSuccessWithDuplicateRejection' {
   $ui.TargetBox.Text=$folders.A;&$actions.Refresh;Require $ui.ApplyButton.IsEnabled 'Different ICO blocked';Click $ui.ApplyButton;Wait-Work;Require (Folder-Uses $folders.A $state.Items[1].SavedPath) 'Second ICO missing'
   Require (-not $ui.ApplyButton.IsEnabled) 'Same target duplicate enabled';Click $ui.NumberPanel.Children[0];Require $ui.ApplyButton.IsEnabled 'Switch-back blocked by historical pair';Click $ui.ApplyButton;Wait-Work;Require (Folder-Uses $folders.A $state.Items[0].SavedPath) 'First ICO not restored'
  }
  Check 'Cancelled confirmation leaves no completion record and can be retried' 'SafeCancellationThenNormalSuccess' {
   $ui.TargetBox.Text=$folders.Retry;$script:Accept=$false;$before=Snapshot;Click $ui.ApplyButton;Require ($ui.ApplyButton.IsEnabled -and (Snapshot) -ceq $before) 'Cancelled target disabled/mutated'
   $script:Accept=$true;Click $ui.ApplyButton;Wait-Work;Require (Folder-Uses $folders.Retry $state.Items[0].SavedPath) 'Retry failed'
  }
  Check 'Failed worker leaves target retryable; next successful apply disables only its duplicate' 'SafeFailureThenNormalSuccess' {
   $locked=Join-Path $run.Root 'Locked';[void][IO.Directory]::CreateDirectory($locked);$ini=Join-Path $locked 'desktop.ini';[IO.File]::WriteAllText($ini,'keep');$ui.TargetBox.Text=$locked;$handle=[IO.File]::Open($ini,'Open','ReadWrite','None')
   try{Click $ui.ApplyButton;Wait-Work $true;Require ($state.Failed -eq 1 -and $ui.ApplyButton.IsEnabled -and -not $ui.StatusText.Text.Contains('設定できたよ')) 'Failure marked completed'}finally{$handle.Dispose()}
   Click $ui.ApplyButton;Wait-Work;Require (-not $ui.ApplyButton.IsEnabled -and (Folder-Uses $locked $state.Items[0].SavedPath)) 'Retry not completed'
  }
  Check 'C clear all after success then new image preview/save/apply in the same session' 'NormalSuccessAndPreservation' {
   $oldIcos=@(Get-ChildItem $run.Root -Recurse -File -Filter *.ico|ForEach-Object {@{Path=$_.FullName;Hash=(Get-FileHash $_.FullName).Hash}})
   Click $ui.ClearButton;Require ($state.Items.Count -eq 0 -and -not $ui.ApplyButton.IsEnabled) 'Clear retained old current';&$actions.Add @($paths[3]);Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work;Apply-To $folders.C
   Require ((Folder-Uses $folders.C $state.Items[0].SavedPath) -and (Ico-Count) -eq 5) 'New session work failed';foreach($i in $oldIcos){Require ((Get-FileHash $i.Path).Hash -eq $i.Hash) 'Old ICO removed/changed'}
  }
  Check 'New shortcut success retains actual output path and blocks identical duplicate' 'NormalSuccessWithDuplicateRejection' {
   $ui.TargetBox.Text=$dummy;$ui.DestinationBox.SelectedIndex=2;$ui.OutputDirectoryBox.Text=$folders.Out;$ui.ShortcutNameBox.Text='repeat';Click $ui.ApplyButton;Wait-Work;$created=Join-Path $folders.Out 'repeat.lnk'
   Require ([IO.File]::Exists($created) -and $ui.StatusText.Text.Contains($created) -and -not $ui.ApplyButton.IsEnabled -and $ui.ApplyMoreButton.Visibility -eq 'Visible') 'Shortcut path/duplicate guard'
   Click $ui.ApplyMoreButton;$ui.TargetBox.Text=$dummy;$ui.ShortcutNameBox.Text='repeat';&$actions.Refresh;Require (-not $ui.ApplyButton.IsEnabled) 'Same shortcut request enabled after More'
  }
  Check 'Inputs, saved checks, 256 preview and seven ICO frames remain intact' 'Preservation' {
   foreach($p in $hashes.Keys){Require ((Get-FileHash $p).Hash -eq $hashes[$p]) 'Input changed'}
   Require ($state.Items[0].SaveChecked -and $ui.Preview256.Source.PixelWidth -eq 256 -and [BitConverter]::ToUInt16([IO.File]::ReadAllBytes($state.Items[0].SavedPath),4) -eq 7) 'Core behavior changed'
  }
  $state.AllowClose=$true;$window.Close()
 }
 $script:RepeatCases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'repeat-apply.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:RepeatCases|Where-Object Status -eq PASS).Count+' PASS / '+@($script:RepeatCases|Where-Object Status -eq FAIL).Count+' FAIL; '+$run.Results)
 if(@($script:RepeatCases|Where-Object Status -eq FAIL).Count){exit 1}
} $app $run
