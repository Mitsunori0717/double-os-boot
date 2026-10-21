$UiBg      = [System.Drawing.Color]::FromArgb(97, 96, 97)     # 背景 #616061
$UiBg2     = [System.Drawing.Color]::FromArgb(117, 116, 117)  # 操作バー #757475 (『CPU割り当て』の操作バーと同じ)
$UiPanel   = [System.Drawing.Color]::FromArgb(117, 116, 117)  # カード #757475
$UiControl = [System.Drawing.Color]::FromArgb(94, 93, 94)     # ボタン・入力欄
$UiHover   = [System.Drawing.Color]::FromArgb(104, 103, 104)
$UiDown    = [System.Drawing.Color]::FromArgb(85, 84, 85)
$UiBorder  = [System.Drawing.Color]::FromArgb(142, 141, 142)  # 境界線
$UiStrong  = [System.Drawing.Color]::FromArgb(181, 180, 181)
$UiText    = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 文字 (灰色の上で読めるよう白)
$UiSub     = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 補助の文字 (#757475 の上で読めるのは白だけのため白)
$UiSilver  = [System.Drawing.Color]::FromArgb(242, 242, 242)  # フォーカス
$UiFont    = New-Object System.Drawing.Font("Meiryo UI", 9)
$UiBold    = New-Object System.Drawing.Font("Meiryo UI", 9.75, [System.Drawing.FontStyle]::Bold)

function Get-AppIcon([string]$Style) {
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        # アイコンは他のアイコンと同じ濃い色の本体 (画面の配色とは別)
        $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 24, 32))
        $edge = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(53, 67, 82))
        $win  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(86, 180, 255))
        $vm   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(108, 200, 81))   # Edge Box = 緑
        $g.FillRectangle($body, 2, 2, 28, 28)
        $g.DrawRectangle($edge, 2, 2, 27, 27)
        switch ($Style) {
            "monitor" {
                $g.FillRectangle($win, 8, 17, 5, 7); $g.FillRectangle($vm, 14, 10, 5, 14); $g.FillRectangle($win, 20, 19, 5, 5)
            }
            "settings" {
                $g.FillRectangle($win, 8, 9, 16, 4); $g.FillRectangle($vm, 8, 16, 16, 4); $g.FillRectangle($win, 8, 23, 10, 3)
            }
            default {
                $g.FillRectangle($win, 8, 8, 6, 16); $g.FillRectangle($vm, 18, 8, 6, 16)
            }
        }
        $g.Dispose()
        $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        return $ico
    } catch { return $null }
}

# タイトルバーも背景の色にそろえる (Windows 10 2004 以降 / 11。使えない環境では標準のまま)
if (-not ("EdgeBoxSettingsUi.Dwm" -as [type])) {
    Add-Type -Namespace EdgeBoxSettingsUi -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
'@ -ErrorAction SilentlyContinue
}

$form = New-Object System.Windows.Forms.Form
$appIcon = Get-AppIcon "settings"
if ($appIcon) { $form.Icon = $appIcon }
$form.Text = "設定"
$form.TopMost = $true          # 全画面表示のブラウザ等に隠れないように
$form.Add_Shown({ $form.Activate() })
$form.ClientSize = New-Object System.Drawing.Size(624, 318)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = $UiBg
$form.ForeColor = $UiText
$form.Font = $UiFont
$form.Add_HandleCreated({
    try {
        $on = 1;  [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$on, 4)
        $cap = 0x00616061; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 35, [ref]$cap, 4)
        $brd = 0x008E8D8E; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 34, [ref]$brd, 4)
        $txt = 0x00FFFFFF; [void][EdgeBoxSettingsUi.Dwm]::DwmSetWindowAttribute($form.Handle, 36, [ref]$txt, 4)
    } catch { }
})

