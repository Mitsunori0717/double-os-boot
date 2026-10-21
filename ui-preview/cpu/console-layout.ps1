
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

# 横並びの列 (幅の割合を指定)
function New-Columns([int]$Height, [int[]]$Percents) {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.Size = New-Object System.Drawing.Size(1000, $Height)
    $t.BackColor = [System.Drawing.Color]::Transparent
    $t.Margin = New-Object System.Windows.Forms.Padding(0)
    $t.Padding = New-Object System.Windows.Forms.Padding(0)
    $t.ColumnCount = $Percents.Count
    $t.RowCount = 1
    foreach ($p in $Percents) {
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, [float]$p)))
    }
    [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, [float]100)))
    return $t
}
function Add-Column($Tlp, $Ctl, [int]$Col) {
    $Ctl.Dock = "Fill"
    $l = if ($Col -eq 0) { 0 } else { 7 }
    $r = if ($Col -eq ($Tlp.ColumnCount - 1)) { 0 } else { 7 }
    $Ctl.Margin = New-Object System.Windows.Forms.Padding($l, 0, $r, 0)
    $Tlp.Controls.Add($Ctl, $Col, 0)
}

# パネルの中に「項目名 : 値」を 1 行置く (値のラベルは呼び出し側が持つ)
function Add-KeyValue($Card, [string]$Key, $ValueLabel, [int]$Y) {
    $Card.Controls.Add((New-UiLabel $Key 18 $Y 180 "sub"))
    $ValueLabel.Location = New-Object System.Drawing.Point(206, $Y)
    $ValueLabel.AutoSize = $false
    $ValueLabel.AutoEllipsis = $true
    $ValueLabel.Size = New-Object System.Drawing.Size(($Card.Width - 224), 22)
    $ValueLabel.Anchor = "Top,Left,Right"
    $Card.Controls.Add($ValueLabel)
}

# --- ヘッダー ---
$script:header = New-Object CoreUi.HeaderBar
$script:header.Dock = "Top"
$script:header.Brand = $UiAppName
$script:header.Version = $UiAppVersion
$script:header.Tagline = $UiAppTagline
$script:header.SubTitle = "CPU コア割り当て"
$script:chipSplit = New-Object CoreUi.StatusChip
$script:chipVm = New-Object CoreUi.StatusChip
$script:header.Controls.AddRange(@($script:chipSplit, $script:chipVm))
$script:Tip.SetToolTip($script:chipSplit, "分離の状態 (詳しくは Home / System)")
$script:Tip.SetToolTip($script:chipVm, "対象の Edge Box の状態")

function Update-HeaderLayout {
    $x = $script:header.ClientSize.Width - 20
    foreach ($c in @($script:chipVm, $script:chipSplit)) {
        $c.Location = New-Object System.Drawing.Point(($x - $c.Width), [int](($script:header.Height - $c.Height) / 2))
        $x = $c.Left - 10
    }
}
$script:header.Add_Resize({ try { Update-HeaderLayout } catch { } })

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
    @{ Key = "home";     Text = "Home";       Sub = "概要";                Glyph = "home" },
    @{ Key = "core";     Text = "Core Split"; Sub = "コアの割り当て";      Glyph = "cores" },
    @{ Key = "settings"; Text = "Settings";   Sub = "対象・メモリ・アプリ"; Glyph = "settings" },
    @{ Key = "log";      Text = "Log";        Sub = "記録";                Glyph = "log" },
    @{ Key = "system";   Text = "System";     Sub = "この PC の構成";      Glyph = "system" }
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
$navHint = New-UiLabel "Ctrl+1〜5 で画面を切り替え" 18 60 188 "small"
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
    $h.Size = New-Object System.Drawing.Size(1000, 64)
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
        if ($Key -eq "log")  { Update-LogView }
    } catch { }
}

$form.Add_KeyDown({
    param($s, $e)
    if (-not $e.Control -or $e.Alt) { return }
    $keys = @{ "D1" = "home"; "D2" = "core"; "D3" = "settings"; "D4" = "log"; "D5" = "system" }
    $name = [string]$e.KeyCode
    if ($keys.ContainsKey($name)) { Show-Page $keys[$name]; $e.Handled = $true; $e.SuppressKeyPress = $true }
})

