<#
.SYNOPSIS
    Edge Box の統合設定コンソール。すべての設定をタブで切り替えて 1 画面で行えます。

.DESCRIPTION
    タブ構成:
      [画面表示]     左右モニターの表示内容・全画面・ESC・コンソール解像度 (03 と同じ設定)
      [自動サインイン] 電源 ON でデスクトップまで自動で進む設定 (06 と同じ設定)

    保存ボタンで全タブの内容をまとめて反映します。
    起動時の見た目 (ロック画面スキップ・壁紙の黒一色化など) は 07-boot-appearance.ps1 で設定します。

.EXAMPLE
    .\08-settings-console.ps1 -Setup   # デスクトップに『設定』アイコンを作成 (最初にこれ)
    .\08-settings-console.ps1          # 設定コンソールを開く

.NOTES
    管理者権限が必要です (『設定』アイコンは管理者実行フラグ付きで作成されます)。
    従来の 03 -Settings / 06 -Settings / 07 も引き続き使えます (設定の保存先は同じ)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Setup
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
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [System.Windows.Forms.MessageBox]::Show(
        "管理者権限が必要です。`nアイコンを右クリックして『管理者として実行』を選んでください。",
        "設定",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 1
}

# ============================================================
#  デスクトップに『設定』アイコンを作成
# ============================================================
if ($Setup) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    # 旧アイコンは統合版に置き換える
    foreach ($old in "EdgeBox表示設定.lnk", "Edge Box表示設定.lnk", "自動サインイン設定.lnk", "EdgeBox設定.lnk") {
        Remove-Item (Join-Path $desktop $old) -Force -ErrorAction SilentlyContinue
    }

    # UAC の確認 (「許可しますか?」) を出さずに開けるよう、
    # 管理者権限付きのタスクとして登録し、アイコンはそのタスクを起動するだけにする
    $taskName = "EdgeBox-Settings-Console"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    # 時間制限なし + 多重起動可 (設定コンソールから表示処理を呼ぶと常駐プロセスが残るため。理由は 10-restart-edgebox.ps1 の -Setup を参照)
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path $desktop "設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,21"
    $lnk.Description  = "Edge Box の統合設定コンソール (UAC 確認なしで開く)"
    $lnk.Save()
    Write-Host "デスクトップに『設定』アイコンを作成しました (旧アイコンは置き換え)。" -ForegroundColor Green
    Write-Host "  UAC の確認なしで、ダブルクリックだけで設定画面が開きます。"
    exit 0
}

