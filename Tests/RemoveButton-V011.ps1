param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition 'using System.Windows.Controls; public class RemoveProbeButton : Button { public void ProbePressed(bool value) { IsPressed=value; } }' -ReferencedAssemblies PresentationFramework,PresentationCore,WindowsBase,System.Xaml
function Require($ok,$why){if(-not $ok){throw $why}}
$records=[Collections.Generic.List[object]]::new()
$after=[xml][IO.File]::ReadAllText((Join-Path $app 'App\MainWindow.xaml'))
# Assert the current release contract rather than a historical, external XAML.
Require ($after.DocumentElement.Title -eq 'あいこんふぁくとりー v0.1.1' -and -not $after.OuterXml.Contains('v0.1.1 候補')) 'Release version labels differ'
$style=$after.SelectSingleNode('//*[local-name()="Style" and @*[local-name()="Key"]="RemoveImageButton"]')
Require ($null -ne $style -and $style.TargetType -eq 'Button') 'Remove style missing'
Require ($after.DocumentElement.GetAttribute('Icon') -eq 'Assets/app.ico') 'Official relative window icon missing'
$buttons=$after.SelectNodes('//*[local-name()="Button" and @Content="×"]')
Require ($buttons.Count -eq 1 -and $buttons[0].Tag -ceq '{Binding Id}' -and $buttons[0].Style -ceq '{StaticResource RemoveImageButton}' -and $buttons[0].ToolTip -ceq 'この画像を一覧から外す') 'Remove button binding/style/tooltip changed'
$cross=$style.SelectSingleNode('.//*[local-name()="Path" and @*[local-name()="Name"]="RemoveCross"]')
Require ($cross.Data -ceq 'M 1,1 L 9,9 M 9,1 L 1,9' -and $cross.IsHitTestVisible -eq 'False') 'Remove cross geometry/hit handling changed'
foreach($property in @('IsMouseOver','IsPressed','IsKeyboardFocused','IsEnabled')){
 $triggers=$style.SelectNodes('.//*[local-name()="Trigger" and @Property="'+$property+'"]');$expected=if($property -eq 'IsEnabled'){'False'}else{'True'}
 Require ($triggers.Count -eq 1 -and $triggers[0].Value -eq $expected) ('Remove trigger missing: '+$property)
}
$guide=$after.SelectSingleNode('//*[local-name()="Expander" and @Header="アイコンを設定したあとについて"]')
Require ($null -ne $guide) 'Expected approved display guide'
foreach($text in @('フォルダのアイコンは、変更してもすぐに見た目が切り替わらないことがあります。','そんなときは、少し待ってみてね。','それでも変わらない場合は、デスクトップの何もないところをクリックして、F5キーで表示を更新してみてください。')){Require ($guide.OuterXml.Contains($text)) 'Approved display guide text changed'}
$records.Add(@{Name='Current v0.1.1 remove-button binding, glyph, triggers, release labels and guidance';Status='PASS';Method='Explicit current XAML contract; no historical baseline'})
# WPF IsMouseOver is read-only. Change only its condition in a test copy.
foreach($n in $style.SelectNodes('.//*[@Property="IsMouseOver"]')){$n.SetAttribute('Property','Tag')}
$resources=$after.SelectSingleNode('//*[local-name()="Window.Resources"]').InnerXml
$dict=[Windows.Markup.XamlReader]::Parse('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'+$resources+'</ResourceDictionary>')
function Render($visual,$scale,$name){
 $drawing=[Windows.Media.DrawingVisual]::new();$dc=$drawing.RenderOpen();$dc.DrawRectangle([Windows.Media.Brushes]::Transparent,$null,[Windows.Rect]::new(0,0,47,56));$dc.DrawRectangle([Windows.Media.VisualBrush]::new($visual),$null,[Windows.Rect]::new(10,10,27,36));$dc.Close()
 $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling(47*$scale),[int][Math]::Ceiling(56*$scale),96*$scale,96*$scale,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($drawing)
 $enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$file=[IO.File]::Create((Join-Path $run.Results ($name+'.png')));try{$enc.Save($file)}finally{$file.Dispose()};return $bitmap
}
foreach($scale in @(1.0,1.25,1.5)){
 foreach($stateName in @('normal','hover','pressed')){
  $b=[RemoveProbeButton]::new();$b.Content='×';$b.Style=$dict['RemoveImageButton'];$b.Resources=$dict;$b.Width=27;$b.Height=36
  if($stateName -eq 'hover'){$b.Tag='True'};if($stateName -eq 'pressed'){$b.ProbePressed($true)}
  $b.Measure([Windows.Size]::new(27,36));$b.Arrange([Windows.Rect]::new(0,0,27,36));$b.UpdateLayout()
  $face=$b.Template.FindName('RemoveFace',$b);$chrome=$b.Template.FindName('RemoveChrome',$b);$cross=$b.Template.FindName('RemoveCross',$b);$hit=$b.Template.FindName('RemoveHitArea',$b)
  $faceBounds=$face.TransformToAncestor($b).TransformBounds([Windows.Rect]::new(0,0,$face.ActualWidth,$face.ActualHeight))
  $crossBounds=$cross.TransformToAncestor($b).TransformBounds([Windows.Rect]::new(0,0,$cross.ActualWidth,$cross.ActualHeight))
  $centerDx=[Math]::Abs(($faceBounds.X+$faceBounds.Width/2)-($crossBounds.X+$crossBounds.Width/2))*$scale
  $centerDy=[Math]::Abs(($faceBounds.Y+$faceBounds.Height/2)-($crossBounds.Y+$crossBounds.Height/2))*$scale
  Require ($chrome -is [Windows.Shapes.Ellipse] -and $face.ActualWidth -eq 24 -and $face.ActualHeight -eq 24 -and [Math]::Abs($faceBounds.Width-$faceBounds.Height) -lt 0.001) 'Visible face not circular'
  Require ($centerDx -lt 0.01 -and $centerDy -lt 0.01) 'Cross not centered'
  Require ($hit.ActualWidth -eq 27 -and $hit.ActualHeight -eq 36 -and $null -ne $hit.Background) 'Original click area lost'
  if($stateName -eq 'hover'){Require ($chrome.Fill -is [Windows.Media.SolidColorBrush] -and $chrome.Fill.Color.ToString() -eq '#FFE6F4FB') 'Remove hover color changed'}
  if($stateName -eq 'pressed'){Require ($chrome.Fill -is [Windows.Media.SolidColorBrush] -and $chrome.Fill.Color.ToString() -eq '#FFCEE1EB' -and [Math]::Abs($face.RenderTransform.Value.M11-0.96) -lt 0.0001 -and [Math]::Abs($face.RenderTransform.Value.M22-0.96) -lt 0.0001) 'Remove pressed color/scale changed'}
  $name='remove-'+[int]($scale*100)+'-'+$stateName;$bitmap=Render $b $scale $name
  # Measure the actual rendered ellipse mask at each export DPI, without shadow/gloss/glyph.
  $maskVisual=[Windows.Media.DrawingVisual]::new();$dc=$maskVisual.RenderOpen();$dc.DrawRectangle([Windows.Media.VisualBrush]::new($chrome),$null,[Windows.Rect]::new(0,0,$faceBounds.Width,$faceBounds.Height));$dc.Close()
  $fill=$chrome.Fill;$effect=$chrome.Effect;$stroke=$chrome.Stroke;$thickness=$chrome.StrokeThickness
  $chrome.Fill=[Windows.Media.Brushes]::White;$chrome.Stroke=[Windows.Media.Brushes]::White;$chrome.Effect=$null
  $px=[int][Math]::Ceiling($faceBounds.Width*$scale);$mask=[Windows.Media.Imaging.RenderTargetBitmap]::new($px,$px,96*$scale,96*$scale,[Windows.Media.PixelFormats]::Pbgra32);$mask.Render($maskVisual)
  $bytes=[byte[]]::new($px*$px*4);$mask.CopyPixels($bytes,$px*4,0);$xs=@();$ys=@();for($y=0;$y -lt $px;$y++){for($x=0;$x -lt $px;$x++){if($bytes[4*($y*$px+$x)+3] -ge 128){$xs+=$x;$ys+=$y}}}
  $chrome.Fill=$fill;$chrome.Stroke=$stroke;$chrome.Effect=$effect;$chrome.StrokeThickness=$thickness
  Require ($xs.Count -gt 0) 'Empty circle mask';$maskW=($xs|Measure-Object -Maximum).Maximum-($xs|Measure-Object -Minimum).Minimum+1;$maskH=($ys|Measure-Object -Maximum).Maximum-($ys|Measure-Object -Minimum).Minimum+1
  Require ([Math]::Abs($maskW-$maskH) -le 1) 'Raster circle is elliptical'
  $records.Add(@{Name=$name;Status='PASS';Method='Offscreen DPI rendering; hover condition substituted; pressed via protected setter';Scale=$scale;Dpi=96*$scale;VisualDIP=24;VisualPixelWidth=$faceBounds.Width*$scale;VisualPixelHeight=$faceBounds.Height*$scale;MaskPixelWidth=$maskW;MaskPixelHeight=$maskH;CrossCenterErrorX=$centerDx;CrossCenterErrorY=$centerDy;HitDIPWidth=27;HitDIPHeight=36;WidthReductionPercent=(100*(27-24)/27);Image=$name+'.png'})
  Write-Host ('PASS '+$name+' circle '+$maskW+'x'+$maskH+' px; center error '+$centerDx+','+$centerDy)
 }
}
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run,$records)
 Add-Type -AssemblyName System.Drawing;$paths=@();for($n=1;$n -le 2;$n++){$p=Join-Path $run.Root ($n.ToString()+'.png');$bitmap=[Drawing.Bitmap]::new(10,10);try{$bitmap.Save($p,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()};$paths+=$p}
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $run.Root -UserDataRoot $run.Root -Harness {
  function Find-Remove($v){if($v -is [Windows.Controls.Button] -and $v.Content -eq '×'){return $v};for($n=0;$n -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($v);$n++){$found=Find-Remove ([Windows.Media.VisualTreeHelper]::GetChild($v,$n));if($found){return $found}}}
  $window.Show();&$actions.Add $paths;$window.UpdateLayout();$button=Find-Remove $ui.InputList;$id=[string]$button.Tag;$source=$state.Items[0].Source;$hash=(Get-FileHash $source).Hash
  Require ($null -ne $button.InputHitTest([Windows.Point]::new(1,1))) 'Actual transparent corner click area lost'
  $state.DialogResponder={@{Accepted=$false;Remember=$false}};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Require ($state.Items.Count -eq 2) 'Cancel removed input'
  $state.DialogResponder={@{Accepted=$true;Remember=$false}};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Require ($state.Items.Count -eq 1 -and $state.Items[0].Id -ne $id -and (Get-FileHash $source).Hash -eq $hash) 'Remove event or source preservation changed'
  $records.Add(@{Name='Real WPF remove-button event keeps cancellation and original-file preservation';Status='PASS';Method='Owned WPF routed event; no native mouse'})
  $state.AllowClose=$true;$window.Close()
 }
} $app $run $records
$records|ConvertTo-Json -Depth 6|Set-Content (Join-Path $run.Results 'remove-button.json') -Encoding UTF8
Write-Host ('RESULT '+$records.Count+' PASS; '+$run.Results)