function New-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.ForeColor = $UiText
    return $l
}
function New-Check($text, $x, $y, $w, $checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 26)
    $c.Checked = $checked
    $c.FlatStyle = "Flat"
    $c.FlatAppearance.BorderColor = $UiStrong
    $c.FlatAppearance.CheckedBackColor = $UiControl
    $c.FlatAppearance.MouseOverBackColor = $UiHover
    $c.FlatAppearance.MouseDownBackColor = $UiControl
    $c.BackColor = $UiBg
    $c.ForeColor = $UiText
    $c.Cursor = [System.Windows.Forms.Cursors]::Hand
    # 標準の平らな四角は灰色の上で見えにくいため、四角と文字をここで描き直す (状態と操作は CheckBox のまま)
    $c.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.Clear($s.BackColor)
        $y = [int](($s.Height - 14) / 2)
        $b = New-Object System.Drawing.SolidBrush ($(if ($s.Checked) { $UiSilver } else { $UiControl }))
        $g.FillRectangle($b, 1, $y, 14, 14); $b.Dispose()
        $p = New-Object System.Drawing.Pen ($(if ($s.Checked) { $UiSilver } else { $UiStrong }))
        $g.DrawRectangle($p, 1, $y, 13, 13); $p.Dispose()
        if ($s.Checked) {
            $g.SmoothingMode = "AntiAlias"
            $k = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(28, 28, 28)), 2
            $g.DrawLines($k, [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF(4, ($y + 7))),
                (New-Object System.Drawing.PointF(6.5, ($y + 10))),
                (New-Object System.Drawing.PointF(11.5, ($y + 3.5)))))
            $k.Dispose()
            $g.SmoothingMode = "Default"
        }
        if ($s.Focused) { [System.Windows.Forms.ControlPaint]::DrawFocusRectangle($g, (New-Object System.Drawing.Rectangle(0, ($y - 1), 16, 16))) }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, (New-Object System.Drawing.Rectangle(22, 0, ($s.Width - 22), $s.Height)),
            $s.ForeColor, [System.Windows.Forms.TextFormatFlags]"VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix")
    })
    return $c
}
# 入力欄: 細い枠の中に置く (フォーカス中は枠を明るく)
function New-Field($tb, $x, $y, $w) {
    $frame = New-Object System.Windows.Forms.Panel
    $frame.Location = New-Object System.Drawing.Point($x, $y)
    $frame.Size = New-Object System.Drawing.Size($w, 30)
    $frame.BackColor = $UiBorder
    $frame.Padding = New-Object System.Windows.Forms.Padding(1)
    $inner = New-Object System.Windows.Forms.Panel
    $inner.Dock = "Fill"
    $inner.BackColor = $UiControl
    $inner.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 0)
    $tb.BorderStyle = "None"
    $tb.BackColor = $UiControl
    $tb.ForeColor = $UiText
    $tb.Dock = "Fill"
    $inner.Controls.Add($tb)
    $frame.Controls.Add($inner)
    $tb.Add_Enter({ $this.Parent.Parent.BackColor = $UiSilver })
    $tb.Add_Leave({ $this.Parent.Parent.BackColor = $UiBorder })
    return $frame
}
function New-FlatButton($text, $x, $y, $w, [bool]$Primary = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = "Flat"
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(62, 61, 62) } else { $UiControl })
    $b.ForeColor = $UiText
    $b.FlatAppearance.BorderColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(198, 198, 198) } else { $UiBorder })
    $b.FlatAppearance.MouseOverBackColor = $(if ($Primary) { [System.Drawing.Color]::FromArgb(78, 77, 78) } else { $UiHover })
    $b.FlatAppearance.MouseDownBackColor = $UiDown
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) { $b.Font = New-Object System.Drawing.Font("Meiryo UI", 9, [System.Drawing.FontStyle]::Bold) }
    return $b
}

$alState = Get-AutoLogonState

$cbAuto = New-Check "電源 ON でサインイン画面を省略し、デスクトップまで自動で進む" 18 18 588 $alState.Enabled
$form.Controls.Add($cbAuto)

# 枠付きのパネル (見出しを左上に描く)
$grpAcc = New-Object System.Windows.Forms.Panel
$grpAcc.Location = New-Object System.Drawing.Point(16, 56)
$grpAcc.Size = New-Object System.Drawing.Size(592, 168)
$grpAcc.BackColor = $UiPanel
$grpAcc.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen ($UiBorder)
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, "サインインするアカウント", $UiBold, (New-Object System.Drawing.Point(16, 13)), $UiText)
})
$grpAcc.Controls.Add((New-Label "アカウント名" 16 54))
$tbUser = New-Object System.Windows.Forms.TextBox
$tbUser.Text = $alState.UserName
$grpAcc.Controls.Add((New-Field $tbUser 130 48 444))
$grpAcc.Controls.Add((New-Label "パスワード" 16 92))
$tbPass = New-Object System.Windows.Forms.TextBox
$tbPass.UseSystemPasswordChar = $true
$tbPass.Add_TextChanged({ if ($tbPass.Text) { $cbAuto.Checked = $true } })
$grpAcc.Controls.Add((New-Field $tbPass 130 86 444))
$lblPw = New-Label "※ パスワード欄を空のまま保存すると、今保存されているパスワードをそのまま使います。" 16 124
$lblPw.ForeColor = $UiSub
$grpAcc.Controls.Add($lblPw)
$lblPw2 = New-Label "※ PIN は使えません。Windows のパスワードを入力してください。" 16 143
$lblPw2.ForeColor = $UiSub
$grpAcc.Controls.Add($lblPw2)
$form.Controls.Add($grpAcc)

$lblAl = New-Label "現在: $(if ($alState.Enabled) { '有効' } else { '無効' })  ($($alState.Domain)\$($alState.UserName))" 18 234
$lblAl.ForeColor = $UiSub
$form.Controls.Add($lblAl)

# ------------------------------------------------------------
#  保存 / 閉じる
# ------------------------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = "Bottom"
$footer.Height = 60
$footer.BackColor = $UiBg2
$footer.Add_Paint({ param($s, $e) $p = New-Object System.Drawing.Pen ($UiBorder); $e.Graphics.DrawLine($p, 0, 0, $s.Width, 0); $p.Dispose() })
$btnOK = New-FlatButton "保存" 400 13 100 $true
$btnOK.DialogResult = "OK"
$btnCancel = New-FlatButton "閉じる" 508 13 100
$btnCancel.DialogResult = "Cancel"
$footer.Controls.AddRange(@($btnOK, $btnCancel))
$form.Controls.Add($footer)
$form.AcceptButton = $btnOK
$form.CancelButton = $btnCancel

