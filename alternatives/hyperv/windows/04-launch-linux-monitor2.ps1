<#
.SYNOPSIS
    Linux 仮想マシンを起動し、指定モニターにフルスクリーン表示します。

.DESCRIPTION
    - VM が停止していれば起動し、IP アドレスの取得を待ちます
    - RDP 接続ファイルを生成し、mstsc で指定モニターに全画面表示します
    - Linux 側で xrdp が動いている必要があります (linux/setup-guest.sh で設定)

.EXAMPLE
    .\04-launch-linux-monitor2.ps1
    .\04-launch-linux-monitor2.ps1 -MonitorIndex 2   # モニター番号は mstsc /l で確認

.NOTES
    デスクトップにショートカットを作っておくと、ワンクリックで
    「モニター2 = Linux」の状態にできます。
#>
[CmdletBinding()]
param(
    [string]$VMName = "LinuxVM",

    # 表示先モニター番号。mstsc /l で表示される番号 (0 始まり)。既定はモニター2 (= 1)
    [int]$MonitorIndex = 1,

    # IP 取得を待つ最大秒数
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = "Stop"

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "仮想マシン '$VMName' が見つかりません。windows\02-create-linux-vm.ps1 で作成してください。"
    exit 1
}

if ($vm.State -ne "Running") {
    Write-Host "仮想マシン '$VMName' を起動しています..." -ForegroundColor Cyan
    Start-VM -Name $VMName
}

# IPv4 アドレスの取得を待つ (統合サービス経由)
Write-Host "IP アドレスの取得を待っています..." -ForegroundColor Cyan
$ip = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $ip = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
        Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" -and $_ -notmatch "^169\.254\." } |
        Select-Object -First 1
    if ($ip) { break }
    Start-Sleep -Seconds 3
}

if (-not $ip) {
    Write-Error "IP アドレスを取得できませんでした。VM 内で Hyper-V 統合サービスが動作しているか確認してください (linux/setup-guest.sh 参照)。"
    exit 1
}
Write-Host "Linux の IP アドレス: $ip" -ForegroundColor Green

# xrdp (3389) が応答するまで待つ
Write-Host "リモートデスクトップサービス (xrdp) の応答を待っています..." -ForegroundColor Cyan
$rdpReady = $false
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    if ((Test-NetConnection -ComputerName $ip -Port 3389 -WarningAction SilentlyContinue).TcpTestSucceeded) {
        $rdpReady = $true
        break
    }
    Start-Sleep -Seconds 3
}
if (-not $rdpReady) {
    Write-Error "ポート 3389 に接続できません。Linux 内で 'sudo systemctl status xrdp' を確認してください。"
    exit 1
}

# RDP 接続ファイルを生成
# use multimon + selectedmonitors で「指定した 1 枚のモニターに全画面」を実現する
$rdpFile = Join-Path $env:TEMP "$VMName-monitor$MonitorIndex.rdp"
@"
full address:s:$ip
screen mode id:i:2
use multimon:i:1
selectedmonitors:s:$MonitorIndex
desktopscalefactor:i:100
audiomode:i:0
redirectclipboard:i:1
autoreconnection enabled:i:1
authentication level:i:0
prompt for credentials:i:1
"@ | Set-Content -Path $rdpFile -Encoding ASCII

Write-Host "モニター $MonitorIndex に Linux デスクトップを全画面表示します..." -ForegroundColor Cyan
Start-Process "mstsc.exe" -ArgumentList "`"$rdpFile`""

Write-Host ""
Write-Host "接続ダイアログには Linux のユーザー名とパスワードを入力してください。" -ForegroundColor Yellow
Write-Host "モニター番号が違う場合は 'mstsc /l' で番号を確認し、-MonitorIndex で指定してください。"
