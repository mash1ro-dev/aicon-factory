#Requires -Version 5.1
Set-StrictMode -Version Latest
$script:DefaultRoot = Split-Path -Parent $PSScriptRoot
$script:Categories = @('AI','Image','Audio','Development','Tools','Apps','Other')
function Assert-AiconWindows {
    if ($env:OS -ne 'Windows_NT') { throw 'Windows 11 が必要です。' }
}
function Assert-AiconName {
    param([Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 100 -or $Name -match '[<>:"/\\|?*\x00-\x1f]' -or $Name -match '[. ]$' -or $Name -in @('.','..') -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw '名前に使えない文字、予約名、長さが含まれています。' }
    return $Name
}
function Get-AiconFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'ローカルの絶対パスを指定してください。' }
    foreach ($segment in ($Path.Substring(3) -split '[\\/]')) {
        if ($segment -and ($segment -in @('.','..') -or $segment -match '[. ]$|[<>"|?*\x00-\x1f]' -or $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)')) { throw 'パスに無効な要素が含まれています。' }
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Substring(2).Contains(':')) { throw '代替データストリームは使用できません。' }
    $cursor = $full
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'リンク／ジャンクション経由のパスは使用できません。' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
    return $full
}
function Assert-AiconWritableTarget {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-AiconFullPath $Path
    if ($full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw 'ドライブのルートは変更できません。' }
    foreach ($protected in @($env:windir,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)) {
        if ($protected -and ($full.Equals($protected,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($protected.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) { throw 'システム領域は変更できません。' }
    }
    return $full
}
function Initialize-AiconRoot {
    param([string]$Root=$script:DefaultRoot)
    Assert-AiconWindows
    $rootPath = Assert-AiconWritableTarget $Root
    foreach ($part in @('Library\ICO','Library\Source','Backup','Logs')) {
        $p = Get-AiconFullPath (Join-Path $rootPath $part)
        [void][IO.Directory]::CreateDirectory($p)
    }
    return $rootPath
}
function Write-AiconLog {
    param([string]$Root,[string]$Operation,[string]$Source,[string]$Icon,[string]$Target,[bool]$Success,[string]$ErrorMessage='')
    $record = [ordered]@{Timestamp=[DateTime]::UtcNow.ToString('o');Operation=$Operation;Source=$Source;Icon=$Icon;Target=$Target;Success=$Success;Error=$ErrorMessage}
    try { Add-Content -LiteralPath (Get-AiconFullPath (Join-Path $Root ('Logs\'+(Get-Date -Format yyyy-MM-dd)+'.jsonl'))) -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop } catch { Write-Warning ('ログを保存できません: '+$_.Exception.Message) }
}
function Initialize-AiconEngine {
    if (-not ('Aicon.ImageEngine' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ImageEngine.cs') -ReferencedAssemblies @('System.Drawing.dll','System.Core.dll') -ErrorAction Stop
    }
    [Aicon.ImageEngine]::ConfigureWebPDecoder((Join-Path $PSScriptRoot 'Native\dwebp.exe'))
}
function New-AiconReservedFile {
    param([string]$Directory,[string]$Name,[string]$Extension)
    for ($i=1;$i -le 9999;$i++) {
        $suffix = if ($i -eq 1) { '' } else { '_{0:D2}' -f $i }
        $path = Join-Path $Directory ($Name+$suffix+$Extension)
        try { $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);return [pscustomobject]@{Path=$path;Stream=$stream} }
        catch [IO.IOException] { if ([IO.File]::Exists($path)) { continue };throw }
    }
    throw '同名ファイルが多すぎます。別の名前を指定してください。'
}
function New-AiconFactoryIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory,Position=0)][string]$Source,[string]$Name,[string]$Category='Other',[string]$Root=$script:DefaultRoot,[string]$Target,[ValidateSet('Desktop','SameFolder','Custom')][string]$Destination='Desktop',[string]$OutputDirectory,[string]$ShortcutName)
    $rootPath=Initialize-AiconRoot $Root; $iconPath='';$reservation=$null;$previewDir=$null;$frames=$null
    try {
        $sourcePath=Get-AiconFullPath $Source
        if (-not [IO.File]::Exists($sourcePath)) { throw '入力画像が見つかりません。' }
        if ([IO.Path]::GetExtension($sourcePath).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')) { throw 'PNG / JPG / JPEG / WEBP を選んでください。' }
        if (-not $Name) { $Name=[IO.Path]::GetFileNameWithoutExtension($sourcePath) }
        $Name=Assert-AiconName $Name;$Category=Assert-AiconName $Category
        $categoryDir=Get-AiconFullPath (Join-Path $rootPath ('Library\ICO\'+$Category));[void][IO.Directory]::CreateDirectory($categoryDir)
        Initialize-AiconEngine
        $result=[Aicon.ImageEngine]::Process($sourcePath)
        $reservation=New-AiconReservedFile $categoryDir $Name '.ico';$iconPath=$reservation.Path
        $reservation.Stream.Write($result.Ico,0,$result.Ico.Length);$reservation.Stream.Dispose();$reservation=$null
        $previewDir=$iconPath+'.previews'
        if ([IO.Directory]::Exists($previewDir)) { throw 'プレビュー保存先が既に存在します。' }
        [void][IO.Directory]::CreateDirectory($previewDir);$frames=@{}
        foreach ($size in @(16,24,32,48,64,128,256)) { $p=Join-Path $previewDir ($size.ToString()+'.png');[IO.File]::WriteAllBytes($p,$result.Frames[$size]);$frames[$size]=$p }
        $output=[pscustomobject]@{IconPath=$iconPath;PreviewPath=$frames[256];Frames=$frames;BackupId=$null}
        Write-AiconLog $rootPath 'Generate' $sourcePath $iconPath '' $true
    } catch {
        if ($reservation) { $reservation.Stream.Dispose() }
        if ($iconPath -and [IO.File]::Exists($iconPath)) { [IO.File]::Delete($iconPath) }
        # Only remove a directory this call created, never a pre-existing collision.
        if ($previewDir -and $frames -and [IO.Directory]::Exists($previewDir)) { [IO.Directory]::Delete($previewDir,$true) }
        Write-AiconLog $rootPath 'Generate' $Source $iconPath '' $false $_.Exception.Message
        throw
    }
    if ($Target) {
        try { $applied=Set-AiconFactoryIcon -Icon $iconPath -Target $Target -Root $rootPath -Destination $Destination -OutputDirectory $OutputDirectory -ShortcutName $ShortcutName;$output.BackupId=$applied.BackupId }
        catch { throw ('ICO は保存済みです: '+$iconPath+'。適用だけ失敗しました: '+$_.Exception.Message) }
    }
    return $output
}
function Get-AiconHash { param([string]$Path); if ([IO.File]::Exists($Path)) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash };return '' }
function Enter-AiconTargetLock {
    param([string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToUpperInvariant()))).Replace('-','') }
    finally { $sha.Dispose() }
    $mutex=New-Object Threading.Mutex -ArgumentList @($false,('Local\AiconFactory-'+$hash))
    try {
        $acquired=$false
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'この対象は別の処理で使用中です。完了してから再試行してください。' }
        return $mutex
    } catch { $mutex.Dispose();throw }
}
function Write-AiconManifest {
    param([string]$Directory,$Record)
    $manifest=Get-AiconFullPath (Join-Path $Directory 'manifest.json')
    $temp=Join-Path $Directory ([Guid]::NewGuid().ToString('N')+'.tmp')
    try {
        $bytes=[Text.Encoding]::UTF8.GetPreamble()+[Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 8))
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($manifest)) { [IO.File]::Replace($temp,$manifest,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$manifest) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Save-AiconBackup {
    param([string]$Root,[string]$Kind,[string]$Path,[string]$Folder='')
    $id=[Guid]::NewGuid().ToString('N');$dir=Get-AiconFullPath (Join-Path $Root ('Backup\'+$id));[void][IO.Directory]::CreateDirectory($dir)
    $exists=[IO.File]::Exists($Path);$created=($Kind -eq 'CreatedShortcut')
    $r=[ordered]@{Version=2;Id=$id;Kind=$Kind;Path=$Path;Folder=$Folder;Existed=($exists -and -not $created);FileAttributes=0;FolderAttributes=0;AfterFileAttributes=0;AfterFolderAttributes=0;BeforeHash='';SnapshotHash=(Get-AiconHash $Path);AfterHash='';State='prepared';Timestamp=[DateTime]::UtcNow.ToString('o')}
    if ($r.Existed) {
        $r.FileAttributes=[int][IO.File]::GetAttributes($Path);$r.BeforeHash=$r.SnapshotHash
        [IO.File]::Copy($Path,(Join-Path $dir 'original'),$false)
        if ((Get-AiconHash (Join-Path $dir 'original')) -ne $r.BeforeHash -or (Get-AiconHash $Path) -ne $r.BeforeHash) { throw 'バックアップ中に対象が変更されました。変更せず中止しました。' }
    }
    if ($Folder) { $r.FolderAttributes=[int][IO.File]::GetAttributes($Folder) }
    Write-AiconManifest $dir $r
    return [pscustomobject]@{Record=$r;Directory=$dir}
}
function Complete-AiconBackup {
    param($Backup,[string]$State='applied')
    $Backup.Record.State=$State
    Write-AiconManifest $Backup.Directory $Backup.Record
}
function Assert-AiconSnapshot {
    param($Backup)
    $r=$Backup.Record;$p=Get-AiconFullPath $r.Path
    if ((Get-AiconHash $p) -ne $r.SnapshotHash) { throw '準備中に対象が変更されました。上書きせず中止しました。' }
    if ($r.Existed -and [int][IO.File]::GetAttributes($p) -ne $r.FileAttributes) { throw '準備中に対象の属性が変更されました。' }
    if ($r.Folder -and [int][IO.File]::GetAttributes((Get-AiconFullPath $r.Folder)) -ne $r.FolderAttributes) { throw '準備中にフォルダーの属性が変更されました。' }
}
function Invoke-AiconBackupRestore {
    param($Record,[string]$Directory,[string]$FinalState='restored')
    $r=$Record;$path=Assert-AiconWritableTarget $r.Path
    if ($r.Kind -notin @('Folder','Shortcut','CreatedShortcut')) { throw 'バックアップ種別が不正です。' }
    $folder=''
    if ($r.Kind -eq 'Folder') {
        $folder=Assert-AiconWritableTarget $r.Folder
        if ($path -ine (Join-Path $folder 'desktop.ini')) { throw 'バックアップ対象が不正です。' }
        $attrs=[int][IO.File]::GetAttributes($folder)
        if ($attrs -ne $r.FolderAttributes -and $attrs -ne $r.AfterFolderAttributes) { throw '適用後にフォルダー属性が変更されています。復元を中止しました。' }
    } elseif ([IO.Path]::GetExtension($path) -ine '.lnk' -or $r.Folder) { throw '復元対象が不正です。' }
    $original=Get-AiconFullPath (Join-Path $Directory 'original')
    if ($r.Existed -and (-not [IO.File]::Exists($original) -or (Get-AiconHash $original) -ne $r.BeforeHash)) { throw 'バックアップの整合性を確認できません。' }
    $current=Get-AiconHash $path
    # A crash can leave the before image, committed image, or our empty reservation.
    $allowed=@($r.AfterHash)
    if ($r.State -ne 'applied') { $allowed+= @($r.BeforeHash,$r.SnapshotHash) }
    if ($current -notin $allowed) { throw '適用後に対象が変更されています。上書きせず中止しました。' }
    if ([IO.File]::Exists($path)) {
        $attrs=[int][IO.File]::GetAttributes($path)
        $before=[int]$r.FileAttributes;$after=[int]$r.AfterFileAttributes
        $withoutReadOnly=$before -band (-bnot [int][IO.FileAttributes]::ReadOnly)
        $afterWithoutReadOnly=$after -band (-bnot [int][IO.FileAttributes]::ReadOnly)
        if ($r.Existed -and $attrs -notin @($before,$after,$withoutReadOnly,$afterWithoutReadOnly)) { throw '対象の属性が変更されています。復元を中止しました。' }
    }
    $r.State='restoring';Write-AiconManifest $Directory $r
    $stage=$null
    try {
        if ($r.Existed -and $current -ne $r.BeforeHash) {
            $stage=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.aicon-restore-'+[Guid]::NewGuid().ToString('N')+'.tmp')
            [IO.File]::Copy($original,$stage,$false);[IO.File]::SetAttributes($stage,[IO.FileAttributes]::Normal)
            if ((Get-AiconHash $path) -ne $current) { throw '復元準備中に対象が変更されました。' }
            if ([IO.File]::Exists($path)) {
                $a=[IO.File]::GetAttributes($path);[IO.File]::SetAttributes($path,($a -band (-bnot [IO.FileAttributes]::ReadOnly)))
                [IO.File]::Replace($stage,$path,[System.Management.Automation.Language.NullString]::Value)
            } else { [IO.File]::Move($stage,$path) }
        } elseif (-not $r.Existed -and [IO.File]::Exists($path)) {
            if ((Get-AiconHash $path) -ne $current) { throw '復元準備中に対象が変更されました。' }
            [IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal);[IO.File]::Delete($path)
        }
        if ($r.Existed) { [IO.File]::SetAttributes($path,[IO.FileAttributes]$r.FileAttributes) }
        if ($folder) { [IO.File]::SetAttributes($folder,[IO.FileAttributes]$r.FolderAttributes) }
        $r.State=$FinalState;Write-AiconManifest $Directory $r
    } finally { if ($stage -and [IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
    return $path
}
function Invoke-AiconRefresh {
    param([string]$Path)
    if (-not ('Aicon.ShellNotify' -as [type])) { Add-Type 'using System; using System.Runtime.InteropServices; namespace Aicon { public static class ShellNotify { [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(uint e, uint f, string a, IntPtr b); } }' }
    [Aicon.ShellNotify]::SHChangeNotify(0x00002000,0x0005,$Path,[IntPtr]::Zero)
}
function Set-AiconFactoryIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Icon,[Parameter(Mandatory)][string]$Target,[string]$Root=$script:DefaultRoot,[ValidateSet('Desktop','SameFolder','Custom')][string]$Destination='Desktop',[string]$OutputDirectory,[string]$ShortcutName)
    $rootPath=Initialize-AiconRoot $Root;$backup=$null;$reserved=$null;$shell=$null;$link=$null;$stage=$null;$mutationStarted=$false;$ownedReservation=$null;$targetLock=$null
    try {
        $ico=Get-AiconFullPath $Icon
        if (-not [IO.File]::Exists($ico) -or [IO.Path]::GetExtension($ico) -ine '.ico') { throw '存在する ICO ファイルを指定してください。' }
        $t=Get-AiconFullPath $Target
        if (-not (Test-Path -LiteralPath $t)) { throw '適用対象が見つかりません。' }
        if ([IO.Directory]::Exists($t)) {
            $t=Assert-AiconWritableTarget $t
            $path=Get-AiconFullPath (Join-Path $t 'desktop.ini');$targetLock=Enter-AiconTargetLock $path;$backup=Save-AiconBackup $rootPath 'Folder' $path $t
            $stage=Join-Path $t ('.aicon-'+[Guid]::NewGuid().ToString('N')+'.tmp')
            $lines=if ([IO.File]::Exists($path)) { @(Get-Content -LiteralPath $path -ErrorAction Stop) } else { @() }
            $new=New-Object 'System.Collections.Generic.List[string]';$inShell=$false;$found=$false
            foreach ($line in $lines) {
                if ($line -match '^\s*\[(.+)\]\s*$') {
                    if ($inShell) { $new.Add('IconResource="'+$ico+'",0') }
                    $inShell=($Matches[1] -ieq '.ShellClassInfo');if ($inShell) { if ($found) { throw 'desktop.ini に重複セクションがあります。安全のため中止しました。' };$found=$true }
                    $new.Add($line)
                } elseif (-not ($inShell -and $line -match '^\s*(IconResource|IconFile|IconIndex)\s*=')) { $new.Add($line) }
            }
            if ($inShell) { $new.Add('IconResource="'+$ico+'",0') }
            if (-not $found) { $new.Add('[.ShellClassInfo]');$new.Add('IconResource="'+$ico+'",0') }
            [IO.File]::WriteAllLines($stage,$new.ToArray(),[Text.Encoding]::Unicode)
            $backup.Record.AfterFileAttributes=($backup.Record.FileAttributes -bor [int][IO.FileAttributes]::Hidden -bor [int][IO.FileAttributes]::System)
            $backup.Record.AfterFolderAttributes=($backup.Record.FolderAttributes -bor [int][IO.FileAttributes]::ReadOnly)
        } else {
            $ext=[IO.Path]::GetExtension($t).ToLowerInvariant()
            if ($ext -notin @('.lnk','.ps1','.bat','.cmd','.exe')) { throw '対応対象は .lnk / .ps1 / .bat / .cmd / .exe / フォルダです。' }
            $shell=New-Object -ComObject WScript.Shell
            if ($ext -eq '.lnk') { $path=Assert-AiconWritableTarget $t;$targetLock=Enter-AiconTargetLock $path;$backup=Save-AiconBackup $rootPath 'Shortcut' $path }
            else {
                $dest= switch ($Destination) { 'Desktop' { [Environment]::GetFolderPath('Desktop') }; 'SameFolder' { [IO.Path]::GetDirectoryName($t) }; 'Custom' { if (-not $OutputDirectory) { throw '保存先フォルダを指定してください。' };$OutputDirectory } }
                $dest=Assert-AiconWritableTarget $dest;if (-not [IO.Directory]::Exists($dest)) { throw '保存先フォルダが見つかりません。' }
                if (-not $ShortcutName) { $ShortcutName=[IO.Path]::GetFileNameWithoutExtension($t) };$ShortcutName=Assert-AiconName $ShortcutName
                $reserved=New-AiconReservedFile $dest $ShortcutName '.lnk';$path=$reserved.Path;$ownedReservation=$path;$reserved.Stream.Dispose();$reserved=$null
                # A newly reserved empty shortcut is owned by this call, not a pre-existing file.
                $targetLock=Enter-AiconTargetLock $path
                $backup=Save-AiconBackup $rootPath 'CreatedShortcut' $path
            }
            $stage=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.aicon-'+[Guid]::NewGuid().ToString('N')+'.lnk')
            if ($ext -eq '.lnk') { [IO.File]::Copy((Join-Path $backup.Directory 'original'),$stage,$false);[IO.File]::SetAttributes($stage,[IO.FileAttributes]::Normal) }
            $link=$shell.CreateShortcut($stage)
            if ($ext -ne '.lnk') {
                $link.WorkingDirectory=[IO.Path]::GetDirectoryName($t)
                if ($ext -eq '.ps1') { $link.TargetPath=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe';$link.Arguments='-NoProfile -File "'+$t+'"' }
                else { $link.TargetPath=$t;$link.Arguments='' }
                $link.Description='あいこんふぁくとりー'
            }
            $link.IconLocation=$ico+',0';$link.Save()
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);$link=$null
            $backup.Record.AfterFileAttributes=if ($backup.Record.Existed) { $backup.Record.FileAttributes } else { [int][IO.File]::GetAttributes($stage) }
        }
        Assert-AiconSnapshot $backup
        $backup.Record.AfterHash=Get-AiconHash $stage
        $backup.Record.State='committing';Write-AiconManifest $backup.Directory $backup.Record
        Assert-AiconSnapshot $backup
        $mutationStarted=$true
        if ([IO.File]::Exists($path)) {
            $a=[IO.File]::GetAttributes($path);[IO.File]::SetAttributes($path,($a -band (-bnot [IO.FileAttributes]::ReadOnly)))
            [IO.File]::Replace($stage,$path,[System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($stage,$path) }
        [IO.File]::SetAttributes($path,[IO.FileAttributes]$backup.Record.AfterFileAttributes)
        if ($backup.Record.Folder) { [IO.File]::SetAttributes($backup.Record.Folder,[IO.FileAttributes]$backup.Record.AfterFolderAttributes) }
        Complete-AiconBackup $backup
        try { Invoke-AiconRefresh $t } catch { Write-Warning '表示の更新が遅れる場合があります。' }
        Write-AiconLog $rootPath 'Apply' '' $ico $t $true
        return [pscustomobject]@{TargetPath=$path;BackupId=$backup.Record.Id}
    } catch {
        $errorRecord=$_
        if ($backup -and $mutationStarted) {
            try { [void](Invoke-AiconBackupRestore $backup.Record $backup.Directory 'rolledBack') }
            catch { Write-Warning ('自動復元を完了できません。復元を再試行できます。Backup ID: '+$backup.Record.Id+' / '+$_.Exception.Message) }
        } elseif ($ownedReservation -and [IO.File]::Exists($ownedReservation)) {
            # Delete only this invocation's unmodified empty reservation.
            if ((Get-AiconFullPath $ownedReservation) -eq $ownedReservation -and (Get-Item -LiteralPath $ownedReservation -ErrorAction Stop).Length -eq 0) { [IO.File]::Delete($ownedReservation) }
        }
        Write-AiconLog $rootPath 'Apply' '' $Icon $Target $false $errorRecord.Exception.Message;throw $errorRecord
    } finally {
        if ($reserved) { $reserved.Stream.Dispose() }
        if ($stage -and [IO.File]::Exists($stage)) { try { [IO.File]::Delete($stage) } catch { Write-Warning ('一時ファイルを削除できません: '+$stage) } }
        if ($link) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        if ($targetLock) { $targetLock.ReleaseMutex();$targetLock.Dispose() }
    }
}
function Restore-AiconFactoryIcon {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$BackupId,[string]$Root=$script:DefaultRoot)
    $rootPath=Initialize-AiconRoot $Root;$path='';$targetLock=$null
    try {
        $dir=Get-AiconFullPath (Join-Path $rootPath ('Backup\'+$BackupId));$manifest=Join-Path $dir 'manifest.json'
        $r=Get-Content -LiteralPath (Get-AiconFullPath $manifest) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($r.Version -ne 2 -or $r.Id -ne $BackupId -or $r.State -notin @('prepared','committing','applied','restoring')) { throw '復元できるバックアップではありません。' }
        $path=Assert-AiconWritableTarget $r.Path
        if (-not $PSCmdlet.ShouldProcess($path,'アイコン適用前へ復元')) { return }
        $targetLock=Enter-AiconTargetLock $path
        $path=Invoke-AiconBackupRestore $r $dir
        try { Invoke-AiconRefresh $path } catch { }
        Write-AiconLog $rootPath 'Restore' '' '' $path $true
        return $path
    } catch { Write-AiconLog $rootPath 'Restore' '' '' $path $false $_.Exception.Message;throw }
    finally { if ($targetLock) { $targetLock.ReleaseMutex();$targetLock.Dispose() } }
}
function Start-AiconFactory {
    [CmdletBinding()]param([string]$Root=$script:DefaultRoot)
    Assert-AiconWindows
    $Root=(Assert-AiconWritableTarget $Root).TrimEnd('\')
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        $exe=Join-Path (Split-Path $PSScriptRoot -Parent) 'IconFactory.exe'
        if (-not [IO.File]::Exists($exe)) { throw 'GUI起動用ファイルがありません。配布フォルダを確認してください。' }
        $arguments=''
        if ($Root -ine (Split-Path $PSScriptRoot -Parent)) { $arguments='--test-root "'+$Root+'"' }
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$exe;$startInfo.Arguments=$arguments;$startInfo.UseShellExecute=$false;$startInfo.CreateNoWindow=$true
        [void][Diagnostics.Process]::Start($startInfo);return
    }
    . (Join-Path $PSScriptRoot 'Gui.ps1')
    Show-AiconFactoryWindow -Root $Root
}
function aicon {
    [CmdletBinding()]param([Parameter(Position=0)][string]$Source,[string]$Name,[string]$Category='Other',[string]$Target,[string]$Root=$script:DefaultRoot,[ValidateSet('Desktop','SameFolder','Custom')][string]$Destination='Desktop',[string]$OutputDirectory,[string]$ShortcutName)
    if ($Source) { New-AiconFactoryIcon @PSBoundParameters } else { Start-AiconFactory -Root $Root }
}
. (Join-Path $PSScriptRoot 'ErrorPresentation.ps1')
. (Join-Path $PSScriptRoot 'Batch.ps1')
Export-ModuleMember -Function @('New-AiconFactoryBatch','New-AiconFactoryIcon','Set-AiconFactoryIcon','Restore-AiconFactoryIcon','Start-AiconFactory','aicon')
