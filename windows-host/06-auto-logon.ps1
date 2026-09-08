<#
.SYNOPSIS
    Windows のサインイン画面 (スタート画面) を省略し、電源投入から直接デスクトップへ入ります。

.DESCRIPTION
    電源 ON → ロック画面 → パスワード入力 …を省略して、そのままデスクトップまで自動で進みます。
    これにより「電源を入れるだけ」で以下が全部そろいます:
        EdgeBox 自動起動 → 自動サインイン → 左右モニターへの自動表示 (03) が起動

    アカウント名とパスワードは後からいつでも変更できます:
        デスクトップの『自動サインイン設定』アイコン (-Setup で作成) からウィンドウで変更します。

    パスワードの保存方法:
        Windows の LSA 秘密領域に保存します (Sysinternals Autologon と同じ方式)。
        レジストリに平文で書く方法は取りません (同じ PC の一般ユーザーから読めてしまうため)。

.EXAMPLE
    .\06-auto-logon.ps1 -Setup     # デスクトップに『自動サインイン設定』アイコンを作成 (最初にこれ)
    .\06-auto-logon.ps1 -Settings  # 設定ウィンドウを開く (アカウント名・パスワードの変更)
    .\06-auto-logon.ps1            # PowerShell 上で対話設定する
    .\06-auto-logon.ps1 -Status    # 現在の設定状態を表示
    .\06-auto-logon.ps1 -Disable   # 自動サインインを解除 (元に戻す)

.NOTES
    - 管理者権限が必要です (『自動サインイン設定』アイコンは管理者実行フラグ付きで作成されます)。
    - 自動サインインにすると、電源を入れた人は誰でも Windows を操作できる状態になります。
      施錠された工場内など、PC の設置場所が管理されていることが前提です。
    - Win+L による手動ロックは今までどおり使えます (ロック解除にはパスワードが必要)。
    - Windows のパスワードを変更したら、ここでも設定し直してください。
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Settings,
    [switch]$Netplwiz,
    [switch]$Disable,
    [switch]$Status,
    [string]$UserName
)

$ErrorActionPreference = "Stop"

$WinlogonKey  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$PwdLessKey   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
$PowerSubNone = "fea3413e-7e05-4911-9a71-700331f1c294"   # 「その他の設定」
$PowerWakePwd = "0e796bdb-100d-47d6-a2d5-f7d2daa51f51"   # 「スリープ解除時にパスワードを要求する」

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($Settings) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "管理者権限が必要です。`nアイコンを右クリックして『管理者として実行』を選んでください。",
            "自動サインイン設定",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } else {
        Write-Error "管理者権限で実行してください (PowerShell を右クリック →『管理者として実行』)。"
    }
    exit 1
}

# ============================================================
#  Windows API (LSA 秘密領域への保存 / パスワード照合)
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
    if ($st -ne 0) {
        throw "Windows の資格情報保存領域を開けませんでした (エラー $([FieldLsa]::LsaNtStatusToWinError($st)))。"
    }
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
        if ($st -ne 0) {
            throw "パスワードの保存に失敗しました (エラー $([FieldLsa]::LsaNtStatusToWinError($st)))。"
        }
    } finally { [FieldLsa]::LsaClose($h) | Out-Null }
}

function Remove-AutoLogonSecret {
    $h = Open-LsaPolicy
    try {
        $k = New-LsaString "DefaultPassword"
        $st = [FieldLsa]::LsaDeletePrivateData($h, [ref]$k, [IntPtr]::Zero)
        [Runtime.InteropServices.Marshal]::FreeHGlobal($k.Buffer)
        # Win32 エラー 2 (見つかりません) = 元から保存されていない。解除としては成功扱い
        # ※ 0xC0000034 との直接比較は、PowerShell が 16 進数を符号付きで解釈するため使わない
        $win32 = [FieldLsa]::LsaNtStatusToWinError($st)
        if ($st -ne 0 -and $win32 -ne 2) {
            Write-Warning "保存済みパスワードの削除に失敗しました (エラー $win32)。"
        }
    } finally { [FieldLsa]::LsaClose($h) | Out-Null }
}

