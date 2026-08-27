<#
.SYNOPSIS
    FIELD system の画面表示を管理します (左右モニターへの自動表示・コンソール自動ログイン)。
    すべての設定は『FIELD表示設定』の設定コンソール (-Settings) で変更できます。

.EXAMPLE
    .\03-field-display-kiosk.ps1              # 設定内容で今すぐ表示
    .\03-field-display-kiosk.ps1 -Settings    # 設定コンソールを開く
    .\03-field-display-kiosk.ps1 -Setup       # デスクトップに『FIELD表示設定』アイコンを作成
    .\03-field-display-kiosk.ps1 -Install     # ログオン時の自動表示を登録
    .\03-field-display-kiosk.ps1 -Uninstall   # 自動表示を解除
#>
[CmdletBinding()]
param(
    [string]$VMName   = "FIELDsystem",
    [string]$RightUrl,
    [string]$LeftUrl,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Settings,
    [switch]$Setup,
    [switch]$EscWatcher,
    [int]$TimeoutSec  = 420
)

$ErrorActionPreference = "Stop"
$TaskName = "FIELD-Display-Kiosk"
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"

# ============================================================
#  ESC 見張り役: FIELD 表示用ブラウザ窓が前面・最大化のときだけ ESC で解除
# ============================================================
if ($EscWatcher) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class EscApi {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    $edgePids = @()
    $lastScan = [datetime]::MinValue
    while ($true) {
        if (((Get-Date) - $lastScan).TotalSeconds -gt 10) {
            $edgePids = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'FieldKiosk' } | Select-Object -ExpandProperty ProcessId)
            $lastScan = Get-Date
        }
        if (([EscApi]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
            $h = [EscApi]::GetForegroundWindow()
            $procId = [uint32]0
            [EscApi]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
            if ($edgePids -contains $procId -and [EscApi]::IsZoomed($h)) {
                [EscApi]::ShowWindow($h, 9) | Out-Null   # 9 = 元のサイズに戻す
            }
            while (([EscApi]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) { Start-Sleep -Milliseconds 50 }
        }
        Start-Sleep -Milliseconds 100
    }
    exit 0
}

function Stop-EscWatcher {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-EscWatcher' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ============================================================
#  設定ファイル
# ============================================================
$DefaultConfig = [ordered]@{
    "_説明"            = "FIELD 表示の設定。『FIELD表示設定』アイコンから編集できます。"
    "RightUrl"         = "https://192.168.0.200/"
    "LeftUrl"          = "console"
    "Kiosk"            = $false
    "EscEnabled"       = $true
    "ConsoleAutoLogin" = $false
    "ConsoleUser"      = ""
    "ConsolePass"      = ""
    "ConsoleFullScreen" = $true
}
if (-not (Test-Path $ConfigFile)) {
    $DefaultConfig | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "設定ファイルを作成しました: $ConfigFile" -ForegroundColor Cyan
}
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $PSBoundParameters.ContainsKey("RightUrl")) { $RightUrl = [string]$cfg.RightUrl }
if (-not $PSBoundParameters.ContainsKey("LeftUrl"))  { $LeftUrl  = [string]$cfg.LeftUrl }
$KioskMode = ($cfg.Kiosk -eq $true)