# ============================================================
#  Windows API (LSA 秘密領域 / パスワード照合) ※ 06 と同じ方式
# ============================================================
if (-not ("FieldLsa" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class FieldLsa
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING
    {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES
    {
        public int Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint LsaOpenPolicy(IntPtr SystemName,
        ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern uint LsaStorePrivateData(IntPtr PolicyHandle,
        ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);

    [DllImport("advapi32.dll", SetLastError = true, EntryPoint = "LsaStorePrivateData")]
    public static extern uint LsaDeletePrivateData(IntPtr PolicyHandle,
        ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);

    [DllImport("advapi32.dll")]
    public static extern uint LsaClose(IntPtr PolicyHandle);

    [DllImport("advapi32.dll")]
    public static extern int LsaNtStatusToWinError(uint Status);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(string user, string domain, string password,
        int logonType, int logonProvider, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

function New-LsaString([string]$s) {
    $u = New-Object 'FieldLsa+LSA_UNICODE_STRING'
    $u.Buffer        = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($s)
    $u.Length        = [uint16](2 * $s.Length)
    $u.MaximumLength = [uint16](2 * $s.Length + 2)
    return $u
}

function Open-LsaPolicy {
    $oa = New-Object 'FieldLsa+LSA_OBJECT_ATTRIBUTES'
    $oa.Length = [Runtime.InteropServices.Marshal]::SizeOf($oa)
    $h = [IntPtr]::Zero
    $st = [FieldLsa]::LsaOpenPolicy([IntPtr]::Zero, [ref]$oa, 0x000F0FFF, [ref]$h)
    if ($st -ne 0) { throw "Windows の資格情報保存領域を開けませんでした。" }
    return $h
}

function Set-AutoLogonSecret([string]$password) {
    $h = Open-LsaPolicy
    try {
        $k = New-LsaString "DefaultPassword"
        $v = New-LsaString $password
        $st = [FieldLsa]::LsaStorePrivateData($h, [ref]$k, [ref]$v)
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($v.Buffer)
        [Runtime.InteropServices.Marshal]::FreeHGlobal($k.Buffer)
        if ($st -ne 0) { throw "パスワードの保存に失敗しました。" }
    } finally { [FieldLsa]::LsaClose($h) | Out-Null }
}

function Remove-AutoLogonSecret {
    $h = Open-LsaPolicy
    try {
        $k = New-LsaString "DefaultPassword"
        [FieldLsa]::LsaDeletePrivateData($h, [ref]$k, [IntPtr]::Zero) | Out-Null
        [Runtime.InteropServices.Marshal]::FreeHGlobal($k.Buffer)
    } finally { [FieldLsa]::LsaClose($h) | Out-Null }
}

function Test-Password([string]$user, [string]$domain, [string]$password) {
    $tok = [IntPtr]::Zero
    $domains = @($domain, ".", $env:COMPUTERNAME) | Where-Object { $_ } | Select-Object -Unique
    foreach ($d in $domains) {
        foreach ($t in 2, 3, 8) {
            if ([FieldLsa]::LogonUser($user, $d, $password, $t, 0, [ref]$tok)) {
                [FieldLsa]::CloseHandle($tok) | Out-Null
                return $true
            }
            if ([Runtime.InteropServices.Marshal]::GetLastWin32Error() -eq 1326) { break }
        }
    }
    return $false
}

# ============================================================
#  レジストリ設定の読み書き
# ============================================================
$WinlogonKey  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$PwdLessKey   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
$PowerSubNone = "fea3413e-7e05-4911-9a71-700331f1c294"
$PowerWakePwd = "0e796bdb-100d-47d6-a2d5-f7d2daa51f51"

function Get-AutoLogonState {
    $wl = Get-ItemProperty $WinlogonKey -ErrorAction SilentlyContinue
    $u = [string]$wl.DefaultUserName
    $d = [string]$wl.DefaultDomainName
    if (-not $u) { $u = $env:USERNAME }
    if (-not $d) { $d = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME } }
    return [pscustomobject]@{ Enabled = ($wl.AutoAdminLogon -eq "1"); UserName = $u; Domain = $d }
}

function Split-Account([string]$text) {
    $t = $text.Trim()
    if ($t -match '^(.+?)\\(.+)$') { return [pscustomobject]@{ Domain = $Matches[1]; User = $Matches[2] } }
    if ($t -match '^(.+)@(.+)$')   { return [pscustomobject]@{ Domain = $env:COMPUTERNAME; User = $t } }
    $d = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME }
    return [pscustomobject]@{ Domain = $d; User = $t }
}

# ============================================================
#  表示設定 (display-config.json)
# ============================================================
$DefaultConfig = [ordered]@{
    "_説明"             = "Edge Box 表示の設定。『設定』アイコンから編集できます。"
    "RightUrl"          = ""       # 右画面は通常の Windows デスクトップ (URL を入れるとブラウザで表示)
    "RightFullScreen"   = $false
    "LeftUrl"           = "console"
    "LeftFullScreen"    = $true
    "RightBrowserV2"    = $true
    "EscEnabled"        = $true
    "ConsoleStripFrame" = $true
    "ConsoleAutoClose"  = $false
    "ConsoleAutoCloseV2" = $true
    "ConsoleHideBar"    = $true
    "LeftGuard"         = $true
    "LeftGuardHotkey"   = "Alt+F11"
    "ConsoleResolution" = "自動 (モニターに合わせる)"
}
if (-not (Test-Path $ConfigFile)) {
    $DefaultConfig | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
}
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

# ============================================================
#  画面の構築
# ============================================================
# --- 普通のアプリらしく見せる: 専用のアイコンと、タスクバーでの独立 ---
# これを入れないと、PowerShell のアイコンで PowerShell と同じ束にまとめられてしまう
if (-not ("Win.AppShell" -as [type])) {
    Add-Type -Namespace Win -Name AppShell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction SilentlyContinue
}
try { [Win.AppShell]::SetCurrentProcessExplicitAppUserModelID("Edge Box.Settings") | Out-Null } catch { }

# --- 見た目: 『CPU割り当て』と同じ配色 (このフォルダだけで完結させるため、ここで直接指定する) ---
$UiBg      = [System.Drawing.Color]::FromArgb(97, 96, 97)     # 背景 #616061
$UiBg2     = [System.Drawing.Color]::FromArgb(117, 116, 117)  # 操作バー #757475 (『CPU割り当て』の操作バーと同じ)
$UiPanel   = [System.Drawing.Color]::FromArgb(117, 116, 117)  # カード #757475
$UiControl = [System.Drawing.Color]::FromArgb(94, 93, 94)     # ボタン・入力欄
$UiHover   = [System.Drawing.Color]::FromArgb(104, 103, 104)
$UiDown    = [System.Drawing.Color]::FromArgb(85, 84, 85)
$UiBorder  = [System.Drawing.Color]::FromArgb(142, 141, 142)  # 境界線
$UiStrong  = [System.Drawing.Color]::FromArgb(181, 180, 181)
$UiText    = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 文字 (灰色の上で読めるよう白)
$UiSub     = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 補助の文字 (#757475 の上で読めるのは白だけのため白)
$UiSilver  = [System.Drawing.Color]::FromArgb(242, 242, 242)  # フォーカス
$UiFont    = New-Object System.Drawing.Font("Meiryo UI", 9)
$UiBold    = New-Object System.Drawing.Font("Meiryo UI", 9.75, [System.Drawing.FontStyle]::Bold)

function Get-AppIcon([string]$Style) {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        # アイコンは他のアイコンと同じ濃い色の本体 (画面の配色とは別)
        $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 24, 32))
        $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(53, 67, 82))
        $win  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(86, 180, 255))
        $vm   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(242, 166, 90))
        $g.FillRectangle($body, 2, 2, 28, 28)
        $g.DrawRectangle($edge, 2, 2, 27, 27)
        switch ($Style) {
            "monitor" {
                $g.FillRectangle($win, 8, 17, 5, 7); $g.FillRectangle($vm, 14, 10, 5, 14); $g.FillRectangle($win, 20, 19, 5, 5)
            }
            "settings" {
                $g.FillRectangle($win, 8, 9, 16, 4); $g.FillRectangle($vm, 8, 16, 16, 4); $g.FillRectangle($win, 8, 23, 10, 3)
            }
            default {
                $g.FillRectangle($win, 8, 8, 6, 16); $g.FillRectangle($vm, 18, 8, 6, 16)
            }
        }
        $g.Dispose()
        $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        return $ico
    } catch { return $null }
}

