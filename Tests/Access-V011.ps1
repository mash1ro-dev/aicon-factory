param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1');$run=New-OwnedTestRun $app
Import-Module (Join-Path $app 'App\AiconFactory.psm1') -Force
& (Get-Module AiconFactory) {
 param($run)
 function Require([bool]$ok,[string]$why){if(-not $ok){throw $why}}
 function Reject($body){$caught=$false;try{&$body|Out-Null}catch{$caught=$true};Require $caught 'Expected access failure'}
 $results=@();$dir=Join-Path $run.Root 'Denied';[void][IO.Directory]::CreateDirectory($dir)
 $sentinel=Join-Path $dir 'unchanged.txt';[IO.File]::WriteAllText($sentinel,'preserve');$hash=(Get-FileHash $sentinel).Hash
 $acl=Get-Acl -LiteralPath $dir;$original=$acl.GetSecurityDescriptorSddlForm('All')
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
 try{
  $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]'ReadData,WriteData,AppendData',[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
  $acl.AddAccessRule($rule);Set-Acl -LiteralPath $dir -AclObject $acl
  Reject {Save-AiconPreviewBytes ([byte[]]@(1,2,3)) $dir 'denied'}
  $state=New-AiconSession -Root $run.Root -UserDataRoot $run.Root;$state.LastIcoSavedDirectory=$dir;Reject {Get-AiconSavedDirectory $state}
  $results+=@{Name='4/8c actual access-denied save and history opening are rejected';Passed=$true}
 }finally{
  $restore=[Security.AccessControl.DirectorySecurity]::new();$restore.SetSecurityDescriptorSddlForm($original);Set-Acl -LiteralPath $dir -AclObject $restore
 }
 Require ((Get-FileHash $sentinel).Hash -eq $hash -and @(Get-ChildItem $dir -Force).Count -eq 1) 'Denied attempt mutated files'
 $results+=@{Name='4 failed save preserves existing bytes and leaves no partial ICO';Passed=$true}
 # Simulate an empty lock file left by an exited process, then an active lock.
 $lockPath=Join-Path $run.Root 'settings.json.lock';[IO.File]::WriteAllText($lockPath,'')
 Write-AiconSettings $run.Root @{Other='keep';LastIcoSavedDirectory=$dir}
 $lock=[IO.File]::Open($lockPath,'Open','ReadWrite','None')
 try{Reject {Write-AiconSettings $run.Root @{Other='lost'}}}finally{$lock.Dispose()}
 Require ((Read-AiconSettings $run.Root).Data.Other -eq 'keep') 'Concurrent writer overwrote config'
 Write-AiconSettings $run.Root @{IcoOutputDirectoryPreference=$dir}
 Require ((Read-AiconSettings $run.Root).Data.Other -eq 'keep') 'Unknown properties lost'
 $results+=@{Name='8c stale lock recovers, active lock refuses safely, later write succeeds';Passed=$true}
 $results|ConvertTo-Json|Set-Content (Join-Path $run.Results 'access.json') -Encoding UTF8
 Write-Host ('RESULT 3 PASS; '+$run.Results)
} $run
