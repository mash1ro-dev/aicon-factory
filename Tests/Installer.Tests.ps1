#requires -Version 5.1
# Windows-only standalone assertions; no Pester or external test dependency.
param([string]$Root = (Join-Path $PSScriptRoot '.work'))
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows-only tests have not been run on this host.' }
$repository = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$Root = [IO.Path]::GetFullPath($Root)
if (-not $Root.StartsWith($repository + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Test Root must remain inside this app folder.' }
$script:passed = 0; $script:skipped = 0
$script:failures = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Label, [scriptblock]$Body) {
    Remove-Module AiconFactory -Force -ErrorAction SilentlyContinue
    try { & $Body; $script:passed++; Write-Host "PASS $Label" }
    catch { $script:failures.Add($Label + ': ' + $_.Exception.Message); Write-Host "FAIL $Label" }
    finally { Remove-Module AiconFactory -Force -ErrorAction SilentlyContinue }
}
function Assert-Result {
    param([Parameter(ValueFromPipeline)]$Actual, $Be, [switch]$BeTrue, [switch]$BeFalse, [switch]$Throw)
    process {
        if ($Throw) { $thrown = $false; try { & $Actual | Out-Null } catch { $thrown = $true }; if (-not $thrown) { throw 'Expected rejection' }; return }
        if ($BeTrue -and -not $Actual) { throw 'Expected true' }
        if ($BeFalse -and $Actual) { throw 'Expected false' }
        if ($PSBoundParameters.ContainsKey('Be') -and $Actual -ne $Be) { throw "Expected [$Be]; got [$Actual]" }
    }
}

    $script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
    $script:InstallerWork = Join-Path $Root ('Installer-' + [guid]::NewGuid().ToString('N'))
    $script:InstallerPath = Join-Path $script:RepositoryRoot 'Install.ps1'
    if ($env:OS -eq 'Windows_NT') { [void][IO.Directory]::CreateDirectory($script:InstallerWork) }

    function New-InstallerFixture {
        param([string]$Build = 'initial', [switch]$FailFinalImport, [switch]$MissingExport)
        $id = [guid]::NewGuid().ToString('N')
        $package = Join-Path $script:InstallerWork ('package-' + $id)
        [void][IO.Directory]::CreateDirectory((Join-Path $package 'App'))
        foreach ($file in @('Install.ps1','Start.ps1','aicon.ps1','README.md','LICENSE','CHANGELOG.md')) {
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $file) -Destination (Join-Path $package $file)
        }
        $module = @"
function New-AiconFactoryIcon { '$Build' }
function Set-AiconFactoryIcon { }
function Restore-AiconFactoryIcon { }
function Start-AiconFactory { }
function aicon { New-AiconFactoryIcon }
Export-ModuleMember -Function New-AiconFactoryIcon,Set-AiconFactoryIcon,Restore-AiconFactoryIcon,Start-AiconFactory,aicon
"@
        if ($MissingExport) { $module = $module.Replace(',Start-AiconFactory,aicon', ',Start-AiconFactory') }
        if ($FailFinalImport) {
            $guard = @'
if ($PSScriptRoot -notmatch '\.aicon-stage-') { throw 'Injected final import failure' }
'@
            $module = $guard + [Environment]::NewLine + $module
        }
        Set-Content -LiteralPath (Join-Path $package 'App\AiconFactory.psm1') -Value $module -Encoding UTF8
        return [pscustomobject]@{ Package = $package; Root = (Join-Path $script:InstallerWork ('installed-' + $id)) }
    }

Check 'creates the intended folder layout and makes aicon available immediately' {
        $fixture = New-InstallerFixture
        . (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root | Out-Null
        foreach ($name in @('App','Library\ICO','Library\Source','Backup','Logs')) {
            Test-Path -LiteralPath (Join-Path $fixture.Root $name) -PathType Container | Assert-Result -BeTrue
        }
        (Get-Command aicon -ErrorAction Stop).CommandType | Assert-Result -Be 'Function'
        (aicon) | Assert-Result -Be 'initial'
        Test-Path -LiteralPath (Join-Path $fixture.Root '.aicon-install.json') | Assert-Result -BeTrue
    }

Check 'allows app-local extraction under _package and leaves its source intact' {
        $fixture = New-InstallerFixture
        $source = Join-Path $fixture.Root '_package\release'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $source))
        [IO.Directory]::Move($fixture.Package, $source)
        $before = (Get-FileHash -LiteralPath (Join-Path $source 'App\AiconFactory.psm1')).Hash
        & (Join-Path $source 'Install.ps1') -Root $fixture.Root | Out-Null
        (aicon) | Assert-Result -Be 'initial'
        (Get-FileHash -LiteralPath (Join-Path $source 'App\AiconFactory.psm1')).Hash | Assert-Result -Be $before
    }

Check 'rejects install targets beneath their source package to prevent recursive copying' {
        $fixture = New-InstallerFixture
        $nested = Join-Path $fixture.Package 'inside-source'
        { & (Join-Path $fixture.Package 'Install.ps1') -Root $nested } | Assert-Result -Throw
        Test-Path -LiteralPath $nested | Assert-Result -BeFalse
    }

Check 'does not remove a pre-existing install lock' {
        $fixture = New-InstallerFixture
        [void][IO.Directory]::CreateDirectory($fixture.Root)
        $lock = Join-Path $fixture.Root '.aicon-install.lock'
        [IO.File]::WriteAllText($lock, 'another-install')
        { & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root } | Assert-Result -Throw
        [IO.File]::ReadAllText($lock) | Assert-Result -Be 'another-install'
    }

