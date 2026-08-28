<#
.SYNOPSIS
    FIELD system の画面表示を管理します (左右モニターへの自動表示)。
    すべての設定は『FIELD表示設定』の設定コンソール (-Settings) で変更できます。

.EXAMPLE
    .\03-field-display-kiosk.ps1              # 設定内容で今すぐ表示
    .\03-field-display-kiosk.ps1 -Settings    # 設定コンソールを開く
    .\03-field-display-kiosk.ps1 -Setup       # デスクトップに『FIELD表示設定』アイコンを作成
    .\03-field-display-kiosk.ps1 -Install     # ログオン時の自動表示を登録
    .\03-field-display-kiosk.ps1 -Uninstall   # 自動表示を解除
    .\03-field-display-kiosk.ps1 -ConsoleResolution auto   # コンソールの解像度をモニターに合わせる (VM 停止中)

.NOTES
    動作の記録は display-log.txt に残ります (うまく表示されないときはこれを確認)。
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
    [string]$ConsoleResolution,
    [int]$TimeoutSec  = 420
)

$ErrorActionPreference = "Stop"
$TaskName = "FIELD-Display-Kiosk"
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"
$LogFile    = Join-Path $PSScriptRoot "display-log.txt"

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

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
    "_説明"             = "FIELD 表示の設定。『FIELD表示設定』アイコンから編集できます。"
    "RightUrl"          = "https://192.168.0.200/"
    "LeftUrl"           = "console"
    "Kiosk"             = $false
    "EscEnabled"        = $true
    "ConsoleFullScreen" = $true
    "ConsoleStripFrame" = $true
    "ConsoleResolution" = "自動 (モニターに合わせる)"
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
#  コンソール (仮想マシン) の画面解像度
# ============================================================
$ResolutionChoices = @(
    "自動 (モニターに合わせる)",
    "1920x1080", "1920x1200", "1680x1050", "1600x900",
    "1440x900", "1366x768", "1280x1024", "1280x720", "1024x768"
)

# 「1920x1080」「自動」などの文字列を幅・高さに解決する。解釈できなければ $null
function Resolve-ResolutionText([string]$text) {
    $t = ([string]$text).Trim()
    if (-not $t) { return $null }
    if ($t -match '^(auto|自動)') {
        Add-Type -AssemblyName System.Windows.Forms
        $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
        return [pscustomobject]@{ W = $b.Width; H = $b.Height }
    }
    if ($t -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
        return [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2] }
    }
    return $null
}

# 解像度を VM に適用する。実行中なら再起動が要るので、その扱いを $OnRunning で決める
#   "ask" = 確認ダイアログ / "skip" = 何もしない
function Set-ConsoleResolution([int]$w, [int]$h, [string]$OnRunning = "skip") {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return "VM '$VMName' が見つからないため、解像度は反映していません。" }
    if ($vm.State -eq "Off") {
        Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
        return "コンソールの解像度を ${w}x${h} にしました。"
    }
    if ($OnRunning -ne "ask") {
        return "FIELD system が動作中のため、解像度 ${w}x${h} は保存だけしました (次回停止時に反映)。"
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "コンソールの解像度を ${w}x${h} にするには、FIELD system をいったん終了して起動し直す必要があります。`n`n" +
        "今すぐ再起動しますか?`n" +
        "[はい]    FIELD を正常終了 → 解像度を変更 → 起動し直す`n" +
        "[いいえ]  設定だけ保存する (次に FIELD を起動したときに反映)",
        "FIELD 表示設定",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
        return "設定だけ保存しました。次に FIELD system を起動したときに ${w}x${h} で表示されます。"
    }
    Stop-VM -Name $VMName            # ACPI シャットダウン要求 (強制電源断ではない)
    $wsw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($wsw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        return "FIELD system が3分以内に停止しませんでした。解像度は変更していません (強制終了はしていません)。"
    }
    Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
    Start-VM -Name $VMName
    return "解像度を ${w}x${h} にして FIELD system を起動し直しました。"
}

