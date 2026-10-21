
$ColHost  = [CoreUi.Theme]::Win
$ColGuest = [CoreUi.Theme]::Edge
$ColNone  = [CoreUi.Theme]::Faint

# --- 普通のアプリらしく見せる: 専用のアイコンと、タスクバーでの独立 ---
# これを入れないと、PowerShell のアイコンで PowerShell と同じ束にまとめられてしまう
if (-not ("Win.AppShell" -as [type])) {
    Add-Type -Namespace Win -Name AppShell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction SilentlyContinue
}
try { [Win.AppShell]::SetCurrentProcessExplicitAppUserModelID("Edge Box.CpuConsole") | Out-Null } catch { }

$form = New-Object System.Windows.Forms.Form
Initialize-UiForm $form
$appIcon = Get-UiAppIcon "console"
if ($appIcon) { $form.Icon = $appIcon }
$form.Text = "CPU コア割り当て"
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"
$form.MaximizeBox = $true
$form.KeyPreview = $true
# 大きさは画面に合わせる (小さい画面でも操作バーが見切れないよう最小サイズを決めておく)
$wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$form.MinimumSize = New-Object System.Drawing.Size(1120, 720)
$form.ClientSize = New-Object System.Drawing.Size(
    [Math]::Max(1104, [Math]::Min(1280, $wa.Width - 60)),
    [Math]::Max(680, [Math]::Min(820, $wa.Height - 60)))

$script:Tip = [CoreUi.Styler]::CreateToolTip()

function New-Lbl([string]$Text, [int]$X, [int]$Y, [int]$W = 0) {
    return (New-UiLabel $Text $X $Y $W "body")
}

# パネル。中身の位置は幅 1000 を基準に置き、Anchor で実際の幅に合わせて伸び縮みさせる
function New-Card([string]$Title, [string]$Meta = "", [int]$Height = 160) {
    $c = New-Object CoreUi.Card
    $c.Title = $Title
    $c.Meta = $Meta
    $c.Size = New-Object System.Drawing.Size(1000, $Height)
    return $c
}

# Dock = Top は後から追加したものほど上に並ぶため、逆順に追加する (間に $Gap の余白)
function Add-Stack($Parent, [object[]]$Items, [int]$Gap = 14) {
    for ($i = $Items.Count - 1; $i -ge 0; $i--) {
        $c = $Items[$i]
        $c.Dock = "Top"
        $Parent.Controls.Add($c)
        if ($i -gt 0) {
            $sp = New-Object System.Windows.Forms.Panel
            $sp.Height = $Gap
            $sp.Dock = "Top"
            $sp.BackColor = [System.Drawing.Color]::Transparent
            $Parent.Controls.Add($sp)
        }
    }
}

# --- ヘッダー ---
$script:header = New-Object CoreUi.HeaderBar
$script:header.Dock = "Top"
$script:header.Brand = $UiAppName
$script:header.Version = $UiAppVersion
$script:header.Tagline = $UiAppTagline
$script:header.SubTitle = "CPU コア割り当て"

# --- 左メニュー ---
$script:sidebar = New-Object CoreUi.Strip
$script:sidebar.BackColor = [CoreUi.Theme]::Sidebar
$script:sidebar.Line = "Right"
$script:sidebar.Dock = "Left"
$script:sidebar.Width = 220
$script:sidebar.Padding = New-Object System.Windows.Forms.Padding(0, 14, 1, 0)

$script:Pages = [ordered]@{}
$script:NavItems = @{}
$navDefs = @(
    @{ Key = "core";     Text = "Core Split"; Sub = "コアの割り当て";      Glyph = "cores" },
    @{ Key = "settings"; Text = "Settings";   Sub = "対象・メモリ・アプリ"; Glyph = "settings" }
)
$navList = @()
$k = 1
foreach ($nd in $navDefs) {
    $n = New-Object CoreUi.NavItem
    $n.Text = $nd.Text
    $n.SubText = $nd.Sub
    $n.Glyph = $nd.Glyph
    $n.Tag = $nd.Key
    $n.Add_Click({ param($s, $e) Show-Page ([string]$s.Tag) })
    $script:Tip.SetToolTip($n, ("{0} — {1}   (Ctrl+{2})" -f $nd.Text, $nd.Sub, $k))
    $script:NavItems[$nd.Key] = $n
    $navList += $n
    $k++
}
Add-Stack $script:sidebar $navList 2

