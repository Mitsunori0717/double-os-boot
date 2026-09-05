<#
.SYNOPSIS
    EdgeBox 監視 — 各コアの負荷「誰が使っているか」と、メモリの使用量をリアルタイムで表示します。

.DESCRIPTION
    ハイパーバイザーの性能カウンターを毎秒読み、論理 CPU ごとに
        VM の実行 (緑) / Windows 自身の実行 (青) / ハイパーバイザー内部 (灰)
    を積み上げ棒で描きます。タスクマネージャーでは VM の分が「vmmem」という
    1 つのプロセスにしか見えませんが、ここではコア単位で分かります。
    枠の色は CPU 割り当ての計画 (青 = Windows 用 / 緑 = EdgeBox 用) です。

    メモリは PC 全体を「Windows 使用中 / EdgeBox 使用中 / 空き」に分けて表示します。

    ウィンドウの大きさは自由に変えられ、最小化してしまっておけます
    (最小化中は測定を休みます)。

.EXAMPLE
    .\cpu-monitor.ps1                    # 監視ウィンドウを開く
    .\cpu-monitor.ps1 -IntervalMs 2000   # 2 秒ごとに更新
    .\cpu-monitor.ps1 -TopMost           # 常に手前に表示

.NOTES
    CPU の表示は管理者でなくてもできます。VM の状態とメモリ割り当ての取得には
    Hyper-V の管理権限が要ります (無い場合はその部分だけ「取得不可」になります)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [int]$IntervalMs = 1000,
    [switch]$TopMost
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ConfigFile   = Join-Path $PSScriptRoot "cpu-partition.json"
$SnapshotFile = Join-Path $PSScriptRoot "cpu-topology.json"

# -VMName を明示していない場合は、保存済み計画の VM 名を使う
if (-not $PSBoundParameters.ContainsKey("VMName") -and (Test-Path $ConfigFile)) {
    try {
        $c0 = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c0.VMName) { $VMName = [string]$c0.VMName }
    } catch { }
}

# ============================================================ 情報源

function ConvertTo-LpRangeText([int[]]$Lps) {
    if (-not $Lps -or $Lps.Count -eq 0) { return "-" }
    $sorted = @($Lps | Sort-Object -Unique)
    $parts = @(); $start = $sorted[0]; $prev = $sorted[0]
    for ($k = 1; $k -lt $sorted.Count; $k++) {
        $i = $sorted[$k]
        if ($i -eq ($prev + 1)) { $prev = $i; continue }
        if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
        $start = $i; $prev = $i
    }
    if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
    return ($parts -join ",")
}

