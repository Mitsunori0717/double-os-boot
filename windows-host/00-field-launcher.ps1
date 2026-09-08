<#
.SYNOPSIS
    EdgeBox をワンクリックで起動します。
    EdgeBox があればそのまま起動し、無ければ作成してから起動します。

.DESCRIPTION
    これ 1 本で、毎回つまずきがちな段取りを全部自動でやります。

      1. 既存 EdgeBox を探す
         - 指定名の EdgeBox があればそれを使う
         - 名前が違っても、EdgeBox のディスクを使っている EdgeBox があればそれを使う
           (旧構成の EdgeBox がそのまま活きるので、作り直す必要がありません)
      2. 対象ディスクを決める
         - 既存 EdgeBox が使っているディスク / 前回の記録 / 指定 / 自動検出 の順
      3. 起動できない原因を先に片付ける
         - 同じディスクの二重接続を外す
         - 他の EdgeBox が同じディスクを掴んでいれば、その接続だけ外す (停止中のみ)
         - ディスクが Windows でオンラインならオフラインにする
      4. EdgeBox が無ければ作成する (01-create-field-vm.ps1 を呼ぶ)
      5. 起動してコンソールを表示する (02-start-field-vm.ps1 を呼ぶ)

    ディスクの中身には一切触れません。EdgeBox を消したり作り直したりもしません
    (作成は「EdgeBox がまったく無い場合」だけです)。

.EXAMPLE
    .\00-field-launcher.ps1              # おまかせ起動
    .\00-field-launcher.ps1 -Status      # 何が使われるかだけ確認 (変更しない)
    .\00-field-launcher.ps1 -Setup       # デスクトップに『EdgeBox 起動』アイコンを作成
    .\00-field-launcher.ps1 -DiskNumber 0 -SwitchName "EdgeBox-External"
    .\00-field-launcher.ps1 -NetAdapterName "イーサネット 2"   # 新規 PC (外部スイッチがまだ無い) の初回

.NOTES
    管理者権限が必要です (アイコンから起動すれば UAC 確認なしで管理者になります)。
#>
[CmdletBinding()]
param(
    [string]$VMName    = "EdgeBox",
    [int]$DiskNumber   = -1,      # 省略時: 既存 EdgeBox / 記録 / 自動検出 から決める
    [string]$SwitchName = "",     # 省略時: 既存の外部スイッチを自動選択
    [string]$NetAdapterName = "", # 外部スイッチがまだ無い PC で、ライン側 LAN ポートの Name (Get-NetAdapter)。IP でも可
    [int]$MemoryGB     = 8,
    [int]$CpuCount     = 6,
    [switch]$Status,              # 判定結果だけ表示 (何も変更しない)
    [switch]$Setup,               # デスクトップアイコンの作成
    [switch]$NoConfirm            # 確認プロンプトを出さない
)

$ErrorActionPreference = "Stop"

$DiskConf  = Join-Path $PSScriptRoot "field-disk.conf"
$Script01  = Join-Path $PSScriptRoot "01-create-field-vm.ps1"
$Script02  = Join-Path $PSScriptRoot "02-start-field-vm.ps1"
$TaskName  = "EdgeBox-Launcher"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Step([string]$Text) { Write-Host "" ; Write-Host "== $Text" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }
function Info([string]$Text) { Write-Host "   $Text" }

# アイコンからの起動では画面が残らないため、失敗はダイアログでも知らせる
function Fail([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    if ($NoConfirm) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Text, "EdgeBox 起動",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch { }
    }
    exit 1
}

function Confirm-Step([string]$Question) {
    if ($NoConfirm) { return $true }
    $a = Read-Host "   $Question (y/N)"
    return ($a -eq "y")
}

# ============================================================
#  デスクトップアイコンの作成
# ============================================================
if ($Setup) {
    if (-not (Test-Admin)) { Write-Error "管理者権限で実行してください。"; exit 1 }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoConfirm -VMName `"$VMName`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "EdgeBox 起動.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$TaskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7
    $lnk.IconLocation = "shell32.dll,15"
    $lnk.Description  = "EdgeBox を起動する (EdgeBox が無ければ作成してから起動)"
    $lnk.Save()
    Write-Host "デスクトップに『EdgeBox 起動』アイコンを作成しました (UAC 確認なしで起動できます)。" -ForegroundColor Green
    exit 0
}

