#requires -Version 5.1
[CmdletBinding()]param([switch]$Demo)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'STA_REQUIRED: use start.cmd'}
Import-Module (Join-Path $PSScriptRoot 'AppManager.psm1') -Force
$form=New-AppManagerWindow -Demo:$Demo
[void]$form.ShowDialog()
$form.Dispose()
