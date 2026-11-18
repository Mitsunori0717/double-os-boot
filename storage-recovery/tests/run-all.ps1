#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportDirectory='',[switch]$RequireQemu)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $root 'tests\run-all.ps1') @PSBoundParameters
exit $LASTEXITCODE