# コア構成: 設定コンソールが保存した cpu-topology.json (P/E の区別付き)。無ければ 1 論理 = 1 コア
function Get-Cores {
    $raw = @()
    if (Test-Path $SnapshotFile) {
        try {
            foreach ($r in @(Get-Content $SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
                $lps = @([int[]]$r.Lps)
                if ($lps.Count -gt 0) { $raw += [pscustomobject]@{ Eff = [int]$r.Eff; Lps = $lps; Kind = "C"; Label = "" } }
            }
        } catch { $raw = @() }
    }
    if ($raw.Count -eq 0) {
        foreach ($i in 0..([Environment]::ProcessorCount - 1)) {
            $raw += [pscustomobject]@{ Eff = 0; Lps = @($i); Kind = "C"; Label = "" }
        }
    }
    $raw = @($raw | Sort-Object { $_.Lps[0] })
    $effs = @($raw | ForEach-Object { $_.Eff } | Sort-Object -Unique)
    $maxEff = $effs[-1]
    $np = 0; $ne = 0; $nc = 0
    foreach ($c in $raw) {
        if ($effs.Count -gt 1) {
            if ($c.Eff -eq $maxEff) { $c.Kind = "P"; $c.Label = "P$np"; $np++ }
            else                    { $c.Kind = "E"; $c.Label = "E$ne"; $ne++ }
        } else { $c.Kind = "C"; $c.Label = "C$nc"; $nc++ }
    }
    return ,$raw
}

# 割り当ての計画 (cpu-partition.json)
function Get-Plan {
    $h = @(); $g = @(); $mode = ""
    if (Test-Path $ConfigFile) {
        try {
            $c = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $h = @([int[]]$c.HostLps); $g = @([int[]]$c.GuestLps); $mode = [string]$c.Mode
        } catch { }
    }
    return [pscustomobject]@{ Host = $h; Guest = $g; Mode = $mode }
}

# ハイパーバイザーの性能カウンター (-Verify と同じ考え方)
#   LP の Guest = ルート VP (Windows 自身) + VM の VP なので、同番号のルート VP を引いて VM 分を出す
$script:lpName = $null; $script:rvName = $null
$lpCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorLogicalProcessor" -ErrorAction SilentlyContinue | Select-Object -First 1
$rvCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorRootVirtualProcessor" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lpCls) { $script:lpName = $lpCls.CimClassName }
if ($rvCls) { $script:rvName = $rvCls.CimClassName }

function Get-CounterMap($ClassName) {
    $map = @{}
    if (-not $ClassName) { return $map }
    foreach ($x in @(Get-CimInstance -ClassName $ClassName -ErrorAction SilentlyContinue)) {
        if ($x.Name -notmatch '(\d+)\s*$') { continue }
        $map[[int]$Matches[1]] = $x
    }
    return $map
}
function Get-DeltaPct($A, $B, [string]$Prop) {
    if (-not $A -or -not $B) { return 0.0 }
    $dt = [double]($B.Timestamp_Sys100NS - $A.Timestamp_Sys100NS)
    if ($dt -le 0) { return 0.0 }
    return [Math]::Max(0.0, [Math]::Min(100.0, 100.0 * ($B.$Prop - $A.$Prop) / $dt))
}

# ============================================================ 状態

$script:Cores  = @(Get-Cores)
$script:Plan   = Get-Plan
$script:Hybrid = (@($script:Cores | Where-Object { $_.Kind -eq "E" }).Count -gt 0)
$script:Stat   = @{}            # 論理 CPU 番号 → @{ Vm; Win; Hv }
$script:prevLp = $null
$script:prevRv = $null
$script:Mem    = @{ TotalGB = 0.0; WinGB = 0.0; VmGB = 0.0; FreeGB = 0.0; VmAssignedGB = 0.0; VmState = "?" }
$script:LastErr = ""
$script:TickNo  = 0

function Sample {
    $script:TickNo++
    if ($script:lpName) {
        $lp = Get-CounterMap $script:lpName
        $rv = Get-CounterMap $script:rvName
        if ($script:prevLp) {
            $new = @{}
            foreach ($i in @($lp.Keys)) {
                $a = $script:prevLp[$i]; $b = $lp[$i]
                $guest = Get-DeltaPct $a $b "PercentGuestRunTime"
                $total = Get-DeltaPct $a $b "PercentTotalRunTime"
                $win = 0.0
                if ($rv.ContainsKey($i) -and $script:prevRv -and $script:prevRv.ContainsKey($i)) {
                    $win = Get-DeltaPct $script:prevRv[$i] $rv[$i] "PercentGuestRunTime"
                }
                $new[$i] = @{ Vm = [Math]::Max(0.0, $guest - $win); Win = $win; Hv = [Math]::Max(0.0, $total - $guest) }
            }
            $script:Stat = $new
        }
        $script:prevLp = $lp
        $script:prevRv = $rv
    }
    # メモリ: PC 全体 = Windows 使用中 + VM 使用中 (vmmem の実メモリ) + 空き
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totGB  = [double]$os.TotalVisibleMemorySize / 1MB      # KB → GB
        $freeGB = [double]$os.FreePhysicalMemory / 1MB
        $vmWs = 0.0
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "vmmem*" })) {
            $vmWs += [double]$p.WorkingSet64
        }
        $vmGB = $vmWs / 1GB
        $script:Mem.TotalGB = $totGB
        $script:Mem.FreeGB  = $freeGB
        $script:Mem.VmGB    = $vmGB
        $script:Mem.WinGB   = [Math]::Max(0.0, ($totGB - $freeGB) - $vmGB)
    } catch { }
    # VM の状態と割り当て (重いので 3 回に 1 回)
    if (($script:TickNo % 3) -eq 1) {
        try {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
            $script:Mem.VmState = [string]$vm.State
            $asg = [double]$vm.MemoryAssigned / 1GB
            if ($asg -le 0) { try { $asg = [double](Get-VMMemory -VMName $VMName -ErrorAction Stop).Startup / 1GB } catch { } }
            $script:Mem.VmAssignedGB = $asg
        } catch { $script:Mem.VmState = "取得不可" }
    }
}

