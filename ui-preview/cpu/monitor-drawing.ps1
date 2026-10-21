

# 色: 青 = Windows / 緑 = Edge Box / 明るい灰 = ハイパーバイザー内部。背景は灰色 (#616061)。
# 棒の空き部分は背景より一段濃くし、ハイパーバイザー内部 (明るい灰) と見分けられるようにする
$ColWin  = [CoreUi.Theme]::Win
$ColVm   = [CoreUi.Theme]::Edge
$ColHv   = [System.Drawing.Color]::FromArgb(196, 195, 196)
$ColFree = [CoreUi.Theme]::Inset
$BrWin   = New-Object System.Drawing.SolidBrush $ColWin
$BrVm    = New-Object System.Drawing.SolidBrush $ColVm
$BrHv    = New-Object System.Drawing.SolidBrush $ColHv
# 棒の塗りは少しだけ落ち着かせる (画面いっぱいに並ぶため、純色だと強すぎる)
$BrWinBar = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Mix([CoreUi.Theme]::Panel, $ColWin, 0.8))
$BrVmBar  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Mix([CoreUi.Theme]::Panel, $ColVm, 0.82))
$BrFree  = New-Object System.Drawing.SolidBrush $ColFree
$BrText  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Text)
$BrGray  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::SubText)
# P / E の印は明るさで分ける (緑・青は Windows / Edge Box の色なので使わない)
$BrP     = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Text)                            # P コアの印
$BrE     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(224, 224, 224))   # E コアの印
$BrBad   = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::ErrText)                         # 混ざっている印 (文字)
$BrGood  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::OkText)                          # 分かれている印 (文字)
# 混ざっている印は文字の色だけに頼らず、赤い下線と「△」も付ける (灰色の背景では淡い赤と白が見分けにくいため)
$BrBadMark = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::Err)
# 文字に使う Windows / Edge Box の色 (灰色の背景の上でも読めるよう明るくしたもの)
$BrWinText = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::WinText)
$BrVmText  = New-Object System.Drawing.SolidBrush ([CoreUi.Theme]::EdgeText)
$PenHost  = New-Object System.Drawing.Pen -ArgumentList @([CoreUi.Theme]::Mix([CoreUi.Theme]::Border, $ColWin, 0.8), [float]1.5)
$PenGuest = New-Object System.Drawing.Pen -ArgumentList @([CoreUi.Theme]::Mix([CoreUi.Theme]::Border, $ColVm, 0.8), [float]1.5)
$PenNone  = New-Object System.Drawing.Pen -ArgumentList @([CoreUi.Theme]::Border, [float]1)
$PenRule  = New-Object System.Drawing.Pen -ArgumentList @([CoreUi.Theme]::Border, [float]1)
$FontTitle = [CoreUi.Theme]::UiBold
$FontBody  = [CoreUi.Theme]::Ui
$FontSmall = [CoreUi.Theme]::UiSmall
$FontNum   = New-Object System.Drawing.Font -ArgumentList @([CoreUi.Theme]::MonoFamily, [float]9, [System.Drawing.FontStyle]::Bold)
$FontPct   = [CoreUi.Theme]::Mono

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

# 論理 CPU を番号順に並べる (種類 P/E と、属するコアの名前を付ける)
function Get-LpList {
    $list = @()
    foreach ($c in $script:Cores) {
        foreach ($lp in $c.Lps) { $list += [pscustomobject]@{ Lp = [int]$lp; Kind = $c.Kind; Core = $c.Label } }
    }
    return @($list | Sort-Object Lp)
}

