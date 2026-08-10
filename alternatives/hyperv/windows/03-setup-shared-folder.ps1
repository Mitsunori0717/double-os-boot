<#
.SYNOPSIS
    Windows と Linux でデータをやりとりするための共有フォルダを作成します。

.DESCRIPTION
    - D:\Shared を作成し、SMB 共有 "Shared" として公開します
    - 現在のユーザーにフルアクセス権を付与します
    - プライベートネットワークでファイル共有が通るようファイアウォール規則を有効化します

.EXAMPLE
    .\03-setup-shared-folder.ps1
    .\03-setup-shared-folder.ps1 -FolderPath "D:\Exchange" -ShareName "Exchange"

.NOTES
    管理者権限の PowerShell で実行してください。
#>
[CmdletBinding()]
param(
    [string]$FolderPath = "D:\Shared",
    [string]$ShareName  = "Shared"
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限の PowerShell で実行してください。"
    exit 1
}

New-Item -ItemType Directory -Path $FolderPath -Force | Out-Null

$currentUser = "$env:USERDOMAIN\$env:USERNAME"

if (Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue) {
    Write-Host "SMB 共有 '$ShareName' は既に存在します。設定をそのまま使用します。" -ForegroundColor Yellow
} else {
    New-SmbShare -Name $ShareName -Path $FolderPath -FullAccess $currentUser | Out-Null
    Write-Host "SMB 共有 '$ShareName' を作成しました。" -ForegroundColor Green
}

# ファイル共有 (SMB-In) のファイアウォール規則を有効化 (プライベートプロファイル)
Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -ErrorAction SilentlyContinue |
    Where-Object { $_.Profile -match "Private|Any" } |
    Enable-NetFirewallRule

# 日本語環境ではグループ名が異なるため両方試す
Get-NetFirewallRule -DisplayGroup "ファイルとプリンターの共有" -ErrorAction SilentlyContinue |
    Where-Object { $_.Profile -match "Private|Any" } |
    Enable-NetFirewallRule

$hostname = $env:COMPUTERNAME
$ips = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch "^(127\.|169\.254\.)" } |
    Select-Object -ExpandProperty IPAddress

Write-Host ""
Write-Host "共有フォルダの準備ができました。" -ForegroundColor Green
Write-Host "  Windows 側パス : $FolderPath"
Write-Host "  共有名         : \\$hostname\$ShareName"
Write-Host "  ホスト IP 候補 : $($ips -join ', ')"
Write-Host ""
Write-Host "次の手順: Linux 内で以下を実行してください。" -ForegroundColor Yellow
Write-Host "  sudo bash linux/setup-guest.sh --host-ip <上記のIP> --share-user $env:USERNAME --share-name $ShareName"