# タイトルバーも背景の色にそろえる (Windows 10 2004 以降 / 11。使えない環境では標準のまま)
if (-not ("EdgeBoxSettingsUi.Dwm" -as [type])) {
    Add-Type -Namespace EdgeBoxSettingsUi -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@ -ErrorAction SilentlyContinue
}

$form = New-Object System.Windows.Forms.Form
$appIcon = Get-AppIcon "settings"
if ($appIcon) { $form.Icon = $appIcon }
$form.Text = "設定"
$form.TopMost = $true          # 全画面表示のブラウザ等に隠れないように
$form.Add_Shown({ $form.Activate() })
$form.ClientSize = New-Object System.Drawing.Size(624, 318)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $UiBg
$form.ForeColor = $UiText
$form.Font = $UiFont
$form.Add_HandleCreated({
    try {
        $on = 1;  [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
        $cap = 0x00616061; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 35, [ref]$cap, 4)
        $brd = 0x008E8D8E; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 34, [ref]$brd, 4)
        $txt = 0x00FFFFFF; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 36, [ref]$txt, 4)
    } catch { }
})

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = $UiText
    return $l
}
function New-Check($text, $x, $y, $w, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 26)
    $c.Checked = $checked
    $c.FlatStyle = "Flat"
    $c.FlatAppearance.BorderColor = $UiStrong
    $c.FlatAppearance.CheckedBackColor = $UiControl
    $c.FlatAppearance.MouseOverBackColor = $UiHover
    $c.FlatAppearance.MouseDownBackColor = $UiControl
    $c.BackColor = $UiBg
    $c.ForeColor = $UiText
    $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    # 標準の平らな四角は灰色の上で見えにくいため、四角と文字をここで描き直す (状態と操作は CheckBox のまま)
    $c.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.Clear($s.BackColor)
        $y = [int](($s.Height - 14) / 2)
        $b = New-Object System.Drawing.SolidBrush ($(if ($s.Checked) { $UiSilver } else { $UiControl }))
        $g.FillRectangle($b, 1, $y, 14, 14); $b.Dispose()
        $p = New-Object System.Drawing.Pen ($(if ($s.Checked) { $UiSilver } else { $UiStrong }))
        $g.DrawRectangle($p, 1, $y, 13, 13); $p.Dispose()
        if ($s.Checked) {
            $g.SmoothingMode = "AntiAlias"
            $k = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(28, 28, 28)), 2
            $g.DrawLines($k, [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF(4, ($y + 7))),
                (New-Object System.Drawing.PointF(6.5, ($y + 10))),
                (New-Object System.Drawing.PointF(11.5, ($y + 3.5)))))
            $k.Dispose()
            $g.SmoothingMode = "Default"
        }
        if ($s.Focused) { [System.Windows.Forms.ControlPaint]::DrawFocusRectangle($g, (New-Object System.Drawing.Rectangle(0, ($y - 1), 16, 16))) }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, (New-Object System.Drawing.Rectangle(22, 0, ($s.Width - 22), $s.Height)),
            $s.ForeColor, [System.Windows.Forms.TextFormatFlags]"VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix")
    })
    return $c
}
# 入力欄: 細い枠の中に置く (フォーカス中は枠を明るく)
function New-Field($tb, $x, $y, $w) {
    $frame = New-Object System.Windows.Forms.Panel
    $frame.Location = New-Object System.Drawing.Point($x, $y)
    $frame.Size = New-Object System.Drawing.Size($w, 30)
    $frame.BackColor = $UiBorder
    $frame.Padding = New-Object System.Windows.Forms.Padding(1)
    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = "Fill"
    $inner.BackColor = $UiControl
    $inner.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
    $tb.BorderStyle = "None"
    $tb.BackColor = $UiControl
    $tb.ForeColor = $UiText
    $tb.Dock = "Fill"
    $inner.Controls.Add($tb)
    $frame.Controls.Add($inner)
    $tb.Add_Enter({ $this.Parent.Parent.BackColor = $UiSilver })
    $tb.Add_Leave({ $this.Parent.Parent.BackColor = $UiBorder })
    return $frame
}
function New-FlatButton($text, $x, $y, $w, [bool]$Primary = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = "Flat"
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(62, 61, 62) } else { $UiControl })
    $b.ForeColor = $UiText
    $b.FlatAppearance.BorderColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(198, 198, 198) } else { $UiBorder })
    $b.FlatAppearance.MouseOverBackColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(78, 77, 78) } else { $UiHover })
    $b.FlatAppearance.MouseDownBackColor = $UiDown
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) { $b.Font = New-Object System.Drawing.Font("Meiryo UI", 9, [System.Drawing.FontStyle]::Bold) }
    return $b
}

