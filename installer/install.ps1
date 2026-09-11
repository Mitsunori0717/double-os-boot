<#
.SYNOPSIS
    EdgeBox 一式を新しい PC に配置し、デスクトップのアイコンを作ります。
    EdgeBox-Setup.exe の中から呼ばれます (単体でも実行できます)。

.DESCRIPTION
    やること:
      1. 一式を C:\EdgeBox に配置する (既にあれば中身を入れ替え。設定と記録は残す)
      2. ダウンロードの印 (Mark of the Web) を外す
      3. デスクトップのアイコンを作る
         ※ Hyper-V がまだ無効な PC では、EdgeBox に関わるアイコンは作れません。
            その場合は Hyper-V を有効にして再起動したあと、もう一度この EXE を実行してください。

    EdgeBox の作成や CPU の分離といった、この PC に固有の作業は行いません。
    配置後、C:\EdgeBox\windows-host\SETUP-STEPS.md の①から順に進めてください。

.EXAMPLE
    .\install.ps1
    .\install.ps1 -InstallDir "D:\EdgeBox"
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "C:\EdgeBox"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 管理者でなければ、管理者として起動し直す ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" -InstallDir `"$InstallDir`"")
    } catch {
        Write-Host "管理者として実行してください。" -ForegroundColor Red
        Read-Host "Enter キーで閉じます"
    }
    exit 0
}

function Write-Step([string]$t) { Write-Host $t -ForegroundColor Cyan }

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " EdgeBox 一式を導入します"
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "配置先: $InstallDir"
Write-Host ""

# --- 1. 配置 ---
Write-Step "[1/3] ファイルを配置しています..."
$zip = Join-Path $here "payload.zip"
if (-not (Test-Path $zip)) { throw "payload.zip が見つかりません: $zip" }

# 既存の設定・記録は上書きしない (入れ替えても運用が続けられるように)
$keep = @{}
foreach ($rel in "windows-host\display-config.json", "windows-host\field-boot-entry.conf",
                 "windows-cpu-partition\cpu-partition.json", "windows-cpu-partition\cpu-apps.json") {
    $p = Join-Path $InstallDir $rel
    if (Test-Path $p) { $keep[$rel] = [IO.File]::ReadAllBytes($p) }
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($entry in $archive.Entries) {
        if (-not $entry.Name) { continue }   # フォルダ
        $dest = Join-Path $InstallDir $entry.FullName
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
    }
} finally { $archive.Dispose() }

foreach ($rel in $keep.Keys) {
    $p = Join-Path $InstallDir $rel
    New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
    [IO.File]::WriteAllBytes($p, $keep[$rel])
}
if ($keep.Count -gt 0) { Write-Host "      これまでの設定は残しました ($($keep.Count) 件)" }

# --- 2. ダウンロードの印を外す ---
Write-Step "[2/3] ダウンロードの印を外しています..."
Get-ChildItem $InstallDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# --- 3. デスクトップのアイコン ---
Write-Step "[3/3] デスクトップのアイコンを作っています..."
$hostDir = Join-Path $InstallDir "windows-host"
$cpuDir  = Join-Path $InstallDir "windows-cpu-partition"
$ok = @(); $ng = @()

function Invoke-Setup([string]$label, [string]$script, [string[]]$argv) {
    $p = Join-Path $hostDir $script
    if (-not (Test-Path $p)) { $script:ng += "$label (ファイルなし)"; return }
    try {
        & $p @argv *>&1 | Out-Null
        $script:ok += $label
    } catch {
        $script:ng += "$label"
    }
}

Invoke-Setup "EdgeBox 起動"        "00-field-launcher.ps1"       @("-Setup")
Invoke-Setup "設定"                "08-settings-console.ps1"     @("-Setup")
Invoke-Setup "全部シャットダウン"  "05-shutdown-all.ps1"         @("-Setup")
Invoke-Setup "EdgeBox 再起動/画面" "10-restart-edgebox.ps1"      @("-Setup")

# Windows Update の自動更新・自動再起動を止める (収集が勝手に止まらないように)
try {
    $wuScript = Join-Path $hostDir "12-windows-update.ps1"
    if (Test-Path $wuScript) {
        & $wuScript -Quiet *>&1 | Out-Null
        # 見張り役は -Quiet では登録しないため、ここで一度だけ通常実行して登録する
        & $wuScript *>&1 | Out-Null
        $ok += "Windows Update の自動更新を停止"
    }
} catch { $ng += "Windows Update の停止" }

# CPU 割り当て・監視のアイコン (Hyper-V が無くても作れる)
try {
    $cpuSetup = Join-Path $cpuDir "cpu-console.ps1"
    if (Test-Path $cpuSetup) {
        & $cpuSetup -Setup *>&1 | Out-Null
        $ok += "CPU割り当て / EdgeBox 監視"
    }
} catch { $ng += "CPU割り当て / EdgeBox 監視" }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " 配置が終わりました"
Write-Host "==============================================" -ForegroundColor Green
if ($ok.Count -gt 0) { Write-Host "作成したアイコン: $($ok -join ' / ')" -ForegroundColor Green }
if ($ng.Count -gt 0) {
    Write-Host ""
    Write-Host "作れなかったアイコン: $($ng -join ' / ')" -ForegroundColor Yellow
    Write-Host "  Hyper-V がまだ有効でない可能性があります。有効にして再起動したあと、"
    Write-Host "  この EXE をもう一度実行すると作られます。"
}
Write-Host ""
Write-Host ""
Write-Host "Windows Update は自動更新・自動再起動を止めてあります (収集が止まらないように)。" -ForegroundColor Yellow
Write-Host "  更新を当てる: $hostDir\12-windows-update.ps1 -UpdateNow"
Write-Host "  元に戻す    : $hostDir\12-windows-update.ps1 -Restore"
Write-Host ""
Write-Host "次の手順:" -ForegroundColor Cyan
Write-Host "  $hostDir\SETUP-STEPS.md の①から順に進めてください。"
Write-Host "  (Hyper-V の有効化 → EdgeBox の作成 → CPU の完全分離)"
Write-Host ""
Read-Host "Enter キーで閉じます"
