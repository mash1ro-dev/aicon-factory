param([string]$AppRoot,[string]$Root)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
$Root=Assert-OwnedTestRoot $AppRoot $Root
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $AppRoot 'App\ImageEngine.cs') -ReferencedAssemblies System.Drawing.dll,System.Core.dll
$work=Join-Path $Root 'Aspect';[void][IO.Directory]::CreateDirectory($work)
$script:failed=0;$script:records=@();$script:outputs=@{}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;Write-Host ('PASS '+$Name)}catch{$script:failed++;Write-Host ('FAIL '+$Name+': '+$_.Exception.Message)}}
function Require([bool]$Ok,[string]$Reason){if(-not $Ok){throw $Reason}}
$fixtures=@(@('square',141,141,'rect'),@('landscape',231,117,'rect'),@('portrait',117,231,'rect'),@('transparent-ellipse',180,140,'ellipse'),@('circle',171,171,'circle'),@('large-odd',4097,1001,'rect'))
foreach($f in $fixtures){
 $name=$f[0];$path=Join-Path $work ($name+'.png');$b=New-Object Drawing.Bitmap ([int]$f[1]),([int]$f[2]),([Drawing.Imaging.PixelFormat]::Format32bppArgb);$g=[Drawing.Graphics]::FromImage($b)
 try{$g.Clear([Drawing.Color]::Transparent);$g.CompositingMode=[Drawing.Drawing2D.CompositingMode]::SourceCopy
 if($f[3] -eq 'ellipse'){$g.FillEllipse([Drawing.Brushes]::DodgerBlue,25,15,130,110)}elseif($f[3] -eq 'circle'){$g.FillEllipse([Drawing.Brushes]::DodgerBlue,20,20,131,131)}else{$g.FillRectangle([Drawing.Brushes]::DodgerBlue,0,0,$b.Width,$b.Height)}
 $b.Save($path,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
 $before=(Get-FileHash $path).Hash;$r=[Aicon.ImageEngine]::Process($path);$script:outputs[$name]=$r
 Check ($name+' all-seven actual affine matrices uniform') {
  Require ($r.Frames.Count -eq 7 -and $r.Geometry.Count -eq 7) 'Missing frame'
  foreach($size in @(16,24,32,48,64,128,256)){
   foreach($t in $r.Geometry[$size]){Require ($t.ScaleX -eq $t.ScaleY -and $t.ShearX -eq 0 -and $t.ShearY -eq 0) 'Anisotropic matrix';Require ([Math]::Abs($t.DestinationWidth-$t.SourceWidth*$t.ScaleX) -lt 0.0005 -and [Math]::Abs($t.DestinationHeight-$t.SourceHeight*$t.ScaleY) -lt 0.0005) 'Active bounds altered'}
   $t=$r.Geometry[$size][-1];Require ([Math]::Abs($t.DestinationX-($size-$t.DestinationWidth)/2) -lt 0.0001 -and [Math]::Abs($t.DestinationY-($size-$t.DestinationHeight)/2) -lt 0.0001) 'Subpixel center lost'
   $stream=New-Object IO.MemoryStream (,$r.Frames[$size]);$image=New-Object Drawing.Bitmap $stream;try{Require ($image.Width -eq $size -and $image.Height -eq $size) 'Raster size';Require ($image.GetPixel([int]($size/2),[int]($size/2)).A -gt 0) 'Empty raster'}finally{$image.Dispose();$stream.Dispose()}
   [IO.File]::WriteAllBytes((Join-Path $work ($name+'-'+$size+'.png')),$r.Frames[$size])
   $script:records+=@([pscustomobject]@{Fixture=$name;Size=$size;TrimmedWidth=$r.TrimmedWidth;TrimmedHeight=$r.TrimmedHeight;Stages=@($r.Geometry[$size])})
  }
 }
 Check ($name+' source unchanged') {Require ((Get-FileHash $path).Hash -eq $before) 'Source mutated'}
}
Check 'noninteger final height retained for ellipse at 16 pixels' {$t=$script:outputs['transparent-ellipse'].Geometry[16][-1];Require ([Math]::Abs($t.DestinationHeight-[Math]::Round($t.DestinationHeight)) -gt 0.05) 'Height rounded before rendering'}
Check 'large odd master keeps fractional active bounds' {$ts=$script:outputs['large-odd'].Geometry[16];Require (@($ts|Where-Object Stage -eq 'MasterHalf').Count -gt 0) 'No master stage';Require (@($ts|Where-Object {($_.SourceWidth % 1) -ne 0 -or ($_.SourceHeight % 1) -ne 0}).Count -gt 0) 'Intermediate bounds rounded'}
Check 'WPF image controls use Uniform without forced decode width' {$x=[xml](Get-Content (Join-Path $AppRoot 'App\MainWindow.xaml') -Raw -Encoding UTF8);$images=@($x.SelectNodes('//*[local-name()="Image"]')|Where-Object {$_.'Name' -in @('SourcePreview','Preview16','Preview32','Preview48','Preview256')});Require ($images.Count -eq 5) 'Missing images';Require (@($images|Where-Object Stretch -ne 'Uniform').Count -eq 0) 'Nonuniform stretch';$gui=Get-Content (Join-Path $AppRoot 'App\Gui.ps1') -Raw -Encoding UTF8;Require ($gui -notmatch '\.DecodePixelWidth\s*=') 'Independent WIC dimension quantization'}
$script:records|ConvertTo-Json -Depth 8|Set-Content (Join-Path $work 'geometry.json') -Encoding UTF8
if($script:failed){exit 1};exit 0
