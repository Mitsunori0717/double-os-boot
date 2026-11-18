#requires -Version 5.1
$ErrorActionPreference='Stop'
$exe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($test in @('test-purpose.ps1','test-inventory.ps1','test-uninstall.ps1','test-integration.ps1','test-network.ps1','test-network-view.ps1','test-ui.ps1','test-package.ps1')){
    & $exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw ('TEST_FAILED: '+$test)}
}
Write-Output 'All app-manager non-destructive tests passed. No installed program was inventoried or uninstalled.'