$navFoot = New-Object System.Windows.Forms.Panel
$navFoot.Dock = "Bottom"
$navFoot.Height = 104
$navFoot.BackColor = [CoreUi.Theme]::Sidebar
$script:btnMon = New-UiButton "リアルタイム監視" 188 "Default" "monitor"
$script:btnMon.Location = New-Object System.Drawing.Point(16, 12)
$script:Tip.SetToolTip($script:btnMon, "各コアの負荷とメモリの使用量を毎秒表示する別ウィンドウ (『Edge Box 監視』) を開きます")
$navFoot.Controls.Add($script:btnMon)
$navHint = New-UiLabel "Ctrl+1 / Ctrl+2 で画面を切り替え" 18 60 188 "small"
$navFoot.Controls.Add($navHint)
$script:sidebar.Controls.Add($navFoot)

# --- 下の操作バー ---
$script:footer = New-Object CoreUi.Strip
$script:footer.Line = "Top"
$script:footer.Dock = "Bottom"
$script:footer.Height = 64
$script:chipVerdict = New-Object CoreUi.StatusChip
$script:chipVerdict.Text = "確認中"
$script:chipChange = New-Object CoreUi.StatusChip
$script:chipChange.Text = "—"
$script:footer.Controls.AddRange(@($script:chipVerdict, $script:chipChange))

# --- 画面の入れ物 ---
$script:content = New-Object System.Windows.Forms.Panel
$script:content.Dock = "Fill"
$script:content.BackColor = [CoreUi.Theme]::Bg

# 後から追加したものほど先に場所を取る: ヘッダー (全幅) → 左メニュー → 操作バー → 画面
$form.Controls.Add($script:content)
$form.Controls.Add($script:footer)
$form.Controls.Add($script:sidebar)
$form.Controls.Add($script:header)

function New-Page([string]$Key, [string]$Title, [string]$Sub) {
    $p = New-Object CoreUi.Backdrop
    $p.Dock = "Fill"
    $p.AutoScroll = $true
    $p.Padding = New-Object System.Windows.Forms.Padding(28, 22, 28, 24)
    $p.Visible = $false
    $h = New-Object CoreUi.PageHeader
    $h.Text = $Title
    $h.SubTitle = $Sub
    $h.Size = New-Object System.Drawing.Size(1000, $(if ($Sub) { 64 } else { 46 }))
    $script:Pages[$Key] = $p
    $script:PageHeads[$Key] = $h
    $script:content.Controls.Add($p)
}
$script:PageHeads = @{}

function Show-Page([string]$Key) {
    if (-not $script:Pages.Contains($Key)) { return }
    $script:CurrentPage = $Key
    $script:Pages[$Key].Visible = $true
    foreach ($k in @($script:Pages.Keys)) {
        if ($k -ne $Key) { $script:Pages[$k].Visible = $false }
        $script:NavItems[$k].Selected = ($k -eq $Key)
    }
    try {
        if ($Key -eq "core") { Update-CoreLayout }
    } catch { }
}

$form.Add_KeyDown({
    param($s, $e)
    if (-not $e.Control -or $e.Alt) { return }
    $keys = @{ "D1" = "core"; "D2" = "settings" }
    $name = [string]$e.KeyCode
    if ($keys.ContainsKey($name)) { Show-Page $keys[$name]; $e.Handled = $true; $e.SuppressKeyPress = $true }
})

# ============================================================
#  Core Split — コアのタイル・検査結果
# ============================================================
New-Page "core" "Core Split" ""
$legend = New-Object CoreUi.Legend
$legend.Location = New-Object System.Drawing.Point((1000 - $legend.Width), 8)
$legend.Anchor = "Top,Right"
$script:PageHeads["core"].Controls.Add($legend)

# --- コアのタイル ---
function New-Tile($Core) {
    $b = New-Object CoreUi.CoreTile
    $b.Size = New-Object System.Drawing.Size(84, 80)
    $b.Tag = $Core.Id
    $b.CoreLabel = $Core.Label
    $b.Kind = $Core.Kind
    $b.Threads = [int[]]@($Core.Lps)
    $b.Add_Click({
        param($s, $e)
        $c = $script:Cores[[int]$s.Tag]
        if ($script:Hybrid -and $c.Kind -eq "P") {
            # P コアは Windows 専用 (Edge Box には割り当てない): Windows 用 ⇔ 未割当
            $c.State = $(if ($c.State -eq "Host") { "None" } else { "Host" })
        } else {
            switch ($c.State) {
                "Host"  { $c.State = "Guest" }
                "Guest" { $c.State = "None" }
                default { $c.State = "Host" }
            }
        }
        Sync-Tile $c
        Update-Validation
    })
    $how = if ($script:Hybrid -and $Core.Kind -eq "P") { "クリック: Windows ⇔ 未割当 (P コアは Windows 専用)" } else { "クリック: Windows → Edge Box → 未割当" }
    $script:Tip.SetToolTip($b, ("{0}  —  CPU {1}`n{2}" -f $Core.Label, (ConvertTo-LpRangeText $Core.Lps), $how))
    return $b
}

