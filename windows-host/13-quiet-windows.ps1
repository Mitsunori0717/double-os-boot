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

    さらに、PC が勝手に止まる原因になるスリープ・休止状態・電源ボタンも止めます:
      - 電源プラン「EdgeBox 常時稼働」を作って切り替え、スリープ/休止に入る時間を「なし」にする
      - 休止状態そのものを無効にする (高速スタートアップも一緒に無効になる)
      - 電源ボタン/スリープボタンを押しても何もしないようにする (4 秒以上の長押しによる強制電源断は残る)
    元のプランと休止の設定は quiet-windows-backup.json に控え、-Disable で戻します。

    再起動そのもの (Windows Update による自動再起動) は 12-windows-update.ps1 が止めます。
    両方を実行すると「再起動も通知も出ず、スリープもしない」状態になります。

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

# ------------------------------------------------------------ 電源 (スリープ・休止・電源ボタン)
$BackupFile = Join-Path $PSScriptRoot "quiet-windows-backup.json"
$SchemeName = "EdgeBox 常時稼働"
$GuidRe = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# powercfg を呼ぶ。エラー出力は文字列として受け取り、例外にはしない
# ($ErrorActionPreference = Stop のまま 2> を使うと、標準エラー出力が例外扱いになるため)
function Invoke-Pc([string[]]$ArgList) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        $out = @(& powercfg.exe @ArgList 2>&1 | ForEach-Object { "$_" })
        $script:PcExit = $LASTEXITCODE
        return ,$out
    } finally { $ErrorActionPreference = $prev }
}
function Get-Guid1($text) {
    $m = [regex]::Match((@($text) -join "`n"), $GuidRe)
    if ($m.Success) { return $m.Value } else { return "" }
}
function Get-ActiveScheme { return (Get-Guid1 (Invoke-Pc @("/getactivescheme"))) }
function Get-ActiveSchemeName {
    $t = ((Invoke-Pc @("/getactivescheme")) -join " ")
    $m = [regex]::Match($t, '\(([^)]+)\)\s*$'); if ($m.Success) { return $m.Groups[1].Value } else { return $t }
}
function Find-OurScheme {
    foreach ($l in (Invoke-Pc @("/list"))) { if ($l -like "*$SchemeName*") { return (Get-Guid1 $l) } }
    return ""
}
function Get-PowerIndex([string]$sub, [string]$setting) {
    $out = ((Invoke-Pc @("/query", "SCHEME_CURRENT", $sub, $setting)) -join "`n")
    $m = [regex]::Match($out, 'AC[^\n]*?0x([0-9a-fA-F]+)')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) } else { return -1 }
}
function Get-HibernateEnabled {
    try { return ([int](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled) } catch { return 1 }
}
function Show-PowerStatus {
    Write-Host "[電源]" -ForegroundColor White
    $name = Get-ActiveSchemeName
    $ours = ($name -eq $SchemeName)
    Write-Host ("  {0} 電源プラン: {1}" -f $(if ($ours) { "○" } else { "×" }), $name) -ForegroundColor $(if ($ours) { "Green" } else { "Yellow" })
    $sb = Get-PowerIndex SUB_SLEEP STANDBYIDLE
    Write-Host ("  {0} スリープに入る: {1}" -f $(if ($sb -eq 0) { "○" } else { "×" }), $(if ($sb -eq 0) { "しない" } elseif ($sb -gt 0) { "{0} 分後" -f [int]($sb / 60) } else { "不明" })) -ForegroundColor $(if ($sb -eq 0) { "Green" } else { "Yellow" })
    $hb = Get-PowerIndex SUB_SLEEP HIBERNATEIDLE
    $hibOn = (Get-HibernateEnabled) -eq 1
    Write-Host ("  {0} 休止状態: {1}" -f $(if (-not $hibOn) { "○" } else { "×" }), $(if (-not $hibOn) { "無効" } elseif ($hb -eq 0) { "有効 (自動では入らない)" } else { "有効 ({0} 分後に入る)" -f [int]($hb / 60) })) -ForegroundColor $(if (-not $hibOn) { "Green" } else { "Yellow" })
    $pb = Get-PowerIndex SUB_BUTTONS PBUTTONACTION
    Write-Host ("  {0} 電源ボタンを押したとき: {1}" -f $(if ($pb -eq 0) { "○" } else { "×" }), $(switch ($pb) { 0 { "何もしない" } 1 { "スリープ" } 2 { "休止状態" } 3 { "シャットダウン" } default { "不明" } })) -ForegroundColor $(if ($pb -eq 0) { "Green" } else { "Yellow" })
}
function Set-PowerQuiet {
    $orig = Get-ActiveScheme
    $ours = Find-OurScheme
    if (-not $ours) {
        if (-not (Test-Path $BackupFile)) {
            @{ OriginalScheme = $orig; HibernateEnabled = (Get-HibernateEnabled); Saved = (Get-Date).ToString("s") } |
                ConvertTo-Json | Set-Content -Path $BackupFile -Encoding UTF8
        }
        $ours = Get-Guid1 (Invoke-Pc @("/duplicatescheme", $orig))
        if (-not $ours) { throw "電源プランを複製できませんでした" }
        Invoke-Pc @("/changename", $ours, $SchemeName, "再起動・スリープ・休止をしない (EdgeBox の収集を止めない)") | Out-Null
    }
    Invoke-Pc @("/setactive", $ours) | Out-Null
    if ($script:PcExit -ne 0) { throw "電源プランを切り替えられませんでした" }
    $warn = @()
    foreach ($a in @(@("/change", "standby-timeout-ac", "0"), @("/change", "standby-timeout-dc", "0"),
                     @("/change", "hibernate-timeout-ac", "0"), @("/change", "hibernate-timeout-dc", "0"))) {
        Invoke-Pc $a | Out-Null
        if ($script:PcExit -ne 0) { $warn += ($a[1]) }
    }
    # ボタン類: 電源ボタン / スリープボタン / ふた。機種に無い項目 (デスクトップのふた等) は失敗しても構わない
    foreach ($st in @("PBUTTONACTION", "SLEEPBUTTONACTION", "LIDACTION")) {
        Invoke-Pc @("/setacvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", $st, "0") | Out-Null
        if ($script:PcExit -ne 0 -and $st -eq "PBUTTONACTION") { $warn += "電源ボタン" }
        Invoke-Pc @("/setdcvalueindex", "SCHEME_CURRENT", "SUB_BUTTONS", $st, "0") | Out-Null
    }
    Invoke-Pc @("/setacvalueindex", "SCHEME_CURRENT", "SUB_SLEEP", "HYBRIDSLEEP", "0") | Out-Null
    Invoke-Pc @("/setactive", "SCHEME_CURRENT") | Out-Null
    Invoke-Pc @("/hibernate", "off") | Out-Null
    if ($script:PcExit -ne 0) { $warn += "休止状態の無効化" }
    return $warn
}
function Restore-Power {
    $b = $null
    if (Test-Path $BackupFile) { try { $b = Get-Content $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    if ($b -and $b.OriginalScheme) { Invoke-Pc @("/setactive", $b.OriginalScheme) | Out-Null }
    else { Invoke-Pc @("/setactive", "SCHEME_BALANCED") | Out-Null }
    $ours = Find-OurScheme
    if ($ours) { Invoke-Pc @("/delete", $ours) | Out-Null }
    if ($b -and [int]$b.HibernateEnabled -eq 1) { Invoke-Pc @("/hibernate", "on") | Out-Null }
    Remove-Item $BackupFile -Force -ErrorAction SilentlyContinue
}

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
    Show-PowerStatus
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
try {
    if ($turnOff) {
        $w = @(Set-PowerQuiet)
        Write-Host "電源: スリープ・休止・電源ボタンを止めました (電源プラン「$SchemeName」)。" -ForegroundColor Green
        if ($w.Count -gt 0) { Write-Host ("  警告: 一部の電源設定が入りませんでした: " + ($w -join ", ") + "  (-Status で確認してください)") -ForegroundColor Yellow }
    }
    else { Restore-Power; Write-Host "電源: 元のプランに戻しました。" -ForegroundColor Green }
} catch { Write-Host ("  警告: 電源の設定に失敗: " + $_.Exception.Message) -ForegroundColor Yellow }
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
