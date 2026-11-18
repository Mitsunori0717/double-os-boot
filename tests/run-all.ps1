#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportDirectory='', [switch]$RequireQemu)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if (-not $ReportDirectory) {
    $ReportDirectory=Join-Path $root ('validation-results\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
}
$ReportDirectory=[IO.Path]::GetFullPath($ReportDirectory)
if (Test-Path -LiteralPath $ReportDirectory) { throw 'Use a new validation report directory.' }
New-Item -ItemType Directory -Path $ReportDirectory | Out-Null
$script:results=New-Object 'System.Collections.Generic.List[object]'
$started=[DateTime]::UtcNow.ToString('o')
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$python=$null

function Invoke-FileCheck([string]$Name,[string]$Executable,[string[]]$Arguments) {
    Write-Host ('Checking '+$Name)
    $log=Join-Path $ReportDirectory (($Name -replace '[^A-Za-z0-9_.-]','_')+'.txt')
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $oldPreference=$ErrorActionPreference
    $exitCode=1
    try {
        $ErrorActionPreference='Continue'
        $global:LASTEXITCODE=1
        & $Executable @Arguments *> $log
        # Windows PowerShell 5.1 turns native stderr into ErrorRecords. unittest
        # writes its successful progress to stderr, so $? is not its exit status.
        $exitCode=$LASTEXITCODE
    } catch {
        $exitCode=1
        [IO.File]::WriteAllText($log,($_ | Out-String),(New-Object Text.UTF8Encoding($true)))
    } finally { $ErrorActionPreference=$oldPreference; $timer.Stop() }
    $output=[IO.File]::ReadAllText($log)
    $row=[ordered]@{Name=$Name;ExitCode=$exitCode;Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,3);Log=[IO.Path]::GetFileName($log);Skipped=0}
    if ($output -match 'Ran (\d+) tests?') { $row.TestsRun=[int]$Matches[1] }
    if ($output -match 'skipped=(\d+)') { $row.Skipped=[int]$Matches[1] }
    if ($Name -like 'Python-*') {
        if (-not $row.Contains('TestsRun') -or $row.TestsRun -le 0) {
            $row.ExitCode=1;$row.Error='Python discovery did not report any executed tests.'
        }
        $row.QemuTestsPassed=[regex]::Matches($output,'(?m)test_(?:real_qemu_pipeline|multiple_copy_chunks|unaligned_megabyte_size) \([^\r\n]+\) \.\.\. ok\s*$').Count
        if ($RequireQemu) {
            $expectedQemu=if($Name -eq 'Python-recovery'){1}else{2}
            if ($row.QemuTestsPassed -ne $expectedQemu) { $row.ExitCode=1;$row.Error='Required real-QEMU tests did not all report success.' }
        }
    }
    $script:results.Add([pscustomobject]$row)
    if ($row.ExitCode -eq 0) { Write-Host ('PASS '+$Name) -ForegroundColor Green }
    else { Write-Host ('FAIL '+$Name+' (see '+$log+')') -ForegroundColor Red }
}

Push-Location $root
try {
    $python=(Get-Command python -ErrorAction Stop).Source
    $parseErrors=@()
    $scripts=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })
    foreach ($file in $scripts) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        foreach ($error in $errors) { $parseErrors+=($file.FullName+':'+$error.Extent.StartLineNumber+': '+$error.Message) }
    }
    $script:results.Add([pscustomobject]@{Name='PowerShell-syntax';ExitCode=[int]($parseErrors.Count -gt 0);Files=$scripts.Count;Errors=$parseErrors})
    if ($parseErrors.Count) { throw ($parseErrors -join [Environment]::NewLine) }
    if ($RequireQemu -and (-not $env:QEMU_IMG_TEST_EXE -or -not (Test-Path -LiteralPath $env:QEMU_IMG_TEST_EXE -PathType Leaf))) {
        throw 'RequireQemu needs QEMU_IMG_TEST_EXE pointing to a trusted qemu-img executable.'
    }
    foreach ($directory in @('storage-recovery\tests','setup\tests','windows-host\tests','installer\tests')) {
        $testDirectory=Join-Path $root $directory
        if (-not (Test-Path -LiteralPath $testDirectory)) { throw ('Test directory missing: '+$directory) }
        $tests=@(Get-ChildItem -LiteralPath $testDirectory -Filter '*.ps1' -File |
            Where-Object { $_.Name -eq 'run-tests.ps1' -or $_.Name -like 'test-*.ps1' } | Sort-Object Name)
        # setup/run-tests.ps1 already executes these two suites. Do not count them twice.
        if ($directory -eq 'setup\tests') { $tests=@($tests | Where-Object { $_.Name -notin @('test-safety.ps1','test-vm-create-safety.ps1') }) }
        if (-not $tests.Count) { throw ('No tests found: '+$directory) }
        foreach ($test in $tests) {
            Invoke-FileCheck ($directory.Replace('\','-')+'-'+$test.BaseName) $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$test.FullName)
        }
    }
    Invoke-FileCheck 'Python-recovery' $python @('-B','-m','unittest','discover','-s','storage-recovery/tests','-p','test_*.py','-v')
    Invoke-FileCheck 'Python-release' $python @('-B','-m','unittest','discover','-s','tests','-p','test_*.py','-v')
} catch {
    $script:results.Add([pscustomobject]@{Name='Runner';ExitCode=1;Error=$_.Exception.Message})
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    Pop-Location
    $failed=@($script:results | Where-Object ExitCode -ne 0).Count
    $pythonTestsRun=0;$pythonTestsSkipped=0;$qemuTestsPassed=0
    foreach ($check in $script:results) {
        if ($check.Name -like 'Python-*') { $pythonTestsRun+=[int]$check.TestsRun;$pythonTestsSkipped+=[int]$check.Skipped;$qemuTestsPassed+=[int]$check.QemuTestsPassed }
    }
    $report=[ordered]@{StartedUtc=$started;FinishedUtc=[DateTime]::UtcNow.ToString('o');Passed=($failed -eq 0);PowerShellVersion=$PSVersionTable.PSVersion.ToString();PythonTestsRun=$pythonTestsRun;PythonTestsSkipped=$pythonTestsSkipped;QemuConfigured=[bool]$env:QEMU_IMG_TEST_EXE;QemuTestsPassed=$qemuTestsPassed;RealDiskRestoreTested=$false;RealGuestBootTested=$false;Checks=@($script:results.ToArray())}
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'results.json') -Encoding UTF8
}
Write-Host ('Report: '+(Join-Path $ReportDirectory 'results.json'))
if ($failed) { exit 1 }
Write-Host ('All nonhardware checks passed. Python tests run: '+$pythonTestsRun+'; skipped: '+$pythonTestsSkipped+'; real QEMU tests passed: '+$qemuTestsPassed+'.') -ForegroundColor Green
exit 0
