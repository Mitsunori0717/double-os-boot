<#
.SYNOPSIS
    既存環境の名称を FIELDsystem から EdgeBox に切り替える移行スクリプト (1回だけ実行)。

.DESCRIPTION
    やること:
      1. 仮想マシン名を FIELDsystem → EdgeBox に変更 (中身・ディスクには一切触れません)
      2. 仮想スイッチ名を FIELD-External → EdgeBox-External に変更
      3. 古い名前のタスク (FIELD-*) を削除
      4. 古い名前のデスクトップアイコンを削除
      5. 新しい名前でタスクとアイコンを登録し直す

    VM の設定・ディスク・データは変わりません。名前だけの変更です。

.EXAMPLE
    .\09-rename-to-edgebox.ps1            # 実行 (VM は停止しておくこと)
    .\09-rename-to-edgebox.ps1 -WhatIf    # 何が起きるか確認するだけ

.NOTES
    管理者権限が必要です。VM は停止中に実行してください。
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
Write-Host " 名称を EdgeBox に切り替えます"
Write-Host "==============================================" -ForegroundColor Cyan

# --- 1. 仮想マシン名 ---
$vmNew = Get-VM -Name $NewName -ErrorAction SilentlyContinue
$vmOld = Get-VM -Name $OldName -ErrorAction SilentlyContinue
if ($vmNew) {
    Write-Host "仮想マシン: すでに '$NewName' です。変更は不要です。" -ForegroundColor Green
} elseif ($vmOld) {
    if ($vmOld.State -ne "Off") {
        Write-Error "仮想マシン '$OldName' が動作中です。『全部シャットダウン』で終了してから実行してください。"
        exit 1
    }
    if ($PSCmdlet.ShouldProcess($OldName, "仮想マシン名を $NewName に変更")) {
        Rename-VM -Name $OldName -NewName $NewName
        Write-Host "仮想マシン名を '$OldName' → '$NewName' に変更しました。" -ForegroundColor Green
    }
} else {
    Write-Warning "仮想マシン '$OldName' も '$NewName' も見つかりませんでした。"
}

# --- 2. 仮想スイッチ名 ---
if (Get-VMSwitch -Name "EdgeBox-External" -ErrorAction SilentlyContinue) {
    Write-Host "仮想スイッチ: すでに 'EdgeBox-External' です。" -ForegroundColor Green
} elseif (Get-VMSwitch -Name "FIELD-External" -ErrorAction SilentlyContinue) {
    if ($PSCmdlet.ShouldProcess("FIELD-External", "仮想スイッチ名を EdgeBox-External に変更")) {
        Rename-VMSwitch -Name "FIELD-External" -NewName "EdgeBox-External"
        Write-Host "仮想スイッチ名を 'FIELD-External' → 'EdgeBox-External' に変更しました。" -ForegroundColor Green
    }
}

# --- 3. 古い名前のタスクを削除 ---
foreach ($t in "FIELD-Display-Kiosk", "FIELD-Display-Kiosk-Splash",
                "FIELD-Native-Boot", "FIELD-Shutdown-All", "FIELD-Settings-Console") {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($t, "古いタスクを削除")) {
            Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "古いタスクを削除しました: $t"
        }
    }
}

# --- 4. 古い名前のデスクトップアイコンを削除 ---
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
Write-Host ""
Write-Host "新しい名前でタスクとアイコンを登録し直します..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "03-field-display-kiosk.ps1") -Install
& (Join-Path $PSScriptRoot "08-settings-console.ps1")    -Setup
& (Join-Path $PSScriptRoot "05-shutdown-all.ps1")        -Setup
& (Join-Path $PSScriptRoot "04-reboot-to-field-native.ps1") -Setup

Write-Host ""
Write-Host "移行が完了しました。" -ForegroundColor Green
Write-Host "デスクトップのアイコン: 『設定』『EdgeBox 単独起動』『全部シャットダウン』"
Write-Host "この後 .\02-start-field-vm.ps1 で EdgeBox を起動できます。"
