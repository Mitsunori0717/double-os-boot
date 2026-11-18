<#
.SYNOPSIS
    一式をまとめた EdgeBox-Setup.exe を作ります (Windows 標準の .NET Framework を使用)。

.DESCRIPTION
    作るもの:
      EdgeBox-Setup.exe … 中身を取り出して導入まで行う 1 つの実行ファイル

    しくみ:
      1. windows-host、windows-cpu-partition、setup、storage-recovery とルートの入口を集める
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
Import-Module (Join-Path $here 'package-safety.psm1') -Force
if (-not $OutFile) { $OutFile = Join-Path $here $(if ($ZipOnly) {'EdgeBox-Setup.zip'} else {'EdgeBox-Setup.exe'}) }
$OutFile = Assert-EdgeBoxSafePath $OutFile
if (Test-Path -LiteralPath $OutFile) { throw 'OUTPUT_ALREADY_EXISTS: 別の出力名を指定してください。' }
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutFile))) { throw 'OUTPUT_PARENT_REQUIRED' }
$expectedExtension=if($ZipOnly){'.zip'}else{'.exe'}
if ([IO.Path]::GetExtension($OutFile) -ine $expectedExtension) {throw 'OUTPUT_EXTENSION_MISMATCH'}
$sourceFiles=@(Get-EdgeBoxPackageFileList -Root $root)

$stage = Join-Path ([IO.Path]::GetTempPath()) ("EdgeBoxBuild_" + [Guid]::NewGuid().ToString("N"))
$stage=Assert-EdgeBoxSafePath $stage
$payloadDir = Join-Path $stage "payload"
New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
$buildOk=$false

try {
    # ---------- 1. 必要なファイルを集める ----------
    Write-Host "[1/4] 必要なファイルを集めています..." -ForegroundColor Cyan
    foreach($file in $sourceFiles) {
        $destination=Join-Path $payloadDir $file.RelativePath
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
        Assert-EdgeBoxSafePath $file.FullName|Out-Null
        [IO.File]::Copy($file.FullName,$destination,$false)
    }
    Write-EdgeBoxPayloadManifest -Directory $payloadDir

    $files = @(Get-ChildItem $payloadDir -Recurse -File)
    Write-Host ("      {0} 個のファイル" -f $files.Count)

    # ---------- 2. ZIP にまとめる ----------
    Write-Host "[2/4] ひとまとめにしています..." -ForegroundColor Cyan
    $zip = Join-Path $stage "payload.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $zip)
    if ($ZipOnly) {
        Publish-EdgeBoxArtifact -Source $zip -Destination $OutFile
        Write-Host ('作成しました: '+$OutFile) -ForegroundColor Green
        $buildOk=$true
        return
    }

    # ---------- 3. Windows 標準の .NET コンパイラで自己展開 EXE を作る ----------
    Write-Host '[3/4] 配置用 EXE を作っています...' -ForegroundColor Cyan
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework のコンパイラがありません。-ZipOnly で配布 ZIP を作成してください。' }
    $built=Join-Path $stage 'EdgeBox-Setup.exe'
    foreach($buildInput in @('bootstrap.manifest','bootstrap.cs','install.ps1','package-safety.psm1')) {Assert-EdgeBoxSafePath (Join-Path $here $buildInput)|Out-Null}
    $compilerArgs=@('/nologo','/target:exe',('/out:'+$built),('/win32manifest:'+(Join-Path $here 'bootstrap.manifest')),('/resource:'+$zip+',Payload'),('/resource:'+(Join-Path $here 'install.ps1')+',Installer'),('/resource:'+(Join-Path $here 'package-safety.psm1')+',SafetyModule'),(Join-Path $here 'bootstrap.cs'))
    $compilerLog=(& $compiler @compilerArgs 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $built)) { throw ('EXE の作成に失敗しました: '+$compilerLog) }
    Publish-EdgeBoxArtifact -Source $built -Destination $OutFile
    $sizeMB = [Math]::Round((Get-Item $OutFile).Length / 1MB, 1)
    Write-Host ("[4/4] できました: {0} ({1} MB)" -f $OutFile, $sizeMB) -ForegroundColor Green
    $buildOk=$true
}
finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $target=[IO.Path]::GetFullPath($stage)
    if (-not $buildOk) { Write-Host ('作成失敗の調査用ファイル: '+$target) -ForegroundColor Yellow }
    elseif ($target.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $target -Leaf) -match '^EdgeBoxBuild_[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}