# 論理 CPU を番号順に格子で描く: 上に「CPU 番号」と種類 (P0/E3)、縦棒、下に使用率 (%)
# (以前はコアごとに P/E の行に分けていたため、番号順に追いにくく、細い棒では数字も出なかった)
# $only = 表示する論理 CPU 番号の一覧 ($null = 全部)。$side = "host" (Windows 用) / "guest" (Edge Box 用) / ""
# $cols = 1 行に並べる数 (0 = 幅から決める)。区画どうしで同じ数を渡すと、棒の幅と高さがそろう
# Windows 用の区画で Edge Box が動いた、または Edge Box 用の区画で Windows が動いた論理 CPU は、使用率を赤で出す
function Draw-LpGrid($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title, $only, [string]$side, [int]$cols = 0) {
    $lps = @(Get-LpList)
    if ($only) { $lps = @($lps | Where-Object { $only -contains $_.Lp }) }
    if ($title) {
        # 区画の見出し: 左に区画の色の印 (青 = Windows 用 / 緑 = Edge Box 用)
        $mark = if ($side -eq "host") { $BrWin } elseif ($side -eq "guest") { $BrVm } else { $BrGray }
        $g.FillRectangle($mark, (Rect $x ($y + 4) 3 12))
        $g.DrawString($title, $FontTitle, $BrText, (PointF ($x + 9) $y))
        $y += 22; $h -= 22
    }
    if ($lps.Count -eq 0) { $g.DrawString("(該当する CPU なし)", $FontBody, $BrGray, (PointF $x $y)); return }
    $minSlot = 54
    if ($cols -lt 1) { $cols = [Math]::Max(1, [Math]::Min($lps.Count, [int]($w / $minSlot))) }
    $rows = [int][Math]::Ceiling($lps.Count / $cols)
    $slotW = [int]($w / $cols)
    $rowH = [int]($h / $rows)
    if ($rowH -lt 80) { $rowH = 80 }
    $i = 0
    foreach ($e in $lps) {
        $r = [int][Math]::Floor($i / $cols); $ci = $i % $cols; $i++
        $sx = $x + $ci * $slotW; $sy = $y + $r * $rowH
        $vm = 0.0; $win = 0.0; $hv = 0.0
        $st = $script:Stat[[int]$e.Lp]
        if ($st) { $vm = [double]$st.Vm; $win = [double]$st.Win; $hv = [double]$st.Hv }
        $total = $vm + $win + $hv
        # 上: 番号と種類
        $g.DrawString(("CPU {0}" -f $e.Lp), $FontNum, $BrText, (PointF ($sx + 2) $sy))
        $brKind = if ($e.Kind -eq "P") { $BrP } elseif ($e.Kind -eq "E") { $BrE } else { $BrGray }
        $g.DrawString($e.Core, $FontSmall, $brKind, (PointF ($sx + 3) ($sy + 16)))
        # 縦棒 (枠の色 = 割り当ての計画: 青 = Windows 用 / 緑 = Edge Box 用)
        $barTop = $sy + 33
        $barH = $rowH - 33 - 20
        if ($barH -lt 12) { $barH = 12 }
        $bx = $sx + 4; $bw = $slotW - 8
        $pen = $PenNone
        if ($script:Plan.Guest -contains $e.Lp) { $pen = $PenGuest } elseif ($script:Plan.Host -contains $e.Lp) { $pen = $PenHost }
        $g.DrawRectangle($pen, (Rect ($bx - 1) ($barTop - 1) ($bw + 2) ($barH + 2)))
        $g.FillRectangle($BrFree, (Rect $bx $barTop $bw $barH))
        $hVm  = [int]($barH * $vm / 100.0)
        $hWin = [int]($barH * $win / 100.0)
        $hHv  = [int]($barH * $hv / 100.0)
        if (($hVm + $hWin + $hHv) -gt $barH) { $hHv = [Math]::Max(0, $barH - $hVm - $hWin) }
        $yy = $barTop + $barH
        if ($hVm -gt 0)  { $yy -= $hVm;  $g.FillRectangle($BrVmBar,  (Rect $bx $yy $bw $hVm)) }
        if ($hWin -gt 0) { $yy -= $hWin; $g.FillRectangle($BrWinBar, (Rect $bx $yy $bw $hWin)) }
        if ($hHv -gt 0)  { $yy -= $hHv;  $g.FillRectangle($BrHv,  (Rect $bx $yy $bw $hHv)) }
        # 下: 使用率 (常に表示)。区画に合わない側の使用が 1% を超えていれば赤 (混ざっている印)
        $brPct = $BrText
        if (($side -eq "host" -and $vm -gt 1.0) -or ($side -eq "guest" -and $win -gt 1.0)) { $brPct = $BrBad }
        $g.DrawString(("{0:N0}%" -f $total), $FontPct, $brPct, (PointF ($sx + 2) ($barTop + $barH + 3)))
        if ($brPct -eq $BrBad) { $g.FillRectangle($BrBadMark, (Rect ($sx + 2) ($barTop + $barH + 17) $bw 2)) }
    }
}

