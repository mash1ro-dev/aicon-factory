#requires -Version 5.1
<#
.SYNOPSIS
あいこんふぁくとりーをユーザー指定の場所へ安全に配置します。
.DESCRIPTION
Windows PowerShell 5.1 用。管理者権限、PATH / Profile / レジストリ変更は不要です。
このスクリプトをドットソースすると同じウィンドウですぐ aicon を使用できます。
#>
[CmdletBinding()]
param(
    [Parameter()][ValidateNotNullOrEmpty()][string]$Root = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\AiconFactory'),
    [Parameter()][switch]$Launch
)

# Keep validation helpers and strict mode out of the caller's dot-sourced scope.
& {
    param([string]$RequestedRoot, [string]$PackageRoot, [bool]$LaunchRequested)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $productId = 'BLUEFATHOM.AiconFactory'
    $version = '0.1.1'
    $transactionId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 10)

    function Assert-PlainPath([string]$Path) {
        # Inspect every existing ancestor. Junctions/symlinks can otherwise escape Root.
        $cursor = [IO.Path]::GetFullPath($Path)
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "再解析ポイント（リンク / ジャンクション）は使用できません: $cursor"
                }
            }
            $parent = [IO.Directory]::GetParent($cursor)
            if ($null -eq $parent) { break }
            $cursor = $parent.FullName
        }
    }

    function Assert-PlainTree([string]$Path) {
        Assert-PlainPath $Path
        # Never use -Recurse until each directory is known not to be a reparse point.
        $pending = New-Object 'System.Collections.Generic.Queue[string]'
        $pending.Enqueue($Path)
        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            foreach ($child in @(Get-ChildItem -LiteralPath $current -Force)) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "配布ファイルにリンク / ジャンクションを含めることはできません: $($child.FullName)"
                }
                if ($child.PSIsContainer) { $pending.Enqueue($child.FullName) }
            }
        }
    }

    function Get-SafeRoot([string]$Value) {
        if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Windows 11 x64 / 64-bit Windows PowerShell 5.1 で実行してください。' }
        if ($Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.Substring(2).Contains(':')) {
            throw 'Root はローカルドライブの絶対パスで指定してください。'
        }
        foreach ($segment in ($Value.Substring(3) -split '[\\/]')) {
            if ($segment -eq '..' -or $segment -eq '.' -or $segment -match '[. ]$' -or $segment -match '[<>"|?*]') {
                throw 'Root に相対要素、末尾の空白 / ピリオド、無効な文字は使用できません。'
            }
        }
        $full = [IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
        $drive = [IO.Path]::GetPathRoot($full)
        if ($full -eq $drive.TrimEnd('\', '/')) { throw 'ドライブ直下にはインストールできません。専用フォルダーを指定してください。' }
        if (-not (Test-Path -LiteralPath $drive -PathType Container)) { throw "指定したドライブが見つかりません: $drive" }
        $blocked = @($env:WINDIR, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
        foreach ($protected in $blocked) {
            if ([string]::IsNullOrWhiteSpace($protected)) { continue }
            $protectedFull = [IO.Path]::GetFullPath($protected).TrimEnd('\', '/')
            if ($full.Equals($protectedFull, [StringComparison]::OrdinalIgnoreCase) -or
                $full.StartsWith($protectedFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $protectedFull.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "システムの管理フォルダーにはインストールできません: $full"
            }
        }
        if ($env:USERPROFILE -and $full.Equals($env:USERPROFILE.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'ユーザーフォルダーそのものは指定できません。専用の子フォルダーを指定してください。'
        }
        Assert-PlainPath $full
        if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Container)) {
            throw "Root はフォルダーではありません: $full"
        }
        return $full
    }

    function Move-Exact([string]$From, [string]$To) {
        Assert-PlainPath $From
        Assert-PlainPath ([IO.Path]::GetDirectoryName($To))
        if (Test-Path -LiteralPath $To) { throw "移動先がすでに存在します: $To" }
        if (Test-Path -LiteralPath $From -PathType Container) { [IO.Directory]::Move($From, $To) }
        else { [IO.File]::Move($From, $To) }
    }

    function Add-PlannedPath($Plan, [string]$Path, [bool]$Directory, [string]$Role) {
        # UTF-16 code units, including the drive and separators; no long-path opt-in.
        $limit = if ($Directory) { 248 } else { 260 }
        if ($Path.Length -ge $limit) {
            throw "更新に必要なパスが長すぎます（$Role、$($Path.Length)文字）。階層が浅く名前の短いローカルフォルダーを選んでください。既存ファイルは変更していません。"
        }
        $full = [IO.Path]::GetFullPath($Path)
        $parent = [IO.Path]::GetDirectoryName($full)
        if ($parent -and $parent.Length -ge 248) { throw '更新に必要な親フォルダーのパスが長すぎます。短い配置先を選んでください。既存ファイルは変更していません。' }
        if ($Plan.ContainsKey($full)) {
            if ($Plan[$full].Directory -ne $Directory) { throw "更新パスの種類が衝突しています: $full" }
        } else { $Plan.Add($full, [pscustomobject]@{Path=$full;Directory=$Directory;Role=$Role}) }
    }

    function Get-PlainEntries([string]$Path) {
        $pending = New-Object 'System.Collections.Generic.Queue[string]'
        $pending.Enqueue($Path)
        while ($pending.Count) {
            $p = $pending.Dequeue()
            Assert-PlainPath $p
            $item = Get-Item -LiteralPath $p -Force
            [pscustomobject]@{Path=$item.FullName;Directory=$item.PSIsContainer}
            if ($item.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $p -Force)) { $pending.Enqueue($child.FullName) }
            }
        }
    }

    function Initialize-AccessProbe {
        if ('AiconInstallPreflightV011' -as [type]) { return }
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AiconInstallPreflightV011 {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    static SafeFileHandle Open(string path, uint access, uint share, bool directory) {
        SafeFileHandle h=CreateFileW(path,access,share,IntPtr.Zero,3,directory?0x02000000u:0u,IntPtr.Zero);
        if(h.IsInvalid) { int error=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(error,"更新前のアクセス確認に失敗しました: "+path); }
        return h;
    }
    public static SafeFileHandle FileLease(string path, bool existingTarget) {
        // Validate DELETE capability, then deny writers until the final snapshot check.
        // Windows requires leases on descendants to close before moving their directory.
        if(existingTarget) { using(SafeFileHandle h=Open(path,0x80010000u,7,false)) {} }
        return Open(path,0x80000000u,5,false);
    }
    public static void DirectoryAccess(string path, bool writable) {
        // LIST/TRAVERSE/READ_ATTRIBUTES; additionally ADD_FILE/ADD_SUBDIR/DELETE_CHILD.
        using(SafeFileHandle h=Open(path,writable?0xE7u:0xA1u,7,true)) {}
    }
    public static SafeFileHandle DirectoryLease(string path) {
        // Pin existing destination ancestors against replacement; do not pin movable App/docs trees.
        return Open(path,0x81u,3,true);
    }
    public static void DirectoryMoveAccess(string path) {
        using(SafeFileHandle h=Open(path,0x10080u,7,true)) {}
    }
}
'@ -ErrorAction Stop
    }

    function Test-OwnedWorkDirectory([string]$Directory) {
        # Only newly created transaction directories; all names are in the preflight plan.
        $first = Join-Path $Directory '.probe'
        $moved = Join-Path $Directory '.probe-moved'
        $stream = [IO.File]::Open($first, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.WriteByte(65); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($first, $moved)
        [IO.File]::Delete($moved)
    }

    $preflightHandles = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $oldFileHandles = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    try {
    try {
    $installRoot = Get-SafeRoot $RequestedRoot
    $package = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
    $packageArea = Join-Path $installRoot '_package'
    if ($package.Equals($installRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $installRoot.StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '展開元そのもの、または展開元の子フォルダーにはインストールできません。Root\_package 配下へ ZIP を展開してください。'
    }
    if ($package.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not $package.StartsWith($packageArea + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'インストール先の内側から実行する場合、展開元は Root\_package の子フォルダーに置いてください。'
    }
    $required = @('App', 'Install.ps1', 'Start.ps1', 'aicon.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md')
    foreach ($name in $required) {
        $source = Join-Path $package $name
        if (-not (Test-Path -LiteralPath $source)) { throw "配布ファイルが不足しています: $name" }
        Assert-PlainTree $source
    }
    if (-not (Test-Path -LiteralPath (Join-Path $package 'App\AiconFactory.psm1') -PathType Leaf)) {
        throw 'App\AiconFactory.psm1 がありません。ZIP 全体を展開してください。'
    }
    $managed = @($required)
    foreach ($name in @('IconFactory.exe', 'docs', 'Tests', 'tools', 'THIRD_PARTY_NOTICES.md', 'SECURITY.md', 'SHA256SUMS.json', 'VERSION', 'settings.example.json')) {
        if (Test-Path -LiteralPath (Join-Path $package $name)) {
            Assert-PlainTree (Join-Path $package $name)
            $managed += $name
        }
    }
    $managed += '.aicon-install.json'

    # Plan both new payload and every existing managed descendant, including paths used only on rollback.
    $stage = Join-Path $installRoot ('.aicon-stage-' + $transactionId)
    $backup = Join-Path $installRoot ('Backup\Install-' + $transactionId)
    $failedNew = Join-Path $stage 'failed-new'
    $lockPath = Join-Path $installRoot '.aicon-install.lock'
    $recoveryPath = Join-Path $backup 'recovery.json'
    $installLogPath = Join-Path $installRoot ('Logs\install-' + $transactionId + '.json')
    $plan = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in @($installRoot,$stage,$backup,$failedNew,(Join-Path $installRoot 'Backup'),(Join-Path $installRoot 'Logs'))) { Add-PlannedPath $plan $dir $true '作業フォルダー' }
    foreach ($file in @($lockPath,$recoveryPath,$installLogPath)) { Add-PlannedPath $plan $file $false 'ロック・復旧記録・ログ' }
    foreach ($dir in @($stage,$backup,$failedNew)) {
        Add-PlannedPath $plan (Join-Path $dir '.probe') $false '事前書込確認'
        Add-PlannedPath $plan (Join-Path $dir '.probe-moved') $false '事前移動確認'
    }
    foreach ($name in @('Library\ICO','Library\Source','Backup','Logs')) { Add-PlannedPath $plan (Join-Path $installRoot $name) $true 'データフォルダー' }
    $newEntries = @()
    $oldEntries = @()
    foreach ($name in $managed) {
        if ($name -ne '.aicon-install.json') {
            foreach ($entry in @(Get-PlainEntries (Join-Path $package $name))) {
                $relative = $entry.Path.Substring($package.Length + 1)
                $newEntries += $entry
                Add-PlannedPath $plan $entry.Path $entry.Directory '配布元'
                foreach ($base in @($installRoot,$stage,$failedNew)) { Add-PlannedPath $plan (Join-Path $base $relative) $entry.Directory '新規ファイル・失敗時退避先' }
            }
        } else {
            foreach ($base in @($installRoot,$stage,$failedNew)) { Add-PlannedPath $plan (Join-Path $base $name) $false '管理情報' }
        }
        $old = Join-Path $installRoot $name
        if (Test-Path -LiteralPath $old) {
            foreach ($entry in @(Get-PlainEntries $old)) {
                $oldEntries += $entry
                $relative = $entry.Path.Substring($installRoot.Length + 1)
                Add-PlannedPath $plan $entry.Path $entry.Directory '既存ファイル・復元先'
                Add-PlannedPath $plan (Join-Path $backup $relative) $entry.Directory '旧ファイルのバックアップ'
            }
        }
    }
    foreach ($path in @($stage,$backup,$failedNew,$installLogPath)) {
        if (Test-Path -LiteralPath $path) { throw "作業先が既に存在するため更新を開始しません: $path" }
    }
    Initialize-AccessProbe
    $checkedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $plan.Values) {
        Assert-PlainPath $entry.Path
        if (Test-Path -LiteralPath $entry.Path) {
            $actual = Get-Item -LiteralPath $entry.Path -Force
            if ($actual.PSIsContainer -ne $entry.Directory) { throw "更新パスの種類が一致しません: $($entry.Path)" }
        }
        $parent = if ($entry.Directory) { $entry.Path } else { [IO.Path]::GetDirectoryName($entry.Path) }
        while (-not (Test-Path -LiteralPath $parent)) { $parent = [IO.Path]::GetDirectoryName($parent) }
        if ($checkedDirectories.Add($parent)) {
            # Existing managed descendants are moved as trees; don't require write access inside them.
            $writeParent = $parent -ieq $installRoot -or $parent -ieq (Join-Path $installRoot 'Backup') -or $parent -ieq (Join-Path $installRoot 'Logs') -or -not (Test-Path -LiteralPath $installRoot)
            [AiconInstallPreflightV011]::DirectoryAccess($parent,$writeParent)
        }
    }
    foreach ($entry in $newEntries | Where-Object { -not $_.Directory }) { $preflightHandles.Add([AiconInstallPreflightV011]::FileLease($entry.Path,$false)) }
    foreach ($name in $managed) {
        $old = Join-Path $installRoot $name
        if (Test-Path -LiteralPath $old -PathType Container) { [AiconInstallPreflightV011]::DirectoryMoveAccess($old) }
    }
    $oldSnapshots = @()
    foreach ($entry in $oldEntries | Where-Object { -not $_.Directory }) {
        $oldFileHandles.Add([AiconInstallPreflightV011]::FileLease($entry.Path,$true))
        $oldSnapshots += [pscustomobject]@{Path=$entry.Path;Hash=(Get-FileHash -LiteralPath $entry.Path).Hash}
    }
    foreach ($base in @($installRoot,(Join-Path $installRoot 'Backup'),(Join-Path $installRoot 'Logs'))) {
        $cursor = $base
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor -PathType Container) { $preflightHandles.Add([AiconInstallPreflightV011]::DirectoryLease($cursor)) }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    }
    } catch {
        throw "更新を開始できません。配置先を短いローカルフォルダーにし、アプリを閉じて権限と空き容量を確認してください。既存ファイルは変更していません。`n事前確認: $($_.Exception.Message)"
    }

    [void][IO.Directory]::CreateDirectory($installRoot)
    $lockPath = Join-Path $installRoot '.aicon-install.lock'
    Assert-PlainPath $lockPath
    try { $installLock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
    catch { throw '別のインストールが実行中か、前回のロックが残っています。docs/RECOVERY.md を確認してください。' }
    try {
    $markerPath = Join-Path $installRoot '.aicon-install.json'
    $isUpdate = $false
    if (Test-Path -LiteralPath $markerPath) {
        Assert-PlainPath $markerPath
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($marker.ProductId -ne $productId) { throw '既存の管理情報が一致しません。別の専用フォルダーを指定してください。' }
        $isUpdate = $true
    }
    foreach ($name in $managed) {
        $target = Join-Path $installRoot $name
        Assert-PlainPath $target
        if ((Test-Path -LiteralPath $target) -and -not $isUpdate) {
            throw "既存ファイルを上書きしません: $target`n新しい専用フォルダーを指定してください。"
        }
    }
    # These folders contain user-owned data. Only create missing folders; never copy
    # release contents into them or overwrite any existing file within them.
    foreach ($name in @('Library\ICO', 'Library\Source', 'Backup', 'Logs')) {
        $dataPath = Join-Path $installRoot $name
        Assert-PlainPath $dataPath
        if ((Test-Path -LiteralPath $dataPath) -and -not (Test-Path -LiteralPath $dataPath -PathType Container)) {
            throw "データ用フォルダーと同名のファイルがあります: $dataPath"
        }
    }

    [void][IO.Directory]::CreateDirectory($installRoot)
    # A same-volume staging folder lets each managed path be renamed, not overwritten.
    [void][IO.Directory]::CreateDirectory($stage)
    $oldMoved = New-Object 'System.Collections.Generic.List[string]'
    $newMoved = New-Object 'System.Collections.Generic.List[string]'
    $modulePath = Join-Path $installRoot 'App\AiconFactory.psm1'
    $importedModule = $null
    $phase = 'stage'
    try {
        foreach ($name in $managed) {
            if ($name -eq '.aicon-install.json') { continue }
            Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $stage $name) -Recurse -Force
        }
        [ordered]@{ ProductId = $productId; Version = $version; InstalledAtUtc = [DateTime]::UtcNow.ToString('o'); Root = $installRoot } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage '.aicon-install.json') -Encoding UTF8
        $stagedModule = Join-Path $stage 'App\AiconFactory.psm1'
        $probe = Import-Module -Name $stagedModule -Force -PassThru -Scope Local -ErrorAction Stop
        try {
            foreach ($command in @('aicon', 'New-AiconFactoryIcon', 'Set-AiconFactoryIcon', 'Restore-AiconFactoryIcon', 'Start-AiconFactory')) {
                if (-not $probe.ExportedCommands.ContainsKey($command)) { throw "モジュールの公開コマンドが不足しています: $command" }
            }
        } finally { Remove-Module -ModuleInfo $probe -Force -ErrorAction SilentlyContinue }
        foreach ($name in @('Library\ICO', 'Library\Source', 'Backup', 'Logs')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $installRoot $name))
        }
        [void][IO.Directory]::CreateDirectory($backup)
        [void][IO.Directory]::CreateDirectory($failedNew)
        foreach ($directory in @($stage,$backup,$failedNew)) { Test-OwnedWorkDirectory $directory }
        # Prepare rollback destination and recovery map before moving the first old file.
        [ordered]@{ProductId=$productId;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Root=$installRoot;Stage=$stage;Status='Prepared';Files=@($managed|Where-Object {Test-Path -LiteralPath (Join-Path $installRoot $_)})} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recoveryPath -Encoding UTF8
        foreach ($snapshot in $oldSnapshots) {
            if ((Get-FileHash -LiteralPath $snapshot.Path).Hash -ne $snapshot.Hash) { throw '事前確認後に既存ファイルが変更されたため、入れ替えを中止しました。' }
        }
        $currentOldPaths = @(foreach($name in $managed){$path=Join-Path $installRoot $name;if(Test-Path -LiteralPath $path){Get-PlainEntries $path|ForEach-Object Path}})
        if (@($oldEntries).Count -ne $currentOldPaths.Count -or @($oldEntries|Where-Object {$_.Path -notin $currentOldPaths}).Count) { throw '事前確認後に既存ファイルの構成が変わったため、入れ替えを中止しました。' }
        foreach ($handle in $oldFileHandles) { $handle.Dispose() }
        $oldFileHandles.Clear()
        $phase = 'commit'
        foreach ($name in $managed) {
            $target = Join-Path $installRoot $name
            Assert-PlainPath $target
            if (Test-Path -LiteralPath $target) {
                Move-Exact $target (Join-Path $backup $name)
                $oldMoved.Add($name)
            }
            Move-Exact (Join-Path $stage $name) $target
            $newMoved.Add($name)
        }
        # Keep installed commands available immediately in this PowerShell session.
        $importedModule = Import-Module -Name $modulePath -Force -PassThru -Global -ErrorAction Stop
        $phase = 'complete'
    } catch {
        $originalError = $_
        $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $importedModule) { Remove-Module -ModuleInfo $importedModule -Force -ErrorAction SilentlyContinue }
        if ($phase -eq 'commit') {
            # Already created and exercised before commit. A failure for one path must not skip other restores.
            for ($i = $newMoved.Count - 1; $i -ge 0; $i--) {
                $name = $newMoved[$i]
                try { Move-Exact (Join-Path $installRoot $name) (Join-Path $failedNew $name) }
                catch { $rollbackErrors.Add($_.Exception.Message) }
            }
            for ($i = $oldMoved.Count - 1; $i -ge 0; $i--) {
                $name = $oldMoved[$i]
                try { Move-Exact (Join-Path $backup $name) (Join-Path $installRoot $name) }
                catch { $rollbackErrors.Add($_.Exception.Message) }
            }
        }
        if ($isUpdate -and $rollbackErrors.Count -eq 0 -and (Test-Path -LiteralPath $modulePath)) {
            try { Import-Module -Name $modulePath -Force -Global -ErrorAction Stop }
            catch { Write-Warning "元のファイルは復元しましたが再読込できません: $($_.Exception.Message)" }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "インストールに失敗し、自動復元にも問題があります。App を起動せず Backup を保全してください。`n退避先: $backup`n作業場所: $stage`n$($rollbackErrors -join [Environment]::NewLine)`n元のエラー: $($originalError.Exception.Message)"
        }
        # Preserve staging artifacts for diagnosis; never delete user data on failure.
        throw "インストールを完了できませんでした。既存の管理ファイルは変更されていないか復元済みです。`n作業場所: $stage`n$($originalError.Exception.Message)"
    }

    # Ancillary cleanup/logging must not undo a successfully committed installation.
    try {
        if ($oldMoved.Count -gt 0) {
            [ordered]@{ ProductId = $productId; CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); Root = $installRoot; Files = @($oldMoved.ToArray()) } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'recovery.json') -Encoding UTF8
        }
        # The prepared recovery record is retained even for a first installation.
        Remove-Item -LiteralPath $failedNew -Force
        Remove-Item -LiteralPath $stage -Force
        [ordered]@{ TimeUtc = [DateTime]::UtcNow.ToString('o'); Operation = 'Install'; Version = $version; Root = $installRoot; Updated = $isUpdate; Backup = $(if ($oldMoved.Count -gt 0) { $backup } else { $null }) } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $installRoot ('Logs\install-' + $transactionId + '.json')) -Encoding UTF8
    } catch { Write-Warning "インストールは完了しましたが、後片付け / ログ保存に失敗しました: $($_.Exception.Message)" }
    Write-Host "あいこんふぁくとりー $version を配置しました: $installRoot"
    Write-Host '通常の起動は IconFactory.exe をダブルクリックしてください。開発者はこの PowerShell で aicon を使用できます。'
    if ($oldMoved.Count -gt 0) { Write-Host "更新前のファイル: $backup" }
    if ($LaunchRequested) { Start-AiconFactory -Root $installRoot }
    [pscustomobject]@{ Root = $installRoot; Version = $version; ModulePath = $modulePath; BackupPath = $(if ($oldMoved.Count -gt 0) { $backup } else { $null }) }
    } finally {
        $installLock.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    } finally {
        foreach ($handle in $oldFileHandles) { $handle.Dispose() }
        foreach ($handle in $preflightHandles) { $handle.Dispose() }
    }
} $Root $PSScriptRoot ([bool]$Launch)
