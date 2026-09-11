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

# ============================================================
#  画面の構築
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "設定"
$form.TopMost = $true          # 全画面表示のブラウザ等に隠れないように
$form.Add_Shown({ $form.Activate() })
$form.Size = New-Object System.Drawing.Size(640, 340)
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

$alState = Get-AutoLogonState

$cbAuto = New-Check "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む" 15 20 580 $alState.Enabled
$form.Controls.Add($cbAuto)

$grpAcc = New-Object System.Windows.Forms.GroupBox
$grpAcc.Text = "サインインするアカウント"
$grpAcc.Location = New-Object System.Drawing.Point(15, 52)
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
$form.Controls.Add($grpAcc)

$lblAl = New-Label "現在: $(if ($alState.Enabled) { '有効' } else { '無効' })  ($($alState.Domain)\$($alState.UserName))" 15 220
$form.Controls.Add($lblAl)



# ------------------------------------------------------------
#  保存 / 閉じる
# ------------------------------------------------------------
$btnOK = New-Object System.Windows.Forms.Button
$btnOK.Text = "保存"
$btnOK.Location = New-Object System.Drawing.Point(400, 252)
$btnOK.Size = New-Object System.Drawing.Size(90, 34)
$btnOK.DialogResult = "OK"
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "閉じる"
$btnCancel.Location = New-Object System.Drawing.Point(505, 252)
$btnCancel.Size = New-Object System.Drawing.Size(90, 34)
$btnCancel.DialogResult = "Cancel"
$form.Controls.AddRange(@($btnOK, $btnCancel))
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
