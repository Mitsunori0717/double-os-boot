<#
.SYNOPSIS
    EdgeBox の統合設定コンソール。すべての設定をタブで切り替えて 1 画面で行えます。

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

# -VMName を明示していない場合、既定名の EdgeBox が無ければ、EdgeBox のディスク
# (物理ディスクのパススルー) を持つ EdgeBox を探して使う。00-field-launcher.ps1 と
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
    foreach ($old in "EdgeBox表示設定.lnk", "自動サインイン設定.lnk", "EdgeBox設定.lnk") {
        Remove-Item (Join-Path $desktop $old) -Force -ErrorAction SilentlyContinue
    }

    # UAC の確認 (「許可しますか?」) を出さずに開けるよう、
    # 管理者権限付きのタスクとして登録し、アイコンはそのタスクを起動するだけにする
    $taskName = "EdgeBox-Settings-Console"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path $desktop "設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,21"
    $lnk.Description  = "EdgeBox の統合設定コンソール (UAC 確認なしで開く)"
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
    "_説明"             = "EdgeBox 表示の設定。『設定』アイコンから編集できます。"
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

$ResolutionChoices = @(
    "自動 (モニターに合わせる)",
    "1920x1080", "1920x1200", "1680x1050", "1600x900",
    "1440x900", "1366x768", "1280x1024", "1280x720", "1024x768"
)

function Resolve-ResolutionText([string]$text) {
    $t = ([string]$text).Trim()
    if (-not $t) { return $null }
    if ($t -match '^(auto|自動)') {
        $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
        return [pscustomobject]@{ W = $b.Width; H = $b.Height }
    }
    if ($t -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
        return [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2] }
    }
    return $null
}

function Set-ConsoleResolution([int]$w, [int]$h) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return "登録 '$VMName' が見つからないため、解像度は反映していません。" }
    if ($vm.State -eq "Off") {
        Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
        return "コンソールの解像度を ${w}x${h} にしました。"
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "コンソールの解像度を ${w}x${h} にするには、EdgeBox をいったん終了して起動し直す必要があります。`n`n" +
        "今すぐ再起動しますか?`n[はい] 正常終了 → 変更 → 起動し直す`n[いいえ] 設定だけ保存 (次回起動時に反映)",
        "設定",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
        return "解像度は保存のみ。次に EdgeBox を起動し直したときに反映されます。"
    }
    Stop-VM -Name $VMName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        return "EdgeBox が3分以内に停止しませんでした。解像度は変更していません。"
    }
    Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
    Start-VM -Name $VMName
    return "解像度を ${w}x${h} にして EdgeBox を起動し直しました。"
}

# ============================================================
#  画面の構築
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "設定"
$form.TopMost = $true          # 全画面表示のブラウザ等に隠れないように
$form.Add_Shown({ $form.Activate() })
$form.Size = New-Object System.Drawing.Size(660, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    return $l
}
function New-Check($text, $x, $y, $w, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 24)
    $c.Checked = $checked
    return $c
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 12)
$tabs.Size = New-Object System.Drawing.Size(620, 440)

# ------------------------------------------------------------
#  タブ1: 画面表示
# ------------------------------------------------------------
$tp1 = New-Object System.Windows.Forms.TabPage
$tp1.Text = "画面表示"
$tp1.BackColor = [System.Drawing.SystemColors]::Control

$tp1.Controls.Add((New-Label "モニターに表示する内容 (URL / console = EdgeBox のコンソール画面 / 空欄 = 表示しない)" 15 15))

$tp1.Controls.Add((New-Label "左モニター:" 15 45))
$tbL = New-Object System.Windows.Forms.TextBox
$tbL.Location = New-Object System.Drawing.Point(110, 42)
$tbL.Size = New-Object System.Drawing.Size(360, 24)
$tbL.Text = [string]$cfg.LeftUrl
$tp1.Controls.Add($tbL)
$cbLF = New-Check "全画面" 485 44 100 ($cfg.LeftFullScreen -eq $true)
$tp1.Controls.Add($cbLF)

$tp1.Controls.Add((New-Label "右モニター:" 15 80))
$tbR = New-Object System.Windows.Forms.TextBox
$tbR.Location = New-Object System.Drawing.Point(110, 77)
$tbR.Size = New-Object System.Drawing.Size(360, 24)
$tbR.Text = [string]$cfg.RightUrl
$tp1.Controls.Add($tbR)
$cbRF = New-Check "全画面" 485 79 100 ($cfg.RightFullScreen -eq $true)
$tp1.Controls.Add($cbRF)

$lblFs = New-Label "右モニター 空欄 = 通常のデスクトップ (起動中だけ『EdgeBox 起動中』を表示) / 全画面 = 枠なしで画面全体" 110 108
$lblFs.ForeColor = [System.Drawing.Color]::DimGray
$tp1.Controls.Add($lblFs)

