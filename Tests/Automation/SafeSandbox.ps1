#requires -Version 5.1
Set-StrictMode -Version 2.0
function Assert-TestLocalPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')){throw 'Absolute local path required; UNC/ADS rejected'}
    if(@($Path.Substring(3).Split('\')|Where-Object {$_ -in @('.','..') -or $_ -match '[. ]$'}).Count){throw 'Ambiguous path rejected'}
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){if(([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse point rejected'}}
        $parent=[IO.Directory]::GetParent($cursor);if($null -eq $parent){break};$cursor=$parent.FullName
    }
    return $full
}
function New-OwnedTestRun([string]$AppRoot) {
    $app=Assert-TestLocalPath $AppRoot
    $base=Assert-TestLocalPath (Join-Path $app 'Tests\Sandbox')
    $results=Assert-TestLocalPath (Join-Path $app 'Tests\Results')
    [void][IO.Directory]::CreateDirectory($base);[void][IO.Directory]::CreateDirectory($results)
    $id=[guid]::NewGuid().ToString('N');$name='Run-'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+$id
    $root=Join-Path $base $name;$out=Join-Path $results $name
    if((Test-Path -LiteralPath $root) -or (Test-Path -LiteralPath $out)){throw 'Unique run collision; preserve existing paths'}
    New-Item -ItemType Directory -Path $root -ErrorAction Stop|Out-Null
    New-Item -ItemType Directory -Path $out -ErrorAction Stop|Out-Null
    $marker=[ordered]@{Schema=1;Purpose='AiconFactory.Automation';RunId=$id;Root=$root;Results=$out;CreatedUtc=[DateTime]::UtcNow.ToString('o')}
    $marker|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root '.aicon-test-owner.json') -Encoding UTF8
    $marker|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $out 'ownership.json') -Encoding UTF8
    return [pscustomobject]$marker
}
function Assert-OwnedTestRoot([string]$AppRoot,[string]$Root,[string]$ResultDirectory='') {
    $app=Assert-TestLocalPath $AppRoot;$rootPath=Assert-TestLocalPath $Root
    $base=Join-Path $app 'Tests\Sandbox'
    if([IO.Directory]::GetParent($rootPath).FullName -ine $base -or [IO.Path]::GetFileName($rootPath) -notmatch '^Run-\d{8}-\d{6}-[a-f0-9]{32}$'){throw 'Test Root must be one owned run directly under Tests/Sandbox'}
    $marker=Get-Content -LiteralPath (Join-Path $rootPath '.aicon-test-owner.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($marker.Schema -ne 1 -or $marker.Purpose -ne 'AiconFactory.Automation' -or $marker.Root -ine $rootPath -or -not $rootPath.EndsWith($marker.RunId)){throw 'Invalid owned test Root'}
    if($ResultDirectory -and (Assert-TestLocalPath $ResultDirectory) -ine $marker.Results){throw 'Result directory does not belong to this run'}
    return $rootPath
}
function Get-TestTree([string]$Root) {
    $q=New-Object 'System.Collections.Generic.Queue[string]';$q.Enqueue($Root)
    $entries=New-Object 'System.Collections.Generic.List[object]'
    while($q.Count){
        $dir=$q.Dequeue()
        foreach($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)){
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reparse point in Sandbox; no traversal or deletion'}
            $entries.Add($item)
            if($item.PSIsContainer){$q.Enqueue($item.FullName)}
        }
    }
    return $entries.ToArray()
}
function Save-TestInventory($Run) {
    $entries=@(Get-TestTree $Run.Root | ForEach-Object {
        [pscustomobject]@{Relative=$_.FullName.Substring($Run.Root.Length+1);Directory=$_.PSIsContainer;SHA256=$(if(-not $_.PSIsContainer){(Get-FileHash -LiteralPath $_.FullName).Hash}else{''})}
    })
    $entries|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $Run.Results 'sandbox-inventory.json') -Encoding UTF8
}
function Save-TestApplicationArtifacts([string]$AppRoot,$Run) {
    $root=Assert-OwnedTestRoot $AppRoot $Run.Root $Run.Results
    foreach($item in @(Get-TestTree $root|Where-Object {-not $_.PSIsContainer -and ($_.Extension -eq '.jsonl' -or $_.Name -eq 'manifest.json')})){
        $relative=$item.FullName.Substring($root.Length+1)
        $dest=Assert-TestLocalPath (Join-Path $Run.Results ('Artifacts\'+$relative))
        if(-not $dest.StartsWith($Run.Results+'\Artifacts\',[StringComparison]::OrdinalIgnoreCase)){throw 'Artifact destination escaped Results'}
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
        [IO.File]::Copy($item.FullName,$dest,$false)
    }
}
function Remove-OwnedTestRun {
    [CmdletBinding(SupportsShouldProcess=$true)]param([string]$AppRoot,[string]$ResultDirectory)
    $app=Assert-TestLocalPath $AppRoot
    $result=Assert-TestLocalPath $ResultDirectory
    $resultBase=Join-Path $app 'Tests\Results'
    if(-not $result.StartsWith($resultBase+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Results path outside approved base'}
    $ownership=Join-Path $result 'ownership.json'
    if(-not(Test-Path -LiteralPath $ownership -PathType Leaf)){throw 'Ownership record missing'}
    $run=Get-Content -LiteralPath $ownership -Raw|ConvertFrom-Json
    $root=Assert-TestLocalPath $run.Root
    $base=Join-Path $app 'Tests\Sandbox'
    if($run.Purpose -ne 'AiconFactory.Automation' -or $run.Schema -ne 1 -or $run.RunId -notmatch '^[a-f0-9]{32}$' -or
       $root -notlike ($base+'\Run-*') -or [IO.Directory]::GetParent($root).FullName -ine $base -or
       [IO.Path]::GetFileName($root) -notmatch ('^Run-\d{8}-\d{6}-'+$run.RunId+'$') -or $run.Results -ine $result){throw 'Ownership/scope mismatch'}
    $markerPath=Join-Path $root '.aicon-test-owner.json'
    if(-not(Test-Path -LiteralPath $markerPath -PathType Leaf)){throw 'Sandbox ownership marker missing'}
    $marker=Get-Content -LiteralPath $markerPath -Raw|ConvertFrom-Json
    if($marker.RunId -ne $run.RunId -or $marker.Root -ine $root -or $marker.Purpose -ne $run.Purpose){throw 'Sandbox ownership marker mismatch'}
    if(-not(Test-Path -LiteralPath (Join-Path $result 'results.json'))){throw 'Save results before cleanup'}
    $inventory=Get-Content -LiteralPath (Join-Path $result 'sandbox-inventory.json') -Raw|ConvertFrom-Json
    $inventory=@($inventory)
    $current=@(Get-TestTree $root)
    if($current.Count -ne $inventory.Count){throw 'Sandbox inventory changed; nothing deleted'}
    foreach($item in $current){
        $relative=$item.FullName.Substring($root.Length+1)
        $expected=@($inventory|Where-Object {$_.Relative -ceq $relative})
        if($expected.Count -ne 1 -or [bool]$expected[0].Directory -ne $item.PSIsContainer){throw 'Unexpected entry; nothing deleted'}
        if(-not $item.PSIsContainer -and (Get-FileHash -LiteralPath $item.FullName).Hash -ne $expected[0].SHA256){throw 'Sandbox bytes changed; nothing deleted'}
    }
    if($PSCmdlet.ShouldProcess($root,'Remove this owned run only; keep results')){
        # No recursive deletion: validated entries, deepest first, in this PowerShell session.
        foreach($item in @($current|Sort-Object {$_.FullName.Length} -Descending)){Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop}
        Remove-Item -LiteralPath $root -Force -ErrorAction Stop
    }
}
