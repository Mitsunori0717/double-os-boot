<#
.SYNOPSIS
    メーカー専用機 Linux (FANUC EdgeBox 等) の物理ディスクを、
    Windows ホスト上の Hyper-V VM としてそのまま起動する定義を作成します。

.DESCRIPTION
    - 対象ディスクを Windows からオフライン化し (誤操作・同時アクセス防止)、
      無改造のまま VM に接続します (イメージのコピーや変換はしません)
    - セキュアブートを無効化します (専用機は独自の署名チェーンを持つため)
    - メモリは固定割り当て、チェックポイントは無効 (物理ディスクのため)
    - ネットワークは外部スイッチ推奨 (工作機械が VM に到達できる必要があるため)

.EXAMPLE
    # まずディスク番号と NIC 名を確認
    Get-Disk
    Get-NetAdapter

    # EdgeBox のディスクが 0、有線LAN が "イーサネット" の場合
    .\01-create-field-vm.ps1 -DiskNumber 0 -NetAdapterName "イーサネット"

.NOTES
    管理者権限の PowerShell で実行してください。
    元に戻す (ネイティブ起動に戻す) 手順は windows-host/README.md を参照。
#>
[CmdletBinding()]
param(
    # 専用機 Linux が入っている物理ディスク番号 (Get-Disk で確認)
    [Parameter(Mandatory = $true)]
    [int]$DiskNumber,

    [string]$VMName   = "EdgeBox",
    [int]$MemoryGB    = 8,
    [int]$CpuCount    = 6,

    # 外部スイッチを作る物理 NIC 名 (Get-NetAdapter で確認)。IP アドレスでも指定できます。
    # 省略時は Default Switch (NAT) になり、工作機械から VM に到達できないため
    # 収集運用では必ず指定を推奨
    [string]$NetAdapterName = "",

    # 既にある Hyper-V 仮想スイッチをそのまま使う場合はこちら (Get-VMSwitch で確認)
    [string]$SwitchName = "",

    # 確認プロンプトを出さずに実行する (00-field-launcher.ps1 から呼ぶとき用)
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限の PowerShell で実行してください。"
    exit 1
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V が有効になっていません。alternatives\hyperv\windows\01-enable-hyperv.ps1 を実行して再起動してください。"
    exit 1
}
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Error "VM '$VMName' は既に存在します。削除するには: Remove-VM $VMName -Force"
    exit 1
}

# --- 安全確認: システムディスク (C:) ではないこと ---
$sysDisk = (Get-Partition -DriveLetter C).DiskNumber
if ($DiskNumber -eq $sysDisk) {
    Write-Error "ディスク $DiskNumber は Windows のシステムディスクです。専用機 Linux のディスク番号を指定してください。"
    exit 1
}

