#requires -Version 5.1
<#
.SYNOPSIS
    Edge Box の UI プレビューを開きます (start.cmd から起動)。
.DESCRIPTION
    全画面を 1 つのウィンドウ (viewer.ps1) で表示し、左の一覧ですぐに切り替えます。
    このスクリプトはプレビューのファイルを見張り、保存されたら同じ画面と位置で開き直します。
    -SmokeTest は画面ごとの検証と、まとめ表示の検証を行います (verify.ps1 から使用)。
.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\preview.ps1 -Screen Monitor
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Console', 'Monitor', 'Apps', 'CoreChooser', 'Processes', 'InstalledApps', 'Display', 'AutoLogon', 'Settings')]
    [string]$Screen = 'All',
    [switch]$SmokeTest,
    [string]$ScreenshotDirectory = ''
)
$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Start-PreviewScreen([string]$Name, [switch]$WaitForExit, [switch]$Test) {
    $runner = if ($Name -in @('Display', 'AutoLogon', 'Settings')) { 'host\preview-host.ps1' } else { 'cpu\preview-cpu.ps1' }
    $path = Join-Path $PSScriptRoot $runner
    $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Screen {1}' -f $path, $Name
    if ($Test) { $arguments += ' -SmokeTest' }
    if ($ScreenshotDirectory) { $arguments += ' -ScreenshotDirectory "{0}"' -f ([IO.Path]::GetFullPath($ScreenshotDirectory)) }
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if ($WaitForExit) {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "プレビューの検証に失敗しました: $Name (exit $($process.ExitCode))" }
    }
}

if ($SmokeTest) {
    $screens = if ($Screen -eq 'All') { @('Console', 'Monitor', 'Apps', 'Display', 'AutoLogon', 'Settings') } else { @($Screen) }
    foreach ($name in $screens) { Start-PreviewScreen $name -WaitForExit -Test; Write-Host "PASS: $name" }
    if ($Screen -eq 'All') {
        # まとめ表示: 全画面を 1 つのウィンドウへ順に埋め込み、切り替えでエラーが出ないことを確認
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -SelfTest' -f (Join-Path $PSScriptRoot 'viewer.ps1')
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "まとめ表示の検証に失敗しました (exit $($process.ExitCode))" }
        Write-Host 'PASS: Viewer'
    }
    return
}

# プレビューのソースが保存されたかを、名前・大きさ・更新日時で判定する (生成物のフォルダは除く)
function Get-PreviewStamp {
    $root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $files = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.ps1', '.json') -and
        $_.FullName.Substring($root.Length) -notmatch '^(backups|screenshots|output|logs)\\'
    }
    return (@($files | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join "`n")
}

$viewer = Join-Path $PSScriptRoot 'viewer.ps1'
$state = Join-Path ([IO.Path]::GetTempPath()) ('EdgeBox-UI-Preview-' + $PID + '.json')
$start = if ($Screen -eq 'All') { 'Console' } else { $Screen }
Write-Host 'Edge Box UI プレビュー'
Write-Host '  左の一覧をクリック (または Ctrl+PgUp / PgDn) で画面を切り替えます。'
Write-Host '  プレビューのファイルを保存すると、同じ画面のまま自動で開き直します。'
Write-Host '  この黒いウィンドウを閉じると、プレビューも終了します。'
try {
    while ($true) {
        $stamp = Get-PreviewStamp
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Start {1} -StateFile "{2}"' -f $viewer, $start, $state
        $process = Start-Process -FilePath $powershell -ArgumentList $arguments -NoNewWindow -PassThru
        $null = $process.Handle   # Windows PowerShell 5.1 で終了後に ExitCode を読むため
        $changed = $false
        while (-not $process.WaitForExit(700)) {
            if ((Get-PreviewStamp) -ne $stamp) {
                Start-Sleep -Milliseconds 600   # 保存の途中で読み込まないよう、書き込みが終わるのを待つ
                Write-Host '変更を検出しました。開き直します...'
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $process.WaitForExit()
                $changed = $true
                break
            }
        }
        if ($changed) { continue }
        if ($process.ExitCode -eq 0) { break }
        if ($process.ExitCode -eq 10) { Write-Host '開き直しています...'; continue }
        Write-Host ''
        Write-Host "プレビューを表示できませんでした (exit $($process.ExitCode))。上のメッセージを確認してください。" -ForegroundColor Yellow
        Write-Host 'ファイルを直して保存すると、自動で開き直します。' -ForegroundColor Yellow
        while ((Get-PreviewStamp) -eq $stamp) { Start-Sleep -Milliseconds 700 }
        Start-Sleep -Milliseconds 600
    }
} finally {
    Remove-Item -LiteralPath $state -ErrorAction SilentlyContinue
}
