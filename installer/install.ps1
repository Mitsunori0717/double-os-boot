<#
.SYNOPSIS
    Edge Box 一式を配置し、状態を自動判定する一括セットアップへ引き継ぎます。
    EdgeBox-Setup.exe の中から呼ばれます (単体でも実行できます)。

.DESCRIPTION
    やること:
      1. 一式を C:\EdgeBox に配置する (既にあれば中身を入れ替え。設定と記録は残す)
      2. ダウンロードの印 (Mark of the Web) を外す
      3. setup\setup-all.ps1 で未完了の設定だけを適用し、必要時に再起動します
    失敗時の原因・対処法・再実行する番号別バッチは setup\logs に残ります。

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
Write-Host " Edge Box 一式を導入します"
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
        $base = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
        $dest = [IO.Path]::GetFullPath((Join-Path $base $entry.FullName))
        if (-not $dest.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw '配布 ZIP に配置先の外を指す項目があります。' }
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

# --- 3. 一括セットアップへ引き継ぐ ---
Write-Step '[3/3] この PC の設定を確認し、未完了の手順を実行します...'
$setup=Join-Path $InstallDir 'setup\setup-all.ps1'
if (-not (Test-Path -LiteralPath $setup)) { throw 'setup フォルダがありません。最新の配布物を作成し直してください。' }
# 子プロセスで実行する。設定済みなら何も変更せず、失敗時は番号別の再実行先を案内する。
$child=Start-Process powershell.exe -NoNewWindow -Wait -PassThru -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$setup+'" -RestartIfNeeded -NoPause')
if ($child.ExitCode -notin @(0,3010)) {
    Write-Host ('未完了の設定があります。'+$InstallDir+'\setup\logs の最新の summary.txt を確認してください。') -ForegroundColor Yellow
}
Read-Host 'Enter キーで閉じます'
exit $child.ExitCode