function Draw-All($g, [int]$W, [int]$H) {
    $g.Clear([CoreUi.Theme]::Bg)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $pad = 10

    # --- 見出し: 平均 ---
    $hostLps = @($script:Plan.Host); $guestLps = @($script:Plan.Guest)
    $allLps = @($script:Stat.Keys)
    $winAvg = if ($hostLps.Count -gt 0) { $script:RootTotal / $hostLps.Count } else { Get-Avg $allLps "Win" }
    $vmAvg  = if ($script:VpOk -and $guestLps.Count -gt 0) { $script:VmTotal / $guestLps.Count } elseif ($guestLps.Count -gt 0) { Get-Avg $guestLps "Vm" } else { Get-Avg $allLps "Vm" }
    if ($hostLps.Count -gt 0) {
        $l1 = "Windows : 平均 {0:N0}%   (割り当て CPU {1} / {2} スレッド)" -f $winAvg, (ConvertTo-LpRangeText $hostLps), $hostLps.Count
    } else {
        $l1 = "Windows : 平均 {0:N0}%   (割り当てなし = 全コア)" -f $winAvg
    }
    if ($guestLps.Count -gt 0) {
        $l2 = "{0} : 平均 {1:N0}%   (割り当て CPU {2} / {3} スレッド)   状態: {4}" -f $VMName, $vmAvg, (ConvertTo-LpRangeText $guestLps), $guestLps.Count, $script:Mem.VmState
    } else {
        $l2 = "{0} : 平均 {1:N0}%   状態: {2}" -f $VMName, $vmAvg, $script:Mem.VmState
    }
    $g.DrawString($l1, $FontBody, $BrWinText, (PointF $pad 4))
    $g.DrawString($l2, $FontBody, $BrVmText,  (PointF $pad 22))
    Draw-Legend $g ([Math]::Max($pad, $W - 400)) 8
    $top = 46
    if (-not $script:lpName) {
        $g.DrawString("ハイパーバイザーの性能カウンターが見つかりません (Hyper-V が無効か、カウンターの破損)。", $FontBody, $BrBad, (PointF $pad 44))
        $top = 66
    }
    $avail = $H - $top - $pad
    $gridW = $W - 2 * $pad

    if ($hostLps.Count -gt 0 -and $guestLps.Count -gt 0) {
        # --- 区画ごとに分けて、論理 CPU を番号順に (P/E は色付きの印で区別) ---
        $allLpNums = @((Get-LpList) | ForEach-Object { $_.Lp })
        $other = @($allLpNums | Where-Object { ($hostLps -notcontains $_) -and ($guestLps -notcontains $_) })
        $secs = @()
        $secs += ,@(("Windows 用  (CPU {0} / {1} スレッド)" -f (ConvertTo-LpRangeText $hostLps), $hostLps.Count), $hostLps, "host")
        $secs += ,@(("{0} 用  (CPU {1} / {2} スレッド)" -f $VMName, (ConvertTo-LpRangeText $guestLps), $guestLps.Count), $guestLps, "guest")
        if ($other.Count -gt 0) { $secs += ,@(("割り当て外  (CPU {0})" -f (ConvertTo-LpRangeText $other)), $other, "") }
        # どの区画も同じ列数で並べ、棒の幅と高さをそろえる (Edge Box 用も Windows 用と同じ縦長の棒にする)。
        # 高さは各区画の行数に応じて配分する (見出し 22 px + 行数 × 1 行の高さ)
        $maxN = 1; foreach ($sec in $secs) { $maxN = [Math]::Max($maxN, $sec[1].Count) }
        $cols = [Math]::Max(1, [Math]::Min($maxN, [int]($gridW / 54)))
        $rowsAll = 0; foreach ($sec in $secs) { $rowsAll += [Math]::Max(1, [int][Math]::Ceiling($sec[1].Count / $cols)) }
        $rowH = [Math]::Max(80, [int](($avail - 22 * $secs.Count) / $rowsAll))
        $y = $top
        foreach ($sec in $secs) {
            $hh = 22 + [Math]::Max(1, [int][Math]::Ceiling($sec[1].Count / $cols)) * $rowH
            Draw-LpGrid $g $pad $y $gridW $hh $sec[0] $sec[1] $sec[2] $cols
            $y += $hh
        }
    } else {
        $g.DrawString("割り当ての計画がありません (設定コンソールで CPU コアを分割すると、区画ごとに表示します)", $FontBody, $BrGray, (PointF $pad $top))
        Draw-LpGrid $g $pad ($top + 22) $gridW ($avail - 22) "" $null ""
    }
}
