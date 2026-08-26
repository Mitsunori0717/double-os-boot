<#
.SYNOPSIS
    FIELD system VM を起動し、コンソール画面を開きます。

.EXAMPLE
    .\02-start-field-vm.ps1              # 起動 + コンソール表示
    .\02-start-field-vm.ps1 -Stop       # 通常シャットダウン要求
    .\02-start-field-vm.ps1 -Status     # 状態表示
#>
[CmdletBinding()]
param(
    [string]$VMName = "FIELDsystem",
    [switch]$Stop,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VMName' がありません。01-create-field-vm.ps1 で作成してください。"
    exit 1
}

if ($Status) {
    $vm | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime
    exit 0
}

if ($Stop) {
    if ($vm.State -eq "Running") {
        Stop-VM -Name $VMName   # ACPI シャットダウン要求 (専用機側が正常終了処理を行う)
        Write-Host "シャットダウンを要求しました。"
    } else {
        Write-Host "VM は起動していません ($($vm.State))。"
    }
    exit 0
}

if ($vm.State -ne "Running") {
    Write-Host "FIELD system を起動しています..." -ForegroundColor Cyan
    Start-VM -Name $VMName
}

# コンソール画面 (起動ログ・専用機の画面) を表示。モニター2に置いて監視用に
Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName

Write-Host ""
Write-Host "起動しました。" -ForegroundColor Green
Write-Host "  - コンソール窓が開きます。モニター2に移動して監視用にどうぞ"
Write-Host "  - 管理画面 (Web UI) は、VM の IP アドレスにブラウザでアクセスしてください"
Write-Host "    IP の確認: Get-VMNetworkAdapter -VMName $VMName | Select -Expand IPAddresses"
Write-Host "    (表示されるまで起動から数分かかることがあります)"
