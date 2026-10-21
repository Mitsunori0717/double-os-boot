#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Gallery', 'Console', 'Monitor', 'Apps', 'Display', 'AutoLogon', 'Settings')]
    [string]$Screen = 'Gallery',
    [switch]$SmokeTest,
    [string]$ScreenshotDirectory = ''
)
$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Start-PreviewScreen([string]$Name, [switch]$WaitForExit, [switch]$Test) {
    $runner = if ($Name -in @('Console', 'Monitor', 'Apps')) { 'cpu\preview-cpu.ps1' } else { 'host\preview-host.ps1' }
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
    $screens = if ($Screen -eq 'Gallery') { @('Console', 'Monitor', 'Apps', 'Display', 'AutoLogon', 'Settings') } else { @($Screen) }
    foreach ($name in $screens) { Start-PreviewScreen $name -WaitForExit -Test; Write-Host "PASS: $name" }
    return
}
if ($Screen -ne 'Gallery') { Start-PreviewScreen $Screen -WaitForExit; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Edge Box — UI デザインプレビュー'
$form.ClientSize = New-Object Drawing.Size(620, 520)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Meiryo UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(244, 246, 248)
$title = New-Object Windows.Forms.Label
$title.Text = 'Edge Box  デザインプレビュー'
$title.Font = New-Object Drawing.Font('Meiryo UI', 17, [Drawing.FontStyle]::Bold)
$title.SetBounds(28, 24, 570, 40)
$form.Controls.Add($title)
$note = New-Object Windows.Forms.Label
$note.Text = 'サンプルデータで画面を確認します。編集したデザインは、各画面を閉じて開き直すと反映されます。'
$note.SetBounds(30, 76, 550, 52)
$form.Controls.Add($note)
$definitions = @(
    @('Console', 'CPU 割り当て', 'Home / Core Split / Settings / Log / System'),
    @('Monitor', 'Edge Box 監視', 'コアの負荷・メモリの表示'),
    @('Apps', 'アプリの割り当て', 'アプリ一覧・コア選択'),
    @('Display', '画面表示の設定', '左右モニター・全画面・コンソール解像度'),
    @('AutoLogon', '自動サインイン', '有効 / 無効・サンプルアカウント'),
    @('Settings', '設定', '設定アイコンから開くサインイン画面')
)
$y = 140
foreach ($definition in $definitions) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $definition[1]
    $button.Tag = $definition[0]
    $button.SetBounds(30, $y, 190, 44)
    $button.Add_Click({ param($sender, $eventArgs) Start-PreviewScreen ([string]$sender.Tag) })
    $label = New-Object Windows.Forms.Label
    $label.Text = $definition[2]
    $label.SetBounds(234, ($y + 11), 360, 30)
    $form.Controls.AddRange(@($button, $label))
    $y += 56
}
[void]$form.ShowDialog()
$form.Dispose()