# パスワードを照合する。ログオン種別やドメイン表記の違いで弾かれることがあるので、
# 組み合わせを一通り試し、駄目だった理由 (Win32 エラー) も返す
function Test-Password([string]$user, [string]$domain, [string]$password) {
    $tok = [IntPtr]::Zero
    $lastErr = 0
    $domains = @($domain, ".", $env:COMPUTERNAME) | Where-Object { $_ } | Select-Object -Unique
    foreach ($d in $domains) {
        foreach ($t in 2, 3, 8) {   # 2=対話 3=ネットワーク 8=ネットワーク(平文)
            if ([FieldLsa]::LogonUser($user, $d, $password, $t, 0, [ref]$tok)) {
                [FieldLsa]::CloseHandle($tok) | Out-Null
                return [pscustomobject]@{ Ok = $true; Error = 0 }
            }
            $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if ($e -ne 0) { $lastErr = $e }
            if ($e -eq 1326) { break }   # 資格情報そのものが違う。種別を変えても同じ
        }
    }
    return [pscustomobject]@{ Ok = $false; Error = $lastErr }
}

# 照合に失敗した理由と、パスワード自体が正しそうかどうか
function Get-LogonErrorInfo([int]$code) {
    switch ($code) {
        1326 { return [pscustomobject]@{ Text = "ユーザー名またはパスワードが違います。"; PasswordLikelyOk = $false } }
        1327 { return [pscustomobject]@{ Text = "アカウントに制限がかかっています (パスワードが空、または使用時間の制限など)。"; PasswordLikelyOk = $true } }
        1331 { return [pscustomobject]@{ Text = "アカウントが無効になっています。"; PasswordLikelyOk = $true } }
        1385 { return [pscustomobject]@{ Text = "このアカウントには、この種類のログオンが許可されていません。"; PasswordLikelyOk = $true } }
        1907 { return [pscustomobject]@{ Text = "次回サインイン時にパスワード変更が必要な状態です。"; PasswordLikelyOk = $true } }
        1909 { return [pscustomobject]@{ Text = "アカウントがロックアウトされています。"; PasswordLikelyOk = $true } }
    }
    return [pscustomobject]@{ Text = "確認できませんでした (エラーコード $code)。"; PasswordLikelyOk = $true }
}

# ============================================================
#  現在の設定の読み出し / 書き込み
# ============================================================
function Get-AutoLogonState {
    $wl = Get-ItemProperty $WinlogonKey -ErrorAction SilentlyContinue
    $u = [string]$wl.DefaultUserName
    $d = [string]$wl.DefaultDomainName
    if (-not $u) { $u = $env:USERNAME }
    if (-not $d) { $d = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME } }
    return [pscustomobject]@{
        Enabled     = ($wl.AutoAdminLogon -eq "1")
        UserName    = $u
        Domain      = $d
        HasPlainPwd = ($null -ne $wl.DefaultPassword)
    }
}

# 今サインインしているアカウントが Microsoft アカウントかどうかを調べる
# (Microsoft アカウントだと、メールアドレスが IdentityStore に記録される)
function Get-MicrosoftAccountMail {
    try {
        $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $key = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
        if (Test-Path $key) {
            $mail = [string](Get-ItemProperty $key -ErrorAction SilentlyContinue).UserName
            if ($mail -match '@') { return $mail }
        }
    } catch { }
    return $null
}

