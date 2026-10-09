#requires -Version 5.1
function Get-AiconUserErrorText {
    param([string]$Stage)
    switch($Stage){
        'ReadImage' {'この画像は読み込めませんでした。壊れているか、対応していない形式です。'}
        'Generate' {'アイコンの保存に失敗しました。名前と保存先を確認して、もう一度お試しください。'}
        'Apply' {'対象へ適用できませんでした。パスや権限を確認して、もう一度お試しください。'}
        'OpenLocation' {'保存場所を開けませんでした。フォルダを確認してください。'}
        'GitHub' {'GitHubのページを開けませんでした。もう一度お試しください。'}
        'Dialog' {'選択画面を開けませんでした。もう一度お試しください。'}
        default {'処理を完了できませんでした。もう一度お試しください。'}
    }
}
function Write-AiconDiagnosticLog {
    [CmdletBinding()]param([string]$Root,[string]$Stage,$ErrorRecord,[string]$Source)
    try{
        $dir=Get-AiconFullPath (Join-Path $Root 'Logs');[void][IO.Directory]::CreateDirectory($dir)
        $errorObject=$ErrorRecord.Exception
        $inner=@();$cursor=$errorObject.InnerException;$depth=0
        while($null -ne $cursor -and $depth -lt 12){$inner+=@{Type=$cursor.GetType().FullName;Message=$cursor.Message;Stack=$cursor.StackTrace};$cursor=$cursor.InnerException;$depth++}
        $record=[ordered]@{Timestamp=[DateTime]::UtcNow.ToString('o');Operation='GuiError';Source=$Source;Stage=$Stage;Success=$false;Type=$errorObject.GetType().FullName;Message=$errorObject.Message;Exception=$errorObject.ToString();ScriptStackTrace=[string]$ErrorRecord.ScriptStackTrace;Invocation=[string]$ErrorRecord.InvocationInfo.PositionMessage;Inner=$inner}
        $path=Get-AiconFullPath (Join-Path $dir ((Get-Date -Format yyyy-MM-dd)+'.diagnostics.jsonl'))
        Add-Content -LiteralPath $path -Value ($record|ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8 -ErrorAction Stop
        return $true
    }catch{return $false}
}
