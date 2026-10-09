#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Source,
    [string]$Name,
    [string]$Category,
    [string]$Root = $PSScriptRoot,
    [string]$Target,
    [ValidateSet('Desktop', 'SameFolder', 'Custom')][string]$Destination,
    [string]$OutputDirectory,
    [string]$ShortcutName
)
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'App\AiconFactory.psm1') -Force -ErrorAction Stop
$arguments = @{}
foreach ($key in $PSBoundParameters.Keys) { $arguments[$key] = $PSBoundParameters[$key] }
$arguments['Root'] = $Root
if ([string]::IsNullOrWhiteSpace($Source)) { Start-AiconFactory -Root $Root }
else { New-AiconFactoryIcon @arguments }