$alState = Get-AutoLogonState

$cbAuto = New-Check "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む" 18 18 588 $alState.Enabled
$form.Controls.Add($cbAuto)

# 枠付きのパネル (見出しを左上に描く)
$grpAcc = New-Object System.Windows.Forms.Panel
$grpAcc.Location = New-Object System.Drawing.Point(16, 56)
$grpAcc.Size = New-Object System.Drawing.Size(592, 168)
$grpAcc.BackColor = $UiPanel
$grpAcc.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen ($UiBorder)
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "サインインするアカウント", $UiBold, (New-Object System.Drawing.Point(16, 13)), $UiText)
})
$grpAcc.Controls.Add((New-Label "アカウント名" 16 54))
$tbUser = New-Object System.Windows.Forms.TextBox
$tbUser.Text = $alState.UserName
$grpAcc.Controls.Add((New-Field $tbUser 130 48 444))
$grpAcc.Controls.Add((New-Label "パスワード" 16 92))
$tbPass = New-Object System.Windows.Forms.TextBox
$tbPass.UseSystemPasswordChar = $true
$tbPass.Add_TextChanged({ if ($tbPass.Text) { $cbAuto.Checked = $true } })
$grpAcc.Controls.Add((New-Field $tbPass 130 86 444))
$lblPw = New-Label "※ パスワード欄を空のまま保存すると、今保存されているパスワードをそのまま使います。" 16 124
$lblPw.ForeColor = $UiSub
$grpAcc.Controls.Add($lblPw)
$lblPw2 = New-Label "※ PIN は使えません。Windows のパスワードを入力してください。" 16 143
$lblPw2.ForeColor = $UiSub
$grpAcc.Controls.Add($lblPw2)
$form.Controls.Add($grpAcc)

