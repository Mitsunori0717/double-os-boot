<#
.SYNOPSIS
    EdgeBox 監視 — 各コアの負荷「誰が使っているか」と、メモリの使用量をリアルタイムで表示します。

.DESCRIPTION
    ハイパーバイザーの性能カウンターを毎秒読み、論理 CPU ごとに
        EdgeBox の実行 (緑) / Windows 自身の実行 (青) / ハイパーバイザー内部 (灰)
    を積み上げ棒で描きます。タスクマネージャーでは EdgeBox の分が「vmmem」という
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
    CPU の表示は管理者でなくてもできます。EdgeBox の状態とメモリ割り当ての取得には
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
$ContainFile  = Join-Path $PSScriptRoot "cpu-contain-status.json"   # 締め出しの常駐 (CpuPartition-Watch) が書く状態
$FullFile     = Join-Path $PSScriptRoot "cpu-full-status.json"      # full モードの起動タスク (CpuPartition-Boot) が書く状態

# -VMName を明示していない場合は、保存済み計画の 登録名を使う
if (-not $PSBoundParameters.ContainsKey("VMName") -and (Test-Path $ConfigFile)) {
    try {
        $c0 = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c0.VMName) { $VMName = [string]$c0.VMName }
    } catch { }
}
# その名前の登録が無ければ (名前を変えた等)、EdgeBox の物理ディスクを持つ登録か 1 つしかない登録を使う
$script:VmLookupError = ""
try {
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        if (-not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
            $all = @(Get-VM -ErrorAction SilentlyContinue)
            $found = @($all | Where-Object { @(Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.DiskNumber }).Count -gt 0 })
            if ($found.Count -eq 1) { $VMName = $found[0].Name } elseif ($all.Count -eq 1) { $VMName = $all[0].Name }
        }
    } else { $script:VmLookupError = "Hyper-V のコマンドが使えません" }
} catch { $script:VmLookupError = $_.Exception.Message }

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

# CPU トポロジの検出 (P コア / E コア / SMT を CPU 自身から取得。設定コンソールと同じ方法)
if (-not ("CpuTopoApi" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class CpuTopoApi {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetLogicalProcessorInformationEx(int RelationshipType, IntPtr Buffer, ref uint ReturnedLength);

    // 物理コアごとに "効率クラス|論理CPU番号,..." を ";" 区切りで返す。
    // 効率クラスは CPU が申告する値で、大きいほど高性能 (P コア)。
    public static string GetCoreMap() {
        uint len = 0;
        GetLogicalProcessorInformationEx(0, IntPtr.Zero, ref len);   // 0 = RelationProcessorCore
        if (len == 0) { return ""; }
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetLogicalProcessorInformationEx(0, buf, ref len)) { return ""; }
            StringBuilder sb = new StringBuilder();
            int offset = 0;
            while (offset < (int)len) {
                IntPtr p = new IntPtr(buf.ToInt64() + offset);
                int rel  = Marshal.ReadInt32(p, 0);
                int size = Marshal.ReadInt32(p, 4);
                if (size <= 0) { break; }
                if (rel == 0) {
                    byte eff = Marshal.ReadByte(p, 9);
                    short groupCount = Marshal.ReadInt16(p, 30);
                    List<string> lps = new List<string>();
                    for (int g = 0; g < groupCount; g++) {
                        int off = 32 + g * (IntPtr.Size + 8);        // GROUP_AFFINITY のサイズ
                        long mask = (IntPtr.Size == 8)
                            ? Marshal.ReadInt64(p, off)
                            : (long)(uint)Marshal.ReadInt32(p, off);
                        short grp = Marshal.ReadInt16(p, off + IntPtr.Size);
                        for (int b = 0; b < 64; b++) {
                            if (((mask >> b) & 1L) != 0) { lps.Add((grp * 64 + b).ToString()); }
                        }
                    }
                    if (lps.Count > 0) {
                        sb.Append(eff).Append('|').Append(string.Join(",", lps.ToArray())).Append(';');
                    }
                }
                offset += size;
            }
            return sb.ToString();
        } finally {
            Marshal.FreeHGlobal(buf);
        }
    }
}
'@
}

