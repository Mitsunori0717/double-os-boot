#requires -Version 5.1
<#
.SYNOPSIS
    Edge Box の全画面を 1 つのウィンドウで切り替えて表示するプレビューです。
.DESCRIPTION
    通常は start.cmd (preview.ps1) から起動します。左の一覧で画面を選ぶと、同じウィンドウの
    中ですぐに切り替わります。各画面は cpu/preview-cpu.ps1 と host/preview-host.ps1 の
    サンプル供給コードで組み立て、本体のスクリプトは読み込みません。
    ファイル保存時の開き直しは preview.ps1 が担当し、このプロセスを起動し直します。
    終了コード: 0 = 閉じた / 10 = 開き直し (F5)。
.EXAMPLE
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\viewer.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [ValidateSet('Console', 'Monitor', 'Apps', 'CoreChooser', 'Processes', 'InstalledApps', 'Display', 'AutoLogon', 'Settings')]
    [string]$Start = 'Console',
    # 表示中の画面とウィンドウ位置を保存し、開き直した時に戻すためのファイル
    [string]$StateFile = '',
    # 画面を描かずに全画面を順に組み立てて埋め込み、エラーが無いことを確かめる
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows で実行してください。' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'powershell.exe -STA で実行してください。' }

$script:ViewerRoot = $PSScriptRoot
$script:ViewerSelfTest = [bool]$SelfTest
$script:ViewerScreens = @(
    [pscustomobject]@{ Key = 'Console'; Title = 'CPU 割り当て'; Note = 'CPU · HOME / SETTING'; Files = 'cpu/console-layout.ps1 · cpu/cpu-ui-theme.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $true }
    [pscustomobject]@{ Key = 'Monitor'; Title = '監視'; Note = 'CPU · 各スレッドの負荷'; Files = 'cpu/monitor-layout.ps1 · cpu/monitor-drawing.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'Apps'; Title = 'アプリの割り当て'; Note = 'CPU · アプリ一覧・優先度'; Files = 'cpu/apps-layout.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'CoreChooser'; Title = 'コアの選択'; Note = 'CPU · アプリに使うコア'; Files = 'cpu/core-chooser-layout.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'Processes'; Title = '起動中のアプリ'; Note = 'CPU · アプリの追加'; Files = 'cpu/process-picker-layout.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'InstalledApps'; Title = 'インストール済みアプリ'; Note = 'CPU · アプリの追加'; Files = 'cpu/installed-app-picker-layout.ps1'; Runner = 'cpu\preview-cpu.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'Display'; Title = '画面表示の設定'; Note = 'ホスト · 左右モニター・全画面・解像度'; Files = 'host/views/display.view.ps1'; Runner = 'host\preview-host.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'AutoLogon'; Title = '自動サインイン'; Note = 'ホスト · 有効 / 無効・アカウント'; Files = 'host/views/auto-logon-main.view.ps1 · auto-logon-actions.view.ps1'; Runner = 'host\preview-host.ps1'; Fill = $false }
    [pscustomobject]@{ Key = 'Settings'; Title = '設定'; Note = 'ホスト · 設定アイコンから開く画面'; Files = 'host/views/settings.view.ps1'; Runner = 'host\preview-host.ps1'; Fill = $false }
)
$script:ViewerNext = $null
$script:ViewerCurrent = $null
$script:ViewerQuit = $false
$script:ViewerExitCode = 0
$script:ViewerEmbedNext = $false
$script:ViewerEmbedded = $null
$script:ViewerShownCount = 0
$script:ViewerSyncing = $false

# プレビュー用ウィンドウの枠の色。製品の配色と区別できるよう、暗い無彩色にする。
function New-ViewerColor([int]$Rgb) { return [System.Drawing.Color]::FromArgb(($Rgb -shr 16) -band 255, ($Rgb -shr 8) -band 255, $Rgb -band 255) }

function Get-ViewerIndex([string]$Key) {
    for ($i = 0; $i -lt $script:ViewerScreens.Count; $i++) { if ($script:ViewerScreens[$i].Key -eq $Key) { return $i } }
    return -1
}

function Request-ViewerScreen([string]$Key) {
    if ($Key -and $Key -ne $script:ViewerCurrent) { $script:ViewerNext = $Key }
}

function Request-ViewerStep([int]$Delta) {
    $count = $script:ViewerScreens.Count
    $i = ((Get-ViewerIndex $script:ViewerCurrent) + $Delta + $count) % $count
    Request-ViewerScreen $script:ViewerScreens[$i].Key
}

function Set-ViewerStatus([string]$Text, [switch]$Problem) {
    $script:ViewerStatus.Text = $Text
    $script:ViewerStatus.ForeColor = if ($Problem) { $script:VwError } else { $script:VwSub }
}

function Save-ViewerState {
    if (-not $StateFile -or $script:ViewerSelfTest) { return }
    $f = $script:ViewerForm
    $b = if ($f.WindowState -eq 'Normal') { $f.Bounds } else { $f.RestoreBounds }
    $state = [ordered]@{ Screen = $script:ViewerCurrent; X = $b.X; Y = $b.Y; Width = $b.Width; Height = $b.Height; Maximized = ($f.WindowState -eq 'Maximized') }
    try { [IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Read-ViewerState {
    if (-not $StateFile -or -not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Update-ViewerStage {
    $w = $script:ViewerEmbedded
    if (-not $w -or $w.IsDisposed) { return }
    $stage = $script:ViewerStage
    $area = $stage.ClientSize
    $scroll = $stage.AutoScrollPosition
    if ($script:ViewerFill) {
        # 本体のメイン画面は、ウィンドウいっぱいに広げてリサイズ時の見え方も確認できるようにする
        $min = $w.MinimumSize
        $w.Size = New-Object System.Drawing.Size([Math]::Max($area.Width, $min.Width), [Math]::Max($area.Height, $min.Height))
        $w.Location = $scroll
    } else {
        $size = $w.Size
        $x = [Math]::Max(24, [int](($area.Width - $size.Width) / 2))
        $y = [Math]::Max(24, [int](($area.Height - $size.Height) / 2))
        $w.Location = New-Object System.Drawing.Point(($x + $scroll.X), ($y + $scroll.Y))
    }
}

function Show-ViewerErrors {
    if (-not $script:PreviewErrors -or -not $script:PreviewErrors.Count) { return }
    $err = $script:PreviewErrors[0]
    $script:PreviewErrors.Clear()
    if ($script:ViewerSelfTest) { throw $err }
    Set-ViewerStatus ('操作中にエラー: ' + $err.Message) -Problem
}

# harness の Show-PreviewWindow / Invoke-HostPreview から呼ばれる。ShowDialog の代わりに
# ステージへ埋め込み、別の画面が選ばれるまでこの中でメッセージを処理する。呼び出し元の
# 関数スコープが生きたままなので、デザインファイルのイベント処理は単独表示と同じに動く。
function Invoke-ViewerEmbed($Window) {
    $stage = $script:ViewerStage
    $client = $Window.ClientSize
    $Window.TopLevel = $false
    $Window.TopMost = $false
    $Window.FormBorderStyle = 'None'
    $Window.Size = $client
    # 指定の無い色とフォントは親から引き継がれるため、単独表示と同じ値に固定してから埋め込む
    $Window.ForeColor = $Window.ForeColor
    $Window.BackColor = $Window.BackColor
    $Window.Font = $Window.Font
    $stage.AutoScrollMargin = if ($script:ViewerFill) { New-Object System.Drawing.Size(0, 0) } else { New-Object System.Drawing.Size(24, 24) }
    $stage.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    $stage.Controls.Add($Window)
    $script:ViewerEmbedded = $Window
    Update-ViewerStage
    $Window.Show()
    $script:ViewerShownCount++
    $results = @{ OK = 'OK・保存'; Cancel = 'キャンセル・閉じる'; Yes = 'はい'; No = 'いいえ'; Abort = '中止'; Retry = '再試行'; Ignore = '無視' }
    $ticks = 0
    try {
        while (-not $script:ViewerNext -and -not $script:ViewerQuit) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:ViewerQuit) { break }
            if ($Window.IsDisposed) {
                # 画面側が自分を閉じた (一覧のダブルクリックなど)。同じ画面を最初から表示し直す。
                Set-ViewerStatus '画面が閉じる操作をしたため、最初の状態から表示し直しました。'
                $script:ViewerNext = $script:ViewerCurrent
                break
            }
            if ($Window.DialogResult -ne [System.Windows.Forms.DialogResult]::None) {
                Set-ViewerStatus ('「' + $results[[string]$Window.DialogResult] + '」のボタンを押しました。プレビューのため保存や画面の終了はしません。')
                $Window.DialogResult = [System.Windows.Forms.DialogResult]::None
            }
            Show-ViewerErrors
            if ($script:ViewerSelfTest -and ++$ticks -ge 6) {
                if ($Window.Parent -ne $stage) { throw "$($script:ViewerCurrent) : 画面をプレビューに埋め込めませんでした。" }
                Write-Host "PASS: viewer $($script:ViewerCurrent)"
                $i = Get-ViewerIndex $script:ViewerCurrent
                if ($i -ge $script:ViewerScreens.Count - 1) { $script:ViewerQuit = $true } else { $script:ViewerNext = $script:ViewerScreens[$i + 1].Key }
            }
            [System.Threading.Thread]::Sleep(10)
        }
    } finally {
        $script:ViewerEmbedded = $null
        if (-not $Window.IsDisposed) { $Window.Hide(); $stage.Controls.Remove($Window) }
    }
    return [System.Windows.Forms.DialogResult]::Cancel
}

function Show-ViewerProblem([string]$Text) {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.SetBounds(32, 32, [Math]::Max(400, $script:ViewerStage.ClientSize.Width - 64), [Math]::Max(200, $script:ViewerStage.ClientSize.Height - 64))
    $label.Anchor = 'Top, Left, Right, Bottom'
    $label.ForeColor = $script:VwError
    $label.Font = New-Object System.Drawing.Font('Meiryo UI', 10.5)
    $label.Text = $Text
    $script:ViewerStage.Controls.Add($label)
}

function Show-ViewerScreen([string]$Key) {
    $def = $script:ViewerScreens[(Get-ViewerIndex $Key)]
    $script:ViewerCurrent = $Key
    $script:ViewerFill = [bool]$def.Fill
    $script:ViewerSyncing = $true
    try { $script:ViewerList.SelectedIndex = Get-ViewerIndex $Key } finally { $script:ViewerSyncing = $false }
    $script:ViewerTitle.Text = $def.Title
    $script:ViewerFiles.Text = '編集するファイル: ' + $def.Files
    Save-ViewerState
    foreach ($old in @($script:ViewerStage.Controls)) { $script:ViewerStage.Controls.Remove($old); $old.Dispose() }
    $script:ViewerStage.Refresh()
    $before = $script:ViewerShownCount
    $script:ViewerEmbedNext = $true
    try {
        switch ($Key) {
            'Console' { Show-PreviewConsole }
            'Monitor' { Show-PreviewMonitor }
            'Apps' { Show-AppsDialog }
            'CoreChooser' { [void](Show-CoreChooser @(0..7) 'コアの選択 - サンプル ブラウザー' @(20..27)) }
            'Processes' { [void](Show-ProcessPicker) }
            'InstalledApps' { [void](Show-InstalledAppPicker) }
            default { Invoke-HostPreview $Key }
        }
    } catch {
        if ($script:ViewerSelfTest) { throw }
        $position = if ($_.InvocationInfo) { $_.InvocationInfo.PositionMessage } else { '' }
        Show-ViewerProblem ("この画面を表示できませんでした。`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" + $position + "`r`n`r`nファイルを直して保存すると、自動で開き直します。")
        Set-ViewerStatus ($def.Title + ' を表示できませんでした。') -Problem
    } finally {
        $script:ViewerEmbedNext = $false
    }
    if ($script:ViewerSelfTest -and $script:ViewerShownCount -eq $before) { throw "$Key : 画面が表示されませんでした。" }
}

function New-ViewerWindow {
    $script:VwChrome = New-ViewerColor 0x262626
    $script:VwSide = New-ViewerColor 0x2E2E2E
    $script:VwSelect = New-ViewerColor 0x454545
    $script:VwStage = New-ViewerColor 0x1A1A1A
    $script:VwText = New-ViewerColor 0xEDEDED
    $script:VwSub = New-ViewerColor 0xB4B4B4
    $script:VwAccent = New-ViewerColor 0x56B4FF
    $script:VwError = New-ViewerColor 0xFF9A9A

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Edge Box UI プレビュー'
    $f.StartPosition = 'Manual'
    $f.KeyPreview = $true
    $f.BackColor = $script:VwChrome
    $f.ForeColor = $script:VwText
    $f.Font = New-Object System.Drawing.Font('Meiryo UI', 9.75)
    $f.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $script:ViewerForm = $f

    $stage = New-Object System.Windows.Forms.Panel
    $stage.Dock = 'Fill'
    $stage.AutoScroll = $true
    $stage.BackColor = $script:VwStage
    $stage.Add_Resize({ Update-ViewerStage })
    $script:ViewerStage = $stage

    $side = New-Object System.Windows.Forms.Panel
    $side.Dock = 'Left'
    $side.Width = 250
    $side.BackColor = $script:VwSide
    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = 'Fill'
    $list.BorderStyle = 'None'
    $list.IntegralHeight = $false
    $list.DrawMode = 'OwnerDrawFixed'
    $list.ItemHeight = 50
    $list.BackColor = $script:VwSide
    $list.ForeColor = $script:VwText
    foreach ($s in $script:ViewerScreens) { [void]$list.Items.Add($s.Title) }
    $script:VwItemFont = New-Object System.Drawing.Font('Meiryo UI', 10, [System.Drawing.FontStyle]::Bold)
    $script:VwNoteFont = New-Object System.Drawing.Font('Meiryo UI', 8.25)
    $list.Add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $item = $script:ViewerScreens[$e.Index]
        $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $brush = New-Object System.Drawing.SolidBrush($(if ($selected) { $script:VwSelect } else { $script:VwSide }))
        $accent = New-Object System.Drawing.SolidBrush($script:VwAccent)
        try {
            $e.Graphics.FillRectangle($brush, $e.Bounds)
            if ($selected) { $e.Graphics.FillRectangle($accent, $e.Bounds.X, ($e.Bounds.Y + 8), 3, ($e.Bounds.Height - 16)) }
        } finally { $brush.Dispose(); $accent.Dispose() }
        $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPrefix, SingleLine'
        $w = $e.Bounds.Width - 28
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $item.Title, $script:VwItemFont, (New-Object System.Drawing.Rectangle(($e.Bounds.X + 18), ($e.Bounds.Y + 5), $w, 22)), $script:VwText, $flags)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $item.Note, $script:VwNoteFont, (New-Object System.Drawing.Rectangle(($e.Bounds.X + 18), ($e.Bounds.Y + 26), $w, 18)), $script:VwSub, $flags)
    })
    $list.Add_SelectedIndexChanged({
        if ($script:ViewerSyncing -or $script:ViewerList.SelectedIndex -lt 0) { return }
        Request-ViewerScreen $script:ViewerScreens[$script:ViewerList.SelectedIndex].Key
    })
    $script:ViewerList = $list

    $buttons = New-Object System.Windows.Forms.Panel
    $buttons.Dock = 'Bottom'
    $buttons.Height = 96
    $btnWindow = New-Object System.Windows.Forms.Button
    $btnWindow.Text = '別ウィンドウで開く'
    $btnWindow.SetBounds(16, 10, 218, 34)
    $btnReload = New-Object System.Windows.Forms.Button
    $btnReload.Text = '開き直す (F5)'
    $btnReload.SetBounds(16, 50, 218, 34)
    foreach ($b in @($btnWindow, $btnReload)) {
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderColor = $script:VwSelect
        $b.BackColor = $script:VwChrome
        $b.ForeColor = $script:VwText
        $b.TabStop = $false
    }
    $script:ViewerTip = New-Object System.Windows.Forms.ToolTip
    $script:ViewerTip.SetToolTip($btnWindow, 'タイトルバーや実際の大きさを確認するため、選んでいる画面を単独のウィンドウで開きます。')
    $btnWindow.Add_Click({
        $def = $script:ViewerScreens[(Get-ViewerIndex $script:ViewerCurrent)]
        $runner = Join-Path $script:ViewerRoot $def.Runner
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -Screen {1}' -f $runner, $def.Key
        [void](Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru)
        Set-ViewerStatus ($def.Title + ' を別ウィンドウで開いています...')
    })
    $btnReload.Add_Click({ $script:ViewerExitCode = 10; $script:ViewerQuit = $true })
    $buttons.Controls.AddRange(@($btnWindow, $btnReload))
    $side.Controls.Add($list)
    $side.Controls.Add($buttons)

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 60
    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(18, 7)
    $title.Font = New-Object System.Drawing.Font('Meiryo UI', 13, [System.Drawing.FontStyle]::Bold)
    $files = New-Object System.Windows.Forms.Label
    $files.AutoSize = $true
    $files.Location = New-Object System.Drawing.Point(20, 36)
    $files.ForeColor = $script:VwSub
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true
    $hint.ForeColor = $script:VwSub
    $hint.Text = "Ctrl+PgUp / PgDn: 前後の画面   F5: 開き直す"
    $hint.Anchor = 'Top, Right'
    $top.Controls.AddRange(@($title, $files, $hint))
    $top.Add_Resize({ $script:ViewerHint.Location = New-Object System.Drawing.Point(($this.ClientSize.Width - $script:ViewerHint.Width - 18), 12) })
    $script:ViewerTitle = $title
    $script:ViewerFiles = $files
    $script:ViewerHint = $hint

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'
    $status.Height = 28
    $status.Padding = New-Object System.Windows.Forms.Padding(18, 0, 18, 0)
    $status.TextAlign = 'MiddleLeft'
    $status.AutoEllipsis = $true
    $script:ViewerStatus = $status
    $script:ViewerStatusDefault = 'サンプルデータで表示しています (実機の設定は変更されません)。ファイルを保存すると自動で開き直します。'

    # Dock は後から追加したものが先に配置される: 上下の帯 → 左の一覧 → 残りがステージ
    $f.Controls.Add($stage)
    $f.Controls.Add($side)
    $f.Controls.Add($status)
    $f.Controls.Add($top)
    Set-ViewerStatus $script:ViewerStatusDefault

    $f.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'F5') { $script:ViewerExitCode = 10; $script:ViewerQuit = $true; $e.Handled = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'Next') { Request-ViewerStep 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'PageUp') { Request-ViewerStep -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
    })
    $f.Add_ResizeEnd({ Save-ViewerState })
    $f.Add_SizeChanged({
        if ($script:ViewerLastState -ne $this.WindowState) { $script:ViewerLastState = $this.WindowState; Save-ViewerState }
    })
    $f.Add_FormClosing({ Save-ViewerState; $script:ViewerQuit = $true })
}

