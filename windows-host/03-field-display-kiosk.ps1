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
    [switch]$Splash,
    [switch]$NoSplash,
    [switch]$Backdrop,
    [string]$BackdropBounds,
    [string]$ConsoleResolution,
    [int]$TimeoutSec  = 420
)

$ErrorActionPreference = "Stop"
$TaskName = "FIELD-Display-Kiosk"
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"
$LogFile    = Join-Path $PSScriptRoot "display-log.txt"
$StatusFile = Join-Path $PSScriptRoot "display-status.txt"

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        # 起動中画面 (スプラッシュ) がこのファイルを読んで進捗を表示する
        Set-Content -Path $StatusFile -Value $m -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

# ============================================================
#  起動中画面: 表示準備が終わるまで、全モニターを黒い画面で覆う
# ============================================================
if ($Splash) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:SplashDeadline = (Get-Date).AddSeconds($TimeoutSec + 120)   # 万一のときは自動で閉じる
    $script:SplashForms = @()
    $script:SplashDots = 0

    function New-SplashForm($bounds) {
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = "None"
        $f.StartPosition = "Manual"
        $f.Bounds = $bounds
        $f.BackColor = [System.Drawing.Color]::Black
        $f.TopMost = $true
        $f.ShowInTaskbar = $false
        $f.KeyPreview = $true
        $f.Add_KeyDown({ param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { [System.Windows.Forms.Application]::Exit() }
        })
        $main = New-Object System.Windows.Forms.Label
        $main.Name = "main"
        $main.Dock = "Fill"
        $main.TextAlign = "MiddleCenter"
        $main.BackColor = [System.Drawing.Color]::Black
        $main.ForeColor = [System.Drawing.Color]::White
        $main.Font = New-Object System.Drawing.Font("Meiryo UI", 26)
        $main.Text = "FIELD system 起動中"
        $f.Controls.Add($main)
        return $f
    }

    # つながっている全モニターを覆う (あとから2枚目が認識されたらそこにも出す)
    function Sync-SplashScreens {
        foreach ($b in @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds })) {
            $covered = @($script:SplashForms | Where-Object { -not $_.IsDisposed -and $_.Bounds -eq $b })
            if ($covered.Count -eq 0) {
                $f = New-SplashForm $b
                $f.Show()
                $script:SplashForms += $f
            }
        }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        if ((Get-Date) -gt $script:SplashDeadline) { [System.Windows.Forms.Application]::Exit(); return }
        $script:SplashDots = ($script:SplashDots + 1) % 4
        foreach ($f in $script:SplashForms) {
            if ($f.IsDisposed) { continue }
            foreach ($c in $f.Controls) {
                if ($c.Name -eq "main") { $c.Text = "FIELD system 起動中" + ("." * $script:SplashDots) }
            }
        }
        Sync-SplashScreens
    })

    Sync-SplashScreens
    $timer.Start()
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
    exit 0
}

