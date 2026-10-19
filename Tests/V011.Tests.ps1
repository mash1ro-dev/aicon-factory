param([string]$Root)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1')
if(-not $Root){$run=New-OwnedTestRun $app;$Root=$run.Root}else{$Root=Assert-OwnedTestRoot $app $Root}
$resultPath=Join-Path $Root 'acceptance.json'
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$root,$resultPath)
 $script:Cases=[Collections.Generic.List[object]]::new()
 $script:Measurements=[Collections.Generic.List[object]]::new()
 $script:PreviewComparisons=0
 function Check([string]$Name,[scriptblock]$Body){try{&$Body;$script:Cases.Add([pscustomobject]@{Name=$Name;Status='PASS';Detail=''});Write-Host ('PASS '+$Name)}catch{$script:Cases.Add([pscustomobject]@{Name=$Name;Status='FAIL';Detail=$_.ToString()});Write-Host ('FAIL '+$Name+': '+$_)}}
 function Require([bool]$Condition,[string]$Why){if(-not $Condition){throw $Why}}
 function Reject([scriptblock]$Body){$caught=$false;try{&$Body|Out-Null}catch{$caught=$true};Require $caught 'Expected rejection'}
 Add-Type -AssemblyName System.Drawing
 $sourceDir=Join-Path $root 'Sources';[void][IO.Directory]::CreateDirectory($sourceDir)
 $paths=@();$hashes=@{}
 for($n=1;$n -le 10;$n++){$path=Join-Path $sourceDir ('image-'+$n+'.png');$b=[Drawing.Bitmap]::new((80+$n),60);$g=[Drawing.Graphics]::FromImage($b);try{$g.Clear([Drawing.Color]::Transparent);$g.FillRectangle([Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(255,20*$n,60,200)),10,10,40+$n,30);$b.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()};$paths+=$path;$hashes[$path]=(Get-FileHash $path).Hash}
 $a=Join-Path $root 'A';$bdir=Join-Path $root 'B';$cdir=Join-Path $root 'C';$shortcutDir=Join-Path $root 'ShortcutOutput';foreach($d in @($a,$bdir,$cdir,$shortcutDir)){[void][IO.Directory]::CreateDirectory($d)}
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $root -UserDataRoot $root -Harness {
   function Measure-Checkpoint([string]$Name){
     $icos=@(Get-ChildItem -LiteralPath $root -Filter '*.ico' -Recurse -File)
     $cfg=Join-Path $root 'settings.json';$persisted=if(Test-Path $cfg){Get-Content $cfg -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
     $saved=@($state.Items|Where-Object SavedPath)
     $script:Measurements.Add([pscustomobject]@{Stage=$Name;PID=$PID;Items=$state.Items.Count;UniqueIDs=@($state.Items.Id|Sort-Object -Unique).Count;RemovalCount=$state.RemovalIds.Count;CheckedCount=@($state.Items|Where-Object SaveChecked).Count;CurrentId=$state.CurrentId;PermanentIcoCount=$icos.Count;PermanentIcos=@($icos|ForEach-Object FullName);NewPreviewPngCount=@(Get-ChildItem $root -Filter '*.png' -File -Recurse|Where-Object {$_.FullName -notin $paths}).Count;LibraryExists=(Test-Path (Join-Path $root 'Library'));SavedItems=$saved.Count;SavedByteMatches=@($saved|Where-Object {[Convert]::ToBase64String([IO.File]::ReadAllBytes($_.SavedPath)) -eq [Convert]::ToBase64String($_.Result.Ico)}).Count;PendingSave=@(Get-AiconSaveCandidates $state).Count;Succeeded=$state.Succeeded;Failed=$state.Failed;LastIcoSavedDirectory=$state.LastIcoSavedDirectory;PersistedSettings=$persisted;Rows=@($state.Items|Select-Object Id,Number,FileName,SaveChecked,SavedPath,Status)})
   }
   function Click($Button){$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
   function Wait-Work {$deadline=[DateTime]::UtcNow.AddSeconds(80);while($state.Busy -and [DateTime]::UtcNow -lt $deadline){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy) 'Worker timeout'}
   $window.Show();$window.UpdateLayout();$state.DialogResponder={param($message,$accept,$cancel,$remember) @{Accepted=$true;Remember=$false}}
   Check '7 initial categories, fixed preview, disabled buttons, desktop default' {Require (($ui.CategoryBox.Items|ForEach-Object Content) -join ',' -eq 'Image,Audio,Development,Tools,Apps,Business,AI,Other') 'Categories';Require (-not $state.ContainsKey('Sizes') -and -not $ui.ContainsKey('SizePanel')) 'Retired size state';Require (-not $ui.SaveButton.IsEnabled -and -not $ui.ApplyButton.IsEnabled -and -not $ui.GenerateButton.IsEnabled) 'Initial buttons';Require ($ui.DestinationBox.SelectedItem.Tag -eq 'Desktop') 'Default shortcut destination'}
   &$actions.Add $paths
   Check '1/4 ten IDs unique and batch checks OFF' {Require ($state.Items.Count -eq 10 -and @($state.Items.Id|Sort-Object -Unique).Count -eq 10 -and @($state.Items|Where-Object SaveChecked).Count -eq 0) 'IDs/checks';Require ($ui.SingleNamePanel.Visibility -eq 'Collapsed') 'Batch name hidden'}
   Check '3 preview creates zero permanent ICO or preview PNG' {Click $ui.GenerateButton;Wait-Work;Require ($state.Succeeded -eq 10) $ui.StatusText.Text;Require (@(Get-ChildItem $root -Filter '*.ico' -Recurse).Count -eq 0) 'ICO before save';Require (-not(Test-Path (Join-Path $root 'Library'))) 'Persistent library before save';Require ($state.Items[0].Result.Frames.Count -eq 7) 'Result frames'}
   Measure-Checkpoint 'PreviewOnly'
   Check '2 all ten number buttons display matching result and filename' {
     foreach($route in @('Number','Name')){for($n=0;$n -lt 10;$n++){
       if($route -eq 'Number'){Click $ui.NumberPanel.Children[$n]}else{$ui.InputList.SelectedItem=$state.Items[$n]}
       Require ($state.CurrentId -eq $state.Items[$n].Id -and $ui.CurrentLabel.Text.Contains($state.Items[$n].FileName)) 'Number/name linkage'
       $expected=&$actions.Bitmap $state.Items[$n].Result.Frames[256];$actual=$ui.Preview256.Source
       $stride=[int](($expected.PixelWidth*$expected.Format.BitsPerPixel+7)/8);$aPixels=[byte[]]::new($stride*$expected.PixelHeight);$ePixels=[byte[]]::new($aPixels.Length)
       $actual.CopyPixels($aPixels,$stride,0);$expected.CopyPixels($ePixels,$stride,0)
       Require ([Convert]::ToBase64String($aPixels) -eq [Convert]::ToBase64String($ePixels)) 'Displayed pixels differ from this item generated frame'
       $script:PreviewComparisons++
     }}
     $script:Measurements.Add([pscustomobject]@{Stage='PreviewPixelIdentity';Routes=@('Number','Name');Compared=$script:PreviewComparisons;Expected=20;Matched=$script:PreviewComparisons})
   }
   Check '1/2 removal selection independent from checks and number selection' {
     $ui.InputList.SelectedItems.Clear();$ui.InputList.SelectedItems.Add($state.Items[1])|Out-Null;$ui.InputList.SelectedItems.Add($state.Items[4])|Out-Null;$ui.InputList.SelectedItems.Add($state.Items[7])|Out-Null
     $currentId=$state.Items[5].Id;Click $ui.NumberPanel.Children[5];Require ($state.RemovalIds.Count -eq 3) 'Numbers changed removal selection'
     $state.Items[0].SaveChecked=$true;Click $ui.RemoveButton
     Require ($state.Items.Count -eq 7 -and $state.CurrentId -eq $currentId -and ((@($state.Items.Number) -join ',') -eq '1,2,3,4,5,6,7')) 'Removal changed active ID';Require $state.Items[0].SaveChecked 'Removal changed check'
   }
   # Restore a fresh ten-item session without touching originals or saved outputs.
   Measure-Checkpoint 'RemovedThree'
   Click $ui.ClearButton;&$actions.Add $paths;Click $ui.GenerateButton;Wait-Work
   Check '3/8 checked three only, same preview bytes, no duplicate resave' {
     Set-AiconOutputPreference $state $a;foreach($n in @(0,1,4)){$state.Items[$n].SaveChecked=$true};&$actions.Refresh;Click $ui.SaveButton;Wait-Work
     Require (@(Get-ChildItem $a -Filter '*.ico').Count -eq 3) 'Expected exactly three'
     foreach($n in @(0,1,4)){Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($state.Items[$n].SavedPath)) -eq [Convert]::ToBase64String($state.Items[$n].Result.Ico)) 'Preview/save bytes differ'}
     Require (-not $ui.SaveButton.IsEnabled) 'Resave enabled';Click $ui.SaveButton;Wait-Work;Require (@(Get-ChildItem $a -Filter '*.ico').Count -eq 3) 'Duplicate save'
   }
   Check '5 close return preserves current ID, checks, previews, destination' {
     Measure-Checkpoint 'SavedThreeAndNoResave'
     $beforeId=$state.CurrentId;$beforeResult=$state.Items[0].Result;$beforeChecks=@($state.Items.SaveChecked) -join ',';$beforeDest=$ui.IcoOutputBox.Text
     $state.DialogResponder={@{Accepted=$false;Remember=$false}};$window.Close();Require ($window.IsVisible -and -not $state.Closed -and $state.CurrentId -eq $beforeId -and [object]::ReferenceEquals($state.Items[0].Result,$beforeResult) -and (@($state.Items.SaveChecked) -join ',') -eq $beforeChecks -and $ui.IcoOutputBox.Text -eq $beforeDest) 'State lost on return'
   }
   Check '9 folder confirmation cancel no mutation, confirm applies current #2 only' {
     Click $ui.NumberPanel.Children[1];$ui.TargetBox.Text=$bdir;Require ($ui.ShortcutPanel.Visibility -eq 'Collapsed' -and $ui.ApplyButton.IsEnabled) 'Folder controls'
     Click $ui.ApplyButton;Require (-not(Test-Path (Join-Path $bdir 'desktop.ini'))) 'Cancel mutated folder'
     $state.DialogResponder={@{Accepted=$true;Remember=$false}};Click $ui.ApplyButton;Wait-Work
     $ini=[IO.File]::ReadAllText((Join-Path $bdir 'desktop.ini'));Require ($ini.Contains($state.Items[1].SavedPath)) 'Wrong applied ID';Require ($state.LastIcoSavedDirectory -eq $a) 'Apply changed history'
   }
   Check '10 EXE creates only custom test shortcut and preserves original' {
     Measure-Checkpoint 'AfterFolderApply'
     $target=Join-Path $root 'dummy.exe';[IO.File]::WriteAllText($target,'DO NOT EXECUTE');$hash=(Get-FileHash $target).Hash
     $ui.TargetBox.Text=$target;$ui.DestinationBox.SelectedIndex=2;$ui.OutputDirectoryBox.Text=$shortcutDir;Require ($ui.ShortcutPanel.Visibility -eq 'Visible') 'EXE options missing';Click $ui.ApplyButton;Wait-Work
     Require (@(Get-ChildItem $shortcutDir -Filter '*.lnk').Count -eq 1 -and (Get-FileHash $target).Hash -eq $hash -and $state.LastIcoSavedDirectory -eq $a) 'EXE safety/history'
     $ui.ShortcutNameBox.Text='alternate';Require $ui.ApplyButton.IsEnabled 'Edited shortcut name did not enable apply';$ui.ShortcutNameBox.Text='dummy'
   }
   Check '10 existing LNK changes without creating another; fields hidden' {
     Measure-Checkpoint 'AfterNewShortcut'
     $link=(Get-ChildItem $shortcutDir -Filter '*.lnk')[0].FullName;$ui.TargetBox.Text=$link;Require ($ui.ShortcutPanel.Visibility -eq 'Collapsed') 'Existing shortcut fields visible';Click $ui.ApplyButton;Wait-Work
     Require (@(Get-ChildItem $shortcutDir -Filter '*.lnk').Count -eq 1 -and $state.LastIcoSavedDirectory -eq $a) 'Existing link duplicated/history'
   }
   Check '8 open location resolves ICO history, never application output' {
     Measure-Checkpoint 'AfterExistingShortcut'
     $script:Opened='';$state.OpenFolder={param($p) $script:Opened=$p};Click $ui.OpenLocationButton;Require ($script:Opened -eq $a) 'Wrong open location'
   }
   Check '4 cancel save retains completed item and leaves others pending' {
     Click $ui.CheckAllButton;Click $ui.SaveButton;Click $ui.CancelButton;Wait-Work
     Require (@($state.Items|Where-Object SavedPath).Count -eq 4 -and @(Get-AiconSaveCandidates $state).Count -eq 6) 'Cancel did not stop between items'
   }
   Check '4 partial save failure retains good item and allows retry' {
     Measure-Checkpoint 'AfterCancelSave'
     foreach($i in $state.Items){$i.SaveChecked=$false};$pending=@($state.Items|Where-Object {-not $_.SavedPath});$pending[0].Name='CON';$pending[0].SaveChecked=$true;$pending[1].SaveChecked=$true
     Click $ui.SaveButton;Wait-Work;Require ($state.Failed -eq 1 -and $state.Succeeded -eq 1 -and $pending[0].Status -eq '保存失敗' -and -not $pending[0].SavedPath -and $pending[1].SavedPath) 'Partial results';$pending[0].Name='retry';Click $ui.SaveButton;Wait-Work;Require ([bool]$pending[0].SavedPath) 'Retry failed'
   }
   Check '6 clear and reuse preserves saved ICOs' {$before=@(Get-ChildItem $a -Filter '*.ico').Count;Click $ui.ClearButton;Require ($state.Items.Count -eq 0 -and @(Get-ChildItem $a -Filter '*.ico').Count -eq $before) 'Clear deletes saved';&$actions.Add @($paths[0]);$ui.IconNameBox.Text='edited';Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work;Require ($state.Items[0].SavedPath.EndsWith('edited.ico')) 'Single rename/reuse'}
   Check '7 editing a saved single name immediately enables save and preserves old file' {$old=$state.Items[0].SavedPath;$ui.IconNameBox.Text='renamed';Require ($ui.SaveButton.IsEnabled -and -not $state.Items[0].SavedPath -and [IO.File]::Exists($old)) 'Edited name state'}
   # Replaces retired selectable-size behavior; old state must not control output.
   Check '7 fixed seven sizes and single 256 preview ignore legacy size state' {
     $state.Sizes=[int[]]@(24,64);$state.Items[0].Result=$null;&$actions.Refresh;Click $ui.GenerateButton;Wait-Work
     Require (($state.Items[0].Result.Frames.Keys|Sort-Object) -join ',' -eq '16,24,32,48,64,128,256') 'Fixed sizes'
     Require ([BitConverter]::ToUInt16($state.Items[0].Result.Ico,4) -eq 7 -and $ui.Preview256.Source.PixelWidth -eq 256 -and $ui.Preview256.Source.PixelHeight -eq 256 -and -not $ui.ContainsKey('Preview48') -and -not $ui.ContainsKey('SizePanel')) 'Fixed preview/UI'
   }
   Check '8c C save updates successful history' {Set-AiconOutputPreference $state $cdir;&$actions.Refresh;Click $ui.SaveButton;Wait-Work;Require ($state.LastIcoSavedDirectory -eq $cdir -and @(Get-ChildItem $cdir -Filter '*.ico').Count -eq 1) 'C history'}
   Check '5 saved-only close requires no confirmation' {$state.DialogResponder={throw 'Unexpected confirmation'};$window.Close();Require $state.Closed 'Saved window did not close'}
 }
 Check '4 all ten original hashes unchanged' {foreach($p in $paths){Require ((Get-FileHash $p).Hash -eq $hashes[$p]) 'Original changed'}}
 Check '4 atomic collision preserves old bytes and no temporary leftovers' {$old=Join-Path $cdir 'same.ico';[IO.File]::WriteAllText($old,'sentinel');$r=[Aicon.ImageEngine]::Process($paths[0]);$path=Save-AiconPreviewBytes $r.Ico $cdir 'same';Require ($path.EndsWith('same_02.ico') -and [IO.File]::ReadAllText($old) -eq 'sentinel' -and @(Get-ChildItem $cdir -Filter '*.tmp' -Force).Count -eq 0) 'Collision/cleanup'}
 Check '8c corrupt settings preserved and writes refused' {$dir=Join-Path $root 'Corrupt';[void][IO.Directory]::CreateDirectory($dir);$p=Join-Path $dir 'settings.json';[IO.File]::WriteAllText($p,'{broken');$hash=(Get-FileHash $p).Hash;$s=New-AiconSession -Root $dir -UserDataRoot $dir;Require ([bool]$s.Warning -and -not $s.LastIcoSavedDirectory) 'Corrupt settings hidden';Reject {Write-AiconSettings $dir @{LastIcoSavedDirectory=$a}};Require ((Get-FileHash $p).Hash -eq $hash) 'Corrupt settings overwritten'}
 Check '8c unknown settings preserved and failed replacement keeps JSON intact' {$dir=Join-Path $root 'Settings';[void][IO.Directory]::CreateDirectory($dir);$p=Join-Path $dir 'settings.json';[IO.File]::WriteAllText($p,'{"Other":{"Keep":17}}');Write-AiconSettings $dir @{LastIcoSavedDirectory=$a};Require ((Read-AiconSettings $dir).Data.Other.Keep -eq 17) 'Other settings lost';$hash=(Get-FileHash $p).Hash;$lock=[IO.File]::Open($p,'Open','Read','Read');try{Reject {Write-AiconSettings $dir @{LastIcoSavedDirectory=$cdir}}}finally{$lock.Dispose()};Require ((Get-FileHash $p).Hash -eq $hash -and @(Get-ChildItem $dir -Filter '*.tmp' -Force).Count -eq 0) 'Settings partial write'}
 Check '8c missing history or invalid path never falls back' {$s=New-AiconSession -Root (Join-Path $root 'Fresh') -UserDataRoot (Join-Path $root 'Fresh');Reject {Get-AiconSavedDirectory $s};$s.LastIcoSavedDirectory=Join-Path $root 'Missing';Reject {Get-AiconSavedDirectory $s};$s.IcoSaveMode='Custom';$s.IcoOutputDirectoryPreference='..\bad';Reject {Get-AiconOutputDirectory $s};$s.LastIcoSavedDirectory='\\server\share';Reject {Get-AiconSavedDirectory $s}}
 $script:Cases|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $resultPath -Encoding UTF8
 $script:Measurements|ConvertTo-Json -Depth 8|Set-Content (Join-Path $root 'measurements.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:Cases|Where-Object Status -eq PASS).Count+' PASS / '+@($script:Cases|Where-Object Status -eq FAIL).Count+' FAIL; '+$resultPath)
 if(@($script:Cases|Where-Object Status -eq FAIL).Count){exit 1}
} $app $Root $resultPath