if (-not (Test-Admin)) {
    Write-Error "管理者権限の PowerShell で実行してください (またはデスクトップの『EdgeBox 起動』アイコンから)。"
    exit 1
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V が有効になっていません。先に有効化して再起動してください: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All"
    exit 1
}

Write-Host ""
Write-Host "===== EdgeBox 起動 =====" -ForegroundColor White

# ============================================================
#  1. 既存 EdgeBox とディスクを探す
# ============================================================
function Get-PassthroughDisks([string]$Name) {
    @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.DiskNumber })
}

Step "既存の EdgeBox を確認"
$sysDisk = (Get-Partition -DriveLetter C).DiskNumber
$targetVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue

if ($targetVm) {
    Info "登録『$VMName』が見つかりました (状態: $($targetVm.State))"
} else {
    # 名前が違っても、物理ディスクを起動している EdgeBox があればそれが EdgeBox
    $candidates = @()
    foreach ($vm in @(Get-VM)) {
        foreach ($d in (Get-PassthroughDisks $vm.Name)) {
            if ($d.DiskNumber -ne $sysDisk) {
                $candidates += [pscustomobject]@{ EdgeBox = $vm; Disk = $d.DiskNumber }
            }
        }
    }
    $candidates = @($candidates | Group-Object { $_.EdgeBox.Name } | ForEach-Object { $_.Group[0] })
    if ($candidates.Count -eq 1) {
        $targetVm = $candidates[0].EdgeBox
        $VMName = $targetVm.Name
        Ok "名前は違いますが、EdgeBox のディスクを起動する 登録『$VMName』が見つかりました。これを使います。"
    } elseif ($candidates.Count -gt 1) {
        foreach ($c in $candidates) { Info "  $($c.EdgeBox.Name)  (ディスク $($c.Disk) / 状態 $($c.EdgeBox.State))" }
        Fail ("物理ディスクを使う EdgeBox が複数あります。-VMName でどれを使うか指定してください:`n" +
            (($candidates | ForEach-Object { "  " + $_.EdgeBox.Name }) -join "`n"))
    } else {
        Info "EdgeBox はまだありません (このあと作成します)"
    }
}

# ============================================================
#  2. 対象ディスクを決める
# ============================================================
Step "対象ディスクを確認"
$diskNo = -1
if ($targetVm) {
    $d = @(Get-PassthroughDisks $targetVm.Name)
    if ($d.Count -gt 0) { $diskNo = [int]$d[0].DiskNumber }
}
if ($diskNo -lt 0 -and $DiskNumber -ge 0) { $diskNo = $DiskNumber }
if ($diskNo -lt 0 -and (Test-Path $DiskConf)) {
    $v = (Get-Content $DiskConf -First 1).Trim()
    if ($v -match '^\d+$') { $diskNo = [int]$v }
}
if ($diskNo -lt 0) {
    # 自動検出: システムディスク以外の物理ディスク
    $others = @(Get-Disk | Where-Object { $_.Number -ne $sysDisk })
    if ($others.Count -eq 1) {
        $diskNo = [int]$others[0].Number
        Info "システムディスク以外はディスク $diskNo だけでした: $($others[0].FriendlyName)"
        if (-not (Confirm-Step "このディスクを EdgeBox のディスクとして使いますか?")) { exit 0 }
    } elseif ($others.Count -gt 1) {
        foreach ($o in $others) {
            Info ("  ディスク {0}: {1} ({2:N0} GB / オフライン={3})" -f $o.Number, $o.FriendlyName, ($o.Size / 1GB), $o.IsOffline)
        }
        Fail ("EdgeBox のディスクを特定できません。-DiskNumber で指定してください:`n" +
            (($others | ForEach-Object { "  ディスク {0}: {1}" -f $_.Number, $_.FriendlyName }) -join "`n"))
    } else {
        Write-Error "システムディスク以外の物理ディスクが見つかりません。EdgeBox のディスクが接続されているか確認してください。"
        exit 1
    }
}
$diskInfo = Get-Disk -Number $diskNo -ErrorAction SilentlyContinue
if (-not $diskInfo) { Write-Error "ディスク $diskNo が見つかりません。"; exit 1 }
if ($diskNo -eq $sysDisk) { Write-Error "ディスク $diskNo は Windows のシステムディスクです。中止します。"; exit 1 }
Ok ("ディスク {0}: {1} ({2:N0} GB)" -f $diskInfo.Number, $diskInfo.FriendlyName, ($diskInfo.Size / 1GB))
if (-not $Status) { $diskNo | Set-Content -Path $DiskConf -Encoding ASCII }

