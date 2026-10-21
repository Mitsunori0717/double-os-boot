<#
.SYNOPSIS
    Edge Box のホスト設定画面を、固定のサンプル値でプレビューします。
.DESCRIPTION
    本番スクリプトは読み込みません。保存は画面を閉じるだけです。
    -SmokeTest はウィンドウを表示せず、入力と画面内イベントを検証します。
    views の見た目を編集し、共通の統合ツールで本番ソースへ反映できます。
.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\preview-host.ps1 -Screen Settings
.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\preview-host.ps1 -Screen All -SmokeTest -ScreenshotDirectory .\screenshots
#>
[CmdletBinding()]
param(
    [ValidateSet('Display', 'AutoLogon', 'Settings', 'All')]
    [string]$Screen = 'All',
    [switch]$SmokeTest,
    [string]$ScreenshotDirectory
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows で実行してください。' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'powershell.exe -STA で実行してください。' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Get-PreviewControlCount($control) {
    $count = 1
    foreach ($child in $control.Controls) { $count += Get-PreviewControlCount $child }
    return $count
}

function Invoke-PreviewClick($button) {
    # Invoke the same UI event even when the smoke-test form has never been shown.
    $flags = [Reflection.BindingFlags]'Instance, NonPublic'
    $method = $button.GetType().GetMethod('OnClick', $flags)
    [void]$method.Invoke($button, @([EventArgs]::Empty))
}

function Invoke-HostPreview([string]$Name) {
    . (Join-Path $PSScriptRoot 'mock-provider.ps1')
    $form = $null
    try {
        switch ($Name) {
            'Display' { . (Join-Path $PSScriptRoot 'views\display.view.ps1') }
            'AutoLogon' {
                . (Join-Path $PSScriptRoot 'views\auto-logon-main.view.ps1')
                # The production registry/netplwiz handler is deliberately outside the design files.
                $btnNet.Add_Click({ $btnNet.Text = 'プレビュー: Windows 設定は開きません' })
                . (Join-Path $PSScriptRoot 'views\auto-logon-actions.view.ps1')
            }
            'Settings' { . (Join-Path $PSScriptRoot 'views\settings.view.ps1') }
        }
        if (-not ($form -is [System.Windows.Forms.Form])) { throw "$Name : Form が構築されませんでした。" }
        $form.Text = 'Edge Box UI プレビュー - ' + $form.Text
        $form.TopMost = $false
        $count = Get-PreviewControlCount $form
        if ($count -lt 6) { throw "$Name : コントロールが不足しています ($count)。" }
        if ($ScreenshotDirectory) {
            [void][IO.Directory]::CreateDirectory($ScreenshotDirectory)
            # WinForms omits invisible child controls from DrawToBitmap. Create their
            # handles in a transparent, nonmodal window before rendering the form itself.
            $form.ShowInTaskbar = $false
            $form.Opacity = 0
            $form.Show()
            [System.Windows.Forms.Application]::DoEvents()
            $form.PerformLayout()
            $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            try {
                $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $path = Join-Path ([IO.Path]::GetFullPath($ScreenshotDirectory)) ($Name.ToLowerInvariant() + '.png')
                $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $bitmap.Dispose()
                $form.Hide()
                $form.Opacity = 1
                $form.ShowInTaskbar = $true
            }
        }
        if ($SmokeTest) {
            switch ($Name) {
                'Display' {
                    $cbFit.Checked = $false
                    if (-not $cmbRes.Enabled) { throw '表示設定: 解像度の入力を有効にできません。' }
                    $cbLF.Checked = $false
                    $cbFit.Checked = $true
                    if ($cmbRes.Enabled -or -not $cbLF.Checked) { throw '表示設定: 全画面の連動が動きません。' }
                }
                'AutoLogon' {
                    $cbOn.Checked = $false
                    $tbPass.Text = 'sample-preview-value'
                    if (-not $cbOn.Checked) { throw '自動サインイン: パスワード欄の連動が動きません。' }
                    $tbPass.Clear()
                    Invoke-PreviewClick $btnNet
                    if ($btnNet.Text -notlike 'プレビュー:*') { throw '自動サインイン: 安全なプレビューボタンが動きません。' }
                }
                'Settings' {
                    $cbAuto.Checked = $false
                    $tbPass.Text = 'sample-preview-value'
                    if (-not $cbAuto.Checked) { throw '設定: パスワード欄の連動が動きません。' }
                    $tbPass.Clear()
                }
            }
            if ($btnOK.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) { throw "$Name : 保存ボタンの応答が不正です。" }
            if ($btnCancel.DialogResult -ne [System.Windows.Forms.DialogResult]::Cancel) { throw "$Name : 閉じるボタンの応答が不正です。" }
            Invoke-PreviewClick $btnOK
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
            Invoke-PreviewClick $btnCancel
            [pscustomobject]@{ Screen = $Name; Controls = $count; Result = 'PASS' }
        } else {
            [void]$form.ShowDialog()
        }
    } finally {
        if ($form) { $form.Dispose() }
    }
}

$screens = if ($Screen -eq 'All') { @('Settings', 'Display', 'AutoLogon') } else { @($Screen) }
foreach ($name in $screens) { Invoke-HostPreview $name }
