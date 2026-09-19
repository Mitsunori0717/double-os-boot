<#
.SYNOPSIS
    「PC のセットアップを完了しましょう」などの勧誘画面と、右下の通知 (トースト) を出さないようにします。

.DESCRIPTION
    Windows 11 は、サインイン直後や更新のあとに、次のような画面を全画面で出すことがあります:
      - 「PC のセットアップを完了しましょう」(Microsoft アカウント・OneDrive・Edge などの勧め)
      - 更新後の「ようこそ」画面、「ヒントと提案」の通知
      - 機能更新後の「プライバシー設定を確認」画面
    また、右下に出る通知 (トースト) も、アプリ・Windows セキュリティ・Windows Update の再起動の予告まで
    含めてすべて止めます (通知センターも無効にします)。
    工場の表示用 PC ではどれも不要で、EdgeBox の画面の前に出てくると邪魔になるため、まとめて止めます。
    設定は、このアカウントと、この PC に読み込まれている全ユーザーのアカウントに入れます。

    再起動そのもの (Windows Update による自動再起動) は 12-windows-update.ps1 が止めます。
    両方を実行すると「再起動も通知も出ない」状態になります。

    元に戻すには -Disable を付けて実行します。

.EXAMPLE
    .\12-quiet-windows.ps1            # 勧誘画面を止める
    .\12-quiet-windows.ps1 -Status    # 現在の状態を表示
    .\12-quiet-windows.ps1 -Disable   # 元に戻す

.NOTES
    管理者権限が必要です。反映にはサインアウト → サインイン (または再起動) が必要です。
#>
[CmdletBinding()]
param(
    [switch]$Disable,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { Write-Error "管理者権限で実行してください (管理者の PowerShell)。"; exit 1 }

# ユーザーごとの設定 (値 = 止めるときの値 / Default = 戻すときの値。$null なら値ごと削除)
$UserItems = @(
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Off = 0; Default = $null
       Label = "「PC のセットアップを完了しましょう」の提案" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Off = 0; Default = 1
       Label = "更新後の「ようこそ」画面" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Off = 0; Default = 1
       Label = "「ヒントと提案」の通知" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Off = 0; Default = 1
       Label = "設定アプリ内の提案" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353696Enabled"; Off = 0; Default = 1
       Label = "タイムラインなどの提案" },
    @{ Key = "Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Off = 1; Default = $null
       Label = "ポリシー: 「ようこそ」画面を無効" },
    # --- 右下の通知 (トースト) ---
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled"; Off = 0; Default = 1
       Label = "通知: 右下の通知 (アプリやシステムからの通知) 全体" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_TOASTS_ENABLED"; Off = 0; Default = 1
       Label = "通知: 設定アプリの「通知」スイッチ" },
    @{ Key = "Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance"; Name = "Enabled"; Off = 0; Default = $null
       Label = "通知: セキュリティとメンテナンス" },
    @{ Key = "Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "NoToastApplicationNotification"; Off = 1; Default = $null
       Label = "ポリシー: アプリの通知を出さない" },
    @{ Key = "Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "NoToastApplicationNotificationOnLockScreen"; Off = 1; Default = $null
       Label = "ポリシー: ロック画面にも通知を出さない" },
    @{ Key = "Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableNotificationCenter"; Off = 1; Default = $null
       Label = "ポリシー: 通知センターを無効" }
)
# PC 全体の設定
$MachineItems = @(
    @{ Key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "DisablePrivacyExperience"; Off = 1; Default = $null
       Label = "ポリシー: 機能更新後の「プライバシー設定」画面を出さない" },
    @{ Key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications"; Name = "DisableNotifications"; Off = 1; Default = $null
       Label = "通知: Windows セキュリティの通知" },
    @{ Key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications"; Name = "DisableEnhancedNotifications"; Off = 1; Default = $null
       Label = "通知: Windows セキュリティの追加の通知" },
    @{ Key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetUpdateNotificationLevel"; Off = 2; Default = $null
       Label = "通知: Windows Update の通知 (再起動の予告を含む) を出さない" },
    @{ Key = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetAutoRestartNotificationDisable"; Off = 1; Default = $null
       Label = "通知: 自動再起動の通知を出さない" }
)

