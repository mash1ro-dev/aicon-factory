param([string]$Root,[string]$Phase)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1')
if(-not $Phase){
 $run=New-OwnedTestRun $app;$Root=$run.Root
 foreach($name in @('A','B','C','Links')){[void][IO.Directory]::CreateDirectory((Join-Path $Root $name))}
 Add-Type -AssemblyName System.Drawing;$im=[Drawing.Bitmap]::new(100,80);$g=[Drawing.Graphics]::FromImage($im)
 try{$g.Clear([Drawing.Color]::CornflowerBlue);$im.Save((Join-Path $Root 'source.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$im.Dispose()}
 [IO.File]::WriteAllText((Join-Path $Root 'dummy.exe'),'Owned fixture; never execute')
 $shell=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe';$results=@()
 foreach($step in @('SaveA','ReadA','ApplyB','ReadAfterB','SaveC','ReadC','Denied','Missing','Invalid','Corrupt','First')){
  $restoreAcl=$null
  if($step -eq 'Denied'){$denied=Join-Path $Root 'C';$acl=Get-Acl $denied;$restoreAcl=$acl.GetSecurityDescriptorSddlForm('All');$rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.FileSystemRights]'ReadData,WriteData,AppendData',[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny);$acl.AddAccessRule($rule);Set-Acl $denied $acl}
  if($step -eq 'Missing'){Rename-Item -LiteralPath (Join-Path $Root 'C') -NewName 'C-moved'}
  if($step -eq 'Invalid'){[IO.File]::WriteAllText((Join-Path $Root 'settings.json'),'{"LastIcoSavedDirectory":"..\\bad","IcoOutputDirectoryPreference":"..\\bad"}')}
  if($step -eq 'Corrupt'){[IO.File]::WriteAllText((Join-Path $Root 'settings.json'),'{broken')}
  if($step -eq 'First'){Rename-Item -LiteralPath (Join-Path $Root 'settings.json') -NewName 'settings.corrupt.preserved.json'}
  $out=Join-Path $run.Results ($step+'.log');$err=Join-Path $run.Results ($step+'.stderr.log')
  $args='-NoProfile -STA -File "'+$PSCommandPath+'" -Root "'+$Root+'" -Phase '+$step
  try{$p=Start-Process $shell -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err;$null=$p.Handle
   if(-not $p.WaitForExit(90000)){$p.Kill();throw ('Owned child timed out '+$step)}
  }finally{if($restoreAcl){$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetSecurityDescriptorSddlForm($restoreAcl);Set-Acl $denied $acl}}
  $resultFile=Join-Path $Root ($step+'.json')
  $ok=$p.ExitCode -eq 0 -and (Test-Path $resultFile)
  $results+=[pscustomobject]@{Phase=$step;Passed=$ok;ProcessId=$p.Id;Exit=$p.ExitCode;Evidence=$resultFile}
  Write-Host ($(if($ok){'PASS '}else{'FAIL '})+$step+' PID '+$p.Id)
  if(-not $ok){Get-Content $err -Encoding UTF8}
 }
 $results|ConvertTo-Json -Depth 6|Set-Content (Join-Path $run.Results 'restart.json') -Encoding UTF8
 Write-Host ('RESULT '+@($results|Where-Object Passed).Count+' / 11; '+$run.Results)
 if(@($results|Where-Object {-not $_.Passed}).Count){exit 1};exit 0
}
$Root=Assert-OwnedTestRoot $app $Root
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$root,$phase)
 function Require([bool]$ok,[string]$why){if(-not $ok){throw $why}}
 . (Join-Path $app 'App\Gui.ps1')
 Show-AiconFactoryWindow -Root $root -UserDataRoot $root -Harness {
  function Click($b){$b.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
  function Wait-Work {$end=[DateTime]::UtcNow.AddSeconds(60);while($state.Busy -and [DateTime]::UtcNow -lt $end){&$actions.Poll;$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background);[Threading.Thread]::Sleep(10)};Require (-not $state.Busy -and $state.Failed -eq 0) 'Worker failed'}
  $window.Show();$window.UpdateLayout();$script:Opened='';$state.OpenFolder={param($path) $script:Opened=$path};$state.DialogResponder={@{Accepted=$true;Remember=$false}}
  if($phase -in @('SaveA','SaveC')){
   $dest=Join-Path $root $(if($phase -eq 'SaveA'){'A'}else{'C'});Set-AiconOutputPreference $state $dest
   &$actions.Add @((Join-Path $root 'source.png'));Click $ui.GenerateButton;Wait-Work;Click $ui.SaveButton;Wait-Work
   Require ([IO.File]::Exists($state.Items[0].SavedPath)) 'No saved ICO'
  }elseif($phase -in @('ReadA','ReadAfterB','ReadC')){
   $dest=Join-Path $root $(if($phase -eq 'ReadC'){'C'}else{'A'})
   Require ($state.Items.Count -eq 0 -and $state.LastIcoSavedDirectory -eq $dest -and $ui.IcoOutputBox.Text -eq $dest) 'History not restored'
   Click $ui.OpenLocationButton;Require ($script:Opened -eq $dest) 'Reopen destination mismatch'
  }elseif($phase -eq 'ApplyB'){
   # Exercise the ordinary save-before-apply flow in this same process.
   &$actions.Add @((Join-Path $root 'source.png'));Click $ui.GenerateButton;Wait-Work
   Click $ui.SaveButton;Wait-Work;Require ([IO.File]::Exists($state.Items[0].SavedPath)) 'Apply requires an actual GUI save'
   $ui.TargetBox.Text=Join-Path $root 'B';Click $ui.ApplyButton;Wait-Work
   $ui.TargetBox.Text=Join-Path $root 'dummy.exe';$ui.DestinationBox.SelectedIndex=2;$ui.OutputDirectoryBox.Text=Join-Path $root 'Links';Click $ui.ApplyButton;Wait-Work
   Require ((Test-Path (Join-Path $root 'B\desktop.ini')) -and @(Get-ChildItem (Join-Path $root 'Links') -Filter '*.lnk').Count -eq 1) 'Apply did not complete'
   Require ($state.LastIcoSavedDirectory -eq (Join-Path $root 'A')) 'Apply overwrote ICO history'
  }elseif($phase -in @('Denied','Missing','Invalid')){
   Click $ui.OpenLocationButton;Require (-not $script:Opened) 'Invalid history fell back'
   Require ($ui.StatusText.Text.Contains('開けません')) 'Missing history message'
  }elseif($phase -eq 'Corrupt'){
   Require ([bool]$state.Warning -and -not $ui.OpenLocationButton.IsEnabled -and [IO.File]::ReadAllText((Join-Path $root 'settings.json')) -eq '{broken') 'Corrupt settings handling'
  }else{Require (-not $ui.OpenLocationButton.IsEnabled -and -not $state.LastIcoSavedDirectory) 'Fresh process has history'}
  $dpi=[Windows.Media.VisualTreeHelper]::GetDpi($window)
  $cfg=Join-Path $root 'settings.json';$configText=if(Test-Path $cfg){[IO.File]::ReadAllText($cfg)}else{''}
  [ordered]@{Phase=$phase;PID=$PID;Items=$state.Items.Count;LastIcoSavedDirectory=$state.LastIcoSavedDirectory;IcoOutputDirectoryPreference=$state.IcoOutputDirectoryPreference;Displayed=$ui.IcoOutputBox.Text;Opened=$script:Opened;Status=$ui.StatusText.Text;SettingsJson=$configText;DpiX=$dpi.PixelsPerInchX;DpiY=$dpi.PixelsPerInchY}|ConvertTo-Json|Set-Content (Join-Path $root ($phase+'.json')) -Encoding UTF8
  $state.AllowClose=$true;$window.Close()
 }
} $app $Root $Phase
