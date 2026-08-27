<#
.SYNOPSIS
    終業用ワンクリック: FIELD system を正しく終了してから、Windows もシャットダウンします。

.DESCRIPTION
    1. FIELD system VM に ACPI シャットダウン要求を送る (物理機の電源ボタン短押しと同じ)
       → FIELD 自身が正規の終了処理を実行する
    2. 完全に停止するのを待つ (最大3分)
    3. Windows をシャットダウンする

.EXAMPLE
    .\05-shutdown-all.ps1              # 確認あり
    .\05-shutdown-all.ps1 -NoConfirm   # 確認なし (ショートカット用)
    .\05-shutdown-all.ps1 -Setup       # デスクトップに『全部シャットダウン』ショートカットを作成
#>
[CmdletBinding()]
param(
    [string]$VMName = "FIELDsystem",
    [switch]$NoConfirm,
    [switch]$Setup
)

$ErrorActionPreference = "Stop"

if ($Setup) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "全部シャットダウン.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,27"
    $lnk.Description  = "FIELD system を正しく終了してから Windows もシャットダウン"
    $lnk.Save()
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20   # 管理者として実行
    [IO.File]::WriteAllBytes($lnkPath, $bytes)
    Write-Host "デスクトップに『全部シャットダウン』ショートカットを作成しました。" -ForegroundColor Green
    exit 0
}

if (-not $NoConfirm) {
    Write-Host "FIELD system を終了してから、Windows もシャットダウンします。" -ForegroundColor Yellow
    Write-Host "作業中のファイルは保存してください。"
    $ans = Read-Host "実行しますか? (y/N)"
    if ($ans -ne "y") { exit 0 }
}

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and $vm.State -eq "Running") {
    Write-Host "FIELD system にシャットダウン要求を送信しました。終了を待っています..."
    Stop-VM -Name $VMName            # ACPI シャットダウン要求 (強制電源断ではない)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        Write-Warning "FIELD system が3分以内に停止しませんでした。Windows のシャットダウンを中止します。"
        Write-Warning "コンソール画面で状態を確認してください (強制終了はしません)。"
        exit 1
    }
    Write-Host "FIELD system が正常に終了しました。" -ForegroundColor Green
} else {
    Write-Host "FIELD system は既に停止しています。"
}

Write-Host "Windows をシャットダウンします..."
shutdown /s /t 10 /c "FIELD system の終了を確認しました。Windows をシャットダウンします。"
