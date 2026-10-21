<#
.SYNOPSIS
    Edge Box 監視 — 各コアの負荷「誰が使っているか」をリアルタイムで表示します。

.DESCRIPTION
    ハイパーバイザーの性能カウンターを毎秒読み、論理 CPU ごとに
        Edge Box の実行 (橙) / Windows 自身の実行 (青) / ハイパーバイザー内部 (灰)
    を積み上げ棒で描きます。タスクマネージャーでは Edge Box の分が「vmmem」という
    1 つのプロセスにしか見えませんが、ここではコア単位で分かります。
    枠の色は CPU 割り当ての計画 (青 = Windows 用 / 橙 = Edge Box 用) です。

    ウィンドウの大きさは自由に変えられ、最小化してしまっておけます
    (最小化中は測定を休みます)。

.EXAMPLE
    .\cpu-monitor.ps1                    # 監視ウィンドウを開く
    .\cpu-monitor.ps1 -IntervalMs 2000   # 2 秒ごとに更新
    .\cpu-monitor.ps1 -TopMost           # 常に手前に表示

.NOTES
    CPU の表示は管理者でなくてもできます。Edge Box の状態の取得には
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

# 画面の見た目 (『CPU割り当て』と同じ配色・部品)。測定の処理は持たない
try {
    . (Join-Path $PSScriptRoot "cpu-ui-theme.ps1")
} catch {
    [System.Windows.Forms.MessageBox]::Show(("画面の部品 (cpu-ui-theme.ps1) を読み込めませんでした。update.cmd で更新してください。`n`n" + $_.Exception.Message),
        "Edge Box 監視", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

$ConfigFile   = Join-Path $PSScriptRoot "cpu-partition.json"
$SnapshotFile = Join-Path $PSScriptRoot "cpu-topology.json"
$FullFile     = Join-Path $PSScriptRoot "cpu-full-status.json"      # full モードの起動タスク (CpuPartition-Boot) が書く状態

# -VMName を明示していない場合は、保存済み計画の 登録名を使う
if (-not $PSBoundParameters.ContainsKey("VMName") -and (Test-Path $ConfigFile)) {
    try {
        $c0 = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c0.VMName) { $VMName = [string]$c0.VMName }
    } catch { }
}
# その名前の登録が無ければ (名前を変えた等)、Edge Box の物理ディスクを持つ登録か 1 つしかない登録を使う
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
    # minroot 適用中は Windows から Edge Box 用の CPU が見えないため、設定コンソールが保存した
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

# ハイパーバイザーの性能カウンター (-Verify と同じ考え方)
#   LP の Guest = ルート VP (Windows 自身) + Edge Box の VP なので、同番号のルート VP を引いて Edge Box 分を出す
$script:lpName = $null; $script:rvName = $null
$lpCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorLogicalProcessor" -ErrorAction SilentlyContinue | Select-Object -First 1
$rvCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorRootVirtualProcessor" -ErrorAction SilentlyContinue | Select-Object -First 1
$vpCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorVirtualProcessor" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lpCls) { $script:lpName = $lpCls.CimClassName }
if ($rvCls) { $script:rvName = $rvCls.CimClassName }
$script:vpName = $null
if ($vpCls) { $script:vpName = $vpCls.CimClassName }

# 仮想プロセッサ (VP) のカウンター: インスタンス名 "EdgeBox:Hv VP 0" のように登録名が付く
function Get-VpCounterMap([string]$ClassName, [string]$Name) {
    $map = @{}
    $script:OtherVpCount = 0
    if (-not $ClassName) { return $map }
    foreach ($x in @(Get-CimInstance -ClassName $ClassName -ErrorAction SilentlyContinue)) {
        $n = [string]$x.Name
        if ($n -like ($Name + ":*")) { $map[$n] = $x }
        elseif ($n -and $n -ne "_Total" -and $n -match ':') { $script:OtherVpCount++ }   # 他の登録 (別の VM) の実行単位
    }
    return $map
}
# full モードで Edge Box が Edge Box 用 CPU に固定済みか (起動タスクの記録)
function Test-FullBound {
    try {
        if (-not $script:Plan -or $script:Plan.Mode -ne "full") { return $false }
        if (-not (Test-Path $FullFile)) { return $false }
        $fs = Get-Content $FullFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]$fs.Bound
    } catch { return $false }
}

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
$script:Stat   = @{}            # 論理 CPU 番号 → @{ Vm; Win; Hv; G (LP の guest 合計) }
$script:prevLp = $null
$script:prevRv = $null
$script:prevVp = $null
# 分離の判定 (VP 合計と LP 合計の突き合わせ)。
# カウンターの種類ごとに読み取り時刻が数十 ms ずれるため、1 秒ごとの差には ± の揺れが出る。
# 揺れは連続する区間で打ち消し合う (前の区間の端の分が次の区間で戻る) ので、符号付きのまま
# 直近 60 秒分を足し合わせてから 0 で切る。真の漏れだけが残る
$script:VmTotal = 0.0; $script:RootTotal = 0.0; $script:VpOk = $false
$script:LeakVmHist = @(); $script:LeakWinHist = @()
$script:LeakWindow = 60
$script:LeakVm = 0.0; $script:LeakWin = 0.0
$script:LeakVmRaw = 0.0; $script:LeakWinRaw = 0.0
# 2 つの帳簿の読み取り時刻のずれは 60 秒の足し合わせでも完全には消えず、0.1% 程度の見かけの値が残ることがある。
# この値以下は測定のゆらぎとみなして 0.0 にする。真の漏れは桁が違う (固定が外れると数 % 出る) ので隠れない。
# 判定 (△ 混ざっています) は従来どおり 0.5% 超
$script:LeakDeadband = 0.3
$script:WinStructOk = $false   # Windows 側の実行単位が Edge Box 用 CPU に 1 つも無く、他の登録 (別の VM) も無い
$script:VmStructOk  = $false   # Edge Box が Edge Box 用 CPU に固定済み
$script:OtherVpCount = 0
$script:Mem    = @{ TotalGB = 0.0; WinGB = 0.0; VmGB = 0.0; FreeGB = 0.0; VmAssignedGB = 0.0; VmState = "?"
                    WinCommitPct = 0.0; WinPagesPerSec = 0.0                    # Windows のメモリ負荷 (コミット率・ページング)
                    VmReported = $false; VmVisibleGB = 0.0; VmAvailGB = 0.0    # Edge Box 内部 (統合サービスの報告)
                    VmDemandGB = 0.0; VmPressure = 0.0; VmMemStatus = ""; VmDynamic = $false }
