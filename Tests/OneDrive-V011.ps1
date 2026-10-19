param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 $script:CloudCases=[Collections.Generic.List[object]]::new()
 function Require($ok,$message){if(-not $ok){throw $message}}
 function Reject($body){$caught=$false;try{&$body|Out-Null}catch{$caught=$true};Require $caught 'Expected safe rejection'}
 function Check($name,$expectation,$method,$body){try{&$body;$script:CloudCases.Add(@{Name=$name;Expectation=$expectation;Method=$method;Status='PASS'});Write-Host ('PASS '+$name)}catch{$script:CloudCases.Add(@{Name=$name;Expectation=$expectation;Method=$method;Status='FAIL';Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 Initialize-AiconPathValidation
 Check 'Known Desktop and cloud ancestor metadata validate without writing' 'ReadOnlyValidation' 'ActualWindowsMetadata' {
  $desktop=Get-AiconDesktopDirectory;Require ($desktop -eq [Environment]::GetFolderPath('DesktopDirectory')) 'Known folder differs'
  $entries=[Aicon.PathValidation]::Inspect($desktop,$true);Require (@($entries|Where-Object Kind -eq Cloud).Count -ge 1) 'Expected actual cloud path'
  foreach($entry in $entries|Where-Object Kind -eq Cloud){Require ($entry.SyncRootHResult -eq 0 -and $entry.SyncRootFileId -ne 0 -and $entry.SyncRootReturnedLength -eq 8 -and [Aicon.PathValidation]::IsCloudTag($entry.ReparseTag)) 'Unverified cloud metadata'}
  $entries|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'desktop-readonly.json') -Encoding UTF8
 }
 for($n=0;$n -lt 16;$n++){
  Check ('Cloud tag variant '+$n+' with verified state/root accepted') 'PolicyAcceptance' 'SyntheticMetadataOnly' {
   $tag=[uint32](2415919130L+4096L*$n);Require ([Aicon.PathValidation]::Classify(1040,$tag,1,0,8,123) -eq 'Cloud') 'Cloud family decision'
  }
 }
 foreach($tag in @([uint32]2684354572L,[uint32]2684354563L,[uint32]2147483681L,[uint32]2415919132L,[uint32]2147483675L,[uint32]2415988762L)){
  Check ('Reject unsafe or unknown tag 0x{0:X8}' -f $tag) 'SafeRejection' 'SyntheticMetadataOnly' {Reject {[Aicon.PathValidation]::Classify(1040,$tag,1,0,8,123)}}
 }
 Check 'Reject cloud tag with denied/missing/invalid Windows verification' 'SafeRejection' 'SyntheticMetadataOnly' {
  Reject {[Aicon.PathValidation]::Classify(1040,2415919130,0,0,8,123)}
  Reject {[Aicon.PathValidation]::Classify(1040,2415919130,[uint32]::MaxValue,0,8,123)}
  Reject {[Aicon.PathValidation]::Classify(1040,2415919130,1,-2147024501,0,0)}
  Reject {[Aicon.PathValidation]::Classify(1040,2415919130,1,0,0,123)}
  Reject {[Aicon.PathValidation]::Classify(1040,2415919130,1,0,8,0)}
  Reject {[Aicon.PathValidation]::Classify(16,2415919130,1,0,8,123)}
 }
 Check 'Retain UNC, ADS, traversal, protected root and system rejection' 'SafeRejection' 'RealValidatorNoWrites' {
  foreach($p in @('\\server\share\x','C:relative','C:\x\..\y','C:\x:stream','C:\x\CON','C:\x.')){Reject {Get-AiconFullPath $p}}
  Reject {Assert-AiconWritableTarget 'C:\'};Reject {Assert-AiconWritableTarget $env:windir};Reject {Assert-AiconWritableTarget $env:ProgramFiles}
 }
 $fixture=Join-Path $run.Root 'Fixtures';$out=Join-Path $run.Root 'Output';$data=Join-Path $run.Root 'Data';$targetFolder=Join-Path $run.Root 'Folder'
 foreach($p in @($fixture,$out,$data,$targetFolder)){[void][IO.Directory]::CreateDirectory($p)}
 Add-Type -AssemblyName System.Drawing
 $source=Join-Path $fixture 'source.png';$b=[Drawing.Bitmap]::new(30,20);$g=[Drawing.Graphics]::FromImage($b);try{$g.Clear([Drawing.Color]::Coral);$b.Save($source,[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}
 $exe=Join-Path $fixture 'never-execute.exe';[IO.File]::WriteAllText($exe,'owned dummy');$exeHash=Get-AiconHash $exe;$sourceHash=Get-AiconHash $source
 $session=New-AiconSession -Root $data -UserDataRoot $data;Add-AiconInputs $session @($source);$item=Get-AiconCurrent $session;$item.Result=[Aicon.ImageEngine]::Process($source);Save-AiconSessionItem $session $item
 Check 'Ordinary-folder shortcut real create, collision and restore succeed' 'NormalSuccess' 'RealFilesystemAndWScriptShell' {
  $first=Set-AiconFactoryIcon -Icon $item.SavedPath -Target $exe -Root $data -Destination Custom -OutputDirectory $out -ShortcutName 'test'
  $second=Set-AiconFactoryIcon -Icon $item.SavedPath -Target $exe -Root $data -Destination Custom -OutputDirectory $out -ShortcutName 'test'
  Require ([IO.File]::Exists($first.TargetPath) -and $second.TargetPath.EndsWith('test_02.lnk')) 'Create/collision'
  $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($first.TargetPath);try{Require ($link.TargetPath -eq $exe -and $link.IconLocation.StartsWith($item.SavedPath)) 'Shortcut properties'}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
  Restore-AiconFactoryIcon -BackupId $first.BackupId -Root $data -Confirm:$false|Out-Null
  Require (-not [IO.File]::Exists($first.TargetPath) -and [IO.File]::Exists($second.TargetPath)) 'Restore scope'
 }
 $outside=Join-Path $run.Root 'EscapeFixture';[void][IO.Directory]::CreateDirectory($outside);$sentinel=Join-Path $outside 'keep.txt';[IO.File]::WriteAllText($sentinel,'keep');$sentinelHash=Get-AiconHash $sentinel
 Check 'Actual junction as target, ancestor, and output is rejected' 'SafeRejection' 'RealJunctionOwnedFixtures' {
  $junction=Join-Path $run.Root 'Junction';New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop|Out-Null
  Reject {Get-AiconFullPath $junction};Reject {Get-AiconFullPath (Join-Path $junction 'new\x.ico')}
  Reject {Set-AiconFactoryIcon -Icon $item.SavedPath -Target $exe -Root $data -Destination Custom -OutputDirectory $junction -ShortcutName 'forbidden'}
  Require ((Get-AiconHash $sentinel) -eq $sentinelHash -and @(Get-ChildItem $outside -Force).Count -eq 1) 'Junction destination modified'
 }
 Check 'Actual hard-linked output file is rejected' 'SafeRejection' 'RealHardLinkOwnedFixture' {
  $hard=Join-Path $fixture 'hard.exe';New-Item -ItemType HardLink -Path $hard -Target $exe|Out-Null;try{Reject {Get-AiconFullPath $hard}}finally{[IO.File]::Delete($hard)}
 }
 Check 'Held parent directories cannot be renamed during apply transaction' 'SafeRejection' 'RealDirectoryLeaseOwnedFixture' {
  $p=Join-Path $run.Root 'Pinned';[void][IO.Directory]::CreateDirectory($p);$lease=[Aicon.PathValidation]::LeaseDirectories([string[]]@($p));try{Reject {[IO.Directory]::Move($p,$p+'-moved')}}finally{$lease.Dispose()};Require ([IO.Directory]::Exists($p)) 'Parent changed'
 }
 Check 'Destination changed to a junction after confirmation is rejected' 'SafeRejection' 'RealSnapshotAndJunctionOwnedFixtures' {
  $dest=Join-Path $run.Root 'SwapDestination';[void][IO.Directory]::CreateDirectory($dest)
  $snap=New-AiconApplySnapshot $session $exe 'Custom' $dest 'blocked' 'same'
  [IO.Directory]::Move($dest,$dest+'-original');New-Item -ItemType Junction -Path $dest -Target $outside|Out-Null
  Require (-not (Test-AiconApplySnapshot $session $snap 'same')) 'Changed destination passed confirmation'
  $arguments=$snap.Arguments;Reject {Set-AiconFactoryIcon @arguments}
  Require (@(Get-ChildItem $outside -Force).Count -eq 1) 'Changed destination written'
 }
 Check 'Same path replaced by another ordinary directory is rejected by worker identity' 'SafeRejection' 'RealWorkerArgumentsOwnedFixtures' {
  $dest=Join-Path $run.Root 'SwapOrdinary';[void][IO.Directory]::CreateDirectory($dest);$snap=New-AiconApplySnapshot $session $exe 'Custom' $dest 'blocked' 'same'
  [IO.Directory]::Move($dest,$dest+'-original');[void][IO.Directory]::CreateDirectory($dest)
  Require (-not (Test-AiconApplySnapshot $session $snap 'same')) 'Replacement directory accepted'
  $arguments=$snap.Arguments;Reject {Set-AiconFactoryIcon @arguments};Require (@(Get-ChildItem $dest -Force).Count -eq 0) 'Worker wrote changed destination'
 }
 Check 'ICO modified after confirmation is rejected by worker hash' 'SafeRejection' 'RealWorkerArgumentsOwnedFixtures' {
  $snap=New-AiconApplySnapshot $session $exe 'Custom' $out 'changed-ico' 'same';$bytes=[IO.File]::ReadAllBytes($item.SavedPath)
  try{[IO.File]::WriteAllText($item.SavedPath,'changed');$arguments=$snap.Arguments;Reject {Set-AiconFactoryIcon @arguments};Require (-not [IO.File]::Exists((Join-Path $out 'changed-ico.lnk'))) 'Worker used changed ICO'}finally{[IO.File]::WriteAllBytes($item.SavedPath,$bytes)}
 }
 Check 'Inputs and saved seven-frame ICO remain intact' 'Preservation' 'RealHashesAndIcoHeader' {
  Require ((Get-AiconHash $exe) -eq $exeHash -and (Get-AiconHash $source) -eq $sourceHash) 'Input modified'
  $bytes=[IO.File]::ReadAllBytes($item.SavedPath);Require ([BitConverter]::ToUInt16($bytes,4) -eq 7 -and [Convert]::ToBase64String($bytes) -eq [Convert]::ToBase64String($item.Result.Ico)) 'Saved ICO changed'
 }
 $script:CloudCases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'onedrive.json') -Encoding UTF8
 Write-Host ('RESULT '+@($script:CloudCases|Where-Object Status -eq PASS).Count+' PASS / '+@($script:CloudCases|Where-Object Status -eq FAIL).Count+' FAIL; '+$run.Results)
 if(@($script:CloudCases|Where-Object Status -eq FAIL).Count){exit 1}
} $app $run
