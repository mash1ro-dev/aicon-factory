param([string]$AppRoot,[string]$Root,[string]$ResultDirectory)
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
$Root=Assert-OwnedTestRoot $AppRoot $Root $ResultDirectory
function Safety-Reject([scriptblock]$Action){$caught=$false;try{&$Action|Out-Null}catch{$caught=$true};if(-not $caught){throw 'Expected safety rejection'}}
Describe 'Sandbox ownership and cleanup guards' {
    It 'rejects traversal, relative, UNC and ADS paths' {foreach($p in @('relative','\\server\share','C:\x\..\y','C:\x:stream')){Safety-Reject {Assert-TestLocalPath $p}}}
    It 'rejects Results directory outside the app test results base' {Safety-Reject {Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $Root -WhatIf};Safety-Reject {Assert-OwnedTestRoot $AppRoot $AppRoot}}
    It 'rejects missing ownership marker without deleting a sentinel' {
        $script:Child=New-OwnedTestRun $AppRoot
        $sentinel=Join-Path $script:Child.Root 'keep.txt';[IO.File]::WriteAllText($sentinel,'owned fixture')
        [IO.File]::WriteAllText((Join-Path $script:Child.Results 'results.json'),'{}')
        Save-TestInventory $script:Child
        $marker=Join-Path $script:Child.Root '.aicon-test-owner.json';$original=[IO.File]::ReadAllBytes($marker)
        # Rename only this test's marker; preserve its original bytes for recovery.
        Move-Item -LiteralPath $marker -Destination ($marker+'.held')
        try{Safety-Reject {Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $script:Child.Results -WhatIf};if(-not(Test-Path -LiteralPath $sentinel)){throw 'Sentinel deleted'}}finally{Move-Item -LiteralPath ($marker+'.held') -Destination $marker}
    }
    It 'rejects additional files absent from saved inventory' {
        $extra=Join-Path $script:Child.Root 'additional.txt';[IO.File]::WriteAllText($extra,'owned new fixture')
        Safety-Reject {Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $script:Child.Results -WhatIf}
        if(-not(Test-Path -LiteralPath $extra)){throw 'Unexpected deletion'}
        Save-TestInventory $script:Child
    }
    It 'rejects bytes changed after inventory was saved' {
        $sentinel=Join-Path $script:Child.Root 'keep.txt';[IO.File]::AppendAllText($sentinel,'changed by this test')
        Safety-Reject {Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $script:Child.Results -WhatIf}
        if(-not(Test-Path -LiteralPath $sentinel)){throw 'Unexpected deletion'}
        Save-TestInventory $script:Child
    }
    It 'rejects a junction before traversal or cleanup' {
        $target=Join-Path $script:Child.Root 'junction-target';[void][IO.Directory]::CreateDirectory($target)
        $link=Join-Path $script:Child.Root 'junction-link'
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop|Out-Null
        try{Safety-Reject {Assert-TestLocalPath $link};Safety-Reject {Get-TestTree $script:Child.Root};Safety-Reject {Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $script:Child.Results -WhatIf}}
        finally{
            # Delete the newly created junction object only, with no recursion or target deletion.
            [IO.Directory]::Delete($link,$false)
        }
        Save-TestInventory $script:Child
    }
    It 'removes only its own current run after validation and retains evidence' {
        Remove-OwnedTestRun -AppRoot $AppRoot -ResultDirectory $script:Child.Results -Confirm:$false
        if(Test-Path -LiteralPath $script:Child.Root){throw 'Owned run cleanup failed'}
        if(-not(Test-Path -LiteralPath (Join-Path $script:Child.Results 'ownership.json'))){throw 'Results deleted'}
    }
}