# ============================================================
#  Home — 現在の割り当てと状態
# ============================================================
New-Page "home" "Home" "現在の割り当てと分離の状態"

$script:cardHero = New-Card "現在の割り当て" "" 262
$script:cardHero.CornerTicks = $true
$script:stripHome = New-Object CoreUi.CoreStrip
$script:stripHome.CellHeight = 16
$script:stripHome.Height = 58
$script:stripHome.Dock = "Top"
$heroCols = New-Columns 124 @(50, 50)
$heroCols.Dock = "Top"
$script:blkHost = New-Object CoreUi.SideBlock
$script:blkHost.Caption = "WINDOWS"
$script:blkHost.Tone = "Win"
$script:blkGuest = New-Object CoreUi.SideBlock
$script:blkGuest.Caption = "EDGE BOX"
$script:blkGuest.Tone = "Edge"
Add-Column $heroCols $script:blkHost 0
Add-Column $heroCols $script:blkGuest 1
$heroGap = New-Object System.Windows.Forms.Panel
$heroGap.Height = 12; $heroGap.Dock = "Top"; $heroGap.BackColor = [System.Drawing.Color]::Transparent
$script:cardHero.Controls.Add($heroCols)
$script:cardHero.Controls.Add($heroGap)
$script:cardHero.Controls.Add($script:stripHome)

function New-StatusCard([string]$Title) {
    $c = New-Card $Title "" 132
    $chip = New-Object CoreUi.StatusChip
    $chip.Location = New-Object System.Drawing.Point(18, 48)
    $c.Controls.Add($chip)
    $lbl = New-UiLabel "" 18 84 964 "sub" 40
    $lbl.Anchor = "Top,Left,Right"
    $c.Controls.Add($lbl)
    return [pscustomobject]@{ Card = $c; Chip = $chip; Label = $lbl }
}
$script:stSplit = New-StatusCard "分離の状態"
$script:stVm    = New-StatusCard "Edge Box"
$script:stWin   = New-StatusCard "Windows"
$statusCols = New-Columns 132 @(40, 32, 28)
Add-Column $statusCols $script:stSplit.Card 0
Add-Column $statusCols $script:stVm.Card 1
Add-Column $statusCols $script:stWin.Card 2

$homeActs = New-Object System.Windows.Forms.Panel
$homeActs.Size = New-Object System.Drawing.Size(1000, 40)
$homeActs.BackColor = [System.Drawing.Color]::Transparent
$btnGoCore = New-UiButton "コアの割り当てを編集" 210 "Primary" "cores"
$btnGoCore.Location = New-Object System.Drawing.Point(0, 2)
$btnGoCore.Add_Click({ Show-Page "core" })
$btnHomeMon = New-UiButton "リアルタイム監視を開く" 220 "Default" "monitor"
$btnHomeMon.Location = New-Object System.Drawing.Point(218, 2)
$btnHomeMon.Add_Click({ $script:btnMon.PerformClick() })
$homeActs.Controls.AddRange(@($btnGoCore, $btnHomeMon))

Add-Stack $script:Pages["home"] @($script:PageHeads["home"], $script:cardHero, $statusCols, $homeActs) 14

# ============================================================
#  Core Split — コアのタイル・割り当ての内容・検査結果
# ============================================================
$coreSub = if ($script:Hybrid) { "タイルをクリックするたびに Windows → Edge Box → 未割当 と切り替わります (P コアは Windows ⇔ 未割当)" }
           else { "タイルをクリックするたびに Windows → Edge Box → 未割当 と切り替わります" }
New-Page "core" "Core Split" $coreSub
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
    $grpP = New-CoreGroup "P コア (性能重視)" ("{0} コア / {1} スレッド   ·   Windows 専用" -f $pCores.Count, $pThreads)
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