# ============================================================
#  3. 起動を妨げる状態を先に片付ける
# ============================================================
Step "ディスクの使用状況を確認"
$blocked = $false

# 3-a. 対象 に同じディスクが二重接続されていないか
if ($targetVm) {
    foreach ($g in (@(Get-PassthroughDisks $targetVm.Name) | Group-Object DiskNumber)) {
        if ($g.Count -le 1) { continue }
        Warn "ディスク $($g.Name) が $($g.Count) 回接続されています (二重接続)"
        if ($Status) { $blocked = $true; continue }
        foreach ($extra in @($g.Group | Select-Object -Skip 1)) {
            Remove-VMHardDiskDrive -VMName $targetVm.Name `
                -ControllerType $extra.ControllerType `
                -ControllerNumber $extra.ControllerNumber `
                -ControllerLocation $extra.ControllerLocation
        }
        Ok "余分な接続を外しました"
    }
}

# 3-b. 他の EdgeBox が同じディスクを掴んでいないか (旧構成の EdgeBox が残っている場合)
foreach ($other in @(Get-VM | Where-Object { -not $targetVm -or $_.Name -ne $targetVm.Name })) {
    foreach ($d in (Get-PassthroughDisks $other.Name)) {
        if ($d.DiskNumber -ne $diskNo) { continue }
        Warn "登録『$($other.Name)』が同じディスク $diskNo を掴んでいます (このままでは起動できません)"
        if ($Status) { $blocked = $true; continue }
        if ($other.State -ne "Off") {
            # 起動中ということは、EdgeBox が既にその EdgeBox で動いている可能性が高い
            Warn "  『$($other.Name)』は【起動中】です。EdgeBox は既にそちらで動いている可能性があります。"
            Info "    そのまま使う場合   : .\00-field-launcher.ps1 -VMName `"$($other.Name)`""
            Info "    こちらに切り替える : Stop-VM '$($other.Name)' で停止してから、もう一度実行"
            $blocked = $true
            continue
        }
        if (-not (Confirm-Step "『$($other.Name)』からディスクの接続だけを外しますか? (EdgeBox もデータも残ります)")) {
            $blocked = $true
            continue
        }
        Remove-VMHardDiskDrive -VMName $other.Name `
            -ControllerType $d.ControllerType `
            -ControllerNumber $d.ControllerNumber `
            -ControllerLocation $d.ControllerLocation
        Ok "『$($other.Name)』から接続を外しました (EdgeBox とディスクの中身はそのままです)"
    }
}

# 3-c. Windows 側でオンラインのままだと EdgeBox から開けない
$diskInfo = Get-Disk -Number $diskNo
if (-not $diskInfo.IsOffline) {
    Warn "ディスク $diskNo が Windows でオンラインです"
    if ($Status) {
        $blocked = $true
    } else {
        Set-Disk -Number $diskNo -IsOffline $true
        Ok "オフラインにしました (Windows からの誤アクセス防止)"
    }
} else {
    Ok "ディスク $diskNo はオフライン (EdgeBox 専有できる状態)"
}

if ($blocked -and -not $Status) {
    Fail "解消できない問題が残っているため起動できません。`n動作中の EdgeBox がディスクを掴んでいる場合は、その EdgeBox を停止してから再実行してください。"
}

# ============================================================
#  4. EdgeBox が無ければ作成する
# ============================================================
if ($Status) {
    Step "確認だけの実行のため、ここで終了します"
    if ($targetVm) {
        Info "起動する EdgeBox   : $($targetVm.Name) (状態: $($targetVm.State))"
    } else {
        Info "EdgeBox は未作成のため、実行時に新しく作成します (名前: $VMName)"
    }
    Info "使うディスク  : $diskNo"
    if ($blocked) { Warn "先に解消が必要な問題があります (上を参照)" }
    else { Ok "このまま起動できます" }
    exit 0
}

# 01 のスクリプトが使えない場合でも作成できるよう、同じ設定をここにも持つ
function New-FieldVmHere {
    $sw = $SwitchName
    if (-not $sw) {
        $ext = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
        if ($ext.Count -eq 1) { $sw = $ext[0].Name; Info "外部スイッチ『$sw』を使います" }
        elseif ($ext.Count -gt 1) {
            Fail ("外部スイッチが複数あります。-SwitchName で指定してください:`n" +
                (($ext | ForEach-Object { "  " + $_.Name }) -join "`n"))
        } elseif ($NetAdapterName) {
            # 新規 PC: 指定された LAN ポートで外部スイッチを作る (01 と同じ名前)
            $nic = Get-NetAdapter -Name $NetAdapterName -ErrorAction SilentlyContinue
            if (-not $nic) {
                $ip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $NetAdapterName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($ip) { $nic = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue }
            }
            if (-not $nic) { Fail "LAN ポート『$NetAdapterName』が見つかりません。Get-NetAdapter の Name を指定してください。" }
            New-VMSwitch -Name "EdgeBox-External" -NetAdapterName $nic.Name -AllowManagementOS $true | Out-Null
            $sw = "EdgeBox-External"
            Ok "外部スイッチ『$sw』を LAN ポート『$($nic.Name)』に作成しました"
        } else {
            # NAT (Default Switch) で作ると工作機械から到達できない EdgeBox ができてしまうため、黙って作らない
            Fail ("外部スイッチがありません。ライン側 LAN ポートを指定して実行してください:`n" +
                  "  .\00-field-launcher.ps1 -NetAdapterName `"<Get-NetAdapter の Name>`"`n" +
                  "(工作機械と通信するには、LAN ポートに直結した外部スイッチが必要です)")
        }
    }
    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) -NoVHD -SwitchName $sw | Out-Null
    Set-VMFirmware  -VMName $VMName -EnableSecureBoot Off        # EdgeBox は独自の署名チェーン
    Set-VMProcessor -VMName $VMName -Count $CpuCount
    Add-VMHardDiskDrive -VMName $VMName -DiskNumber $diskNo      # 物理ディスクを無改造のまま接続
    Set-VMFirmware  -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName)
    Set-VM -Name $VMName -CheckpointType Disabled -AutomaticStopAction ShutDown
}