function Get-Avg($Lps, [string]$Key) {
    $vals = @()
    foreach ($l in @($Lps)) { $s = $script:Stat[[int]$l]; if ($s) { $vals += [double]$s[$Key] } }
    if ($vals.Count -eq 0) { return 0.0 }
    return [double](($vals | Measure-Object -Average).Average)
}

# ============================================================ 描画

$ColWin  = [System.Drawing.Color]::FromArgb(86, 140, 220)
$ColVm   = [System.Drawing.Color]::FromArgb(96, 180, 120)
$ColHv   = [System.Drawing.Color]::FromArgb(175, 175, 175)
$ColFree = [System.Drawing.Color]::FromArgb(232, 232, 232)
$BrWin   = New-Object System.Drawing.SolidBrush $ColWin
$BrVm    = New-Object System.Drawing.SolidBrush $ColVm
$BrHv    = New-Object System.Drawing.SolidBrush $ColHv
$BrFree  = New-Object System.Drawing.SolidBrush $ColFree
$BrText  = [System.Drawing.Brushes]::Black
$BrGray  = [System.Drawing.Brushes]::DimGray
$PenHost  = New-Object System.Drawing.Pen -ArgumentList @($ColWin, [float]2)
$PenGuest = New-Object System.Drawing.Pen -ArgumentList @($ColVm, [float]2)
$PenNone  = New-Object System.Drawing.Pen -ArgumentList @([System.Drawing.Color]::Silver, [float]1)
$FontTitle = New-Object System.Drawing.Font -ArgumentList @("Meiryo UI", [float]9, [System.Drawing.FontStyle]::Bold)
$FontBody  = New-Object System.Drawing.Font -ArgumentList @("Meiryo UI", [float]9)
$FontSmall = New-Object System.Drawing.Font -ArgumentList @("Meiryo UI", [float]7)

function Rect([int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -lt 0) { $w = 0 }; if ($h -lt 0) { $h = 0 }
    return New-Object System.Drawing.Rectangle -ArgumentList @($x, $y, $w, $h)
}
function PointF([double]$x, [double]$y) { return New-Object System.Drawing.PointF -ArgumentList @([float]$x, [float]$y) }

function Draw-Legend($g, [int]$x, [int]$y) {
    $items = @(@($BrVm, "$VMName の実行"), @($BrWin, "Windows の実行"), @($BrHv, "ハイパーバイザー内部"))
    foreach ($it in $items) {
        $g.FillRectangle($it[0], (Rect $x $y 12 12))
        $g.DrawString($it[1], $FontSmall, $BrText, (PointF ($x + 16) ($y - 2)))
        $x += 16 + [int]$g.MeasureString($it[1], $FontSmall).Width + 14
    }
}