# ============================================================
#  設定コンソール (GUI)
# ============================================================
if ($Settings) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "FIELD 表示設定"
    $form.Size = New-Object System.Drawing.Size(600, 470)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    function New-Label($text, $x, $y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
        return $l
    }

    # --- モニター表示 ---
    $grpMon = New-Object System.Windows.Forms.GroupBox
    $grpMon.Text = "モニター表示 (URL を入力 / console = FIELDのコンソール画面 / 空欄 = 表示しない)"
    $grpMon.Location = New-Object System.Drawing.Point(15, 15)
    $grpMon.Size = New-Object System.Drawing.Size(555, 140)

    $grpMon.Controls.Add((New-Label "左モニター:" 15 30))
    $tbL = New-Object System.Windows.Forms.TextBox
    $tbL.Location = New-Object System.Drawing.Point(110, 27)
    $tbL.Size = New-Object System.Drawing.Size(425, 24)
    $tbL.Text = [string]$cfg.LeftUrl
    $grpMon.Controls.Add($tbL)

    $grpMon.Controls.Add((New-Label "右モニター:" 15 65))
    $tbR = New-Object System.Windows.Forms.TextBox
    $tbR.Location = New-Object System.Drawing.Point(110, 62)
    $tbR.Size = New-Object System.Drawing.Size(425, 24)
    $tbR.Text = [string]$cfg.RightUrl
    $grpMon.Controls.Add($tbR)

    $cbK = New-Object System.Windows.Forms.CheckBox
    $cbK.Text = "完全固定の全画面 (チェックなし = 最大化ウィンドウ。F11/Win+矢印で切替可)"
    $cbK.Location = New-Object System.Drawing.Point(15, 98)
    $cbK.Size = New-Object System.Drawing.Size(530, 24)
    $cbK.Checked = ($cfg.Kiosk -eq $true)
    $grpMon.Controls.Add($cbK)
    $form.Controls.Add($grpMon)

    # --- 操作 ---
    $grpOp = New-Object System.Windows.Forms.GroupBox
    $grpOp.Text = "操作"
    $grpOp.Location = New-Object System.Drawing.Point(15, 165)
    $grpOp.Size = New-Object System.Drawing.Size(555, 60)
    $cbEsc = New-Object System.Windows.Forms.CheckBox
    $cbEsc.Text = "ESC キーでブラウザの最大化を解除する (ブラウザ画面が前面のときのみ)"
    $cbEsc.Location = New-Object System.Drawing.Point(15, 25)
    $cbEsc.Size = New-Object System.Drawing.Size(530, 24)
    $cbEsc.Checked = ($cfg.EscEnabled -ne $false)
    $grpOp.Controls.Add($cbEsc)
    $form.Controls.Add($grpOp)

    # --- コンソール自動ログイン ---
    $grpCon = New-Object System.Windows.Forms.GroupBox
    $grpCon.Text = "コンソール画面の自動ログイン (VM 起動直後の login プロンプトに自動入力)"
    $grpCon.Location = New-Object System.Drawing.Point(15, 235)
    $grpCon.Size = New-Object System.Drawing.Size(555, 135)

    $cbCon = New-Object System.Windows.Forms.CheckBox
    $cbCon.Text = "自動ログインを有効にする"
    $cbCon.Location = New-Object System.Drawing.Point(15, 25)
    $cbCon.Size = New-Object System.Drawing.Size(230, 24)
    $cbCon.Checked = ($cfg.ConsoleAutoLogin -eq $true)
    $grpCon.Controls.Add($cbCon)

    $cbCF = New-Object System.Windows.Forms.CheckBox
    $cbCF.Text = "全画面モードで表示 (解除は Ctrl+Alt+Break)"
    $cbCF.Location = New-Object System.Drawing.Point(255, 25)
    $cbCF.Size = New-Object System.Drawing.Size(290, 24)
    $cbCF.Checked = ($cfg.ConsoleFullScreen -ne $false)
    $grpCon.Controls.Add($cbCF)

    $grpCon.Controls.Add((New-Label "ユーザー名:" 15 60))
    $tbCU = New-Object System.Windows.Forms.TextBox
    $tbCU.Location = New-Object System.Drawing.Point(110, 57)
    $tbCU.Size = New-Object System.Drawing.Size(240, 24)
    $tbCU.Text = [string]$cfg.ConsoleUser
    $grpCon.Controls.Add($tbCU)

    $grpCon.Controls.Add((New-Label "パスワード:" 15 95))
    $tbCP = New-Object System.Windows.Forms.TextBox
    $tbCP.Location = New-Object System.Drawing.Point(110, 92)
    $tbCP.Size = New-Object System.Drawing.Size(240, 24)
    $tbCP.UseSystemPasswordChar = $true
    $tbCP.Text = [string]$cfg.ConsolePass
    $grpCon.Controls.Add($tbCP)
    $form.Controls.Add($grpCon)

    # --- ボタン ---
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(370, 385)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(475, 385)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq "OK") {
        $out = [ordered]@{
            "_説明"            = "FIELD 表示の設定。『FIELD表示設定』アイコンから編集できます。"
            "RightUrl"         = $tbR.Text.Trim()
            "LeftUrl"          = $tbL.Text.Trim()
            "Kiosk"            = $cbK.Checked
            "EscEnabled"       = $cbEsc.Checked
            "ConsoleAutoLogin" = $cbCon.Checked
            "ConsoleUser"      = $tbCU.Text.Trim()
            "ConsolePass"      = $tbCP.Text
            "ConsoleFullScreen" = $cbCF.Checked
        }
        $out | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("保存しました。次回の表示から反映されます。", "FIELD 表示設定") | Out-Null
    }
    exit 0
}

# ============================================================
#  デスクトップに『FIELD表示設定』アイコンを作成
# ============================================================
if ($Setup) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "FIELD表示設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Settings"
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,21"
    $lnk.Description  = "FIELD 表示の設定コンソール"
    $lnk.Save()
    Write-Host "デスクトップに『FIELD表示設定』アイコンを作成しました。" -ForegroundColor Green
    exit 0
}

# ============================================================
#  ログオン時自動実行の登録 / 解除
# ============================================================
if ($Install) {
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $taskSettings -RunLevel Highest -Force | Out-Null
    Write-Host "登録しました。次回ログオンから自動で表示されます。" -ForegroundColor Green
    Write-Host "  表示内容の変更: 『FIELD表示設定』アイコン (再登録不要)"
    exit 0
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Stop-EscWatcher
    Write-Host "自動表示を解除しました。"
    exit 0
}
if (-not $RightUrl -and -not $LeftUrl) {
    Write-Error "表示する内容がありません。『FIELD表示設定』(-Settings) で設定してください。"
    exit 1
}

# ============================================================
#  表示処理
# ============================================================
# --- VM の起動を待つ ---
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") { break }
    Start-Sleep -Seconds 5
}