# --- 割り当ての要約 ---
$grpSum = New-Card "この内容で割り当てます" "" 214
$script:stripCore = New-Object CoreUi.CoreStrip
$script:stripCore.Dock = "Top"
$script:stripCore.Height = 56
function New-SideLine([System.Drawing.Color]$Color, [string]$Tag) {
    $row = New-Object System.Windows.Forms.Panel
    $row.Size = New-Object System.Drawing.Size(964, 30)
    $row.BackColor = [System.Drawing.Color]::Transparent
    $sw = New-Object System.Windows.Forms.Panel
    $sw.BackColor = $Color
    $sw.Bounds = New-Object System.Drawing.Rectangle(0, 9, 10, 10)
    $row.Controls.Add($sw)
    $lbl = New-UiLabel "" 18 4 946 "body"
    $lbl.Font = [CoreUi.Theme]::UiMedium
    $lbl.Anchor = "Top,Left,Right"
    $row.Controls.Add($lbl)
    $script:Tip.SetToolTip($lbl, $Tag)
    return [pscustomobject]@{ Row = $row; Label = $lbl }
}
$sumH = New-SideLine ([CoreUi.Theme]::Win) "Windows に割り当てるコア"
$sumG = New-SideLine ([CoreUi.Theme]::Edge) "Edge Box に割り当てるコア"
$script:lblSumH = $sumH.Label
$script:lblSumG = $sumG.Label
$sumGap = New-Object System.Windows.Forms.Panel
$sumGap.Height = 10; $sumGap.BackColor = [System.Drawing.Color]::Transparent
Add-Stack $grpSum @($script:stripCore, $sumGap, $sumH.Row, $sumG.Row) 0

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

$coreBottom = New-Columns 214 @(56, 44)
Add-Column $coreBottom $grpSum 0
Add-Column $coreBottom $grpChk 1

Add-Stack $script:Pages["core"] (@($script:PageHeads["core"]) + $coreGroups + @($coreBottom)) 12

# ============================================================
#  Settings — 対象・メモリ・アプリの割り当て
# ============================================================
New-Page "settings" "Settings" "対象の Edge Box・メモリの割り当て・アプリの割り当て"

# --- 対象 ---
$grpMode = New-Card "対象" "割り当てを適用する Edge Box の登録" 132
$grpMode.Controls.Add((New-UiLabel "対象の登録名" 18 58 120 "sub"))
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
$modeNote = New-UiLabel "一覧に無い名前も入力できます (これから作る Edge Box)。入力欄から移ると反映します。" 18 96 964 "small"
$modeNote.Anchor = "Top,Left,Right"
$grpMode.Controls.Add($modeNote)
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
$grpApps = New-Card "アプリの割り当て" "Windows 側のアプリを決めたコアで動かす" 132
$script:btnApps = New-UiButton "アプリの割り当てを編集..." 230 "Default" "edit"
$script:btnApps.Location = New-Object System.Drawing.Point(16, 52)
$grpApps.Controls.Add($script:btnApps)
$script:lblApps = New-UiLabel "" 262 58 720 "body"
$script:lblApps.Anchor = "Top,Left,Right"
$grpApps.Controls.Add($script:lblApps)
$appsNote = New-UiLabel "登録したアプリは、起動のたびに指定したコアへ自動で固定されます (1 分ごとに確認)。選べるのは Windows 用のコアだけです。" 18 96 964 "small"
$appsNote.Anchor = "Top,Left,Right"
$grpApps.Controls.Add($appsNote)

Add-Stack $script:Pages["settings"] @($script:PageHeads["settings"], $grpMode, $grpMem, $grpApps) 14

