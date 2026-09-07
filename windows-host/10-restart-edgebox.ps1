<#
.SYNOPSIS
    EdgeBox をワンクリックで再起動 / 左画面に表示します。

.DESCRIPTION
    『EdgeBox 再起動』 : 正常シャットダウン → 起動 → 電源 ON のときと同じ画面表示
                        (設定どおり: 左 = コンソール / 右 = 管理画面)。
                        強制電源断は行いません (収集中のデータやファイルシステムを壊しうるため)。
    『EdgeBox 画面』   : 左画面にコンソールを最大化 (設定が全画面なら全画面) で表示します。
                        自動では閉じません。VM が止まっていれば起動してから表示します。

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

# -VMName を明示していない場合、既定名の VM が無ければ、EdgeBox のディスク
# (物理ディスクのパススルー) を持つ VM を探して使う。00-field-launcher.ps1 と
# 同じ考え方で、VM 名が「EdgeBox」でなくても (旧名称のままでも) そのまま動くようにする
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

$Script03 = Join-Path $PSScriptRoot "03-field-display-kiosk.ps1"

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
           Lnk = "EdgeBox 再起動"; Desc = "EdgeBox を正常に再起動して画面を表示 (強制電源断はしない)"; Icon = "shell32.dll,27" },
        @{ Task = "EdgeBox-Console"; Args = "-ShowOnly"; Vbs = "launch-console-view.vbs"
           Lnk = "EdgeBox 画面";   Desc = "左画面に EdgeBox のコンソールを最大化で表示 (自動では閉じない)"; Icon = "shell32.dll,15" }
    )
    foreach ($d in $defs) {
        # UAC 確認なしで実行できるよう、管理者権限付きタスク + wscript 経由のショートカット (黒い窓を出さない)
        $arg = ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`" " + $d.Args).Trim()
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
        $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName $d.Task -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null
        $taskName = $d.Task
        $vbs = Join-Path $PSScriptRoot $d.Vbs
        Set-Content -Path $vbs -Encoding Default -Value @(
            "' " + $d.Lnk + " — 起動用ラッパー (黒い窓を出さない)",
            "CreateObject(""WScript.Shell"").Run ""schtasks.exe /run /tn """"$taskName"""""", 0, False")
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
    Show-Msg "管理者権限が必要です。デスクトップの『EdgeBox 再起動』『EdgeBox 画面』アイコンから実行してください (自動で管理者になります)。" "EdgeBox" "Warning"
    exit 1
}
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Show-Msg "VM '$VMName' が見つかりません。" "EdgeBox" "Warning"; exit 1 }
if (-not (Test-Path $Script03)) { Show-Msg "03-field-display-kiosk.ps1 が見つかりません。update.cmd で更新してください。" "EdgeBox" "Warning"; exit 1 }

# --- 『EdgeBox 画面』: 左画面にコンソールを表示するだけ ---
if ($ShowOnly) {
    if ([string]$vm.State -ne "Running") {
        try { Start-VM -Name $VMName -ErrorAction Stop } catch {
            Show-Msg "EdgeBox を起動できませんでした:`n$($_.Exception.Message)" "EdgeBox 画面" "Warning"; exit 1
        }
    }
    # 設定の全画面指定に従って左画面へ。-KeepConsole で自動クローズはしない
    & $Script03 -VMName $VMName -LeftUrl console -RightUrl "" -NoSplash -KeepConsole
    exit 0
}

# --- 『EdgeBox 再起動』 ---
if (-not $NoConfirm) {
    $ok = Confirm-Msg ("EdgeBox ('$VMName') を再起動します。`n`n" +
        "収集が数分止まります。`n正常にシャットダウンできない場合は、何もせずに中止します。`n`nよろしいですか?") "EdgeBox 再起動"
    if (-not $ok) { exit 0 }
}
if ([string]$vm.State -ne "Off") {
    try { Stop-VM -Name $VMName -ErrorAction Stop } catch {
        Show-Msg ("EdgeBox を停止できませんでした:`n$($_.Exception.Message)`n`n" +
            "EdgeBox の管理画面からシャットダウンしてから、もう一度実行してください。`n(強制電源断は行いません)") "EdgeBox 再起動" "Warning"
        exit 1
    }
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-VM -Name $VMName).State -ne "Off") {
        if ((Get-Date) -gt $deadline) {
            Show-Msg "EdgeBox が 180 秒以内に停止しませんでした。中止します (何も変更していません)。" "EdgeBox 再起動" "Warning"
            exit 1
        }
        Start-Sleep -Seconds 3
    }
}
try { Start-VM -Name $VMName -ErrorAction Stop } catch {
    Show-Msg "EdgeBox を起動できませんでした:`n$($_.Exception.Message)`n`n.\02-start-field-vm.ps1 -Repair で原因を確認できます。" "EdgeBox 再起動" "Warning"
    exit 1
}
# 起動後の画面は、電源 ON のときと同じ流れで出す (設定どおり: 左=コンソール / 右=管理画面)
& $Script03 -VMName $VMName -NoSplash
exit 0