# --- Web 画面の応答を待つ (console 指定はスキップ) ---
function Wait-Url([string]$u) {
    if (-not $u) { return $true }
    $uri = [Uri]$u
    $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "https") { 443 } else { 80 }
    while ($script:sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $tcp = New-Object Net.Sockets.TcpClient
            $ok = $tcp.ConnectAsync($uri.Host, $port).Wait(3000)
            $tcp.Dispose()
            if ($ok) { return $true }
        } catch { }
        Start-Sleep -Seconds 5
    }
    return $false
}
if ($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$') {
    if (-not (Wait-Url $RightUrl)) { Write-Warning "右画面用 URL が応答しません: $RightUrl" }
}
if ($LeftUrl -and $LeftUrl -notmatch '^(console|コンソール)$') {
    if (-not (Wait-Url $LeftUrl)) { Write-Warning "左画面用 URL が応答しません: $LeftUrl" }
}

# --- モニターの位置 (X座標で左右を判定) ---
Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }
$leftScreen  = $screens | Select-Object -First 1
$rightScreen = $screens | Select-Object -Last 1

$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Error "Microsoft Edge が見つかりません。"; exit 1 }

function Open-Kiosk([string]$u, $screen, [string]$profile) {
    if (-not $u) { return }
    if ($KioskMode) {
        & $edge --user-data-dir="$env:LOCALAPPDATA\$profile" --no-first-run --new-window `
            --ignore-certificate-errors `
            --window-position="$($screen.Bounds.X),$($screen.Bounds.Y)" `
            --kiosk $u --edge-kiosk-type=fullscreen
    } else {
        & $edge --user-data-dir="$env:LOCALAPPDATA\$profile" --no-first-run `
            --ignore-certificate-errors `
            --window-position="$($screen.Bounds.X),$($screen.Bounds.Y)" `
            --start-maximized --app=$u
    }
    Start-Sleep -Seconds 2
}

# --- SendKeys 用の特殊文字エスケープ ---
function Esc-SendKeys([string]$s) {
    ($s.ToCharArray() | ForEach-Object { if ("$_" -match '[+^%~(){}\[\]]') { "{$_}" } else { "$_" } }) -join ""
}

# --- FIELD のコンソール画面 (vmconnect) を指定モニターに最大化 + 自動ログイン ---
function Open-Console($screen) {
    if (-not ([System.Management.Automation.PSTypeName]'Win32Api').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Api {
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
    }
    # コンソールは同時に1接続のみ。古い窓が残っていると新しい窓に切断ダイアログが出るため、先に閉じる
    Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName
    $hwnd = [IntPtr]::Zero
    $csw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($csw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Seconds 1
        $p = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { $hwnd = $p.MainWindowHandle; break }
    }
    if ($hwnd -eq [IntPtr]::Zero) { Write-Warning "コンソール画面のウィンドウが見つかりませんでした。"; return }

    [Win32Api]::MoveWindow($hwnd, $screen.Bounds.X, $screen.Bounds.Y, 900, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 400
    [Win32Api]::ShowWindow($hwnd, 3) | Out-Null   # 最大化

    # 全画面モード (メニューバーなし・余白は黒)。解除/再開は Ctrl+Alt+Break
    if ($cfg.ConsoleFullScreen -ne $false) {
        [Win32Api]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait("^%{BREAK}")
        Start-Sleep -Milliseconds 800
    }

    # --- 自動ログイン (VM 起動から15分以内 = 新しい login プロンプトのときだけ) ---
    if ($cfg.ConsoleAutoLogin -eq $true -and $cfg.ConsoleUser) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.Uptime.TotalMinutes -lt 15) {
            Start-Sleep -Seconds 3
            [Win32Api]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.SendKeys]::SendWait((Esc-SendKeys ([string]$cfg.ConsoleUser)))
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Start-Sleep -Seconds 2
            [System.Windows.Forms.SendKeys]::SendWait((Esc-SendKeys ([string]$cfg.ConsolePass)))
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Write-Host "コンソールに自動ログインしました。"
        } else {
            Write-Host "コンソール自動ログインをスキップしました (VM 起動から時間が経過しているため。ログイン済みの画面に文字を打ち込まない安全策です)。"
        }
    }
}

function Open-Display([string]$val, $screen, [string]$profile) {
    if (-not $val) { return }
    if ($val -match '^(console|コンソール)$') { Open-Console $screen } else { Open-Kiosk $val $screen $profile }
}

Open-Display $RightUrl $rightScreen "FieldKioskR"
Open-Display $LeftUrl  $leftScreen  "FieldKioskL"

# --- ESC 見張り役 (設定で有効・ブラウザ表示あり・固定キオスクでない場合) ---
$hasBrowser = (($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$') -or
               ($LeftUrl  -and $LeftUrl  -notmatch '^(console|コンソール)$'))
if ($hasBrowser -and -not $KioskMode -and ($cfg.EscEnabled -ne $false)) {
    Stop-EscWatcher
    Start-Process powershell.exe -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -EscWatcher"
    Write-Host "ESC キーでブラウザの最大化を解除できます (ブラウザ画面が前面のときのみ)。"
}

Write-Host "表示しました。"