# ============================================================
#  Log — 記録ファイルの末尾
# ============================================================
New-Page "log" "Log" "適用・起動タスク・常駐の記録 (新しいものが下)"
$script:LogKind = "cpu"
$grpLog = New-Card "記録ファイル" "" 400
$logBar = New-Object System.Windows.Forms.Panel
$logBar.Dock = "Top"
$logBar.Height = 46
$logBar.BackColor = [System.Drawing.Color]::Transparent
$script:btnLogCpu = New-UiButton "CPU 分割の記録" 160
$script:btnLogCpu.Location = New-Object System.Drawing.Point(0, 0)
$script:btnLogApps = New-UiButton "アプリ割り当ての記録" 190
$script:btnLogApps.Location = New-Object System.Drawing.Point(166, 0)
$script:btnLogReload = New-UiButton "再読み込み" 130 "Ghost" "refresh"
$script:btnLogReload.Location = New-Object System.Drawing.Point(372, 0)
$script:lblLogInfo = New-UiLabel "" 520 8 444 "small"
$script:lblLogInfo.Anchor = "Top,Left,Right"
$script:lblLogInfo.TextAlign = "MiddleRight"
$logBar.Size = New-Object System.Drawing.Size(964, 46)
$logBar.Controls.AddRange(@($script:btnLogCpu, $script:btnLogApps, $script:btnLogReload, $script:lblLogInfo))
$script:rtbLog = New-Object System.Windows.Forms.RichTextBox
$script:rtbLog.Dock = "Fill"
$script:rtbLog.ReadOnly = $true
$script:rtbLog.BorderStyle = "None"
$script:rtbLog.BackColor = [CoreUi.Theme]::Inset
$script:rtbLog.ForeColor = [CoreUi.Theme]::Text
$script:rtbLog.Font = [CoreUi.Theme]::Ui     # 記録は日本語が中心のため、日本語の字形を持つ文字で出す
$script:rtbLog.DetectUrls = $false
$script:rtbLog.WordWrap = $true
$script:rtbLog.Add_HandleCreated({ param($s, $e) [CoreUi.Native]::DarkScroll($s) })
$logBox = New-InsetBox
$logBox.Controls.Add($script:rtbLog)
$grpLog.Controls.Add($logBox)
$grpLog.Controls.Add($logBar)
$grpLog.Dock = "Fill"
$script:Pages["log"].Controls.Add($grpLog)
$logGap = New-Object System.Windows.Forms.Panel
$logGap.Height = 14; $logGap.Dock = "Top"; $logGap.BackColor = [System.Drawing.Color]::Transparent
$script:Pages["log"].Controls.Add($logGap)
$script:PageHeads["log"].Dock = "Top"
$script:Pages["log"].Controls.Add($script:PageHeads["log"])

function Add-RtbText($Box, [string]$Text, [System.Drawing.Color]$Color) {
    $Box.SelectionStart = $Box.TextLength
    $Box.SelectionLength = 0
    $Box.SelectionColor = $Color
    $Box.AppendText($Text)
}

# 記録を読み直して色分けする (時刻は控えめに、失敗は赤、注意は黄)
function Update-LogView {
    $path = if ($script:LogKind -eq "apps") { $AppsLog } else { Join-Path $PSScriptRoot "cpu-partition-log.txt" }
    $script:btnLogCpu.Selected = ($script:LogKind -ne "apps")
    $script:btnLogApps.Selected = ($script:LogKind -eq "apps")
    $grpLog.Meta = [System.IO.Path]::GetFileName($path)
    $box = $script:rtbLog
    $box.Clear()
    if (-not (Test-Path $path)) {
        Add-RtbText $box ("記録はまだありません (" + [System.IO.Path]::GetFileName($path) + ")。適用や起動タスクが動くと、ここに記録されます。") ([CoreUi.Theme]::SubText)
        $script:lblLogInfo.Text = ""
        return
    }
    try {
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -Tail 400 -ErrorAction Stop)
        $info = Get-Item -LiteralPath $path
        $script:lblLogInfo.Text = "{0} 行   最終更新 {1:yyyy-MM-dd HH:mm:ss}" -f $lines.Count, $info.LastWriteTime
    } catch {
        Add-RtbText $box ("記録を読めませんでした: " + $_.Exception.Message) ([CoreUi.Theme]::ErrText)
        return
    }
    $box.SuspendLayout()
    foreach ($ln in $lines) {
        $ts = ""; $body = [string]$ln
        if ($body -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$') { $ts = $Matches[1]; $body = $Matches[2] }
        $col = [CoreUi.Theme]::Text
        if ($body -match '失敗|エラー|できません|できなかった|見つかりません|中止|(?i:error|failed)') { $col = [CoreUi.Theme]::ErrText }
        elseif ($body -match '注意|警告|未成立|再起動待ち|(?i:warn)') { $col = [CoreUi.Theme]::WarnText }
        if ($ts) { Add-RtbText $box ($ts + "  ") ([CoreUi.Theme]::SubText) }
        Add-RtbText $box ($body + "`n") $col
    }
    $box.ResumeLayout()
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}
$script:btnLogCpu.Add_Click({ $script:LogKind = "cpu"; Update-LogView })
$script:btnLogApps.Add_Click({ $script:LogKind = "apps"; Update-LogView })
$script:btnLogReload.Add_Click({ Update-LogView })

