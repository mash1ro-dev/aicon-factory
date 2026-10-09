#requires -Version 5.1
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compiler=Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$automation=[Management.Automation.PowerShell].Assembly.Location
if(-not(Test-Path -LiteralPath $compiler)){throw 'Existing .NET Framework compiler is unavailable'}
$output=Join-Path $root 'IconFactory.exe'
$temp=Join-Path $root ('IconFactory.build-'+[guid]::NewGuid().ToString('N')+'.exe')
try{
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ ('/out:'+$temp) ('/win32manifest:'+(Join-Path $root 'App\launcher.manifest')) ('/reference:'+$automation) /reference:System.Windows.Forms.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll (Join-Path $root 'App\Launcher.cs')
    if($LASTEXITCODE -ne 0){throw 'GUI launcher compilation failed'}
    if(Test-Path -LiteralPath $output){[IO.File]::Replace($temp,$output,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temp,$output)}
}finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
Get-FileHash -LiteralPath $output -Algorithm SHA256
