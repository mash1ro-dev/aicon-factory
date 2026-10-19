#requires -Version 5.1
param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$app=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
$fixture=Join-Path $temp ('afsafe-'+[guid]::NewGuid().ToString('N').Substring(0,8))
if(Test-Path -LiteralPath $fixture){throw 'Fixture collision'}
[void][IO.Directory]::CreateDirectory($fixture)
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
@{Purpose='AiconFactory.InstallerSafety';Root=$fixture}|ConvertTo-Json|Set-Content (Join-Path $fixture '.owner.json') -Encoding UTF8
$cases=New-Object 'System.Collections.Generic.List[object]'
function Need($ok,[string]$why){if(-not $ok){throw $why}}
function Put([string]$path,[string]$text){
 $full=[IO.Path]::GetFullPath($path)
 Need ($full.StartsWith($fixture+'\',[StringComparison]::OrdinalIgnoreCase)) 'Write escaped owned fixture'
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
 [IO.File]::WriteAllText($full,$text,[Text.UTF8Encoding]::new($true))
}
function Seed {
 $id=[guid]::NewGuid().ToString('N').Substring(0,6);$pkg=Join-Path $fixture ('p'+$id);$root=Join-Path $fixture ('r'+$id)
 foreach($name in @('Install.ps1','Start.ps1','aicon.ps1','README.md','LICENSE','CHANGELOG.md')){
  Put (Join-Path $pkg $name) ([IO.File]::ReadAllText((Join-Path $app $name)))
  Put (Join-Path $root $name) ('old-'+$name)
 }
 $module=@'
function aicon { 'new' }
function New-AiconFactoryIcon { }
function Set-AiconFactoryIcon { }
function Restore-AiconFactoryIcon { }
function Start-AiconFactory { }
Export-ModuleMember -Function aicon,New-AiconFactoryIcon,Set-AiconFactoryIcon,Restore-AiconFactoryIcon,Start-AiconFactory
'@
 Put (Join-Path $pkg 'App\AiconFactory.psm1') $module
 Put (Join-Path $root 'App\AiconFactory.psm1') ($module.Replace("'new'","'old'"))
 Put (Join-Path $root '.aicon-install.json') '{"ProductId":"BLUEFATHOM.AiconFactory","Version":"0.1.0"}'
 foreach($p in @('settings.json','Library\ICO\keep.ico','Library\Source\keep.png','Backup\original\manifest.json','Backup\original\original','Logs\keep.log')){Put (Join-Path $root $p) ('retained-'+$p)}
 [pscustomobject]@{Package=$pkg;Root=$root;Installer=(Join-Path $pkg 'Install.ps1')}
}
function Snapshot([string]$root){
 @(Get-ChildItem -LiteralPath $root -Recurse -Force|Sort-Object FullName|ForEach-Object {
  [pscustomobject]@{Path=$_.FullName;Directory=$_.PSIsContainer;Hash=$(if(-not $_.PSIsContainer){(Get-FileHash -LiteralPath $_.FullName).Hash});Utc=$(if(-not $_.PSIsContainer){$_.LastWriteTimeUtc.ToString('o')});Attributes=[long]$_.Attributes}
 })
}
function Intact($before,[string]$except=''){
 foreach($r in $before){if($r.Path -eq $except){continue};Need (Test-Path -LiteralPath $r.Path) ('Original missing: '+$r.Path)
  if(-not $r.Directory){$f=Get-Item -LiteralPath $r.Path -Force;Need ((Get-FileHash -LiteralPath $r.Path).Hash -eq $r.Hash -and $f.LastWriteTimeUtc.ToString('o') -eq $r.Utc -and [long]$f.Attributes -eq $r.Attributes) ('Original changed: '+$r.Path)}
 }
}
function Reject($f,[string]$reason){
 $before=Snapshot $f.Root;$errorText=''
 try{& $f.Installer -Root $f.Root|Out-Null}catch{$errorText=$_.Exception.Message}
 Need ($errorText.Contains($reason)) ('Missing expected refusal: '+$reason+'; '+$errorText)
 Intact $before
 Need ((ConvertTo-Json @(Snapshot $f.Root) -Depth 4 -Compress) -ceq (ConvertTo-Json @($before) -Depth 4 -Compress)) 'Refusal created or changed fixture paths'
}
function Check([string]$name,[scriptblock]$body){
 Remove-Module AiconFactory -Force -ErrorAction SilentlyContinue
 try{&$body;$cases.Add(@{Name=$name;Status='PASS'});Write-Host ('PASS '+$name)}catch{$cases.Add(@{Name=$name;Status='FAIL';Error=$_.Exception.Message});Write-Host ('FAIL '+$name+': '+$_.Exception.Message)}
 finally{Remove-Module AiconFactory -Force -ErrorAction SilentlyContinue}
}
function RelativeAt($f,[int]$length,[string]$area,[bool]$directory){
 $base=if($area -eq 'backup'){Join-Path $f.Root 'Backup\Install-20000101-000000-0000000000'}else{Join-Path $f.Root '.aicon-stage-20000101-000000-0000000000\failed-new'}
 $prefix=Join-Path $base 'App\';$suffix=if($directory){''}else{'.txt'}
 $leaf=('x'*($length-$prefix.Length-$suffix.Length))+$suffix
 Need ($leaf.Length -gt 0 -and $leaf.Length -le 255) 'Invalid fixture leaf length'
 $relative='App\'+$leaf;Need ((Join-Path $base $relative).Length -eq $length) 'Boundary fixture calculation'
 return $relative
}
function FailFinal($f){$p=Join-Path $f.Package 'App\AiconFactory.psm1';Put $p ('if ($PSScriptRoot -notmatch ''\.aicon-stage-'') { throw ''Injected final import failure'' }'+[Environment]::NewLine+[IO.File]::ReadAllText($p))}
function AssertRollback($f,$before){
 $errorText='';try{&$f.Installer -Root $f.Root|Out-Null}catch{$errorText=$_.Exception.Message}
 Need ($errorText.Contains('Injected')) ('Injected failure not reached: '+$errorText);Intact $before
 Need ((aicon) -eq 'old') 'Old module not restored'
 $record=Get-ChildItem (Join-Path $f.Root 'Backup') -Recurse -Filter recovery.json|Select-Object -First 1
 Need ($null -ne $record) 'Recovery record missing before rollback'
 $map=Get-Content $record.FullName -Raw -Encoding UTF8|ConvertFrom-Json
 Need ($map.Status -eq 'Prepared' -and $map.Files -contains 'App') 'Prepared recovery record invalid'
 Need (-not(Test-Path (Join-Path $f.Root '.aicon-install.lock'))) 'Owned lock not released'
}
Check 'normal update preserves settings ICO originals backups and logs and retains old managed bytes' {
 $f=Seed;$before=Snapshot $f.Root;$result=&$f.Installer -Root $f.Root
 Need ((aicon) -eq 'new') 'New module unavailable'
 $user=@($before|Where-Object {$_.Path -notmatch '\\(App|Install\.ps1|Start\.ps1|aicon\.ps1|README\.md|LICENSE|CHANGELOG\.md|\.aicon-install\.json)(\\|$)'})
 Intact $user
 foreach($r in $before|Where-Object {-not $_.Directory -and $_ -notin $user}){Need ((Get-FileHash (Join-Path $result.BackupPath $r.Path.Substring($f.Root.Length+1))).Hash -eq $r.Hash) 'Old backup differs'}
}
Check '259 UTF16 file path accepted including failed-new destination' {
 $f=Seed;$relative=RelativeAt $f 259 'failed' $false;Put (Join-Path $f.Package $relative) 'boundary'
 &$f.Installer -Root $f.Root|Out-Null;Need ([IO.File]::ReadAllText((Join-Path $f.Root $relative)) -eq 'boundary') 'Accepted payload missing'
}
Check '260 UTF16 file path refused before any existing path changes' {
 $f=Seed;$relative=RelativeAt $f 260 'failed' $false;Put (Join-Path $f.Package $relative) 'boundary';Reject $f 'パスが長すぎます'
}
Check '247 UTF16 directory path accepted including failed-new destination' {
 $f=Seed;$relative=RelativeAt $f 247 'failed' $true;[void][IO.Directory]::CreateDirectory((Join-Path $f.Package $relative))
 &$f.Installer -Root $f.Root|Out-Null;Need (Test-Path (Join-Path $f.Root $relative) -PathType Container) 'Accepted directory missing'
}
Check '248 UTF16 directory path refused before any existing path changes' {
 $f=Seed;$relative=RelativeAt $f 248 'failed' $true;[void][IO.Directory]::CreateDirectory((Join-Path $f.Package $relative));Reject $f 'パスが長すぎます'
}
Check 'old-only file backup overflow refused before any existing path changes' {
 $f=Seed;$relative=RelativeAt $f 260 'backup' $false;Put (Join-Path $f.Root $relative) 'old-only';Reject $f 'パスが長すぎます'
}
Check 'old-only directory backup overflow refused before any existing path changes' {
 $f=Seed;$relative=RelativeAt $f 248 'backup' $true;[void][IO.Directory]::CreateDirectory((Join-Path $f.Root $relative));Reject $f 'パスが長すぎます'
}
Check 'surrogate pair counts two UTF16 units in path refusal' {
 $f=Seed;$relative=RelativeAt $f 260 'failed' $false;$relative=$relative.Substring(0,$relative.Length-6)+[char]::ConvertFromUtf32(0x1F680)+'.txt'
 Put (Join-Path $f.Package $relative) 'unicode';Reject $f 'パスが長すぎます'
}
Check 'long requested root refused without creating destination' {
 $f=Seed;$root=Join-Path $fixture ('long-'+('r'*(219-$fixture.Length-6)));Need ($root.Length -eq 219) 'Root length'
 $errorText='';try{&$f.Installer -Root $root|Out-Null}catch{$errorText=$_.Exception.Message}
 Need ($errorText.Contains('パスが長すぎます') -and -not(Test-Path $root)) 'Long root not safely refused'
}
Check 'locked old file refused before any existing path changes' {
 $f=Seed;$h=[IO.File]::Open((Join-Path $f.Root 'README.md'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{Reject $f '事前確認'}finally{$h.Dispose()}
}
Check 'locked old directory refused before any existing path changes' {
 $f=Seed;$h=[AiconInstallPreflightV011]::DirectoryLease((Join-Path $f.Root 'App'))
 try{Reject $f '事前確認'}finally{$h.Dispose()}
}
Check 'unreadable in-use source refused before any existing path changes' {
 $f=Seed;$h=[IO.File]::Open((Join-Path $f.Package 'README.md'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
 try{Reject $f '事前確認'}finally{$h.Dispose()}
}
Check 'existing Logs file refuses update before creating work paths' {
 $f=Seed;# Use a fixture-owned managed directory move, never delete an existing tree.
 [IO.Directory]::Move((Join-Path $f.Root 'Logs'),(Join-Path $f.Root 'kept-logs'));Put (Join-Path $f.Root 'Logs') 'blocked';Reject $f '種類が一致しません'
}
Check 'failed-new preparation failure leaves every old file intact' {
 $f=Seed;$before=Snapshot $f.Root;$p=Join-Path $f.Package 'App\AiconFactory.psm1'
 Put $p ('[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) ''failed-new''),''fixture blocker'')'+[Environment]::NewLine+[IO.File]::ReadAllText($p))
 $errorText='';try{&$f.Installer -Root $f.Root|Out-Null}catch{$errorText=$_.Exception.Message}
 Need ($errorText.Length -gt 0) 'Expected preparation failure';Intact $before
 Need (@(Get-ChildItem (Join-Path $f.Root 'Backup') -Recurse -Filter 'AiconFactory.psm1').Count -eq 0) 'Old files moved before preparation finished'
}
Check 'partial commit exception restores old bytes timestamps settings and backups' {
 $f=Seed;$before=Snapshot $f.Root;$s=[IO.File]::ReadAllText($f.Installer);$needle='            Move-Exact (Join-Path $stage $name) $target'
 Need ($s.Contains($needle)) 'Injection point missing';Put $f.Installer ($s.Replace($needle,'            if ($name -eq ''Start.ps1'') { throw ''Injected partial commit failure'' }'+[Environment]::NewLine+$needle))
 AssertRollback $f $before
}
Check 'final import exception restores old bytes and prepared recovery record' {
 $f=Seed;$before=Snapshot $f.Root;FailFinal $f;AssertRollback $f $before
 Need (@(Get-ChildItem $f.Root -Directory -Filter '.aicon-stage-*'|ForEach-Object {Get-Item (Join-Path $_.FullName 'failed-new\App\AiconFactory.psm1')}).Count -eq 1) 'Failed new payload not retained'
}
Check '259 UTF16 rollback destination is actually usable on failure' {
 $f=Seed;$relative=RelativeAt $f 259 'failed' $false;Put (Join-Path $f.Package $relative) 'boundary';$before=Snapshot $f.Root;FailFinal $f;AssertRollback $f $before
 $stage=Get-ChildItem $f.Root -Directory -Filter '.aicon-stage-*'|Select-Object -First 1
 $saved=Join-Path (Join-Path $stage.FullName 'failed-new') $relative
 Need ($saved.Length -eq 259 -and [IO.File]::ReadAllText($saved) -eq 'boundary') 'Boundary rollback payload missing'
}
Check 'one failed new-payload retirement does not skip other old-file restorations' {
 $f=Seed;$before=Snapshot $f.Root;FailFinal $f;$s=[IO.File]::ReadAllText($f.Installer)
 $needle='try { Move-Exact (Join-Path $installRoot $name) (Join-Path $failedNew $name) }'
 Need ($s.Contains($needle)) 'Recovery injection point missing'
 Put $f.Installer ($s.Replace($needle,'try { if ($name -eq ''README.md'') { throw ''Injected retirement failure'' }; Move-Exact (Join-Path $installRoot $name) (Join-Path $failedNew $name) }'))
 $errorText='';try{&$f.Installer -Root $f.Root|Out-Null}catch{$errorText=$_.Exception.Message}
 Need ($errorText.Contains('自動復元にも問題') -and $errorText.Contains('Injected retirement failure')) ('Partial recovery not reported: '+$errorText)
 Intact $before (Join-Path $f.Root 'README.md')
 $old=Get-ChildItem (Join-Path $f.Root 'Backup') -Recurse -File -Filter README.md|Select-Object -First 1
 Need ($null -ne $old -and [IO.File]::ReadAllText($old.FullName) -eq 'old-README.md') 'Unrestored old file not retained'
}
$result=@{Fixture=$fixture;Passed=@($cases|Where-Object Status -eq PASS).Count;Failed=@($cases|Where-Object Status -eq FAIL).Count;Cases=$cases.ToArray();Runtime=$PSVersionTable.PSVersion.ToString();InstallerSHA256=(Get-FileHash (Join-Path $app 'Install.ps1')).Hash;RealUserDataWritten=$false;SystemSettingsChanged=$false}
$result|ConvertTo-Json -Depth 6|Set-Content (Join-Path $EvidenceDirectory 'installer-safety.json') -Encoding UTF8
Write-Host ('RESULT '+$result.Passed+' PASS / '+$result.Failed+' FAIL; '+$fixture)
if($result.Failed){exit 1}
