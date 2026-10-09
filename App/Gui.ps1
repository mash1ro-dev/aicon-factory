#Requires -Version 5.1
# Loaded by AiconFactory.psm1. All controls and mutable state belong to one window.
function Show-AiconFactoryWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'GUI は STA モードで起動してください。Start.ps1 または Start-AiconFactory を使ってください。'
    }
    Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Windows.Forms')
    if (-not ('Aicon.ImageEngine' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'ImageEngine.cs') -ReferencedAssemblies @('System.Drawing.dll', 'System.Core.dll') -ErrorAction Stop
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    # Capture the module-bound private validator before event closures create their own scope.
    $validateLocalPath = (Get-Command -Name Get-AiconFullPath -CommandType Function -ErrorAction Stop).ScriptBlock
    $writeDiagnostic = (Get-Command Write-AiconDiagnosticLog -CommandType Function -ErrorAction Stop).ScriptBlock
    $getUserError = (Get-Command Get-AiconUserErrorText -CommandType Function -ErrorAction Stop).ScriptBlock
    $modulePath = Join-Path $PSScriptRoot 'AiconFactory.psm1'
    $xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
    $xmlSettings = New-Object System.Xml.XmlReaderSettings
    $xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $reader = [Xml.XmlReader]::Create($xamlPath, $xmlSettings)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }

    $names = @('DropZone','SourcePlaceholder','SourcePreview','ChooseImageButton','SourceFileLabel',
        'IconNameBox','CategoryBox','GenerateButton','PreviewPlaceholder','Preview256','Preview48',
        'Preview32','Preview16','TargetBox','ChooseTargetFileButton','ChooseTargetFolderButton',
        'DestinationBox','OutputDirectoryBox','ChooseOutputButton','ShortcutNameBox','ApplyButton',
        'OpenLocationButton','CancelButton','StatusText','BusyIndicator','GitHubFooter','GitHubLink','SingleSourcePanel','BatchSourcePanel','BatchSourceList','SinglePreviewPanel','BatchResultsPanel','BatchSummaryText','BatchResultsList','PreviewCaption')
    $ui = @{}
    foreach ($name in $names) {
        $ui[$name] = $window.FindName($name)
        if ($null -eq $ui[$name]) { throw ('画面の部品が見つかりません: ' + $name) }
    }
    # Fit smaller displays without reducing the image preview sizes. The body scrolls if needed.
    $workArea = [Windows.SystemParameters]::WorkArea
    $window.MaxHeight = [Math]::Max(500, $workArea.Height)
    $window.MaxWidth = [Math]::Max(760, $workArea.Width)
    if ($workArea.Height -lt $window.MinHeight) { $window.MinHeight = [Math]::Max(500, $workArea.Height - 12) }
    if ($workArea.Width -lt $window.MinWidth) { $window.MinWidth = [Math]::Max(760, $workArea.Width - 12) }
    $window.Height = [Math]::Min($window.Height, $workArea.Height - 12)
    $window.Width = [Math]::Min($window.Width, $workArea.Width - 12)

    $state = @{
        Sources = @(); Batch = $false; BatchCancellation = $null; BatchQueue = $null; BatchResult = $null; BatchRows = $null; Source = ''; Generated = $null; Busy = $false; Updating = $false
        PowerShell = $null; Runspace = $null; Async = $null; Kind = ''
        CancelRequested = $false; CloseAfter = $false; Closed = $false
        LastDirectory = ''; AppliedSignature = ''; PendingSignature = ''; LastBackupId = ''; Timer = $null
    }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $state.Timer = $timer

    $setStatus = {
        param([string]$Message, [bool]$IsError = $false)
        $ui.StatusText.Text = $Message
        $ui.StatusText.ToolTip = $Message
        $ui.StatusText.Foreground = if ($IsError) { [Windows.Media.Brushes]::Firebrick } else { [Windows.Media.Brushes]::DarkSlateGray }
    }.GetNewClosure()

    $reportFailure = {
        param([string]$Stage,$Record)
        $saved = & $writeDiagnostic -Root $rootPath -Stage $Stage -ErrorRecord $Record
        $message = & $getUserError -Stage $Stage
        if (-not $saved) { $message += ' 詳しい記録も保存できませんでした。保存先の空き容量や権限を確認してください。' }
        & $setStatus $message $true
    }.GetNewClosure()
    $getSignature = {
        $icon = if ($null -ne $state.Generated) { [string]$state.Generated.IconPath } else { '' }
        $destination = [string]$ui.DestinationBox.SelectedItem.Tag
        return (@($icon, $ui.TargetBox.Text.Trim(), $destination,
            $ui.OutputDirectoryBox.Text.Trim(), $ui.ShortcutNameBox.Text.Trim()) -join "`n")
    }.GetNewClosure()

    $refreshEnabled = {
        $idle = -not $state.Busy
        foreach ($key in @('ChooseImageButton','IconNameBox','CategoryBox','TargetBox',
                'ChooseTargetFileButton','ChooseTargetFolderButton')) { $ui[$key].IsEnabled = $idle -and (-not $state.Batch -or $key -in @('ChooseImageButton','CategoryBox')) }
        $ui.DropZone.AllowDrop = $idle
        $ui.GenerateButton.IsEnabled = $idle -and ($state.Batch -or (-not [string]::IsNullOrWhiteSpace($state.Source))) -and
            ($state.Batch -or (-not [string]::IsNullOrWhiteSpace($ui.IconNameBox.Text)))
        $target = $ui.TargetBox.Text.Trim()
        $extension = ''
        try { $extension = [IO.Path]::GetExtension($target) } catch { }
        $localTarget = (-not [string]::IsNullOrWhiteSpace($target)) -and (-not $target.StartsWith('\\'))
        $directTarget = ($extension -ieq '.lnk') -or ($localTarget -and [IO.Directory]::Exists($target))
        $ui.DestinationBox.IsEnabled = $idle -and (-not $state.Batch) -and (-not $directTarget)
        $ui.ShortcutNameBox.IsEnabled = $idle -and (-not $state.Batch) -and (-not $directTarget)
        $custom = ([string]$ui.DestinationBox.SelectedItem.Tag -eq 'Custom') -and (-not $directTarget)
        $ui.OutputDirectoryBox.IsEnabled = $idle -and (-not $state.Batch) -and $custom
        $ui.ChooseOutputButton.IsEnabled = $idle -and (-not $state.Batch) -and $custom
        $signature = & $getSignature
        $ui.ApplyButton.IsEnabled = $idle -and (-not $state.Batch) -and ($null -ne $state.Generated) -and
            (-not [string]::IsNullOrWhiteSpace($target)) -and ($signature -ne $state.AppliedSignature)
        $ui.OpenLocationButton.IsEnabled = $idle -and (-not [string]::IsNullOrWhiteSpace($state.LastDirectory))
        $ui.BusyIndicator.Visibility = if ($state.Busy) { 'Visible' } else { 'Collapsed' }
        $ui.CancelButton.Visibility = if ($state.Busy -and $state.Kind -in @('Generate','Batch')) { 'Visible' } else { 'Collapsed' }
        $ui.CancelButton.IsEnabled = -not $state.CancelRequested
    }.GetNewClosure()

    $loadBitmap = {
        param([string]$Path, [int]$DecodeWidth = 0)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            # Preserve original raster dimensions; WPF Uniform controls display size.
            $bitmap.StreamSource = $stream
            $bitmap.EndInit()
            $bitmap.Freeze()
            return $bitmap
        } finally { $stream.Dispose() }
    }.GetNewClosure()

    $refreshPreviewSizes = {
        $scaleX = 1.0; $scaleY = 1.0
        $presentation = [Windows.PresentationSource]::FromVisual($window)
        if ($null -ne $presentation -and $null -ne $presentation.CompositionTarget) {
            $transform = $presentation.CompositionTarget.TransformToDevice
            $scaleX = [Math]::Max(1.0, $transform.M11)
            $scaleY = [Math]::Max(1.0, $transform.M22)
        }
        foreach ($size in @(256,48,32,16)) {
            $ui['Preview' + $size].Width = $size / $scaleX
            $ui['Preview' + $size].Height = $size / $scaleY
        }
    }.GetNewClosure()

    $clearGenerated = {
        $state.Generated = $null
        $state.AppliedSignature = ''
        foreach ($size in @(256,48,32,16)) { $ui['Preview' + $size].Source = $null }
        $ui.PreviewPlaceholder.Visibility = 'Visible'
        & $refreshEnabled
    }.GetNewClosure()

    $setSelectionMode = {
        param([bool]$Batch)
        $state.Batch = $Batch
        $ui.PreviewCaption.Text = if ($Batch) {'画像ごとの保存結果を確認'} else {'透過チェックと、小さいサイズもチェック'}
        $ui.SingleSourcePanel.Visibility = if ($Batch) {'Collapsed'} else {'Visible'}
        $ui.BatchSourcePanel.Visibility = if ($Batch) {'Visible'} else {'Collapsed'}
        $ui.SinglePreviewPanel.Visibility = if ($Batch) {'Collapsed'} else {'Visible'}
        $ui.BatchResultsPanel.Visibility = if ($Batch) {'Visible'} else {'Collapsed'}
        $ui.GenerateButton.Content = if ($Batch) {"$($state.Sources.Count)枚まとめてアイコン化"} else {'アイコン化する'}
        $ui.ApplyButton.ToolTip = if ($Batch) {'一括モードはICOの保存のみです。'} else {'対象へ適用'}
    }.GetNewClosure()
    $selectSource = {
        param([string]$Path)
        if ($state.Busy) { return }
        & $setSelectionMode $false
        $state.Sources = @()
        try {
            # Match module path rules before any existence check, header read or WPF preview.
            # Reject UNC, drive-relative paths, alternate streams and every reparse-point ancestor.
            $source = & $validateLocalPath -Path $Path
            if (-not [IO.File]::Exists($source)) { throw '画像ファイルが見つかりません。' }
            if ([IO.Path]::GetExtension($source).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')) {
                throw 'PNG / JPEG / WebP 画像を1枚選んでください。'
            }
            & $clearGenerated
            $state.Source = ''
            $state.Updating = $true
            try { $ui.IconNameBox.Text = [IO.Path]::GetFileNameWithoutExtension($source) }
            finally { $state.Updating = $false }
            $ui.SourceFileLabel.Text = [IO.Path]::GetFileName($source)
            $ui.SourceFileLabel.ToolTip = $source
            $ui.SourcePreview.Source = $null
            $ui.SourcePlaceholder.Text = '…'
            $ui.SourcePlaceholder.Visibility = 'Visible'
            # Validate file size, format, CRC and pixel dimensions before invoking any WPF decoder.
            [Aicon.ImageEngine]::ValidateSource($source)
            $state.Source = $source
            try {
                if ([IO.Path]::GetExtension($source) -ieq '.webp') {
                    throw 'WebP preview is provided by the bundled decoder after generation.'
                }
                $ui.SourcePreview.Source = & $loadBitmap $source 256
                $ui.SourcePlaceholder.Visibility = 'Collapsed'
                & $setStatus '画像を選べたよ。名前とカテゴリを確認して、アイコン化してみよう。'
            } catch {
                # WebP is decoded by the image engine; a WIC codec is not required for conversion.
                $ui.SourcePlaceholder.Text = [IO.Path]::GetExtension($source).TrimStart('.').ToUpperInvariant()
                $ui.SourcePlaceholder.FontSize = 18
                & $setStatus '画像を選べたよ。プレビューはアイコンの生成後に表示します。'
            }
            & $refreshEnabled
        } catch {
            & $refreshEnabled
            & $reportFailure 'ReadImage' $_
        }
    }.GetNewClosure()

    $selectSources = {
        param([string[]]$Paths)
        if ($state.Busy -or $Paths.Count -eq 0) {return}
        if ($Paths.Count -eq 1) { & $selectSource $Paths[0]; return }
        try {
            $safe = @($Paths | ForEach-Object { & $validateLocalPath -Path $_ })
            foreach ($p in $safe) {
                if (-not [IO.File]::Exists($p) -or [IO.Path]::GetExtension($p).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')) {throw 'Unsupported selection'}
            }
            & $clearGenerated
            $state.Source = ''; $state.Sources = $safe; $state.BatchResult = $null
            $state.LastDirectory = ''; $state.BatchRows = New-Object 'System.Collections.Generic.List[string]'
            $ui.BatchResultsList.Items.Clear()
            $ui.BatchSummaryText.Text = '画像ごとにICOを保存します'
            $ui.BatchSourceList.Text = ($safe | ForEach-Object {[IO.Path]::GetFileName($_) -replace '[\x00-\x1f]',' '}) -join "`n"
            $ui.SourceFileLabel.Text = "$($safe.Count)枚の画像を選択中"
            $ui.SourceFileLabel.ToolTip = $ui.BatchSourceList.Text
            $state.Updating = $true
            try {$ui.IconNameBox.Text = '元のファイル名を使用'} finally {$state.Updating = $false}
            & $setSelectionMode $true
            & $setStatus "$($safe.Count)枚の画像を選択中。カテゴリを確認して、まとめてアイコン化できます。"
            & $refreshEnabled
        } catch { & $reportFailure 'ReadImage' $_ }
    }.GetNewClosure()
    $drainBatchProgress = {
        if ($null -eq $state.BatchQueue) {return}
        $item = $null
        while ($state.BatchQueue.TryDequeue([ref]$item)) {
            $label = switch ($item.Status) {'Success' {'成功'} 'Failed' {'失敗'} 'Cancelled' {'中止'}}
            [void]$ui.BatchResultsList.Items.Add(($label+' · '+$item.Name+' — '+$item.Reason))
            $done = $ui.BatchResultsList.Items.Count
            $ui.BatchSummaryText.Text = "$done / $($state.Sources.Count)枚 処理済み"
        }
    }.GetNewClosure()
    $chooseFolder = {
        param([string]$Description, [string]$InitialPath = '')
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $dialog.Description = $Description
            $dialog.ShowNewFolderButton = $false
            if ([IO.Directory]::Exists($InitialPath)) { $dialog.SelectedPath = $InitialPath }
            # FolderBrowserDialog is modal to the WPF owner through a WinForms IWin32Window.
            $owner = New-Object Windows.Forms.NativeWindow
            $interop = New-Object -TypeName Windows.Interop.WindowInteropHelper -ArgumentList $window
            $owner.AssignHandle($interop.Handle)
            try {
                if ($dialog.ShowDialog($owner) -eq [Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
            } finally { $owner.ReleaseHandle() }
            return $null
        } finally { $dialog.Dispose() }
    }.GetNewClosure()

    $startWork = {
        param([string]$Kind, [hashtable]$Arguments)
        if ($state.Busy) { return }
        $state.Busy = $true; $state.Kind = $Kind; $state.CancelRequested = $false
        $state.CloseAfter = $false
        & $refreshEnabled
        & $setStatus $(if ($Kind -in @('Generate','Batch')) { '画像を整えて、7サイズのICOを作成しています…' } else { 'バックアップを保存して、対象へ適用しています…' })
        try {
            $runspace = [RunspaceFactory]::CreateRunspace()
            $state.Runspace = $runspace
            $runspace.ApartmentState = [Threading.ApartmentState]::STA
            $runspace.ThreadOptions = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
            $runspace.Open()
            $ps = [PowerShell]::Create()
            $state.PowerShell = $ps
            $ps.Runspace = $runspace
            [void]$ps.AddScript({
                param($ModulePath, $Kind, $Arguments)
                $ErrorActionPreference = 'Stop'
                $ProgressPreference = 'SilentlyContinue'
                Import-Module -Name $ModulePath -Force -ErrorAction Stop
                if ($Kind -eq 'Generate') { New-AiconFactoryIcon @Arguments }
                elseif ($Kind -eq 'Batch') { New-AiconFactoryBatch @Arguments }
                elseif ($Kind -eq 'Apply') { Set-AiconFactoryIcon @Arguments }
                else { throw '未定義の処理です。' }
            }).AddArgument($modulePath).AddArgument($Kind).AddArgument($Arguments)
            $state.Async = $ps.BeginInvoke()
            $state.Timer.Start()
        } catch {
            if ($null -ne $state.PowerShell) { $state.PowerShell.Dispose() }
            if ($null -ne $state.Runspace) { $state.Runspace.Dispose() }
            $state.PowerShell = $null; $state.Runspace = $null; $state.Async = $null
            if ($state.BatchCancellation) {$state.BatchCancellation.Dispose();$state.BatchCancellation = $null}
            $state.BatchQueue = $null
            $state.Busy = $false; $state.Kind = ''
            & $refreshEnabled
            & $reportFailure $Kind $_
        }
    }.GetNewClosure()

    $pollWork = {
        if ($state.Busy -and $state.Kind -eq 'Batch') { & $drainBatchProgress }
        if (-not $state.Busy -or $null -eq $state.Async -or -not $state.Async.IsCompleted) { return }
        $state.Timer.Stop()
        try {
            $results = @($state.PowerShell.EndInvoke($state.Async))
            if ($state.PowerShell.HadErrors) {
                $lastError = $state.PowerShell.Streams.Error | Select-Object -Last 1
                throw $lastError.Exception
            }
            if ($state.Kind -eq 'Batch') {
                & $drainBatchProgress
                $result = $results | Where-Object {$null -ne $_.PSObject.Properties['Items']} | Select-Object -Last 1
                if ($null -eq $result -or $result.Total -ne $state.Sources.Count -or ($result.Succeeded+$result.Failed+$result.Cancelled) -ne $result.Total) {throw 'Incomplete batch result'}
                $state.BatchResult = $result
                $first = @($result.Items | Where-Object Status -eq 'Success') | Select-Object -First 1
                if ($first) {$state.LastDirectory = [IO.Path]::GetDirectoryName([string]$first.Result.IconPath)}
                $summary = "$($result.Succeeded)件成功 / $($result.Failed)件失敗 / $($result.Cancelled)件中止"
                if ($result.CancellationRequested) {$summary = '中止しました。'+$summary}
                if (@($result.Items | Where-Object {-not $_.LogSaved}).Count) {$summary += ' 詳しい記録を保存できなかった項目があります。'}
                $ui.BatchSummaryText.Text = $summary
                & $setStatus $summary ($result.Failed -gt 0 -and -not $result.CancellationRequested)
            } elseif ($state.Kind -eq 'Generate') {
                $result = $results | Where-Object { $null -ne $_.PSObject.Properties['IconPath'] } | Select-Object -Last 1
                if ($null -eq $result -or -not [IO.File]::Exists([string]$result.IconPath)) { throw '生成結果を確認できませんでした。' }
                $state.LastDirectory = [IO.Path]::GetDirectoryName([string]$result.IconPath)
                if ($state.CancelRequested) {
                    & $setStatus '中止しました。対象へは適用していません。保存済みのアイコンは保存場所から確認できます。'
                } else {
                    # Load all frames before enabling Apply. A partial preview is never a ready result.
                    $images = @{}
                    foreach ($size in @(256,48,32,16)) {
                        $frame = [string]$result.Frames[$size]
                        if (-not $frame) { $frame = [string]$result.Frames[$size.ToString()] }
                        if (-not [IO.File]::Exists($frame)) { throw ('プレビューがありません: ' + $size + ' px') }
                        $images[$size] = & $loadBitmap $frame
                    }
                    foreach ($size in @(256,48,32,16)) { $ui['Preview' + $size].Source = $images[$size] }
                    & $refreshPreviewSizes
                    $ui.PreviewPlaceholder.Visibility = 'Collapsed'
                    if ($null -eq $ui.SourcePreview.Source) {
                        $ui.SourcePreview.Source = & $loadBitmap ([string]$result.PreviewPath) 256
                        $ui.SourcePlaceholder.Visibility = 'Collapsed'
                    }
                    $state.Generated = $result
                    $state.AppliedSignature = ''
                    & $setStatus ('保存できたよ: ' + [IO.Path]::GetFileName([string]$result.IconPath) + '  ·  対象を選ぶと適用できます。')
                }
            } else {
                $result = $results | Where-Object { $null -ne $_.PSObject.Properties['TargetPath'] } | Select-Object -Last 1
                if ($null -eq $result) { throw '適用結果を確認できませんでした。' }
                $state.AppliedSignature = $state.PendingSignature
                $state.LastDirectory = [IO.Path]::GetDirectoryName([string]$result.TargetPath)
                $message = '適用できたよ。'
                if ($null -ne $result.PSObject.Properties['BackupId'] -and $result.BackupId) {
                    $state.LastBackupId = [string]$result.BackupId
                }
                & $setStatus $message
            }
        } catch {
            if ($state.CancelRequested -and $state.Kind -in @('Generate','Batch')) {
                & $setStatus '中止しました。対象へは適用していません。'
            } else { & $reportFailure $state.Kind $_ }
        } finally {
            $state.PowerShell.Dispose(); $state.Runspace.Dispose()
            $state.PowerShell = $null; $state.Runspace = $null; $state.Async = $null
            if ($state.BatchCancellation) {$state.BatchCancellation.Dispose();$state.BatchCancellation = $null}
            $state.BatchQueue = $null
            $state.Busy = $false; $state.Kind = ''
            & $refreshEnabled
            if ($state.CloseAfter) { $window.Close() }
        }
    }.GetNewClosure()
    $timer.Add_Tick($pollWork)

    $ui.ChooseImageButton.Add_Click({
        if ($state.Busy) { return }
        try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = 'アイコンにする画像を選ぶ'
        $dialog.Filter = '画像 (PNG / JPEG / WebP)|*.png;*.jpg;*.jpeg;*.webp'
        $dialog.Multiselect = $true; $dialog.CheckFileExists = $true; $dialog.DereferenceLinks = $false
        if ($dialog.ShowDialog($window) -eq $true) { & $selectSources $dialog.FileNames }
        } catch { & $reportFailure 'Dialog' $_ }
    }.GetNewClosure())

    $ui.DropZone.Add_PreviewDragOver({
        param($sender, $eventArgs)
        $eventArgs.Effects = [Windows.DragDropEffects]::None
        if (-not $state.Busy -and $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
            $files = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
            if ($files.Count -gt 0 -and @($files | Where-Object {[IO.Path]::GetExtension([string]$_).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp')}).Count -eq 0) {
                $eventArgs.Effects = [Windows.DragDropEffects]::Copy
            }
        }
        $eventArgs.Handled = $true
    }.GetNewClosure())
    $ui.DropZone.Add_Drop({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        if ($state.Busy) { return }
        if (-not $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { & $setStatus 'PNG・JPEG・WebP画像をドロップしてください。' $true; return }
        $files = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop))
        & $selectSources ([string[]]$files)
    }.GetNewClosure())

    $inputChanged = {
        if ($state.Updating -or $state.Busy) { return }
        if ($null -ne $state.Generated) {
            & $clearGenerated
            & $setStatus '名前またはカテゴリが変わりました。もう一度アイコン化してください。'
        }
        & $refreshEnabled
    }.GetNewClosure()
    $ui.IconNameBox.Add_TextChanged($inputChanged)
    $ui.CategoryBox.Add_SelectionChanged($inputChanged)
    $ui.GenerateButton.Add_Click({
        if ($state.Busy) {return}
        if ($state.Batch) {
            if ($state.Sources.Count -lt 2) {return}
            & $clearGenerated
            $state.BatchResult = $null; $ui.BatchResultsList.Items.Clear()
            $state.BatchCancellation = New-Object Threading.CancellationTokenSource
            $state.BatchQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            $arguments = @{Sources=[string[]]@($state.Sources);Category=[string]$ui.CategoryBox.SelectedItem.Content;Root=$rootPath;CancellationToken=$state.BatchCancellation.Token;ProgressQueue=$state.BatchQueue}
            & $startWork 'Batch' $arguments
            return
        }
        if ([string]::IsNullOrWhiteSpace($state.Source)) {return}
        & $clearGenerated
        $arguments = @{
            Source = $state.Source; Name = $ui.IconNameBox.Text.Trim()
            Category = [string]$ui.CategoryBox.SelectedItem.Content; Root = $rootPath
        }
        & $startWork 'Generate' $arguments
    }.GetNewClosure())

    $ui.ChooseTargetFileButton.Add_Click({
        if ($state.Busy) { return }
        try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = 'アイコンを使う対象を選ぶ'
        $dialog.Filter = '対応ファイル|*.lnk;*.ps1;*.bat;*.cmd;*.exe'
        $dialog.Multiselect = $false; $dialog.CheckFileExists = $true; $dialog.DereferenceLinks = $false
        if ($dialog.ShowDialog($window) -eq $true) { $ui.TargetBox.Text = $dialog.FileName }
        } catch { & $reportFailure 'Dialog' $_ }
    }.GetNewClosure())
    $ui.ChooseTargetFolderButton.Add_Click({
        if ($state.Busy) { return }
        try {
        $path = & $chooseFolder 'アイコンを変更するフォルダを選んでください。' $ui.TargetBox.Text
        if ($path) { $ui.TargetBox.Text = $path }
        } catch { & $reportFailure 'Dialog' $_ }
    }.GetNewClosure())
    $ui.ChooseOutputButton.Add_Click({
        if ($state.Busy) { return }
        try {
        $path = & $chooseFolder 'ショートカットを保存するフォルダを選んでください。' $ui.OutputDirectoryBox.Text
        if ($path) { $ui.OutputDirectoryBox.Text = $path }
        } catch { & $reportFailure 'Dialog' $_ }
    }.GetNewClosure())
    foreach ($key in @('TargetBox','OutputDirectoryBox','ShortcutNameBox')) {
        $ui[$key].Add_TextChanged({ & $refreshEnabled }.GetNewClosure())
    }
    $ui.DestinationBox.Add_SelectionChanged({ & $refreshEnabled }.GetNewClosure())
    $ui.ApplyButton.Add_Click({
        if ($state.Busy -or $state.Batch -or $null -eq $state.Generated) { return }
        try {
            $target = $ui.TargetBox.Text.Trim()
            if (-not [IO.Path]::IsPathRooted($target) -or $target.StartsWith('\\')) { throw '対象には、このPCの絶対パスを指定してください。' }
            if (-not [IO.File]::Exists($target) -and -not [IO.Directory]::Exists($target)) { throw '対象が見つかりません。ファイルまたはフォルダを選び直してください。' }
            if ([string]::IsNullOrWhiteSpace([string]$state.Generated.IconPath) -or -not [IO.File]::Exists([string]$state.Generated.IconPath)) { throw '保存したICOが見つかりません。もう一度アイコン化してください。' }
            $signature = & $getSignature
            if ($signature -eq $state.AppliedSignature) { return }
            $arguments = @{
                Icon = [string]$state.Generated.IconPath; Target = $target; Root = $rootPath
                Destination = [string]$ui.DestinationBox.SelectedItem.Tag
                OutputDirectory = $ui.OutputDirectoryBox.Text.Trim()
                ShortcutName = $ui.ShortcutNameBox.Text.Trim()
            }
            $state.PendingSignature = $signature
            & $startWork 'Apply' $arguments
        } catch { & $reportFailure 'Apply' $_ }
    }.GetNewClosure())

    $ui.OpenLocationButton.Add_Click({
        if ($state.Busy -or -not $state.LastDirectory) { return }
        try {
            if (-not [IO.Directory]::Exists($state.LastDirectory)) { throw '保存先フォルダが見つかりません。' }
            # Launch Explorer directly; paths are not interpreted as shell commands.
            $startInfo = New-Object Diagnostics.ProcessStartInfo
            $startInfo.FileName = Join-Path $env:windir 'explorer.exe'
            $startInfo.Arguments = '"' + $state.LastDirectory + '"'
            $startInfo.UseShellExecute = $false
            [void][Diagnostics.Process]::Start($startInfo)
        } catch { & $reportFailure 'OpenLocation' $_ }
    }.GetNewClosure())
    $ui.CancelButton.Add_Click({
        if (-not $state.Busy -or $state.Kind -notin @('Generate','Batch')) { return }
        # Do not abort an in-flight file write. Finish safely, then discard the ready-to-apply state.
        $state.CancelRequested = $true
        if ($state.BatchCancellation) {$state.BatchCancellation.Cancel()}
        & $refreshEnabled
        & $setStatus '中止を受け付けました。安全に処理を終了しています。対象への適用は行いません。'
    }.GetNewClosure())

    # A footer link is optional and inactive by default. Only genuine HTTPS GitHub URLs are opened.
    try {
        $settingsPath = Join-Path $rootPath 'settings.json'
        if ([IO.File]::Exists($settingsPath)) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $settings.PSObject.Properties['GitHubUrl'] -and $settings.GitHubUrl) {
                $githubUri = $null
                if ([Uri]::TryCreate([string]$settings.GitHubUrl, [UriKind]::Absolute, [ref]$githubUri) -and
                    $githubUri.Scheme -eq 'https' -and $githubUri.Host -in @('github.com','www.github.com') -and
                    [string]::IsNullOrWhiteSpace($githubUri.UserInfo)) {
                    $ui.GitHubLink.NavigateUri = $githubUri
                    $ui.GitHubLink.ToolTip = $githubUri.AbsoluteUri
                    $ui.GitHubFooter.Visibility = 'Visible'
                    $ui.GitHubLink.Add_RequestNavigate({
                        param($sender, $eventArgs)
                        $eventArgs.Handled = $true
                        try {
                            $startInfo = New-Object Diagnostics.ProcessStartInfo
                            $startInfo.FileName = $eventArgs.Uri.AbsoluteUri
                            $startInfo.UseShellExecute = $true
                            [void][Diagnostics.Process]::Start($startInfo)
                        } catch { & $reportFailure 'GitHub' $_ }
                    }.GetNewClosure())
                }
            }
        }
    } catch {
        $saved = & $writeDiagnostic -Root $rootPath -Stage 'Settings' -ErrorRecord $_
        $message = '設定を読み込めなかったため、標準設定で起動しました。'
        if (-not $saved) { $message += ' 詳しい記録も保存できませんでした。' }
        & $setStatus $message
    }

    $window.Add_ContentRendered({ & $refreshPreviewSizes; & $refreshEnabled }.GetNewClosure())
    $window.Add_SizeChanged({ & $refreshPreviewSizes }.GetNewClosure())
    $window.Add_Closing({
        param($sender, $eventArgs)
        if ($state.Busy) {
            $eventArgs.Cancel = $true
            $state.CloseAfter = $true
            if ($state.Kind -in @('Generate','Batch')) { $state.CancelRequested = $true; if ($state.BatchCancellation) {$state.BatchCancellation.Cancel()} }
            & $refreshEnabled
            & $setStatus '処理を安全に終了してから、ウィンドウを閉じます。'
        }
    }.GetNewClosure())
    $window.Add_Closed({ $state.Closed = $true; $state.Timer.Stop() }.GetNewClosure())
    & $refreshEnabled
    try { [void]$window.ShowDialog() }
    finally {
        $timer.Stop()
        # Closing is deferred while work is active, so disposal never interrupts a shell mutation.
        if ($null -ne $state.PowerShell -and -not $state.Busy) { $state.PowerShell.Dispose() }
        if ($null -ne $state.Runspace -and -not $state.Busy) { $state.Runspace.Dispose() }
    }
}