# 「PC名\ユーザー名」形式にも対応して分解する
function Split-Account([string]$text) {
    $t = $text.Trim()
    if ($t -match '^(.+?)\\(.+)$') {
        return [pscustomobject]@{ Domain = $Matches[1]; User = $Matches[2] }
    }
    if ($t -match '^(.+)@(.+)$') {   # Microsoft アカウント (メール形式) はそのまま
        return [pscustomobject]@{ Domain = $env:COMPUTERNAME; User = $t }
    }
    $d = if ($env:USERDOMAIN) { $env:USERDOMAIN } else { $env:COMPUTERNAME }
    return [pscustomobject]@{ Domain = $d; User = $t }
}

# 自動サインインを有効化する。$password が $null の場合は保存済みパスワードを据え置く
function Enable-AutoLogon([string]$user, [string]$domain, $password) {
    if ($null -ne $password) {
        if ($password -eq "") { Remove-AutoLogonSecret } else { Set-AutoLogonSecret $password }
    }
    # Windows Hello 専用サインインの制限を解除 (自動サインインを許可する)
    if (-not (Test-Path $PwdLessKey)) { New-Item -Path $PwdLessKey -Force | Out-Null }
    Set-ItemProperty $PwdLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord

    Set-ItemProperty $WinlogonKey -Name AutoAdminLogon    -Value "1"   -Type String
    Set-ItemProperty $WinlogonKey -Name DefaultUserName   -Value $user -Type String
    Set-ItemProperty $WinlogonKey -Name DefaultDomainName -Value $domain -Type String
    Remove-ItemProperty $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue  # 平文保存は使わない
    Remove-ItemProperty $WinlogonKey -Name AutoLogonCount  -ErrorAction SilentlyContinue  # 回数制限を外す

    # スリープ・スクリーンセーバー復帰時のパスワード要求も外す
    powercfg /SETACVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 0 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 0 | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
    Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name ScreenSaverIsSecure -Value "0" -ErrorAction SilentlyContinue
}

function Disable-AutoLogon {
    Set-ItemProperty $WinlogonKey -Name AutoAdminLogon -Value "0" -Type String
    Remove-ItemProperty $WinlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
    Remove-AutoLogonSecret
    powercfg /SETACVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 1 | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT $PowerSubNone $PowerWakePwd 1 | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
    Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name ScreenSaverIsSecure -Value "1" -ErrorAction SilentlyContinue
}

# ============================================================
#  デスクトップに『自動サインイン設定』アイコンを作成
# ============================================================
if ($Setup) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "自動サインイン設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Settings"
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,44"
    $lnk.Description  = "電源 ON でデスクトップまで自動で進む設定 (アカウント名・パスワードの変更)"
    $lnk.Save()
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20   # 管理者として実行
    [IO.File]::WriteAllBytes($lnkPath, $bytes)
    Write-Host "デスクトップに『自動サインイン設定』アイコンを作成しました。" -ForegroundColor Green
    Write-Host "  アカウント名やパスワードを変えたときは、このアイコンから変更してください。"
    Write-Host ""
    Write-Host "アイコンを作っただけでは、まだ自動サインインは有効になりません。" -ForegroundColor Yellow
    Write-Host "続けて設定ウィンドウを開きます。アカウント名とパスワードを入れて『保存』してください。"
    Start-Sleep -Seconds 2
    & $PSCommandPath -Settings
    exit 0
}

# ============================================================
#  Windows 標準の設定画面 (netplwiz) を開く
# ============================================================
if ($Netplwiz) {
    # Windows Hello 専用サインインの制限を外さないと、netplwiz にチェック欄が出ない
    if (-not (Test-Path $PwdLessKey)) { New-Item -Path $PwdLessKey -Force | Out-Null }
    Set-ItemProperty $PwdLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
    Start-Process netplwiz.exe
    Write-Host "Windows 標準の『ユーザー アカウント』画面を開きました。" -ForegroundColor Green
    Write-Host "  1. 一覧から自動サインインさせたいアカウントを選ぶ"
    Write-Host "  2.『ユーザーがこのコンピューターを使うには、ユーザー名とパスワードの入力が必要』のチェックを外す"
    Write-Host "  3.『OK』を押し、パスワードを2回入力する"
    Write-Host ""
    Write-Host "Windows 自身が資格情報を保存するため、Microsoft アカウントでも通ることがあります。"
    exit 0
}