$cbEsc = New-Check "ESC キーでブラウザの全画面/最大化を解除する (ブラウザが前面のときのみ)" 15 140 580 ($cfg.EscEnabled -ne $false)
$tp1.Controls.Add($cbEsc)
$cbSF = New-Check "コンソールの全画面が効かないときは、黒背景の上に中央表示する (代替の全画面)" 15 170 580 ($cfg.ConsoleStripFrame -ne $false)
$tp1.Controls.Add($cbSF)
$cbAC = New-Check "EdgeBox の起動を確認したら、コンソール画面を自動で閉じる (通常はオフ。閉じても EdgeBox は動き続ける)" 15 200 580 ($cfg.ConsoleAutoClose -eq $true)
$tp1.Controls.Add($cbAC)
$cbBar = New-Check "コンソールが全画面のとき、上の接続バー (「localhost 上の EdgeBox」の帯) を表示しない" 15 230 580 ($cfg.ConsoleHideBar -ne $false)
$tp1.Controls.Add($cbBar)
$lgHot = if ($cfg.LeftGuardHotkey) { [string]$cfg.LeftGuardHotkey } else { "Alt+F11" }
$cbLG = New-Check "左画面を EdgeBox の全画面で固定する (他の窓は右画面へ移し、全画面が外れたら戻す。解除/再固定: $lgHot)" 15 260 580 ($cfg.LeftGuard -ne $false)
$tp1.Controls.Add($cbLG)

$grpRes = New-Object System.Windows.Forms.GroupBox
$grpRes.Text = "コンソールの表示サイズ (EdgeBox 側の画面解像度)"
$grpRes.Location = New-Object System.Drawing.Point(15, 300)
$grpRes.Size = New-Object System.Drawing.Size(580, 120)

$cbFit = New-Check "モニターいっぱいに全画面表示する (解像度をモニターに合わせ、全画面にする)" 15 25 550 $false
$grpRes.Controls.Add($cbFit)

$grpRes.Controls.Add((New-Label "解像度:" 15 62))
$cmbRes = New-Object System.Windows.Forms.ComboBox
$cmbRes.Location = New-Object System.Drawing.Point(85, 59)
$cmbRes.Size = New-Object System.Drawing.Size(220, 24)
$cmbRes.DropDownStyle = "DropDown"
$cmbRes.Items.AddRange($ResolutionChoices)
$cmbRes.Text = if ($cfg.ConsoleResolution) { [string]$cfg.ConsoleResolution } else { $ResolutionChoices[0] }
$grpRes.Controls.Add($cmbRes)
$lblRes = New-Label "一覧にないサイズは直接入力 (例: 2560x1440)" 315 62
$lblRes.ForeColor = [System.Drawing.Color]::DimGray
$grpRes.Controls.Add($lblRes)
$lblRes2 = New-Label "※ 変更は EdgeBox の起動し直しで反映 (保存時に選択できます)" 15 90
$lblRes2.ForeColor = [System.Drawing.Color]::DimGray
$grpRes.Controls.Add($lblRes2)
$tp1.Controls.Add($grpRes)

$resCur = [string]$cfg.ConsoleResolution
$consoleFull = if (([string]$cfg.LeftUrl) -match '^(console|コンソール)$') { $cfg.LeftFullScreen -eq $true }
               elseif (([string]$cfg.RightUrl) -match '^(console|コンソール)$') { $cfg.RightFullScreen -eq $true }
               else { $false }
$cbFit.Checked = (((-not $resCur) -or ($resCur -match '^(auto|自動)')) -and $consoleFull)
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

# ------------------------------------------------------------
#  タブ2: 自動サインイン
# ------------------------------------------------------------
$tp2 = New-Object System.Windows.Forms.TabPage
$tp2.Text = "自動サインイン"
$tp2.BackColor = [System.Drawing.SystemColors]::Control

$alState = Get-AutoLogonState

$cbAuto = New-Check "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む" 15 20 580 $alState.Enabled
$tp2.Controls.Add($cbAuto)

$grpAcc = New-Object System.Windows.Forms.GroupBox
$grpAcc.Text = "サインインするアカウント"
$grpAcc.Location = New-Object System.Drawing.Point(15, 55)
$grpAcc.Size = New-Object System.Drawing.Size(580, 150)
$grpAcc.Controls.Add((New-Label "アカウント名:" 15 32))
$tbUser = New-Object System.Windows.Forms.TextBox
$tbUser.Location = New-Object System.Drawing.Point(125, 29)
$tbUser.Size = New-Object System.Drawing.Size(430, 24)
$tbUser.Text = $alState.UserName
$grpAcc.Controls.Add($tbUser)
$grpAcc.Controls.Add((New-Label "パスワード:" 15 68))
$tbPass = New-Object System.Windows.Forms.TextBox
$tbPass.Location = New-Object System.Drawing.Point(125, 65)
$tbPass.Size = New-Object System.Drawing.Size(430, 24)
$tbPass.UseSystemPasswordChar = $true
$tbPass.Add_TextChanged({ if ($tbPass.Text) { $cbAuto.Checked = $true } })
$grpAcc.Controls.Add($tbPass)
$lblPw = New-Label "※ パスワード欄を空のまま保存すると、今保存されているパスワードをそのまま使います。" 15 100
$lblPw.ForeColor = [System.Drawing.Color]::DimGray
$grpAcc.Controls.Add($lblPw)
$lblPw2 = New-Label "※ PIN は使えません。Windows のパスワードを入力してください。" 15 122
$lblPw2.ForeColor = [System.Drawing.Color]::DimGray
$grpAcc.Controls.Add($lblPw2)
$tp2.Controls.Add($grpAcc)

