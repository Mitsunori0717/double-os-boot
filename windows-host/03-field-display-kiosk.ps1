<#
.SYNOPSIS
    FIELD system の管理画面を、サブモニターに全画面 (キオスクモード) で自動表示します。

.DESCRIPTION
    - FIELD system VM の起動と Web 画面の応答を待ってから、Edge をキオスクモード
      (枠なし全画面) でサブモニターに開きます
    - -Install を付けて一度実行すると、ログオン時に自動実行されるタスクを登録します。
      以後、PC の電源を入れてログオンするだけで「モニター1 = Windows、
      モニター2 = FIELD system 全画面」の状態になります

.EXAMPLE
    .\03-field-display-kiosk.ps1            # 今すぐ表示 (動作確認用)
    .\03-field-display-kiosk.ps1 -Install   # ログオン時の自動実行を登録
    .\03-field-display-kiosk.ps1 -Uninstall # 自動実行を解除
#>
[CmdletBinding()]
param(
    [string]$VMName = "FIELDsystem",
    [switch]$Install,
    [switch]$Uninstall,
    [int]$TimeoutSec = 420
)

$ErrorActionPreference = "Stop"
$TaskName = "FIELD-Display-Kiosk"

if ($Install) {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -RunLevel Highest -Force | Out-Null
    Write-Host "登録しました。次回ログオンから、サブモニターに FIELD system が自動で全画面表示されます。" -ForegroundColor Green
    exit 0
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "自動表示を解除しました。"
    exit 0
}

# --- VM の起動を待つ ---
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") { break }
    Start-Sleep -Seconds 5
}

# --- IP アドレスの取得を待つ ---
$ip = $null
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $ip = (Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue).IPAddresses |
        Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" -and $_ -notmatch "^169\.254\." } |
        Select-Object -First 1
    if ($ip) { break }
    Start-Sleep -Seconds 5
}
if (-not $ip) {
    Write-Warning "FIELD system の IP を取得できませんでした。VM の状態を確認してください。"
    exit 1
}

# --- Web 画面の応答を待つ (https → http の順に試す) ---
$url = $null
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec -and -not $url) {
    foreach ($cand in @("https://$ip", "http://$ip")) {
        try {
            $port = if ($cand.StartsWith("https")) { 443 } else { 80 }
            $tcp = New-Object Net.Sockets.TcpClient
            if ($tcp.ConnectAsync($ip, $port).Wait(3000)) { $url = $cand }
            $tcp.Dispose()
            if ($url) { break }
        } catch { }
    }
    if (-not $url) { Start-Sleep -Seconds 5 }
}
if (-not $url) {
    Write-Warning "FIELD system の Web 画面 (80/443) が応答しません。"
    exit 1
}

# --- サブモニターの位置を取得 ---
Add-Type -AssemblyName System.Windows.Forms
$sub = [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
if ($sub) {
    $posX = $sub.Bounds.X; $posY = $sub.Bounds.Y
} else {
    $posX = 0; $posY = 0   # サブモニター未検出時はメインに表示
}

# --- Edge をキオスクモードで起動 ---
$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) {
    Write-Warning "Microsoft Edge が見つかりません。"
    exit 1
}

& $edge --user-data-dir="$env:LOCALAPPDATA\FieldKiosk" --no-first-run --new-window `
    --window-position="$posX,$posY" --kiosk $url --edge-kiosk-type=fullscreen

Write-Host "FIELD system ($url) をサブモニターに全画面表示しました。"
Write-Host "(終了するには Alt+F4)"
