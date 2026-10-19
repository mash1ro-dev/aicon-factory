param([string]$AppRoot,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
$Root=Assert-OwnedTestRoot $AppRoot $Root
$work=Join-Path $Root ('Batch-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
Import-Module (Join-Path $AppRoot 'App\AiconFactory.psm1') -Force
Add-Type -AssemblyName System.Drawing
$a=Join-Path $work 'same.png';$b=Join-Path $work 'same.jpg';$c=Join-Path $work 'third.jpeg';$d=Join-Path $work 'comfyui.webp';$e=Join-Path $work 'touya.png';$bad=Join-Path $work 'broken.png'
$bitmap=[Drawing.Bitmap]::new(150,100);$graphics=[Drawing.Graphics]::FromImage($bitmap)
try{$graphics.Clear([Drawing.Color]::AliceBlue);$graphics.FillEllipse([Drawing.Brushes]::RoyalBlue,20,10,90,70);foreach($file in @($a,$e)){$bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Png)};foreach($file in @($b,$c)){$bitmap.Save($file,[Drawing.Imaging.ImageFormat]::Jpeg)}}finally{$graphics.Dispose();$bitmap.Dispose()}
[IO.File]::WriteAllBytes($d,[Convert]::FromBase64String('UklGRiwAAABXRUJQVlA4TB8AAAAvD8ACEA8wKIM8UPMf8CDMNtpv/qYHcXOI6P8EcGeRAA=='))
[IO.File]::WriteAllText($bad,'not an image')
$sources=[string[]]@($a,$b,$c,$d,$e);$hashes=@{};foreach($file in @($sources)+@($bad)){$hashes[$file]=(Get-FileHash -LiteralPath $file).Hash}
$script:Failed=New-Object 'System.Collections.Generic.List[string]';$script:Passed=0
function Assert-Batch([bool]$ok,[string]$reason){if(-not $ok){throw $reason}}
function Check-Batch([string]$name,[scriptblock]$body){try{&$body;$script:Passed++;Write-Host ('PASS '+$name)}catch{$script:Failed.Add($name+': '+$_.Exception.Message);Write-Host ('FAIL '+$name+': '+$_.Exception.Message)}}
$all=New-AiconFactoryBatch -Sources $sources -Root $work -Category Image
Check-Batch 'five mixed inputs produce five successes and exactly five ICOs' {Assert-Batch ($all.Total -eq 5 -and $all.Succeeded -eq 5 -and $all.Failed -eq 0 -and $all.Cancelled -eq 0 -and @(Get-ChildItem -LiteralPath (Join-Path $work 'Library\ICO\Image') -Filter '*.ico').Count -eq 5) 'Count mismatch'}
Check-Batch 'source stems and safe same-stem suffixes' {Assert-Batch ((@($all.Items|ForEach-Object {[IO.Path]::GetFileName($_.Result.IconPath)}) -join ',') -eq 'same.ico,same_02.ico,third.ico,comfyui.ico,touya.ico') 'Bad output names'}
Check-Batch 'every mixed output contains all seven ICO resolutions' {
    foreach($item in $all.Items){$bytes=[IO.File]::ReadAllBytes($item.Result.IconPath);Assert-Batch ([BitConverter]::ToUInt16($bytes,4) -eq 7) 'Bad ICO count';$sizes=@();for($i=0;$i -lt 7;$i++){$v=[int]$bytes[6+16*$i];if($v -eq 0){$v=256};$sizes+=$v};Assert-Batch (($sizes -join ',') -eq '16,24,32,48,64,128,256') 'Bad sizes'}
}
Check-Batch 'all source images retain original bytes' {foreach($file in $sources){Assert-Batch ((Get-FileHash -LiteralPath $file).Hash -eq $hashes[$file]) 'Source changed'}}
$before=@{};foreach($item in $all.Items){$before[$item.Result.IconPath]=(Get-FileHash -LiteralPath $item.Result.IconPath).Hash}
$repeat=New-AiconFactoryBatch -Sources $sources -Root $work -Category Image
Check-Batch 'repeat keeps prior output bytes and safely reserves new names' {Assert-Batch ($repeat.Succeeded -eq 5 -and [IO.Path]::GetFileName($repeat.Items[0].Result.IconPath) -eq 'same_03.ico' -and [IO.Path]::GetFileName($repeat.Items[1].Result.IconPath) -eq 'same_04.ico') 'Unsafe names';foreach($file in $before.Keys){Assert-Batch ((Get-FileHash -LiteralPath $file).Hash -eq $before[$file]) 'Prior output changed'}}
$partial=New-AiconFactoryBatch -Sources @($a,$bad,$c,$d,$e) -Root $work -Category Tools
Check-Batch 'broken middle input preserves four successes and counts one failure' {Assert-Batch ($partial.Succeeded -eq 4 -and $partial.Failed -eq 1 -and $partial.Cancelled -eq 0 -and $partial.Items[1].Status -eq 'Failed' -and $partial.Items[4].Status -eq 'Success') 'Partial counts/continuation wrong'}
Check-Batch 'failed file has short Japanese reason and detailed local diagnostic' {
    $failure=$partial.Items[1];Assert-Batch ($failure.Name -eq 'broken.png' -and $failure.Reason.Length -lt 100 -and $failure.Reason -notmatch 'Exception|System\.|D:\\|発生場所' -and $failure.LogSaved) 'Public reason wrong'
    $logs=@(Get-ChildItem -LiteralPath (Join-Path $work 'Logs') -Filter '*.diagnostics.jsonl'|Get-Content -Encoding UTF8|ForEach-Object {$_|ConvertFrom-Json})
    Assert-Batch (@($logs|Where-Object {$_.Stage -eq 'BatchReadImage' -and $_.Source -eq $bad -and $_.Exception -and $_.Type}).Count -gt 0) 'Details missing'
}
Check-Batch 'partial success ICOs remain, failed ICO absent, inputs unchanged' {Assert-Batch (@(Get-ChildItem -LiteralPath (Join-Path $work 'Library\ICO\Tools') -Filter '*.ico').Count -eq 4) 'Wrong ICOs';foreach($item in $partial.Items|Where-Object Status -eq 'Success'){Assert-Batch ([IO.File]::Exists($item.Result.IconPath)) 'Success disappeared'};foreach($file in @($sources)+@($bad)){Assert-Batch ((Get-FileHash -LiteralPath $file).Hash -eq $hashes[$file]) 'Input changed'}}
$cts=[Threading.CancellationTokenSource]::new();$cts.Cancel();$cancelled=New-AiconFactoryBatch -Sources $sources -Root $work -Category Cancelled -CancellationToken $cts.Token;$cts.Dispose()
Check-Batch 'pre-cancel produces zero ICOs and five cancelled items' {Assert-Batch ($cancelled.Succeeded -eq 0 -and $cancelled.Failed -eq 0 -and $cancelled.Cancelled -eq 5 -and -not(Test-Path -LiteralPath (Join-Path $work 'Library\ICO\Cancelled'))) 'Cancel count wrong'}
Add-Type -TypeDefinition 'public sealed class BatchCancelAfterOne {public System.Threading.CancellationTokenSource Token; public void Enqueue(object item){Token.Cancel();}}'
$cts=[Threading.CancellationTokenSource]::new();$q=[BatchCancelAfterOne]::new();$q.Token=$cts;$one=New-AiconFactoryBatch -Sources $sources -Root $work -Category One -CancellationToken $cts.Token -ProgressQueue $q;$cts.Dispose()
Check-Batch 'cancel between items retains one finished ICO and four cancelled items' {Assert-Batch ($one.Succeeded -eq 1 -and $one.Cancelled -eq 4 -and $one.Failed -eq 0 -and [IO.File]::Exists($one.Items[0].Result.IconPath)) 'Between-item cancel wrong'}
$guiRoot=Join-Path $work 'GUI';[void][IO.Directory]::CreateDirectory($guiRoot)
$body=@'
function BAssert([bool]$ok,[string]$why){if(-not $ok){throw $why}}
function BClick($control){$control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
function BWait{$deadline=[DateTime]::UtcNow.AddSeconds(35);while($state.Busy -and [DateTime]::UtcNow -lt $deadline){&$pollWork;[Threading.Thread]::Sleep(15)};BAssert (-not $state.Busy) 'GUI timeout'}
function BCheck([string]$name,[scriptblock]$test){try{&$test;$script:BatchGuiPass++;Write-Host ('PASS '+$name)}catch{$script:BatchGuiErrors.Add($name+': '+$_.Exception.Message);Write-Host ('FAIL '+$name+': '+$_.Exception.Message)}}
$window.Show();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
BCheck 'GUI multiple selection shows names, count and batch button; apply controls disabled' {
    &$selectSources $script:BatchSources
    BAssert ($state.Batch -and $ui.SourceFileLabel.Text -eq '5枚の画像を選択中' -and $ui.GenerateButton.Content -eq '5枚まとめてアイコン化' -and $ui.BatchSourceList.Text.Contains('comfyui.webp')) 'Batch selection wrong'
    BAssert ($ui.GenerateButton.IsEnabled -and -not $ui.ApplyButton.IsEnabled -and -not $ui.TargetBox.IsEnabled -and -not $ui.IconNameBox.IsEnabled -and $ui.SinglePreviewPanel.Visibility -eq 'Collapsed') 'Batch target safety wrong'
}
BCheck 'GUI multiple drag-over and drop use same batch selection' {
    $data=[Windows.DataObject]::new([Windows.DataFormats]::FileDrop,$script:BatchSources)
    $ctor=[Windows.DragEventArgs].GetConstructors([Reflection.BindingFlags]'NonPublic,Instance')[0]
    foreach($event in @([Windows.DragDrop]::PreviewDragOverEvent,[Windows.DragDrop]::DropEvent)){
        $args=$ctor.Invoke([object[]]@($data,[Windows.DragDropKeyStates]::None,[Windows.DragDropEffects]::Copy,$ui.DropZone,[Windows.Point]::new(0,0)));$args.RoutedEvent=$event;$ui.DropZone.RaiseEvent($args)
        if($event -eq [Windows.DragDrop]::PreviewDragOverEvent){BAssert ($args.Effects -eq [Windows.DragDropEffects]::Copy) 'Multiple drag rejected'}
    }
    BAssert ($state.Batch -and $state.Sources.Count -eq 5) 'Multiple drop wrong'
}
BCheck 'GUI generate blocks double click and selection changes, with exact five results' {
    BClick $ui.GenerateButton;BAssert ($state.Busy -and -not $ui.ChooseImageButton.IsEnabled -and -not $ui.DropZone.AllowDrop) 'Busy guard wrong'
    BClick $ui.GenerateButton;&$selectSources @($script:BatchSources[0]);BAssert ($state.Sources.Count -eq 5 -and $state.Batch) 'Busy selection changed'
    BWait;BAssert ($state.BatchResult.Succeeded -eq 5 -and $ui.BatchResultsList.Items.Count -eq 5 -and $ui.StatusText.Text.Contains('5件成功 / 0件失敗 / 0件中止') -and -not $ui.ApplyButton.IsEnabled -and $null -eq $state.Generated) $ui.StatusText.Text
    BAssert (@(Get-ChildItem -LiteralPath (Join-Path $rootPath 'Library\ICO\AI') -Filter '*.ico').Count -eq 5) 'Duplicate click produced extra ICO'
}
BCheck 'GUI partial failure lists failed filename and safe reason with accurate counts' {
    &$selectSources @($script:BatchSources[0],$script:BatchBad,$script:BatchSources[2],$script:BatchSources[3],$script:BatchSources[4]);BClick $ui.GenerateButton;BWait
    BAssert ($state.BatchResult.Succeeded -eq 4 -and $state.BatchResult.Failed -eq 1 -and $ui.BatchResultsList.Items.Count -eq 5 -and $ui.StatusText.Text.Contains('4件成功 / 1件失敗 / 0件中止')) 'Partial GUI count wrong'
    $row=@($ui.BatchResultsList.Items|Where-Object {$_ -like '*broken.png*'})[0];BAssert ($row.Contains('失敗') -and $row -notmatch 'Exception|System\.|D:\\|発生場所') 'Raw GUI error'
}
BCheck 'GUI cancel completes safely, preserves finished results and displays neutral exact totals' {
    &$selectSources $script:BatchSources;BClick $ui.GenerateButton;BClick $ui.CancelButton;BWait
    $r=$state.BatchResult;BAssert ($r.Succeeded+$r.Failed+$r.Cancelled -eq 5 -and $r.Cancelled -gt 0 -and $ui.BatchResultsList.Items.Count -eq 5 -and $ui.StatusText.Text.Contains('中止しました') -and $ui.StatusText.Foreground.ToString() -eq [Windows.Media.Brushes]::DarkSlateGray.ToString()) 'Cancel GUI wrong'
    foreach($item in $r.Items|Where-Object Status -eq 'Success'){BAssert ([IO.File]::Exists($item.Result.IconPath)) 'Finished ICO missing'}
}
BCheck 'GUI one image restores original single preview, editable name and generation' {
    &$selectSources @($script:BatchSources[0]);BAssert (-not $state.Batch -and $ui.GenerateButton.Content -eq 'アイコン化する' -and $ui.IconNameBox.IsEnabled -and $ui.SinglePreviewPanel.Visibility -eq 'Visible' -and $ui.BatchResultsPanel.Visibility -eq 'Collapsed') 'Single UI regression'
    BClick $ui.GenerateButton;BWait;BAssert ($state.Generated -and $ui.Preview256.Source.PixelWidth -eq 256) $ui.StatusText.Text
}
BCheck 'GUI close during batch cancels remaining items and closes after safe completion' {
    &$selectSources $script:BatchSources;BClick $ui.GenerateButton;$window.Close();BAssert ($state.CloseAfter -and $state.CancelRequested) 'Close not deferred';BWait;BAssert ($state.Closed -and -not $window.IsVisible -and $state.BatchResult.Total -eq 5) 'Deferred close wrong'
}
if($window.IsVisible){$window.Close()}
'@
$bodyPath=Join-Path $work 'BatchGuiBody.ps1';[IO.File]::WriteAllText($bodyPath,$body,[Text.UTF8Encoding]::new($true))
$module=Get-Module AiconFactory
$guiResult=&$module {
    param($app,$body,$sources,$bad,$root)
    $script:BatchSources=[string[]]$sources;$script:BatchBad=$bad;$script:BatchGuiPass=0;$script:BatchGuiErrors=New-Object 'System.Collections.Generic.List[string]'
    $gui=[IO.File]::ReadAllText((Join-Path $app 'App\Gui.ps1')).Replace('$PSScriptRoot',("'"+(Join-Path $app 'App').Replace("'","''")+"'"))
    $gui=$gui.Replace('[void]$window.ShowDialog()',(". '"+$body.Replace("'","''")+"'"));. ([scriptblock]::Create($gui));Show-AiconFactoryWindow -Root $root
    [pscustomobject]@{Passed=$script:BatchGuiPass;Errors=$script:BatchGuiErrors.ToArray()}
} $AppRoot $bodyPath $sources $bad $guiRoot
$script:Passed+=$guiResult.Passed;foreach($errorText in $guiResult.Errors){$script:Failed.Add($errorText)}
Write-Host ('Batch: '+$script:Passed+' passed / '+$script:Failed.Count+' failed')
if($script:Failed.Count){exit 1};exit 0
