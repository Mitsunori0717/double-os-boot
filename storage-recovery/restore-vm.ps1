#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([Parameter(Mandatory)][string]$VhdxPath,[Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$VMName,[Parameter(Mandatory)][string]$VMRoot,[switch]$Create,[switch]$StartIsolated,[string[]]$DataVhdxPaths=@())
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HyperVRecovery.psm1') -Force
try {
    $profile=Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    $args=@{VhdxPath=$VhdxPath;Profile=$profile;VMName=$VMName;VMRoot=$VMRoot;Create=$Create;StartIsolated=$StartIsolated;DataVhdxPaths=$DataVhdxPaths}
    if($WhatIfPreference){$args.WhatIf=$true}
    if($PSBoundParameters.ContainsKey('Confirm')){$args.Confirm=$PSBoundParameters['Confirm']}
    Invoke-IsolatedVmRecovery @args|ConvertTo-Json -Depth 12
} catch {[Console]::Error.WriteLine(($_|Out-String));exit 1}