function Draw-Row($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title, $cs) {
    $lpTotal = 0; foreach ($c in $cs) { $lpTotal += $c.Lps.Count }
    $g.DrawString(("{0} — {1} コア / {2} スレッド" -f $title, $cs.Count, $lpTotal), $FontTitle, $BrText, (PointF $x $y))
    if ($cs.Count -eq 0) { return }
    $barTop = $y + 36
    $labelH = 30
    $barH = $h - 36 - $labelH - 4
    if ($barH -lt 16) { $barH = 16 }
    $slotW = [int]($w / $cs.Count)
    if ($slotW -lt 12) { $slotW = 12 }
    $i = 0
    foreach ($c in $cs) {
        $sx = $x + $i * $slotW; $i++
        # 枠: 割り当ての計画で色分け
        $inGuest = 0; $inHost = 0
        foreach ($lp in $c.Lps) {
            if ($script:Plan.Guest -contains $lp) { $inGuest++ } elseif ($script:Plan.Host -contains $lp) { $inHost++ }
        }
        $pen = $PenNone
        if ($inGuest -eq $c.Lps.Count) { $pen = $PenGuest } elseif ($inHost -eq $c.Lps.Count) { $pen = $PenHost }
        $g.DrawRectangle($pen, (Rect ($sx + 2) ($barTop - 2) ($slotW - 4) ($barH + 4)))
        # 論理 CPU ごとの棒
        $n = $c.Lps.Count
        $inner = $slotW - 8
        $bw = [int](($inner - ($n - 1) * 2) / $n)
        if ($bw -lt 2) { $bw = 2 }
        $k = 0
        foreach ($lp in $c.Lps) {
            $bx = $sx + 4 + $k * ($bw + 2); $k++
            $vm = 0.0; $win = 0.0; $hv = 0.0
            $st = $script:Stat[[int]$lp]
            if ($st) { $vm = [double]$st.Vm; $win = [double]$st.Win; $hv = [double]$st.Hv }
            $g.FillRectangle($BrFree, (Rect $bx $barTop $bw $barH))
            $hVm  = [int]($barH * $vm / 100.0)
            $hWin = [int]($barH * $win / 100.0)
            $hHv  = [int]($barH * $hv / 100.0)
            if (($hVm + $hWin + $hHv) -gt $barH) { $hHv = [Math]::Max(0, $barH - $hVm - $hWin) }
            $yy = $barTop + $barH
            if ($hVm -gt 0)  { $yy -= $hVm;  $g.FillRectangle($BrVm,  (Rect $bx $yy $bw $hVm)) }
            if ($hWin -gt 0) { $yy -= $hWin; $g.FillRectangle($BrWin, (Rect $bx $yy $bw $hWin)) }
            if ($hHv -gt 0)  { $yy -= $hHv;  $g.FillRectangle($BrHv,  (Rect $bx $yy $bw $hHv)) }
            if ($bw -ge 16) {
                $g.DrawString(("{0:N0}" -f ($vm + $win + $hv)), $FontSmall, $BrGray, (PointF $bx ($barTop - 15)))
            }
        }
        # ラベル (コア名と論理 CPU 番号)
        if ($slotW -ge 30) {
            $lbl = "{0}`nCPU {1}" -f $c.Label, (ConvertTo-LpRangeText $c.Lps)
            $g.DrawString($lbl, $FontSmall, $BrText, (PointF ($sx + 3) ($barTop + $barH + 4)))
        }
    }
}

