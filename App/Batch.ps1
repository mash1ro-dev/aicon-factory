#requires -Version 5.1
function New-AiconFactoryBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Sources,[string]$Category='Other',[string]$Root=$script:DefaultRoot,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,$ProgressQueue)
    $items=New-Object 'System.Collections.Generic.List[object]'
    $success=0;$failed=0;$cancelled=0
    foreach($source in $Sources){
        $display=[IO.Path]::GetFileName($source) -replace '[\x00-\x1f]',' '
        if($CancellationToken.IsCancellationRequested){
            $cancelled++;$item=[pscustomobject]@{Source=$source;Name=$display;Status='Cancelled';Reason='中止しました。';Result=$null;LogSaved=$true}
        }else{
            $stage='ReadImage'
            try{
                $safe=Get-AiconFullPath $source
                Initialize-AiconEngine
                [Aicon.ImageEngine]::ValidateSource($safe)
                $stage='Generate';$warnings=@()
                $result=New-AiconFactoryIcon -Source $safe -Category $Category -Root $Root -WarningVariable warnings -WarningAction SilentlyContinue
                $success++
                $item=[pscustomobject]@{Source=$source;Name=$display;Status='Success';Reason='保存しました。';Result=$result;LogSaved=($warnings.Count -eq 0)}
            }catch{
                $failed++;$saved=Write-AiconDiagnosticLog -Root $Root -Stage ('Batch'+$stage) -ErrorRecord $_ -Source $source
                $item=[pscustomobject]@{Source=$source;Name=$display;Status='Failed';Reason=(Get-AiconUserErrorText -Stage $stage);Result=$null;LogSaved=[bool]$saved}
            }
        }
        $items.Add($item)
        if($null -ne $ProgressQueue){$ProgressQueue.Enqueue($item)}
    }
    [pscustomobject]@{Items=$items.ToArray();Total=$Sources.Count;Succeeded=$success;Failed=$failed;Cancelled=$cancelled;CancellationRequested=$CancellationToken.IsCancellationRequested}
}
