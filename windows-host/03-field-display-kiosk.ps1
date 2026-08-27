<#
.SYNOPSIS
    起動時に、左右のモニターへ FIELD system の画面を全画面 (キオスクモード) で自動表示します。

.DESCRIPTION
    - 表示する URL は同じフォルダの display-config.json で設定します (メモ帳で編集可)。
      初回実行時に自動作成されます。編集後の再登録は不要で、次回表示から反映されます
    - FIELD system VM の起動と Web 画面の応答を待ってから表示します
    - -Install を付けて一度実行すると、ログオン時に自動実行されるタスクを登録します

.EXAMPLE
    .\03-field-display-kiosk.ps1              # display-config.json の内容で今すぐ表示
    .\03-field-display-kiosk.ps1 -Install     # ログオン時の自動表示を登録
    .\03-field-display-kiosk.ps1 -Uninstall   # 自動表示を解除

    # 一時的に URL を指定して試す場合 (設定ファイルより優先)
    .\03-field-display-kiosk.ps1 -RightUrl "https://192.168.0.200/" -LeftUrl "https://192.168.0.205/boxsettings/"
#>
[CmdletBinding()]
param(
    [string]$VMName   = "FIELDsystem",
    [string]$RightUrl,
    [string]$LeftUrl,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$LoginSetup,
    [switch]$SaveLogin,
    [int]$TimeoutSec  = 420
)

$ErrorActionPreference = "Stop"
$TaskName = "FIELD-Display-Kiosk"
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"

# --- 設定ファイル (無ければ既定値で自動作成) ---
if (-not (Test-Path $ConfigFile)) {
    @"
{
  "_説明": "左右モニターに全画面表示する URL の設定。メモ帳で編集できます。空文字にするとそのモニターには表示しません。",
  "RightUrl": "https://192.168.0.200/",
  "LeftUrl": "",
  "AutoLogin": true,
  "LoginDelaySec": 12
}
"@ | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "設定ファイルを作成しました: $ConfigFile" -ForegroundColor Cyan
}
$CredFile = Join-Path $PSScriptRoot "kiosk-login.xml"

# --- ログイン情報の保存 (DPAPI 暗号化。このPC・このユーザーでのみ復号可能) ---
if ($SaveLogin) {
    $cred = Get-Credential -Message "FIELD system のログイン情報 (ユーザー名とパスワード)"
    if (-not $cred) { exit 0 }
    $cred | Export-Clixml -Path $CredFile
    Write-Host "保存しました: $CredFile" -ForegroundColor Green
    Write-Host "(Windows の暗号化機能で保護されており、このPCのこのユーザー以外は復号できません)"
    Write-Host "以後のキオスク表示で自動ログインが有効になります。無効化: display-config.json の AutoLogin を false に"
    exit 0
}
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $PSBoundParameters.ContainsKey("RightUrl")) { $RightUrl = [string]$cfg.RightUrl }
if (-not $PSBoundParameters.ContainsKey("LeftUrl"))  { $LeftUrl  = [string]$cfg.LeftUrl }

if ($Install) {
    # URL は焼き込まず、実行のたびに display-config.json を読む (編集だけで反映される)
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -RunLevel Highest -Force | Out-Null
    Write-Host "登録しました。次回ログオンから自動で全画面表示されます。" -ForegroundColor Green
    Write-Host "  表示内容の変更: $ConfigFile をメモ帳で編集 (再登録不要)"
    Write-Host "  現在の設定 → 右: $(if ($RightUrl) { $RightUrl } else { '(表示なし)' }) / 左: $(if ($LeftUrl) { $LeftUrl } else { '(表示なし)' })"
    exit 0
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "自動表示を解除しました。"
    exit 0
}
if (-not $RightUrl -and -not $LeftUrl) {
    Write-Error "表示する URL がありません。$ConfigFile を編集するか、-RightUrl/-LeftUrl を指定してください。"
    exit 1
}

# --- 初回ログイン設定モード: 通常ウィンドウで開き、ログインを記憶させる ---
if ($LoginSetup) {
    $edge = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    Write-Host "初回ログイン設定モード" -ForegroundColor Cyan
    Write-Host "開いた画面で次を行ってください:"
    Write-Host "  1. ログイン画面で ユーザー名・パスワード を入力"
    Write-Host "  2. 【ログイン状態を記憶】に必ずチェック"
    Write-Host "  3. Edge が『パスワードを保存しますか?』と聞いたら【保存】"
    Write-Host "  4. ログインできたらウィンドウを閉じる"
    Write-Host "これで以後のキオスク表示は、警告なし・ログイン済みの状態で開きます。" -ForegroundColor Green
    if ($RightUrl) { & $edge --user-data-dir="$env:LOCALAPPDATA\FieldKioskR" --no-first-run --ignore-certificate-errors --new-window $RightUrl }
    if ($LeftUrl)  { & $edge --user-data-dir="$env:LOCALAPPDATA\FieldKioskL" --no-first-run --ignore-certificate-errors --new-window $LeftUrl }
    exit 0
}

# --- VM の起動を待つ ---
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") { break }
    Start-Sleep -Seconds 5
}

# --- 表示対象 URL の応答を待つ ---
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
if (-not (Wait-Url $RightUrl)) { Write-Warning "右画面用 URL が応答しません: $RightUrl" }
if (-not (Wait-Url $LeftUrl))  { Write-Warning "左画面用 URL が応答しません: $LeftUrl" }

# --- モニターの位置を取得 (X座標で左右を判定) ---
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
    # --ignore-certificate-errors: FIELD の自己署名証明書の警告画面を出さない (この専用プロファイル内のみ)
    & $edge --user-data-dir="$env:LOCALAPPDATA\$profile" --no-first-run --new-window `
        --ignore-certificate-errors `
        --window-position="$($screen.Bounds.X),$($screen.Bounds.Y)" `
        --kiosk $u --edge-kiosk-type=fullscreen
    Start-Sleep -Seconds 2
}

# --- 自動ログイン (保存済みログイン情報を、開いた直後の画面へ自動タイプ) ---
$autoLogin  = ($cfg.AutoLogin -ne $false) -and (Test-Path $CredFile)
$loginDelay = if ($cfg.LoginDelaySec) { [int]$cfg.LoginDelaySec } else { 12 }
$loginCred  = if ($autoLogin) { Import-Clixml $CredFile } else { $null }

function Send-Login($cred) {
    if (-not $cred) { return }
    # SendKeys の特殊文字 (+^%~(){}) をエスケープ
    function Esc([string]$s) { ($s.ToCharArray() | ForEach-Object { if ("$_" -match '[+^%~(){}]') { "{$_}" } else { "$_" } }) -join "" }
    $u = Esc $cred.UserName
    $p = Esc $cred.GetNetworkCredential().Password
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    [System.Windows.Forms.SendKeys]::SendWait($u)
    [System.Windows.Forms.SendKeys]::SendWait("{TAB}")
    [System.Windows.Forms.SendKeys]::SendWait("^a")
    [System.Windows.Forms.SendKeys]::SendWait($p)
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
}

Open-Kiosk $RightUrl $rightScreen "FieldKioskR"
if ($RightUrl -and $loginCred) {
    Start-Sleep -Seconds $loginDelay   # ログイン画面の表示完了を待つ (遅い場合は LoginDelaySec を増やす)
    Send-Login $loginCred
}

Open-Kiosk $LeftUrl  $leftScreen  "FieldKioskL"
if ($LeftUrl -and $loginCred) {
    Start-Sleep -Seconds $loginDelay
    Send-Login $loginCred
}

Write-Host "表示しました。閉じるには各画面で Alt+F4。"
