#requires -Version 5.1
[CmdletBinding()]
param([Parameter()][string]$Root)
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = $PSScriptRoot }
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'App\AiconFactory.psm1') -Force -ErrorAction Stop
Start-AiconFactory -Root $Root