if (-not $targetVm) {
    Step "EdgeBox を作成"
    if (-not (Confirm-Step "登録『$VMName』を作成します。よろしいですか?")) { exit 0 }
    $made = $false
    if (Test-Path $Script01) {
        $createArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$Script01`"",
                        "-DiskNumber", "$diskNo", "-VMName", "`"$VMName`"",
                        "-MemoryGB", "$MemoryGB", "-CpuCount", "$CpuCount", "-NoConfirm")
        if ($SwitchName) { $createArgs += @("-SwitchName", "`"$SwitchName`"") }
        if ($NetAdapterName) { $createArgs += @("-NetAdapterName", "`"$NetAdapterName`"") }
        $p = Start-Process powershell.exe -ArgumentList ($createArgs -join " ") -NoNewWindow -Wait -PassThru
        $made = ($p.ExitCode -eq 0) -and [bool](Get-VM -Name $VMName -ErrorAction SilentlyContinue)
        if (-not $made) { Warn "01-create-field-vm.ps1 では作成できませんでした。この画面の中で作成します。" }
    } else {
        Warn "01-create-field-vm.ps1 が見つからないため、この画面の中で作成します。"
    }
    if (-not $made) {
        try { New-FieldVmHere } catch { Fail "EdgeBox を作成できませんでした: $($_.Exception.Message)" }
    }
    $targetVm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $targetVm) { Fail "EdgeBox の作成に失敗しました。" }
    Ok "登録『$VMName』を作成しました"
}

# ============================================================
#  5. 起動する
# ============================================================
Step "起動"
$targetVm = Get-VM -Name $targetVm.Name -ErrorAction Stop   # 状態を最新にする
if ($targetVm.State -eq "Running") {
    Ok "すでに起動しています。コンソールを開きます。"
    Start-Process "vmconnect.exe" -ArgumentList "localhost", $targetVm.Name
    exit 0
}

$p = Start-Process powershell.exe -NoNewWindow -Wait -PassThru -ArgumentList (
    "-NoProfile -ExecutionPolicy Bypass -File `"$Script02`" -VMName `"$($targetVm.Name)`"")
if ($p.ExitCode -ne 0) {
    Fail "起動できませんでした (終了コード $($p.ExitCode))。`nもう一度実行すると、ディスクの片付けからやり直します。"
}

Write-Host ""
Write-Host "EdgeBox を起動しました。" -ForegroundColor Green
Write-Host "  起動画面で Ctrl キーを押しっぱなしにしないでください (工場出荷リセットが選ばれる機種があります)" -ForegroundColor Yellow
