<#
.SYNOPSIS
    終業用ワンクリック: EdgeBox を正しく終了してから、Windows もシャットダウンします。

.DESCRIPTION
    1. EdgeBox VM に ACPI シャットダウン要求を送る (物理機の電源ボタン短押しと同じ)
       → EdgeBox 自身が正規の終了処理を実行する
    2. 完全に停止するのを待つ (最大3分)
    3. Windows をシャットダウンする

.EXAMPLE
    .\05-shutdown-all.ps1              # 確認あり
    .\05-shutdown-all.ps1 -NoConfirm   # 確認なし (ショートカット用)
    .\05-shutdown-all.ps1 -Setup       # デスクトップに『全部シャットダウン』ショートカットを作成
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$NoConfirm,
    [switch]$Setup
)

$ErrorActionPreference = "Stop"

if ($Setup) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "管理者権限で実行してください (PowerShell を右クリック →『管理者として実行』)。"
        exit 1
    }

    # UAC 確認なしで実行できるよう、管理者権限付きタスク + それを起動するアイコンを作成
    $taskName = "EdgeBox-Shutdown-All"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "全部シャットダウン.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,27"
    $lnk.Description  = "EdgeBox を正しく終了してから Windows もシャットダウン"
    $lnk.Save()
    Write-Host "デスクトップに『全部シャットダウン』ショートカットを作成しました (UAC 確認なしで実行できます)。" -ForegroundColor Green
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
$shutdownWindows = $true
if (-not $NoConfirm) {
    $msg = "EdgeBox を終了します。`n`nWindows もシャットダウンしますか?`n`n" +
           "[はい]      EdgeBox を終了 → Windows もシャットダウン`n" +
           "[いいえ]    EdgeBox だけ終了 (Windows はこのまま使う)`n" +
           "[キャンセル] 何もしない"
    $res = [System.Windows.Forms.MessageBox]::Show($msg, "全部シャットダウン",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) { exit 0 }
    $shutdownWindows = ($res -eq [System.Windows.Forms.DialogResult]::Yes)
}

# 先にコンソール画面 (vmconnect) を閉じる。
# 開いたままだと、停止後に画面側から VM が自動で再起動されることがあるため
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Start-Sleep -Seconds 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and $vm.State -eq "Running") {
    Write-Host "EdgeBox にシャットダウン要求を送信しました。終了を待っています..."
    Stop-VM -Name $VMName            # ACPI シャットダウン要求 (強制電源断ではない)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        [System.Windows.Forms.MessageBox]::Show(
            "EdgeBox が3分以内に停止しませんでした。`nWindows のシャットダウンを中止します。`nコンソール画面で状態を確認してください (強制終了はしません)。",
            "全部シャットダウン",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        exit 1
    }
    Write-Host "EdgeBox が正常に終了しました。" -ForegroundColor Green
} else {
    Write-Host "EdgeBox は既に停止しています。"
}

# --- 停止中のいまのうちに、『EdgeBox表示設定』のコンソール解像度を反映しておく ---
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
    shutdown /s /t 10 /c "EdgeBox の終了を確認しました。Windows をシャットダウンします。"
} else {
    # 停止後しばらく見張り、何かに自動で再起動されたらもう一度止める (再発防止の保険)
    Write-Host "EdgeBox の停止を確認しています (1分間)..."
    $restarted = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Seconds 5
        if ((Get-VM -Name $VMName -ErrorAction SilentlyContinue).State -eq "Running") { $restarted = $true; break }
    }
    if ($restarted) {
        Write-Warning "EdgeBox が自動で再起動されたため、もう一度停止します..."
        Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Stop-VM -Name $VMName -ErrorAction SilentlyContinue
        $sw3 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw3.Elapsed.TotalSeconds -lt 180) {
            if ((Get-VM -Name $VMName).State -eq "Off") { break }
            Start-Sleep -Seconds 3
        }
    }
    [System.Windows.Forms.MessageBox]::Show("EdgeBox のみ終了しました。Windows はそのまま使えます。`n再開するには 02-start-field-vm.ps1 を実行してください。",
        "全部シャットダウン") | Out-Null
}
