#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRoot = '',
    [string]$ScreenshotDirectory = ''
)
$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
# スクリプトを実行せず、配布フォルダ全体の PowerShell 構文を先に検査。
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter '*.ps1' -File) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "PowerShell 構文エラー: $($file.Name) : $($errors[0].Message)" }
}
Write-Host 'PASS: PowerShell syntax'
$previewArguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'preview.ps1'), '-SmokeTest')
if ($ScreenshotDirectory) { $previewArguments += @('-ScreenshotDirectory', $ScreenshotDirectory) }
& $powershell @previewArguments
if ($LASTEXITCODE -ne 0) { throw '設定画面プレビューの検証に失敗しました。' }
foreach ($screen in @('CoreChooser', 'Processes', 'InstalledApps')) {
    $arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'cpu\preview-cpu.ps1'), '-Screen', $screen, '-SmokeTest')
    if ($ScreenshotDirectory) { $arguments += @('-ScreenshotDirectory', $ScreenshotDirectory) }
    & $powershell @arguments
    if ($LASTEXITCODE -ne 0) { throw "アプリ選択画面の検証に失敗しました: $screen" }
}
if (-not $SourceRoot) {
    $parent = Split-Path $PSScriptRoot -Parent
    if (Test-Path -LiteralPath (Join-Path $parent 'windows-cpu-partition\cpu-console.ps1')) { $SourceRoot = $parent }
}
if ($SourceRoot) {
    & (Join-Path $PSScriptRoot 'tests\integration-tests.ps1') -SourceRoot $SourceRoot
} else {
    Write-Host '本体ソースなし: 取り込み試験は省略しました。-SourceRoot <clone> で追加できます。'
}
Write-Host 'PASS: Edge Box UI preview verification'
