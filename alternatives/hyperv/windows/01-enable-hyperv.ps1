<#
.SYNOPSIS
    Hyper-V と管理ツールを有効化します。実行後に再起動が必要です。

.NOTES
    管理者権限の PowerShell で実行してください。
    Windows 11 Pro / Enterprise / Education が対象です (Home は Hyper-V 非対応)。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# 管理者権限チェック
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限の PowerShell で実行してください。"
    exit 1
}

# エディションチェック (Home では Hyper-V が使えない)
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
if ($edition -match "Home") {
    Write-Error "このエディション ($edition) は Hyper-V に対応していません。docs/ADVANCED.md の WSL2 方式を検討してください。"
    exit 1
}

# 仮想化支援機能のチェック
$cpu = Get-CimInstance Win32_Processor
if (-not $cpu.VirtualizationFirmwareEnabled -and -not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Warning "BIOS/UEFI で仮想化支援機能 (Intel VT-x / AMD-V) が無効の可能性があります。有効化してから再実行してください。"
}

Write-Host "Hyper-V を有効化しています..." -ForegroundColor Cyan
$result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart

if ($result.RestartNeeded) {
    Write-Host ""
    Write-Host "Hyper-V を有効化しました。再起動が必要です。" -ForegroundColor Green
    Write-Host "再起動後、windows\02-create-linux-vm.ps1 を実行してください。"
    $answer = Read-Host "今すぐ再起動しますか? (y/N)"
    if ($answer -eq "y") {
        Restart-Computer
    }
} else {
    Write-Host "Hyper-V は既に有効です。windows\02-create-linux-vm.ps1 に進んでください。" -ForegroundColor Green
}