$lblAl = New-Label "現在: $(if ($alState.Enabled) { '有効' } else { '無効' })  ($($alState.Domain)\$($alState.UserName))" 15 220
$tp2.Controls.Add($lblAl)

$btnNet = New-Object System.Windows.Forms.Button
$btnNet.Text = "うまくいかないときは: Windows 標準の方法 (netplwiz)"
$btnNet.Location = New-Object System.Drawing.Point(15, 250)
$btnNet.Size = New-Object System.Drawing.Size(340, 32)
$btnNet.Add_Click({
    if (-not (Test-Path $PwdLessKey)) { New-Item -Path $PwdLessKey -Force | Out-Null }
    Set-ItemProperty $PwdLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
    Start-Process netplwiz.exe
    [System.Windows.Forms.MessageBox]::Show(
        "Windows 標準の『ユーザー アカウント』画面を開きました。`n`n" +
        "1. 一覧からアカウントを選ぶ`n" +
        "2.『ユーザーがこのコンピューターを使うには…入力が必要』のチェックを外す`n" +
        "3.『OK』→ パスワードを2回入力",
        "設定") | Out-Null
})
$tp2.Controls.Add($btnNet)

$tabs.TabPages.AddRange(@($tp1, $tp2))
$form.Controls.Add($tabs)

# ------------------------------------------------------------
#  保存 / 閉じる
# ------------------------------------------------------------
$btnOK = New-Object System.Windows.Forms.Button
$btnOK.Text = "保存"
$btnOK.Location = New-Object System.Drawing.Point(430, 468)
$btnOK.Size = New-Object System.Drawing.Size(90, 34)
$btnOK.DialogResult = "OK"
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "閉じる"
$btnCancel.Location = New-Object System.Drawing.Point(535, 468)
$btnCancel.Size = New-Object System.Drawing.Size(90, 34)
$btnCancel.DialogResult = "Cancel"
$form.Controls.AddRange(@($btnOK, $btnCancel))
$form.AcceptButton = $btnOK
$form.CancelButton = $btnCancel

if ($form.ShowDialog() -ne "OK") { exit 0 }

$messages = @()

# --- 1. 画面表示の保存 ---
$resText = $cmbRes.Text.Trim()
$res = Resolve-ResolutionText $resText
$resChanged = ($resText -ne [string]$cfg.ConsoleResolution)
if (-not $res) {
    $messages += "解像度の指定『$resText』は解釈できないため、前の値のままにしました。"
    $resText = [string]$cfg.ConsoleResolution
    $resChanged = $false
}
$out = [ordered]@{
    "_説明"             = "EdgeBox 表示の設定。『設定』アイコンから編集できます。"
    "RightUrl"          = $tbR.Text.Trim()
    "RightFullScreen"   = $cbRF.Checked
    "LeftUrl"           = $tbL.Text.Trim()
    "LeftFullScreen"    = $cbLF.Checked
    "EscEnabled"        = $cbEsc.Checked
    "ConsoleStripFrame" = $cbSF.Checked
    "ConsoleAutoClose"  = $cbAC.Checked
    "ConsoleAutoCloseV2" = $true
    "RightBrowserV2"    = $true    # 右画面の既定を切り替え済み (03 側の一度きりの移行を再実行させない)
    "ConsoleHideBar"    = $cbBar.Checked
    "LeftGuard"         = $cbLG.Checked
    "LeftGuardHotkey"   = $lgHot
    "ConsoleResolution" = $resText
}
# 手動で追加できる詳細設定 (自動クローズまでの秒数) は保存で消さない
if ($cfg.PSObject.Properties["ConsoleAutoCloseDelaySec"]) {
    $out["ConsoleAutoCloseDelaySec"] = [int]$cfg.ConsoleAutoCloseDelaySec
}
$out | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
$messages += "画面表示の設定を保存しました (次回の表示から反映)。"
if ($res -and $resChanged) {
    try { $messages += (Set-ConsoleResolution $res.W $res.H) }
    catch { $messages += "解像度の変更に失敗しました: $($_.Exception.Message)" }
}

# --- 2. 自動サインインの保存 ---
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
