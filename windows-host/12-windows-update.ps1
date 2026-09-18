<#
.SYNOPSIS
    Windows Update の自動更新と、勝手な再起動を確実に止めます。

.DESCRIPTION
    工場の PC は、更新の途中で再起動されると収集が止まります。
    Windows は設定を自分で元に戻す (修復する) しくみを持っているため、
    ポリシーだけでは足りません。次の 5 段で止めます。

      1. ポリシー      : 自動更新をしない / 使用中は再起動しない / 今の版に固定
      2. サービス      : 更新をつかさどるサービスを止めて無効にする
                         (修復役の WaaSMedicSvc も止めるため、設定が戻されない)
      3. 予約タスク    : 更新の巡回・再起動を仕掛けるタスクを止める
      4. 見張り役      : 毎日と起動時に 1〜3 を掛け直す (万一戻されても元に戻す)
      5. 先送り        : 1 が効かない版への保険として品質更新を先送り

    -Restore ですべて Windows の既定に戻せます。

.EXAMPLE
    .\12-windows-update.ps1            # 自動更新と自動再起動を止める (見張り役も登録)
    .\12-windows-update.ps1 -Status    # 今の状態を表示 (変更しない)
    .\12-windows-update.ps1 -UpdateNow # 更新を当てたいとき: 一時的に解除して更新画面を開く
    .\12-windows-update.ps1 -Restore   # Windows の既定に完全に戻す

.NOTES
    - 管理者権限が必要です。
    - 止めているのは「自動」更新です。更新そのものを当てない運用は安全ではありません。
      月に一度など、EdgeBox を止めてよい時間を決めて -UpdateNow で当ててください。
    - 更新サービスを止めるため、Microsoft Store の更新も止まります。
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$Status,
    [switch]$UpdateNow,
    [switch]$Quiet,                  # 見張り役から呼ばれるとき用 (画面に出さない)
    [int]$DeferQualityDays = 30
)

$ErrorActionPreference = "Stop"

$WU = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
$AU = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
$SVC = "HKLM:\SYSTEM\CurrentControlSet\Services"
$WatchTask = "EdgeBox-WindowsUpdate-Lock"
$LogFile = Join-Path $PSScriptRoot "windows-update-lock.log"

# 止めるサービス (名前 / 説明 / 既定の開始種別)
$Services = @(
    @{ Name = "wuauserv";     Desc = "Windows Update";           Default = 3 },
    @{ Name = "UsoSvc";       Desc = "更新の段取り役";            Default = 2 },
    @{ Name = "WaaSMedicSvc"; Desc = "更新設定の修復役";          Default = 3 },
    @{ Name = "uhssvc";       Desc = "Microsoft Update Health";   Default = 2 }
)

# 更新の巡回・再起動を仕掛ける予約タスク (在る物だけ扱う)
$UpdateTasks = @(
    "\Microsoft\Windows\UpdateOrchestrator\Reboot",
    "\Microsoft\Windows\UpdateOrchestrator\Reboot_AC",
    "\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task",
    "\Microsoft\Windows\UpdateOrchestrator\UScheduler_Oobe",
    "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker",
    "\Microsoft\Windows\WindowsUpdate\Scheduled Start",
    "\Microsoft\Windows\InstallService\ScanForUpdates",
    "\Microsoft\Windows\InstallService\ScanForUpdatesAsUser"
)

