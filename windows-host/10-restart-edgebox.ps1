<#
.SYNOPSIS
    Edge Box をワンクリックで再起動 / 左画面に表示します。

.DESCRIPTION
    『Edge Box 再起動』 : 正常シャットダウン → 起動 → 電源 ON のときと同じ画面表示
                        (設定どおり: 左 = コンソール / 右 = 管理画面)。
                        強制電源断は行いません (収集中のデータやファイルシステムを壊しうるため)。
    『Edge Box 画面』   : 左画面にコンソールを最大化 (設定が全画面なら全画面) で表示します。
                        自動では閉じません。Edge Box が止まっていれば起動してから表示します。

.EXAMPLE
    .\10-restart-edgebox.ps1            # 再起動 (確認あり)
    .\10-restart-edgebox.ps1 -ShowOnly  # 左画面に表示するだけ
    .\10-restart-edgebox.ps1 -Setup     # デスクトップとスタートメニューに 2 つのアイコンを作成

.NOTES
    管理者権限が必要です (アイコンから起動すれば UAC 確認なしで管理者になります)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$ShowOnly,
    [switch]$Setup,
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($VMName) -or [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($VMName)) {
    throw '対象 VM の正確な登録名を指定してください。'
}

$Script03 = Join-Path $PSScriptRoot "03-field-display-kiosk.ps1"

Import-Module (Join-Path $PSScriptRoot 'cpu-boot.psm1') -ErrorAction Stop

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Show-Msg([string]$Text, [string]$Title, [string]$Icon = "Information") {
    Add-Type -AssemblyName System.Windows.Forms
    $ic = [System.Windows.Forms.MessageBoxIcon]::Information
    if ($Icon -eq "Warning") { $ic = [System.Windows.Forms.MessageBoxIcon]::Warning }
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, $ic) | Out-Null
}
function Confirm-Msg([string]$Text, [string]$Title) {
    Add-Type -AssemblyName System.Windows.Forms
    $r = [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ============================================================ -Setup: アイコンを作る

if ($Setup) {
    if (-not (Test-Admin)) { Write-Error "管理者権限で実行してください。"; exit 1 }
    $shell = New-Object -ComObject WScript.Shell
    $defs = @(
        @{ Task = "EdgeBox-Restart"; Args = "";          Vbs = "launch-restart.vbs"
           Lnk = "Edge Box 再起動"; Desc = "Edge Box を正常に再起動して画面を表示 (強制電源断はしない)"; Icon = "shell32.dll,27" },
        @{ Task = "EdgeBox-Console"; Args = "-ShowOnly"; Vbs = "launch-console-view.vbs"
           Lnk = "Edge Box 画面";   Desc = "左画面に Edge Box のコンソールを最大化で表示 (自動では閉じない)"; Icon = "shell32.dll,15" }
    )
    foreach ($d in $defs) {
        # UAC 確認なしで実行できるよう、管理者権限付きタスク + wscript 経由のショートカット (黒い窓を出さない)
        $arg = ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`" " + $d.Args).Trim()
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
        # 時間制限なし + 多重起動可。表示処理は見張り役などの常駐プロセスを残すため、タスクは「実行中」のまま
        # になる。時間制限があると 1 時間後にタスクごと (常駐プロセスも) 止められ、多重起動不可だと
        # 「実行中」の間はアイコンを押しても何も起きない (以前の設定で『Edge Box 再起動』が効かなくなっていた原因)
        $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
        Register-ScheduledTask -TaskName $d.Task -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null
        $taskName = $d.Task
        $vbs = Join-Path $PSScriptRoot $d.Vbs
        Set-Content -Path $vbs -Encoding Default -Value @(
            "' " + $d.Lnk + " — 起動用ラッパー (黒い窓を出さない)",
            "CreateObject(""WScript.Shell"").Run ""schtasks.exe /run /tn """"$taskName"""""", 0, False")
        # 旧名 (EdgeBox ...) のアイコンは消して、新しい名前で作り直す
        $oldLnk = $d.Lnk -replace '^Edge Box', 'EdgeBox'
        foreach ($dir in @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))) {
            Remove-Item (Join-Path $dir ($oldLnk + ".lnk")) -Force -ErrorAction SilentlyContinue
        }
        foreach ($lnkPath in @((Join-Path ([Environment]::GetFolderPath("Desktop"))  ($d.Lnk + ".lnk")),
                               (Join-Path ([Environment]::GetFolderPath("Programs")) ($d.Lnk + ".lnk")))) {
            $lnk = $shell.CreateShortcut($lnkPath)
            $lnk.TargetPath       = Join-Path $env:SystemRoot "System32\wscript.exe"
            $lnk.Arguments        = "`"$vbs`""
            $lnk.WorkingDirectory = $PSScriptRoot
            $lnk.IconLocation     = $d.Icon
            $lnk.Description      = $d.Desc
            $lnk.Save()
        }
        Write-Host ("『{0}』をデスクトップとスタートメニューに登録しました。" -f $d.Lnk) -ForegroundColor Green
    }
    exit 0
}

# ============================================================ 実行

if (-not (Test-Admin)) {
    Show-Msg "管理者権限が必要です。デスクトップの『Edge Box 再起動』『Edge Box 画面』アイコンから実行してください (自動で管理者になります)。" "EdgeBox" "Warning"
    exit 1
}
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Show-Msg "登録 '$VMName' が見つかりません。" "EdgeBox" "Warning"; exit 1 }
if (-not (Test-Path $Script03)) { Show-Msg "03-field-display-kiosk.ps1 が見つかりません。配布 ZIP 全体を新しいフォルダーへ展開し直してください。" "EdgeBox" "Warning"; exit 1 }

