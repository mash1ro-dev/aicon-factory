param()
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8
$app=Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Automation\SafeSandbox.ps1')
$run=New-OwnedTestRun $app;$records=@()
$shell=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Execute unchanged backend assertions; obsolete GUI assertions are accounted separately.
$variants=@(
 @('Extended','Extended.Windows.ps1','$guiBody=@',4,'if($failures.Count){exit 1}'),
 @('Batch','Batch.Windows.ps1','$guiRoot=Join-Path',10,'if($script:Failed.Count){exit 1}'),
 @('Aspect','Aspect.Windows.ps1',"Check 'WPF image controls",14,'if($script:failed){exit 1}'),
 @('DistributionUX','DistributionUX.Tests.ps1',"    It 'shows friendly startup",4,'}')
)
foreach($v in $variants){
 $src=[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('Automation\'+$v[1])))
 $at=$src.IndexOf($v[2]);if($at -lt 0){throw 'Regression boundary missing'}
 $src=$src.Substring(0,$at)+[Environment]::NewLine+$v[4]
 $src=$src.Replace('$PSScriptRoot',("'"+(Join-Path $PSScriptRoot 'Automation').Replace("'","''")+"'"))
 [IO.File]::WriteAllText((Join-Path $run.Root ($v[0]+'.ps1')),$src,[Text.UTF8Encoding]::new($true))
}
$suites=@(@('Core',(Join-Path $PSScriptRoot 'Core.Tests.ps1'),10),@('ImageEngine',(Join-Path $PSScriptRoot 'ImageEngine.Tests.ps1'),15),@('Safety',(Join-Path $PSScriptRoot 'Safety.Tests.ps1'),7))
foreach($v in $variants|Where-Object {$_[0] -ne 'DistributionUX'}){$suites+=,@($v[0],(Join-Path $run.Root ($v[0]+'.ps1')),$v[3])}
foreach($s in $suites){
 $out=Join-Path $run.Results ($s[0]+'.log');$err=Join-Path $run.Results ($s[0]+'.stderr.log')
 $args='-NoProfile -STA -File "'+$s[1]+'" -Root "'+$run.Root+'"'
 if($s[0] -notin @('Core','Safety')){$args+=' -AppRoot "'+$app+'"'}
 $p=Start-Process $shell -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err;$null=$p.Handle
 if(-not $p.WaitForExit(180000)){$p.Kill();throw 'Owned regression process timed out'}
 $lines=@(Get-Content $out -Encoding UTF8);$passes=@($lines|Where-Object {$_ -match '^PASS '}).Count;$failures=@($lines|Where-Object {$_ -match '^FAIL '}).Count
 $records+=[pscustomobject]@{Suite=$s[0];Passed=$passes;Failed=$failures;Expected=$s[2];Exit=$p.ExitCode;Complete=($p.ExitCode -eq 0 -and $passes -eq $s[2] -and $failures -eq 0)}
 Write-Host ($s[0]+': '+$passes+' PASS / '+$failures+' FAIL; exit '+$p.ExitCode)
}
Import-Module Pester -RequiredVersion 3.4.0
foreach($s in @(@('Supplement',14),@('SandboxSafety',7),@('DistributionUX',4))){
 $path=if($s[0] -eq 'DistributionUX'){Join-Path $run.Root 'DistributionUX.ps1'}else{Join-Path $PSScriptRoot ('Automation\'+$s[0]+'.Tests.ps1')}
 $r=Invoke-Pester -Script @{Path=$path;Parameters=@{AppRoot=$app;Root=$run.Root;ResultDirectory=$run.Results}} -PassThru -OutputFile (Join-Path $run.Results ($s[0]+'.xml')) -OutputFormat NUnitXml
 $records+=[pscustomobject]@{Suite=$s[0];Passed=$r.PassedCount;Failed=$r.FailedCount;Expected=$s[1];Complete=($r.PassedCount -eq $s[1] -and $r.FailedCount -eq 0)}
}
$records|ConvertTo-Json -Depth 5|Set-Content (Join-Path $run.Results 'regression.json') -Encoding UTF8
Write-Host ('RESULT '+($records.Passed|Measure-Object -Sum).Sum+' PASS; '+$run.Results)
if(@($records|Where-Object {-not $_.Complete}).Count){exit 1}