function Sync-Tile($Core) {
    $t = $script:Tiles[$Core.Id]
    if (-not $t) { return }
    $lpText = ConvertTo-LpRangeText $Core.Lps
    switch ($Core.State) {
        "Host"  { $t.Side = 1; $side = "Windows" }
        "Guest" { $t.Side = 2; $side = "EdgeBox" }
        default { $t.Side = 0; $side = "未割当" }
    }
    # 文字はタイル自身が描く。Text は読み上げ・ツール用に同じ内容を持たせておく
    $t.Text = "{0}  ({1})`r`nCPU {2}" -f $Core.Label, $side, $lpText
}

function Sync-AllTiles {
    foreach ($c in $script:Cores) { Sync-Tile $c }
}

function New-CoreGroup([string]$Title, [string]$Meta) {
    $g = New-Card $Title $Meta 150
    $script:CoreCards += $g
    return $g
}

# タイルを格子に並べる。P コアと E コアの列をそろえ、狭いときは折り返す
function Update-CoreLayout {
    $cards = @($script:CoreCards)
    if ($cards.Count -eq 0) { return }
    $inner = $cards[0].ClientSize.Width - 36
    if ($inner -lt 100) { return }
    $gap = 6; $minW = 70; $maxW = 116; $tileH = 80
    $maxN = 1
    foreach ($cd in $cards) { $maxN = [Math]::Max($maxN, @($cd.Controls | Where-Object { $_ -is [CoreUi.CoreTile] }).Count) }
    $fit = [Math]::Max(1, [int][Math]::Floor(($inner + $gap) / ($minW + $gap)))
    $cols = [Math]::Min($maxN, $fit)
    if ($cols -lt $maxN) {
        $rows = [int][Math]::Ceiling($maxN / $cols)
        $cols = [int][Math]::Ceiling($maxN / $rows)
    }
    $w = [int][Math]::Min($maxW, [Math]::Floor(($inner - ($cols - 1) * $gap) / $cols))
    foreach ($cd in $cards) {
        $tiles = @($cd.Controls | Where-Object { $_ -is [CoreUi.CoreTile] } | Sort-Object { [int]$_.Tag })
        for ($i = 0; $i -lt $tiles.Count; $i++) {
            $r = [int][Math]::Floor($i / $cols); $c = $i % $cols
            $tiles[$i].SetBounds((18 + $c * ($w + $gap)), ($cd.HeaderHeight + $r * ($tileH + $gap)), $w, $tileH)
        }
        $rowsHere = [Math]::Max(1, [int][Math]::Ceiling($tiles.Count / $cols))
        $hh = $cd.HeaderHeight + $rowsHere * ($tileH + $gap) - $gap + 18
        if ($cd.Height -ne $hh) { $cd.Height = $hh }
    }
}

$script:CoreCards = @()
if ($script:Hybrid) {
    $pCores = @($script:Cores | Where-Object { $_.Kind -eq "P" })
    $eCores = @($script:Cores | Where-Object { $_.Kind -ne "P" })
    $pThreads = [int]((@($pCores | ForEach-Object { $_.Lps.Count }) | Measure-Object -Sum).Sum)
    $eThreads = [int]((@($eCores | ForEach-Object { $_.Lps.Count }) | Measure-Object -Sum).Sum)
    $grpP = New-CoreGroup "P コア (性能重視)" ("{0} コア / {1} スレッド" -f $pCores.Count, $pThreads)
    $grpE = New-CoreGroup "E コア (効率重視)" ("{0} コア / {1} スレッド" -f $eCores.Count, $eThreads)
    foreach ($c in $pCores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpP.Controls.Add($t) }
    foreach ($c in $eCores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpE.Controls.Add($t) }
    $coreGroups = @($grpP, $grpE)
} else {
    $allThreads = Get-LpCount $script:Cores
    $grpA = New-CoreGroup "CPU コア" ("{0} コア / {1} スレッド" -f $script:Cores.Count, $allThreads)
    foreach ($c in $script:Cores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpA.Controls.Add($t) }
    $coreGroups = @($grpA)
}
foreach ($cd in $coreGroups) { $cd.Add_Resize({ try { Update-CoreLayout } catch { } }) }

