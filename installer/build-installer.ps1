<#
.SYNOPSIS
    一式をまとめた EdgeBox-Setup.exe を作ります (Windows 標準の IExpress を使用)。

.DESCRIPTION
    作るもの:
      EdgeBox-Setup.exe … 中身を取り出して導入まで行う 1 つの実行ファイル

    しくみ:
      1. windows-host と windows-cpu-partition を一時フォルダに集める
         (この PC だけの設定や記録は除く)
      2. payload.zip にまとめる (IExpress はフォルダ構造を保持できないため)
      3. payload.zip + install.cmd + install.ps1 を IExpress で 1 つの EXE にする

    IExpress は Windows に標準で入っているため、追加の導入は不要です。

.EXAMPLE
    .\build-installer.cmd            # ダブルクリックでも可
    .\build-installer.ps1 -OutFile "C:\temp\EdgeBox-Setup.exe"
#>
[CmdletBinding()]
param(
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $OutFile) { $OutFile = Join-Path $here "EdgeBox-Setup.exe" }

$stage = Join-Path ([IO.Path]::GetTempPath()) ("EdgeBoxBuild_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$payloadDir = Join-Path $stage "payload"
New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

try {
    # ---------- 1. 必要なファイルを集める ----------
    Write-Host "[1/4] 必要なファイルを集めています..." -ForegroundColor Cyan
    foreach ($d in "windows-host", "windows-cpu-partition") {
        $src = Join-Path $root $d
        if (-not (Test-Path $src)) { throw "$d が見つかりません: $src" }
        Copy-Item $src (Join-Path $payloadDir $d) -Recurse -Force
    }
    $readme = Join-Path $root "README.md"
    if (Test-Path $readme) { Copy-Item $readme $payloadDir -Force }

    # この PC だけの設定・記録は配布物に含めない
    $exclude = @(
        "windows-host\display-config.json", "windows-host\display-log.txt",
        "windows-host\display-error.txt", "windows-host\display-status.txt",
        "windows-host\field-boot-entry.conf", "windows-host\kiosk-login.xml",
        "windows-cpu-partition\cpu-partition.json", "windows-cpu-partition\cpu-apps.json"
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
    Copy-Item (Join-Path $here "install.cmd") $stage -Force
    Copy-Item (Join-Path $here "install.ps1") $stage -Force

    # ---------- 3. IExpress の指示書 ----------
    Write-Host "[3/4] EXE を作っています (少し時間がかかります)..." -ForegroundColor Cyan
    $sed = Join-Path $stage "EdgeBox.sed"
    $lines = @(
        "[Version]", "Class=IEXPRESS", "SEDVersion=3",
        "[Options]",
        "PackagePurpose=InstallApp",
        "ShowInstallProgramWindow=0",
        "HideExtractAnimation=1",
        "UseLongFileName=1",
        "InsideCompressed=0",
        "CAB_FixedSize=0",
        "CAB_ResvCodeSigning=0",
        "RebootMode=N",
        "InstallPrompt=%InstallPrompt%",
        "DisplayLicense=%DisplayLicense%",
        "FinishMessage=%FinishMessage%",
        "TargetName=%TargetName%",
        "FriendlyName=%FriendlyName%",
        "AppLaunched=%AppLaunched%",
        "PostInstallCmd=%PostInstallCmd%",
        "AdminQuietInstCmd=",
        "UserQuietInstCmd=",
        "SourceFiles=SourceFiles",
        "[Strings]",
        "InstallPrompt=",
        "DisplayLicense=",
        "FinishMessage=",
        "TargetName=$OutFile",
        "FriendlyName=EdgeBox セットアップ",
        "AppLaunched=cmd.exe /c install.cmd",
        "PostInstallCmd=<None>",
        'FILE0="payload.zip"',
        'FILE1="install.cmd"',
        'FILE2="install.ps1"',
        "[SourceFiles]",
        "SourceFiles0=$stage",
        "[SourceFiles0]",
        "%FILE0%=",
        "%FILE1%=",
        "%FILE2%="
    )
    # IExpress の指示書は ANSI (日本語 Windows では Shift-JIS) で書く
    [IO.File]::WriteAllLines($sed, $lines, [Text.Encoding]::Default)

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    $p = Start-Process "iexpress.exe" -ArgumentList "/N", "/Q", "`"$sed`"" -Wait -PassThru -NoNewWindow
    if (-not (Test-Path $OutFile)) {
        throw "EXE が作られませんでした (iexpress の終了コード $($p.ExitCode))。"
    }
    $sizeMB = [Math]::Round((Get-Item $OutFile).Length / 1MB, 1)
    Write-Host ("[4/4] できました: {0} ({1} MB)" -f $OutFile, $sizeMB) -ForegroundColor Green
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
