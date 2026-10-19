param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $script:Cases=[Collections.Generic.List[object]]::new();$script:Prompts=[Collections.Generic.List[object]]::new();$script:CancelAt=0;$script:Mutation=$null;$script:Remember=$false
 function Require($ok,$why){if(-not $ok){throw $why}}
 function Check($name,$body){try{&$body;$script:Cases.Add(@{Name=$name;Passed=$true});Write-Host ('PASS '+$name)}catch{$script:Cases.Add(@{Name=$name;Passed=$false;Error=$_.ToString();Line=$_.InvocationInfo.ScriptLineNumber});Write-Host ('FAIL '+$name+': '+$_+' LINE '+$_.InvocationInfo.ScriptLineNumber)}}
 function Snapshot{return (@(Get-ChildItem -LiteralPath $run.Root -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash+'|'+$_.LastWriteTimeUtc.ToString('o')}) -join "`n")}
 Add-Type -AssemblyName System.Drawing,PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
 $paths=@();$sourceHashes=@{};$targets=@{};$data=Join-Path $run.Root 'Data';$out=Join-Path $run.Root 'Shortcuts';$targetFolder=Join-Path $run.Root 'Folder';[void][IO.Directory]::CreateDirectory($out);[void][IO.Directory]::CreateDirectory($targetFolder)
 [IO.File]::WriteAllText((Join-Path $targetFolder 'keep.txt'),'keep folder content');$sourceHashes[(Join-Path $targetFolder 'keep.txt')]=(Get-FileHash (Join-Path $targetFolder 'keep.txt')).Hash
 for($n=1;$n -le 3;$n++){$p=Join-Path $run.Root ('image-'+$n+'.png');$im=[Drawing.Bitmap]::new(80,60);$g=[Drawing.Graphics]::FromImage($im);try{$g.Clear([Drawing.Color]::FromArgb(255,50*$n,40,180));$im.Save($p,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$im.Dispose()};$paths+=$p;$sourceHashes[$p]=(Get-FileHash $p).Hash}
 foreach($ext in @('exe','ps1','bat','cmd')){$p=Join-Path $run.Root ('dummy.'+$ext);[IO.File]::WriteAllText($p,'Never execute this fixture');$targets[$ext]=$p;$sourceHashes[$p]=(Get-FileHash $p).Hash}
 $link=Join-Path $run.Root 'existing.lnk';$shell=New-Object -ComObject WScript.Shell;$ln=$shell.CreateShortcut($link);$ln.TargetPath=$targets.exe;$ln.Arguments='test-argument';$ln.WorkingDirectory=$run.Root;$ln.Description='keep metadata';$ln.Save();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ln);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $run.Root -UserDataRoot $data -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work{$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and $state.Failed -eq 0) 'Worker failed or timed out'}
  function Reset-Prompts($cancel=0){$script:Prompts.Clear();$script:CancelAt=$cancel;$script:Mutation=$null;$script:Remember=$false}
  function Target($p,$name='made'){$ui.TargetBox.Text=$p;$ui.DestinationBox.SelectedIndex=2;$ui.OutputDirectoryBox.Text=$out;$ui.ShortcutNameBox.Text=$name;&$actions.Refresh}
  $window.Show();$window.UpdateLayout()
  $state.DialogResponder={param($message,$accept,$cancel,$remember)
   $script:Prompts.Add(@{Message=$message;Accept=$accept;Cancel=$cancel;Remember=$remember})
   if($script:Mutation){&$script:Mutation}
   return @{Accepted=($script:CancelAt -eq 0 -or $script:Prompts.Count -ne $script:CancelAt);Remember=$script:Remember}
  }
  Check '01 Windows standard dialog types and link dereferencing disabled' {
   $d=New-AiconNativeTargetDialog 'File' $run.Root;Require ($d -is [Microsoft.Win32.OpenFileDialog] -and -not $d.DereferenceLinks -and -not $d.Multiselect -and $d.CheckFileExists -and $d.InitialDirectory -eq $run.Root) 'File dialog configuration'
   $d=New-AiconNativeTargetDialog 'Folder' $targetFolder;try{Require ($d -is [Windows.Forms.FolderBrowserDialog] -and $d.SelectedPath -eq $targetFolder -and -not $d.ShowNewFolderButton) 'Folder dialog configuration'}finally{$d.Dispose()}
  }
  Check '02 initial directory restores valid history; missing and AppData fall back' {
   $state.LastTargetSelectionDirectory=$targetFolder;Require ((Get-AiconTargetInitialDirectory $state @($out)) -eq $targetFolder) 'Valid history ignored'
   $state.LastTargetSelectionDirectory=Join-Path $run.Root 'missing';Require ((Get-AiconTargetInitialDirectory $state @($state.LastTargetSelectionDirectory,$out)) -eq $out) 'Missing history not skipped'
   $state.LastTargetSelectionDirectory=[Environment]::GetFolderPath('LocalApplicationData');Require ((Get-AiconTargetInitialDirectory $state @($out)) -eq $out) 'AppData used as initial directory'
   $state.LastTargetSelectionDirectory='';$first=Get-AiconTargetInitialDirectory $state;Require ($first -eq [Environment]::GetFolderPath('DesktopDirectory') -or $first -eq [Environment]::GetFolderPath('MyDocuments') -or $first -eq [Environment]::GetFolderPath('UserProfile')) 'Unexpected initial directory'
  }
  Check '03 unsaved text and preview-first generation; explicit full-size save' {
   &$actions.Add $paths;Target $targetFolder;Click $ui.GenerateButton;Wait-Work
   Require (-not $ui.ApplyButton.IsEnabled -and $ui.ApplyReason.Text -eq "このアイコンはまだ保存されていないよ。`n先に02で保存してから、ここで設定してね。") 'Unsaved explanation'
   Require (@(Get-ChildItem $run.Root -Recurse -File -Filter *.ico).Count -eq 0) 'Auto-saved ICO'
   Click $ui.CheckAllButton;Click $ui.SaveButton;Wait-Work;Click $ui.NumberPanel.Children[1]
   Require ($ui.ApplyButton.IsEnabled -and $ui.ApplyIconLabel.Text -eq 'いま設定するアイコン：2番 image-2.ico' -and [object]::ReferenceEquals($ui.ApplyPreview.Source,$ui.Preview256.Source)) 'Current preview/label mismatch'
  }
  Check '04 menu routes folder and file; last selection independent of ICO history' {
   Reset-Prompts;$history=$state.LastIcoSavedDirectory;$state.TargetKindPicker={'Folder'};$script:Pick=$targetFolder;$script:ExpectedKind='Folder'
   $state.NativeTargetPicker={param($kind,$initial) Require ($kind -eq $script:ExpectedKind -and [IO.Directory]::Exists($initial) -and -not $ui.ApplyButton.IsEnabled) 'Picker route/state';return $script:Pick}
   Click $ui.ChooseTargetButton;Require ($ui.TargetBox.Text -eq $targetFolder -and $script:Prompts.Count -eq 0) 'Folder selection/multiple warning during browsing'
   $state.TargetKindPicker={'File'};$script:ExpectedKind='File';$script:Pick=$link;Click $ui.ChooseTargetButton
   Require ($ui.TargetBox.Text -eq $link -and (Get-AiconTargetKind $ui.TargetBox.Text) -eq 'Shortcut') 'Shortcut became executable'
   Require ($state.LastIcoSavedDirectory -eq $history -and $state.LastTargetSelectionDirectory -eq $run.Root -and (New-AiconSession -Root $run.Root -UserDataRoot $data).LastTargetSelectionDirectory -eq $run.Root) 'History collision/restart'
  }
  Check '05 menu and native picker cancel leave every fixture unchanged' {
   $before=Snapshot;$targetBefore=$ui.TargetBox.Text;$state.TargetKindPicker={''};Click $ui.ChooseTargetButton;Require ((Snapshot) -ceq $before -and $ui.TargetBox.Text -eq $targetBefore) 'Menu cancel wrote data'
   $state.TargetKindPicker={'File'};$state.NativeTargetPicker={param($kind,$initial) ''};Click $ui.ChooseTargetButton;Require ((Snapshot) -ceq $before -and $ui.TargetBox.Text -eq $targetBefore) 'Native cancel wrote data'
  }
  Check '06 picker current change refreshes 03 to latest 02 without applying' {
   $state.TargetKindPicker={'File'};$state.NativeTargetPicker={param($kind,$initial) Set-AiconCurrent $state $state.Items[2].Id;return $targets.exe};Reset-Prompts;Click $ui.ChooseTargetButton
   Require ($ui.ApplyIconLabel.Text -eq 'いま設定するアイコン：3番 image-3.ico' -and $script:Prompts.Count -eq 0 -and -not $state.Busy) 'Stale picker current'
   Click $ui.NumberPanel.Children[1]
  }
  Check '07 drop handler auto-detects folder, lnk, exe, ps1, bat, cmd; rejects multiple' {
   foreach($p in @($targetFolder,$link,$targets.exe,$targets.ps1,$targets.bat,$targets.cmd)){
    &$actions.DropTargets @($p)
    Require ($ui.TargetBox.Text -eq $p -and (Get-AiconTargetKind $p) -ne 'Invalid') 'Drop routing'
   }
   $before=$ui.TargetBox.Text;&$actions.DropTargets @($targetFolder,$link);Require ($ui.TargetBox.Text -eq $before -and $ui.StatusText.Text.Contains('1つだけ')) 'Multiple drop accepted'
  }
  foreach($cancel in @(1,2,3)){
   Check ('08 cancel shortcut stage '+$cancel+' changes no file or settings') {
    Target $targets.exe ('cancel-'+$cancel);$state.SkipShortcutExplanation=$false;Reset-Prompts $cancel;$script:Remember=$true;$before=Snapshot;Click $ui.ApplyButton
    Require (-not $state.Busy -and -not $state.SkipShortcutExplanation -and $script:Prompts.Count -eq $cancel -and (Snapshot) -ceq $before) 'Cancel mutated data or remembered skip'
   }
  }
  Check '09 folder and existing-link final or multiple cancel leave backups and targets unchanged' {
   foreach($p in @($targetFolder,$link)){foreach($cancel in @(1,2)){Target $p;Reset-Prompts $cancel;$before=Snapshot;Click $ui.ApplyButton;Require (-not $state.Busy -and (Snapshot) -ceq $before -and $script:Prompts.Count -eq $cancel) 'Cancel changed target'}}
  }
  Check '10 changing current or target during accepted confirmation aborts safely' {
   Target $targetFolder;Reset-Prompts;$before=Snapshot;$script:Mutation={Set-AiconCurrent $state $state.Items[0].Id};Click $ui.ApplyButton
   Require (-not $state.Busy -and (Snapshot) -ceq $before -and $ui.StatusText.Text.Contains('設定を止めました')) 'Changed current applied'
   Click $ui.NumberPanel.Children[1];Target $targetFolder;Reset-Prompts;$script:Mutation={$ui.TargetBox.Text=$link};$before=Snapshot;Click $ui.ApplyButton
   Require (-not $state.Busy -and (Snapshot) -ceq $before -and $ui.StatusText.Text.Contains('設定を止めました')) 'Changed target applied';Reset-Prompts
  }
  Check '11 replaced ICO bytes during confirmation prevent application' {
   Target $targetFolder;Reset-Prompts;$script:Icon=$state.Items[1].SavedPath;$bytes=[IO.File]::ReadAllBytes($script:Icon);$script:Mutation={[IO.File]::WriteAllText($script:Icon,'changed by test')}
   try{Click $ui.ApplyButton;Require (-not $state.Busy -and -not [IO.File]::Exists((Join-Path $targetFolder 'desktop.ini')) -and $ui.StatusText.Text.Contains('設定を止めました')) 'Changed ICO applied'}finally{[IO.File]::WriteAllBytes($script:Icon,$bytes);Reset-Prompts}
  }
  Check '12 folder success uses current item two; multiple warning last and exact' {
   Target $targetFolder;Reset-Prompts;Click $ui.ApplyButton;Wait-Work
   $nl=[Environment]::NewLine;$expected="保存する画像が3枚選ばれているよ。${nl}${nl}ここで使うのは、いま02に表示している『2番：image-2.ico』の1枚です。${nl}${nl}このアイコンでいい？"
   Require ($script:Prompts.Count -eq 2 -and $script:Prompts[0].Message.StartsWith("このフォルダのアイコンを『image-2.ico』に変えるよ。${nl}中に入っているファイルはそのままです。") -and $script:Prompts[0].Accept -eq 'このアイコンにする' -and $script:Prompts[0].Cancel -eq 'やめる') 'Folder copy'
   Require ($script:Prompts[1].Message -eq $expected -and $script:Prompts[1].Accept -eq 'この1枚を設定する' -and $script:Prompts[1].Cancel -eq 'プレビューに戻る') 'Multiple copy/timing'
   Require ([IO.File]::ReadAllText((Join-Path $targetFolder 'desktop.ini')).Contains($state.Items[1].SavedPath) -and $ui.StatusText.Text.StartsWith('アイコンを設定したよ。見た目が変わらないときは、少し待ってみてね。') -and $state.LastBackupId) 'Wrong folder icon/status/backup'
  }
  Check '13 unchecked current saved item applies to existing link; link metadata preserved' {
   Click $ui.UncheckAllButton;Target $link;Reset-Prompts;Require ($ui.ApplyButton.IsEnabled) 'No save checks disabled apply';Click $ui.ApplyButton;Wait-Work
   Require ($script:Prompts.Count -eq 1 -and $script:Prompts[0].Message.StartsWith('このショートカットのアイコンを『image-2.ico』に変えるよ。') -and $ui.StatusText.Text.StartsWith('アイコンを設定できたよ。')) 'Shortcut copy'
   $shell=New-Object -ComObject WScript.Shell;$ln=$shell.CreateShortcut($link);try{Require ($ln.TargetPath -eq $targets.exe -and $ln.Arguments -eq 'test-argument' -and $ln.Description -eq 'keep metadata' -and $ln.IconLocation.StartsWith($state.Items[1].SavedPath)) 'Existing link changed target/metadata'}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ln);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
  }
  Check '14 custom destination explanation, final always shown, skip saved only after success' {
   Target $targets.exe 'collision';[IO.File]::WriteAllText((Join-Path $out 'collision.lnk'),'existing file stays');$collisionHash=(Get-FileHash (Join-Path $out 'collision.lnk')).Hash
   Reset-Prompts;$script:Remember=$true;Click $ui.ApplyButton;Wait-Work
   Require ($script:Prompts.Count -eq 2 -and $script:Prompts[0].Remember -and $script:Prompts[0].Message.Contains('好きなアイコンをつけたショートカットを作るよ。') -and $script:Prompts[0].Message.Contains('「'+$out+'」') -and -not $script:Prompts[0].Message.Contains('保存先はデスクトップ') -and $script:Prompts[0].Accept -eq 'ショートカットを作る') 'Explanation destination/copy'
   Require ($state.SkipShortcutExplanation -and (New-AiconSession -Root $run.Root -UserDataRoot $data).SkipShortcutExplanation -and $ui.StatusText.Text.StartsWith('アイコンを設定できたよ。') -and $ui.StatusText.Text.Contains((Join-Path $out 'collision_02.lnk')) -and (Get-FileHash (Join-Path $out 'collision.lnk')).Hash -eq $collisionHash) 'Skip/success path/collision'
  }
  Check '15 skipped explanation retains final and multiple confirmation; cancel unchanged' {
   Click $ui.CheckAllButton;Target $targets.ps1 'skip-cancel';Reset-Prompts 2;$before=Snapshot;Click $ui.ApplyButton
   Require ($script:Prompts.Count -eq 2 -and -not $script:Prompts[0].Remember -and $script:Prompts[0].Message.StartsWith('このアイコンでショートカットを作るよ。') -and $script:Prompts[1].Message.StartsWith('保存する画像が3枚') -and (Snapshot) -ceq $before) 'Skip bypassed confirmation'
  }
  Check '16 PS1 BAT CMD create separate links without executing or changing original' {
   Click $ui.UncheckAllButton
   foreach($ext in @('ps1','bat','cmd')){Target $targets[$ext] ('made-'+$ext);Reset-Prompts;Click $ui.ApplyButton;Wait-Work;$created=Join-Path $out ('made-'+$ext+'.lnk');Require ([IO.File]::Exists($created) -and $script:Prompts.Count -eq 1 -and $ui.StatusText.Text.Contains($created)) 'Missing new shortcut/final/path'}
  }
  Check '17 invalid target and missing saved ICO give accurate non-success state' {
   Target (Join-Path $run.Root 'missing.exe');Reset-Prompts;Click $ui.ApplyButton;Require (-not $state.Busy -and $script:Prompts.Count -eq 0 -and $ui.StatusText.Text.Contains('設定先が見つからない')) 'Invalid target'
   $saved=$state.Items[1].SavedPath;$state.Items[1].SavedPath=Join-Path $run.Root 'missing.ico';try{Target $targetFolder;Click $ui.ApplyButton;Require (-not $ui.ApplyButton.IsEnabled -and $ui.StatusText.Text.Contains('まだ保存されていないよ。')) 'Missing ICO'}finally{$state.Items[1].SavedPath=$saved;&$actions.Refresh}
  }
  Check '18 all inputs preserved; three ICOs contain full seven frames; history unchanged by apply' {
   foreach($p in $sourceHashes.Keys){Require ((Get-FileHash -LiteralPath $p).Hash -eq $sourceHashes[$p]) ('Input changed '+$p)}
   Require (@(Get-ChildItem $run.Root -Recurse -File -Filter *.ico).Count -eq 3) 'Unexpected ICO copy'
   foreach($i in $state.Items){$bytes=[IO.File]::ReadAllBytes($i.SavedPath);Require ([BitConverter]::ToUInt16($bytes,4) -eq 7 -and [Convert]::ToBase64String($bytes) -eq [Convert]::ToBase64String($i.Result.Ico)) 'ICO frames/content changed'}
   Require ($state.LastIcoSavedDirectory -eq [IO.Path]::GetDirectoryName($state.Items[2].SavedPath) -and (Read-AiconSettings $data).Data.LastIcoSavedDirectory -eq $state.LastIcoSavedDirectory) 'ICO history overwritten'
  }
  Check '19 Desktop explanation exact without writes; SameFolder path accurate' {
   $state.SkipShortcutExplanation=$false;Target $targets.exe 'desktop-cancel';$ui.DestinationBox.SelectedIndex=0;Reset-Prompts 1;$before=Snapshot;Click $ui.ApplyButton
   $nl=[Environment]::NewLine;$expected="元のファイルはそのままに、好きなアイコンをつけたショートカットを作るよ。${nl}${nl}保存先はデスクトップです。変えたいときだけ『保存先を変更』から選んでね。"
   Require ((Get-AiconApplyPrompt @{Destination='Desktop'} 'Explain').Message -eq $expected) 'Desktop explanation wording'
   $desktopSafe=$true;try{[void](Assert-AiconWritableTarget ([Environment]::GetFolderPath('DesktopDirectory')))}catch{$desktopSafe=$false}
   if($desktopSafe){Require ($script:Prompts.Count -eq 1 -and $script:Prompts[0].Message -eq $expected) 'Desktop explanation/cancel'}else{Require ($script:Prompts.Count -eq 0 -and $ui.StatusText.Text.Contains('保存先を安全に確認できません') -and $ui.StatusText.Text.Contains('保存先を変更')) 'Protected Desktop lacks actionable error'}
   Require ((Snapshot) -ceq $before) 'Desktop attempt wrote data'
   $ui.DestinationBox.SelectedIndex=1;Reset-Prompts 2;Click $ui.ApplyButton
   Require ($script:Prompts.Count -eq 2 -and $script:Prompts[0].Message.Contains('「'+$run.Root+'」') -and $script:Prompts[1].Message.Contains('保存先：'+$run.Root) -and (Snapshot) -ceq $before) 'SameFolder explanation/final/cancel'
  }
  Check '20 actual worker failure retains error and preserves locked target bytes' {
   $failedFolder=Join-Path $run.Root 'LockedFolder';[void][IO.Directory]::CreateDirectory($failedFolder);$ini=Join-Path $failedFolder 'desktop.ini';[IO.File]::WriteAllText($ini,'existing content');$hash=(Get-FileHash $ini).Hash
   Target $failedFolder;Reset-Prompts;$handle=[IO.File]::Open($ini,'Open','ReadWrite','None')
   try{Click $ui.ApplyButton;$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and $state.Failed -eq 1 -and $ui.StatusText.Text.Contains('処理を完了できませんでした') -and -not $ui.StatusText.Text.Contains('できたよ')) 'Failure overwritten by success/count'}finally{$handle.Dispose()}
   Require ((Get-FileHash $ini).Hash -eq $hash) 'Failed apply modified target'
  }
  $state.AllowClose=$true;$window.Close()
 }
 $script:Cases|ConvertTo-Json -Depth 6|Set-Content (Join-Path $run.Results 'apply.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:Cases|Where-Object Passed).Count+' PASS / '+@($script:Cases|Where-Object {-not $_.Passed}).Count+' FAIL; '+$run.Results)
 if(@($script:Cases|Where-Object {-not $_.Passed}).Count){exit 1}
} $app $run
