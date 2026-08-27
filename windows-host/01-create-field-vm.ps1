<#
.SYNOPSIS
    メーカー専用機 Linux (FANUC FIELD system 等) の物理ディスクを、
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

    # FIELD system のディスクが 0、有線LAN が "イーサネット" の場合
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

    [string]$VMName   = "FIELDsystem",
    [int]$MemoryGB    = 8,
    [int]$CpuCount    = 6,

    # 外部スイッチを作る物理 NIC 名 (Get-NetAdapter で確認)。
    # 省略時は Default Switch (NAT) になり、工作機械から VM に到達できないため
    # 収集運用では必ず指定を推奨
    [string]$NetAdapterName = ""
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

$disk = Get-Disk -Number $DiskNumber
Write-Host "対象ディスク:" -ForegroundColor Cyan
Write-Host ("  番号 {0}: {1} ({2:N0} GB)" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
$ans = Read-Host "このディスクを VM として起動します。よろしいですか? (y/N)"
if ($ans -ne "y") { exit 0 }

# --- WSL にアタッチされたままだと衝突するため注意喚起 ---
Write-Host "注意: このディスクを wsl --mount している場合は、先に wsl --unmount してください。" -ForegroundColor Yellow

# --- ディスクをオフライン化 (Windows 側から見えなくし、VM 専有にする) ---
if (-not $disk.IsOffline) {
    Write-Host "ディスクをオフライン化しています (Windows からの誤アクセス防止)..." -ForegroundColor Cyan
    Set-Disk -Number $DiskNumber -IsOffline $true
}

# --- ネットワークスイッチ ---
if ($NetAdapterName) {
    $switchName = "FIELD-External"
    if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
        Write-Host "外部スイッチ '$switchName' を作成しています (NIC: $NetAdapterName)..." -ForegroundColor Cyan
        Write-Host "  ※ 作成の瞬間、ネットワークが数秒切断されます。"
        New-VMSwitch -Name $switchName -NetAdapterName $NetAdapterName -AllowManagementOS $true | Out-Null
    }
} else {
    $switchName = "Default Switch"
    Write-Host "警告: Default Switch (NAT) を使用します。工作機械から VM に到達できません。" -ForegroundColor Yellow
    Write-Host "      収集運用では -NetAdapterName で物理 NIC を指定してください。"
}

Write-Host "VM '$VMName' を作成しています..." -ForegroundColor Cyan
New-VM -Name $VMName `
    -Generation 2 `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -NoVHD `
    -SwitchName $switchName | Out-Null

# 専用機は独自の署名済みブートチェーンを持つため、MS のセキュアブートは無効化
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

Set-VMProcessor -VMName $VMName -Count $CpuCount

# 物理ディスクを無改造のまま接続し、起動デバイスに設定
Add-VMHardDiskDrive -VMName $VMName -DiskNumber $DiskNumber
$bootDisk = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $bootDisk

# 物理ディスクのためチェックポイントは使用不可。自動停止はシャットダウン要求に
Set-VM -VMName $VMName -CheckpointType Disabled -AutomaticStopAction ShutDown

Write-Host ""
Write-Host "作成しました。" -ForegroundColor Green
Write-Host "  VM 名      : $VMName"
Write-Host "  ディスク   : 物理ディスク $DiskNumber (無改造・専有)"
Write-Host "  CPU        : ${CpuCount} 仮想プロセッサ / メモリ: ${MemoryGB}GB (固定)"
Write-Host "  スイッチ   : $switchName"
Write-Host ""
Write-Host "起動するには: .\02-start-field-vm.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "重要:" -ForegroundColor Yellow
Write-Host "  - 初回起動でメーカーシステムが正常に立ち上がるか、ライセンス・機器認識に"
Write-Host "    問題がないかを必ず確認してください (VM での動作はメーカーサポート外です)。"
Write-Host "  - 問題があれば VM を削除し、README の手順でネイティブ起動に戻せます"
Write-Host "    (ディスクは無改造なので、いつでも元の運用に戻れます)。"