# ============================================================
#  設定コンソール (GUI)
# ============================================================
if ($Settings) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "FIELD 表示設定"
    $form.Size = New-Object System.Drawing.Size(600, 515)
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
    $grpOp.Size = New-Object System.Drawing.Size(555, 120)
    $cbEsc = New-Object System.Windows.Forms.CheckBox
    $cbEsc.Text = "ESC キーでブラウザの最大化を解除する (ブラウザ画面が前面のときのみ)"
    $cbEsc.Location = New-Object System.Drawing.Point(15, 25)
    $cbEsc.Size = New-Object System.Drawing.Size(530, 24)
    $cbEsc.Checked = ($cfg.EscEnabled -ne $false)
    $grpOp.Controls.Add($cbEsc)

    $cbCF = New-Object System.Windows.Forms.CheckBox
    $cbCF.Text = "コンソールを全画面モードで表示 (解除/再開は Ctrl+Alt+Break)"
    $cbCF.Location = New-Object System.Drawing.Point(15, 55)
    $cbCF.Size = New-Object System.Drawing.Size(530, 24)
    $cbCF.Checked = ($cfg.ConsoleFullScreen -ne $false)
    $grpOp.Controls.Add($cbCF)

    $cbSF = New-Object System.Windows.Forms.CheckBox
    $cbSF.Text = "全画面モードが効かないときは、枠とメニューを消して画面いっぱいに広げる"
    $cbSF.Location = New-Object System.Drawing.Point(15, 85)
    $cbSF.Size = New-Object System.Drawing.Size(530, 24)
    $cbSF.Checked = ($cfg.ConsoleStripFrame -ne $false)
    $grpOp.Controls.Add($cbSF)
    $form.Controls.Add($grpOp)

    # --- コンソールの表示サイズ ---
    $grpRes = New-Object System.Windows.Forms.GroupBox
    $grpRes.Text = "コンソールの表示サイズ (FIELD system 側の画面解像度)"
    $grpRes.Location = New-Object System.Drawing.Point(15, 295)
    $grpRes.Size = New-Object System.Drawing.Size(555, 115)

    # このチェック 1 つで「解像度をモニターに合わせる」+「全画面モード」がまとめて有効になる
    $cbFit = New-Object System.Windows.Forms.CheckBox
    $cbFit.Text = "モニターいっぱいに全画面表示する (解像度をモニターに合わせ、全画面モードにする)"
    $cbFit.Location = New-Object System.Drawing.Point(15, 25)
    $cbFit.Size = New-Object System.Drawing.Size(530, 24)
    $resCur = [string]$cfg.ConsoleResolution
    $cbFit.Checked = (((-not $resCur) -or ($resCur -match '^(auto|自動)')) -and ($cfg.ConsoleFullScreen -ne $false))
    $grpRes.Controls.Add($cbFit)

    $grpRes.Controls.Add((New-Label "解像度:" 15 58))
    $cmbRes = New-Object System.Windows.Forms.ComboBox
    $cmbRes.Location = New-Object System.Drawing.Point(85, 55)
    $cmbRes.Size = New-Object System.Drawing.Size(220, 24)
    $cmbRes.DropDownStyle = "DropDown"        # 一覧から選ぶほか、直接入力もできる
    $cmbRes.Items.AddRange($ResolutionChoices)
    $cmbRes.Text = if ($cfg.ConsoleResolution) { [string]$cfg.ConsoleResolution } else { $ResolutionChoices[0] }
    $grpRes.Controls.Add($cmbRes)

    $lblRes = New-Label "一覧にないサイズは直接入力できます (例: 2560x1440)" 315 58
    $lblRes.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes)

    $lblRes2 = New-Label "※ 変更は FIELD system を起動し直したときに反映されます" 15 85
    $lblRes2.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes2)
    $form.Controls.Add($grpRes)

    # チェックに合わせて、解像度欄と全画面モード欄の状態をそろえる
    $syncFit = {
        if ($cbFit.Checked) {
            $cmbRes.Text = $ResolutionChoices[0]
            $cmbRes.Enabled = $false
            $cbCF.Checked = $true
            $cbCF.Enabled = $false
        } else {
            $cmbRes.Enabled = $true
            $cbCF.Enabled = $true
        }
    }
    $cbFit.Add_CheckedChanged($syncFit)
    & $syncFit

    # --- ボタン ---
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(370, 425)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(475, 425)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq "OK") {
        # --- 解像度の指定を解釈する ---
        $resText = $cmbRes.Text.Trim()
        $res = Resolve-ResolutionText $resText
        $resChanged = ($resText -ne [string]$cfg.ConsoleResolution)
        if (-not $res) {
            [System.Windows.Forms.MessageBox]::Show(
                "解像度の指定『$resText』を解釈できませんでした。`n" +
                "「1920x1080」のような形式か、一覧からの選択にしてください。`n`n" +
                "解像度以外の設定は保存します。",
                "FIELD 表示設定",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $resText = [string]$cfg.ConsoleResolution
            $resChanged = $false
        }

        $out = [ordered]@{
            "_説明"             = "FIELD 表示の設定。『FIELD表示設定』アイコンから編集できます。"
            "RightUrl"          = $tbR.Text.Trim()
            "LeftUrl"           = $tbL.Text.Trim()
            "Kiosk"             = $cbK.Checked
            "EscEnabled"        = $cbEsc.Checked
            "ConsoleFullScreen" = $cbCF.Checked
            "ConsoleStripFrame" = $cbSF.Checked
            "ConsoleResolution" = $resText
        }
        $out | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8

        $msg = "保存しました。次回の表示から反映されます。"
        if ($res -and $resChanged) {
            try { $msg += "`n`n" + (Set-ConsoleResolution $res.W $res.H "ask") }
            catch { $msg += "`n`n解像度の変更に失敗しました: $($_.Exception.Message)" }
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "FIELD 表示設定") | Out-Null
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
#  コンソール解像度をモニターに合わせる (VM 停止中のみ)
# ============================================================
if ($ConsoleResolution) {
    $res = Resolve-ResolutionText $ConsoleResolution
    if (-not $res) {
        Write-Error "解像度の指定が不正です。例: -ConsoleResolution 1920x1080  または  -ConsoleResolution auto"
        exit 1
    }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Error "VM '$VMName' がありません。"; exit 1 }
    if ($vm.State -ne "Off") {
        Write-Error "VM を停止してから実行してください (.\05-shutdown-all.ps1 で FIELD だけ終了 → もう一度実行)。"
        exit 1
    }
    Set-VMVideo -VMName $VMName -ResolutionType Single `
        -HorizontalResolution $res.W -VerticalResolution $res.H
    # 設定画面にも反映させておく
    $cfg | Add-Member -NotePropertyName ConsoleResolution -NotePropertyValue $ConsoleResolution -Force
    $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "コンソールの解像度を $($res.W)x$($res.H) に設定しました。" -ForegroundColor Green
    Write-Host "次に VM を起動すると、この解像度で表示されます (.\02-start-field-vm.ps1)。"
    exit 0
}

# ============================================================
#  ログオン時自動実行の登録 / 解除
# ============================================================
if ($Install) {
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # サインイン直後はモニターがまだ 1 枚しか見えないことがあるため、少し待ってから開始する
    try { $trigger.Delay = "PT20S" } catch { Write-Warning "開始遅延を設定できませんでした (動作には影響しません)。" }
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
# ログが育ちすぎないように、大きくなったら作り直す
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) { Remove-Item $LogFile -Force }
Log "===== 表示処理を開始 (左=$LeftUrl / 右=$RightUrl) ====="

# --- VM の起動を待つ ---
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") { break }
    Start-Sleep -Seconds 5
}
Log ("VM の状態: " + $(if ($vm) { $vm.State } else { "見つかりません" }))

# --- モニターの位置 (X座標で左右を判定) ---
# サインイン直後はまだ 2 枚目が認識されていないことがあるため、そろうまで待つ
Add-Type -AssemblyName System.Windows.Forms
$msw = [System.Diagnostics.Stopwatch]::StartNew()
while ($msw.Elapsed.TotalSeconds -lt 90) {
    if (@([System.Windows.Forms.Screen]::AllScreens).Count -ge 2) { break }
    Start-Sleep -Seconds 3
}
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
$leftScreen  = $screens[0]
$rightScreen = $screens[-1]
Log ("認識したモニター: {0} 枚 — {1}" -f $screens.Count,
     (($screens | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)@$($_.Bounds.X)" }) -join " / "))
if ($screens.Count -lt 2) {
    Log "警告: モニターが 1 枚しか認識できません。左右の表示が同じ画面に重なります。"
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
    if (Wait-Url $RightUrl) { Log "右画面用 URL が応答しました: $RightUrl" }
    else { Log "警告: 右画面用 URL が応答しません (それでも開きます): $RightUrl" }
}
if ($LeftUrl -and $LeftUrl -notmatch '^(console|コンソール)$') {
    if (Wait-Url $LeftUrl) { Log "左画面用 URL が応答しました: $LeftUrl" }
    else { Log "警告: 左画面用 URL が応答しません (それでも開きます): $LeftUrl" }
}

$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Log "エラー: Microsoft Edge が見つかりません。"; exit 1 }

# --- ウィンドウ操作用 API ---
if (-not ([System.Management.Automation.PSTypeName]'FieldWin').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class FieldWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetMenu(IntPtr hWnd, IntPtr hMenu);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
}
"@
}

# 前面化のブロック (フォアグラウンドロック) を ALT キー疑似押下で解除してから前面化する
function Force-Foreground([IntPtr]$hwnd) {
    [FieldWin]::keybd_event(0x12, 0, 0, 0)      # ALT down
    [FieldWin]::SetForegroundWindow($hwnd) | Out-Null
    [FieldWin]::keybd_event(0x12, 0, 2, 0)      # ALT up
    Start-Sleep -Milliseconds 400
}

# 指定プロファイルの Edge ウィンドウを探す
function Get-EdgeWindow([string]$profile) {
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 800
        $procIds = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match [regex]::Escape($profile) } |
            Select-Object -ExpandProperty ProcessId)
        if ($procIds.Count -gt 0) {
            $p = Get-Process -Id $procIds -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($p) { return $p.MainWindowHandle }
        }
    }
    return [IntPtr]::Zero
}

function Open-Kiosk([string]$u, $screen, [string]$profile) {
    if (-not $u) { return }
    Log "ブラウザを開きます: $u  (モニター $($screen.Bounds.X),$($screen.Bounds.Y))"
    if ($KioskMode) {
        & $edge --user-data-dir="$env:LOCALAPPDATA\$profile" --no-first-run --new-window `
            --ignore-certificate-errors `
            --window-position="$($screen.Bounds.X),$($screen.Bounds.Y)" `
            --kiosk $u --edge-kiosk-type=fullscreen
    } else {
        # --test-type: 「サポートされていないフラグ」警告バーを非表示にする
        & $edge --user-data-dir="$env:LOCALAPPDATA\$profile" --no-first-run `
            --ignore-certificate-errors --test-type `
            --window-position="$($screen.Bounds.X),$($screen.Bounds.Y)" `
            --app=$u
        # 起動したウィンドウを直接つかんで、対象モニターへ移動 + 最大化 (--start-maximized は app 窓では無視されるため)
        $h = Get-EdgeWindow $profile
        if ($h -ne [IntPtr]::Zero) {
            [FieldWin]::MoveWindow($h, $screen.Bounds.X, $screen.Bounds.Y, 1000, 700, $true) | Out-Null
            Start-Sleep -Milliseconds 300
            [FieldWin]::ShowWindow($h, 3) | Out-Null   # 最大化
            Log "ブラウザのウィンドウを配置しました。"
        } else {
            Log "警告: ブラウザのウィンドウを見つけられませんでした。"
        }
    }
    Start-Sleep -Seconds 2
}

# ウィンドウがモニター全体を覆っているか
function Test-CoversScreen([IntPtr]$hwnd, $screen) {
    $r = New-Object 'FieldWin+RECT'
    if (-not [FieldWin]::GetWindowRect($hwnd, [ref]$r)) { return $false }
    return (($r.Right - $r.Left) -ge ($screen.Bounds.Width - 4) -and
            ($r.Bottom - $r.Top) -ge ($screen.Bounds.Height - 4))
}

# Ctrl+Alt+Break (vmconnect の全画面モード切り替え)
function Send-CtrlAltBreak {
    [FieldWin]::keybd_event(0x11, 0, 0, 0)          # Ctrl down
    [FieldWin]::keybd_event(0x12, 0, 0, 0)          # Alt down
    [FieldWin]::keybd_event(0x03, 0x46, 1, 0)       # Break down (拡張キー)
    Start-Sleep -Milliseconds 60
    [FieldWin]::keybd_event(0x03, 0x46, 3, 0)       # Break up
    [FieldWin]::keybd_event(0x12, 0, 2, 0)          # Alt up
    [FieldWin]::keybd_event(0x11, 0, 2, 0)          # Ctrl up
}

# 全画面モードが効かない場合の代替: 枠・メニューを外してモニター全体に広げる
function Expand-ConsoleWindow([IntPtr]$hwnd, $screen) {
    $GWL_STYLE = -16
    $WS_CAPTION = 0x00C00000; $WS_THICKFRAME = 0x00040000; $WS_BORDER = 0x00800000
    $style = [FieldWin]::GetWindowLong($hwnd, $GWL_STYLE)
    $style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_BORDER))
    [FieldWin]::ShowWindow($hwnd, 1) | Out-Null       # 最大化を解除しないと大きさを変えられない
    Start-Sleep -Milliseconds 300
    [FieldWin]::SetWindowLong($hwnd, $GWL_STYLE, $style) | Out-Null
    if ([FieldWin]::GetMenu($hwnd) -ne [IntPtr]::Zero) { [FieldWin]::SetMenu($hwnd, [IntPtr]::Zero) | Out-Null }
    # 0x0020 = SWP_FRAMECHANGED, 0x0040 = SWP_SHOWWINDOW
    [FieldWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $screen.Bounds.X, $screen.Bounds.Y,
        $screen.Bounds.Width, $screen.Bounds.Height, 0x0060) | Out-Null
}

# --- FIELD のコンソール画面 (vmconnect) を指定モニターに表示 ---
function Open-Console($screen) {
    Log "コンソールを開きます (モニター $($screen.Bounds.X),$($screen.Bounds.Y))"
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
    if ($hwnd -eq [IntPtr]::Zero) { Log "警告: コンソール画面のウィンドウが見つかりませんでした。"; return }

    [FieldWin]::MoveWindow($hwnd, $screen.Bounds.X, $screen.Bounds.Y, 900, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 400
    [FieldWin]::ShowWindow($hwnd, 3) | Out-Null   # 最大化
    Start-Sleep -Milliseconds 600

    if ($cfg.ConsoleFullScreen -eq $false) { Log "コンソール: 全画面モードは設定で無効です。"; return }

    # 全画面モード (メニューバーなし・余白は黒)。解除/再開は Ctrl+Alt+Break
    $done = $false
    for ($try = 1; $try -le 3; $try++) {
        Force-Foreground $hwnd
        if ($try -eq 1) {
            [System.Windows.Forms.SendKeys]::SendWait("^%{BREAK}")
        } else {
            Send-CtrlAltBreak
        }
        Start-Sleep -Milliseconds 1200
        if (Test-CoversScreen $hwnd $screen) { $done = $true; Log "コンソール: 全画面モードになりました (試行 $try)"; break }
    }

    if (-not $done) {
        Log "コンソール: 全画面モードの切り替えが効きませんでした。"
        if ($cfg.ConsoleStripFrame -ne $false) {
            Expand-ConsoleWindow $hwnd $screen
            Log "コンソール: 枠とメニューを外して画面いっぱいに広げました (閉じるときは Alt+F4)。"
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
    Log "ESC キーでブラウザの最大化を解除できます (ブラウザ画面が前面のときのみ)。"
}

Log "===== 表示処理を完了 ====="