function Start-ViewerLoop {
    New-ViewerWindow
    $f = $script:ViewerForm
    $first = $Start
    $saved = Read-ViewerState
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Bounds = New-Object System.Drawing.Rectangle(($area.X + 40), ($area.Y + 30), [Math]::Min(1560, $area.Width - 80), [Math]::Min(940, $area.Height - 60))
    $maximize = $true
    if ($saved) {
        if ((Get-ViewerIndex ([string]$saved.Screen)) -ge 0) { $first = [string]$saved.Screen }
        $bounds = New-Object System.Drawing.Rectangle([int]$saved.X, [int]$saved.Y, [int]$saved.Width, [int]$saved.Height)
        $visible = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($bounds) }).Count -gt 0
        if ($visible -and $bounds.Width -ge 600 -and $bounds.Height -ge 400) { $f.Bounds = $bounds }
        $maximize = [bool]$saved.Maximized
    }
    if ($script:ViewerSelfTest) {
        $first = $script:ViewerScreens[0].Key
        $maximize = $false
        $f.Location = New-Object System.Drawing.Point(-30000, -30000)
        $f.ShowInTaskbar = $false
    }
    if ($maximize) { $f.WindowState = 'Maximized' }
    $script:ViewerLastState = $f.WindowState
    $f.Show()
    $script:ViewerNext = $first
    try {
        while (-not $script:ViewerQuit) {
            if ($script:ViewerNext) {
                $key = $script:ViewerNext
                $script:ViewerNext = $null
                if ($key -ne $script:ViewerCurrent) { Set-ViewerStatus $script:ViewerStatusDefault }
                Show-ViewerScreen $key
                continue
            }
            # 画面を表示できなかった時は、次の操作を待つ
            [System.Windows.Forms.Application]::DoEvents()
            Show-ViewerErrors
            [System.Threading.Thread]::Sleep(10)
        }
    } finally {
        $f.Dispose()
    }
}

# 2 つの harness は同じ名前の引数 (-Screen, -SmokeTest など) を持つ。それぞれ別の関数スコープで
# 読み込み、引数の変数が互いを上書きしないようにする。定義された関数とサンプルは、
# この下から呼ぶ処理 (Start-ViewerLoop) からそのまま参照できる。
function Enter-CpuHarness {
    . (Join-Path $script:ViewerRoot 'cpu\preview-cpu.ps1') -LoadOnly
    Enter-HostHarness
}
function Enter-HostHarness {
    . (Join-Path $script:ViewerRoot 'host\preview-host.ps1') -LoadOnly
    Start-ViewerLoop
}

Enter-CpuHarness
if ($script:ViewerSelfTest) { Write-Host "PASS: viewer ($($script:ViewerScreens.Count) screens)" }
exit $script:ViewerExitCode