$dmCls = Get-CimClass -ClassName "Win32_PerfFormattedData_*HyperVDynamicMemoryVM" -ErrorAction SilentlyContinue | Select-Object -First 1
$script:dmName = $null
if ($dmCls) { $script:dmName = $dmCls.CimClassName }
$script:LastErr = ""
$script:TickNo  = 0
# この画面自身の負荷 (自プロセスの CPU 時間の増分 / 経過時間。Windows が使える CPU 全体に対する %)
$script:SelfCpu = $null; $script:SelfAt = $null; $script:SelfPct = -1.0

function Sample {
    $script:TickNo++
    if ($script:lpName) {
        # LP と Edge Box の VP は続けて読む (2 つの帳簿の読み取り時刻のずれを最小にする)。ルート側はその後
        $lp = Get-CounterMap $script:lpName
        $vp = Get-VpCounterMap $script:vpName $VMName
        $rv = Get-CounterMap $script:rvName
        # Edge Box の再起動などで VP の帳簿がリセット (減少・入れ替わり) した区間は、突き合わせに使わない
        $reset = $false
        if ($script:prevVp) {
            $pk = (@($script:prevVp.Keys) | Sort-Object) -join ","; $ck = (@($vp.Keys) | Sort-Object) -join ","
            if ($pk -ne $ck) { $reset = $true }
            else { foreach ($k in @($vp.Keys)) { if ([double]$vp[$k].PercentGuestRunTime -lt [double]$script:prevVp[$k].PercentGuestRunTime) { $reset = $true } } }
        }
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
                $new[$i] = @{ Vm = [Math]::Max(0.0, $guest - $win); Win = [Math]::Min($guest, $win); Hv = [Math]::Max(0.0, $total - $guest); G = $guest }
            }
            # --- 分離の判定は「合計」で行う ---
            # LP ごとの「guest − 同じ番号のルート VP」は、ルート VP が LP と 1:1 で固定されていても正確にならない。
            # LP の帳簿とルート VP の帳簿は別々に読むため読み取り時刻がずれ、毎秒の差を 0 で切ると正の偏りが残り、
            # 見かけ上の「Edge Box 実行」が出るため。そこで、Edge Box の VP の合計実行時間と Edge Box 用 LP の guest 合計を
            # 突き合わせる: Edge Box 用 LP には (minroot で) Windows は載れないので、
            #   Edge Box が Edge Box 用コアの外で動いた量 = Edge Box VP 合計 − Edge Box 用 LP の guest 合計
            #   Windows が Edge Box 用コアで動いた量     = Edge Box 用 LP の guest 合計 − Edge Box VP 合計
            $vmTot = 0.0; $rootTot = 0.0; $vpOk = $false
            if ($script:prevVp -and $vp.Count -gt 0) {
                foreach ($k in @($vp.Keys)) {
                    if ($script:prevVp.ContainsKey($k)) { $vmTot += Get-DeltaPct $script:prevVp[$k] $vp[$k] "PercentGuestRunTime"; $vpOk = $true }
                }
            }
            foreach ($i in @($rv.Keys)) {
                if ($script:prevRv -and $script:prevRv.ContainsKey($i)) { $rootTot += Get-DeltaPct $script:prevRv[$i] $rv[$i] "PercentGuestRunTime" }
            }
            $script:VmTotal = $vmTot; $script:RootTotal = $rootTot; $script:VpOk = $vpOk
            $hostLps = @($script:Plan.Host); $guestLps = @($script:Plan.Guest)
            if ($hostLps.Count -gt 0 -and $guestLps.Count -gt 0) {
                # 構造上の確認: Windows 側の実行単位は Windows 用 CPU の分しか無いか / 他の登録 (別の VM) は無いか / Edge Box は固定済みか
                $rootOnGuest = 0; foreach ($i in @($rv.Keys)) { if ($guestLps -contains [int]$i) { $rootOnGuest++ } }
                $script:WinStructOk = ($rv.Count -gt 0 -and $rootOnGuest -eq 0 -and $script:OtherVpCount -eq 0)
                $script:VmStructOk  = (Test-FullBound)
                $gOnGuest = 0.0; foreach ($l in $guestLps) { if ($new.ContainsKey([int]$l)) { $gOnGuest += [double]$new[[int]$l].G } }
                $gOnHost  = 0.0; foreach ($l in $hostLps)  { if ($new.ContainsKey([int]$l)) { $gOnHost  += [double]$new[[int]$l].G } }
                if ($vpOk) {
                    $leakVmTot  = $vmTot - $gOnGuest      # Edge Box が Edge Box 用コアの外で動いた量 (LP% の合計。符号付き)
                    $leakWinTot = $gOnGuest - $vmTot      # Windows (など Edge Box 以外) が Edge Box 用コアで動いた量 (符号付き)
                } else {
                    # VP カウンターが無い環境は従来どおり LP ごとの差し引きを合計する
                    $leakVmTot = 0.0;  foreach ($l in $hostLps)  { if ($new.ContainsKey([int]$l)) { $leakVmTot  += [double]$new[[int]$l].Vm } }
                    $leakWinTot = 0.0; foreach ($l in $guestLps) { if ($new.ContainsKey([int]$l)) { $leakWinTot += [double]$new[[int]$l].Win } }
                }
                # 表示用: LP ごとの色分けは合計に合わせて按分する (合計が 0 なら Windows 用 LP の guest は全部 Windows の実行)
                $rawVm = 0.0;  foreach ($l in $hostLps)  { if ($new.ContainsKey([int]$l)) { $rawVm  += [double]$new[[int]$l].Vm } }
                $rawWin = 0.0; foreach ($l in $guestLps) { if ($new.ContainsKey([int]$l)) { $rawWin += [double]$new[[int]$l].Win } }
                # 直近 60 秒分を符号付きで足してから 0 で切る (読み取り時刻のずれによる揺れは打ち消し合う)
                # 注意: 配列に数値を足すときは両方を @() で包む (1 要素だとスカラーになり、数値の足し算になってしまう)
                if (-not $reset) {
                    $script:LeakVmHist  = @(@($script:LeakVmHist)  + @([double]$leakVmTot)  | Select-Object -Last $script:LeakWindow)
                    $script:LeakWinHist = @(@($script:LeakWinHist) + @([double]$leakWinTot) | Select-Object -Last $script:LeakWindow)
                }
                $n = [Math]::Max(1, $script:LeakVmHist.Count)
                $script:LeakVm  = [Math]::Max(0.0, [double](($script:LeakVmHist  | Measure-Object -Sum).Sum) / $n / $hostLps.Count)
                $script:LeakWin = [Math]::Max(0.0, [double](($script:LeakWinHist | Measure-Object -Sum).Sum) / $n / $guestLps.Count)
                $script:LeakVmRaw = $script:LeakVm; $script:LeakWinRaw = $script:LeakWin
                # ゆらぎの上限以下は 0.0 にする (帳簿の読み取り時刻のずれによる見かけの値)
                if ($script:LeakVm  -le $script:LeakDeadband) { $script:LeakVm  = 0.0 }
                if ($script:LeakWin -le $script:LeakDeadband) { $script:LeakWin = 0.0 }
                # 表示用: LP ごとの色分けは、この 60 秒平均の漏れ量に合わせて按分する (漏れ 0 なら Windows 用 LP の guest は全部 Windows)
                $leakVmNow  = $script:LeakVm  * $hostLps.Count
                $leakWinNow = $script:LeakWin * $guestLps.Count
                $fVm  = if ($rawVm  -gt 0) { [Math]::Min(1.0, $leakVmNow  / $rawVm) }  else { 0.0 }
                $fWin = if ($rawWin -gt 0) { [Math]::Min(1.0, $leakWinNow / $rawWin) } else { 0.0 }
                foreach ($l in $hostLps) {
                    if (-not $new.ContainsKey([int]$l)) { continue }
                    $e = $new[[int]$l]; $v = [double]$e.Vm * $fVm
                    if ($rawVm -le 0 -and $leakVmNow -gt 0) { $v = $leakVmNow / $hostLps.Count }
                    $e.Vm = $v; $e.Win = [Math]::Max(0.0, [double]$e.G - $v)
                }
                foreach ($l in $guestLps) {
                    if (-not $new.ContainsKey([int]$l)) { continue }
                    $e = $new[[int]$l]; $w = [double]$e.Win * $fWin
                    if ($rawWin -le 0 -and $leakWinNow -gt 0) { $w = $leakWinNow / $guestLps.Count }
                    $e.Win = $w; $e.Vm = [Math]::Max(0.0, [double]$e.G - $w)
                }
            }
            $script:Stat = $new
        }
        $script:prevLp = $lp
        $script:prevRv = $rv
        $script:prevVp = $vp
    }
    # メモリ: PC 全体 = Windows 使用中 + Edge Box 使用中 (vmmem の実メモリ) + 空き
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $totGB  = [double]$os.TotalVisibleMemorySize / 1MB      # KB → GB
        $freeGB = [double]$os.FreePhysicalMemory / 1MB
        $vmWs = 0.0
        foreach ($p in @(Get-Process -Name "vmmem*" -ErrorAction SilentlyContinue)) {
            $vmWs += [double]$p.WorkingSet64
        }
        $vmGB = $vmWs / 1GB
        $script:Mem.TotalGB = $totGB
        $script:Mem.FreeGB  = $freeGB
        $script:Mem.VmGB    = $vmGB
        $script:Mem.WinGB   = [Math]::Max(0.0, ($totGB - $freeGB) - $vmGB)
        # Windows のメモリ負荷: コミット率 (仮想メモリの使い切り具合) とページング (ディスクへの退避の激しさ)
        try {
            $pm = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop | Select-Object -First 1
            $script:Mem.WinCommitPct   = [double]$pm.PercentCommittedBytesInUse
            $script:Mem.WinPagesPerSec = [double]$pm.PagesPersec
        } catch { }
    } catch { }
    # Edge Box の状態と割り当て (重いので 3 回に 1 回)
    if (($script:TickNo % 3) -eq 1) {
        try {
            $vm = Get-VM -Name $VMName -ErrorAction Stop
            $script:Mem.VmState = [string]$vm.State
            $asg = [double]$vm.MemoryAssigned / 1GB
            if ($asg -le 0) { try { $asg = [double](Get-VMMemory -VMName $VMName -ErrorAction Stop).Startup / 1GB } catch { } }
            $script:Mem.VmAssignedGB = $asg
            # Edge Box 内部のメモリ: Edge Box が Hyper-V の統合サービス (動的メモリの報告) で知らせてくる値。
            # 報告が無い Edge Box (統合サービスの無い OS / 固定メモリ) では外からは見えないので、その旨を出す
            $script:Mem.VmDynamic   = [bool]$vm.DynamicMemoryEnabled
            $script:Mem.VmDemandGB  = [double]$vm.MemoryDemand / 1GB
            $script:Mem.VmMemStatus = [string]$vm.MemoryStatus
            $vis = 0.0; $avail = 0.0; $pres = 0.0
            if ($script:dmName) {
                foreach ($d in @(Get-CimInstance -ClassName $script:dmName -ErrorAction SilentlyContinue)) {
                    if ([string]$d.Name -ne $VMName) { continue }
                    $vis = [double]$d.GuestVisiblePhysicalMemory / 1024.0    # MB → GB
                    $avail = [double]$d.GuestAvailableMemory / 1024.0
                    $pres = [double]$d.CurrentPressure
                }
            }
            $script:Mem.VmVisibleGB = $vis; $script:Mem.VmAvailGB = $avail; $script:Mem.VmPressure = $pres
            $script:Mem.VmReported  = (($vis -gt 0 -and $avail -gt 0) -or $script:Mem.VmDemandGB -gt 0)
        } catch { $script:Mem.VmState = "取得不可 (" + $(if ($script:VmLookupError) { $script:VmLookupError } else { $_.Exception.Message }) + ")" }
    }
    # この画面自身の負荷
    try {
        $me = [System.Diagnostics.Process]::GetCurrentProcess()
        $cpu = $me.TotalProcessorTime; $now = Get-Date
        if ($script:SelfAt) {
            $dt = ($now - $script:SelfAt).TotalSeconds
            if ($dt -gt 0) { $script:SelfPct = 100.0 * ($cpu - $script:SelfCpu).TotalSeconds / $dt / [Math]::Max(1, [Environment]::ProcessorCount) }
        }
        $script:SelfCpu = $cpu; $script:SelfAt = $now
    } catch { }

}

