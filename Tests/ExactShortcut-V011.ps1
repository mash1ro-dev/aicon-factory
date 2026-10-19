param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($app,$run)
 . (Join-Path $app 'Tests\Automation\ExactShortcutProbe.ps1')
 $cases=[Collections.Generic.List[object]]::new()
 function Require($ok,$why){if(-not $ok){throw $why}}
 function Reject($action){$caught=$false;try{&$action|Out-Null}catch{$caught=$true};Require $caught 'Expected rejection'}
 function Check($name,$body){try{&$body;$cases.Add(@{Name=$name;Status='PASS'});Write-Host ('PASS '+$name)}catch{$cases.Add(@{Name=$name;Status='FAIL';Error=$_.ToString()});Write-Host ('FAIL '+$name+': '+$_)}}
 $fixture=Join-Path $run.Root 'Fixtures';$stage=Join-Path $run.Root 'Stage';$out=Join-Path $run.Root 'Output';$data=Join-Path $run.Root 'Data'
 foreach($p in @($fixture,$stage,$out,$data)){[void][IO.Directory]::CreateDirectory($p)}
 $exe=Join-Path $fixture 'never-execute.exe';[IO.File]::WriteAllText($exe,'owned dummy, never execute')
 # Generate a synthetic fixture inside this owned run; no retained user/test ICO.
 Add-Type -AssemblyName System.Drawing
 $png=Join-Path $fixture 'fixture.png';$bitmap=[Drawing.Bitmap]::new(72,48);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.Clear([Drawing.Color]::Transparent);$graphics.FillEllipse([Drawing.Brushes]::SteelBlue,8,4,40,40);$bitmap.Save($png,[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 Initialize-AiconEngine;$ico=Join-Path $fixture 'source.ico';[IO.File]::WriteAllBytes($ico,([Aicon.ImageEngine]::Process($png)).Ico)
 $icoHash=Get-AiconHash $ico;$exeHash=Get-AiconHash $exe
 $prepared=Set-AiconFactoryIcon -Icon $ico -Target $exe -Root $data -Destination Custom -OutputDirectory $stage -ShortcutName 'payload'
 $script:probeArgs=@{PreparedLink=$prepared.TargetPath;Target=$exe;Icon=$ico;Root=$data;ExpectedIconHash=$icoHash;ExpectedLinkHash=$prepared.TargetHash;ExpectedPathIdentity=(Get-AiconApplyPathIdentity $ico $exe $out $data)}
 Check 'Exact create succeeds; actual LNK properties and bytes match application output' {
  $path=Join-Path $out 'exact.lnk';$r=Write-AiconExactProbeFile @script:probeArgs -ExactPath $path
  Require ($r.Complete -and (Get-AiconHash $path) -eq $prepared.TargetHash) 'Commit/hash'
  $shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($path)
  try{Require ($link.TargetPath -eq $exe -and $link.IconLocation -eq ($ico+',0')) 'Link properties'}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
 }
 Check 'Existing nonempty exact name is unchanged and never numbered' {
  $path=Join-Path $out 'occupied.lnk';[IO.File]::WriteAllText($path,'keep');$hash=Get-AiconHash $path
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath $path}
  Require ((Get-AiconHash $path) -eq $hash -and -not (Test-Path (Join-Path $out 'occupied_02.lnk'))) 'Existing output changed/numbered'
 }
 Check 'Existing empty exact name is preserved and never deleted' {
  $path=Join-Path $out 'empty.lnk';[IO.File]::WriteAllBytes($path,[byte[]]@())
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath $path}
  Require ((Test-Path $path) -and (Get-Item $path).Length -eq 0) 'Empty existing file removed'
 }
 Check 'Competitor after preliminary check wins; atomic CreateNew rejects without overwrite' {
  $script:racePath=Join-Path $out 'race.lnk'
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath $script:racePath -BeforeCreate {[IO.File]::WriteAllText($script:racePath,'competitor')}}
  Require ([IO.File]::ReadAllText($script:racePath) -eq 'competitor' -and -not (Test-Path (Join-Path $out 'race_02.lnk'))) 'Race overwritten/numbered'
 }
 Check 'Competing directory after check is preserved; no suffix output' {
  $script:racePath=Join-Path $out 'directory.lnk'
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath $script:racePath -BeforeCreate {[void][IO.Directory]::CreateDirectory($script:racePath)}}
  Require ([IO.Directory]::Exists($script:racePath) -and -not (Test-Path (Join-Path $out 'directory_02.lnk'))) 'Directory changed'
 }
 Check 'Exclusive new handle prevents competing write and rename during commit' {
  $script:lockedPath=Join-Path $out 'exclusive.lnk'
  Write-AiconExactProbeFile @script:probeArgs -ExactPath $script:lockedPath -WhileExclusive {
   Reject {[IO.File]::WriteAllText($script:lockedPath,'forbidden')}
   Reject {[IO.File]::Move($script:lockedPath,$script:lockedPath+'.moved')}
  }|Out-Null
  Require ((Get-AiconHash $script:lockedPath) -eq $prepared.TargetHash) 'Exclusive protection failed'
 }
 Check 'Injected failure after creation retains owned incomplete output; no automatic deletion' {
  $path=Join-Path $out 'incomplete.lnk'
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath $path -WhileExclusive {throw 'intentional test failure'}}
  Require ((Test-Path $path) -and (Get-Item $path).Length -eq 0) 'Incomplete result auto-deleted'
 }
 Check 'Preexisting foreign temporary-looking file is preserved; no output-directory temp generated' {
  $foreign=Join-Path $out '.aicon-existing.lnk';[IO.File]::WriteAllText($foreign,'keep foreign temp');$hash=Get-AiconHash $foreign
  Write-AiconExactProbeFile @script:probeArgs -ExactPath (Join-Path $out 'temp-check.lnk')|Out-Null
  Require ((Get-AiconHash $foreign) -eq $hash -and @(Get-ChildItem $out -Filter '.aicon-*' -Force).Count -eq 1) 'Foreign temp changed or new temp created'
 }
 Check 'Real junction output is rejected and its destination untouched' {
  $foreignDir=Join-Path $run.Root 'Foreign';[void][IO.Directory]::CreateDirectory($foreignDir)
  $junction=Join-Path $run.Root 'Junction';New-Item -ItemType Junction -Path $junction -Target $foreignDir|Out-Null
  Reject {Write-AiconExactProbeFile @script:probeArgs -ExactPath (Join-Path $junction 'forbidden.lnk')}
  Require (@(Get-ChildItem $foreignDir -Force).Count -eq 0) 'Junction destination touched'
 }
 Check 'Inputs and prepared LNK remain unchanged; all outputs confined to owned run' {
  Require ((Get-AiconHash $ico) -eq $icoHash -and (Get-AiconHash $exe) -eq $exeHash -and (Get-AiconHash $prepared.TargetPath) -eq $prepared.TargetHash) 'Input/source change'
 }
 $cases|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'exact-shortcut.json') -Encoding UTF8
 Write-Host ('RESULT '+@($cases|Where-Object Status -eq PASS).Count+' / '+$cases.Count+'; '+$run.Results)
 if(@($cases|Where-Object Status -eq FAIL).Count){exit 1}
} $app $run