# --- 検査結果 ---
$grpChk = New-Card "検査結果" "適用できるかを自動で確かめます" 214
# 色付きの文字 (不可・注意) を読みやすくするため、一段濃い下地の上に出す
function New-InsetBox {
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = "Fill"
    $p.BackColor = [CoreUi.Theme]::Inset
    $p.Padding = New-Object System.Windows.Forms.Padding(12, 10, 6, 8)
    return $p
}
$script:rtb = New-Object System.Windows.Forms.RichTextBox
$script:rtb.Dock = "Fill"
$script:rtb.ReadOnly = $true
$script:rtb.BorderStyle = "None"
$script:rtb.BackColor = [CoreUi.Theme]::Inset
$script:rtb.ForeColor = [CoreUi.Theme]::Text
$script:rtb.Font = [CoreUi.Theme]::Ui
$script:rtb.DetectUrls = $false
$script:rtb.Add_HandleCreated({ param($s, $e) [CoreUi.Native]::DarkScroll($s) })
$chkBox = New-InsetBox
$chkBox.Controls.Add($script:rtb)
$grpChk.Controls.Add($chkBox)

Add-Stack $script:Pages["core"] (@($script:PageHeads["core"]) + $coreGroups + @($grpChk)) 12

# ============================================================
#  Settings — 対象・メモリ・アプリの割り当て
# ============================================================
New-Page "settings" "Settings" ""

# --- 対象 ---
$grpMode = New-Card "対象" "" 102
$grpMode.Controls.Add((New-UiLabel "登録名" 18 58 120 "sub"))
$script:cmbVm = New-Object CoreUi.DarkComboBox
$script:cmbVm.Location = New-Object System.Drawing.Point(140, 54)
$script:cmbVm.Size = New-Object System.Drawing.Size(260, 30)
$script:cmbVm.ItemHeight = 22
$script:cmbVm.DropDownStyle = "DropDown"   # 未作成の 登録名も入力できるようにする
if ($script:HyperVOk) {
    foreach ($n in @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)) {
        [void]$script:cmbVm.Items.Add($n)
    }
}
if ($script:cmbVm.Items.Contains($script:VmNameSel)) { $script:cmbVm.SelectedItem = $script:VmNameSel }
$script:cmbVm.Text = $script:VmNameSel
$grpMode.Controls.Add($script:cmbVm)
$script:lblVm = New-UiLabel "" 420 58 562 "body"
$script:lblVm.Anchor = "Top,Left,Right"
$grpMode.Controls.Add($script:lblVm)
# 方式は「完全分離」固定 (選択肢は出さない)

# --- メモリの割り当て ---
$grpMem = New-Card "メモリの割り当て" "PC 全体のメモリを Windows と Edge Box で分ける" 172
$script:lblMemPc = New-UiLabel "" 18 58 230 "body"
$grpMem.Controls.Add($script:lblMemPc)
$script:lblMemVm = New-UiLabel "" 252 58 130 "sub"
$script:lblMemVm.TextAlign = "MiddleRight"
$grpMem.Controls.Add($script:lblMemVm)
$btnMemDown = New-UiButton "−" 34
$btnMemDown.Location = New-Object System.Drawing.Point(388, 52)
$script:numMem = New-Object System.Windows.Forms.NumericUpDown
$script:numMem.Minimum = 1
$script:numMem.Maximum = 4096
$script:numMem.Value = 8
$script:numMem.TextAlign = "Center"
$fMem = New-UiField $script:numMem 424 54 64 30 ([CoreUi.Theme]::Mono)   # 両側の − / + で操作する (キーの ↑↓ も使える)
$btnMemUp = New-UiButton "+" 34
$btnMemUp.Location = New-Object System.Drawing.Point(490, 52)
$btnMemDown.Add_Click({ $script:numMem.DownButton() })
$btnMemUp.Add_Click({ $script:numMem.UpButton() })
$script:numMem.Add_EnabledChanged({ $btnMemDown.Enabled = $script:numMem.Enabled; $btnMemUp.Enabled = $script:numMem.Enabled })
$grpMem.Controls.AddRange(@($btnMemDown, $fMem, $btnMemUp))
$grpMem.Controls.Add((New-UiLabel "GB" 532 58 0 "sub"))
$script:lblMemHost = New-UiLabel "" 566 58 250 "body"
$script:lblMemHost.Anchor = "Top,Left,Right"
$grpMem.Controls.Add($script:lblMemHost)
$script:btnMem = New-UiButton "メモリを適用" 150 "Default" "check"
$script:btnMem.Location = New-Object System.Drawing.Point(832, 52)
$script:btnMem.Anchor = "Top,Right"
$grpMem.Controls.Add($script:btnMem)
$script:memBar = New-Object CoreUi.MemoryBar
$script:memBar.Location = New-Object System.Drawing.Point(18, 102)
$script:memBar.Size = New-Object System.Drawing.Size(964, 8)
$script:memBar.Anchor = "Top,Left,Right"
$grpMem.Controls.Add($script:memBar)
$script:lblMemNote = New-UiLabel "" 18 122 964 "sub" 36
$script:lblMemNote.Anchor = "Top,Left,Right"
$grpMem.Controls.Add($script:lblMemNote)

