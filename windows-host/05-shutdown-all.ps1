<#
.SYNOPSIS
    終業用ワンクリック: Edge Box を正しく終了してから、Windows もシャットダウンします。

.DESCRIPTION
    1. Edge Box に ACPI シャットダウン要求を送る (物理機の電源ボタン短押しと同じ)
       → Edge Box 自身が正規の終了処理を実行する
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
    [switch]$Setup,
    [ValidateRange(1,1800)][int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"

# -VMName を明示していない場合、既定名の Edge Box が無ければ、Edge Box のディスク
# (物理ディスクのパススルー) を持つ Edge Box を探して使う。00-field-launcher.ps1 と
# 同じ考え方で、登録名が「EdgeBox」でなくても (旧名称のままでも) そのまま動くようにする
if (-not $PSBoundParameters.ContainsKey("VMName") -and
    -not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    $foundVms = @()
    foreach ($v in @(Get-VM -ErrorAction SilentlyContinue)) {
        $pt = @(Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.DiskNumber })
        if ($pt.Count -gt 0) { $foundVms += $v }
    }
    if ($foundVms.Count -eq 1) { $VMName = $foundVms[0].Name }
}

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
    $lnk.Description  = "Edge Box を正しく終了してから Windows もシャットダウン"
    $lnk.Save()
    Write-Host "デスクトップに『全部シャットダウン』ショートカットを作成しました (UAC 確認なしで実行できます)。" -ForegroundColor Green
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
$shutdownWindows = $true
if (-not $NoConfirm) {
    $msg = "Edge Box を終了します。`n`nWindows もシャットダウンしますか?`n`n" +
           "[はい]      Edge Box を終了 → Windows もシャットダウン`n" +
           "[いいえ]    Edge Box だけ終了 (Windows はこのまま使う)`n" +
           "[キャンセル] 何もしない"
    $res = [System.Windows.Forms.MessageBox]::Show($msg, "全部シャットダウン",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) { exit 0 }
    $shutdownWindows = ($res -eq [System.Windows.Forms.DialogResult]::Yes)
}

Import-Module (Join-Path $PSScriptRoot 'vm-shutdown.psm1') -Force
$shutdownLog = Join-Path $PSScriptRoot 'shutdown-log.txt'
function Write-ShutdownLog([string]$Message) {
    Write-Host $Message
    try { Add-Content -LiteralPath $shutdownLog -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Message) } catch { }
}
Write-ShutdownLog '===== 終了開始 ====='
function Close-ShutdownConsole {
# 先にコンソール画面 (vmconnect) を閉じる。
# 開いたままだと、停止後に画面側から Edge Box が自動で再起動されることがあるため
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
try {
    Wait-EdgeBoxShutdown -VMName $VMName -TimeoutSec $TimeoutSec -Log {param($m) Write-ShutdownLog $m} -AfterRequest {Close-ShutdownConsole}
} catch {
    Write-ShutdownLog ('失敗: '+$_.Exception.Message)
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '全部シャットダウン', 'OK', 'Warning') | Out-Null
    exit 1
}

# --- 停止中のいまのうちに、予約していた入出力の設定 (メモリの固定など) を反映しておく ---
$s11 = Join-Path $PSScriptRoot "11-io-passthrough.ps1"
if (Test-Path $s11) { try { & $s11 -VMName $VMName -ApplyPending } catch { } }

# --- 停止中のいまのうちに、『Edge Box表示設定』のコンソール解像度を反映しておく ---
# (Edge Box は Windows 起動時に自動起動するため、解像度変更はここが唯一の機会)
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
    # /t > 0 は Windows の強制終了を暗黙に有効化するため、待ち時間 0・/f なしで要求する。
    Write-ShutdownLog 'Windows へ通常のシャットダウンを要求（追加の 10 秒待ちは省略）。'
    shutdown.exe /s /t 0 /c "Edge Box の終了を確認しました。Windows をシャットダウンします。"
    if ($LASTEXITCODE -ne 0) { Write-ShutdownLog ('Windows の終了要求に失敗。終了コード: '+$LASTEXITCODE); exit 1 }
} else {
    # 停止後しばらく見張り、何かに自動で再起動されたらもう一度止める (再発防止の保険)
    Write-Host "Edge Box の停止を確認しています (1分間)..."
    $restarted = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Seconds 5
        if ((Get-VM -Name $VMName -ErrorAction SilentlyContinue).State -eq "Running") { $restarted = $true; break }
    }
    if ($restarted) {
        Write-Warning "Edge Box が自動で再起動されたため、もう一度停止します..."
        Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        try { Wait-EdgeBoxShutdown -VMName $VMName -TimeoutSec $TimeoutSec -Log {param($m) Write-ShutdownLog $m} }
        catch { Write-ShutdownLog ('再停止に失敗: '+$_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'全部シャットダウン') | Out-Null; exit 1 }
    }
    [System.Windows.Forms.MessageBox]::Show("Edge Box のみ終了しました。Windows はそのまま使えます。`n再開するには 02-start-field-vm.ps1 を実行してください。",
        "全部シャットダウン") | Out-Null
}