# ============================================================
#  黒背景: 指定モニターを黒いウィンドウで覆う (コンソールの余白を黒にする土台)
# ============================================================
if ($Backdrop) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ("BdApi" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class BdApi {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
}
'@
    }
    $p = $BackdropBounds -split ','
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = "None"
    $f.StartPosition = "Manual"
    $f.Bounds = New-Object System.Drawing.Rectangle([int]$p[0], [int]$p[1], [int]$p[2], [int]$p[3])
    $f.BackColor = [System.Drawing.Color]::Black
    $f.ShowInTaskbar = $false
    $f.KeyPreview = $true
    $f.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { [System.Windows.Forms.Application]::Exit() }
    })
    # 黒背景は常に「いちばん後ろ」に居させる (コンソールなど他の窓を隠さないため)
    # 0x0013 = SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE / (-2) = HWND_BOTTOM
    $f.Add_Shown({ param($s, $e) [BdApi]::SetWindowPos($s.Handle, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null })
    $bt = New-Object System.Windows.Forms.Timer
    $bt.Interval = 2000
    $bt.Add_Tick({ if (-not $f.IsDisposed) { [BdApi]::SetWindowPos($f.Handle, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null } })
    $bt.Start()
    $f.Show()
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
    exit 0
}

# ============================================================
#  ESC 見張り役: FIELD 表示用ブラウザ窓が前面・最大化のときだけ ESC で解除
# ============================================================
if ($EscWatcher) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class EscApi {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
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
            if ($edgePids -contains $procId) {
                if ([EscApi]::IsZoomed($h)) {
                    [EscApi]::ShowWindow($h, 9) | Out-Null   # 最大化 → 元のサイズに戻す
                } else {
                    # 全画面 (F11) 状態なら解除する。ウィンドウがモニター全体を覆っているかで判定
                    $r = New-Object 'EscApi+RECT'
                    [EscApi]::GetWindowRect($h, [ref]$r) | Out-Null
                    $b = [System.Windows.Forms.Screen]::FromHandle($h).Bounds
                    if ($r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom) {
                        [System.Windows.Forms.SendKeys]::SendWait("{F11}")
                    }
                }
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
    "RightFullScreen"   = $false
    "LeftUrl"           = "console"
    "LeftFullScreen"    = $true
    "EscEnabled"        = $true
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
# 左右それぞれの全画面指定。設定が無い場合は旧バージョンの設定から引き継ぐ
function Get-SideFullScreen([string]$side, [string]$url) {
    $name = $side + "FullScreen"
    $v = $cfg.$name
    if ($null -ne $v) { return ($v -eq $true) }
    if ($url -match '^(console|コンソール)$') { return ($cfg.ConsoleFullScreen -ne $false) }
    return ($cfg.Kiosk -eq $true)
}
$LeftFull  = Get-SideFullScreen "Left"  $LeftUrl
$RightFull = Get-SideFullScreen "Right" $RightUrl

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
    $form.Size = New-Object System.Drawing.Size(600, 475)
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
    $grpMon.Size = New-Object System.Drawing.Size(555, 130)

    $grpMon.Controls.Add((New-Label "左モニター:" 15 30))
    $tbL = New-Object System.Windows.Forms.TextBox
    $tbL.Location = New-Object System.Drawing.Point(110, 27)
    $tbL.Size = New-Object System.Drawing.Size(330, 24)
    $tbL.Text = [string]$cfg.LeftUrl
    $grpMon.Controls.Add($tbL)

    $cbLF = New-Object System.Windows.Forms.CheckBox
    $cbLF.Text = "全画面"
    $cbLF.Location = New-Object System.Drawing.Point(455, 29)
    $cbLF.Size = New-Object System.Drawing.Size(85, 24)
    $cbLF.Checked = $LeftFull
    $grpMon.Controls.Add($cbLF)

    $grpMon.Controls.Add((New-Label "右モニター:" 15 65))
    $tbR = New-Object System.Windows.Forms.TextBox
    $tbR.Location = New-Object System.Drawing.Point(110, 62)
    $tbR.Size = New-Object System.Drawing.Size(330, 24)
    $tbR.Text = [string]$cfg.RightUrl
    $grpMon.Controls.Add($tbR)

    $cbRF = New-Object System.Windows.Forms.CheckBox
    $cbRF.Text = "全画面"
    $cbRF.Location = New-Object System.Drawing.Point(455, 64)
    $cbRF.Size = New-Object System.Drawing.Size(85, 24)
    $cbRF.Checked = $RightFull
    $grpMon.Controls.Add($cbRF)

    $lblMon = New-Label "全画面 = 枠なしで画面全体 (タスクバーも隠れる) / チェックなし = 最大化ウィンドウ" 15 98
    $lblMon.ForeColor = [System.Drawing.Color]::DimGray
    $grpMon.Controls.Add($lblMon)
    $form.Controls.Add($grpMon)

    # --- 操作 ---
    $grpOp = New-Object System.Windows.Forms.GroupBox
    $grpOp.Text = "操作"
    $grpOp.Location = New-Object System.Drawing.Point(15, 155)
    $grpOp.Size = New-Object System.Drawing.Size(555, 90)
    $cbEsc = New-Object System.Windows.Forms.CheckBox
    $cbEsc.Text = "ESC キーでブラウザの最大化を解除する (ブラウザ画面が前面のときのみ)"
    $cbEsc.Location = New-Object System.Drawing.Point(15, 25)
    $cbEsc.Size = New-Object System.Drawing.Size(530, 24)
    $cbEsc.Checked = ($cfg.EscEnabled -ne $false)
    $grpOp.Controls.Add($cbEsc)

    $cbSF = New-Object System.Windows.Forms.CheckBox
    $cbSF.Text = "コンソールの全画面が効かないときは、黒背景の上に中央表示する (代替の全画面)"
    $cbSF.Location = New-Object System.Drawing.Point(15, 55)
    $cbSF.Size = New-Object System.Drawing.Size(530, 24)
    $cbSF.Checked = ($cfg.ConsoleStripFrame -ne $false)
    $grpOp.Controls.Add($cbSF)
    $form.Controls.Add($grpOp)

    # --- コンソールの表示サイズ ---
    $grpRes = New-Object System.Windows.Forms.GroupBox
    $grpRes.Text = "コンソールの表示サイズ (FIELD system 側の画面解像度)"
    $grpRes.Location = New-Object System.Drawing.Point(15, 255)
    $grpRes.Size = New-Object System.Drawing.Size(555, 115)

    # このチェック 1 つで「解像度をモニターに合わせる」+「コンソール側を全画面」がまとまる
    $cbFit = New-Object System.Windows.Forms.CheckBox
    $cbFit.Text = "モニターいっぱいに全画面表示する (解像度をモニターに合わせ、全画面にする)"
    $cbFit.Location = New-Object System.Drawing.Point(15, 25)
    $cbFit.Size = New-Object System.Drawing.Size(530, 24)
    $resCur = [string]$cfg.ConsoleResolution
    $consoleFull = if ($LeftUrl -match '^(console|コンソール)$') { $LeftFull }
                   elseif ($RightUrl -match '^(console|コンソール)$') { $RightFull }
                   else { $false }
    $cbFit.Checked = (((-not $resCur) -or ($resCur -match '^(auto|自動)')) -and $consoleFull)
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

    # チェックを入れたら、解像度は自動、コンソール側のモニターは全画面にそろえる
    $syncFit = {
        if ($cbFit.Checked) {
            $cmbRes.Text = $ResolutionChoices[0]
            $cmbRes.Enabled = $false
            if ($tbL.Text.Trim() -match '^(console|コンソール)$') { $cbLF.Checked = $true }
            if ($tbR.Text.Trim() -match '^(console|コンソール)$') { $cbRF.Checked = $true }
        } else {
            $cmbRes.Enabled = $true
        }
    }
    $cbFit.Add_CheckedChanged($syncFit)
    & $syncFit

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
            "RightFullScreen"   = $cbRF.Checked
            "LeftUrl"           = $tbL.Text.Trim()
            "LeftFullScreen"    = $cbLF.Checked
            "EscEnabled"        = $cbEsc.Checked
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
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    # 起動中画面 (スプラッシュ) は独立のタスクとして先に走らせる。
    # メイン処理の読み込みを待たず、サインイン直後にできるだけ早く黒画面を出すため
    $sAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Splash"
    $sTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName "$TaskName-Splash" -Action $sAction -Trigger $sTrigger `
        -Settings $taskSettings -RunLevel Highest -Force | Out-Null

    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $taskSettings -RunLevel Highest -Force | Out-Null
    Write-Host "登録しました。次回ログオンから自動で表示されます (起動中は黒い画面で覆います)。" -ForegroundColor Green
    Write-Host "  表示内容の変更: 『FIELD表示設定』アイコン (再登録不要)"
    exit 0
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$TaskName-Splash" -Confirm:$false -ErrorAction SilentlyContinue
    Stop-EscWatcher
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-(Splash|Backdrop)' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
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

# --- 起動中画面: 表示がそろうまでデスクトップを黒い画面で覆う ---
function Stop-Splash {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Splash' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
if (-not $NoSplash) {
    # ログオンタスク (FIELD-Display-Kiosk-Splash) が先に出していればそれを使い、無ければここで出す
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Splash' -and $_.ProcessId -ne $PID })
    if ($existing.Count -eq 0) {
        Start-Process powershell.exe -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Splash -TimeoutSec $TimeoutSec"
    }
}
# 前回の黒背景が残っていれば片付ける
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '-Backdrop' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
try {

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
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
} catch { Log "警告: UI Automation を読み込めませんでした (メニュー操作の代替は使えません)。" }
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
using System.Text;
using System.Runtime.InteropServices;
public class FieldWin {
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr hMenu, uint uIDItem, StringBuilder lpString, int cchMax, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
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

# 前面化のブロック (フォアグラウンドロック) を回避して前面化する。
# ALT キー疑似押下 → 駄目なら AttachThreadInput 方式。成功したかを返す
function Force-Foreground([IntPtr]$hwnd) {
    for ($i = 0; $i -lt 3; $i++) {
        [FieldWin]::keybd_event(0x12, 0, 0, 0)      # ALT down
        [FieldWin]::SetForegroundWindow($hwnd) | Out-Null
        [FieldWin]::keybd_event(0x12, 0, 2, 0)      # ALT up
        Start-Sleep -Milliseconds 300
        if ([FieldWin]::GetForegroundWindow() -eq $hwnd) { return $true }

        # 前面ウィンドウのスレッドに入力を相乗りさせてから前面化する (確実性の高い方式)
        $fg = [FieldWin]::GetForegroundWindow()
        $procId = [uint32]0
        $fgThread = [FieldWin]::GetWindowThreadProcessId($fg, [ref]$procId)
        $myThread = [FieldWin]::GetCurrentThreadId()
        [FieldWin]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
        [FieldWin]::BringWindowToTop($hwnd) | Out-Null
        [FieldWin]::SetForegroundWindow($hwnd) | Out-Null
        [FieldWin]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([FieldWin]::GetForegroundWindow() -eq $hwnd) { return $true }
    }
    return ([FieldWin]::GetForegroundWindow() -eq $hwnd)
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

function Open-Kiosk([string]$u, $screen, [string]$profile, [bool]$fullScreen) {
    if (-not $u) { return }
    Log ("ブラウザを開きます: {0}  (モニター {1},{2} / {3})" -f $u, $screen.Bounds.X, $screen.Bounds.Y,
         $(if ($fullScreen) { "全画面" } else { "最大化ウィンドウ" }))
    # --test-type: 「サポートされていないフラグ」警告バーを非表示にする
    # 全画面指定は --start-fullscreen で最初から全画面にする (F11 と同じ状態 = ESC 見張りで解除可)
    $eargs = @(
        "--user-data-dir=$env:LOCALAPPDATA\$profile", "--no-first-run",
        "--ignore-certificate-errors", "--test-type",
        "--window-position=$($screen.Bounds.X),$($screen.Bounds.Y)",
        "--app=$u"
    )
    if ($fullScreen) { $eargs += "--start-fullscreen" }
    & $edge @eargs
    $h = Get-EdgeWindow $profile
    if ($h -eq [IntPtr]::Zero) { Log "警告: ブラウザのウィンドウを見つけられませんでした。"; return }

    if ($fullScreen -and (Test-CoversScreen $h $screen)) {
        Log "ブラウザ: 全画面表示で開きました。"
        Start-Sleep -Seconds 2
        return
    }

    # 対象モニターへ移動 + 最大化 (--start-maximized は app 窓では無視されるため直接操作する)
    [FieldWin]::MoveWindow($h, $screen.Bounds.X, $screen.Bounds.Y, 1000, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 300
    [FieldWin]::ShowWindow($h, 3) | Out-Null   # 最大化
    Log "ブラウザのウィンドウを配置しました。"

    # 全画面指定なのに全画面になっていない場合 (別モニターで開いた等) は F11 で仕上げる
    if ($fullScreen) {
        for ($try = 1; $try -le 2; $try++) {
            Force-Foreground $h | Out-Null
            [System.Windows.Forms.SendKeys]::SendWait("{F11}")
            Start-Sleep -Milliseconds 900
            if (Test-CoversScreen $h $screen) { Log "ブラウザ: 全画面表示にしました。"; break }
            if ($try -eq 2) { Log "ブラウザ: 全画面化できなかったため最大化ウィンドウのままにします。" }
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

# Win32 メニューを再帰的にたどり、項目名が一致するコマンド (ID と表示名) を探す
function Find-MenuCommand([IntPtr]$menu, [string]$pattern, [int]$depth) {
    if ($depth -gt 3 -or $menu -eq [IntPtr]::Zero) { return $null }
    $sb = New-Object System.Text.StringBuilder 256
    for ($i = 0; $i -lt [FieldWin]::GetMenuItemCount($menu); $i++) {
        [void]$sb.Clear()
        [FieldWin]::GetMenuString($menu, [uint32]$i, $sb, 256, 0x400) | Out-Null   # 0x400 = MF_BYPOSITION
        $text = $sb.ToString()
        $sub = [FieldWin]::GetSubMenu($menu, $i)
        if ($sub -ne [IntPtr]::Zero) {
            $r = Find-MenuCommand $sub $pattern ($depth + 1)
            if ($r) { return $r }
        } elseif ($text -match $pattern) {
            $cmdId = [FieldWin]::GetMenuItemID($menu, $i)
            if ($cmdId -ne [uint32]::MaxValue) {
                return [pscustomobject]@{ Id = $cmdId; Text = $text }
            }
        }
    }
    return $null
}

# Win32 メニューから項目名が一致するコマンドを探し、WM_COMMAND を直接送って実行する。
# 実行した項目の表示名を返す (見つからなければ $null)。フォーカス不要
function Invoke-ConsoleMenuCommand([IntPtr]$hwnd, [string]$pattern) {
    $menu = [FieldWin]::GetMenu($hwnd)
    if ($menu -eq [IntPtr]::Zero) { return $null }
    $hit = Find-MenuCommand $menu $pattern 0
    if (-not $hit) { return $null }
    [FieldWin]::PostMessage($hwnd, 0x0111, [IntPtr][int64]$hit.Id, [IntPtr]::Zero) | Out-Null   # WM_COMMAND
    return $hit.Text
}

# vmconnect のメニュー『表示 → 全画面モード』を UI Automation で直接クリックする
# (キー送信と違い、タイミングやフォーカスの影響を受けにくい)
function Invoke-ConsoleFullScreenMenu([IntPtr]$hwnd) {
    try {
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $condMi = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::MenuItem)

        # メニューバーの「表示」を開く
        $view = $null
        foreach ($i in $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condMi)) {
            if ($i.Current.Name -match '表示|View') { $view = $i; break }
        }
        if (-not $view) { return $false }
        ($view.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
        Start-Sleep -Milliseconds 700

        # 開いた項目から「全画面」を探す (まずメニュー配下、なければ vmconnect のポップアップから)
        $full = $null
        foreach ($i in $view.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condMi)) {
            if ($i.Current.Name -match '全画面|Full') { $full = $i; break }
        }
        if (-not $full) {
            $procId = [uint32]0
            [FieldWin]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
            $pidCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$procId)
            $rootEl = [System.Windows.Automation.AutomationElement]::RootElement
            foreach ($w in $rootEl.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)) {
                foreach ($i in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condMi)) {
                    if ($i.Current.Name -match '全画面|Full') { $full = $i; break }
                }
                if ($full) { break }
            }
        }
        if (-not $full) {
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")   # 開いたメニューを閉じる
            return $false
        }
        ($full.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
        Start-Sleep -Milliseconds 900
        return $true
    } catch { return $false }
}

# ウィンドウ上端からツールバー下端までの高さ (メニュー・ツールバー領域のサイズ)
function Get-ConsoleChromeHeight([IntPtr]$hwnd) {
    try {
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $condTb = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ToolBar)
        $tb = $ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condTb)
        $r = New-Object 'FieldWin+RECT'
        [FieldWin]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        if ($tb) {
            $h = [int]([Math]::Ceiling($tb.Current.BoundingRectangle.Bottom) - $r.Top)
            if ($h -gt 0 -and $h -lt 200) { return $h }
        }
    } catch { }
    return 60   # 取得できなければ標準的なメニュー+ツールバーの高さで近似
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

# 枠を外して指定位置・サイズに固定する
function Set-FramelessWindow([IntPtr]$hwnd, [int]$x, [int]$y, [int]$w, [int]$h) {
    $GWL_STYLE = -16
    $WS_CAPTION = 0x00C00000; $WS_THICKFRAME = 0x00040000; $WS_BORDER = 0x00800000
    [FieldWin]::ShowWindow($hwnd, 1) | Out-Null       # 最大化を解除しないと大きさを変えられない
    Start-Sleep -Milliseconds 300
    $style = [FieldWin]::GetWindowLong($hwnd, $GWL_STYLE)
    $style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_BORDER))
    [FieldWin]::SetWindowLong($hwnd, $GWL_STYLE, $style) | Out-Null
    if ([FieldWin]::GetMenu($hwnd) -ne [IntPtr]::Zero) { [FieldWin]::SetMenu($hwnd, [IntPtr]::Zero) | Out-Null }
    # 0x0020 = SWP_FRAMECHANGED, 0x0040 = SWP_SHOWWINDOW
    [FieldWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x0060) | Out-Null
    [FieldWin]::BringWindowToTop($hwnd) | Out-Null
}

# vmconnect を正しく閉じる (強制終了ではなく通常の閉じ方にして、全画面などの状態を保存させる)
function Close-ConsoleGracefully {
    $procs = @(Get-Process vmconnect -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    foreach ($p in $procs) { [void]$p.CloseMainWindow() }
    # 設定ファイルの書き出しが終わるまで、最大8秒はプロセスの終了を待つ
    $csw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($csw.Elapsed.TotalSeconds -lt 8) {
        if (-not (Get-Process vmconnect -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# vmconnect が保存している「この VM の表示設定」ファイルを探す
function Get-ConsoleConfigFile {
    try {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) { return $null }
        $vmid = $vm.Id.ToString()
        foreach ($root in $env:APPDATA, $env:LOCALAPPDATA) {
            $dir = Join-Path $root "Microsoft\Windows\Hyper-V\Client\1.0"
            $f = Get-ChildItem -Path $dir -Filter "vmconnect.rdp.*.config" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match [regex]::Escape($vmid) } | Select-Object -First 1
            if ($f) { return $f }
        }
        return $null
    } catch { return $null }
}

# 表示設定ファイルの FullScreen を書き換える。
# True にしてから起動すると、切り替え操作なしで最初から全画面で開く
function Set-ConsoleSavedFullScreen([bool]$on) {
    try {
        $file = Get-ConsoleConfigFile
        if (-not $file) { return $false }
        [xml]$x = Get-Content $file.FullName -Raw -Encoding UTF8
        $nodes = $x.SelectNodes("//setting[@name='FullScreen']")
        if (-not $nodes -or $nodes.Count -eq 0) { return $false }
        foreach ($n in $nodes) { $n.InnerText = $(if ($on) { "True" } else { "False" }) }
        $x.Save($file.FullName)
        return $true
    } catch { return $false }
}

# vmconnect を起動してウィンドウハンドルを返す
function Start-ConsoleWindow {
    Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName
    $csw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($csw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Seconds 1
        $p = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

# --- FIELD のコンソール画面 (vmconnect) を指定モニターに表示 ---
function Open-Console($screen, [bool]$fullScreen) {
    Log ("コンソールを開きます (モニター {0},{1} / {2})" -f $screen.Bounds.X, $screen.Bounds.Y,
         $(if ($fullScreen) { "全画面" } else { "最大化ウィンドウ" }))
    # コンソールは同時に1接続のみ。古い窓は「正しく閉じて」状態を保存させる
    Close-ConsoleGracefully

    # 保存設定を「全画面」に書き換えてから起動する (起動した瞬間から全画面になる)
    $NoCfgFlag = Join-Path $PSScriptRoot "vmconnect-config-unsupported.flag"
    if ($fullScreen) {
        if (-not (Get-ConsoleConfigFile) -and -not (Test-Path $NoCfgFlag)) {
            # 初回のみ: 一度開いて正しく閉じ、vmconnect 自身に設定ファイルを作らせる
            Log "コンソール: 設定ファイルが無いため、一度開いて作成させます..."
            $tmp = Start-ConsoleWindow
            if ($tmp -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 1500 }
            Close-ConsoleGracefully
            $cf = Get-ConsoleConfigFile
            if ($cf) { Log "コンソール: 設定ファイルを作成しました ($($cf.Name))。" }
            else {
                # この環境では作られないと判断し、以後この手順は省略する (毎回10秒の無駄を防ぐ)
                New-Item -Path $NoCfgFlag -ItemType File -Force | Out-Null
                Log "コンソール: 設定ファイルは作成されませんでした。以後この手順は省略します。"
                # 実際の保存場所を探すための診断情報
                try {
                    $found = @()
                    foreach ($root in "$env:APPDATA\Microsoft", "$env:LOCALAPPDATA\Microsoft") {
                        $found += Get-ChildItem -Path $root -Recurse -Depth 6 -Filter "vmconnect*" -File -ErrorAction SilentlyContinue |
                            Select-Object -First 5
                    }
                    if ($found.Count -gt 0) {
                        Log ("コンソール: [診断] vmconnect 関連ファイル: " + (($found | ForEach-Object { $_.FullName }) -join " ; "))
                    } else {
                        Log "コンソール: [診断] vmconnect 関連ファイルはプロファイル内に見つかりませんでした。"
                    }
                } catch { }
            }
        }
        if (Set-ConsoleSavedFullScreen $true) { Log "コンソール: 保存設定を全画面に書き換えました。" }
        elseif (-not (Test-Path $NoCfgFlag)) { Log "コンソール: 保存設定を書き換えられなかったため、起動後に切り替えます。" }
    } else {
        Set-ConsoleSavedFullScreen $false | Out-Null
    }

    $hwnd = Start-ConsoleWindow
    if ($hwnd -eq [IntPtr]::Zero) { Log "警告: コンソール画面のウィンドウが見つかりませんでした。"; return }

    # 保存設定が効いて、最初から目的のモニターで全画面になっているか確認
    if ($fullScreen) {
        Start-Sleep -Milliseconds 1200
        if (Test-CoversScreen $hwnd $screen) {
            Log "コンソール: 保存設定により最初から全画面で起動しました。"
            return
        }
        $own = [System.Windows.Forms.Screen]::FromHandle($hwnd)
        if ($own -and ($own.Bounds -ne $screen.Bounds) -and (Test-CoversScreen $hwnd $own)) {
            # 別のモニターで全画面になってしまった → いったん解除してから配置し直す
            Invoke-ConsoleMenuCommand $hwnd '全画面|Full' | Out-Null
            Start-Sleep -Milliseconds 800
        }
    }

    [FieldWin]::MoveWindow($hwnd, $screen.Bounds.X, $screen.Bounds.Y, 900, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 400
    [FieldWin]::ShowWindow($hwnd, 3) | Out-Null   # 最大化
    Start-Sleep -Milliseconds 600

    if (-not $fullScreen) { Log "コンソール: 最大化ウィンドウで表示します (全画面の指定なし)。"; return }

    # 全画面モード (メニューバーなし・余白は黒)。解除/再開は Ctrl+Alt+Break
    $done = $false
    $hadWin32Menu = ([FieldWin]::GetMenu($hwnd) -ne [IntPtr]::Zero)

    # 方法1: メニューの「全画面」コマンドを WM_COMMAND で直接実行 (フォーカス不要で最も確実)
    for ($try = 1; $try -le 2 -and -not $done; $try++) {
        $hit = Invoke-ConsoleMenuCommand $hwnd '全画面|Full'
        if ($hit) {
            Start-Sleep -Milliseconds 1000
            if (Test-CoversScreen $hwnd $screen) { $done = $true; Log "コンソール: 全画面モードになりました (メニューコマンド『$hit』)" }
            else { Log "コンソール: メニューコマンド『$hit』を実行しましたが全画面になりませんでした (試行 $try)" }
        } else { break }   # Win32 メニューが無い場合は方法2へ
    }

    # 方法2: メニュー『表示 → 全画面モード』を UI Automation でクリック
    for ($try = 1; $try -le 2 -and -not $done; $try++) {
        Force-Foreground $hwnd | Out-Null
        if (Invoke-ConsoleFullScreenMenu $hwnd) {
            Start-Sleep -Milliseconds 700
            if (Test-CoversScreen $hwnd $screen) { $done = $true; Log "コンソール: 全画面モードになりました (メニュー操作)" }
        }
    }

    # 方法3: Ctrl+Alt+Break のキー送信
    for ($try = 1; $try -le 2 -and -not $done; $try++) {
        $fgOk = Force-Foreground $hwnd
        if (-not $fgOk) { Log "コンソール: 前面化に失敗 (キー送信 試行 $try)" }
        if ($try -eq 1) { [System.Windows.Forms.SendKeys]::SendWait("^%{BREAK}") } else { Send-CtrlAltBreak }
        Start-Sleep -Milliseconds 1500
        if (Test-CoversScreen $hwnd $screen) { $done = $true; Log "コンソール: 全画面モードになりました (キー送信 試行 $try)" }
    }

    # 方法4: 黒背景を敷き、枠を外したコンソールを「実際の映像サイズ」で中央に重ねる
    if (-not $done) {
        Log "コンソール: 全画面モードの切り替えが効きませんでした。代替表示に切り替えます。"
        if ($cfg.ConsoleStripFrame -ne $false) {
            # VM がいま実際に出している映像の解像度を調べる (設定値ではなく実測)
            $vw = 0; $vh = 0
            try {
                $vm2 = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                if ($vm2) {
                    $head = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VideoHead -ErrorAction SilentlyContinue |
                        Where-Object { $_.SystemName -eq $vm2.Id.ToString() } | Select-Object -First 1
                    if ($head -and [int]$head.CurrentHorizontalResolution -gt 0) {
                        $vw = [int]$head.CurrentHorizontalResolution
                        $vh = [int]$head.CurrentVerticalResolution
                        Log "コンソール: 現在の実映像サイズは ${vw}x${vh} です。"
                    }
                }
            } catch { }
            if ($vw -le 0) {
                try {
                    $vid = Get-VMVideo -VMName $VMName -ErrorAction SilentlyContinue
                    $vw = [int]$vid.HorizontalResolution; $vh = [int]$vid.VerticalResolution
                } catch { }
            }
            if ($vw -le 0 -or $vw -gt $screen.Bounds.Width)  { $vw = [Math]::Min(1024, $screen.Bounds.Width) }
            if ($vh -le 0 -or $vh -gt $screen.Bounds.Height) { $vh = [Math]::Min(768,  $screen.Bounds.Height) }
            if ($vw -lt $screen.Bounds.Width) {
                Log "コンソール: 映像がモニターより小さいため余白は黒になります (FIELD の再起動後はモニターと同じ大きさになります)。"
            }
            $cx = $screen.Bounds.X + [int](($screen.Bounds.Width  - $vw) / 2)
            $cy = $screen.Bounds.Y + [int](($screen.Bounds.Height - $vh) / 2)

            # 黒背景を敷く (黒背景は自分で最背面に下がるので、コンソールを隠さない)
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
                "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Backdrop " +
                "-BackdropBounds `"$($screen.Bounds.X),$($screen.Bounds.Y),$($screen.Bounds.Width),$($screen.Bounds.Height)`"")
            Start-Sleep -Milliseconds 900

            # 枠とメニューを外して実映像サイズで中央に配置し、ステータスバー等も隠す
            Set-FramelessWindow $hwnd $cx $cy $vw $vh
            Start-Sleep -Milliseconds 400
            foreach ($cls in "msctls_statusbar32", "ToolbarWindow32", "msctls_toolbarwindow32", "ReBarWindow32") {
                $child = [FieldWin]::FindWindowEx($hwnd, [IntPtr]::Zero, $cls, $null)
                if ($child -ne [IntPtr]::Zero) { [FieldWin]::ShowWindow($child, 0) | Out-Null }
            }
            [FieldWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $cx, $cy, $vw, $vh, 0x0060) | Out-Null
            [FieldWin]::BringWindowToTop($hwnd) | Out-Null
            Log "コンソール: 黒背景の上に実映像サイズ ${vw}x${vh} で表示しました。"
        }
    }
}

function Open-Display([string]$val, $screen, [string]$profile, [bool]$fullScreen) {
    if (-not $val) { return }
    if ($val -match '^(console|コンソール)$') { Open-Console $screen $fullScreen }
    else { Open-Kiosk $val $screen $profile $fullScreen }
}

Open-Display $RightUrl $rightScreen "FieldKioskR" $RightFull
Open-Display $LeftUrl  $leftScreen  "FieldKioskL" $LeftFull

# --- ESC 見張り役 (ブラウザ表示があれば起動。全画面→最大化→元のサイズ の順に ESC で戻せる) ---
$hasBrowser = (($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$') -or
               ($LeftUrl  -and $LeftUrl  -notmatch '^(console|コンソール)$'))
if ($hasBrowser -and ($cfg.EscEnabled -ne $false)) {
    Stop-EscWatcher
    Start-Process powershell.exe -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -EscWatcher"
    Log "ESC キーでブラウザの全画面/最大化を解除できます (ブラウザ画面が前面のときのみ)。"
}

Log "===== 表示処理を完了 ====="

} finally {
    # 表示がそろったので起動中画面を閉じる (エラーで中断した場合も必ず閉じる)
    Start-Sleep -Milliseconds 500
    Stop-Splash
}
