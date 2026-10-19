param([string]$AppRoot,[string]$Root,[string]$ResultDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
$Root=Assert-OwnedTestRoot $AppRoot $Root $ResultDirectory
Import-Module (Join-Path $AppRoot 'App\AiconFactory.psm1') -Force
Add-Type -AssemblyName System.Drawing
$script:SupplementRoot=Join-Path $Root 'Supplement'
[void][IO.Directory]::CreateDirectory($script:SupplementRoot)
$script:Sources=@{};$script:SourceHashes=@{};$script:Outputs=@{}
foreach($ext in @('png','jpg','jpeg')){
    $p=Join-Path $script:SupplementRoot ('format.'+$ext)
    $b=[Drawing.Bitmap]::new(90,70);$g=[Drawing.Graphics]::FromImage($b)
    try{$g.Clear([Drawing.Color]::White);$g.FillEllipse([Drawing.Brushes]::CornflowerBlue,15,10,60,50);$b.Save($p,$(if($ext -eq 'png'){[Drawing.Imaging.ImageFormat]::Png}else{[Drawing.Imaging.ImageFormat]::Jpeg}))}finally{$g.Dispose();$b.Dispose()}
    $script:Sources[$ext]=$p;$script:SourceHashes[$ext]=(Get-FileHash -LiteralPath $p).Hash
}
$p=Join-Path $script:SupplementRoot 'format.webp'
[IO.File]::WriteAllBytes($p,[Convert]::FromBase64String('UklGRiwAAABXRUJQVlA4TB8AAAAvD8ACEA8wKIM8UPMf8CDMNtpv/qYHcXOI6P8EcGeRAA=='))
$script:Sources.webp=$p;$script:SourceHashes.webp=(Get-FileHash -LiteralPath $p).Hash
function Assert-Supplement([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Rejected([scriptblock]$Body){$caught=$false;try{&$Body|Out-Null}catch{$caught=$true};Assert-Supplement $caught 'Expected rejection'}
Describe 'Supplemental functional coverage (Pester, isolated Root)' {
    foreach($ext in @('png','jpg','jpeg','webp')){
        It ('loads '+$ext+' and writes expected name/category/root') {
            $r=New-AiconFactoryIcon -Source $script:Sources[$ext] -Name ('format-'+$ext) -Category Image -Root $script:SupplementRoot
            Assert-Supplement ($r.IconPath -eq (Join-Path $script:SupplementRoot ('Library\ICO\Image\format-'+$ext+'.ico'))) 'Wrong output path/name/category'
            Assert-Supplement ([IO.File]::Exists($r.IconPath)) 'Missing ICO'
            $script:Outputs[$ext]=$r
        }
    }
    It 'preserves bytes of all four inputs' {
        foreach($ext in @('png','jpg','jpeg','webp')){Assert-Supplement ((Get-FileHash -LiteralPath $script:Sources[$ext]).Hash -eq $script:SourceHashes[$ext]) ('Input modified: '+$ext)}
    }
    It 'contains exactly seven ICO entries and matching decodable PNG frames' {
        $r=$script:Outputs.png;$bytes=[IO.File]::ReadAllBytes($r.IconPath)
        Assert-Supplement ([BitConverter]::ToUInt16($bytes,4) -eq 7) 'ICO count'
        $sizes=@(16,24,32,48,64,128,256)
        for($i=0;$i -lt 7;$i++){
            $s=[int]$bytes[6+16*$i];if($s -eq 0){$s=256};Assert-Supplement ($s -eq $sizes[$i]) 'ICO sizes'
            $b=[Drawing.Bitmap]::new($r.Frames[$s]);try{Assert-Supplement ($b.Width -eq $s -and $b.Height -eq $s) 'Preview dimensions'}finally{$b.Dispose()}
        }
    }
    It 'numbers duplicate names without overwriting existing ICO bytes' {
        $r=$script:Outputs.png;$hash=(Get-FileHash -LiteralPath $r.IconPath).Hash
        $next=New-AiconFactoryIcon -Source $script:Sources.png -Name format-png -Category Image -Root $script:SupplementRoot
        Assert-Supplement ($next.IconPath.EndsWith('format-png_02.ico')) 'Duplicate suffix'
        Assert-Supplement ((Get-FileHash -LiteralPath $r.IconPath).Hash -eq $hash) 'Original ICO overwritten'
    }
    It 'rejects corrupted, absent, unsupported and invalid-name inputs without creating ICOs' {
        $bad=Join-Path $script:SupplementRoot 'bad.png';[IO.File]::WriteAllText($bad,'bad')
        $txt=Join-Path $script:SupplementRoot 'bad.txt';[IO.File]::WriteAllText($txt,'keep')
        $count=@(Get-ChildItem -LiteralPath (Join-Path $script:SupplementRoot 'Library\ICO') -Recurse -Filter '*.ico').Count
        Assert-Rejected {New-AiconFactoryIcon -Source $bad -Root $script:SupplementRoot}
        Assert-Rejected {New-AiconFactoryIcon -Source $txt -Root $script:SupplementRoot}
        Assert-Rejected {New-AiconFactoryIcon -Source (Join-Path $script:SupplementRoot 'absent.png') -Root $script:SupplementRoot}
        Assert-Rejected {New-AiconFactoryIcon -Source $script:Sources.png -Name CON -Root $script:SupplementRoot}
        Assert-Supplement (@(Get-ChildItem -LiteralPath (Join-Path $script:SupplementRoot 'Library\ICO') -Recurse -Filter '*.ico').Count -eq $count) 'Rejected input created an ICO'
    }
    It 'logs readable success and failure JSON with correct operation/path/error fields' {
        $records=@(Get-ChildItem -LiteralPath (Join-Path $script:SupplementRoot 'Logs') -Filter '*.jsonl'|Get-Content|ForEach-Object {$_|ConvertFrom-Json})
        $success=@($records|Where-Object {$_.Operation -eq 'Generate' -and $_.Success})
        $failure=@($records|Where-Object {$_.Operation -eq 'Generate' -and -not $_.Success})
        Assert-Supplement ($success.Count -ge 5 -and $failure.Count -ge 4) 'Missing success/failure log entries'
        foreach($r in $records){Assert-Supplement ([bool]$r.Timestamp) 'Missing timestamp';if(-not $r.Success){Assert-Supplement (-not [string]::IsNullOrWhiteSpace($r.Error)) 'Missing failure reason'}}
    }
    foreach($ext in @('ps1','bat','cmd')){
        It ('applies '+$ext+' shortcut with correct TargetPath/IconLocation and restores safely') {
            $target=Join-Path $script:SupplementRoot ('supplement.'+$ext);[IO.File]::WriteAllText($target,'dummy; never execute');$hash=(Get-FileHash -LiteralPath $target).Hash
            $r=Set-AiconFactoryIcon -Icon $script:Outputs.png.IconPath -Target $target -Destination SameFolder -ShortcutName ('link-'+$ext) -Root $script:SupplementRoot
            $shell=New-Object -ComObject WScript.Shell;$lnk=$shell.CreateShortcut($r.TargetPath)
            try{
                $expected=$(if($ext -eq 'ps1'){Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'}else{$target})
                Assert-Supplement ($lnk.TargetPath -ieq $expected) 'Wrong TargetPath'
                $location=$lnk.IconLocation;$comma=$location.LastIndexOf(',')
                Assert-Supplement ($comma -gt 0 -and $location.Substring(0,$comma).Trim('"') -eq $script:Outputs.png.IconPath -and $location.Substring($comma+1).Trim() -eq '0') 'Wrong IconLocation'
                Assert-Supplement ($r.TargetPath -eq (Join-Path $script:SupplementRoot ('link-'+$ext+'.lnk'))) 'Wrong shortcut destination/name'
            }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($lnk);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
            $manifest=Get-Content -LiteralPath (Join-Path $script:SupplementRoot ('Backup\'+$r.BackupId+'\manifest.json')) -Raw -Encoding UTF8|ConvertFrom-Json
            Assert-Supplement ($manifest.State -eq 'applied' -and $manifest.Kind -eq 'CreatedShortcut') 'Wrong backup state/kind'
            Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $script:SupplementRoot -Confirm:$false|Out-Null
            Assert-Supplement (-not [IO.File]::Exists($r.TargetPath) -and (Get-FileHash -LiteralPath $target).Hash -eq $hash) 'Unsafe restore'
        }
    }
    It 'logs application and restoration successes and failures' {
        Assert-Rejected {Set-AiconFactoryIcon -Icon $script:Outputs.png.IconPath -Target (Join-Path $script:SupplementRoot 'absent.ps1') -Root $script:SupplementRoot}
        Assert-Rejected {Restore-AiconFactoryIcon -BackupId ('0'*32) -Root $script:SupplementRoot -Confirm:$false}
        $records=@(Get-ChildItem -LiteralPath (Join-Path $script:SupplementRoot 'Logs') -Filter '*.jsonl'|Get-Content|ForEach-Object {$_|ConvertFrom-Json})
        foreach($op in @('Apply','Restore')){Assert-Supplement (@($records|Where-Object {$_.Operation -eq $op -and $_.Success}).Count -ge 3) ('Missing '+$op+' success');Assert-Supplement (@($records|Where-Object {$_.Operation -eq $op -and -not $_.Success -and $_.Error}).Count -ge 1) ('Missing '+$op+' error')}
    }
    It 'Shell resolves shortcut ICO pixels with spaces and Japanese paths' {
        Add-Type -Path (Join-Path $PSScriptRoot 'ShellIconTest.cs') -ReferencedAssemblies System.Drawing
        $icon=New-AiconFactoryIcon -Source $script:Sources.png -Name 'shell icon space' -Category Image -Root $script:SupplementRoot
        $target=Join-Path $script:SupplementRoot 'shell dummy.exe';[IO.File]::WriteAllText($target,'never execute')
        $result=Set-AiconFactoryIcon -Icon $icon.IconPath -Target $target -Destination SameFolder -Root $script:SupplementRoot
        try {Assert-Supplement ([ShellIconTest]::BluePixelMatch($result.TargetPath,$icon.Frames[32]) -gt 0.9) 'Shell displayed a generic shortcut icon'}
        finally {Restore-AiconFactoryIcon -BackupId $result.BackupId -Root $script:SupplementRoot -Confirm:$false|Out-Null}
    }
}
