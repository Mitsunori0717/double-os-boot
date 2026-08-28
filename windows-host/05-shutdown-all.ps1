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

Add-Type -AssemblyName System.Windows.Forms
$shutdownWindows = $true
if (-not $NoConfirm) {
    $msg = "FIELD system を終了します。`n`nWindows もシャットダウンしますか?`n`n" +
           "[はい]      FIELD を終了 → Windows もシャットダウン`n" +
           "[いいえ]    FIELD だけ終了 (Windows はこのまま使う)`n" +
           "[キャンセル] 何もしない"
    $res = [System.Windows.Forms.MessageBox]::Show($msg, "全部シャットダウン",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) { exit 0 }
    $shutdownWindows = ($res -eq [System.Windows.Forms.DialogResult]::Yes)
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

# --- 停止中のいまのうちに、『FIELD表示設定』のコンソール解像度を反映しておく ---
# (VM は Windows 起動時に自動起動するため、解像度変更はここが唯一の機会)
try {
    $cfgFile = Join-Path $PSScriptRoot "display-config.json"
    if ((Test-Path $cfgFile) -and ((Get-VM -Name $VMName -ErrorAction SilentlyContinue).State -eq "Off")) {
        $resText = [string](Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).ConsoleResolution
        $rw = 0; $rh = 0
        if ($resText -match '^(auto|自動)' -or -not $resText) {
            $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
            $rw = $b.Width; $rh = $b.Height
        } elseif ($resText -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
            $rw = [int]$Matches[1]; $rh = [int]$Matches[2]
        }
        if ($rw -gt 0) {
            Set-VMVideo -VMName $VMName -ResolutionType Single `
                -HorizontalResolution $rw -VerticalResolution $rh -ErrorAction SilentlyContinue
            Write-Host "コンソールの解像度を ${rw}x${rh} に設定しました (次回起動時から)。"
        }
    }
} catch { }

if ($shutdownWindows) {
    Write-Host "Windows をシャットダウンします..."
    shutdown /s /t 10 /c "FIELD system の終了を確認しました。Windows をシャットダウンします。"
} else {
    [System.Windows.Forms.MessageBox]::Show("FIELD system のみ終了しました。Windows はそのまま使えます。`n再開するには 02-start-field-vm.ps1 を実行してください。",
        "全部シャットダウン") | Out-Null
}
