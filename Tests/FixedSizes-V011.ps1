param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $script:FixedCases=[Collections.Generic.List[object]]::new();$script:Frames=[Collections.Generic.List[object]]::new();$script:Switches=[Collections.Generic.List[object]]::new()
 function Require($ok,$why){if(-not $ok){throw $why}}
 function Check($name,$body){try{&$body;$script:FixedCases.Add(@{Name=$name;Passed=$true});Write-Host ('PASS '+$name)}catch{$script:FixedCases.Add(@{Name=$name;Passed=$false;Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 function Icos{return @(Get-ChildItem -LiteralPath $run.Root -Recurse -File -Filter *.ico)}
 function Pngs{return @(Get-ChildItem -LiteralPath $run.Root -Recurse -File -Filter *.png)}
 function Inspect-Ico($item){
  $bytes=[IO.File]::ReadAllBytes($item.SavedPath)
  Require ([BitConverter]::ToUInt16($bytes,0) -eq 0 -and [BitConverter]::ToUInt16($bytes,2) -eq 1 -and [BitConverter]::ToUInt16($bytes,4) -eq 7) 'ICO header'
  Require ([Convert]::ToBase64String($bytes) -eq [Convert]::ToBase64String($item.Result.Ico)) 'Saved bytes differ from preview result'
  $dims=@();$end=118
  for($n=0;$n -lt 7;$n++){
   $entry=6+16*$n;$w=if($bytes[$entry]){[int]$bytes[$entry]}else{256};$h=if($bytes[$entry+1]){[int]$bytes[$entry+1]}else{256}
   $len=[BitConverter]::ToUInt32($bytes,$entry+8);$offset=[BitConverter]::ToUInt32($bytes,$entry+12)
   Require ($w -eq $h -and $offset -eq $end -and $len -gt 0 -and $offset+$len -le $bytes.Length) 'Frame offsets/dimensions'
   $frame=[byte[]]::new($len);[Array]::Copy($bytes,$offset,$frame,0,$len);$stream=[IO.MemoryStream]::new($frame)
   try{$decoder=[Windows.Media.Imaging.BitmapDecoder]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$bitmap=$decoder.Frames[0];Require ($decoder.Frames.Count -eq 1 -and $bitmap.PixelWidth -eq $w -and $bitmap.PixelHeight -eq $h) 'Decoded frame does not match directory'}finally{$stream.Dispose()}
   Require ([Convert]::ToBase64String($frame) -eq [Convert]::ToBase64String($item.Result.Frames[$w])) 'Embedded PNG differs from generated frame'
   $script:Frames.Add([pscustomobject]@{File=$item.SavedPath;Index=$n;DirectoryWidth=$w;DirectoryHeight=$h;DecodedWidth=$bitmap.PixelWidth;DecodedHeight=$bitmap.PixelHeight;Bytes=$len;Offset=$offset;Planes=[BitConverter]::ToUInt16($bytes,$entry+4);BitCount=[BitConverter]::ToUInt16($bytes,$entry+6);SHA256=(Get-FileHash $item.SavedPath).Hash})
   $dims+=$w;$end=$offset+$len
  }
  Require (($dims -join ',') -eq '16,24,32,48,64,128,256' -and @($dims|Sort-Object -Unique).Count -eq 7 -and $end -eq $bytes.Length) 'Missing/duplicate frame or trailing bytes'
 }
 Add-Type -AssemblyName System.Drawing,PresentationFramework,PresentationCore,WindowsBase
 $data=Join-Path $run.Root 'Data';$legacyApp=Join-Path $run.Root 'LegacyApp';[void][IO.Directory]::CreateDirectory($legacyApp)
 $oldSettings=Join-Path $legacyApp 'settings.json';[IO.File]::WriteAllText($oldSettings,'{"Sizes":[24,64],"SelectedSizes":[16],"IconSizes":[32],"KeepUnknown":"preserve"}')
 $oldHash=(Get-FileHash $oldSettings).Hash;$paths=@();$sourceHashes=@{}
 for($n=1;$n -le 3;$n++){$p=Join-Path $run.Root ('image-'+$n+'.png');$im=[Drawing.Bitmap]::new((70+$n*10),60);$g=[Drawing.Graphics]::FromImage($im);try{$g.Clear([Drawing.Color]::FromArgb(255,60*$n,40,200));$im.Save($p,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$im.Dispose()};$paths+=$p;$sourceHashes[$p]=(Get-FileHash $p).Hash}
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $legacyApp -UserDataRoot $data -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work{$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and $state.Failed -eq 0) 'Worker failed or timed out'}
  function Capture($name){$window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render);$dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window);$bmp=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($window.ActualWidth*$dpi.DpiScaleX),[int]($window.ActualHeight*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32);$bmp.Render($window);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp));$f=[IO.File]::Create((Join-Path $run.Results ($name+'.png')));try{$enc.Save($f)}finally{$f.Dispose()}}
  $window.Show();$window.UpdateLayout();$state.DialogResponder={@{Accepted=$true;Remember=$false}}
  Check 'UI removes size controls and small previews; legacy settings are ignored and retained' {
   foreach($name in @('SizeSettings','SizePanel','Preview16','Preview32','Preview48','SizeLabel16','SizeLabel32','SizeLabel48','SizeLabel256')){Require (-not $ui.ContainsKey($name)) ('Retired UI remains: '+$name)}
   Require (-not $state.ContainsKey('Sizes') -and -not (Get-Command Set-AiconSizes -ErrorAction SilentlyContinue)) 'Retired size state/API remains'
   $xaml=[IO.File]::ReadAllText((Join-Path $app 'App\MainWindow.xaml'));Require ($xaml.Contains('画像がアイコンになります。') -and $xaml.Contains('02   仕上がりを確認') -and $xaml -notmatch '\d+ px|7サイズ|ICOに含めるサイズ') 'Copy/size explanation'
   Require ((Read-AiconSettings $data).Data.Sizes -join ',' -eq '24,64') 'Unknown old size property lost'
   Capture 'fixed-initial'
  }
  Check 'Three fixed previews ignore injected old size state; no ICO/PNG before save' {
   $state.Sizes=[int[]]@(24,64);&$actions.Add $paths;Click $ui.GenerateButton;Wait-Work
   Require ($state.Items.Count -eq 3 -and @(Icos).Count -eq 0 -and @(Pngs).Count -eq 3) 'Preview created persistent output'
   foreach($i in $state.Items){Require (($i.Result.Frames.Keys|Sort-Object) -join ',' -eq '16,24,32,48,64,128,256') 'Subset generated'}
   Require ($ui.Preview256.Source.PixelWidth -eq 256 -and $ui.Preview256.Source.PixelHeight -eq 256) 'Preview bitmap dimensions'
  }
  Check 'Number and list selection match current ID and 256 bitmap pixels six times' {
   foreach($route in @('Number','List')){for($n=0;$n -lt 3;$n++){
    if($route -eq 'Number'){Click $ui.NumberPanel.Children[$n]}else{$ui.InputList.SelectedItem=$state.Items[$n]}
    $item=$state.Items[$n];Require ($state.CurrentId -eq $item.Id) 'Current ID mismatch';$expected=&$actions.Bitmap $item.Result.Frames[256];$actual=$ui.Preview256.Source
    $stride=[int](($expected.PixelWidth*$expected.Format.BitsPerPixel+7)/8);$a=[byte[]]::new($stride*256);$e=[byte[]]::new($a.Length);$actual.CopyPixels($a,$stride,0);$expected.CopyPixels($e,$stride,0)
    Require ($actual.PixelWidth -eq 256 -and $actual.PixelHeight -eq 256 -and [Convert]::ToBase64String($a) -eq [Convert]::ToBase64String($e)) 'Displayed pixels mismatch'
    $script:Switches.Add(@{Route=$route;Number=$n+1;CurrentId=$state.CurrentId;ExpectedId=$item.Id;Width=$actual.PixelWidth;Height=$actual.PixelHeight;PixelsMatch=$true})
   }}
   $state.Items[0].SaveChecked=$true;$state.Items[2].SaveChecked=$true;&$actions.Refresh;Capture 'fixed-preview'
  }
  Check 'Only two selected files saved; 14 embedded frames decoded with exact seven dimensions' {
   Click $ui.SaveButton;Wait-Work;Require (@(Icos).Count -eq 2 -and @(Pngs).Count -eq 3 -and -not $state.Items[1].SavedPath) 'Unselected or extra output'
   Inspect-Ico $state.Items[0];Inspect-Ico $state.Items[2];Click $ui.SaveButton;Wait-Work;Require (@(Icos).Count -eq 2) 'Repeated save duplicated ICO'
  }
  Check '03 applies currently displayed saved item three with no new ICO' {
   Click $ui.NumberPanel.Children[2];$folder=Join-Path $run.Root 'Target';[void][IO.Directory]::CreateDirectory($folder);$ui.TargetBox.Text=$folder;Click $ui.ApplyButton;Wait-Work
   $ini=[IO.File]::ReadAllText((Join-Path $folder 'desktop.ini'));Require ($ini.Contains($state.Items[2].SavedPath) -and -not $ini.Contains($state.Items[0].SavedPath) -and @(Icos).Count -eq 2) 'Wrong current ICO or hidden copy'
   Click $ui.NumberPanel.Children[1];Require (-not $ui.ApplyButton.IsEnabled) 'Unsaved current item can apply';Capture 'fixed-saved'
  }
  Check 'Clear and reuse with empty legacy state still saves seven frames; inputs/settings preserved' {
   Click $ui.ClearButton;Require ($state.Items.Count -eq 0 -and @(Icos).Count -eq 2) 'Clear removed output';$state.Sizes=[int[]]@();&$actions.Add @($paths[1]);Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work;Inspect-Ico $state.Items[0]
   Require (@(Icos).Count -eq 3 -and @(Pngs).Count -eq 3 -and (Get-FileHash $oldSettings).Hash -eq $oldHash) 'Unexpected file changes';foreach($p in $paths){Require ((Get-FileHash $p).Hash -eq $sourceHashes[$p]) 'Input changed'}
   Require ((Read-AiconSettings $data).Data.Sizes -join ',' -eq '24,64') 'Old unknown setting rewritten'
  }
  $state.AllowClose=$true;$window.Close()
 }
 $script:FixedCases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'fixed-sizes.json') -Encoding UTF8
 $script:Frames|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'ico-frames.json') -Encoding UTF8
 $script:Switches|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'preview-switches.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:FixedCases|Where-Object Passed).Count+' PASS / '+@($script:FixedCases|Where-Object {-not $_.Passed}).Count+' FAIL; '+$run.Results)
 if(@($script:FixedCases|Where-Object {-not $_.Passed}).Count){exit 1}
} $app $run