function Draw-Memory($g, [int]$x, [int]$y, [int]$w, [int]$h) {
    $m = $script:Mem
    $tot = [double]$m.TotalGB
    $g.DrawString("メモリ", $FontTitle, $BrText, (PointF $x $y))
    $barY = $y + 22; $barH = 18
    $g.FillRectangle($BrFree, (Rect $x $barY $w $barH))
    if ($tot -gt 0) {
        $wWin = [int]($w * [double]$m.WinGB / $tot)
        $wVm  = [int]($w * [double]$m.VmGB / $tot)
        $g.FillRectangle($BrWin, (Rect $x $barY $wWin $barH))
        $g.FillRectangle($BrVm,  (Rect ($x + $wWin) $barY $wVm $barH))
        $g.DrawRectangle($PenNone, (Rect $x $barY $w $barH))
        $txt = "PC 全体 {0:N1} GB    Windows 使用中 {1:N1} GB    {2} 使用中 {3:N1} GB (割り当て {4:N0} GB)    空き {5:N1} GB" -f `
            $tot, $m.WinGB, $VMName, $m.VmGB, $m.VmAssignedGB, $m.FreeGB
    } else {
        $txt = "メモリ情報を取得できません"
    }
    $g.DrawString($txt, $FontBody, $BrText, (PointF $x ($barY + $barH + 4)))
}

function Draw-All($g, [int]$W, [int]$H) {
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $pad = 10

    # --- 見出し: 平均 ---
    $hostLps = @($script:Plan.Host); $guestLps = @($script:Plan.Guest)
    $allLps = @($script:Stat.Keys)
    if ($hostLps.Count -gt 0) {
        $l1 = "Windows : 平均 {0:N0}%   (割り当て CPU {1} / {2} 論理)" -f (Get-Avg $hostLps "Win"), (ConvertTo-LpRangeText $hostLps), $hostLps.Count
    } else {
        $l1 = "Windows : 平均 {0:N0}%   (割り当てなし = 全コア)" -f (Get-Avg $allLps "Win")
    }
    if ($guestLps.Count -gt 0) {
        $l2 = "{0} : 平均 {1:N0}%   (割り当て CPU {2} / {3} 論理)   状態: {4}" -f $VMName, (Get-Avg $guestLps "Vm"), (ConvertTo-LpRangeText $guestLps), $guestLps.Count, $script:Mem.VmState
    } else {
        $l2 = "{0} : 平均 {1:N0}%   状態: {2}" -f $VMName, (Get-Avg $allLps "Vm"), $script:Mem.VmState
    }
    $g.DrawString($l1, $FontBody, $BrWin, (PointF $pad 4))
    $g.DrawString($l2, $FontBody, $BrVm,  (PointF $pad 22))
    Draw-Legend $g ([Math]::Max($pad, $W - 400)) 8
    if (-not $script:lpName) {
        $g.DrawString("ハイパーバイザーの性能カウンターが見つかりません (Hyper-V が無効か、カウンターの破損)。", $FontBody, [System.Drawing.Brushes]::Firebrick, (PointF $pad 44))
    }

    # --- コアの行 ---
    $rows = @()
    if ($script:Hybrid) {
        $rows += ,@("P", "P コア (性能重視)")
        $rows += ,@("E", "E コア (効率重視)")
    } else {
        $rows += ,@("C", "コア")
    }
    $top = 48; $memH = 70
    $avail = $H - $top - $memH - $pad
    $rowH = [int]($avail / $rows.Count)
    if ($rowH -lt 90) { $rowH = 90 }
    $y = $top
    foreach ($r in $rows) {
        $cs = @($script:Cores | Where-Object { $_.Kind -eq $r[0] })
        Draw-Row $g $pad $y ($W - 2 * $pad) $rowH $r[1] $cs
        $y += $rowH
    }

    # --- メモリ ---
    Draw-Memory $g $pad ($H - $memH) ($W - 2 * $pad) ($memH - $pad)
}

# ============================================================ ウィンドウ

$form = New-Object System.Windows.Forms.Form
$form.Text = "$VMName 監視 — 各コアの負荷とメモリ"
$form.ClientSize = New-Object System.Drawing.Size(1000, 600)
$form.MinimumSize = New-Object System.Drawing.Size(640, 440)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "Sizable"      # 大きさは自由に変えられる
$form.MaximizeBox = $true
$form.MinimizeBox = $true              # 最小化してしまっておける
$form.TopMost = [bool]$TopMost
$form.Font = New-Object System.Drawing.Font -ArgumentList @("Meiryo UI", [float]9)

# 上のバー: 更新間隔・常に手前・状態
$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Top"
$top.Height = 32
$lblIv = New-Object System.Windows.Forms.Label
$lblIv.Text = "更新間隔:"; $lblIv.AutoSize = $true
$lblIv.Location = New-Object System.Drawing.Point(10, 8)
$cmbIv = New-Object System.Windows.Forms.ComboBox
$cmbIv.DropDownStyle = "DropDownList"
[void]$cmbIv.Items.AddRange(@("1 秒", "2 秒", "5 秒"))
$cmbIv.Location = New-Object System.Drawing.Point(72, 5)
$cmbIv.Size = New-Object System.Drawing.Size(70, 24)
$cmbIv.SelectedIndex = $(if ($IntervalMs -ge 5000) { 2 } elseif ($IntervalMs -ge 2000) { 1 } else { 0 })
$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = "常に手前に表示"; $chkTop.AutoSize = $true
$chkTop.Location = New-Object System.Drawing.Point(160, 7)
$chkTop.Checked = [bool]$TopMost
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(300, 8)
$lblStatus.Size = New-Object System.Drawing.Size(680, 20)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblStatus.Anchor = "Top,Left,Right"
$top.Controls.AddRange(@($lblIv, $cmbIv, $chkTop, $lblStatus))

# 描画面 (ちらつき防止のため二重バッファ)
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = "Fill"
$panel.BackColor = [System.Drawing.Color]::White
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

$timer.Add_Tick({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }   # しまっている間は休む
    try { Sample; $script:LastErr = "" } catch { $script:LastErr = $_.Exception.Message }
    if ($script:LastErr) { $lblStatus.Text = "エラー: $($script:LastErr)" }
    else { $lblStatus.Text = "更新 " + (Get-Date -Format "HH:mm:ss") + "   (数値は直前の更新間隔での平均。枠の色 = 割り当ての計画)" }
    $panel.Invalidate()
})
$cmbIv.Add_SelectedIndexChanged({
    $timer.Interval = @(1000, 2000, 5000)[$cmbIv.SelectedIndex]
    $script:prevLp = $null; $script:prevRv = $null   # 間隔を変えた直後の 1 回は捨てる
})
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked })
$form.Add_Shown({
    try { Sample } catch { }
    $timer.Start()
})
$form.Add_FormClosing({ $timer.Stop() })

[void]$form.ShowDialog()