Check 'supports future-session import by full path' {
        $fixture = New-InstallerFixture
        & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root | Out-Null
        Remove-Module AiconFactory -Force
        Import-Module -Name (Join-Path $fixture.Root 'App\AiconFactory.psm1') -Force
        (aicon) | Assert-Result -Be 'initial'
    }

Check 'preserves user data byte for byte and backs up managed files during update' {
        $fixture = New-InstallerFixture
        & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root | Out-Null
        $sentinels = @()
        foreach ($name in @('Library\ICO','Library\Source','Backup','Logs')) {
            $sentinel = Join-Path (Join-Path $fixture.Root $name) 'ユーザー データ.keep'
            [IO.File]::WriteAllBytes($sentinel, [byte[]]@(0, 1, 2, 255, 17))
            $sentinels += $sentinel
        }
        $oldHash = (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'App\AiconFactory.psm1')).Hash
        $update = New-InstallerFixture -Build 'updated'
        $result = & (Join-Path $update.Package 'Install.ps1') -Root $fixture.Root
        (aicon) | Assert-Result -Be 'updated'
        foreach ($sentinel in $sentinels) {
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($sentinel))) | Assert-Result -Be 'AAEC/xE='
        }
        (Get-FileHash -LiteralPath (Join-Path $result.BackupPath 'App\AiconFactory.psm1')).Hash | Assert-Result -Be $oldHash
        Test-Path -LiteralPath (Join-Path $result.BackupPath 'recovery.json') | Assert-Result -BeTrue
    }

Check 'does not overwrite an unrelated existing App folder' {
        $fixture = New-InstallerFixture
        [void][IO.Directory]::CreateDirectory((Join-Path $fixture.Root 'App'))
        $sentinel = Join-Path $fixture.Root 'App\keep.txt'
        [IO.File]::WriteAllText($sentinel, 'user-owned')
        { & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root } | Assert-Result -Throw
        [IO.File]::ReadAllText($sentinel) | Assert-Result -Be 'user-owned'
    }

Check 'rejects invalid roots before modifying managed files' {
        $fixture = New-InstallerFixture
        $drive = [IO.Path]::GetPathRoot($fixture.Root)
        foreach ($unsafe in @($drive, $env:WINDIR, $env:USERPROFILE, 'relative\folder', '\\server\share\folder', ($fixture.Root + ':stream'), ($fixture.Root + '.'))) {
            { & (Join-Path $fixture.Package 'Install.ps1') -Root $unsafe } | Assert-Result -Throw
        }
        Test-Path -LiteralPath $fixture.Root | Assert-Result -BeFalse
    }

Check 'rejects a package whose source overlaps the install root' {
        $fixture = New-InstallerFixture
        $before = (Get-FileHash -LiteralPath (Join-Path $fixture.Package 'App\AiconFactory.psm1')).Hash
        { & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Package } | Assert-Result -Throw
        (Get-FileHash -LiteralPath (Join-Path $fixture.Package 'App\AiconFactory.psm1')).Hash | Assert-Result -Be $before
    }

Check 'rejects an existing reparse-point destination' {
        $fixture = New-InstallerFixture
        $destination = Join-Path $script:InstallerWork ('junction-target-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($destination)
        $junction = Join-Path $script:InstallerWork ('junction-' + [guid]::NewGuid().ToString('N'))
        try {
            try { New-Item -Path $junction -ItemType Junction -Target $destination -ErrorAction Stop | Out-Null }
            catch { throw ('Junction creation unavailable; test is unverified: ' + $_.Exception.Message) }
            { & (Join-Path $fixture.Package 'Install.ps1') -Root (Join-Path $junction 'AppRoot') } | Assert-Result -Throw
            @(Get-ChildItem -LiteralPath $destination -Force).Count | Assert-Result -Be 0
        } finally {
            if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
        }
    }

Check 'rejects an invalid staged module without changing the previous installation' {
        $fixture = New-InstallerFixture
        & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root | Out-Null
        $before = (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'App\AiconFactory.psm1')).Hash
        $invalid = New-InstallerFixture -Build 'invalid' -MissingExport
        { & (Join-Path $invalid.Package 'Install.ps1') -Root $fixture.Root } | Assert-Result -Throw
        (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'App\AiconFactory.psm1')).Hash | Assert-Result -Be $before
    }

Check 'rolls back managed files if importing the final installed module fails' {
        $fixture = New-InstallerFixture
        & (Join-Path $fixture.Package 'Install.ps1') -Root $fixture.Root | Out-Null
        $before = (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'App\AiconFactory.psm1')).Hash
        $markerBefore = (Get-FileHash -LiteralPath (Join-Path $fixture.Root '.aicon-install.json')).Hash
        $broken = New-InstallerFixture -Build 'broken' -FailFinalImport
        { & (Join-Path $broken.Package 'Install.ps1') -Root $fixture.Root } | Assert-Result -Throw
        (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'App\AiconFactory.psm1')).Hash | Assert-Result -Be $before
        (Get-FileHash -LiteralPath (Join-Path $fixture.Root '.aicon-install.json')).Hash | Assert-Result -Be $markerBefore
        (aicon) | Assert-Result -Be 'initial'
    }
Remove-Module AiconFactory -Force -ErrorAction SilentlyContinue
Write-Host "$($script:passed) passed; $($script:failures.Count) failed. Fixtures retained at: $script:InstallerWork"
if ($script:failures.Count -gt 0) { throw ($script:failures -join [Environment]::NewLine) }