function Get-Avg($Lps, [string]$Key) {
    $vals = @()
    foreach ($l in @($Lps)) { $s = $script:Stat[[int]$l]; if ($s) { $vals += [double]$s[$Key] } }
    if ($vals.Count -eq 0) { return 0.0 }
    return [double](($vals | Measure-Object -Average).Average)
}

# ============================================================ 描画

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
# $cols = 1 行に並べる数 (0 = 幅から決める)。区画どうしで同じ数を渡すと、棒の幅と高さがそろう
# Windows 用の区画で Edge Box が動いた、または Edge Box 用の区画で Windows が動いた論理 CPU は、使用率を赤で出す
function Draw-LpGrid($g, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title, $only, [string]$side, [int]$cols = 0) {
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
# ============================================================ ウィンドウ

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
$form.Text = "$VMName 監視 — 各コアの負荷"
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

$timer.Add_Tick({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }   # しまっている間は休む
    try { Sample; $script:LastErr = "" } catch { $script:LastErr = $_.Exception.Message }
    if ($script:LastErr) { $lblStatus.Text = "エラー: $($script:LastErr)" }
    else {
        $selfTxt = if ($script:SelfPct -ge 0) { "   この画面自身の負荷 {0:N1}%" -f $script:SelfPct } else { "" }
        $lblStatus.Text = "更新 " + (Get-Date -Format "HH:mm:ss") + $selfTxt + "   (数値は直前の更新間隔での平均。枠の色 = 割り当ての計画)"
    }
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
