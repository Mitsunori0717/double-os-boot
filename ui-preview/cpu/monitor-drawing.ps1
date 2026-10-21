

# 色: 青 = Windows / 橙 = Edge Box / 明るい灰 = ハイパーバイザー内部。背景は灰色 (#616061)。
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
# P / E の印は明るさで分ける (橙・青は Windows / Edge Box の色なので使わない)
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
# Windows 用の区画で Edge Box が動いた、または Edge Box 用の区画で Windows が動いた論理 CPU は、使用率を赤で出す
function Draw-LpGrid($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title, $only, [string]$side) {
    $lps = @(Get-LpList)
    if ($only) { $lps = @($lps | Where-Object { $only -contains $_.Lp }) }
    if ($title) {
        # 区画の見出し: 左に区画の色の印 (青 = Windows 用 / 橙 = Edge Box 用)
        $mark = if ($side -eq "host") { $BrWin } elseif ($side -eq "guest") { $BrVm } else { $BrGray }
        $g.FillRectangle($mark, (Rect $x ($y + 4) 3 12))
        $g.DrawString($title, $FontTitle, $BrText, (PointF ($x + 9) $y))
        $y += 22; $h -= 22
    }
    if ($lps.Count -eq 0) { $g.DrawString("(該当する CPU なし)", $FontBody, $BrGray, (PointF $x $y)); return }
    $minSlot = 54
    $cols = [Math]::Max(1, [Math]::Min($lps.Count, [int]($w / $minSlot)))
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
        # 縦棒 (枠の色 = 割り当ての計画: 青 = Windows 用 / 橙 = Edge Box 用)
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

function Draw-Memory($g, [int]$x, [int]$y, [int]$w, [int]$h) {
    $m = $script:Mem
    $tot = [double]$m.TotalGB
    $g.DrawString("メモリ", $FontTitle, $BrText, (PointF $x $y))
    $barY = $y + 22; $barH = 18
    $g.FillRectangle($BrFree, (Rect $x $barY $w $barH))
    if ($tot -gt 0) {
        # Edge Box の取り分は、渡している量 (割り当て) で数える。
        # vmmem として見えない構成があるため、見えない場合も割り当て量で色分けする
        $vmGB = [double]$m.VmGB
        if ($vmGB -le 0.1 -and $m.VmState -eq "Running") { $vmGB = [double]$m.VmAssignedGB }
        # 使用中の合計から Edge Box の分を引いたものが Windows の分
        $winGB = [Math]::Max(0.0, ($tot - $m.FreeGB) - $vmGB)
        $wWin = [int]($w * $winGB / $tot)
        $wVm  = [int]($w * $vmGB / $tot)
        $g.FillRectangle($BrWinBar, (Rect $x $barY $wWin $barH))
        $g.FillRectangle($BrVmBar,  (Rect ($x + $wWin) $barY $wVm $barH))
        $g.DrawRectangle($PenNone, (Rect $x $barY $w $barH))
        # 1 行目: PC 全体の内訳 (Windows / Edge Box / 空き) とメモリの逼迫具合
        $winPct = if ($tot -gt 0) { 100.0 * ($tot - $m.FreeGB) / $tot } else { 0.0 }
        $l1 = "PC 全体 {0:N1} GB    Windows {1:N1} GB    {2} {3:N1} GB    空き {4:N1} GB (物理 {5:N0}% 使用)    コミット率 {6:N0}%    ページング {7:N0} /秒" -f `
            $tot, $winGB, $VMName, $vmGB, $m.FreeGB, $winPct, $m.WinCommitPct, $m.WinPagesPerSec
        $brL1 = $BrText
        if ($m.WinCommitPct -ge 90 -or $m.WinPagesPerSec -ge 1000) { $brL1 = $BrBad }
        $g.DrawString($(if ($brL1 -eq $BrBad) { "△ " + $l1 } else { $l1 }), $FontBody, $brL1, (PointF $x ($barY + $barH + 4)))
        # 2 行目: Edge Box 内部 (統合サービスの報告があるときだけ表示する。報告が無ければ割り当てだけ)
        if ($m.VmReported) {
            $usedIn = [Math]::Max(0.0, $m.VmVisibleGB - $m.VmAvailGB)
            $inPct = if ($m.VmVisibleGB -gt 0) { 100.0 * $usedIn / $m.VmVisibleGB } else { 0.0 }
            $l2 = "{0} 割り当て {1:N1} GB    内部で使用中 {2:N1} GB / 内部の空き {3:N1} GB ({4:N0}% 使用)    要求 {5:N1} GB    圧力 {6:N0}%    状態 {7}" -f `
                $VMName, $m.VmAssignedGB, $usedIn, $m.VmAvailGB, $inPct, $m.VmDemandGB, $m.VmPressure, $(if ($m.VmMemStatus) { $m.VmMemStatus } else { "-" })
            $brL2 = if ($m.VmPressure -ge 90 -or $m.VmMemStatus -match 'Low|Warning') { $BrBad } else { $BrText }
        } else {
            $l2 = "{0} 割り当て {1:N1} GB    (量の変更は『CPU コア割り当て』画面の「メモリの割り当て」から)" -f `
                $VMName, $m.VmAssignedGB
            $brL2 = $BrGray
        }
        $g.DrawString($(if ($brL2 -eq $BrBad) { "△ " + $l2 } else { $l2 }), $FontBody, $brL2, (PointF $x ($barY + $barH + 22)))
    } else {
        $g.DrawString("メモリ情報を取得できません", $FontBody, $BrText, (PointF $x ($barY + $barH + 4)))
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
        $l1 = "Windows : 平均 {0:N0}%   (割り当て CPU {1} / {2} 論理)" -f $winAvg, (ConvertTo-LpRangeText $hostLps), $hostLps.Count
    } else {
        $l1 = "Windows : 平均 {0:N0}%   (割り当てなし = 全コア)" -f $winAvg
    }
    if ($guestLps.Count -gt 0) {
        $l2 = "{0} : 平均 {1:N0}%   (割り当て CPU {2} / {3} 論理)   状態: {4}" -f $VMName, $vmAvg, (ConvertTo-LpRangeText $guestLps), $guestLps.Count, $script:Mem.VmState
    } else {
        $l2 = "{0} : 平均 {1:N0}%   状態: {2}" -f $VMName, $vmAvg, $script:Mem.VmState
    }
    $g.DrawString($l1, $FontBody, $BrWinText, (PointF $pad 4))
    $g.DrawString($l2, $FontBody, $BrVmText,  (PointF $pad 22))
    Draw-Legend $g ([Math]::Max($pad, $W - 400)) 8
    if (-not $script:lpName) {
        $g.DrawString("ハイパーバイザーの性能カウンターが見つかりません (Hyper-V が無効か、カウンターの破損)。", $FontBody, $BrBad, (PointF $pad 44))
    }

    # --- コア構成の見出し (P コア 8 / E コア 12 のように種類ごとの数と CPU 番号) ---
    $pc = @($script:Cores | Where-Object { $_.Kind -eq "P" }); $ec = @($script:Cores | Where-Object { $_.Kind -eq "E" })
    $lpTotal = 0; foreach ($c in $script:Cores) { $lpTotal += $c.Lps.Count }
    if ($script:Hybrid) {
        $pl = @(); foreach ($c in $pc) { $pl += $c.Lps }
        $el = @(); foreach ($c in $ec) { $el += $c.Lps }
        $l3 = "コア構成: P コア {0} (CPU {1}) / E コア {2} (CPU {3})   合計 {4} コア / {5} スレッド" -f `
              $pc.Count, (ConvertTo-LpRangeText $pl), $ec.Count, (ConvertTo-LpRangeText $el), $script:Cores.Count, $lpTotal
    } else {
        $l3 = "コア構成: {0} コア / {1} スレッド" -f $script:Cores.Count, $lpTotal
    }
    $g.DrawString($l3, $FontBody, $BrText, (PointF $pad 40))

    # --- 分離の状態: 「Edge Box が Windows 用コアで動いた割合」と「Windows が Edge Box 用コアで動いた割合」 ---
    $memH = 90
    if ($hostLps.Count -gt 0 -and $guestLps.Count -gt 0) {
        $leakVm  = $script:LeakVm    # Edge Box が Edge Box 用コアの外で動いた量 (VP 合計と LP 合計の突き合わせ。固定が効いていれば 0)
        $leakWin = $script:LeakWin   # Edge Box 用コアで動いた Edge Box 以外 (minroot が効いていれば 0)
        $mixed = ($leakVm -gt 0.5 -or $leakWin -gt 0.5)
        $how = if ($script:VpOk) { "直近 {0} 秒" -f [Math]::Min($script:LeakWindow, [Math]::Max(1, $script:LeakVmHist.Count)) } else { "概算" }
        $l4 = "分離の状態: {0}   Edge Box が Windows 用コアで動いた割合 {1:N1}%  /  Windows が Edge Box 用コアで動いた割合 {2:N1}%   ({3})" -f `
              $(if ($mixed) { "△ 混ざっています" } else { "○ 混ざっていません" }), $leakVm, $leakWin, $how
        $g.DrawString($l4, $FontTitle, $(if ($mixed) { $BrBad } else { $BrGood }), (PointF $pad 58))
        $cs = Get-ContainState
        $g.DrawString($cs.Text, $FontBody, $(if ($cs.Ok) { $BrGood } else { $BrBad }), (PointF $pad 76))

        # --- 区画ごとに分けて、論理 CPU を番号順に (P/E は色付きの印で区別) ---
        $top = 98
        $avail = $H - $top - $memH - $pad
        $allLpNums = @((Get-LpList) | ForEach-Object { $_.Lp })
        $other = @($allLpNums | Where-Object { ($hostLps -notcontains $_) -and ($guestLps -notcontains $_) })
        $secs = @()
        $secs += ,@(("Windows 用  (CPU {0} / {1} 論理)" -f (ConvertTo-LpRangeText $hostLps), $hostLps.Count), $hostLps, "host")
        $secs += ,@(("{0} 用  (CPU {1} / {2} 論理)" -f $VMName, (ConvertTo-LpRangeText $guestLps), $guestLps.Count), $guestLps, "guest")
        if ($other.Count -gt 0) { $secs += ,@(("割り当て外  (CPU {0})" -f (ConvertTo-LpRangeText $other)), $other, "") }
        # 区画の高さは論理 CPU の数に応じて配分 (最低 110 px)
        $tot = 0; foreach ($sec in $secs) { $tot += [Math]::Max(4, $sec[1].Count) }
        $y = $top
        foreach ($sec in $secs) {
            $hh = [int]($avail * [Math]::Max(4, $sec[1].Count) / $tot)
            if ($hh -lt 110) { $hh = 110 }
            Draw-LpGrid $g $pad $y ($W - 2 * $pad) $hh $sec[0] $sec[1] $sec[2]
            $y += $hh
        }
    } else {
        $g.DrawString("分離の状態: 割り当ての計画がありません (設定コンソールで CPU コアを分割すると、区画ごとに表示します)", $FontBody, $BrGray, (PointF $pad 58))
        $top = 80
        $avail = $H - $top - $memH - $pad
        Draw-LpGrid $g $pad $top ($W - 2 * $pad) $avail "" $null ""
    }

    # --- メモリ ---
    $g.DrawLine($PenRule, $pad, ($H - $memH - 6), ($W - $pad), ($H - $memH - 6))
    Draw-Memory $g $pad ($H - $memH) ($W - 2 * $pad) ($memH - $pad)
}