# コア構成: まず CPU 自身から取得 (P/E の区別付き)。取れなければ設定コンソールが保存した
# cpu-topology.json、それも無ければ 1 論理 = 1 コア とみなす
function Get-Cores {
    $raw = @()
    try {
        $map = [CpuTopoApi]::GetCoreMap()
        foreach ($entry in ($map -split ';')) {
            if (-not $entry) { continue }
            $parts = $entry -split '\|'
            if ($parts.Count -lt 2) { continue }
            $lps = @($parts[1] -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
            if ($lps.Count -gt 0) { $raw += [pscustomobject]@{ Eff = [int]$parts[0]; Lps = $lps; Kind = "C"; Label = "" } }
        }
    } catch { $raw = @() }
    # minroot 適用中は Windows から EdgeBox 用の CPU が見えないため、設定コンソールが保存した
    # 構成 (cpu-topology.json) の方が多ければそちらを使う
    $liveLps = 0; foreach ($r in $raw) { $liveLps += $r.Lps.Count }
    $snapRaw = @()
    if (Test-Path $SnapshotFile) {
        try {
            $json = Get-Content $SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @()
            if ($json.PSObject.Properties["Cores"]) {
                # 新形式: この PC の CPU 名と一致するときだけ使う (別 PC の構成を持ち込んだ場合の誤表示を防ぐ)
                $cpuName = ""
                try { $cpuName = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()) } catch { }
                if ([string]$json.Cpu -eq $cpuName) { $items = @($json.Cores) }
            } else {
                # 旧形式: 論理 CPU 数が一致するときだけ使う
                $items = @($json)
                $n = 0; foreach ($r in $items) { $n += @([int[]]$r.Lps).Count }
                if ($n -ne [Environment]::ProcessorCount) { $items = @() }
            }
            foreach ($r in $items) {
                $lps = @([int[]]$r.Lps)
                if ($lps.Count -gt 0) { $snapRaw += [pscustomobject]@{ Eff = [int]$r.Eff; Lps = $lps; Kind = "C"; Label = "" } }
            }
        } catch { $snapRaw = @() }
    }
    $snapLps = 0; foreach ($r in $snapRaw) { $snapLps += $r.Lps.Count }
    if ($snapLps -gt $liveLps) { $raw = $snapRaw }
    if ($raw.Count -eq 0) {
        foreach ($i in 0..([Environment]::ProcessorCount - 1)) {
            $raw += [pscustomobject]@{ Eff = 0; Lps = @($i); Kind = "C"; Label = "" }
        }
    }
    # それでも割り当ての計画にある CPU 番号が足りなければ (保存した構成が無いまま minroot になった)、
    # 隠れている CPU を 1 つずつ E コア相当として補う
    try {
        $plan0 = $null
        if (Test-Path $ConfigFile) { $plan0 = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        $have = @{}; foreach ($r in $raw) { foreach ($l in $r.Lps) { $have[[int]$l] = $true } }
        $minEff = ($raw | ForEach-Object { $_.Eff } | Measure-Object -Minimum).Minimum
        foreach ($l in @([int[]]$plan0.HostLps) + @([int[]]$plan0.GuestLps)) {
            if (-not $have.ContainsKey([int]$l)) { $raw += [pscustomobject]@{ Eff = [int]$minEff; Lps = @([int]$l); Kind = "C"; Label = "" }; $have[[int]$l] = $true }
        }
    } catch { }
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
    # 注意: ",$raw" で返すと呼び出し側の @() で二重に包まれる (1 要素の配列の中に配列) ため、そのまま返す
    return $raw
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

# Windows 側の締め出し (常駐 CpuPartition-Watch) の状態。戻り値: @{ Text; Ok }
function Get-ContainState {
    $plan = $script:Plan
    if (-not $plan -or $plan.Mode -ne "runtime") {
        if ($plan -and $plan.Mode -eq "full") {
            $fs = $null
            try { if (Test-Path $FullFile) { $fs = Get-Content $FullFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
            if (-not $fs) { return @{ Text = "完全分割 (full): 起動タスクの記録がまだありません (再起動待ち)"; Ok = $false } }
            if ($fs.Bound) { return @{ Text = ("完全分割 (full): 成立 — Windows は CPU {0} に封じ込め (minroot) / EdgeBox は CPU {1} に固定 (CPU グループ)" -f $fs.HostLps, $fs.GuestLps); Ok = $true } }
            if (-not $fs.MinrootOk) { return @{ Text = ("完全分割 (full): 未反映 — " + $fs.Message); Ok = $false } }
            return @{ Text = ("完全分割 (full): 準分割 — EdgeBox の固定が効いていません (" + $fs.Message + ")"); Ok = $false }
        }
        return @{ Text = "Windows の締め出し: 未設定 (設定コンソールで割り当てを適用すると始まります)"; Ok = $false }
    }
    $st = $null
    try { if (Test-Path $ContainFile) { $st = Get-Content $ContainFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    if (-not $st) { return @{ Text = "Windows の締め出し: 常駐の記録がありません (設定コンソールで runtime を適用し直してください)"; Ok = $false } }
    $age = 9999
    try { $age = ((Get-Date) - [datetime]$st.At).TotalSeconds } catch { }
    $unp = @($st.Unpinnable)
    if ($age -gt 30) {
        return @{ Text = ("Windows の締め出し: 停止中? (最終確認 {0} / {1} 秒前)。2 分以内に自動で再開します" -f $st.At, [int]$age); Ok = $false }
    }
    return @{ Text = ("Windows の締め出し: 動作中 — Windows のプロセス {0} 個を CPU {1} に固定 (固定不可: {2})" -f
        $st.Contained, $st.HostLps, $(if ($unp.Count -gt 0) { $unp -join ", " } else { "なし" })); Ok = $true }
}

# ハイパーバイザーの性能カウンター (-Verify と同じ考え方)
#   LP の Guest = ルート VP (Windows 自身) + EdgeBox の VP なので、同番号のルート VP を引いて EdgeBox 分を出す
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
    # メモリ: PC 全体 = Windows 使用中 + EdgeBox 使用中 (vmmem の実メモリ) + 空き
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
    # EdgeBox の状態と割り当て (重いので 3 回に 1 回)
    if (($script:TickNo % 3) -eq 1) {
        try {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
            $script:Mem.VmState = [string]$vm.State
            $asg = [double]$vm.MemoryAssigned / 1GB
            if ($asg -le 0) { try { $asg = [double](Get-VMMemory -VMName $VMName -ErrorAction Stop).Startup / 1GB } catch { } }
            $script:Mem.VmAssignedGB = $asg
        } catch { $script:Mem.VmState = "取得不可 (" + $(if ($script:VmLookupError) { $script:VmLookupError } else { $_.Exception.Message }) + ")" }
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
$BrP     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 110, 0))   # P コアの印
$BrE     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 130, 160))   # E コアの印
$BrBad   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 30, 30))   # 混ざっている印
$BrGood  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 130, 60))    # 分かれている印
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
# $only = 表示する論理 CPU 番号の一覧 ($null = 全部)。$side = "host" (Windows 用) / "guest" (EdgeBox 用) / ""
# Windows 用の区画で EdgeBox が動いた、または EdgeBox 用の区画で Windows が動いた論理 CPU は、使用率を赤で出す
function Draw-LpGrid($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title, $only, [string]$side) {
    $lps = @(Get-LpList)
    if ($only) { $lps = @($lps | Where-Object { $only -contains $_.Lp }) }
    if ($title) {
        $g.DrawString($title, $FontTitle, $BrText, (PointF $x $y))
        $y += 20; $h -= 20
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
        $g.DrawString(("CPU {0}" -f $e.Lp), $FontTitle, $BrText, (PointF ($sx + 2) $sy))
        $brKind = if ($e.Kind -eq "P") { $BrP } elseif ($e.Kind -eq "E") { $BrE } else { $BrGray }
        $g.DrawString($e.Core, $FontSmall, $brKind, (PointF ($sx + 3) ($sy + 16)))
        # 縦棒 (枠の色 = 割り当ての計画: 青 = Windows 用 / 緑 = EdgeBox 用)
        $barTop = $sy + 30
        $barH = $rowH - 30 - 20
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
        if ($hVm -gt 0)  { $yy -= $hVm;  $g.FillRectangle($BrVm,  (Rect $bx $yy $bw $hVm)) }
        if ($hWin -gt 0) { $yy -= $hWin; $g.FillRectangle($BrWin, (Rect $bx $yy $bw $hWin)) }
        if ($hHv -gt 0)  { $yy -= $hHv;  $g.FillRectangle($BrHv,  (Rect $bx $yy $bw $hHv)) }
        # 下: 使用率 (常に表示)。区画に合わない側の使用が 1% を超えていれば赤 (混ざっている印)
        $brPct = $BrText
        if (($side -eq "host" -and $vm -gt 1.0) -or ($side -eq "guest" -and $win -gt 1.0)) { $brPct = $BrBad }
        $g.DrawString(("{0:N0}%" -f $total), $FontBody, $brPct, (PointF ($sx + 2) ($barTop + $barH + 2)))
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

    # --- 分離の状態: 「EdgeBox が Windows 用コアで動いた割合」と「Windows が EdgeBox 用コアで動いた割合」 ---
    $memH = 70
    if ($hostLps.Count -gt 0 -and $guestLps.Count -gt 0) {
        $leakVm  = Get-Avg $hostLps  "Vm"    # Windows 用コアに載った EdgeBox (物理固定が効いていれば 0)
        $leakWin = Get-Avg $guestLps "Win"   # EdgeBox 用コアに載った Windows (runtime モードでは少し出ることがある)
        $mixed = ($leakVm -gt 1.0 -or $leakWin -gt 1.0)
        $l4 = "分離の状態: {0}   EdgeBox が Windows 用コアで動いた割合 {1:N1}%  /  Windows が EdgeBox 用コアで動いた割合 {2:N1}%" -f `
              $(if ($mixed) { "△ 混ざっています" } else { "○ 混ざっていません" }), $leakVm, $leakWin
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
    Draw-Memory $g $pad ($H - $memH) ($W - 2 * $pad) ($memH - $pad)
}

# ============================================================ ウィンドウ

$form = New-Object System.Windows.Forms.Form
$form.Text = "$VMName 監視 — 各コアの負荷とメモリ"
$form.ClientSize = New-Object System.Drawing.Size(1120, 620)
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
