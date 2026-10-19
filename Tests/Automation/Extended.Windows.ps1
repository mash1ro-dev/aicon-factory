param([string]$AppRoot,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
$Root=Assert-OwnedTestRoot $AppRoot $Root
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$work=Join-Path $Root ('Extended-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
Import-Module (Join-Path $AppRoot 'App\AiconFactory.psm1') -Force
Add-Type -AssemblyName System.Drawing
$source=Join-Path $work 'dummy source.png'
$b=New-Object Drawing.Bitmap 120,80
$g=[Drawing.Graphics]::FromImage($b)
try {$g.Clear([Drawing.Color]::Transparent);$g.FillRectangle([Drawing.Brushes]::Orange,20,15,70,50);$b.Save($source,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
$sourceHash=(Get-FileHash -LiteralPath $source).Hash
$icon=New-AiconFactoryIcon -Source $source -Name Extended -Root $work
$passed=0;$failures=New-Object 'System.Collections.Generic.List[string]'
foreach($ext in @('bat','cmd','exe')){
    try{
        $target=Join-Path $work ('dummy.'+$ext)
        [IO.File]::WriteAllText($target,'dummy test bytes; never execute')
        $hash=(Get-FileHash -LiteralPath $target).Hash
        $r=Set-AiconFactoryIcon -Icon $icon.IconPath -Target $target -Destination Custom -OutputDirectory $work -Root $work
        $s=New-Object -ComObject WScript.Shell;$link=$s.CreateShortcut($r.TargetPath)
        try{if($link.TargetPath -ne $target -or $link.IconLocation -notlike '*Extended.ico*'){throw 'Incorrect shortcut properties'}}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($s)}
        Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $work -Confirm:$false | Out-Null
        if([IO.File]::Exists($r.TargetPath) -or (Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Original preservation/restore failed'}
        $passed++;Write-Host "PASS $ext shortcut apply/properties/restore (target not executed)"
    }catch{$failures.Add($_.Exception.Message);Write-Host "FAIL $ext : $_"}
}
try{
    $target=Join-Path $work 'existing.lnk';$s=New-Object -ComObject WScript.Shell;$link=$s.CreateShortcut($target)
    try{$link.TargetPath=Join-Path $work 'dummy.exe';$link.Arguments='--sentinel';$link.Description='preserve';$link.Save()}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($s)}
    $hash=(Get-FileHash -LiteralPath $target).Hash
    $r=Set-AiconFactoryIcon -Icon $icon.IconPath -Target $target -Root $work
    Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $work -Confirm:$false | Out-Null
    if((Get-FileHash -LiteralPath $target).Hash -ne $hash){throw 'Existing link bytes not restored'}
    $passed++;Write-Host 'PASS existing LNK apply and byte-exact restore'
}catch{$failures.Add($_.Exception.Message);Write-Host "FAIL existing LNK: $_"}
$guiBody=@'
function Gui-Assert([bool]$condition,[string]$message){if(-not $condition){throw $message}}
function Gui-Wait{
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while($state.Busy -and [DateTime]::UtcNow -lt $deadline){& $pollWork;[Threading.Thread]::Sleep(25)}
    Gui-Assert (-not $state.Busy) 'Worker timed out'
}
function Gui-Click($control){$control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function Gui-Check([string]$label,[scriptblock]$test){try{& $test;$script:GuiPassed++;Write-Host "PASS GUI $label"}catch{$script:GuiFailures.Add($label+': '+$_.Exception.Message);Write-Host "FAIL GUI $label : $_"}}
$window.Show()
$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
Gui-Check 'shown window and initial disabled states' {Gui-Assert ($window.IsVisible -and -not $ui.GenerateButton.IsEnabled -and -not $ui.ApplyButton.IsEnabled) 'Incorrect initial state'}
Gui-Check 'synthetic file drag-over and drop handlers' {
    $data=[Windows.DataObject]::new([Windows.DataFormats]::FileDrop,[string[]]@($script:GuiSource))
    $ctor=[Windows.DragEventArgs].GetConstructors([Reflection.BindingFlags]'NonPublic,Instance')[0]
    $drag=$ctor.Invoke([object[]]@($data,[Windows.DragDropKeyStates]::None,[Windows.DragDropEffects]::Copy,$ui.DropZone,[Windows.Point]::new(0,0)))
    $drag.RoutedEvent=[Windows.DragDrop]::PreviewDragOverEvent;$ui.DropZone.RaiseEvent($drag)
    Gui-Assert ($drag.Effects -eq [Windows.DragDropEffects]::Copy) 'Drag-over rejected image'
    $drop=$ctor.Invoke([object[]]@($data,[Windows.DragDropKeyStates]::None,[Windows.DragDropEffects]::Copy,$ui.DropZone,[Windows.Point]::new(0,0)))
    $drop.RoutedEvent=[Windows.DragDrop]::DropEvent;$ui.DropZone.RaiseEvent($drop)
    Gui-Assert ($state.Source -eq $script:GuiSource -and $ui.GenerateButton.IsEnabled -and $null -ne $ui.SourcePreview.Source) 'Drop source or preview failed'
}
Gui-Check 'generation and all four decoded previews' {
    Gui-Click $ui.GenerateButton;Gui-Wait
    Gui-Assert ($null -ne $state.Generated) $ui.StatusText.Text
    foreach($size in @(256,48,32,16)){Gui-Assert ($ui['Preview'+$size].Source.PixelWidth -eq $size) "Bad preview $size"}
}
Gui-Check 'busy repeated click creates one result' {
    Gui-Click $ui.GenerateButton;Gui-Click $ui.GenerateButton;Gui-Wait
    Gui-Assert ($null -ne $state.Generated -and $state.Generated.IconPath.EndsWith('_02.ico')) 'Busy guard or numbering failed'
}
Gui-Check 'cancel finishes safely and disables apply' {
    Gui-Click $ui.GenerateButton;Gui-Click $ui.CancelButton;Gui-Wait
    Gui-Assert ($null -eq $state.Generated -and -not $ui.ApplyButton.IsEnabled -and $ui.StatusText.Text.Contains('中止')) 'Cancel state incorrect'
    Gui-Assert ($ui.StatusText.Foreground.ToString() -eq [Windows.Media.Brushes]::DarkSlateGray.ToString()) 'Cancellation displayed as error'
}
Gui-Check 'regenerate after cancel' {Gui-Click $ui.GenerateButton;Gui-Wait;Gui-Assert ($null -ne $state.Generated) $ui.StatusText.Text}
Gui-Check 'apply uses Custom test folder and suppresses repeat apply' {
    $target=Join-Path $rootPath 'gui-dummy.ps1';[IO.File]::WriteAllText($target,'Write-Output "dummy"')
    $hash=(Get-FileHash -LiteralPath $target).Hash
    $ui.TargetBox.Text=$target
    $ui.DestinationBox.SelectedItem=@($ui.DestinationBox.Items | Where-Object {$_.Tag -eq 'Custom'})[0]
    $ui.OutputDirectoryBox.Text=$rootPath
    Gui-Assert $ui.ApplyButton.IsEnabled 'Apply not enabled'
    Gui-Click $ui.ApplyButton;Gui-Wait
    Gui-Assert (-not $ui.ApplyButton.IsEnabled -and $state.LastBackupId.Length -eq 32) $ui.StatusText.Text
    ${id}=[string]$state.LastBackupId
    Restore-AiconFactoryIcon -BackupId $id -Root $rootPath -Confirm:$false | Out-Null
    Gui-Assert ((Get-FileHash -LiteralPath $target).Hash -eq $hash) 'GUI target changed'
}
Gui-Check 'WebP select/generate supplies input preview' {
    $path=Join-Path $rootPath 'gui.webp'
    [IO.File]::WriteAllBytes($path,[Convert]::FromBase64String('UklGRiwAAABXRUJQVlA4TB8AAAAvD8ACEA8wKIM8UPMf8CDMNtpv/qYHcXOI6P8EcGeRAA=='))
    & $selectSource $path;Gui-Click $ui.GenerateButton;Gui-Wait
    Gui-Assert ($null -ne $state.Generated -and $null -ne $ui.SourcePreview.Source -and $ui.SourcePlaceholder.Visibility -eq 'Collapsed') $ui.StatusText.Text
}
$window.Close()
'@
$bodyPath=Join-Path $work 'GuiHarnessBody.ps1'
[IO.File]::WriteAllText($bodyPath,$guiBody,[Text.UTF8Encoding]::new($true))
$module=Get-Module AiconFactory
$guiResult=& $module {
    param($app,$body,$src,$root)
    $script:GuiSource=$src;$script:GuiPassed=0;$script:GuiFailures=New-Object 'System.Collections.Generic.List[string]'
    $gui=[IO.File]::ReadAllText((Join-Path $app 'App\Gui.ps1'))
    $gui=$gui.Replace('$PSScriptRoot',("'"+(Join-Path $app 'App').Replace("'","''")+"'"))
    $gui=$gui.Replace('[void]$window.ShowDialog()',(". '"+$body.Replace("'","''")+"'"))
    . ([scriptblock]::Create($gui))
    Show-AiconFactoryWindow -Root $root
    [pscustomobject]@{Passed=$script:GuiPassed;Failures=@($script:GuiFailures.ToArray())}
} $AppRoot $bodyPath $source $work
$passed+=$guiResult.Passed
foreach($failure in $guiResult.Failures){$failures.Add($failure)}
if((Get-FileHash -LiteralPath $source).Hash -ne $sourceHash){$failures.Add('Source bytes changed')}
Write-Host "Extended: $passed passed; $($failures.Count) failed. Fixtures retained: $work"
if($failures.Count){throw ($failures -join [Environment]::NewLine)}