# --- ネットワーク NIC の確認 (ディスクに触れる前に済ませる) ---
# 名前・IP アドレス・説明のどれで指定されても、実際のアダプター名に解決する
function Show-NetAdapters {
    Write-Host ""
    Write-Host "この PC の LAN アダプター一覧:" -ForegroundColor Cyan
    $rows = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($a in $rows) {
        $ips = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            ForEach-Object { $_.IPAddress })
        Write-Host ("  名前: {0,-22} 状態: {1,-8} IP: {2,-16} {3}" -f `
            $a.Name, $a.Status, $(if ($ips.Count -gt 0) { $ips -join "," } else { "(なし)" }), $a.InterfaceDescription)
    }
    Write-Host ""
    Write-Host "  -NetAdapterName には上の『名前』を指定してください (例: -NetAdapterName 'イーサネット 2')" -ForegroundColor Yellow
}

function Show-VMSwitches {
    $sws = @(Get-VMSwitch -ErrorAction SilentlyContinue)
    Write-Host ""
    if ($sws.Count -eq 0) {
        Write-Host "この PC には Hyper-V 仮想スイッチがまだありません。" -ForegroundColor Cyan
        return
    }
    Write-Host "既にある Hyper-V 仮想スイッチ:" -ForegroundColor Cyan
    foreach ($sw in $sws) {
        Write-Host ("  名前: {0,-24} 種類: {1,-10} {2}" -f $sw.Name, $sw.SwitchType, $sw.NetAdapterInterfaceDescription)
    }
    Write-Host "  既存のものを使う場合: -SwitchName '<上の名前>'" -ForegroundColor Yellow
}

# ホスト側の仮想アダプター名 (vEthernet (X)) から、その仮想スイッチを探す
function Get-SwitchByHostAdapter([string]$AdapterName) {
    foreach ($sw in @(Get-VMSwitch -ErrorAction SilentlyContinue)) {
        if ($AdapterName -eq ("vEthernet (" + $sw.Name + ")")) { return $sw }
    }
    return $null
}

# 物理 NIC が既にどれかの外部スイッチに割り当て済みかを調べる
function Get-SwitchByPhysicalNic($Nic) {
    if (-not $Nic) { return $null }
    foreach ($sw in @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)) {
        if ($sw.NetAdapterInterfaceDescription -eq $Nic.InterfaceDescription) { return $sw }
    }
    return $null
}

function Resolve-NetAdapterName([string]$Spec) {
    $a = Get-NetAdapter -Name $Spec -ErrorAction SilentlyContinue
    if ($a) { return $a.Name }
    # IPv4 アドレスで指定された場合は、そのアドレスを持つアダプターを探す
    if ($Spec -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $ip = @(Get-NetIPAddress -IPAddress $Spec -AddressFamily IPv4 -ErrorAction SilentlyContinue)[0]
        if ($ip) {
            $byIp = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
            if ($byIp) {
                Write-Host "IP $Spec は LAN アダプター『$($byIp.Name)』のものでした。これを使います。" -ForegroundColor Cyan
                return $byIp.Name
            }
        }
        return $null
    }
    # 製品名 (説明) の一部でも探す
    $byDesc = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like "*$Spec*" })
    if ($byDesc.Count -eq 1) {
        Write-Host "『$Spec』は LAN アダプター『$($byDesc[0].Name)』と判断しました。" -ForegroundColor Cyan
        return $byDesc[0].Name
    }
    return $null
}

# 使用するスイッチ名 ($useSwitch) と、新規作成が必要なら元になる NIC ($createFrom) を決める
$useSwitch = ""
$createFrom = ""

if ($SwitchName) {
    # --- 既にあるスイッチを指定された ---
    $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $sw) {
        Write-Host ""
        Write-Host "仮想スイッチ『$SwitchName』がありません。" -ForegroundColor Red
        Show-VMSwitches
        Write-Host "ディスクには何も変更していません。" -ForegroundColor Green
        exit 1
    }
    $useSwitch = $sw.Name
    Write-Host "既存の仮想スイッチ『$useSwitch』($($sw.SwitchType)) を使います。" -ForegroundColor Cyan

} elseif ($NetAdapterName) {
    $resolvedNic = Resolve-NetAdapterName $NetAdapterName
    if (-not $resolvedNic) {
        Write-Host ""
        Write-Host "LAN アダプター『$NetAdapterName』が見つかりません。" -ForegroundColor Red
        if ($NetAdapterName -match '^\d{1,3}(\.\d{1,3}){3}$') {
            Write-Host "  IP アドレスで指定されましたが、その IP を持つアダプターはこの PC にありません。" -ForegroundColor Yellow
            Write-Host "  (工作機械や EdgeBox 側の IP ではなく、この PC の LAN ポートを指定してください)" -ForegroundColor Yellow
        }
        Show-NetAdapters
        Show-VMSwitches
        Write-Host "ディスクには何も変更していません。上の一覧から選んで実行し直してください。" -ForegroundColor Green
        exit 1
    }

    # 指定されたのが仮想スイッチ側のアダプター (vEthernet (X)) なら、そのスイッチを使う
    $sw = Get-SwitchByHostAdapter $resolvedNic
    if (-not $sw) {
        # 物理 NIC が既に外部スイッチへ割り当て済みなら、それを再利用する
        # (1 枚の NIC を 2 つの外部スイッチに割り当てることはできないため)
        $sw = Get-SwitchByPhysicalNic (Get-NetAdapter -Name $resolvedNic -ErrorAction SilentlyContinue)
    }
    if ($sw) {
        $useSwitch = $sw.Name
        Write-Host "『$resolvedNic』は既存の仮想スイッチ『$useSwitch』のものでした。これをそのまま使います。" -ForegroundColor Cyan
        Write-Host "  (新しいスイッチは作らないため、ネットワークは切断されません)"
    } else {
        $useSwitch = "EdgeBox-External"
        $createFrom = $resolvedNic
    }

} else {
    # --- 指定なし: 外部スイッチが 1 つだけならそれを使う ---
    $ext = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
    if ($ext.Count -eq 1) {
        $useSwitch = $ext[0].Name
        Write-Host "外部スイッチ『$useSwitch』が 1 つだけあるため、これを使います。" -ForegroundColor Cyan
    } elseif ($ext.Count -gt 1) {
        Write-Host ""
        Write-Host "外部スイッチが複数あります。どれを使うか -SwitchName で指定してください。" -ForegroundColor Red
        Show-VMSwitches
        Write-Host "ディスクには何も変更していません。" -ForegroundColor Green
        exit 1
    } else {
        $useSwitch = "Default Switch"
        Write-Host "警告: Default Switch (NAT) を使用します。工作機械から VM に到達できません。" -ForegroundColor Yellow
        Write-Host "      収集運用では -NetAdapterName または -SwitchName を指定してください。"
    }
}

# --- 同じ物理ディスクを既に他の VM が使っていないか (同時使用は不可) ---
foreach ($other in @(Get-VM -ErrorAction SilentlyContinue)) {
    foreach ($d in @(Get-VMHardDiskDrive -VMName $other.Name -ErrorAction SilentlyContinue)) {
        if ($d.DiskNumber -eq $DiskNumber) {
            Write-Host ""
            Write-Host "ディスク $DiskNumber は既に VM『$($other.Name)』が使っています。" -ForegroundColor Red
            Write-Host "  1 つの物理ディスクを 2 つの VM から同時に使うことはできません。" -ForegroundColor Yellow
            Write-Host "  旧構成の VM が残っている場合は、先に削除してください: Remove-VM '$($other.Name)' -Force" -ForegroundColor Yellow
            Write-Host "ディスクには何も変更していません。" -ForegroundColor Green
            exit 1
        }
    }
}

$disk = Get-Disk -Number $DiskNumber
Write-Host "対象ディスク:" -ForegroundColor Cyan
Write-Host ("  番号 {0}: {1} ({2:N0} GB)" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
if (-not $NoConfirm) {
    $ans = Read-Host "このディスクを VM として起動します。よろしいですか? (y/N)"
    if ($ans -ne "y") { exit 0 }
}

# --- WSL にアタッチされたままだと衝突するため注意喚起 ---
Write-Host "注意: このディスクを wsl --mount している場合は、先に wsl --unmount してください。" -ForegroundColor Yellow

# --- ディスクをオフライン化 (Windows 側から見えなくし、VM 専有にする) ---
if (-not $disk.IsOffline) {
    Write-Host "ディスクをオフライン化しています (Windows からの誤アクセス防止)..." -ForegroundColor Cyan
    Set-Disk -Number $DiskNumber -IsOffline $true
}

# --- ネットワークスイッチ (必要な場合のみ新規作成) ---
if ($createFrom) {
    Write-Host "外部スイッチ '$useSwitch' を作成しています (NIC: $createFrom)..." -ForegroundColor Cyan
    Write-Host "  ※ 作成の瞬間、ネットワークが数秒切断されます。"
    New-VMSwitch -Name $useSwitch -NetAdapterName $createFrom -AllowManagementOS $true | Out-Null
}

Write-Host "VM '$VMName' を作成しています..." -ForegroundColor Cyan
New-VM -Name $VMName `
    -Generation 2 `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -NoVHD `
    -SwitchName $useSwitch | Out-Null

# 専用機は独自の署名済みブートチェーンを持つため、MS のセキュアブートは無効化
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

Set-VMProcessor -VMName $VMName -Count $CpuCount

# 物理ディスクを無改造のまま接続し、起動デバイスに設定
Add-VMHardDiskDrive -VMName $VMName -DiskNumber $DiskNumber
$bootDisk = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDisk

# 物理ディスクのためチェックポイントは使用不可。自動停止はシャットダウン要求に
Set-VM -Name $VMName -CheckpointType Disabled -AutomaticStopAction ShutDown

Write-Host ""
Write-Host "作成しました。" -ForegroundColor Green
Write-Host "  VM 名      : $VMName"
Write-Host "  ディスク   : 物理ディスク $DiskNumber (無改造・専有)"
Write-Host "  CPU        : ${CpuCount} 仮想プロセッサ / メモリ: ${MemoryGB}GB (固定)"
Write-Host "  スイッチ   : $useSwitch"
Write-Host ""
Write-Host "起動するには: .\02-start-field-vm.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "重要:" -ForegroundColor Yellow
Write-Host "  - 初回起動でメーカーシステムが正常に立ち上がるか、ライセンス・機器認識に"
Write-Host "    問題がないかを必ず確認してください (VM での動作はメーカーサポート外です)。"
Write-Host "  - 問題があれば VM を削除し、README の手順でネイティブ起動に戻せます"
Write-Host "    (ディスクは無改造なので、いつでも元の運用に戻れます)。"