# ============================================================
#  状態表示
# ============================================================
if ($Status) {
    $s = Get-AutoLogonState
    Write-Host ""
    Write-Host "自動サインイン: $(if ($s.Enabled) { '有効' } else { '無効' })" -ForegroundColor $(if ($s.Enabled) { "Green" } else { "Yellow" })
    Write-Host "  サインインするアカウント: $($s.Domain)\$($s.UserName)"
    $mail = Get-MicrosoftAccountMail
    if ($mail) {
        Write-Host "  アカウントの種類: Microsoft アカウント ($mail)" -ForegroundColor Yellow
        Write-Host "    Microsoft アカウントは自動サインインが通らないことがあります。"
        Write-Host "    その場合は『Windows 標準の方法 (netplwiz)』か、ローカルアカウントの利用を検討してください。"
    } else {
        Write-Host "  アカウントの種類: ローカル アカウント"
    }
    if ($s.HasPlainPwd) {
        Write-Warning "レジストリにパスワードが平文で保存されています。設定し直すと安全な保存方式に置き換わります。"
    }
    $wake = (powercfg /QUERY SCHEME_CURRENT $PowerSubNone $PowerWakePwd | Out-String)
    if ($wake -match '(?m)^.*\bAC\b.*:\s*0x00000000\s*$') {
        Write-Host "  スリープ解除時のパスワード要求: なし"
    } else {
        Write-Host "  スリープ解除時のパスワード要求: あり"
    }
    Write-Host ""
    exit 0
}

# ============================================================
#  解除 (元に戻す)
# ============================================================
if ($Disable) {
    Disable-AutoLogon
    Write-Host "自動サインインを解除しました。次回起動からサインイン画面が表示されます。" -ForegroundColor Green
    exit 0
}