$lblAl = New-Label "現在: $(if ($alState.Enabled) { '有効' } else { '無効' })  ($($alState.Domain)\$($alState.UserName))" 18 234
$lblAl.ForeColor = $UiSub
$form.Controls.Add($lblAl)

# ------------------------------------------------------------
#  保存 / 閉じる
# ------------------------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = "Bottom"
$footer.Height = 60
$footer.BackColor = $UiBg2
$footer.Add_Paint({ param($s, $e) $p = New-Object System.Drawing.Pen ($UiBorder); $e.Graphics.DrawLine($p, 0, 0, $s.Width, 0); $p.Dispose() })
$btnOK = New-FlatButton "保存" 400 13 100 $true
$btnOK.DialogResult = "OK"
$btnCancel = New-FlatButton "閉じる" 508 13 100
$btnCancel.DialogResult = "Cancel"
$footer.Controls.AddRange(@($btnOK, $btnCancel))
$form.Controls.Add($footer)
$form.AcceptButton = $btnOK
$form.CancelButton = $btnCancel

if ($form.ShowDialog() -ne "OK") { exit 0 }

$messages = @()

# --- 自動サインインの保存 ---
try {
    if ($cbAuto.Checked) {
        $acct = Split-Account $tbUser.Text
        $pass = $tbPass.Text
        $accountChanged = ($acct.User -ne $alState.UserName -or $acct.Domain -ne $alState.Domain)
        $proceed = $true
        if (-not $acct.User) {
            $messages += "自動サインイン: アカウント名が空のため変更しませんでした。"
            $proceed = $false
        } elseif ($pass -eq "" -and ($accountChanged -or -not $alState.Enabled)) {
            $messages += "自動サインイン: 新しく有効にする/アカウントを変えるにはパスワードの入力が必要なため、変更しませんでした。"
            $proceed = $false
        } elseif ($pass -ne "" -and -not (Test-Password $acct.User $acct.Domain $pass)) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "自動サインイン: このアカウント名とパスワードでのサインインを事前確認できませんでした。`n" +
                "(確認のしくみ側の制限の場合もあります。間違っていても PC は壊れません)`n`n" +
                "この内容で保存しますか?",
                "設定",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
                $messages += "自動サインイン: 保存を中止しました。"
                $proceed = $false
            }
        }
        if ($proceed) {
            if ($pass -ne "") { Set-AutoLogonSecret $pass }
            if (-not (Test-Path $PwdLessKey)) { New-Item -Path $PwdLessKey -Force | Out-Null }
            Set-ItemProperty $PwdLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
            Set-ItemProperty $WinlogonKey -Name AutoAdminLogon    -Value "1"          -Type String
            Set-ItemProperty $WinlogonKey -Name DefaultUserName   -Value $acct.User   -Type String
            Set-ItemProperty $WinlogonKey -Name DefaultDomainName -Value $acct.Domain -Type String
            Remove-ItemProperty $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
            Remove-ItemProperty $WinlogonKey -Name AutoLogonCount  -ErrorAction SilentlyContinue
            powercfg /SETACVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 0 | Out-Null
            powercfg /SETDCVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 0 | Out-Null
            powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
            $messages += "自動サインイン: 有効にしました ($($acct.Domain)\$($acct.User))。"
        }
    } elseif ($alState.Enabled) {
        Set-ItemProperty $WinlogonKey -Name AutoAdminLogon -Value "0" -Type String
        Remove-ItemProperty $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
        Remove-AutoLogonSecret
        powercfg /SETACVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 1 | Out-Null
        powercfg /SETDCVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 1 | Out-Null
        powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
        $messages += "自動サインイン: 解除しました (次回からサインイン画面が表示されます)。"
    }
} catch {
    $messages += "自動サインインの設定に失敗しました: $($_.Exception.Message)"
} finally {
    $tbPass.Text = ""
}

[System.Windows.Forms.MessageBox]::Show(($messages -join "`n`n"), "設定") | Out-Null
exit 0
