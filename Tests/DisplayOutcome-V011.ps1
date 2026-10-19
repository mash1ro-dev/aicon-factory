param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $cases=[Collections.Generic.List[object]]::new()
 function Require($ok,$why){if(-not $ok){throw $why}}
 function Reject($action){$caught=$false;try{&$action|Out-Null}catch{$caught=$true};Require $caught 'Expected failure'}
 function Check($name,$body){try{&$body;$cases.Add(@{Name=$name;Status='PASS'});Write-Host ('PASS '+$name)}catch{$cases.Add(@{Name=$name;Status='FAIL';Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 $data=Join-Path $run.Root 'Data';[void][IO.Directory]::CreateDirectory($data)
 # Generate a synthetic fixture inside this owned run; no retained user/test ICO.
 Add-Type -AssemblyName System.Drawing
 $png=Join-Path $run.Root 'fixture.png';$bitmap=[Drawing.Bitmap]::new(72,48);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.Clear([Drawing.Color]::Transparent);$graphics.FillEllipse([Drawing.Brushes]::SteelBlue,8,4,40,40);$bitmap.Save($png,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 Initialize-AiconEngine;$ico=Join-Path $run.Root 'source.ico';[IO.File]::WriteAllBytes($ico,([Aicon.ImageEngine]::Process($png)).Ico)
 $icoHash=Get-AiconHash $ico
 function Folder($name){$p=Join-Path $run.Root $name;[void][IO.Directory]::CreateDirectory($p);return $p}
 $script:originalSnapshot=(Get-Command Assert-AiconSnapshot).ScriptBlock
 $script:originalVerify=(Get-Command Assert-AiconApplied).ScriptBlock
 $script:originalComplete=(Get-Command Complete-AiconBackup).ScriptBlock
 $script:originalRefresh=(Get-Command Invoke-AiconRefresh).ScriptBlock
 Check 'Observed values reproduce PS5 direct-enum failure; replacement preserves every bit' {
  foreach($value in @(1572870,1572902)){Reject {$null=[IO.FileAttributes]$value};Require ([int](ConvertTo-AiconFileAttributes $value) -eq $value) 'Flags lost'}
 }
 Check 'Normal folder write is verified and backup finalized before success' {
  $folder=Folder 'Normal';$r=Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data
  Require ($r.WriteVerified -and $r.RefreshRequested -and $r.LogRecorded -and $r.Warnings.Count -eq 0 -and (Get-AiconHash $r.TargetPath) -eq $r.TargetHash) 'Outcome fields/hash'
  $m=Get-Content (Join-Path $data ('Backup\'+$r.BackupId+'\manifest.json')) -Raw|ConvertFrom-Json;Require ($m.State -eq 'applied') 'Backup not applied'
 }
 Check 'Observed high-bit attributes injected after snapshot no longer fail after content commit' {
  function script:Assert-AiconSnapshot($Backup){&$script:originalSnapshot $Backup;$Backup.Record.AfterFileAttributes=1572902}
  try{$folder=Folder 'HighBits';$r=Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data;Require ($r.WriteVerified -and (Get-AiconHash $r.TargetPath) -eq $r.TargetHash) 'High-bit commit failed'}
  finally{Set-Item Function:script:Assert-AiconSnapshot $script:originalSnapshot}
 }
 Check 'Restore accepts recorded high-bit file attributes and preserves original bytes' {
  $folder=Folder 'Restore';$ini=Join-Path $folder 'desktop.ini';[IO.File]::WriteAllText($ini,'original');$hash=Get-AiconHash $ini
  $r=Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data
  $dir=Join-Path $data ('Backup\'+$r.BackupId);$m=Get-Content (Join-Path $dir 'manifest.json') -Raw|ConvertFrom-Json
  $m.FileAttributes=1572902;Write-AiconManifest $dir $m
  Restore-AiconFactoryIcon -BackupId $r.BackupId -Root $data -Confirm:$false|Out-Null
  Require ((Get-AiconHash $ini) -eq $hash) 'Restore bytes wrong'
 }
 Check 'Refresh exception preserves verified write and reports warning separately' {
  function script:Invoke-AiconRefresh {throw 'injected display failure'}
  try{$r=Set-AiconFactoryIcon -Icon $ico -Target (Folder 'RefreshFailure') -Root $data;Require ($r.WriteVerified -and -not $r.RefreshRequested -and $r.LogRecorded -and $r.Warnings.Count -eq 1 -and (Get-AiconHash $r.TargetPath) -eq $r.TargetHash) 'Refresh failure became whole failure'}
  finally{Set-Item Function:script:Invoke-AiconRefresh $script:originalRefresh}
 }
 Check 'Nonterminating refresh error does not leak into GUI worker Error stream' {
  $ps=[PowerShell]::Create();$folder=Folder 'RefreshStream'
  try{
   [void]$ps.AddScript({param($module,$ico,$folder,$data) $ErrorActionPreference='Stop';Import-Module $module -Force;&(Get-Module AiconFactory){param($ico,$folder,$data) function script:Invoke-AiconRefresh {Write-Error 'injected refresh error' -ErrorAction Continue};Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data} $ico $folder $data}).AddArgument((Join-Path $app 'App\AiconFactory.psm1')).AddArgument($ico).AddArgument($folder).AddArgument($data)
   $r=@($ps.Invoke());Require ($ps.Streams.Error.Count -eq 0 -and $r.Count -eq 1 -and $r[0].WriteVerified -and -not $r[0].RefreshRequested) 'Refresh leaked worker error'
  }finally{$ps.Dispose()}
 }
 Check 'Actual blocked log path does not undo verified settings; warning is returned' {
  $blocked=Folder 'BlockedData';[void](Initialize-AiconRoot $blocked);[void][IO.Directory]::CreateDirectory((Join-Path $blocked ('Logs\'+(Get-Date -Format yyyy-MM-dd)+'.jsonl')))
  $r=Set-AiconFactoryIcon -Icon $ico -Target (Folder 'LogFailure') -Root $blocked
  Require ($r.WriteVerified -and -not $r.LogRecorded -and $r.Warnings.Count -eq 1 -and (Get-AiconHash $r.TargetPath) -eq $r.TargetHash) 'Log failure marked whole failure'
 }
 Check 'Actual locked write fails and preserves preexisting bytes' {
  $folder=Folder 'Locked';$ini=Join-Path $folder 'desktop.ini';[IO.File]::WriteAllText($ini,'keep');$hash=Get-AiconHash $ini;$lock=[IO.File]::Open($ini,'Open','ReadWrite','None')
  try{Reject {Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data}}finally{$lock.Dispose()}
  Require ((Get-AiconHash $ini) -eq $hash) 'Failed write changed bytes'
 }
 Check 'Verification failure remains failure and rolls back owned target' {
  $folder=Folder 'VerifyFailure';$ini=Join-Path $folder 'desktop.ini';[IO.File]::WriteAllText($ini,'keep');$hash=Get-AiconHash $ini
  function script:Assert-AiconApplied {throw 'injected verification failure'}
  try{Reject {Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data}}finally{Set-Item Function:script:Assert-AiconApplied $script:originalVerify}
  Require ((Get-AiconHash $ini) -eq $hash) 'Verification failure not rolled back'
 }
 Check 'Backup finalization failure remains failure and rolls back owned target' {
  $folder=Folder 'FinalizeFailure';$ini=Join-Path $folder 'desktop.ini';[IO.File]::WriteAllText($ini,'keep');$hash=Get-AiconHash $ini
  function script:Complete-AiconBackup {throw 'injected manifest failure'}
  try{Reject {Set-AiconFactoryIcon -Icon $ico -Target $folder -Root $data}}finally{Set-Item Function:script:Complete-AiconBackup $script:originalComplete}
  Require ((Get-AiconHash $ini) -eq $hash) 'Finalization failure not rolled back'
 }
 Check 'Exact requested guidance and target-specific success copy are present' {
  Require ((Get-AiconApplySuccessText 'Folder') -ceq 'アイコンを設定したよ。見た目が変わらないときは、少し待ってみてね。') 'Folder copy'
  Require ((Get-AiconApplySuccessText 'Shortcut') -ceq 'アイコンを設定できたよ。' -and (Get-AiconApplySuccessText 'NewShortcut') -ceq 'アイコンを設定できたよ。') 'Other copy changed'
  $x=[xml][IO.File]::ReadAllText((Join-Path $app 'App\MainWindow.xaml'));$e=$x.SelectSingleNode('//*[local-name()="Expander" and @Header="アイコンを設定したあとについて"]')
  Require ($e -and $e.FirstChild.Text -ceq "フォルダのアイコンは、変更してもすぐに見た目が切り替わらないことがあります。`nそんなときは、少し待ってみてね。`nそれでも変わらない場合は、デスクトップの何もないところをクリックして、F5キーで表示を更新してみてください。") 'Exact guidance missing'
 }
 Check 'Failure phases and successful notification failure are distinguishable in logs' {
  $logs=@(Get-Content (Join-Path $data ('Logs\'+(Get-Date -Format yyyy-MM-dd)+'.jsonl'))|ForEach-Object {$_|ConvertFrom-Json}|Where-Object Operation -eq Apply)
  Require (@($logs|Where-Object {$_.Success -and $_.Phase -eq 'VerifiedDisplayNotificationFailed'}).Count -ge 1) 'Notification phase missing'
  Require (@($logs|Where-Object {-not $_.Success -and $_.Phase -eq 'Verify'}).Count -eq 1) 'Verify failure phase missing'
  Require (@($logs|Where-Object {-not $_.Success -and $_.Phase -eq 'BackupFinalize'}).Count -eq 1) 'Backup failure phase missing'
  Require ((Get-AiconHash $ico) -eq $icoHash) 'ICO changed'
 }
 Check 'GUI keeps verified success, current ICO and More button when log writing is locked' {
  Add-Type -AssemblyName System.Drawing
  $png=Join-Path $run.Root 'ui.png';$image=[Drawing.Bitmap]::new(20,20);$g=[Drawing.Graphics]::FromImage($image)
  try{$g.Clear([Drawing.Color]::Coral);$image.Save($png,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$image.Dispose()}
  $script:displayUiImage=$png;$script:displayUiFolder=Folder 'UiTarget';$script:displayUiRoot=Folder 'UiData'
  . (Join-Path $app 'App\Gui.ps1')
  Show-AiconFactoryWindow -Root $run.Root -UserDataRoot $script:displayUiRoot -Harness {
   function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
   function Wait-Work {$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and $state.Failed -eq 0) $ui.StatusText.Text}
   $state.DialogResponder={@{Accepted=$true;Remember=$false}};$window.Show();&$actions.Add @($script:displayUiImage)
   Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work;$id=$state.CurrentId;$saved=$state.Items[0].SavedPath
   [void][IO.Directory]::CreateDirectory((Join-Path $script:displayUiRoot 'Logs'))
   $log=Join-Path $script:displayUiRoot ('Logs\'+(Get-Date -Format yyyy-MM-dd)+'.jsonl');$lock=[IO.File]::Open($log,'OpenOrCreate','ReadWrite','None')
   try{
    $ui.TargetBox.Text=$script:displayUiFolder;Click $ui.ApplyButton;Wait-Work
    Require ($ui.StatusText.Text.StartsWith('アイコンを設定したよ。見た目が変わらないときは、少し待ってみてね。') -and $ui.StatusText.Text.Contains('操作ログを記録できなかったよ。')) 'GUI lost success or warning'
    Require ($state.CurrentId -eq $id -and $state.Items[0].SavedPath -eq $saved -and $ui.ApplyMoreButton.Visibility -eq 'Visible' -and $state.Succeeded -eq 1) 'GUI lost state or More'
   }finally{$lock.Dispose();$state.AllowClose=$true;$window.Close()}
  }
 }
 $cases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'display-outcome.json') -Encoding UTF8
 Write-Host ('RESULT '+@($cases|Where-Object Status -eq PASS).Count+' / '+$cases.Count+'; '+$run.Results)
 if(@($cases|Where-Object Status -eq FAIL).Count){exit 1}
} $app $run
