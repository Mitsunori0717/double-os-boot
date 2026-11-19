#requires -Version 5.1
$script:CrashControl = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'

function Test-EdgeBoxCrashRestartBlocked {
    $value = (Get-ItemProperty -LiteralPath $script:CrashControl -ErrorAction Stop).AutoReboot
    return ($value -is [int] -and $value -eq 0)
}

function Set-EdgeBoxCrashRestartPolicy {
    if (Test-EdgeBoxCrashRestartBlocked) { return }
    New-ItemProperty -LiteralPath $script:CrashControl -Name AutoReboot -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
    if (-not (Test-EdgeBoxCrashRestartBlocked)) { throw 'Windows のシステム障害時の自動再起動禁止を確認できません。' }
}

Export-ModuleMember -Function Test-EdgeBoxCrashRestartBlocked,Set-EdgeBoxCrashRestartPolicy
