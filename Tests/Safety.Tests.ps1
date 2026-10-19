#Requires -Version 5.1
param([string]$Root=(Join-Path (Split-Path $PSScriptRoot -Parent) 'Validation'))
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows tests only; no runtime results are simulated.' }
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'App\AiconFactory.psm1') -Force
$module=Get-Module AiconFactory
$failures=New-Object 'System.Collections.Generic.List[string]';$passed=0
function Assert([bool]$Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Body) { $did=$false;try { & $Body } catch { $did=$true };Assert $did 'Expected rejection' }
function Check([string]$Label,[scriptblock]$Body) { try { & $Body;$script:passed++;Write-Host "PASS $Label" } catch { $script:failures.Add($Label+': '+$_.Exception.Message);Write-Host "FAIL $Label" } }
$Root=& $module { param($p) Assert-AiconWritableTarget $p } $Root
$work=Join-Path $Root ('safety-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
$icon=Join-Path $work 'fixture.ico';[IO.File]::WriteAllBytes($icon,[byte[]]@(0,0,1,0,0,0))
# The application tests icon conversion elsewhere; this file is a harmless path fixture.
function New-Fixture([string]$Name) {
    $folder=Join-Path $work $Name;[void][IO.Directory]::CreateDirectory($folder)
    $ini=Join-Path $folder 'desktop.ini';[IO.File]::WriteAllText($ini,"[.ShellClassInfo]`r`nInfoTip=preserve`r`nIconResource=before.ico,0",[Text.Encoding]::Unicode)
    return [pscustomobject]@{Folder=$folder;Ini=$ini;Hash=(Get-FileHash -LiteralPath $ini).Hash;Attrs=[IO.File]::GetAttributes($ini);FolderAttrs=[IO.File]::GetAttributes($folder)}
}
Check 'Reject root-relative, bare drive and ambiguous Win32 paths' {
    foreach ($p in @('C:','\temp\x','C:\Windows.\temp','C:\foo \bar','C:\foo\..\bar','C:\NUL\x')) { Throws { & $module { param($v) Get-AiconFullPath $v } $p } }
}
Check 'Preflight parse failure never rewrites original bytes or attributes' {
    $f=New-Fixture 'duplicate'
    [IO.File]::AppendAllText($f.Ini,"`r`n[.ShellClassInfo]`r`nInfoTip=duplicate",[Text.Encoding]::Unicode)
    $hash=(Get-FileHash -LiteralPath $f.Ini).Hash;$write=[IO.File]::GetLastWriteTimeUtc($f.Ini)
    Throws { Set-AiconFactoryIcon -Icon $icon -Target $f.Folder -Root $work }
    Assert ((Get-FileHash -LiteralPath $f.Ini).Hash -eq $hash)
    Assert ([IO.File]::GetLastWriteTimeUtc($f.Ini) -eq $write)
    Assert ([IO.File]::GetAttributes($f.Ini) -eq $f.Attrs)
}
Check 'Manifest failure before commit prevents target modification' {
    $f=New-Fixture 'manifest-failure'
    & $module {
        param($ico,$target,$root)
        $script:SafetySavedWriter=(Get-Command Write-AiconManifest).ScriptBlock
        try {
            Set-Item function:script:Write-AiconManifest -Value { param($Directory,$Record) throw 'Injected manifest failure' }
            $failed=$false;try { Set-AiconFactoryIcon -Icon $ico -Target $target -Root $root } catch { $failed=$true }
            if (-not $failed) { throw 'Expected injected failure' }
        } finally { Set-Item function:script:Write-AiconManifest -Value $script:SafetySavedWriter;Remove-Variable SafetySavedWriter -Scope Script }
    } $icon $f.Folder $work
    Assert ((Get-FileHash -LiteralPath $f.Ini).Hash -eq $f.Hash)
    Assert ([IO.File]::GetAttributes($f.Ini) -eq $f.Attrs)
}
Check 'Failed completion manifest rolls back committed file' {
    $f=New-Fixture 'postcommit-failure'
    & $module {
        param($ico,$target,$root)
        $script:SafetySavedWriter=(Get-Command Write-AiconManifest).ScriptBlock;$script:SafetyWriteCount=0
        try {
            Set-Item function:script:Write-AiconManifest -Value {
                param($Directory,$Record)
                $script:SafetyWriteCount++
                if ($script:SafetyWriteCount -eq 3) { throw 'Injected completion failure' }
                & $script:SafetySavedWriter $Directory $Record
            }
            $failed=$false;try { Set-AiconFactoryIcon -Icon $ico -Target $target -Root $root } catch { $failed=$true }
            if (-not $failed) { throw 'Expected injected failure' }
        } finally { Set-Item function:script:Write-AiconManifest -Value $script:SafetySavedWriter;Remove-Variable -Name @('SafetySavedWriter','SafetyWriteCount') -Scope Script }
    } $icon $f.Folder $work
    Assert ((Get-FileHash -LiteralPath $f.Ini).Hash -eq $f.Hash)
    Assert ([IO.File]::GetAttributes($f.Ini) -eq $f.Attrs)
    Assert ([IO.File]::GetAttributes($f.Folder) -eq $f.FolderAttrs)
}
Check 'Restore resumes after original bytes were restored before crash' {
    $f=New-Fixture 'resume';$r=Set-AiconFactoryIcon -Icon $icon -Target $f.Folder -Root $work
    $dir=Join-Path $work ('Backup\'+$r.BackupId);$manifest=Join-Path $dir 'manifest.json'
    $record=Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    $record.State='restoring'; & $module { param($d,$r) Write-AiconManifest $d $r } $dir $record
    [IO.File]::SetAttributes($f.Ini,[IO.FileAttributes]::Normal);[IO.File]::Copy((Join-Path $dir 'original'),$f.Ini,$true)
    Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $work -Confirm:$false | Out-Null
    Assert ((Get-FileHash -LiteralPath $f.Ini).Hash -eq $f.Hash)
    Assert ([IO.File]::GetAttributes($f.Ini) -eq $f.Attrs)
    Assert ((Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).State -eq 'restored')
}
Check 'Restore refuses unrelated later folder attribute changes' {
    $f=New-Fixture 'folder-attrs';$r=Set-AiconFactoryIcon -Icon $icon -Target $f.Folder -Root $work
    $a=[IO.File]::GetAttributes($f.Folder);[IO.File]::SetAttributes($f.Folder,($a -bor [IO.FileAttributes]::Hidden))
    $hash=(Get-FileHash -LiteralPath $f.Ini).Hash
    Throws { Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $work -Confirm:$false }
    Assert ((Get-FileHash -LiteralPath $f.Ini).Hash -eq $hash)
    [IO.File]::SetAttributes($f.Folder,$a)
    Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $work -Confirm:$false | Out-Null
}
Check 'Created-shortcut prepared record never claims an existing original' {
    $rootPath=& $module { param($r) Initialize-AiconRoot $r } $work
    $file=Join-Path $work 'reserved.lnk';[IO.File]::WriteAllBytes($file,[byte[]]@())
    $b=& $module { param($r,$p) Save-AiconBackup $r 'CreatedShortcut' $p } $rootPath $file
    $r=Get-Content -LiteralPath (Join-Path $b.Directory 'manifest.json') -Raw | ConvertFrom-Json
    Assert (-not $r.Existed);Assert ($r.BeforeHash -eq '')
    Restore-AiconFactoryIcon -BackupId $r.Id -Root $work -Confirm:$false | Out-Null
    Assert (-not [IO.File]::Exists($file))
}
Write-Host "$passed passed; $($failures.Count) failed. Fixtures: $work"
if ($failures.Count) { throw ($failures -join "`n") }