# ============================================================
#  設定ウィンドウ (アカウント名・パスワードの変更)
# ============================================================
if ($Settings) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $st = Get-AutoLogonState

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "自動サインイン設定"
    $form.Size = New-Object System.Drawing.Size(560, 350)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    function New-Label($text, $x, $y, $w) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, 20)
        return $l
    }

    $cbOn = New-Object System.Windows.Forms.CheckBox
    $cbOn.Text = "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む"
    $cbOn.Location = New-Object System.Drawing.Point(20, 18)
    $cbOn.Size = New-Object System.Drawing.Size(500, 24)
    $cbOn.Checked = $st.Enabled
    $form.Controls.Add($cbOn)

    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = "サインインするアカウント"
    $grp.Location = New-Object System.Drawing.Point(20, 50)
    $grp.Size = New-Object System.Drawing.Size(500, 150)

    $grp.Controls.Add((New-Label "アカウント名:" 15 32 100))
    $tbUser = New-Object System.Windows.Forms.TextBox
    $tbUser.Location = New-Object System.Drawing.Point(125, 29)
    $tbUser.Size = New-Object System.Drawing.Size(355, 24)
    $tbUser.Text = $st.UserName
    $grp.Controls.Add($tbUser)

    $grp.Controls.Add((New-Label "パスワード:" 15 68 100))
    $tbPass = New-Object System.Windows.Forms.TextBox
    $tbPass.Location = New-Object System.Drawing.Point(125, 65)
    $tbPass.Size = New-Object System.Drawing.Size(355, 24)
    $tbPass.UseSystemPasswordChar = $true
    # パスワードを入力し始めたら「有効にする」の意思表示とみなしてチェックを入れる
    $tbPass.Add_TextChanged({ if ($tbPass.Text) { $cbOn.Checked = $true } })
    $grp.Controls.Add($tbPass)

    $note = New-Label "※ パスワード欄を空のまま保存すると、今保存されているパスワードをそのまま使います。" 15 100 470
    $note.Size = New-Object System.Drawing.Size(470, 40)
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $grp.Controls.Add($note)
    $form.Controls.Add($grp)

    $mail = Get-MicrosoftAccountMail
    $info = New-Label ("現在: {0}  ({1}\{2}){3}" -f
        $(if ($st.Enabled) { '有効' } else { '無効' }), $st.Domain, $st.UserName,
        $(if ($mail) { "  ― Microsoft アカウント ($mail)" } else { "  ― ローカル アカウント" })) 20 210 500
    if ($mail) { $info.ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0) }
    $form.Controls.Add($info)

    # Microsoft アカウントなどで保存がうまくいかない場合の逃げ道 (Windows 純正の設定画面)
    $btnNet = New-Object System.Windows.Forms.Button
    $btnNet.Text = "Windows 標準の方法 (netplwiz)"
    $btnNet.Location = New-Object System.Drawing.Point(20, 245)
    $btnNet.Size = New-Object System.Drawing.Size(230, 32)
    $btnNet.Add_Click({
        if (-not (Test-Path $PwdLessKey)) { New-Item -Path $PwdLessKey -Force | Out-Null }
        Set-ItemProperty $PwdLessKey -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
        Start-Process netplwiz.exe
        [System.Windows.Forms.MessageBox]::Show(
            "Windows 標準の『ユーザー アカウント』画面を開きました。`n`n" +
            "1. 一覧から自動サインインさせたいアカウントを選ぶ`n" +
            "2.『ユーザーがこのコンピューターを使うには、ユーザー名とパスワードの入力が必要』のチェックを外す`n" +
            "3.『OK』を押し、パスワードを2回入力する`n`n" +
            "この方法は Windows 自身が資格情報を保存するため、Microsoft アカウントでも通ることがあります。`n" +
            "設定できたら、この画面は『キャンセル』で閉じてください。",
            "自動サインイン設定") | Out-Null
    })
    $form.Controls.Add($btnNet)

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(320, 245)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(425, 245)
    $btnCancel.Size = New-Object System.Drawing.Size(95, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -ne "OK") { exit 0 }

    if (-not $cbOn.Checked) {
        # 解除は取り消しが効かない操作なので、意図を一度確認する
        $r = [System.Windows.Forms.MessageBox]::Show(
            "一番上のチェックが外れています。このまま保存すると`n" +
            "自動サインインは『解除』され、起動時にサインイン画面が表示されます。`n`n" +
            "自動サインインを有効にしたい場合は『いいえ』を押し、`n" +
            "一番上のチェックを入れてから保存し直してください。`n`n" +
            "解除でよろしいですか?",
            "自動サインイン設定",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
        Disable-AutoLogon
        [System.Windows.Forms.MessageBox]::Show(
            "自動サインインを解除しました。`n次回の起動からサインイン画面が表示されます。",
            "自動サインイン設定") | Out-Null
        exit 0
    }

    $acct = Split-Account $tbUser.Text
    if (-not $acct.User) {
        [System.Windows.Forms.MessageBox]::Show("アカウント名を入力してください。", "自動サインイン設定",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        exit 1
    }

    $pass = $tbPass.Text
    $accountChanged = ($acct.User -ne $st.UserName -or $acct.Domain -ne $st.Domain)
    if ($pass -eq "") {
        # 空欄 = 据え置き。ただしアカウントを変えた場合や、まだ一度も設定していない場合は入力が必要
        if ($accountChanged -or -not $st.Enabled) {
            [System.Windows.Forms.MessageBox]::Show(
                "アカウントを変更する場合は、そのアカウントのパスワードを入力してください。",
                "自動サインイン設定",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            exit 1
        }
        $pass = $null   # 保存済みパスワードを据え置く
    } else {
        $chk = Test-Password $acct.User $acct.Domain $pass
        if (-not $chk.Ok) {
            $info = Get-LogonErrorInfo $chk.Error
            $body = "パスワードの事前確認ができませんでした。`n`n理由: $($info.Text)`n`n"
            if ($info.PasswordLikelyOk) {
                $body += "これは確認のしくみ側の制限で、パスワード自体は正しい可能性が高いです。`n" +
                         "そのまま保存して、再起動で試すことをおすすめします。`n"
            } else {
                $body += "入力したアカウント名かパスワードを見直してください。`n"
            }
            $body += "(間違っていても PC は壊れません。サインイン画面が出るだけです)`n`n" +
                     "効かなかったときは『Windows 標準の方法 (netplwiz)』ボタンをお試しください。`n`n" +
                     "この内容で保存しますか?"
            $r = [System.Windows.Forms.MessageBox]::Show($body, "自動サインイン設定",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
        }
    }

    Enable-AutoLogon $acct.User $acct.Domain $pass
    $tbPass.Text = ""
    [System.Windows.Forms.MessageBox]::Show(
        "保存しました。`n次回の起動から、電源 ON でそのままデスクトップまで進みます。`n`n" +
        "対象アカウント: $($acct.Domain)\$($acct.User)",
        "自動サインイン設定") | Out-Null
    exit 0
}

# ============================================================
#  PowerShell 上での対話設定
# ============================================================
$st = Get-AutoLogonState
if (-not $UserName) { $UserName = $st.UserName }
$acct = Split-Account $UserName

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " 自動サインインの設定"
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "対象アカウント: $($acct.Domain)\$($acct.User)"
Write-Host ""
Write-Host "電源を入れた人は誰でも、この PC の Windows をそのまま操作できる状態になります。"
Write-Host "PC の設置場所が管理されていることを確認してください。"
Write-Host ""
$ans = Read-Host "続けますか? (y/N)"
if ($ans -ne "y") { Write-Host "中止しました。"; exit 0 }

Write-Host ""
Write-Host "$($acct.User) のサインイン用パスワードを入力してください (画面には表示されません)。"
$sec = Read-Host "パスワード" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if ($plain) {
        Write-Host "パスワードを確認しています..."
        $chk = Test-Password $acct.User $acct.Domain $plain
        if ($chk.Ok) {
            Write-Host "パスワードを確認しました。" -ForegroundColor Green
        } else {
            $info = Get-LogonErrorInfo $chk.Error
            Write-Host ""
            Write-Warning "パスワードの事前確認ができませんでした。理由: $($info.Text)"
            if ($info.PasswordLikelyOk) {
                Write-Warning "確認のしくみ側の制限で、パスワード自体は正しい可能性が高いです。そのまま設定して構いません。"
            } else {
                Write-Warning "入力したアカウント名かパスワードを見直してください。"
            }
            Write-Warning "間違っていても PC は壊れません (起動時にサインイン画面が出るだけです)。"
            $ans2 = Read-Host "この内容で設定しますか? (y/N)"
            if ($ans2 -ne "y") { Write-Host "中止しました。設定は変更していません。"; exit 0 }
        }
    }
    Enable-AutoLogon $acct.User $acct.Domain $plain
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
}

Write-Host ""
Write-Host "設定しました。" -ForegroundColor Green
Write-Host "次回の起動から、電源 ON でそのままデスクトップまで進みます。"
Write-Host ""
Write-Host "後からアカウント名やパスワードを変更する:"
Write-Host "  .\06-auto-logon.ps1 -Setup      # デスクトップに『自動サインイン設定』アイコンを作成"
Write-Host "  .\06-auto-logon.ps1 -Settings   # 設定ウィンドウを直接開く"
Write-Host "  .\06-auto-logon.ps1 -Status     # 設定状態の確認"
Write-Host "  .\06-auto-logon.ps1 -Disable    # 元に戻す"
Write-Host ""
Write-Host "あわせて: powercfg /h off  (高速スタートアップ無効。EdgeBox 自動起動を確実にする)" -ForegroundColor Yellow
