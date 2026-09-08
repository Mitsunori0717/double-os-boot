<#
.SYNOPSIS
    名称を EdgeBox に統一する移行スクリプト (1 回だけ実行)。

.DESCRIPTION
    やること:
      1. 登録名を FIELDsystem → EdgeBox に変更 (中身・ディスクには一切触れません)
         実行中でも変更できます (収集は止まりません)
      2. 外部スイッチ名を FIELD-External → EdgeBox-External に変更
      3. CPU コア分割の設定 (cpu-partition.json) の 登録名を書き換え、固定を適用し直す
         ※ これを忘れると、自動タスクが EdgeBox を見つけられず、コア分割が静かに外れます
      4. 古い名前のタスク・デスクトップアイコンを削除
      5. 新しい名前でタスクとアイコンを登録し直す

    EdgeBox の設定・ディスク・データは変わりません。名前だけの変更です。

.EXAMPLE
    .\09-rename-to-edgebox.ps1            # 実行
    .\09-rename-to-edgebox.ps1 -WhatIf    # 何が起きるか確認するだけ

.NOTES
    管理者権限が必要です。
    コンソール窓 (vmconnect) を開いている場合は、名前変更後に開き直してください。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OldName = "FIELDsystem",
    [string]$NewName = "EdgeBox"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限で実行してください (スタートボタンを右クリック →『ターミナル (管理者)』)。"
    exit 1
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 名称を $NewName に統一します"
Write-Host "==============================================" -ForegroundColor Cyan

# --- 1. 登録名 ---
$vmNew = Get-VM -Name $NewName -ErrorAction SilentlyContinue
$vmOld = Get-VM -Name $OldName -ErrorAction SilentlyContinue
if ($vmNew) {
    Write-Host "EdgeBox: すでに '$NewName' です。変更は不要です。" -ForegroundColor Green
} elseif ($vmOld) {
    if ($vmOld.State -ne "Off") {
        Write-Host "EdgeBox '$OldName' は実行中ですが、名前の変更は実行中でも行えます (収集は止まりません)。" -ForegroundColor Yellow
    }
    if ($PSCmdlet.ShouldProcess($OldName, "登録名を $NewName に変更")) {
        Rename-VM -Name $OldName -NewName $NewName
        Write-Host "登録名を '$OldName' → '$NewName' に変更しました。" -ForegroundColor Green
    }
} else {
    Write-Warning "EdgeBox '$OldName' も '$NewName' も見つかりませんでした。"
}

# --- 2. 外部スイッチ名 ---
if (Get-VMSwitch -Name "EdgeBox-External" -ErrorAction SilentlyContinue) {
    Write-Host "外部スイッチ: すでに 'EdgeBox-External' です。" -ForegroundColor Green
} elseif (Get-VMSwitch -Name "FIELD-External" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess("FIELD-External", "外部スイッチ名を EdgeBox-External に変更")) {
        try {
            Rename-VMSwitch -Name "FIELD-External" -NewName "EdgeBox-External"
            Write-Host "外部スイッチ名を 'FIELD-External' → 'EdgeBox-External' に変更しました。" -ForegroundColor Green
        } catch {
            Write-Host "外部スイッチ名は変更できませんでした (動作には影響しません): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# --- 3. CPU コア分割の設定を新しい名前に合わせる ---
# 自動タスク (CpuPartition-Pin) は cpu-partition.json の 登録名で EdgeBox を探す。
# ここを書き換えないと、名前変更のあと EdgeBox が見つからず、コア分割が静かに外れる
$cpuDir  = Join-Path (Split-Path $PSScriptRoot -Parent) "windows-cpu-partition"
$cpuJson = Join-Path $cpuDir "cpu-partition.json"
$cpuPs1  = Join-Path $cpuDir "cpu-partition.ps1"
if (Test-Path $cpuJson) {
    $cpuCfg = $null
    try { $cpuCfg = Get-Content $cpuJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if ($cpuCfg -and [string]$cpuCfg.VMName -eq $OldName) {
        if ($PSCmdlet.ShouldProcess("cpu-partition.json", "CPU コア分割の 登録名を $NewName に書き換えて適用し直す")) {
            $cpuCfg.VMName = $NewName
            $cpuCfg | ConvertTo-Json -Depth 4 | Set-Content -Path $cpuJson -Encoding UTF8
            Write-Host "CPU コア分割の設定: 登録名を '$NewName' に書き換えました。" -ForegroundColor Green
            if (Test-Path $cpuPs1) {
                & $cpuPs1 -ApplyRuntime -Quiet
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "CPU コア分割: 新しい名前で固定を適用し直しました。" -ForegroundColor Green
                } else {
                    Write-Host "CPU コア分割の再適用に失敗しました。あとで確認してください: $cpuPs1 -Verify" -ForegroundColor Yellow
                }
            }
        }
    } elseif ($cpuCfg) {
        Write-Host "CPU コア分割の設定: 登録名は既に '$($cpuCfg.VMName)' です。" -ForegroundColor Green
    }
} else {
    Write-Host "CPU コア分割: 設定なし (未適用)。" -ForegroundColor Gray
}

# --- 4. 古い名前のタスク・アイコンを削除 ---
foreach ($t in "FIELD-Display-Kiosk", "FIELD-Display-Kiosk-Splash",
                "FIELD-Native-Boot", "FIELD-Shutdown-All", "FIELD-Settings-Console") {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($t, "古いタスクを削除")) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "古いタスクを削除しました: $t"
        }
    }
}
$desktop = [Environment]::GetFolderPath("Desktop")
foreach ($n in "FIELD system 単独起動.lnk", "FIELD表示設定.lnk", "FIELD設定.lnk", "自動サインイン設定.lnk") {
    $p = Join-Path $desktop $n
    if (Test-Path $p) {
        if ($PSCmdlet.ShouldProcess($n, "古いアイコンを削除")) {
            Remove-Item $p -Force -ErrorAction SilentlyContinue
            Write-Host "古いアイコンを削除しました: $n"
        }
    }
}

if ($WhatIfPreference) { Write-Host "`n(確認モードのため、実際の変更は行っていません)" -ForegroundColor Yellow; exit 0 }

# --- 5. 新しい名前で登録し直す ---
# 表示タスクは 登録名を焼き込んでいるため、必ず登録し直す
Write-Host ""
Write-Host "新しい名前でタスクとアイコンを登録し直します..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "03-field-display-kiosk.ps1")     -Install -VMName $NewName
& (Join-Path $PSScriptRoot "08-settings-console.ps1")        -Setup   -VMName $NewName
& (Join-Path $PSScriptRoot "05-shutdown-all.ps1")            -Setup   -VMName $NewName
& (Join-Path $PSScriptRoot "04-reboot-to-field-native.ps1")  -Setup   -VMName $NewName
& (Join-Path $PSScriptRoot "00-field-launcher.ps1")          -Setup   -VMName $NewName
& (Join-Path $PSScriptRoot "10-restart-edgebox.ps1")         -Setup   -VMName $NewName

Write-Host ""
Write-Host "移行が完了しました。以後はすべて '$NewName' の名前で動きます。" -ForegroundColor Green
Write-Host "  確認: cd ..\windows-cpu-partition ; .\cpu-partition.ps1 -Verify -Seconds 10"
Write-Host "  コンソール窓を開いていた場合は、開き直してください (.\03-field-display-kiosk.ps1)。"
