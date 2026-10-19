param([string]$AppRoot,[string]$Root,[string]$ResultDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1');$Root=Assert-OwnedTestRoot $AppRoot $Root $ResultDirectory
Import-Module (Join-Path $AppRoot 'App\AiconFactory.psm1') -Force
$script:UXModule=Get-Module AiconFactory
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
if(-not ('AiconTestNative' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'NativeTestUi.cs') -ReferencedAssemblies System.Drawing}
function UX-Assert([bool]$Condition,[string]$Reason){if(-not $Condition){throw $Reason}}
function UX-StartupFailure([string]$Name,[switch]$BlockLogs){
    $folder=Join-Path $Root $Name;[void][IO.Directory]::CreateDirectory($folder)
    Copy-Item -LiteralPath (Join-Path $AppRoot 'IconFactory.exe') -Destination (Join-Path $folder 'IconFactory.exe')
    if($BlockLogs){[IO.File]::WriteAllText((Join-Path $folder 'Logs'),'owned blocker fixture')}
    $p=Start-Process (Join-Path $folder 'IconFactory.exe') -PassThru;$null=$p.Handle
    try{
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        do{Start-Sleep -Milliseconds 100;$p.Refresh();if($p.HasExited){throw 'Startup failure dialog did not appear'}}while($p.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
        UX-Assert ($p.MainWindowHandle -ne [IntPtr]::Zero) 'No startup dialog'
        $w=[Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
        $nodes=$w.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
        $text=(@($nodes|ForEach-Object {$_.Current.Name}) -join ' ')
        UX-Assert ($text.Contains('アプリを起動できませんでした。')) 'Wrong public startup message'
        UX-Assert ($text -notmatch 'Exception|Import-Module|System\.|発生場所|At line|\.psm1|スタック') 'Technical startup details leaked'
        if($BlockLogs){UX-Assert ($text.Contains('詳しい記録も保存できませんでした。')) 'Logging failure hidden';UX-Assert (-not(Test-Path -LiteralPath (Join-Path $folder 'Logs\launcher.jsonl'))) 'False log success'}
        else{
            $records=@(Get-Content -LiteralPath (Join-Path $folder 'Logs\launcher.jsonl') -Encoding UTF8|ForEach-Object {$_|ConvertFrom-Json})
            $errorRecord=@($records|Where-Object {-not $_.Success})[-1]
            UX-Assert ([bool]$errorRecord.Details.Exception -and [bool]$errorRecord.Details.Type) 'Startup exception not logged'
            UX-Assert ($errorRecord.ConsoleHandle -eq 0) 'Console attached at startup failure'
        }
        $buttons=@($nodes|Where-Object {$_.Current.ClassName -eq 'Button' -and $_.Current.Name -eq 'OK'})
        UX-Assert ($buttons.Count -eq 1) 'Ambiguous startup dialog OK button'
        [AiconTestNative]::DialogClick([IntPtr]::new($buttons[0].Current.NativeWindowHandle),$p.Id)
        UX-Assert ($p.WaitForExit(5000)) 'Startup dialog did not close'
        UX-Assert ($p.ExitCode -eq 1) 'Startup failure did not return exit 1'
    }finally{if(-not $p.HasExited){$p.Kill()}}
}
Describe 'Distribution UX and developer diagnostics' {
    It 'ships an x64 Windows GUI executable with no console subsystem' {
        $bytes=[IO.File]::ReadAllBytes((Join-Path $AppRoot 'IconFactory.exe'));$pe=[BitConverter]::ToInt32($bytes,0x3c)
        UX-Assert ([BitConverter]::ToUInt16($bytes,$pe+24) -eq 0x20b) 'Not x64 PE32+'
        UX-Assert ([BitConverter]::ToUInt16($bytes,$pe+92) -eq 2) 'Not Windows GUI subsystem'
    }
    It 'maps every public failure stage to short Japanese without exception text' {
        foreach($stage in @('ReadImage','Generate','Apply','OpenLocation','Dialog','GitHub')){
            $text=& $script:UXModule {param($s) Get-AiconUserErrorText $s} $stage
            UX-Assert ($text.Length -lt 100 -and $text -match '[ぁ-龯]') 'Not a short Japanese message'
            UX-Assert ($text -notmatch 'Exception|System\.|StackTrace|SENTINEL') 'Technical text in mapping'
        }
    }
    It 'writes the actual exception, inner exception and script stack to local diagnostics' {
        $dir=Join-Path $Root 'diagnostic-check'
        $saved=& $script:UXModule {
            param($p)
            try{throw [IO.InvalidDataException]::new('PRIVATE_OUTER_SENTINEL',[ArgumentException]::new('PRIVATE_INNER_SENTINEL'))}
            catch{Write-AiconDiagnosticLog -Root $p -Stage ReadImage -ErrorRecord $_}
        } $dir
        UX-Assert $saved 'Diagnostic not saved'
        $record=Get-ChildItem -LiteralPath (Join-Path $dir 'Logs') -Filter '*.jsonl'|Get-Content -Encoding UTF8|ConvertFrom-Json
        UX-Assert ($record.Exception.Contains('PRIVATE_OUTER_SENTINEL') -and $record.Exception.Contains('PRIVATE_INNER_SENTINEL') -and [bool]$record.ScriptStackTrace -and [bool]$record.Invocation) 'Missing diagnostic detail'
    }
    It 'returns failure honestly when diagnostic destination is blocked' {
        $dir=Join-Path $Root 'blocked-diagnostic';[void][IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'Logs'),'owned fixture')
        $saved=& $script:UXModule {param($p) try{throw 'PRIVATE_LOG_SENTINEL'}catch{Write-AiconDiagnosticLog -Root $p -Stage Apply -ErrorRecord $_}} $dir
        UX-Assert (-not $saved) 'False diagnostic success'
    }
    It 'shows friendly startup failure and retains details without a console' {UX-StartupFailure 'startup-missing-module'}
    It 'shows logging failure honestly without leaking raw startup exception' {UX-StartupFailure 'startup-blocked-log' -BlockLogs}
    It 'keeps GUI error and tooltip friendly when the real diagnostic write fails' {
        $dir=Join-Path $Root 'gui-blocked-log';[void][IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'Logs'),'owned fixture')
        $source=Join-Path $dir 'bad.png';[IO.File]::WriteAllText($source,'PRIVATE_BAD_BYTES')
        $harness=Join-Path $dir 'body.ps1'
        $body=@'
$window.Show();$window.UpdateLayout()
& $selectSource (Join-Path $rootPath 'bad.png')
if(-not $ui.StatusText.Text.Contains('この画像は読み込めませんでした。') -or -not $ui.StatusText.Text.Contains('詳しい記録も保存できませんでした。')) {throw 'Wrong GUI logging-failure message'}
if($ui.StatusText.Text -match 'Exception|ValidateSource|PRIVATE|System\.' -or $ui.StatusText.ToolTip -ne $ui.StatusText.Text) {throw 'GUI/tooltip technical leakage'}
if($ui.GenerateButton.IsEnabled) {throw 'Bad input remained ready'}
$window.Close()
'@
        [IO.File]::WriteAllText($harness,$body,[Text.UTF8Encoding]::new($true))
        & $script:UXModule {
            param($app,$body,$root)
            $gui=[IO.File]::ReadAllText((Join-Path $app 'App\Gui.ps1')).Replace('$PSScriptRoot',("'"+(Join-Path $app 'App').Replace("'","''")+"'"))
            $gui=$gui.Replace('[void]$window.ShowDialog()',(". '"+$body.Replace("'","''")+"'"))
            . ([scriptblock]::Create($gui));Show-AiconFactoryWindow -Root $root
        } $AppRoot $harness $dir
    }
}