function Say([string]$t, [string]$color = "Gray") { if (-not $Quiet) { Write-Host $t -ForegroundColor $color } }
function Log([string]$t) {
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $t) } catch { }
}
function Get-RegValue([string]$path, [string]$name) {
    try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name } catch { return $null }
}
function Set-RegValue([string]$path, [string]$name, $value, [string]$type) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $value -Type $type
}
function Set-ServiceStart([string]$name, [int]$start) {
    # サービスの開始種別はレジストリで直接変える (Set-Service では権限で弾かれる物があるため)
    #   2 = 自動 / 3 = 手動 / 4 = 無効
    $p = Join-Path $SVC $name
    if (-not (Test-Path $p)) { return $false }
    try { Set-ItemProperty -Path $p -Name "Start" -Value $start -Type DWord -ErrorAction Stop; return $true }
    catch {
        # 保護されている場合は sc.exe でもう一度試す
        $verb = switch ($start) { 2 { "auto" } 3 { "demand" } default { "disabled" } }
        & sc.exe config $name start= $verb *>&1 | Out-Null
        return ((Get-RegValue $p "Start") -eq $start)
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Status) {
    Write-Error "管理者権限で実行してください (スタートボタンを右クリック →『ターミナル (管理者)』)。"
    exit 1
}

# ============================================================
#  状態表示
# ============================================================
if ($Status) {
    $ver = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "DisplayVersion"
    Write-Host ""
    Write-Host "この PC の Windows: $ver"
    Write-Host ""
    Write-Host "--- ポリシー ---"
    Write-Host "  自動更新:            $(if ((Get-RegValue $AU 'NoAutoUpdate') -eq 1) { '止めている' } else { '動いている (既定)' })"
    Write-Host "  使用中の自動再起動:  $(if ((Get-RegValue $AU 'NoAutoRebootWithLoggedOnUsers') -eq 1) { 'しない' } else { 'することがある (既定)' })"
    $trv = Get-RegValue $WU "TargetReleaseVersionInfo"
    Write-Host "  バージョンの固定:    $(if ($trv) { "$trv に固定" } else { '固定なし (既定)' })"
    $dq = Get-RegValue $WU "DeferQualityUpdatesPeriodInDays"
    Write-Host "  品質更新の先送り:    $(if ($dq) { "$dq 日" } else { 'なし (既定)' })"
    Write-Host ""
    Write-Host "--- サービス ---"
    foreach ($s in $Services) {
        $st = Get-RegValue (Join-Path $SVC $s.Name) "Start"
        if ($null -eq $st) { continue }
        $txt = switch ([int]$st) { 4 { "無効 (止めている)" } 3 { "手動" } 2 { "自動" } default { "種別 $st" } }
        $run = (Get-Service -Name $s.Name -ErrorAction SilentlyContinue).Status
        Write-Host ("  {0,-14} {1,-18} 現在: {2}" -f $s.Name, $txt, $run)
    }
    Write-Host ""
    Write-Host "--- 予約タスク ---"
    $dis = 0; $en = 0
    foreach ($t in $UpdateTasks) {
        $n = Split-Path $t -Leaf; $p = Split-Path $t -Parent
        $task = Get-ScheduledTask -TaskName $n -TaskPath "$p\" -ErrorAction SilentlyContinue
        if ($task) { if ($task.State -eq "Disabled") { $dis++ } else { $en++ } }
    }
    Write-Host "  止めている: $dis 件 / 動いている: $en 件"
    $w = Get-ScheduledTask -TaskName $WatchTask -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "見張り役: $(if ($w) { "登録あり ($($w.State))" } else { 'なし' })"
    Write-Host ""
    exit 0
}

# ============================================================
#  既定に戻す
# ============================================================
if ($Restore) {
    Unregister-ScheduledTask -TaskName $WatchTask -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($n in "NoAutoUpdate", "NoAutoRebootWithLoggedOnUsers", "AUOptions", "AlwaysAutoRebootAtScheduledTime") {
        Remove-ItemProperty -Path $AU -Name $n -ErrorAction SilentlyContinue
    }
    foreach ($n in "TargetReleaseVersion", "TargetReleaseVersionInfo", "ProductVersion",
                   "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays",
                   "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays") {
        Remove-ItemProperty -Path $WU -Name $n -ErrorAction SilentlyContinue
    }
    foreach ($s in $Services) { Set-ServiceStart $s.Name $s.Default | Out-Null }
    foreach ($t in $UpdateTasks) {
        $n = Split-Path $t -Leaf; $p = Split-Path $t -Parent
        try { Enable-ScheduledTask -TaskName $n -TaskPath "$p\" -ErrorAction Stop | Out-Null } catch { }
    }
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Host "Windows Update の設定を既定に戻しました。" -ForegroundColor Green
    Write-Host "  確実に反映するため、PC を再起動してください。"
    Log "既定に戻した"
    exit 0
}

# ============================================================
#  更新を当てたいとき: 一時的に解除して更新画面を開く
# ============================================================
if ($UpdateNow) {
    Write-Host "更新を当てられるよう、一時的に解除します..." -ForegroundColor Cyan
    Disable-ScheduledTask -TaskName $WatchTask -ErrorAction SilentlyContinue | Out-Null
    Set-RegValue $AU "NoAutoUpdate" 0 "DWord"
    foreach ($s in $Services) { Set-ServiceStart $s.Name $s.Default | Out-Null }
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service UsoSvc  -ErrorAction SilentlyContinue
    Log "更新のため一時解除"
    Start-Sleep -Seconds 2
    Start-Process "ms-settings:windowsupdate"
    Write-Host ""
    Write-Host "Windows Update の画面を開きました。" -ForegroundColor Green
    Write-Host "  1. 『更新プログラムのチェック』で更新を当てる"
    Write-Host "  2. EdgeBox を止めてよい時間に再起動する"
    Write-Host "  3. 落ち着いたら、もう一度このスクリプトを引数なしで実行して止め直す:"
    Write-Host "       .\12-windows-update.ps1" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "     (止め直しを忘れても、見張り役が翌日には掛け直します)"
    exit 0
}

# ============================================================
#  止める (既定の動作)
# ============================================================
Say "==============================================" "Cyan"
Say " Windows Update の自動更新と自動再起動を止めます" "Cyan"
Say "==============================================" "Cyan"

# --- 1. ポリシー ---
Set-RegValue $AU "NoAutoUpdate" 1 "DWord"
Set-RegValue $AU "AUOptions"    2 "DWord"      # 2 = 落とす前に知らせる (NoAutoUpdate が効かない版への保険)
Set-RegValue $AU "NoAutoRebootWithLoggedOnUsers" 1 "DWord"
Set-RegValue $AU "AlwaysAutoRebootAtScheduledTime" 0 "DWord"
Say "  [1/5] 自動更新と使用中の自動再起動を止めました。"

# --- 2. サービス ---
$svcOk = 0; $svcNg = @()
foreach ($s in $Services) {
    try { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue } catch { }
    if (Set-ServiceStart $s.Name 4) { $svcOk++ } else { $svcNg += $s.Name }
}
$svcNgText = ""
if ($svcNg.Count -gt 0) { $svcNgText = "  止められず: " + ($svcNg -join ", ") }
Say "  [2/5] 更新のサービスを $svcOk 件止めました。$svcNgText"

# --- 3. 予約タスク ---
$taskOk = 0
foreach ($t in $UpdateTasks) {
    $n = Split-Path $t -Leaf; $p = Split-Path $t -Parent
    try {
        if (Get-ScheduledTask -TaskName $n -TaskPath "$p\" -ErrorAction SilentlyContinue) {
            Disable-ScheduledTask -TaskName $n -TaskPath "$p\" -ErrorAction Stop | Out-Null
            $taskOk++
        }
    } catch { }
}
Say "  [3/5] 更新の予約タスクを $taskOk 件止めました。"

# --- 4. バージョンの固定と先送り ---
$ver = Get-RegValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" "DisplayVersion"
if ($ver) {
    Set-RegValue $WU "ProductVersion"          "Windows 11" "String"
    Set-RegValue $WU "TargetReleaseVersion"     1 "DWord"
    Set-RegValue $WU "TargetReleaseVersionInfo" $ver "String"
}
Set-RegValue $WU "DeferQualityUpdates"             1 "DWord"
Set-RegValue $WU "DeferQualityUpdatesPeriodInDays" $DeferQualityDays "DWord"
Set-RegValue $WU "DeferFeatureUpdates"             1 "DWord"
Set-RegValue $WU "DeferFeatureUpdatesPeriodInDays" 365 "DWord"
Say "  [4/5] Windows を $ver に固定し、更新を先送りにしました。"

# --- 5. 見張り役 (毎日と起動時に掛け直す) ---
if (-not $Quiet) {
    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Quiet"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trg = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -Daily -At "12:00")
    )
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $pr = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $WatchTask -Action $action -Trigger $trg `
        -Settings $ts -Principal $pr -Force | Out-Null
    Say "  [5/5] 見張り役を登録しました (毎日 12:00 と PC 起動時に掛け直します)。"
}

Log "止めた (サービス $svcOk 件 / タスク $taskOk 件)"

if (-not $Quiet) {
    Write-Host ""
    Write-Host "止めました。" -ForegroundColor Green
    Write-Host "  - 更新は自動では落ちてこず、勝手に再起動もしません"
    Write-Host "  - Windows が設定を戻しても、見張り役が掛け直します"
    Write-Host ""
    Write-Host "  状態の確認 : .\12-windows-update.ps1 -Status"
    Write-Host "  更新を当てる: .\12-windows-update.ps1 -UpdateNow"
    Write-Host "  既定に戻す : .\12-windows-update.ps1 -Restore"
    Write-Host ""
    Write-Host "注意: 止めているのは『自動』更新です。更新をずっと当てない運用は安全ではありません。" -ForegroundColor Yellow
    Write-Host "      月に一度など、当てる日をあらかじめ決めておいてください。"
}
