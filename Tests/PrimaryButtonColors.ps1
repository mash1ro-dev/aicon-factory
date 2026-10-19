param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -TypeDefinition @'
using System.Windows.Controls;
public class ColorProbeButton : Button { public void ProbePressed(bool value) { IsPressed=value; } }
'@ -ReferencedAssemblies PresentationFramework,PresentationCore,WindowsBase,System.Xaml
function Require($ok,$why){if(-not $ok){throw $why}}
function Get-Primary($xml){$xml.SelectSingleNode('//*[local-name()="Style" and @*[local-name()="Key"]="PrimaryButton"]')}
function Brush-Colors($brush){if($brush -is [Windows.Media.SolidColorBrush]){return $brush.Color.ToString()};return (($brush.GradientStops|ForEach-Object {$_.Color.ToString()}) -join ',')}
$after=[xml][IO.File]::ReadAllText((Join-Path $app 'App\MainWindow.xaml'))
# Assert current v0.1.1 controls and original trigger conditions before substituting
# the read-only hover input in an in-memory test copy. No external XAML fixture.
$primary=Get-Primary $after;Require ($null -ne $primary) 'PrimaryButton style missing'
$labels=@{GenerateButton='仕上がりを確認';SaveButton='選んだアイコンを保存';ApplyButton='アイコンを設定'}
foreach($name in $labels.Keys){
 $buttons=$after.SelectNodes('//*[local-name()="Button" and @*[local-name()="Name"]="'+$name+'"]')
 Require ($buttons.Count -eq 1 -and $buttons[0].Content -ceq $labels[$name] -and $buttons[0].Style -ceq '{StaticResource PrimaryButton}' -and $buttons[0].IsEnabled -eq 'False') ('Primary control wiring changed: '+$name)
}
foreach($property in @('IsMouseOver','IsPressed','IsKeyboardFocused')){
 $conditions=$primary.SelectNodes('.//*[local-name()="Condition" and @Property="'+$property+'"]')
 Require ($conditions.Count -eq 1 -and $conditions[0].Value -eq 'True') ('Primary trigger missing: '+$property)
 $enabled=$conditions[0].ParentNode.SelectNodes('*[@Property="IsEnabled" and @Value="True"]')
 Require ($enabled.Count -eq 1) ('Primary enabled gate missing: '+$property)
}
Require ($primary.SelectNodes('.//*[local-name()="Trigger" and @Property="IsEnabled" and @Value="False"]').Count -eq 1) 'Primary disabled trigger missing'
$records=[Collections.Generic.List[object]]::new();$pictures=[Collections.Generic.List[object]]::new()
foreach($version in @('current')){
 $xml=$after.Clone();$primary=Get-Primary $xml
 # Read-only IsMouseOver cannot be set through WPF's public API. Substitute only
 # this condition in a test copy; all brush setters and other triggers stay intact.
 foreach($n in $primary.SelectNodes('.//*[@Property="IsMouseOver"]')){$n.SetAttribute('Property','Tag')}
 $resources=$xml.SelectSingleNode('//*[local-name()="Window.Resources"]').InnerXml
 $dictionary=[Windows.Markup.XamlReader]::Parse('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">'+$resources+'</ResourceDictionary>')
 $w=[Windows.Window]::new();$w.Width=460;$w.Height=190;$w.WindowStartupLocation='CenterScreen';$w.Title='Owned primary-button color test';$w.Background='#F5EFE6';$w.Resources=$dictionary
 $panel=[Windows.Controls.StackPanel]::new();$panel.Margin=20;$sink=[Windows.Controls.TextBox]::new();$sink.Height=25;$panel.Children.Add($sink)|Out-Null
 $button=[ColorProbeButton]::new();$button.Width=360;$button.Style=$w.Resources['PrimaryButton'];$button.Margin='0,12,0,0';$panel.Children.Add($button)|Out-Null;$w.Content=$panel
 try{
  $w.Show();$w.Activate()|Out-Null;$w.UpdateLayout()
  foreach($label in @('仕上がりを確認','選んだアイコンを保存','アイコンを設定')){
   $button.Content=$label
   foreach($state in @('normal','hover','pressed','focus','disabled')){
    $button.IsEnabled=$true;$button.ProbePressed($false);$button.Tag='False';[void][Windows.Input.Keyboard]::Focus($sink)
    if($state -in @('hover','pressed','disabled')){$button.Tag='True'}
    if($state -in @('pressed','disabled')){$button.ProbePressed($true)}
    if($state -eq 'focus'){[void][Windows.Input.Keyboard]::Focus($button)}
    if($state -eq 'disabled'){$button.IsEnabled=$false;$button.ProbePressed($true)}
    $w.UpdateLayout();$w.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
    $chrome=$button.Template.FindName('Chrome',$button);$drop=$button.Template.FindName('Droplet',$button)
    $background=Brush-Colors $chrome.Background;$edge=Brush-Colors $chrome.BorderBrush;$shadow=$chrome.Effect.Color.ToString()
    $mode=switch($state){'hover'{'Test-copy Tag condition; static original hover condition checked'} 'pressed'{'Actual IsPressed dependency property via protected setter; hover condition surrogate'} 'focus'{'Actual Keyboard.Focus and IsKeyboardFocused'} 'disabled'{'Actual IsEnabled=false, competing hover/pressed requested'} default{'Actual normal template'}}
    $status='FAIL';$errorText=''
     try{
      $expected=switch($state){'hover'{'#FFFFF8D9,#FFF7DF96,#FFFFF9E2'} 'pressed'{'#FFF5D779,#FFDBB650,#FFEDCD7B'} 'disabled'{'#FFDADDE0'} default{'#FFFFF2BE,#FFF7DF8F,#FFECCD72,#FFF5E2A1,#FFFFF4CF'}}
      Require ($background -ceq $expected) ('Background '+$background)
      $bottom=$button.Template.FindName('BottomSheen',$button);$inner=$button.Template.FindName('InnerEdge',$button);$glaze=$button.Template.FindName('TopGlaze',$button)
      if($state -eq 'disabled'){
       Require ($edge -eq '#FFB9BEC2' -and $shadow -eq '#FF7C8084' -and (Brush-Colors $bottom.BorderBrush) -eq '#FFF1F2F3' -and (Brush-Colors $inner.BorderBrush) -eq '#FFE5E7E8') 'Disabled color leak'
       Require ($drop.RenderTransform.Value.IsIdentity -and $drop.Opacity -eq 0.68) 'Disabled transform/opacity leak'
      }else{
       Require ($shadow -eq '#FF8D783E' -and (Brush-Colors $bottom.BorderBrush) -eq '#FFF9E7A8') 'Cool sheen/shadow remains'
       if($state -eq 'focus'){Require ($button.IsKeyboardFocused -and $edge -eq '#FF8A651D' -and $chrome.BorderThickness.Left -eq 2) 'Keyboard focus missing'}
       if($state -eq 'pressed'){Require ($button.IsPressed -and [Math]::Abs($drop.RenderTransform.Value.M11-0.985) -lt 0.0001) 'Pressed trigger not active'}
      }
      Require ($button.ActualHeight -eq 56 -and $button.Padding.ToString() -eq '20,9,20,9' -and $chrome.CornerRadius.ToString() -eq '27,35,30,19') 'Geometry changed'
      $status='PASS'
     }catch{$status='FAIL';$errorText=$_.ToString()}
    $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($button)
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int](380*$dpi.DpiScaleX),[int](76*$dpi.DpiScaleY),$dpi.PixelsPerInchX,$dpi.PixelsPerInchY,[Windows.Media.PixelFormats]::Pbgra32)
    $visual=[Windows.Media.DrawingVisual]::new();$dc=$visual.RenderOpen();$dc.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#F5EFE6'),$null,[Windows.Rect]::new(0,0,380,76));$dc.DrawRectangle([Windows.Media.VisualBrush]::new($button),$null,[Windows.Rect]::new(10,10,360,56));$dc.Close();$bitmap.Render($visual);$bitmap.Freeze()
    $index=$records.Count;$filename=$version+'-'+$index+'-'+$state+'.png';$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$f=[IO.File]::Create((Join-Path $run.Results $filename));try{$enc.Save($f)}finally{$f.Dispose()}
    $pictures.Add(@{Version=$version;Label=$label;State=$state;Bitmap=$bitmap})
    $records.Add([pscustomobject]@{Version=$version;Button=$label;State=$state;Status=$status;Method=$mode;Background=$background;Edge=$edge;Shadow=$shadow;IsPressed=$button.IsPressed;IsKeyboardFocused=$button.IsKeyboardFocused;IsEnabled=$button.IsEnabled;Dpi=$dpi.PixelsPerInchX;Error=$errorText;Image=$filename})
   }
  }
 }finally{$w.Close()}
}
# Render a contact sheet from the WPF captures; no OS screenshot or image model.
$sheet=[Windows.Media.DrawingVisual]::new();$dc=$sheet.RenderOpen();$dc.DrawRectangle([Windows.Media.Brushes]::White,$null,[Windows.Rect]::new(0,0,1900,370))
$font=[Windows.Media.Typeface]::new('Segoe UI');$ink=[Windows.Media.Brushes]::Black
for($row=0;$row -lt 3;$row++){
 $title='CURRENT v0.1.1 / button '+($row+1)
 $dc.DrawText([Windows.Media.FormattedText]::new($title,[Globalization.CultureInfo]::InvariantCulture,[Windows.FlowDirection]::LeftToRight,$font,15,$ink),[Windows.Point]::new(12,$row*110+2))
 for($col=0;$col -lt 5;$col++){$p=$pictures[$row*5+$col];$dc.DrawText([Windows.Media.FormattedText]::new($p.State,[Globalization.CultureInfo]::InvariantCulture,[Windows.FlowDirection]::LeftToRight,$font,13,$ink),[Windows.Point]::new($col*380+12,$row*110+23));$dc.DrawImage($p.Bitmap,[Windows.Rect]::new($col*380,$row*110+40,380,76))}
}
$dc.Close();$out=[Windows.Media.Imaging.RenderTargetBitmap]::new(1900,370,96,96,[Windows.Media.PixelFormats]::Pbgra32);$out.Render($sheet);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($out));$f=[IO.File]::Create((Join-Path $run.Results 'current-states.png'));try{$enc.Save($f)}finally{$f.Dispose()}
$records|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'colors.json') -Encoding UTF8
$pass=@($records|Where-Object Status -eq PASS).Count;$fail=@($records|Where-Object Status -eq FAIL).Count
Write-Host ('RESULT '+$pass+' PASS / '+$fail+' FAIL; '+$run.Results)
if($fail -or $pass -ne 15){$records|Where-Object Status -eq FAIL|Format-List;exit 1}
