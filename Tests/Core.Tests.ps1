#Requires -Version 5.1
param([string]$Root=(Join-Path (Split-Path $PSScriptRoot -Parent) 'Validation'))
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'These tests require Windows; no results have been simulated.' }
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'App\AiconFactory.psm1') -Force
$module=Get-Module AiconFactory
$failures=New-Object 'System.Collections.Generic.List[string]';$passed=0
function Check([string]$Label,[scriptblock]$Body) { try { & $Body;$script:passed++;Write-Host "PASS $Label" } catch { $script:failures.Add($Label+': '+$_.Exception.Message);Write-Host "FAIL $Label" } }
function Assert([bool]$Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Body) { $did=$false;try { & $Body } catch { $did=$true };Assert $did 'Expected rejection' }
# Never overwrite a fixture from a previous run; all changes remain in this app-local sandbox.
$Root=& $module { param($p) Assert-AiconWritableTarget $p } $Root
$testRoot=Join-Path $Root ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($testRoot)
Check 'Reject traversal, ADS, reserved names, trailing dots/spaces' {
    foreach ($n in @('..','../oops','a\b','CON','nul.txt','LPT1','a:stream','a*','a?','name.','name ')) { Throws { & $module { param($s) Assert-AiconName $s } $n } }
    Assert ((& $module { Assert-AiconName '透也_01' }) -eq '透也_01')
}
Check 'Reject UNC, relative, drive root and system writes' {
    foreach ($p in @('relative','C:relative','\\server\share\x','C:\',($env:windir+'\temp\x'))) { Throws { & $module { param($s) Assert-AiconWritableTarget $s } $p } }
}
Check 'Atomic numbering preserves existing bytes' {
    $d=Join-Path $testRoot 'collision';[void][IO.Directory]::CreateDirectory($d);[IO.File]::WriteAllText((Join-Path $d 'Touya.ico'),'original')
    $r=& $module { param($dir) New-AiconReservedFile $dir 'Touya' '.ico' } $d
    try { Assert ($r.Path.EndsWith('Touya_02.ico'));Assert ([IO.File]::ReadAllText((Join-Path $d 'Touya.ico')) -eq 'original') } finally { $r.Stream.Dispose() }
}
Add-Type -AssemblyName System.Drawing
$source=Join-Path $testRoot '元画像.png';$bmp=New-Object Drawing.Bitmap 100,60;$g=[Drawing.Graphics]::FromImage($bmp)
try { $g.Clear([Drawing.Color]::Transparent);$g.FillRectangle([Drawing.Brushes]::Aqua,20,10,60,40);$bmp.Save($source,[Drawing.Imaging.ImageFormat]::Png) } finally { $g.Dispose();$bmp.Dispose() }
$before=(Get-FileHash -LiteralPath $source).Hash;$generated=$null
Check 'Generate seven sizes; preserve original; duplicate numbered' {
    $script:generated=New-AiconFactoryIcon -Source $source -Root $testRoot -Name 'テスト' -Category Other
    $second=New-AiconFactoryIcon -Source $source -Root $testRoot -Name 'テスト' -Category Other
    Assert ($second.IconPath.EndsWith('テスト_02.ico'));Assert ((Get-FileHash -LiteralPath $source).Hash -eq $before)
    $bytes=[IO.File]::ReadAllBytes($script:generated.IconPath);Assert ([BitConverter]::ToUInt16($bytes,4) -eq 7)
    $sizes=@(16,24,32,48,64,128,256)
    for ($i=0;$i -lt 7;$i++) { $v=[int]$bytes[6+16*$i];if ($v -eq 0) { $v=256 };Assert ($v -eq $sizes[$i]);Assert ([IO.File]::Exists($script:generated.Frames[$sizes[$i]])) }
}
Check 'Bad source/name/category create no output and preserve original' {
    Throws { New-AiconFactoryIcon -Source $source -Root $testRoot -Name '..' }
    Throws { New-AiconFactoryIcon -Source $source -Root $testRoot -Category '..' }
    Throws { New-AiconFactoryIcon -Source (Join-Path $testRoot 'absent.png') -Root $testRoot }
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $before)
}
Check 'Pre-existing preview directory preserved on collision' {
    $folder=Join-Path $testRoot 'Library\ICO\Other\Existing.ico.previews';[void][IO.Directory]::CreateDirectory($folder)
    $sentinel=Join-Path $folder 'keep.txt';[IO.File]::WriteAllText($sentinel,'keep')
    Throws { New-AiconFactoryIcon -Source $source -Root $testRoot -Name Existing }
    Assert ([IO.File]::ReadAllText($sentinel) -eq 'keep')
    Assert (-not [IO.File]::Exists((Join-Path $testRoot 'Library\ICO\Other\Existing.ico')))
}
Check 'PS1 shortcut does not modify original; no bypass argument; restore removes only created shortcut' {
    Assert ($null -ne $generated)
    $target=Join-Path $testRoot 'hello & 日本語.ps1';[IO.File]::WriteAllText($target,'Write-Output "hello"');$hash=(Get-FileHash -LiteralPath $target).Hash
    $r=Set-AiconFactoryIcon -Icon $generated.IconPath -Target $target -Destination Custom -OutputDirectory $testRoot -Root $testRoot
    $shell=New-Object -ComObject WScript.Shell;$lnk=$shell.CreateShortcut($r.TargetPath)
    try { Assert ($lnk.Arguments -eq ('-NoProfile -File "'+$target+'"'));Assert ($lnk.Arguments -notmatch 'Bypass|Unrestricted') } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($lnk);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    Assert ((Get-FileHash -LiteralPath $target).Hash -eq $hash)
    Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $testRoot -Confirm:$false | Out-Null
    Assert (-not [IO.File]::Exists($r.TargetPath));Assert ((Get-FileHash -LiteralPath $target).Hash -eq $hash)
}
Check 'Folder ini backup, unrelated settings and exact restore' {
    $folder=Join-Path $testRoot 'folder';[void][IO.Directory]::CreateDirectory($folder);$ini=Join-Path $folder 'desktop.ini'
    [IO.File]::WriteAllText($ini,"[.ShellClassInfo]`r`nInfoTip=keep me`r`nIconFile=old.ico`r`nIconIndex=0`r`n[Other]`r`nValue=42",[Text.Encoding]::Unicode)
    $hash=(Get-FileHash -LiteralPath $ini).Hash;$attrs=[IO.File]::GetAttributes($folder)
    $r=Set-AiconFactoryIcon -Icon $generated.IconPath -Target $folder -Root $testRoot
    $text=Get-Content -LiteralPath $ini -Raw;Assert ($text.Contains('InfoTip=keep me'));Assert ($text.Contains('Value=42'));Assert (-not $text.Contains('IconFile='))
    Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $testRoot -Confirm:$false | Out-Null
    Assert ((Get-FileHash -LiteralPath $ini).Hash -eq $hash);Assert ([IO.File]::GetAttributes($folder) -eq $attrs)
}
Check 'Restore refuses to overwrite changes made after apply' {
    $target=Join-Path $testRoot 'other.cmd';[IO.File]::WriteAllText($target,'echo hello')
    $r=Set-AiconFactoryIcon -Icon $generated.IconPath -Target $target -Destination Custom -OutputDirectory $testRoot -Root $testRoot
    [IO.File]::AppendAllText($r.TargetPath,'changed');$h=(Get-FileHash -LiteralPath $r.TargetPath).Hash
    Throws { Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $testRoot -Confirm:$false }
    Assert ((Get-FileHash -LiteralPath $r.TargetPath).Hash -eq $h)
}
Check 'Invalid target leaves generated icon intact' {
    $target=Join-Path $testRoot 'do-not-touch.txt';[IO.File]::WriteAllText($target,'unchanged')
    Throws { Set-AiconFactoryIcon -Icon $generated.IconPath -Target $target -Root $testRoot }
    Assert ([IO.File]::ReadAllText($target) -eq 'unchanged');Assert ([IO.File]::Exists($generated.IconPath))
}
Write-Host "$passed passed; $($failures.Count) failed. Fixtures: $testRoot"
if ($failures.Count) { throw ($failures -join "`n") }