# 設定を入れる先: いまのユーザー + この PC に読み込まれている全ユーザー (自動サインインのアカウントなど)
function Get-UserHives {
    $hives = [ordered]@{}
    $hives["HKCU:"] = "このアカウント"
    foreach ($k in (Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-' -or $sid -match '_Classes$') { continue }
        $name = $sid
        try { $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
        $hives["Registry::HKEY_USERS\$sid"] = $name
    }
    return $hives
}

function Set-Item2([string]$Path, [hashtable]$Item, [bool]$TurnOff) {
    if ($TurnOff) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Item.Name -Value $Item.Off -Type DWord
    } else {
        if (-not (Test-Path $Path)) { return }
        if ($null -eq $Item.Default) { Remove-ItemProperty -Path $Path -Name $Item.Name -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $Path -Name $Item.Name -Value $Item.Default -Type DWord }
    }
}
function Get-Item2([string]$Path, [hashtable]$Item) {
    if (-not (Test-Path $Path)) { return $null }
    $p = Get-ItemProperty -Path $Path -Name $Item.Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [int]$p.($Item.Name)
}

$hives = Get-UserHives

if ($Status) {
    Write-Host ""
    foreach ($h in $hives.Keys) {
        Write-Host ("[{0}]" -f $hives[$h]) -ForegroundColor White
        foreach ($it in $UserItems) {
            $v = Get-Item2 ($h + "\" + $it.Key) $it
            $off = ($null -ne $v -and $v -eq $it.Off)
            Write-Host ("  {0} {1}" -f $(if ($off) { "○ 止めている" } else { "× 出る    " }), $it.Label) -ForegroundColor $(if ($off) { "Green" } else { "Yellow" })
        }
    }
    Write-Host "[この PC 全体]" -ForegroundColor White
    foreach ($it in $MachineItems) {
        $v = Get-Item2 $it.Key $it
        $off = ($null -ne $v -and $v -eq $it.Off)
        Write-Host ("  {0} {1}" -f $(if ($off) { "○ 止めている" } else { "× 出る    " }), $it.Label) -ForegroundColor $(if ($off) { "Green" } else { "Yellow" })
    }
    Write-Host ""
    exit 0
}

$turnOff = -not $Disable
foreach ($h in $hives.Keys) {
    foreach ($it in $UserItems) {
        try { Set-Item2 ($h + "\" + $it.Key) $it $turnOff }
        catch { Write-Host ("  警告: {0} / {1}: {2}" -f $hives[$h], $it.Label, $_.Exception.Message) -ForegroundColor Yellow }
    }
    Write-Host ("{0}: {1}" -f $hives[$h], $(if ($turnOff) { "勧誘画面を止めました" } else { "元に戻しました" })) -ForegroundColor Green
}
foreach ($it in $MachineItems) {
    try { Set-Item2 $it.Key $it $turnOff }
    catch { Write-Host ("  警告: {0}: {1}" -f $it.Label, $_.Exception.Message) -ForegroundColor Yellow }
}
Write-Host ("この PC 全体: {0}" -f $(if ($turnOff) { "勧誘画面を止めました" } else { "元に戻しました" })) -ForegroundColor Green
Write-Host ""
Write-Host "反映には、いちど サインアウト → サインイン (または PC の再起動) が必要です。" -ForegroundColor Cyan
Write-Host "もし今、画面に出ている場合は、その画面の「今はスキップ」(または右上の ×) で閉じてください。次回からは出ません。" -ForegroundColor Cyan
if ($turnOff) {
    $wu = Join-Path $PSScriptRoot "12-windows-update.ps1"
    $wuOn = $false
    try { $wuOn = ((Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate -eq 1) } catch { }
    if (-not $wuOn -and (Test-Path $wu)) {
        Write-Host "再起動そのもの (Windows Update の自動再起動) はまだ止まっていません。次も実行してください:  .\12-windows-update.ps1" -ForegroundColor Yellow
    }
}
exit 0
