<#
.SYNOPSIS
    一式をまとめた EdgeBox-Setup.exe を作ります (Windows 標準の .NET Framework を使用)。

.DESCRIPTION
    作るもの:
      EdgeBox-Setup.exe … 中身を取り出して導入まで行う 1 つの実行ファイル

    しくみ:
      1. windows-host、windows-cpu-partition、setup とルートの入口を集める
         (この PC だけの設定や記録は除く)
      2. payload.zip にまとめる
      3. payload.zip と install.ps1 を、管理者権限を要求する 1 つの EXE に埋め込む

    .NET Framework は対象の Windows 11 に標準で入っているため、追加の導入は不要です。

.EXAMPLE
    .\build-installer.cmd            # ダブルクリックでも可
    .\build-installer.ps1 -OutFile "C:\temp\EdgeBox-Setup.exe"
    .\build-installer.ps1 -ZipOnly   # 同じセットアップ一式を ZIP で配布
#>
[CmdletBinding()]
param(
    [string]$OutFile = "",
    [switch]$ZipOnly
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $OutFile) { $OutFile = Join-Path $here $(if ($ZipOnly) {'EdgeBox-Setup.zip'} else {'EdgeBox-Setup.exe'}) }
$OutFile = [IO.Path]::GetFullPath($OutFile)

$stage = Join-Path ([IO.Path]::GetTempPath()) ("EdgeBoxBuild_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$payloadDir = Join-Path $stage "payload"
New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
$buildOk=$false

try {
    # ---------- 1. 必要なファイルを集める ----------
    Write-Host "[1/4] 必要なファイルを集めています..." -ForegroundColor Cyan
    foreach ($d in "windows-host", "windows-cpu-partition", "setup") {
        $src = Join-Path $root $d
        if (-not (Test-Path $src)) { throw "$d が見つかりません: $src" }
        # ソースだけを同梱する許可リスト。設定・ログ・資格情報・端末固有の状態は持ち出さない。
        $destDir=Join-Path $payloadDir $d
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Get-ChildItem -LiteralPath $src -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.cmd','.md','.cs') } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destDir -Force }
    }
    # アプリ名の字体 (同梱フォントとそのライセンス)
    $fonts = Join-Path $root "windows-cpu-partition\fonts"
    if (Test-Path -LiteralPath $fonts) { Copy-Item -LiteralPath $fonts -Destination (Join-Path $payloadDir "windows-cpu-partition") -Recurse -Force }
    foreach ($f in @('start.cmd','setup-all.cmd','update.cmd','update.ps1')) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $payloadDir -Force }
    $readme = Join-Path $root "README.md"
    if (Test-Path $readme) { Copy-Item $readme $payloadDir -Force }

    # この PC だけの設定・記録は配布物に含めない
    $exclude = @(
        "windows-host\display-config.json", "windows-host\display-log.txt",
        "windows-host\display-error.txt", "windows-host\display-status.txt",
        "windows-host\field-boot-entry.conf", "windows-host\kiosk-login.xml",
        "windows-cpu-partition\cpu-partition.json", "windows-cpu-partition\cpu-apps.json",
        "windows-host\windows-update-lock.log", "windows-host\io-pending.json"
    )
    foreach ($e in $exclude) { Remove-Item (Join-Path $payloadDir $e) -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $payloadDir -Recurse -Include "*.flag", "*.log", "*.bak" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $files = @(Get-ChildItem $payloadDir -Recurse -File)
    Write-Host ("      {0} 個のファイル" -f $files.Count)

    # ---------- 2. ZIP にまとめる ----------
    Write-Host "[2/4] ひとまとめにしています..." -ForegroundColor Cyan
    $zip = Join-Path $stage "payload.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $zip)
    if ($ZipOnly) {
        Copy-Item -LiteralPath $zip -Destination $OutFile -Force
        Write-Host ('作成しました: '+$OutFile) -ForegroundColor Green
        $buildOk=$true
        return
    }
    Copy-Item (Join-Path $here "install.cmd") $stage -Force
    Copy-Item (Join-Path $here "install.ps1") $stage -Force

    # ---------- 3. Windows 標準の .NET コンパイラで自己展開 EXE を作る ----------
    Write-Host '[3/4] 配置用 EXE を作っています...' -ForegroundColor Cyan
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework のコンパイラがありません。-ZipOnly で配布 ZIP を作成してください。' }
    $built=Join-Path $stage 'EdgeBox-Setup.exe'
    $compilerArgs=@('/nologo','/target:exe',('/out:'+$built),('/win32manifest:'+(Join-Path $here 'bootstrap.manifest')),('/resource:'+$zip+',Payload'),('/resource:'+(Join-Path $here 'install.ps1')+',Installer'),(Join-Path $here 'bootstrap.cs'))
    $compilerLog=(& $compiler @compilerArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $built)) { throw ('EXE の作成に失敗しました: '+$compilerLog) }
    Copy-Item -LiteralPath $built -Destination $OutFile -Force
    $sizeMB = [Math]::Round((Get-Item $OutFile).Length / 1MB, 1)
    Write-Host ("[4/4] できました: {0} ({1} MB)" -f $OutFile, $sizeMB) -ForegroundColor Green
    $buildOk=$true
}
finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $target=[IO.Path]::GetFullPath($stage)
    if (-not $buildOk) { Write-Host ('作成失敗の調査用ファイル: '+$target) -ForegroundColor Yellow }
    elseif ($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $target -Leaf) -like 'EdgeBoxBuild_*') {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}