# --- アプリの割り当て (Windows 側アプリを特定コアに固定する) ---
$grpApps = New-Card "アプリの割り当て" "" 102
$script:btnApps = New-UiButton "編集" 104 "Default" "edit"
$script:btnApps.Location = New-Object System.Drawing.Point(16, 52)
$grpApps.Controls.Add($script:btnApps)
$script:lblApps = New-UiLabel "" 136 58 846 "body"
$script:lblApps.Anchor = "Top,Left,Right"
$grpApps.Controls.Add($script:lblApps)

Add-Stack $script:Pages["settings"] @($script:PageHeads["settings"], $grpMode, $grpMem, $grpApps) 14

# ============================================================
#  操作ボタン (下の操作バー)
# ============================================================
$script:btnUndo = New-UiButton "分割を解除" 140 "Danger" "undo"

$script:btnFix = New-UiButton "完全分離用に並べ直す" 214 "Default" "sort"
$script:btnFix.Visible = $false
$script:FixVisible = $false

$script:chkTools = New-Object System.Windows.Forms.CheckBox
$script:chkTools.Text = "CpuGroups.exe を自動取得"
$script:chkTools.Checked = $true
$script:chkTools.Visible = $false   # 常に自動取得する (仕組みの名前は画面に出さない)

$script:btnApply = New-UiButton "この内容で適用" 180 "Primary" "check"

$btnClose = New-UiButton "閉じる" 110
$btnClose.DialogResult = "Cancel"
$form.CancelButton = $btnClose

$script:footDivider = New-Object System.Windows.Forms.Panel
$script:footDivider.BackColor = [CoreUi.Theme]::Border
$script:footDivider.Size = New-Object System.Drawing.Size(1, 24)
$script:footer.Controls.AddRange(@($script:btnUndo, $script:footDivider, $script:btnFix, $script:chkTools, $script:btnApply, $btnClose))

# 右から: 閉じる / 適用 / 並べ直す (必要なときだけ) | 分割を解除。左には検査の結果と変更の有無
function Update-FooterLayout {
    $w = $script:footer.ClientSize.Width
    $h = $script:footer.ClientSize.Height
    $y = [int](($h - 34) / 2)
    $script:btnApply.Width = $script:btnApply.PreferredWidthFor(180)
    $x = $w - 20
    foreach ($b in @($btnClose, $script:btnApply, $script:btnFix)) {
        if ($b -eq $script:btnFix -and -not $script:FixVisible) { continue }
        $x -= $b.Width
        $b.Location = New-Object System.Drawing.Point($x, $y)
        $x -= 8
    }
    $x -= 10
    $script:footDivider.Location = New-Object System.Drawing.Point($x, ($y + 5))
    $x -= 18 + $script:btnUndo.Width
    $script:btnUndo.Location = New-Object System.Drawing.Point($x, $y)
    $limit = $x - 16
    $cy = [int](($h - 28) / 2)
    $script:chipVerdict.AutoFit = $true
    $script:chipVerdict.Location = New-Object System.Drawing.Point(20, $cy)
    if ($script:chipVerdict.Right -gt $limit) { $script:chipVerdict.AutoFit = $false; $script:chipVerdict.Width = [Math]::Max(80, $limit - 20) }
    $script:chipChange.AutoFit = $true
    $script:chipChange.Location = New-Object System.Drawing.Point(($script:chipVerdict.Right + 8), $cy)
    $script:chipChange.Visible = ($script:chipChange.Right -le $limit)
}
$script:footer.Add_Resize({ try { Update-FooterLayout } catch { } })
$script:btnApply.Add_TextChanged({ try { Update-FooterLayout } catch { } })

