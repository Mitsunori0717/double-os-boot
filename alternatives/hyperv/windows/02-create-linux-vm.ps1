<#
.SYNOPSIS
    Linux 仮想マシンを D ドライブに作成します。

.DESCRIPTION
    - 仮想ディスク (VHDX) と VM 構成ファイルを D ドライブに配置します
    - 外部ネットワークに接続できる仮想スイッチが無ければ「Default Switch」を使用します
    - 作成後、ISO からの Linux インストールを開始できるよう VM を起動して接続画面を開きます

.EXAMPLE
    .\02-create-linux-vm.ps1 -IsoPath "C:\Users\you\Downloads\ubuntu-24.04-desktop-amd64.iso"

.NOTES
    管理者権限の PowerShell で実行してください。
#>
[CmdletBinding()]
param(
    # Linux インストール ISO のパス (Ubuntu Desktop 24.04 LTS 推奨)
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [string]$VMName     = "LinuxVM",

    # 仮想マシン一式の保存先。要件どおり D ドライブに置く
    [string]$VMPath     = "D:\LinuxVM",

    [int]$MemoryGB      = 8,
    [int]$CpuCount      = 4,
    [int]$DiskSizeGB    = 64,

    # 使用する仮想スイッチ名。省略時は Default Switch
    [string]$SwitchName = "Default Switch"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限の PowerShell で実行してください。"
    exit 1
}

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V が有効になっていません。先に windows\01-enable-hyperv.ps1 を実行し、再起動してください。"
    exit 1
}

if (-not (Test-Path $IsoPath)) {
    Write-Error "ISO が見つかりません: $IsoPath`nUbuntu は https://ubuntu.com/download/desktop から取得できます。"
    exit 1
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Error "仮想マシン '$VMName' は既に存在します。別名を -VMName で指定するか、既存 VM を削除してください。"
    exit 1
}

$driveRoot = [System.IO.Path]::GetPathRoot($VMPath)
if (-not (Test-Path $driveRoot)) {
    Write-Error "ドライブ $driveRoot が見つかりません。-VMPath で存在するドライブを指定してください。"
    exit 1
}

$free = (Get-PSDrive -Name $driveRoot.TrimEnd(':\')).Free
if ($free -lt 10GB) {
    Write-Warning "$driveRoot の空き容量が少なめです (VHDX は使用分だけ拡張されますが、最大 ${DiskSizeGB}GB まで成長します)。"
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Error "仮想スイッチ '$SwitchName' が見つかりません。Get-VMSwitch で既存スイッチ名を確認し -SwitchName で指定してください。"
    exit 1
}

$vhdxPath = Join-Path $VMPath "$VMName.vhdx"
New-Item -ItemType Directory -Path $VMPath -Force | Out-Null

Write-Host "仮想マシン '$VMName' を $VMPath に作成しています..." -ForegroundColor Cyan

New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -NewVHDPath $vhdxPath `
    -NewVHDSizeBytes ($DiskSizeGB * 1GB) `
    -Path $VMPath `
    -SwitchName $SwitchName | Out-Null

Set-VMProcessor -VMName $VMName -Count $CpuCount

# メモリは固定より動的の方がホスト側と共存しやすい
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true `
    -MinimumBytes 2GB -StartupBytes ($MemoryGB * 1GB) -MaximumBytes ($MemoryGB * 1GB)

# Linux ゲスト用: セキュアブートのテンプレートを Microsoft UEFI CA に変更
Set-VMFirmware -VMName $VMName -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

# ISO を接続し、DVD から起動するよう設定
Add-VMDvdDrive -VMName $VMName -Path $IsoPath
$dvd = Get-VMDvdDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

# 統合サービス (時刻同期・シャットダウンなど) を全て有効化
Get-VMIntegrationService -VMName $VMName | Enable-VMIntegrationService

# チェックポイント (スナップショット) も D ドライブ側へ
Set-VM -VMName $VMName -CheckpointType Production -SnapshotFileLocation $VMPath

Write-Host ""
Write-Host "仮想マシンを作成しました。" -ForegroundColor Green
Write-Host "  名前          : $VMName"
Write-Host "  仮想ディスク  : $vhdxPath (最大 ${DiskSizeGB}GB・容量可変)"
Write-Host "  メモリ        : ${MemoryGB}GB / CPU: ${CpuCount}コア"
Write-Host ""

Write-Host "VM を起動して接続画面を開きます。画面の指示に従って Linux をインストールしてください。" -ForegroundColor Cyan
Start-VM -Name $VMName
Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName

Write-Host ""
Write-Host "インストール完了後の手順:" -ForegroundColor Yellow
Write-Host "  1. windows\03-setup-shared-folder.ps1 を実行 (共有フォルダ作成)"
Write-Host "  2. Linux 内で linux/setup-guest.sh を実行 (xrdp と共有フォルダの設定)"
Write-Host "  3. windows\04-launch-linux-monitor2.ps1 でモニター2に全画面表示"