# --- 『Edge Box 画面』: 左画面にコンソールを表示するだけ ---
if ($ShowOnly) {
    if ([string]$vm.State -ne "Running") {
        try { & $Script03 -VMName $VMName -ApplyResolution | Out-Null } catch { }   # 『設定』の解像度を停止中に反映
        $s11 = Join-Path $PSScriptRoot "11-io-passthrough.ps1"   # 予約された設定 (メモリの固定など) を停止中に反映
        if (Test-Path $s11) { try { & $s11 -VMName $VMName -ApplyPending | Out-Null } catch { } }
        Invoke-EdgeBoxCpuPreparation -VMName $VMName | Out-Null   # full モードなら CPU グループに固定してから起動
        try { Start-VM -VM $vm -ErrorAction Stop } catch {
            Show-Msg "Edge Box を起動できませんでした:`n$($_.Exception.Message)" "Edge Box 画面" "Warning"; exit 1
        }
    }
    # 設定の全画面指定に従って左画面へ。-KeepConsole で自動クローズはしない
    & $Script03 -VMName $VMName -LeftUrl console -RightUrl "" -NoSplash -KeepConsole
    exit 0
}

# --- 『Edge Box 再起動』 ---
if (-not $NoConfirm) {
    $ok = Confirm-Msg ("Edge Box ('$VMName') を再起動します。`n`n" +
        "収集が数分止まります。`n正常にシャットダウンできない場合は、何もせずに中止します。`n`nよろしいですか?") "Edge Box 再起動"
    if (-not $ok) { exit 0 }
}
Import-Module (Join-Path $PSScriptRoot 'vm-shutdown.psm1') -ErrorAction Stop
try {
    Wait-EdgeBoxShutdown -VMName $VMName -ExpectedVmId $vm.Id -TimeoutSec 180
    $current = Get-VM -Id $vm.Id -ErrorAction Stop
    if ($current.Name -ne $VMName -or $current.State -ne 'Off') { throw '停止した VM の登録情報または状態が変わりました。' }
} catch {
    Show-Msg $_.Exception.Message "Edge Box 再起動" "Warning"
    exit 1
}
try { & $Script03 -VMName $VMName -ApplyResolution | Out-Null } catch { }   # 『設定』の解像度を停止中に反映
$s11 = Join-Path $PSScriptRoot "11-io-passthrough.ps1"   # 予約された設定 (メモリの固定など) を停止中に反映
if (Test-Path $s11) { try { & $s11 -VMName $VMName -ApplyPending | Out-Null } catch { } }
Invoke-EdgeBoxCpuPreparation -VMName $VMName | Out-Null   # full モードなら、停止中のいまのうちに CPU グループへ固定してから起動
try { Start-VM -VM $vm -ErrorAction Stop } catch {
    Show-Msg "Edge Box を起動できませんでした:`n$($_.Exception.Message)`n`n.\02-start-field-vm.ps1 -Repair で原因を確認できます。" "Edge Box 再起動" "Warning"
    exit 1
}
# 起動後の画面は、電源 ON のときと同じ流れで出す (設定どおり: 左=コンソール / 右=管理画面)
& $Script03 -VMName $VMName -NoSplash
exit 0
