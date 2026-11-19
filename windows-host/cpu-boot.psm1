function Invoke-EdgeBoxCpuPreparation([Parameter(Mandatory)][string]$VMName) {
    $ErrorActionPreference = 'Stop'
    $cpuDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-cpu-partition'
    $config = Join-Path $cpuDir 'cpu-partition.json'
    if (-not (Test-Path -LiteralPath $config)) { return $false }
    $plan = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.Mode -notin @('runtime','full') -or -not $plan.VMName) { throw "Invalid CPU plan: $config" }
    if ($plan.Mode -ne 'full' -or $plan.VMName -ne $VMName) { return $false }

    $scriptPath = Join-Path $cpuDir 'cpu-partition.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Missing CPU setup: $scriptPath" }
    $command = "& '{0}' -BootApply -PrepareOnly -Quiet -VMName '{1}'" -f $scriptPath.Replace("'","''"), $VMName.Replace("'","''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command + '; exit $LASTEXITCODE'))
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process $exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded)
    try {
        if (-not $process.WaitForExit(240000)) {
            if (-not $process.HasExited) { $process.Kill() }
            throw 'CPU preparation timed out. Check cpu-partition-log.txt.'
        }
        if ($process.ExitCode -ne 0) { throw "CPU preparation failed (exit $($process.ExitCode)). Check cpu-partition-log.txt." }
        return $true
    } finally { $process.Dispose() }
}
Export-ModuleMember -Function Invoke-EdgeBoxCpuPreparation
