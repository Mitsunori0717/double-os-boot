<#
.SYNOPSIS
    画面が黒いまま操作できない (右クリックも効かない) ときの復旧ツール。

.DESCRIPTION
    黒い画面の正体は、たいてい次のどれかです。順に確認して直します。

      1. 起動中スプラッシュ (-Splash) の残骸
         … 画面全体を覆う黒い窓。クリックを受け止めるため何も反応しなくなる
      2. コンソール表示用の黒背景 (-Backdrop) の残骸
         … 最背面に居座る黒い窓。デスクトップのアイコンが隠れる
      3. デスクトップ本体 (explorer.exe) が動いていない
         … アイコンもタスクバーも無く、右クリックも効かない状態

    1・2 は閉じ、3 は起動し直します。EdgeBox や CPU の割り当てには触れません。

.EXAMPLE
    .\99-fix-black-screen.ps1                # 確認して直す
    .\99-fix-black-screen.ps1 -CloseConsole  # EdgeBox のコンソール窓も閉じる

.NOTES
    管理者権限は不要です (必要な場面では自動で昇格を求めます)。
    デスクトップを管理者権限で起動しないよう、あえて昇格せずに動く作りです。
#>
[CmdletBinding()]
param(
    [switch]$CloseConsole,   # EdgeBox のコンソール窓 (vmconnect) も閉じる
    [switch]$KillOnly        # 内部用: 昇格して黒い窓を閉じるだけの再実行
)

$ErrorActionPreference = "Continue"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BlackWindows {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-(Splash|Backdrop)' -and $_.ProcessId -ne $PID })
}

# --- 1. 黒い窓 (スプラッシュ・黒背景) を閉じる ---
$targets = Get-BlackWindows
$closed = 0
$denied = @()
foreach ($t in $targets) {
    $kind = if ($t.CommandLine -match '-Splash') { "起動中スプラッシュ" } else { "黒背景" }
    try {
        Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop
        Write-Host "  閉じました: $kind (PID $($t.ProcessId))" -ForegroundColor Green
        $closed++
    } catch {
        $denied += $t.ProcessId
    }
}

# 管理者として起動された窓は、こちらも昇格しないと閉じられない
if ($denied.Count -gt 0 -and -not $KillOnly -and -not (Test-Admin)) {
    Write-Host "  管理者権限が必要な窓が $($denied.Count) 個あります。昇格して閉じます..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList (
        "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -KillOnly")
    $left = Get-BlackWindows
    $closed += ($denied.Count - $left.Count)
    if ($left.Count -gt 0) { Write-Host "  $($left.Count) 個は閉じられませんでした。" -ForegroundColor Yellow }
    else { Write-Host "  残りも閉じました。" -ForegroundColor Green }
}
if ($KillOnly) { exit 0 }   # 昇格側の役目はここまで

if ($closed -eq 0 -and $targets.Count -eq 0) {
    Write-Host "  黒い窓 (スプラッシュ・黒背景) は残っていません。"
}

# --- 2. デスクトップ本体 (explorer) の確認 ---
$exp = @(Get-Process explorer -ErrorAction SilentlyContinue)
if ($exp.Count -eq 0) {
    Write-Host "  デスクトップ (explorer) が動いていません。" -ForegroundColor Yellow
    if (Test-Admin) {
        # 管理者のまま起動すると、デスクトップ全体が管理者権限で動いてしまう
        Write-Host "  この画面は管理者権限のため、ここからは起動しません。" -ForegroundColor Yellow
        Write-Host "  次のどちらかで復帰してください:" -ForegroundColor Cyan
        Write-Host "    ・管理者ではない PowerShell で  explorer.exe  と入力"
        Write-Host "    ・Ctrl+Shift+Esc → ファイル → 新しいタスクの実行 → explorer.exe"
        Write-Host "      (『管理者特権で…』にはチェックを入れない)"
    } else {
        Start-Process explorer.exe
        Write-Host "  デスクトップを起動し直しました。" -ForegroundColor Green
    }
} else {
    Write-Host "  デスクトップ (explorer) は動いています。"
}

# --- 3. EdgeBox のコンソール窓 ---
$vc = @(Get-Process vmconnect -ErrorAction SilentlyContinue)
if ($vc.Count -gt 0) {
    if ($CloseConsole) {
        foreach ($p in $vc) { [void]$p.CloseMainWindow() }
        Start-Sleep -Seconds 2
        Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "  EdgeBox のコンソール窓を閉じました (EdgeBox は動いたままです)。" -ForegroundColor Green
    } else {
        Write-Host "  EdgeBox のコンソール窓が開いています (画面が真っ黒に見える原因になります)。"
        Write-Host "    閉じる場合: .\99-fix-black-screen.ps1 -CloseConsole" -ForegroundColor Cyan
        Write-Host "    (EdgeBox は動いたままです。再表示は .\02-start-field-vm.ps1)"
    }
} else {
    Write-Host "  EdgeBox のコンソール窓は開いていません。"
}

Write-Host ""
Write-Host "確認が終わりました。" -ForegroundColor Green
Write-Host "  まだ黒いままの場合は、Ctrl+Shift+Esc (タスクマネージャー) を開き、"
Write-Host "  全画面のアプリが残っていないか確認してください。"
