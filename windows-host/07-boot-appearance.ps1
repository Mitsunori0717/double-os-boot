<#
.SYNOPSIS
    起動時の見た目を落ち着かせます: サインイン画面を無地の暗色にし、
    アカウント名を隠し、デスクトップの壁紙を黒にします。

.DESCRIPTION
    電源 ON からの流れを、できるだけ「黒い画面」でそろえるための設定です:
      1. ロック画面 (時計の画面) を飛ばす
      2. サインイン画面の背景写真とぼかしをやめ、無地の暗い色にする
      3. サインイン画面にアカウント名やメールアドレスを表示しない
      4. デスクトップの壁紙を黒一色にする (アイコンはそのまま)

    これで、電源 ON → 暗いサインイン画面 (自動で通過) → 黒いデスクトップ →
    起動中スプラッシュ → EdgeBox の画面、と一貫した見た目になります。

.EXAMPLE
    .\07-boot-appearance.ps1            # 設定する
    .\07-boot-appearance.ps1 -Disable   # すべて元に戻す
    .\07-boot-appearance.ps1 -Status    # 現在の状態を表示

.NOTES
    - 管理者権限が必要です。
    - アカウント名を隠す設定を入れると、手動でサインインするときは
      アカウント名 (BELab など) を自分で入力する必要があります。
      自動サインイン (06) には影響しません。
#>
[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

$PolWinSystem = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"            # サインイン背景
$PolPerso     = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"   # ロック画面
$PolSystem    = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"  # アカウント名表示

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限で実行してください (PowerShell を右クリック →『管理者として実行』)。"
    exit 1
}

# 壁紙の反映用
if (-not ("BootLook" -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class BootLook {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, string pvParam, uint fWinIni);
}
'@
}

function Get-RegValue([string]$path, [string]$name) {
    try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name } catch { return $null }
}

if ($Status) {
    Write-Host ""
    Write-Host "ロック画面を飛ばす:            $(if ((Get-RegValue $PolPerso 'NoLockScreen') -eq 1) { '有効' } else { '無効' })"
    Write-Host "サインイン背景を無地の暗色に:  $(if ((Get-RegValue $PolWinSystem 'DisableLogonBackgroundImage') -eq 1) { '有効' } else { '無効' })"
    Write-Host "アカウント名を隠す:            $(if ((Get-RegValue $PolSystem 'dontdisplaylastusername') -eq 1) { '有効' } else { '無効' })"
    $wp = [string](Get-RegValue "HKCU:\Control Panel\Desktop" "Wallpaper")
    Write-Host "デスクトップの壁紙:            $(if (-not $wp) { '黒一色' } else { $wp })"
    Write-Host ""
    exit 0
}

if ($Disable) {
    foreach ($n in "DisableLogonBackgroundImage", "DisableAcrylicBackgroundOnLogon") {
        Remove-ItemProperty -Path $PolWinSystem -Name $n -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -Path $PolPerso -Name "NoLockScreen" -ErrorAction SilentlyContinue
    foreach ($n in "dontdisplaylastusername", "BlockUserFromShowingAccountDetailsOnSignin") {
        Remove-ItemProperty -Path $PolSystem -Name $n -ErrorAction SilentlyContinue
    }
    # 壁紙を Windows 標準に戻す
    $img = Join-Path $env:windir "Web\Wallpaper\Windows\img0.jpg"
    if (Test-Path $img) {
        Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $img
        [BootLook]::SystemParametersInfo(20, 0, $img, 3) | Out-Null   # 20 = 壁紙の変更
    }
    Write-Host "起動時の見た目の設定をすべて元に戻しました。" -ForegroundColor Green
    exit 0
}

# --- 1. ロック画面 (時計の画面) を飛ばす ---
if (-not (Test-Path $PolPerso)) { New-Item -Path $PolPerso -Force | Out-Null }
Set-ItemProperty $PolPerso -Name NoLockScreen -Value 1 -Type DWord

# --- 2. サインイン画面の背景写真・ぼかしをやめて無地の暗色にする ---
if (-not (Test-Path $PolWinSystem)) { New-Item -Path $PolWinSystem -Force | Out-Null }
Set-ItemProperty $PolWinSystem -Name DisableLogonBackgroundImage     -Value 1 -Type DWord
Set-ItemProperty $PolWinSystem -Name DisableAcrylicBackgroundOnLogon -Value 1 -Type DWord

# --- 3. サインイン画面にアカウント名・メールアドレスを出さない ---
if (-not (Test-Path $PolSystem)) { New-Item -Path $PolSystem -Force | Out-Null }
Set-ItemProperty $PolSystem -Name dontdisplaylastusername                    -Value 1 -Type DWord
Set-ItemProperty $PolSystem -Name BlockUserFromShowingAccountDetailsOnSignin -Value 1 -Type DWord

# --- 4. デスクトップの壁紙を黒一色にする (アイコンはそのまま) ---
Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value ""
Set-ItemProperty "HKCU:\Control Panel\Colors"  -Name Background -Value "0 0 0"
[BootLook]::SystemParametersInfo(20, 0, "", 3) | Out-Null   # 壁紙なし = 単色背景を即反映

Write-Host "設定しました。" -ForegroundColor Green
Write-Host "  - ロック画面は表示されなくなります"
Write-Host "  - サインイン画面は無地の暗い色になり、アカウント名も表示されません"
Write-Host "  - デスクトップの壁紙は黒一色になりました (アイコンはそのまま)"
Write-Host ""
Write-Host "注意: 手動でサインインするときは、アカウント名も自分で入力する必要があります。" -ForegroundColor Yellow
Write-Host "      (自動サインインには影響しません。元に戻す: .\07-boot-appearance.ps1 -Disable)"
