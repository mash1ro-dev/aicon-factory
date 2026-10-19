#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]param([Parameter(Mandatory)][string]$ResultDirectory)
$ErrorActionPreference='Stop'
$app=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'SafeSandbox.ps1')
Remove-OwnedTestRun -AppRoot $app -ResultDirectory $ResultDirectory -WhatIf:$WhatIfPreference -Confirm:$false
