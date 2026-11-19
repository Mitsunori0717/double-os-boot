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
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
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
function Assert-ShutdownTargetOff([string]$ExpectedVmId) {
    if ([string]::IsNullOrWhiteSpace($ExpectedVmId)) { throw '停止対象の Edge Box の ID を確認できません。' }
    $matches=@(Get-VM -Id $ExpectedVmId -ErrorAction Stop)
    if ($matches.Count -ne 1 -or [string]$matches[0].Id -ne $ExpectedVmId -or [string]$matches[0].Name -ne $VMName -or [string]$matches[0].State -ne 'Off') {
        throw '選択した Edge Box の停止を再確認できません。Windows の終了を中止します。'
    }
}
function Invoke-ConfirmedWindowsShutdown([string]$ExpectedVmId) {
    Assert-ShutdownTargetOff $ExpectedVmId
    Write-ShutdownLog 'Windows へ通常のシャットダウンを要求（追加の 10 秒待ちは省略）。'
    # /t > 0 implicitly forces applications closed; use zero delay and no /f.
    shutdown.exe /s /t 0 /c "Edge Box の終了を確認しました。Windows をシャットダウンします。"
    if ($LASTEXITCODE -ne 0) { throw ('Windows の終了要求に失敗。終了コード: '+$LASTEXITCODE) }
}
Write-ShutdownLog '===== 終了開始 ====='
function Close-ShutdownConsole {
# 先にコンソール画面 (vmconnect) を閉じる。
# 開いたままだと、停止後に画面側から Edge Box が自動で再起動されることがあるため
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
try {
    $selected=@(Get-VM -ErrorAction Stop | Where-Object { $_.Name -eq $VMName })
    if ($selected.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$selected[0].Id)) { throw '対象の Edge Box を一意に確認できません。' }
    $shutdownVmId=[string]$selected[0].Id
    Wait-EdgeBoxShutdown -VMName $VMName -ExpectedVmId $shutdownVmId -TimeoutSec $TimeoutSec -Log {param($m) Write-ShutdownLog $m} -AfterRequest {Close-ShutdownConsole}
    Assert-ShutdownTargetOff $shutdownVmId
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
    try { Invoke-ConfirmedWindowsShutdown $shutdownVmId }
    catch {
        Write-ShutdownLog ('失敗: '+$_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '全部シャットダウン', 'OK', 'Warning') | Out-Null
        exit 1
    }
} else {
    # 停止後しばらく見張り、何かに自動で再起動されたらもう一度止める (再発防止の保険)
    Write-Host "Edge Box の停止を確認しています (1分間)..."
    $restarted = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Seconds 5
        try {
            $observed=@(Get-VM -Id $shutdownVmId -ErrorAction Stop)
            if ($observed.Count -ne 1 -or [string]$observed[0].Id -ne $shutdownVmId -or [string]$observed[0].Name -ne $VMName) { throw '停止監視中に対象の Edge Box が変わりました。' }
            if ([string]$observed[0].State -ne 'Off') { $restarted = $true; break }
        } catch { Write-ShutdownLog ('停止監視に失敗: '+$_.Exception.Message); exit 1 }
    }
    if ($restarted) {
        Write-Warning "Edge Box が自動で再起動されたため、もう一度停止します..."
        Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        try { Wait-EdgeBoxShutdown -VMName $VMName -ExpectedVmId $shutdownVmId -TimeoutSec $TimeoutSec -Log {param($m) Write-ShutdownLog $m} }
        catch { Write-ShutdownLog ('再停止に失敗: '+$_.Exception.Message); [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'全部シャットダウン') | Out-Null; exit 1 }
    }
    [System.Windows.Forms.MessageBox]::Show("Edge Box のみ終了しました。Windows はそのまま使えます。`n再開するには 02-start-field-vm.ps1 を実行してください。",
        "全部シャットダウン") | Out-Null
}
