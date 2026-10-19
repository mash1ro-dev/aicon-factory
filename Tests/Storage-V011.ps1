param([string]$Root,[string]$Phase,[string]$CopyName)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1')
if(-not $Phase){
 $run=New-OwnedTestRun $app;$Root=$run.Root
 foreach($name in @('AppA','AppB','AppUpdated','Data','Custom','LegacyData','Folder','Folder2','Links')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $name))}
 foreach($name in @('AppA','AppB','AppUpdated')){Copy-Item -LiteralPath (Join-Path $app 'App') -Destination (Join-Path $Root $name) -Recurse}
 Add-Type -AssemblyName System.Drawing
 $im=[Drawing.Bitmap]::new(90,70);$g=[Drawing.Graphics]::FromImage($im)
 try{$g.Clear([Drawing.Color]::Goldenrod);$im.Save((Join-Path $Root 'source.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$im.Dispose()}
 [IO.File]::WriteAllText((Join-Path $Root 'dummy.exe'),'Owned fixture; never execute')
 # Synthetic legacy fixtures, never the user's actual settings or ICOs.
 $legacy=Join-Path $Root 'LegacyData';[IO.File]::WriteAllBytes((Join-Path $legacy 'legacy.ico'),[byte[]]@(0,0,1,0,0,0))
 $settings=@{LastIcoSavedDirectory=$legacy;IcoOutputDirectoryPreference='';KeepUnknown=@{Name='keep';Value=27}}|ConvertTo-Json -Depth 5
 [IO.File]::WriteAllText((Join-Path $Root 'AppA\settings.json'),$settings)
 [void][IO.Directory]::CreateDirectory((Join-Path $Root 'AppA\Backup'));[IO.File]::WriteAllText((Join-Path $Root 'AppA\Backup\keep.txt'),'old backup unchanged')
 foreach($name in @('AppB','AppUpdated')){[IO.File]::WriteAllText((Join-Path $Root ($name+'\settings.json')),'{"LastIcoSavedDirectory":"C:\\stale-update-path","IcoSaveMode":"Custom","IcoOutputDirectoryPreference":"C:\\stale-update-path"}')}
 $before=@(Get-ChildItem (Join-Path $Root 'AppA') -Recurse -File|Where-Object {$_.Name -eq 'settings.json' -or $_.Name -eq 'keep.txt'}|ForEach-Object {@{Relative=$_.FullName.Substring((Join-Path $Root 'AppA').Length+1);Hash=(Get-FileHash $_.FullName).Hash}})
 $shell=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe';$results=@()
 foreach($step in @('SaveStore','RestartSwitch','Moved','Updated','MissingAndMigration')){
  $copy=if($step -eq 'Moved'){'AppB'}elseif($step -in @('Updated','MissingAndMigration')){'AppUpdated'}else{'AppA'}
  if($step -eq 'Moved'){
   $owned=Assert-OwnedTestRoot $app $Root;$source=Assert-TestLocalPath (Join-Path $owned 'AppA');$dest=Assert-TestLocalPath (Join-Path $owned 'AppA-retired')
   if([IO.Directory]::GetParent($source).FullName -ine $owned -or [IO.Directory]::GetParent($dest).FullName -ine $owned){throw 'Move escaped owned root'}
   Rename-Item -LiteralPath $source -NewName 'AppA-retired'
  }
  $args='-NoProfile -STA -File "'+$PSCommandPath+'" -Root "'+$Root+'" -Phase '+$step+' -CopyName '+$copy
  $p=Start-Process $shell -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run.Results ($step+'.log')) -RedirectStandardError (Join-Path $run.Results ($step+'.stderr.log'));$null=$p.Handle
  if(-not $p.WaitForExit(90000)){$p.Kill();throw ('Owned child timeout: '+$step)}
  $file=Join-Path $Root ($step+'.json');$ok=$p.ExitCode -eq 0 -and (Test-Path $file)
  $results+=[pscustomobject]@{Phase=$step;Passed=$ok;PID=$p.Id;Exit=$p.ExitCode;Evidence=$file}
  Write-Host ($(if($ok){'PASS '}else{'FAIL '})+$step+' PID '+$p.Id)
  if(-not $ok){Get-Content (Join-Path $run.Results ($step+'.stderr.log')) -Encoding UTF8;break}
 }
 $preserved=@($before|ForEach-Object {$path=Join-Path $Root ('AppA-retired\'+$_.Relative);[pscustomobject]@{Path=$path;Unchanged=((Test-Path $path) -and (Get-FileHash $path).Hash -eq $_.Hash)}})
 $results|ConvertTo-Json -Depth 6|Set-Content (Join-Path $run.Results 'storage.json') -Encoding UTF8
 $preserved|ConvertTo-Json|Set-Content (Join-Path $run.Results 'legacy-preserved.json') -Encoding UTF8
 Save-TestInventory $run
 Write-Host ('RESULT '+@($results|Where-Object Passed).Count+' / 5; '+$run.Results)
 if($results.Count -ne 5 -or @($results|Where-Object {-not $_.Passed}).Count -or @($preserved|Where-Object {-not $_.Unchanged}).Count){exit 1};exit 0
}
$Root=Assert-OwnedTestRoot $app $Root;$copyRoot=Join-Path $Root $CopyName
if($CopyName -notin @('AppA','AppB','AppUpdated')){throw 'Invalid owned app copy'}
Import-Module (Join-Path $copyRoot 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($fixtureRoot,$copyRoot,$phase)
 $checks=[Collections.Generic.List[string]]::new()
 function Require([bool]$ok,[string]$why){if(-not $ok){throw $why}}
 function Reject($body){$caught=$false;try{&$body|Out-Null}catch{$caught=$true};Require $caught 'Expected rejection'}
 $applicationIconHash=(Get-FileHash -LiteralPath (Join-Path $copyRoot 'App\Assets\app.ico')).Hash
 function Count-Ico{
  $count=0
  foreach($file in Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.ico' -File -Recurse -Force){
   $relative=$file.FullName.Substring($fixtureRoot.Length+1)
   if($relative -match '^(AppA|AppB|AppUpdated|AppA-retired)\\App\\Assets\\app\.ico$'){
    Require ((Get-FileHash -LiteralPath $file.FullName).Hash -eq $applicationIconHash) 'Packaged app icon changed'
   }else{$count++}
  }
  return $count
 }
 $data=Join-Path $fixtureRoot 'Data';$custom=Join-Path $fixtureRoot 'Custom';$legacy=Join-Path $fixtureRoot 'LegacyData'
 . (Join-Path $copyRoot 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $copyRoot -UserDataRoot $data -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work {$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy) 'Worker timeout'}
  function Save-One($name,$expected){
   &$actions.Add @((Join-Path $fixtureRoot 'source.png'));$ui.IconNameBox.Text=$name;$before=Count-Ico
   Click $ui.GenerateButton;Wait-Work;Require ($state.Failed -eq 0 -and (Count-Ico) -eq $before) 'Preview wrote an ICO'
   Require ($ui.IcoOutputBox.Text -eq $expected -and $ui.SaveButton.IsEnabled) ("Displayed destination differs before save: actual=$($ui.IcoOutputBox.Text); expected=$expected; enabled=$($ui.SaveButton.IsEnabled); items=$($state.Items.Count); status=$($ui.StatusText.Text); reason=$($ui.SaveReason.Text)")
   Click $ui.SaveButton;Wait-Work;$item=$state.Items[0]
   Require ($state.Failed -eq 0 -and [IO.Path]::GetDirectoryName($item.SavedPath) -eq $expected) 'Actual output differs'
   Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($item.SavedPath)) -eq [Convert]::ToBase64String($item.Result.Ico)) 'Preview/save bytes differ'
   Require ((Count-Ico) -eq $before+1) 'Unexpected hidden ICO copy'
   Click $ui.SaveButton;Wait-Work;Require ((Count-Ico) -eq $before+1) 'Duplicate save'
  }
  function Capture($name){$ui.IcoOutputBox.BringIntoView();$window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render);Require ($ui.IcoOutputBox.LineCount -gt 1 -and $ui.IcoOutputBox.ExtentHeight -le $ui.IcoOutputBox.ViewportHeight+1) 'Long output path clipped';$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window);$bmp=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($window.ActualWidth*$dpi.DpiScaleX),[int]($window.ActualHeight*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32);$bmp.Render($window);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp));$f=[IO.File]::Create((Join-Path $fixtureRoot ($name+'.png')));try{$enc.Save($f)}finally{$f.Dispose()}}
  function Check-References($record){
   Require ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'Folder\desktop.ini')).Contains($record.SavedPath)) 'Folder reference changed'
   $shell=New-Object -ComObject WScript.Shell;$link=$null
   try{$link=$shell.CreateShortcut((Join-Path $fixtureRoot 'Links\dummy.lnk'));Require ($link.IconLocation -eq ($record.SavedPath+',0')) 'Shortcut reference changed'}finally{if($link){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
   Require ([IO.File]::Exists($record.SavedPath) -and (Get-FileHash $record.SavedPath).Hash -eq $record.Hash) 'Referenced ICO missing/changed'
  }
  $window.Show();$window.UpdateLayout();$script:Opened='';$state.OpenFolder={param($p) $script:Opened=$p};$state.DialogResponder={@{Accepted=$true;Remember=$false}}
  Require ($state.Root -eq $data -and $state.AppRoot -eq $copyRoot) 'Data and app roots are not separate'
  if($phase -eq 'SaveStore'){
   Require ((Get-AiconUserDataRoot) -eq (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AiconFactory')) 'Default root is not stable known-folder'
   Require ($state.IcoSaveMode -eq 'Library' -and $state.LastIcoSavedDirectory -eq $legacy -and [bool]$state.MigrationNotice) 'Legacy history/mode migration'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq $legacy -and $ui.IcoOutputBox.Text -eq (Join-Path $data 'Library\ICO\Image')) 'History became future destination'
   Require ((Read-AiconSettings $data).Data.KeepUnknown.Value -eq 27) 'Unknown legacy setting lost';$checks.Add('Settings-only migration preserves unknown settings and legacy history; future library separate')
   $ui.CategoryBox.SelectedIndex=5;Save-One 'stable' (Join-Path $data 'Library\ICO\Business');Capture 'storage-library'
   $checks.Add('Business category: displayed path equals sole output; preview bytes exact; no auto/duplicate save')
   $hash=(Get-FileHash $state.Items[0].SavedPath).Hash;$configHash=(Get-FileHash (Join-Path $data 'settings.json')).Hash
   $ui.TargetBox.Text=Join-Path $fixtureRoot 'Folder';Click $ui.ApplyButton;Wait-Work;Require ($state.Failed -eq 0) 'Folder apply failed'
   $ui.TargetBox.Text=Join-Path $fixtureRoot 'dummy.exe';$ui.DestinationBox.SelectedIndex=2;$ui.OutputDirectoryBox.Text=Join-Path $fixtureRoot 'Links';Click $ui.ApplyButton;Wait-Work;Require ($state.Failed -eq 0) 'Shortcut apply failed'
   $record=@{SavedPath=$state.Items[0].SavedPath;Hash=$hash};Check-References $record
   Require ((Get-FileHash (Join-Path $data 'settings.json')).Hash -eq $configHash -and (Count-Ico) -eq 2) '03 changed history/settings or copied ICO'
   $record|ConvertTo-Json|Set-Content (Join-Path $fixtureRoot 'reference.json') -Encoding UTF8;$checks.Add('Folder and LNK reference exact stable ICO; 03 leaves save settings and ICO count unchanged')
  }elseif($phase -eq 'RestartSwitch'){
   Require ($state.Items.Count -eq 0 -and $state.Category -eq 'Business' -and $state.IcoSaveMode -eq 'Library') 'Fresh-process restoration'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq (Join-Path $data 'Library\ICO\Business')) 'Restart open history';$checks.Add('Separate process restores library category and successful history')
   $ui.CustomSaveOption.IsChecked=$true;Require (-not $ui.SaveButton.IsEnabled -and $ui.IcoOutputBox.Text -eq '') 'Custom without destination falls back'
   Set-AiconOutputPreference $state $custom;&$actions.Refresh;Require ($ui.CustomSaveOption.IsChecked -and $ui.CustomSaveWarning.Visibility -eq 'Visible') 'Custom warning/mode missing'
   Save-One 'custom' $custom;Capture 'storage-custom';$checks.Add('Custom selection requires explicit directory; displayed destination/bytes/count match')
   $ui.LibrarySaveOption.IsChecked=$true;$ui.CategoryBox.SelectedIndex=1
   Require ($state.LastIcoSavedDirectory -eq $custom -and $state.IcoOutputDirectoryPreference -eq $custom -and $ui.IcoOutputBox.Text -eq (Join-Path $data 'Library\ICO\Audio')) 'Switch mixed future mode with history'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq $custom) 'Switch changed successful history';$checks.Add('Switch retains custom preference and history while future library follows category')
  }elseif($phase -in @('Moved','Updated')){
   Require (-not (Test-Path (Join-Path $fixtureRoot 'AppA'))) 'Old test app path still exists'
   Require ($state.IcoSaveMode -eq 'Library' -and $state.Category -eq 'Audio' -and $state.LastIcoSavedDirectory -eq $custom -and $ui.IcoOutputBox.Text -eq (Join-Path $data 'Library\ICO\Audio')) 'Moved/update app did not use stable settings'
   Require ((Read-AiconSettings $data).Data.KeepUnknown.Value -eq 27) 'Stale update settings replaced stable settings'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq $custom) 'Open after move/update changed history'
   $record=Get-Content (Join-Path $fixtureRoot 'reference.json') -Raw|ConvertFrom-Json;Check-References $record
   Require ((Count-Ico) -eq 3) 'Move/update duplicated ICO';$checks.Add('Old app path absent; copied/updated app restores stable settings and opens actual history')
   $checks.Add('Original folder and LNK still reference identical existing stable ICO after app removal')
   if($phase -eq 'Updated'){
    Save-One 'after-update' (Join-Path $data 'Library\ICO\Audio');$checks.Add('Updated copy saves to same stable library with no duplicate ICO')
    $ui.TargetBox.Text=Join-Path $fixtureRoot 'Folder2';Click $ui.ApplyButton;Wait-Work
    Require ([IO.File]::ReadAllText((Join-Path $fixtureRoot 'Folder2\desktop.ini')).Contains($state.Items[0].SavedPath)) 'Updated folder reference wrong'
    Require ($state.LastIcoSavedDirectory -eq (Join-Path $data 'Library\ICO\Audio')) 'Updated apply changed history'
   }
  }else{
   Require ($state.LastIcoSavedDirectory -eq (Join-Path $data 'Library\ICO\Audio') -and $state.IcoSaveMode -eq 'Library') 'Updated save history not restored in new process'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq $state.LastIcoSavedDirectory) 'Updated save history Open differs';$script:Opened='';$checks.Add('Fresh process restores and opens the post-update successful library save')
   $missing=Join-Path $fixtureRoot 'DoesNotExist';$state.LastIcoSavedDirectory=$missing;$state.IcoOutputDirectoryPreference=$missing;Set-AiconSaveMode $state 'Custom';&$actions.Refresh
   Click $ui.OpenLocationButton;Require ($script:Opened -eq '' -and $ui.StatusText.Text.Contains('開けません')) 'Missing history fell back'
   &$actions.Add @((Join-Path $fixtureRoot 'source.png'));Click $ui.GenerateButton;Wait-Work;$before=Count-Ico;Click $ui.SaveButton;Wait-Work
   Require ($state.Failed -eq 1 -and (Count-Ico) -eq $before -and -not (Test-Path $missing) -and $state.LastIcoSavedDirectory -eq $missing) 'Missing custom directory fell back or created';$checks.Add('Missing custom path fails without creation/fallback; failed save preserves history')
   $old=Join-Path $fixtureRoot 'CorruptApp';$new=Join-Path $fixtureRoot 'CorruptData';[void][IO.Directory]::CreateDirectory($old);[IO.File]::WriteAllText((Join-Path $old 'settings.json'),'{broken')
   $s=New-AiconSession -Root $old -UserDataRoot $new;Require ($s.SettingsBlocked -and [bool]$s.Warning) 'Corrupt migration not reported';Reject {Write-AiconSessionSettings $s @{LastIcoSavedDirectory=$custom}}
   Require (-not (Test-Path $new) -and [IO.File]::ReadAllText((Join-Path $old 'settings.json')) -eq '{broken') 'Corrupt legacy changed';$checks.Add('Corrupt legacy settings preserved; migration and writes safely refused')
   $old2=Join-Path $fixtureRoot 'LegacyCustomApp';$new2=Join-Path $fixtureRoot 'LegacyCustomData';[void][IO.Directory]::CreateDirectory($old2)
   @{IcoOutputDirectoryPreference=$custom;LastIcoSavedDirectory=$custom}|ConvertTo-Json|Set-Content (Join-Path $old2 'settings.json') -Encoding UTF8
   $s=New-AiconSession -Root $old2 -UserDataRoot $new2;Require ($s.IcoSaveMode -eq 'Custom' -and (Get-AiconOutputDirectory $s) -eq $custom -and $s.LastIcoSavedDirectory -eq $custom) 'Legacy explicit custom destination lost';$checks.Add('Existing explicit custom destination remains custom with unchanged reference')
  }
  [ordered]@{Phase=$phase;PID=$PID;AppRoot=$copyRoot;UserDataRoot=$state.Root;Mode=$state.IcoSaveMode;Category=$state.Category;Displayed=$ui.IcoOutputBox.Text;History=$state.LastIcoSavedDirectory;Opened=$script:Opened;IcoCount=(Count-Ico);Checks=$checks.ToArray();SettingsJson=[IO.File]::ReadAllText((Join-Path $data 'settings.json'))}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $fixtureRoot ($phase+'.json')) -Encoding UTF8
  $state.AllowClose=$true;$window.Close()
 }
} $Root $copyRoot $Phase