# ============================================================
#  System — この PC と Edge Box の構成
# ============================================================
New-Page "system" "System" "この PC の CPU・メモリと、対象の Edge Box の構成"

$grpPc = New-Card "プロセッサ" "CPU 自身が申告する構成" 222
$script:lblCpu1 = New-UiLabel "" 0 0 0 "body"
$script:lblSysKinds = New-UiLabel "" 0 0 0 "body"
$script:lblCpu2 = New-UiLabel "" 0 0 0 "body"
$script:lblCpu3 = New-UiLabel "" 0 0 0 "body"
Add-KeyValue $grpPc "CPU" $script:lblCpu1 56
Add-KeyValue $grpPc "コアの種類" $script:lblSysKinds 88
Add-KeyValue $grpPc "Windows 側" $script:lblCpu2 120
Add-KeyValue $grpPc "分離の状態" $script:lblCpu3 152
$script:lblSysNote = New-UiLabel "" 18 186 964 "small"
$script:lblSysNote.Anchor = "Top,Left,Right"
$grpPc.Controls.Add($script:lblSysNote)
if ($script:Hybrid) {
    $pl = @(); foreach ($c in @($script:Cores | Where-Object { $_.Kind -eq "P" })) { $pl += $c.Lps }
    $el = @(); foreach ($c in @($script:Cores | Where-Object { $_.Kind -eq "E" })) { $el += $c.Lps }
    $script:lblSysKinds.Text = "P コア {0} (CPU {1})   /   E コア {2} (CPU {3})" -f @($script:Cores | Where-Object { $_.Kind -eq "P" }).Count,
        (ConvertTo-LpRangeText $pl), @($script:Cores | Where-Object { $_.Kind -eq "E" }).Count, (ConvertTo-LpRangeText $el)
} else {
    $script:lblSysKinds.Text = "すべて同じ種類のコア (CPU {0})" -f (ConvertTo-LpRangeText @($script:Cores | ForEach-Object { $_.Lps }))
}
if ($script:UsedSnapshot) { $script:lblSysNote.Text = "一部のコアが Windows から見えないため、保存済みのコア構成を表示しています。" }

$grpSysVm = New-Card "Edge Box (Hyper-V)" "" 190
$script:lblSysHv = New-UiLabel "" 0 0 0 "body"
$script:lblSysVmName = New-UiLabel "" 0 0 0 "body"
$script:lblSysVm = New-UiLabel "" 0 0 0 "body"
$script:lblSysMem = New-UiLabel "" 0 0 0 "body"
Add-KeyValue $grpSysVm "Hyper-V" $script:lblSysHv 56
Add-KeyValue $grpSysVm "対象の登録名" $script:lblSysVmName 88
Add-KeyValue $grpSysVm "現在の構成" $script:lblSysVm 120
Add-KeyValue $grpSysVm "この PC のメモリ" $script:lblSysMem 152

$grpTools = New-Card "ツール" "" 104
$btnSysMon = New-UiButton "リアルタイム監視を開く" 220 "Default" "monitor"
$btnSysMon.Location = New-Object System.Drawing.Point(16, 50)
$btnSysMon.Add_Click({ $script:btnMon.PerformClick() })
$grpTools.Controls.Add($btnSysMon)
$toolsNote = New-UiLabel "各コアの負荷 (Windows / Edge Box のどちらが使っているか) とメモリの使用量を毎秒表示します。" 252 58 730 "sub"
$toolsNote.Anchor = "Top,Left,Right"
$grpTools.Controls.Add($toolsNote)

Add-Stack $script:Pages["system"] @($script:PageHeads["system"], $grpPc, $grpSysVm, $grpTools) 14

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

