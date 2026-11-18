#requires -Version 5.1
# File fixtures and mocked Hyper-V only. Does not create/stop real VMs or open raw devices.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($test in @('run-tests.ps1','test-hyperv-recovery.ps1','test-hyperv-wiring.ps1','test-windows-inventory.ps1','test-windows-plan.ps1','test-windows-integration.ps1','test-hyperv-v2.ps1','test-windows-expanded-plan.ps1')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw ('Validation failed: '+$test+' exit='+$LASTEXITCODE)}
}
$python=Get-Command python -ErrorAction Stop
& $python.Source -B -m unittest discover -s $PSScriptRoot -p 'test_*.py' -v
if($LASTEXITCODE -ne 0){throw ('Python validation failed: exit='+$LASTEXITCODE)}
$setup=Join-Path (Split-Path $root -Parent) 'setup\tests\run-tests.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup
if($LASTEXITCODE -ne 0){throw ('Setup regression validation failed: exit='+$LASTEXITCODE)}
Write-Host 'All nonhardware validation commands passed. See explicit skipped cases above; no real SSD or guest boot was tested.'
