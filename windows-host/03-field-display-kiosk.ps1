<#
.SYNOPSIS
    起動時に、左右のモニターへ FIELD system の画面を全画面 (キオスクモード) で自動表示します。
    証明書の警告は表示されず、ログイン画面まで自動で到達します (ログイン操作は手動)。

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
    [switch]$Settings,
    [switch]$Setup,
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
  "LeftUrl": ""
}
"@ | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "設定ファイルを作成しました: $ConfigFile" -ForegroundColor Cyan
}
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $PSBoundParameters.ContainsKey("RightUrl")) { $RightUrl = [string]$cfg.RightUrl }
if (-not $PSBoundParameters.ContainsKey("LeftUrl"))  { $LeftUrl  = [string]$cfg.LeftUrl }

# --- 設定 GUI: 左右の URL を入力ウィンドウで編集 ---
if ($Settings) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "FIELD 表示設定"
    $form.Size = New-Object System.Drawing.Size(560, 260)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lblR = New-Object System.Windows.Forms.Label
    $lblR.Text = "右モニターに表示する URL (空欄 = 表示しない):"
    $lblR.Location = New-Object System.Drawing.Point(15, 20)
    $lblR.AutoSize = $true
    $tbR = New-Object System.Windows.Forms.TextBox
    $tbR.Location = New-Object System.Drawing.Point(15, 45)
    $tbR.Size = New-Object System.Drawing.Size(510, 24)
    $tbR.Text = [string]$cfg.RightUrl

    $lblL = New-Object System.Windows.Forms.Label
    $lblL.Text = "左モニターに表示する URL (空欄 = 表示しない):"
    $lblL.Location = New-Object System.Drawing.Point(15, 85)
    $lblL.AutoSize = $true
    $tbL = New-Object System.Windows.Forms.TextBox
    $tbL.Location = New-Object System.Drawing.Point(15, 110)
    $tbL.Size = New-Object System.Drawing.Size(510, 24)
    $tbL.Text = [string]$cfg.LeftUrl

    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(330, 160)
    $btnOK.Size = New-Object System.Drawing.Size(90, 30)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(435, 160)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.DialogResult = "Cancel"

    $form.Controls.AddRange(@($lblR, $tbR, $lblL, $tbL, $btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq "OK") {
        $out = [ordered]@{
            "_説明"    = "左右モニターに全画面表示する URL の設定。『FIELD表示設定』アイコンから編集できます。"
            "RightUrl" = $tbR.Text.Trim()
            "LeftUrl"  = $tbL.Text.Trim()
        }
        $out | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("保存しました。次回の表示から反映されます。", "FIELD 表示設定") | Out-Null
    }
    exit 0
}

# --- デスクトップに『FIELD表示設定』アイコンを作成 ---
if ($Setup) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "FIELD表示設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Settings"
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,21"
    $lnk.Description  = "左右モニターに表示する FIELD 画面の URL を設定"
    $lnk.Save()
    Write-Host "デスクトップに『FIELD表示設定』アイコンを作成しました。" -ForegroundColor Green
    exit 0
}

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

Open-Kiosk $RightUrl $rightScreen "FieldKioskR"
Open-Kiosk $LeftUrl  $leftScreen  "FieldKioskL"

Write-Host "表示しました (ログインは画面上で行ってください)。閉じるには各画面で Alt+F4。"
