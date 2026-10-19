function Show-AiconChoice {
 param($Owner,[string]$Message,[string]$Accept='設定する',[string]$Cancel='キャンセル',[switch]$Remember)
 $w=[Windows.Window]::new();$w.Title='あいこんふぁくとりー';$w.Owner=$Owner;$w.WindowStartupLocation='CenterOwner';$w.SizeToContent='Height';$w.Width=490;$w.ResizeMode='NoResize';$w.Background='#FAF6EE'
 $p=[Windows.Controls.StackPanel]::new();$p.Margin=20;$t=[Windows.Controls.TextBlock]::new();$t.Text=$Message;$t.TextWrapping='Wrap';$t.Margin='0,0,0,15';$p.Children.Add($t)|Out-Null
 $c=[Windows.Controls.CheckBox]::new();$c.Content='次からこの説明を表示しない';if($Remember){$p.Children.Add($c)|Out-Null}
 $b=[Windows.Controls.StackPanel]::new();$b.Orientation='Horizontal';$b.HorizontalAlignment='Right'
 $no=[Windows.Controls.Button]::new();$no.Content=$Cancel;$no.IsCancel=$true;$no.IsDefault=$true;$no.Padding=10;$no.Margin=5
 $yes=[Windows.Controls.Button]::new();$yes.Content=$Accept;$yes.Padding=10;$yes.Margin=5;$yes.Style=$Owner.FindResource('PrimaryButton')
 $no.Add_Click({$w.DialogResult=$false}.GetNewClosure());$yes.Add_Click({$w.DialogResult=$true}.GetNewClosure())
 $b.Children.Add($no)|Out-Null;$b.Children.Add($yes)|Out-Null;$p.Children.Add($b)|Out-Null;$w.Content=$p
 return @{Accepted=($w.ShowDialog() -eq $true);Remember=($c.IsChecked -eq $true)}
}
function Show-AiconTargetKindMenu {
 param($Owner)
 $w=[Windows.Window]::new();$w.Title='アイコンを設定する場所を選ぶ';$w.Owner=$Owner;$w.WindowStartupLocation='CenterOwner';$w.Width=480;$w.SizeToContent='Height';$w.ResizeMode='NoResize';$w.Background='#FAF6EE'
 $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=18;$ctx=@{Kind=''}
 foreach($choice in @(@('Folder','フォルダを選ぶ','フォルダの見た目を変えるよ。'),@('File','ファイル・ショートカットを選ぶ','ファイルからショートカットを作ったり、今あるショートカットの見た目を変えられるよ。'))){
  $button=[Windows.Controls.Button]::new();$button.Tag=$choice[0];$button.Margin='0,0,0,10';$button.Padding=12;$button.HorizontalContentAlignment='Stretch'
  $content=[Windows.Controls.StackPanel]::new();$title=[Windows.Controls.TextBlock]::new();$title.Text=$choice[1];$title.FontWeight='SemiBold';$content.Children.Add($title)|Out-Null
  $description=[Windows.Controls.TextBlock]::new();$description.Text=$choice[2];$description.TextWrapping='Wrap';$description.Margin='0,5,0,0';$content.Children.Add($description)|Out-Null;$button.Content=$content
  $button.Add_Click({param($s,$e) $ctx.Kind=[string]$s.Tag;$w.DialogResult=$true}.GetNewClosure());$panel.Children.Add($button)|Out-Null
 }
 $cancel=[Windows.Controls.Button]::new();$cancel.Content='やめる';$cancel.IsCancel=$true;$cancel.IsDefault=$true;$cancel.HorizontalAlignment='Right';$cancel.Padding='15,7';$cancel.Add_Click({$w.DialogResult=$false}.GetNewClosure());$panel.Children.Add($cancel)|Out-Null
 $w.Content=$panel;if($w.ShowDialog() -eq $true){return $ctx.Kind};return ''
}
function New-AiconNativeTargetDialog {
 param([ValidateSet('Folder','File')][string]$Kind,[string]$InitialDirectory)
 if($Kind -eq 'Folder'){
  $d=[Windows.Forms.FolderBrowserDialog]::new();$d.Description='フォルダを選ぶ';$d.RootFolder=[Environment+SpecialFolder]::Desktop;$d.SelectedPath=$InitialDirectory;$d.ShowNewFolderButton=$false;return $d
 }
 $d=[Microsoft.Win32.OpenFileDialog]::new();$d.Title='ファイル・ショートカットを選ぶ';$d.InitialDirectory=$InitialDirectory;$d.Multiselect=$false;$d.CheckFileExists=$true;$d.CheckPathExists=$true
 # Selecting a .lnk must return the .lnk itself, never its executable target.
 $d.DereferenceLinks=$false;$d.Filter='ファイル・ショートカット|*.lnk;*.exe;*.ps1;*.bat;*.cmd|すべてのファイル|*.*';return $d
}
function Show-AiconNativeTargetDialog {
 param($Owner,[ValidateSet('Folder','File')][string]$Kind,[string]$InitialDirectory)
 $d=New-AiconNativeTargetDialog $Kind $InitialDirectory
 if($Kind -eq 'File'){if($d.ShowDialog($Owner) -eq $true){return $d.FileName};return ''}
 if(-not ('Aicon.DialogOwner' -as [type])){Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition 'using System; using System.Windows.Forms; namespace Aicon { public sealed class DialogOwner : IWin32Window { public IntPtr Handle { get; private set; } public DialogOwner(IntPtr handle) { Handle=handle; } } }'}
 $ownerHandle=[Windows.Interop.WindowInteropHelper]::new($Owner).Handle
 try{if($d.ShowDialog([Aicon.DialogOwner]::new($ownerHandle)) -eq [Windows.Forms.DialogResult]::OK){return $d.SelectedPath}}finally{$d.Dispose()}
 return ''
}
