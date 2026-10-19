#Requires -Version 5.1
function Show-AiconFactoryWindow {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$Root,[string]$UserDataRoot,[scriptblock]$Harness)
 if($Harness -and -not $UserDataRoot){throw 'テストには明示的なUserDataRootが必要です。'}
 if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 の STA で起動してください。'}
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
 Initialize-AiconEngine;. (Join-Path $PSScriptRoot 'Dialogs.ps1')
 $state=New-AiconSession -Root $Root -UserDataRoot $UserDataRoot;$rootPath=$state.Root
 foreach($k in @('PowerShell','Runspace','Async','WorkItem','DialogResponder','OpenFolder','ApplyArguments','TargetKindPicker','NativeTargetPicker')){$state[$k]=$null}
 $state.Confirming=$false;$state.Picking=$false;$state.ApplySuccessText='';$state.LastErrorText=''
 $state.Updating=$false;$state.Queue=[Collections.Generic.Queue[object]]::new();$state.Succeeded=0;$state.Failed=0
 $api=@{};foreach($n in @('Get-AiconCurrent','Set-AiconCurrent','Add-AiconInputs','Remove-AiconInputs','Test-AiconUnsaved','Set-AiconItemName','Get-AiconSaveCandidates','Get-AiconOutputDirectory','Set-AiconOutputPreference','Set-AiconSaveMode','Get-AiconSavedDirectory','Get-AiconTargetKind','Write-AiconSessionSettings','Show-AiconChoice','Show-AiconTargetKindMenu','Show-AiconNativeTargetDialog','Get-AiconTargetInitialDirectory','Remember-AiconTargetDirectory','New-AiconApplySnapshot','Test-AiconApplySnapshot','Test-AiconAlreadyApplied','Get-AiconApplyPrompt','Get-AiconApplySuccessText','Write-AiconDiagnosticLog')){$api[$n]=(Get-Command $n).ScriptBlock}
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$reader=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'MainWindow.xaml'),$settings)
 try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
 $area=[Windows.SystemParameters]::WorkArea;$window.Height=[Math]::Min($window.Height,$area.Height-20);$window.Width=[Math]::Min($window.Width,$area.Width-20);$window.MinHeight=[Math]::Min(650,$area.Height-20);$window.MinWidth=[Math]::Min(830,$area.Width-20)
 $ui=@{};$xml=[xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MainWindow.xaml'))
 foreach($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){$n=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($n){$v=$window.FindName($n);if($v){$ui[$n]=$v}}}
 $modulePath=Join-Path $PSScriptRoot 'AiconFactory.psm1';$actions=@{}
 $actions.Status={param([string]$text,[bool]$error=$false) $ui.StatusText.Text=$text;$ui.StatusText.ToolTip=$text;$ui.StatusText.Foreground=if($error){[Windows.Media.Brushes]::IndianRed}else{[Windows.Media.Brushes]::DarkSlateGray}}.GetNewClosure()
 $actions.Error={param($stage,$record) $logged=&$api['Write-AiconDiagnosticLog'] -Root $rootPath -Stage $stage -ErrorRecord $record
 $msg=if($stage -eq 'OpenLocation'){'前回の保存先を開けません。移動先やアクセス権を確認してください。'}else{'処理を完了できませんでした。画像・保存先・アクセス権を確認してください。'}
 if(-not $logged){$msg+=' 詳しい記録も保存できませんでした。'};$state.LastErrorText=$msg;&$actions.Status $msg $true}.GetNewClosure()
 $actions.Bitmap={param([byte[]]$bytes) $stream=[IO.MemoryStream]::new($bytes);try{$b=[Windows.Media.Imaging.BitmapImage]::new();$b.BeginInit();$b.CacheOption='OnLoad';$b.StreamSource=$stream;$b.EndInit();$b.Freeze();return $b}finally{$stream.Dispose()}}.GetNewClosure()
 $actions.Confirm={param($message,$accept='設定する',$cancel='キャンセル',$remember=$false) if($state.DialogResponder){return (&$state.DialogResponder $message $accept $cancel $remember)};return (&$api['Show-AiconChoice'] -Owner $window -Message $message -Accept $accept -Cancel $cancel -Remember:$remember)}.GetNewClosure()
 $actions.Signature={$i=&$api['Get-AiconCurrent'] $state;return (@($(if($i){$i.SavedPath}else{''}),$ui.TargetBox.Text.Trim(),$ui.DestinationBox.SelectedItem.Tag,$ui.OutputDirectoryBox.Text.Trim(),$ui.ShortcutNameBox.Text.Trim()) -join [Environment]::NewLine)}.GetNewClosure()
 $actions.IsApplied={return (&$api['Test-AiconAlreadyApplied'] $state $ui.TargetBox.Text.Trim() ([string]$ui.DestinationBox.SelectedItem.Tag) $ui.OutputDirectoryBox.Text.Trim() $ui.ShortcutNameBox.Text.Trim())}.GetNewClosure()
 $actions.SelectNumber={param($s,$e) &$api['Set-AiconCurrent'] $state ([string]$s.Tag);&$actions.Refresh}.GetNewClosure()
 $actions.Refresh={
 $state.Updating=$true
 try{
 $cur=&$api['Get-AiconCurrent'] $state;$idle=-not ($state.Busy -or $state.Confirming -or $state.Picking)
 foreach($k in @('ChooseImageButton','InputList','CategoryBox','CheckAllButton','UncheckAllButton','ChooseIcoOutputButton','LibrarySaveOption','CustomSaveOption','ChooseTargetButton','TargetBox','ShortcutSettings','IconNameBox')){$ui[$k].IsEnabled=$idle}
 $ui.DropZone.AllowDrop=$idle;$ui.TargetBox.AllowDrop=$idle;$ui.RemoveButton.IsEnabled=$idle -and $state.RemovalIds.Count -gt 0;$ui.ClearButton.IsEnabled=$idle -and $state.Items.Count -gt 0
 $ui.GenerateButton.IsEnabled=$idle -and @($state.Items|Where-Object {-not $_.Result}).Count -gt 0
 $ui.GenerateReason.Text=if($state.Busy){'処理中です。'}elseif($state.Items.Count){'完成プレビューを作ります。ICOはまだ保存しません。'}else{'画像を追加してください。ここでは保存しません。'}
 $ui.SingleNamePanel.Visibility=if($state.Items.Count -eq 1){'Visible'}else{'Collapsed'};if($state.Items.Count -eq 1){$ui.IconNameBox.Text=$state.Items[0].Name}
 $ui.ModeText.Text=if($state.Items.Count -gt 1){"$($state.Items.Count)枚・一括モード：保存名には元ファイル名を使います。"}elseif($state.Items.Count){'1枚・単体モード：アイコン名を編集できます。'}else{'PNG・JPEG・静止WebPをここへドロップ'}
 if($null -eq $ui.InputList.ItemsSource){$ui.InputList.ItemsSource=$state.Items}
 foreach($row in $state.Items){$row.IsCurrent=($row.Id -eq $state.CurrentId)}
 $ui.NumberPanel.Children.Clear();foreach($i in $state.Items){$b=[Windows.Controls.Button]::new();$b.Content=[string]$i.Number;$b.Tag=$i.Id;$b.MinWidth=32;$b.Padding='7,3';$b.Margin='0,0,4,0';$b.IsEnabled=$idle;$b.ToolTip=$i.FileName;if($i.Id -eq $state.CurrentId){$b.Background='#F7DF8F'};$b.Add_Click($actions.SelectNumber);$ui.NumberPanel.Children.Add($b)|Out-Null}
 $ui.NumberScroller.UpdateLayout()
 if($cur){$x=0.0;for($n=0;$n -lt $cur.Number-1;$n++){$x+=$ui.NumberPanel.Children[$n].ActualWidth+4};$right=$x+$ui.NumberPanel.Children[$cur.Number-1].ActualWidth+4;if($x -lt $ui.NumberScroller.HorizontalOffset){$ui.NumberScroller.ScrollToHorizontalOffset($x)}elseif($right -gt $ui.NumberScroller.HorizontalOffset+$ui.NumberScroller.ViewportWidth){$ui.NumberScroller.ScrollToHorizontalOffset($right-$ui.NumberScroller.ViewportWidth)}}
 $ui.CurrentLabel.Text=if($cur){"$($cur.Number) / $($state.Items.Count)　$($cur.FileName)"}else{'画像を選んでください'};$ui.CurrentLabel.ToolTip=$ui.CurrentLabel.Text
 $hasPreview=$cur -and $cur.Result -and $cur.Result.Frames.ContainsKey(256)
 $ui.Preview256.Source=if($hasPreview){&$actions.Bitmap $cur.Result.Frames[256]}else{$null}
 $ui.PreviewPlaceholder.Visibility=if($hasPreview){'Collapsed'}else{'Visible'}
 # One fixed 256-pixel preview; GUI generation always uses the engine's full ICO.
 $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window)
 $ui.Preview256.Width=256/$dpi.DpiScaleX;$ui.Preview256.Height=256/$dpi.DpiScaleY
 $ui.PreviewStatus.Text=if($cur){$cur.Status+'　'+$cur.Error}else{'完成プレビューは保存するICOと同じ内容です。'}
 $candidates=@(&$api['Get-AiconSaveCandidates'] $state);$checked=@($state.Items|Where-Object SaveChecked).Count
 $ui.CheckCount.Text="$checked 件チェック / $($candidates.Count) 件保存可能";$ui.SaveButton.IsEnabled=$idle -and $candidates.Count -gt 0
 $ui.SaveReason.Text=if($state.Busy){'処理中です。'}elseif($candidates.Count){"チェックした未保存の $($candidates.Count) 件だけ保存します。"}else{'保存可能な未保存アイコンにチェックしてください。保存済みは再保存しません。'}
 $ui.LibrarySaveOption.IsChecked=$state.IcoSaveMode -eq 'Library';$ui.CustomSaveOption.IsChecked=$state.IcoSaveMode -eq 'Custom'
 $ui.ChooseIcoOutputButton.Visibility=if($state.IcoSaveMode -eq 'Custom'){'Visible'}else{'Collapsed'}
 $ui.CustomSaveWarning.Visibility=if($state.IcoSaveMode -eq 'Custom'){'Visible'}else{'Collapsed'}
 $ui.StorageNotice.Text=$state.MigrationNotice;$ui.StorageNotice.Visibility=if($state.MigrationNotice){'Visible'}else{'Collapsed'}
 foreach($category in $ui.CategoryBox.Items){if($category.Content -eq $state.Category){$ui.CategoryBox.SelectedItem=$category;break}}
 try{$ui.IcoOutputBox.Text=&$api['Get-AiconOutputDirectory'] $state}catch{$ui.IcoOutputBox.Text=$state.IcoOutputDirectoryPreference;$ui.SaveButton.IsEnabled=$false;$ui.SaveReason.Text='保存方法と保存先を確認し、フォルダを選んでください。'}
 $ui.IcoOutputBox.ToolTip=$ui.IcoOutputBox.Text;$kind=&$api['Get-AiconTargetKind'] $ui.TargetBox.Text.Trim()
 $ui.ShortcutPanel.Visibility=if($kind -eq 'NewShortcut'){'Visible'}else{'Collapsed'};$ui.CustomShortcutPanel.Visibility=if($ui.DestinationBox.SelectedItem.Tag -eq 'Custom'){'Visible'}else{'Collapsed'}
 $ui.TargetKindText.Text=switch($kind){'Folder'{'フォルダのアイコンを変更します。中のファイルは変更しません。'} 'Shortcut'{'既存ショートカットのアイコンだけを変更します。'} 'NewShortcut'{'新しいショートカットを作ります。元ファイルは変更しません。'} default{'フォルダ・既存ショートカット・EXE等を選択／ドロップしてください。'}}
 $saved=$cur -and $cur.SavedPath -and [IO.File]::Exists($cur.SavedPath)
 $ui.ApplyIconLabel.Text=if($cur){$name=if($saved){[IO.Path]::GetFileName($cur.SavedPath)}else{$cur.Name+'.ico'};"いま設定するアイコン：$($cur.Number)番 $name"}else{'いま設定するアイコン：02で画像を選んでね。'}
 $ui.ApplyIconLabel.ToolTip=$ui.ApplyIconLabel.Text;$ui.ApplyPreview.Source=$ui.Preview256.Source
 $already=&$actions.IsApplied;$ui.ApplyButton.IsEnabled=$idle -and $saved -and $kind -ne 'Invalid' -and -not $already
 $ui.ApplyMoreButton.Visibility=if($state.ShowApplyMore){'Visible'}else{'Collapsed'};$ui.ApplyMoreButton.IsEnabled=$idle
 $ui.ApplyReason.Text=if($state.Busy){'処理中です。'}elseif(-not $saved){"このアイコンはまだ保存されていないよ。`n先に02で保存してから、ここで設定してね。"}elseif($kind -eq 'Invalid'){'設定先を選んでください。'}elseif($already){'この場所には、このアイコンを設定済みです。ほかの場所や別のアイコンを選べるよ。'}else{'表示中の1枚と設定先を確認してから、設定します。'}
 $ui.OpenLocationButton.IsEnabled=$idle -and -not [string]::IsNullOrWhiteSpace($state.LastIcoSavedDirectory);$ui.OpenLocationButton.ToolTip=if($state.LastIcoSavedDirectory){$state.LastIcoSavedDirectory}else{'まだ保存履歴がありません。'}
 $ui.BusyIndicator.Visibility=if($state.Busy){'Visible'}else{'Collapsed'};$ui.CancelButton.Visibility=if($state.Busy -and $state.Kind -ne 'Apply'){'Visible'}else{'Collapsed'};$ui.CancelButton.IsEnabled=-not $state.CancelRequested
 }finally{$state.Updating=$false}
 }.GetNewClosure()
 $actions.Add={param([string[]]$paths) &$api['Add-AiconInputs'] $state $paths;foreach($i in $state.Items){if(-not $i.Thumbnail){try{$thumb=[Aicon.ImageEngine]::Process($i.Source,[int[]]@(48));$i.Thumbnail=&$actions.Bitmap $thumb.Preview}catch{$i.Status='失敗';$i.Error='この画像は読み込めませんでした。'}}};&$actions.Refresh;if($state.Warning){&$actions.Status $state.Warning $true}}.GetNewClosure()
 $actions.Remove={param([string[]]$ids) if($state.Busy){return};if(@($state.Items|Where-Object {$_.Id -in $ids -and -not $_.SavedPath}).Count){$a=&$actions.Confirm 'まだ保存していない画像を一覧から外しますか？ 元画像と保存済みICOは削除しません。' '一覧から外す' '作業に戻る';if(-not $a.Accepted){return}};$state.Updating=$true;try{&$api['Remove-AiconInputs'] $state $ids}finally{$state.Updating=$false};&$actions.Refresh}.GetNewClosure()
 $actions.Next={
 if($state.CancelRequested -or -not $state.Queue.Count){$state.Busy=$false
 if($state.Kind -eq 'Apply'){if($state.Failed){&$actions.Status $state.LastErrorText $true}else{&$actions.Status ($state.ApplySuccessText+$(if($state.Warning){[Environment]::NewLine+$state.Warning}else{''}))}}
 else{&$actions.Status ("$($state.Kind)：$($state.Succeeded)件成功 / $($state.Failed)件失敗"+$(if($state.CancelRequested){'・中止しました。完了済みの結果は保持しています。'}else{''}));if($state.Warning){&$actions.Status $state.Warning $true}}
 &$actions.Refresh;if($state.CloseAfter){$state.AllowClose=$true;$window.Close()};return}
 $state.WorkItem=$state.Queue.Dequeue();$ps=[PowerShell]::Create();$rs=[RunspaceFactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open();$ps.Runspace=$rs
 [void]$ps.AddScript({param($module,$kind,$item,$session,$arguments) $ErrorActionPreference='Stop';Import-Module $module -Force;$m=Get-Module AiconFactory
 if($kind -eq 'Generate'){&$m {param($source) Initialize-AiconEngine;[Aicon.ImageEngine]::Process($source)} $item.Source}
 elseif($kind -eq 'Save'){&$m {param($s,$i) Save-AiconSessionItem $s $i} $session $item}else{Set-AiconFactoryIcon @arguments}
 }).AddArgument($modulePath).AddArgument($state.Kind).AddArgument($state.WorkItem).AddArgument($state).AddArgument($state.ApplyArguments)
 $state.PowerShell=$ps;$state.Runspace=$rs;$state.Async=$ps.BeginInvoke()
 }.GetNewClosure()
 $actions.Start={param($kind,[object[]]$items,$arguments=$null) if($state.Busy -or $state.Confirming -or $state.Picking -or -not $items.Count){return};$state.Kind=$kind;$state.Busy=$true;$state.CancelRequested=$false;$state.Succeeded=0;$state.Failed=0;$state.ApplyArguments=$arguments;$state.Warning='';$state.LastErrorText='';$state.Queue.Clear();foreach($i in $items){$state.Queue.Enqueue($i)};&$actions.Refresh;&$actions.Status "$kind：処理中です。";&$actions.Next}.GetNewClosure()
 $actions.Poll={
 if(-not $state.Busy -or -not $state.Async -or -not $state.Async.IsCompleted){return}
 try{$r=$state.PowerShell.EndInvoke($state.Async);if($state.PowerShell.Streams.Error.Count){throw $state.PowerShell.Streams.Error[0]}
 if($state.Kind -eq 'Generate'){$i=$state.WorkItem;$i.Result=$r[0];$i.Status='未保存';$i.Error='';$i.Thumbnail=&$actions.Bitmap $i.Result.Preview}
 elseif($state.Kind -eq 'Apply'){
 $state.AppliedSignature=$state.PendingSignature;$state.LastBackupId=$r[0].BackupId;$state.AppliedTargetDirectory=[IO.Path]::GetDirectoryName($r[0].TargetPath)
 $state.ApplySuccessText=(&$api['Get-AiconApplySuccessText'] $state.ApplySnapshot.Kind)+[Environment]::NewLine+$r[0].TargetPath;$state.ShowApplyMore=$true
 $state.Warning=@($r[0].Warnings) -join [Environment]::NewLine
 $state.CompletedApplications[$state.ApplySnapshot.OperationKey]=@{Icon=$state.ApplySnapshot.Icon;IconHash=$state.ApplySnapshot.IconHash;TargetPath=$r[0].TargetPath;TargetHash=$r[0].TargetHash}
 if($state.RememberAfterApply){try{&$api['Write-AiconSessionSettings'] $state @{SkipShortcutExplanation=$true};$state.SkipShortcutExplanation=$true}catch{$state.Warning=(@($state.Warning,'説明の表示設定を記憶できませんでした。')|Where-Object {$_}) -join [Environment]::NewLine}}
 };$state.Succeeded++
 }catch{$state.Failed++;if($state.Kind -eq 'Generate'){$state.WorkItem.Result=$null;$state.WorkItem.Status='失敗';$state.WorkItem.Error='画像形式・破損・サイズを確認してください。'};&$actions.Error $state.Kind $_}
 finally{$state.PowerShell.Dispose();$state.Runspace.Dispose();$state.PowerShell=$null;$state.Runspace=$null;$state.Async=$null};&$actions.Refresh;&$actions.Next
 }.GetNewClosure()
 $ui.InputList.Add_SelectionChanged({param($s,$e) if($state.Updating){return};$state.RemovalIds.Clear();foreach($row in $s.SelectedItems){[void]$state.RemovalIds.Add($row.Id)};if($e.AddedItems.Count){&$api['Set-AiconCurrent'] $state $e.AddedItems[$e.AddedItems.Count-1].Id};&$actions.Refresh}.GetNewClosure())
 $ui.InputList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent,[Windows.RoutedEventHandler]{param($s,$e) if($state.Busy){return};$c=$e.OriginalSource
 if($c -is [Windows.Controls.CheckBox]){$i=$state.Items|Where-Object Id -eq $c.Tag|Select-Object -First 1;if($i){$i.SaveChecked=($c.IsChecked -eq $true)};$e.Handled=$true;&$actions.Refresh}
 elseif($c -is [Windows.Controls.Button] -and $c.Content -eq '×'){$e.Handled=$true;&$actions.Remove @([string]$c.Tag)}}.GetNewClosure())
 $ui.ChooseImageButton.Add_Click({$d=[Microsoft.Win32.OpenFileDialog]::new();$d.Filter='画像|*.png;*.jpg;*.jpeg;*.webp';$d.Multiselect=$true;if($d.ShowDialog($window)){&$actions.Add $d.FileNames}}.GetNewClosure())
 $ui.RemoveButton.Add_Click({&$actions.Remove @($state.RemovalIds)}.GetNewClosure());$ui.ClearButton.Add_Click({&$actions.Remove @($state.Items|ForEach-Object Id)}.GetNewClosure())
 $ui.DropZone.Add_PreviewDragOver({param($s,$e) $e.Effects=if(-not $state.Busy -and $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){'Copy'}else{'None'};$e.Handled=$true}.GetNewClosure())
 $ui.DropZone.Add_Drop({param($s,$e) if(-not $state.Busy -and $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){&$actions.Add ([string[]]$e.Data.GetData([Windows.DataFormats]::FileDrop))};$e.Handled=$true}.GetNewClosure())
 $ui.IconNameBox.Add_TextChanged({if(-not $state.Updating){&$api['Set-AiconItemName'] $state $ui.IconNameBox.Text;&$actions.Refresh}}.GetNewClosure());$ui.IconNameBox.Add_LostFocus({&$actions.Refresh}.GetNewClosure())
 $ui.CategoryBox.Add_SelectionChanged({if(-not $state.Updating -and -not $state.Busy){$state.Category=[string]$ui.CategoryBox.SelectedItem.Content;try{&$api['Write-AiconSessionSettings'] $state @{IcoCategory=$state.Category}}catch{&$actions.Status 'カテゴリの設定を記憶できませんでした。' $true};&$actions.Refresh}}.GetNewClosure())
 $ui.GenerateButton.Add_Click({&$actions.Start 'Generate' @($state.Items|Where-Object {-not $_.Result})}.GetNewClosure());$ui.SaveButton.Add_Click({&$actions.Start 'Save' @(&$api['Get-AiconSaveCandidates'] $state)}.GetNewClosure())
 $ui.CheckAllButton.Add_Click({foreach($i in $state.Items){$i.SaveChecked=$true};&$actions.Refresh}.GetNewClosure());$ui.UncheckAllButton.Add_Click({foreach($i in $state.Items){$i.SaveChecked=$false};&$actions.Refresh}.GetNewClosure())
 $folder={param($initial) $d=[Windows.Forms.FolderBrowserDialog]::new();$d.Description='保存先フォルダを選んでください';if([IO.Directory]::Exists($initial)){$d.SelectedPath=$initial};try{if($d.ShowDialog() -eq 'OK'){return $d.SelectedPath}}finally{$d.Dispose()};return ''}.GetNewClosure()
 $ui.ChooseIcoOutputButton.Add_Click({$path=&$folder $ui.IcoOutputBox.Text;if($path){try{&$api['Set-AiconOutputPreference'] $state $path;&$actions.Refresh;if($state.Warning){&$actions.Status $state.Warning $true}}catch{&$actions.Error 'Save' $_}}}.GetNewClosure())
 foreach($option in @($ui.LibrarySaveOption,$ui.CustomSaveOption)){$option.Add_Checked({param($s,$e) if(-not $state.Updating -and -not $state.Busy){&$api['Set-AiconSaveMode'] $state ([string]$s.Tag);&$actions.Refresh;if($state.Warning){&$actions.Status $state.Warning $true}}}.GetNewClosure())}
 $actions.SetTarget={param([string]$path)
 if((&$api['Get-AiconTargetKind'] $path) -eq 'Invalid'){&$actions.Status '設定先が見つからないか、対応していない種類です。フォルダ・ショートカット・EXE・PS1・BAT・CMDを選んでね。' $true;return}
 $ui.TargetBox.Text=$path;&$api['Remember-AiconTargetDirectory'] $state $path;&$actions.Refresh;if($state.Warning){&$actions.Status $state.Warning $true}
 }.GetNewClosure()
 $actions.ChooseTarget={
 if($state.Busy -or $state.Confirming -or $state.Picking){return};$state.Picking=$true;&$actions.Refresh
 try{
 $kind=if($state.TargetKindPicker){&$state.TargetKindPicker}else{&$api['Show-AiconTargetKindMenu'] $window}
 if($kind -notin @('Folder','File')){return}
 $initial=&$api['Get-AiconTargetInitialDirectory'] $state
 $path=if($state.NativeTargetPicker){&$state.NativeTargetPicker $kind $initial}else{&$api['Show-AiconNativeTargetDialog'] $window $kind $initial}
 if($path){&$actions.SetTarget $path}
 }catch{&$actions.Status '設定先の選択画面を開けませんでした。設定先の存在とアクセス権を確認してね。' $true}
 finally{$state.Picking=$false;&$actions.Refresh}
 }.GetNewClosure()
 $ui.ChooseTargetButton.Add_Click($actions.ChooseTarget)
 $ui.TargetBox.Add_TextChanged({if(-not $state.Updating){try{$ui.ShortcutNameBox.Text=[IO.Path]::GetFileNameWithoutExtension($ui.TargetBox.Text.Trim())}catch{};&$actions.Refresh}}.GetNewClosure())
 $actions.DropTargets={param([string[]]$paths) if($state.Busy -or $state.Confirming -or $state.Picking){return};if($paths.Count -eq 1){&$actions.SetTarget $paths[0]}else{&$actions.Status '設定先は1つだけ選んでください。' $true}}.GetNewClosure()
 $ui.TargetBox.Add_PreviewDragOver({param($s,$e) $e.Effects=if(-not ($state.Busy -or $state.Confirming -or $state.Picking) -and $e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){'Copy'}else{'None'};$e.Handled=$true}.GetNewClosure())
 $ui.TargetBox.Add_Drop({param($s,$e) if($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){&$actions.DropTargets ([string[]]$e.Data.GetData([Windows.DataFormats]::FileDrop))};$e.Handled=$true}.GetNewClosure())
 $ui.DestinationBox.Add_SelectionChanged({if(-not $state.Updating){&$actions.Refresh}}.GetNewClosure());$ui.ChooseOutputButton.Add_Click({$path=&$folder $ui.OutputDirectoryBox.Text;if($path){$ui.OutputDirectoryBox.Text=$path}}.GetNewClosure())
 $ui.OutputDirectoryBox.Add_TextChanged({if(-not $state.Updating){$state.ShortcutOutputDirectory=$ui.OutputDirectoryBox.Text;&$actions.Refresh}}.GetNewClosure());$ui.ShortcutNameBox.Add_TextChanged({if(-not $state.Updating){&$actions.Refresh}}.GetNewClosure())
 $actions.Apply={
 if($state.Busy -or $state.Confirming -or $state.Picking){return}
 try{$snapshot=&$api['New-AiconApplySnapshot'] $state $ui.TargetBox.Text.Trim() ([string]$ui.DestinationBox.SelectedItem.Tag) $ui.OutputDirectoryBox.Text.Trim() $ui.ShortcutNameBox.Text.Trim() (&$actions.Signature)}
 catch{&$actions.Status $_.Exception.Message $true;&$actions.Refresh;return}
 if(&$actions.IsApplied){return}
 $state.Confirming=$true;&$actions.Refresh;$remember=$false;$ready=$false
 try{
 $stages=@();if($snapshot.Kind -eq 'NewShortcut' -and -not $state.SkipShortcutExplanation){$stages+='Explain'};$stages+='Final';if($snapshot.CheckedCount -gt 1){$stages+='Multiple'}
 foreach($stage in $stages){
 $prompt=&$api['Get-AiconApplyPrompt'] $snapshot $stage;$answer=&$actions.Confirm $prompt.Message $prompt.Accept $prompt.Cancel $prompt.Remember
 if(-not $answer.Accepted){return}
 if(-not (&$api['Test-AiconApplySnapshot'] $state $snapshot (&$actions.Signature))){&$actions.Status '表示中のアイコンや設定先が変わったため、設定を止めました。内容を確認して、もう一度設定してね。' $true;return}
 if($stage -eq 'Explain'){$remember=$answer.Remember -eq $true}
 };$ready=$true
 }finally{$state.Confirming=$false;&$actions.Refresh}
 if($ready -and (&$api['Test-AiconApplySnapshot'] $state $snapshot (&$actions.Signature))){$state.ApplySnapshot=$snapshot;$state.RememberAfterApply=$remember;$state.PendingSignature=$snapshot.Signature;&$actions.Start 'Apply' @(&$api['Get-AiconCurrent'] $state) $snapshot.Arguments}
 }.GetNewClosure()
 $ui.ApplyButton.Add_Click($actions.Apply)
 $actions.ApplyMore={
 if($state.Busy -or $state.Confirming -or $state.Picking){return}
 $state.Updating=$true;try{$ui.TargetBox.Text='';$state.ShowApplyMore=$false}finally{$state.Updating=$false}
 &$actions.Refresh;&$actions.Status '次にアイコンを設定する場所を選んでね。'
 }.GetNewClosure()
 $ui.ApplyMoreButton.Add_Click($actions.ApplyMore)
 $ui.OpenLocationButton.Add_Click({try{$path=&$api['Get-AiconSavedDirectory'] $state;if($state.OpenFolder){&$state.OpenFolder $path}else{$p=[Diagnostics.ProcessStartInfo]::new();$p.FileName=$path;$p.UseShellExecute=$true;[void][Diagnostics.Process]::Start($p)}}catch{&$actions.Error 'OpenLocation' $_}}.GetNewClosure())
 $ui.CancelButton.Add_Click({$state.CancelRequested=$true;&$actions.Refresh}.GetNewClosure())
 $window.Add_Closing({param($s,$e) if($state.AllowClose){return};if($state.Confirming -or $state.Picking){$e.Cancel=$true;return};if(&$api['Test-AiconUnsaved'] $state){$a=&$actions.Confirm 'まだ保存していないアイコンがあります。保存せずに終了すると、今回の作業内容は消えます。終了しますか？' '保存せず終了' '作業に戻る';if(-not $a.Accepted){$e.Cancel=$true;return}};if($state.Busy){$e.Cancel=$true;$state.CloseAfter=$true;$state.CancelRequested=$true;&$actions.Status '現在の1件を安全に終えてから終了します。';return};$state.AllowClose=$true}.GetNewClosure())
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(80);$timer.Add_Tick({&$actions.Poll}.GetNewClosure())
 $window.Add_Closed({$state.Closed=$true;$timer.Stop();foreach($i in $state.Items){$i.Result=$null;$i.Thumbnail=$null}}.GetNewClosure())
 &$actions.Refresh;if($state.Warning){&$actions.Status $state.Warning $true};$timer.Start()
 try{if($Harness){&$Harness}else{[void]$window.ShowDialog()}}finally{$timer.Stop();if($state.PowerShell -and -not $state.Busy){$state.PowerShell.Dispose();$state.Runspace.Dispose()}}
}
