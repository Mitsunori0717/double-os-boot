

# --- 普通のアプリらしく見せる: 専用のアイコンと、タスクバーでの独立 ---
# これを入れないと、PowerShell のアイコンで PowerShell と同じ束にまとめられてしまう
if (-not ("Win.AppShell" -as [type])) {
    Add-Type -Namespace Win -Name AppShell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction SilentlyContinue
}
try { [Win.AppShell]::SetCurrentProcessExplicitAppUserModelID("Edge Box.Monitor") | Out-Null } catch { }

$form = New-Object System.Windows.Forms.Form
Initialize-UiForm $form
$appIcon = Get-UiAppIcon "monitor"
if ($appIcon) { $form.Icon = $appIcon }
$form.Text = "$VMName 監視 — 各コアの負荷とメモリ"
$form.ClientSize = New-Object System.Drawing.Size(1120, 600)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"   # 大きさは固定
$form.MaximizeBox = $false
$form.MinimizeBox = $true              # 最小化してしまっておける
$form.TopMost = [bool]$TopMost

# 上のバー: 更新間隔・常に手前・状態
$top = New-Object CoreUi.Strip
$top.Line = "Bottom"
$top.Dock = "Top"
$top.Height = 44
$top.Width = $form.ClientSize.Width
$lblIv = New-UiLabel "更新間隔" 14 13 0 "sub"
$cmbIv = New-Object CoreUi.DarkComboBox
$cmbIv.DropDownStyle = "DropDownList"
[void]$cmbIv.Items.AddRange(@("1 秒", "2 秒", "5 秒"))
$cmbIv.Location = New-Object System.Drawing.Point(78, 8)
$cmbIv.Size = New-Object System.Drawing.Size(80, 28)
$cmbIv.SelectedIndex = $(if ($IntervalMs -ge 5000) { 2 } elseif ($IntervalMs -ge 2000) { 1 } else { 0 })
$chkTop = New-Object CoreUi.ToggleSwitch
$chkTop.Text = "常に手前に表示"
$chkTop.Location = New-Object System.Drawing.Point(176, 9)
$chkTop.Size = New-Object System.Drawing.Size(160, 26)
$chkTop.Checked = [bool]$TopMost
$lblStatus = New-UiLabel "" 352 13 754 "small"
$lblStatus.Anchor = "Top,Left,Right"
$top.Controls.AddRange(@($lblIv, $cmbIv, $chkTop, $lblStatus))

# 描画面 (ちらつき防止のため二重バッファ)
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.BackColor = [CoreUi.Theme]::Bg
try {
    $prop = $panel.GetType().GetProperty("DoubleBuffered",
        ([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic))
    $prop.SetValue($panel, $true, $null)
} catch { }

$form.Controls.Add($panel)   # Fill を先に、Top を後に追加すると Top の分だけ Fill が避ける
$form.Controls.Add($top)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(500, $IntervalMs)

$panel.Add_Paint({
    param($s, $e)
    try { Draw-All $e.Graphics $s.ClientSize.Width $s.ClientSize.Height } catch { }
})
$panel.Add_Resize({ $panel.Invalidate() })

