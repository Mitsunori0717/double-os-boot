<#
.SYNOPSIS
    CPU コア割り当ての設定コンソール (GUI)。
    P コア / E コアを画面で直接選んで、Windows とEdgeBox に振り分けます。

.DESCRIPTION
    - この PC の実際のコア構成を検出して 1 コア = 1 タイルで表示します
      (Intel 12世代以降の P コア/E コアは、CPU が申告する効率クラスで判別)
    - タイルをクリックするたびに Windows 用 → EdgeBox 用 → 未割当 と切り替わります
    - 選んだ内容が「動かない・矛盾している」場合は、その理由を表示して
      [この内容で適用] を押せないようにします (安全装置)
    - 適用そのものは同じフォルダの cpu-partition.ps1 が行います
      (このコンソールは入力と検査の担当。設定の実体は 1 か所にまとまっています)

.EXAMPLE
    .\cpu-console.ps1 -Setup   # デスクトップに『CPU割り当て』アイコンを作成 (最初にこれ)
    .\cpu-console.ps1          # コンソールを開く

.NOTES
    管理者権限が必要です (アイコンから開けば UAC 確認なしで管理者として起動します)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Setup,
    # EdgeBox に最低限割り当てるべき物理コア数 (安全装置)。E コア 8 個を EdgeBox 専用にする運用が既定
    [int]$MinGuestCores = 8
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$EnginePath   = Join-Path $PSScriptRoot "cpu-partition.ps1"
$ConfigFile   = Join-Path $PSScriptRoot "cpu-partition.json"
$SnapshotFile = Join-Path $PSScriptRoot "cpu-topology.json"
$AppsFile     = Join-Path $PSScriptRoot "cpu-apps.json"
$AppsEngine   = Join-Path $PSScriptRoot "cpu-apps.ps1"
$AppsLog      = Join-Path $PSScriptRoot "cpu-apps-log.txt"
# メモリ割り当ての検査基準 (cpu-partition.ps1 と同じ値)
$MemHostReserveGB = 8    # Windows 側に最低限残す量
$MemGuestMinGB    = 4    # EdgeBox の最低量
$MemGuestRecGB    = 8    # EdgeBox の推奨量
$TaskName     = "CpuPartition-Console"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Info([string]$Text, [string]$Icon = "Information") {
    $ic = [System.Windows.Forms.MessageBoxIcon]::Information
    if     ($Icon -eq "Warning") { $ic = [System.Windows.Forms.MessageBoxIcon]::Warning }
    elseif ($Icon -eq "Error")   { $ic = [System.Windows.Forms.MessageBoxIcon]::Error }
    [System.Windows.Forms.MessageBox]::Show($Text, "CPU コア割り当て",
        [System.Windows.Forms.MessageBoxButtons]::OK, $ic) | Out-Null
}

if (-not (Test-Path $EnginePath)) {
    Show-Info "cpu-partition.ps1 が同じフォルダに見つかりません。`n$PSScriptRoot" "Error"
    exit 1
}

# ============================================================
#  デスクトップアイコンの作成 (-Setup)
# ============================================================
# 一般的なアプリらしく見せるためのアイコンを作る (失敗しても致命的ではない)
function New-ConsoleIcon([string]$Path, [string]$Style = "console") {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $sz  = 256
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)

    $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, 62, 110))
    $pins = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 168, 196))
    $win  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 148, 232))
    $vm   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(104, 196, 138))

    foreach ($i in 0..3) {                      # CPU の足
        $o = 62 + $i * 40
        $g.FillRectangle($pins, $o, 18, 18, 30)
        $g.FillRectangle($pins, $o, 208, 18, 30)
        $g.FillRectangle($pins, 18, $o, 30, 18)
        $g.FillRectangle($pins, 208, $o, 30, 18)
    }
    $g.FillRectangle($body, 46, 46, 164, 164)   # パッケージ
    if ($Style -eq "monitor") {
        # 監視: 高さの違う棒グラフ
        $g.FillRectangle($win, 70, 124, 30, 56)
        $g.FillRectangle($vm, 113, 80, 30, 100)
        $g.FillRectangle($win, 156, 144, 30, 36)
    } else {
        $g.FillRectangle($win, 76, 76, 46, 104)     # 内側を 2 色に分けて「分割」を表す
        $g.FillRectangle($vm, 134, 76, 46, 104)
    }
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $png = $ms.ToArray()
    $ms.Dispose()

    # PNG を ICO のヘッダで包む (256x256 は幅・高さを 0 で表す決まり)
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]0);   $bw.Write([byte]0)
    $bw.Write([byte]0);   $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png)
    $bw.Close(); $fs.Close()
}

if ($Setup) {
    if (-not (Test-Admin)) {
        Show-Info "管理者権限で実行してください (右クリック →『管理者として実行』)。" "Warning"
        exit 1
    }
    # UAC 確認なしで開けるよう、管理者権限付きタスク + それを起動するアイコンにする
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    # schtasks を直接ショートカットにすると一瞬だけ黒い窓が出る。
    # wscript から呼べば窓は一切出ない (ウィンドウ スタイル 0)
    $vbsPath = Join-Path $PSScriptRoot "launch-console.vbs"
    $vbs = @(
        "' CPU コア割り当て — 設定コンソールの起動用",
        "' 黒いコンソール窓を出さずにタスクを起動するためのラッパー",
        "CreateObject(""WScript.Shell"").Run ""schtasks.exe /run /tn """"$TaskName"""""", 0, False"
    )
    # VBScript は ANSI として読まれるため、UTF-8 ではなくシステム既定の文字コードで書く
    Set-Content -Path $vbsPath -Value $vbs -Encoding Default

    $icoPath = Join-Path $PSScriptRoot "cpu-console.ico"
    $iconRef = "shell32.dll,27"
    try {
        New-ConsoleIcon $icoPath
        if (Test-Path $icoPath) { $iconRef = "$icoPath,0" }
    } catch {
        Write-Host "  (アイコンを作成できなかったため、標準のアイコンを使います)" -ForegroundColor Yellow
    }

    # デスクトップとスタートメニューの両方に置く。
    # スタートメニューに入れると検索から名前で開けるようになり、
    # 右クリックからタスクバーへピン留めもできる (ピン留めは Windows の仕様上、手動のみ)
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath("Desktop"))  "CPU割り当て.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Programs")) "CPU割り当て.lnk")
    )
    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnkPath in $targets) {
        $dir = Split-Path $lnkPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath       = Join-Path $env:SystemRoot "System32\wscript.exe"
        $lnk.Arguments        = "`"$vbsPath`""
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.IconLocation     = $iconRef
        $lnk.Description      = "CPU コア割り当ての設定コンソール"
        $lnk.Save()
    }

    # --- リアルタイム監視『EdgeBox 監視』も同じ仕組みで登録する ---
    $monPath = Join-Path $PSScriptRoot "cpu-monitor.ps1"
    $monOk = $false
    if (Test-Path $monPath) {
        try {
            $monTask = "CpuPartition-Monitor"
            $mAction = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monPath`" -VMName `"$VMName`""
            # 監視は開きっぱなしにするため、実行時間の上限は付けない (0 = 制限なし)
            $mts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
            Register-ScheduledTask -TaskName $monTask -Action $mAction -Settings $mts -RunLevel Highest -Force | Out-Null
            $mvbs = Join-Path $PSScriptRoot "launch-monitor.vbs"
            Set-Content -Path $mvbs -Encoding Default -Value @(
                "' EdgeBox 監視 — 起動用ラッパー (黒い窓を出さない)",
                "CreateObject(""WScript.Shell"").Run ""schtasks.exe /run /tn """"$monTask"""""", 0, False")
            $micoPath = Join-Path $PSScriptRoot "cpu-monitor.ico"
            $miconRef = "shell32.dll,22"
            try { New-ConsoleIcon $micoPath "monitor"; if (Test-Path $micoPath) { $miconRef = "$micoPath,0" } } catch { }
            foreach ($lnkPath in @((Join-Path ([Environment]::GetFolderPath("Desktop"))  "EdgeBox 監視.lnk"),
                                   (Join-Path ([Environment]::GetFolderPath("Programs")) "EdgeBox 監視.lnk"))) {
                $lnk = $shell.CreateShortcut($lnkPath)
                $lnk.TargetPath       = Join-Path $env:SystemRoot "System32\wscript.exe"
                $lnk.Arguments        = "`"$mvbs`""
                $lnk.WorkingDirectory = $PSScriptRoot
                $lnk.IconLocation     = $miconRef
                $lnk.Description      = "各コアの負荷とメモリの使用量をリアルタイムで表示"
                $lnk.Save()
            }
            $monOk = $true
        } catch {
            Write-Host "  (『EdgeBox 監視』の登録に失敗しました: $($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    Write-Host "『CPU割り当て』を登録しました。" -ForegroundColor Green
    Write-Host "  - デスクトップのアイコン" -ForegroundColor Green
    Write-Host "  - スタートメニュー (「CPU」で検索しても出ます)" -ForegroundColor Green
    if ($monOk) { Write-Host "『EdgeBox 監視』(各コアの負荷とメモリのリアルタイム表示) も同じ場所に登録しました。" -ForegroundColor Green }
    Write-Host "  PowerShell を開く必要はありません。黒い窓も出ません。" -ForegroundColor Green
    Write-Host "  タスクバーに置くには、スタートメニューで右クリック →『タスクバーにピン留めする』" -ForegroundColor Cyan
    exit 0
}

if (-not (Test-Admin)) {
    Show-Info "管理者権限が必要です。`nデスクトップの『CPU割り当て』アイコンから開いてください。`n(アイコンが無い場合: 管理者 PowerShell で .\cpu-console.ps1 -Setup)" "Warning"
    exit 1
}

# ============================================================
#  CPU トポロジの検出 (P コア / E コア / SMT を CPU 自身から取得)
# ============================================================
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

function New-Core([int]$Eff, [int[]]$Lps) {
    [pscustomobject]@{ Id = 0; Eff = $Eff; Lps = @($Lps); Kind = "C"; Label = ""; State = "None" }
}

# 実機から取得。取れない場合は Win32_Processor から推定 (SMT 一律とみなす)
function Get-LiveTopology {
    $cores = @()
    $map = ""
    try { $map = [CpuTopoApi]::GetCoreMap() } catch { $map = "" }
    foreach ($entry in ($map -split ';')) {
        if (-not $entry) { continue }
        $parts = $entry -split '\|'
        if ($parts.Count -lt 2) { continue }
        $lps = @($parts[1] -split ',' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
        if ($lps.Count -eq 0) { continue }
        $cores += (New-Core ([int]$parts[0]) $lps)
    }
    if ($cores.Count -eq 0) {
        $procs = @(Get-CimInstance Win32_Processor)
        $pc  = [int](($procs | Measure-Object -Property NumberOfCores -Sum).Sum)
        $lpc = [int](($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        if ($pc -le 0) { $pc = 1 }
        $smt = 1
        if (($lpc % $pc) -eq 0 -and $lpc -ge $pc) { $smt = [int]($lpc / $pc) }
        for ($k = 0; $k -lt $pc; $k++) {
            $lps = @()
            for ($t = 0; $t -lt $smt; $t++) { $lps += ($k * $smt + $t) }
            $cores += (New-Core 0 $lps)
        }
    }
    return ,(Set-CoreLabels $cores)
}

# 論理 CPU 番号順に並べ、P/E の区別と表示名を付ける
function Set-CoreLabels($Cores) {
    $sorted = @($Cores | Sort-Object { $_.Lps[0] })
    $effs = @($sorted | ForEach-Object { $_.Eff })
    $maxEff = ($effs | Measure-Object -Maximum).Maximum
    $minEff = ($effs | Measure-Object -Minimum).Minimum
    $pn = 0; $en = 0; $cn = 0; $i = 0
    foreach ($c in $sorted) {
        $c.Id = $i; $i++
        if ($maxEff -eq $minEff) {
            $c.Kind = "C"; $c.Label = "コア$cn"; $cn++
        } elseif ($c.Eff -eq $maxEff) {
            $c.Kind = "P"; $c.Label = "P$pn"; $pn++
        } else {
            $c.Kind = "E"; $c.Label = "E$en"; $en++
        }
    }
    return ,$sorted
}

function Get-CpuName {
    try { return ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()) } catch { return "" }
}
function Save-Snapshot($Cores) {
    # CPU 名を一緒に保存する。別 PC からコピーされたファイルを使わないための照合用
    try {
        $obj = [pscustomobject]@{
            Cpu   = (Get-CpuName)
            Cores = @($Cores | ForEach-Object { [pscustomobject]@{ Eff = $_.Eff; Lps = @($_.Lps) } })
        }
        $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $SnapshotFile -Encoding UTF8
    } catch { }
}

function Read-Snapshot {
    if (-not (Test-Path $SnapshotFile)) { return $null }
    try {
        $json = Get-Content $SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $raw = @()
        if ($json.PSObject.Properties["Cores"]) {
            # 新形式: CPU 名が一致するものだけ信用する (別 PC の構成を持ち込んだ場合の誤表示を防ぐ)
            if ([string]$json.Cpu -ne (Get-CpuName)) { return $null }
            $raw = @($json.Cores)
        } else {
            # 旧形式 (配列のみ): 論理 CPU 数がこの PC と一致するときだけ信用する
            $raw = @($json)
            $n = 0; foreach ($r in $raw) { $n += @([int[]]$r.Lps).Count }
            if ($n -ne [Environment]::ProcessorCount) { return $null }
        }
        $cores = @()
        foreach ($r in $raw) {
            $lps = @([int[]]$r.Lps)
            if ($lps.Count -gt 0) { $cores += (New-Core ([int]$r.Eff) $lps) }
        }
        if ($cores.Count -eq 0) { return $null }
        return ,(Set-CoreLabels $cores)
    } catch { return $null }
}

function Get-LpCount($Cores) {
    return [int]((@($Cores | ForEach-Object { $_.Lps.Count }) | Measure-Object -Sum).Sum)
}

function ConvertTo-LpRangeText([int[]]$Lps) {
    if (-not $Lps -or $Lps.Count -eq 0) { return "なし" }
    $sorted = @($Lps | Sort-Object -Unique)
    $parts = @()
    $start = $sorted[0]; $prev = $sorted[0]
    for ($k = 1; $k -lt $sorted.Count; $k++) {
        $i = $sorted[$k]
        if ($i -eq ($prev + 1)) { $prev = $i; continue }
        if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
        $start = $i; $prev = $i
    }
    if ($start -eq $prev) { $parts += "$start" } else { $parts += "$start-$prev" }
    return ($parts -join ",")
}

# ============================================================
#  環境の読み取り (cpu-partition.ps1 と同じ判定を、変更せずに参照するだけ)
# ============================================================
function Get-HvSchedulerType {
    try {
        $ev = Get-WinEvent -FilterHashtable @{ ProviderName = "Microsoft-Windows-Hyper-V-Hypervisor"; Id = 2 } `
            -MaxEvents 1 -ErrorAction Stop
        $val = 0
        if ($ev.Properties.Count -ge 1) { $val = [int]$ev.Properties[0].Value }
        if ($val -eq 0 -and $ev.Message -match '0x([0-9a-fA-F]+)') { $val = [Convert]::ToInt32($Matches[1], 16) }
        switch ($val) {
            1 { return "classic" }
            2 { return "classic" }
            3 { return "core" }
            4 { return "root" }
        }
        return "unknown"
    } catch { return "unknown" }
}

function Get-BcdHvSettings {
    $ErrorActionPreference = "Continue"
    $out = (bcdedit /enum "{current}" 2>&1 | Out-String)
    $sched = $null; $rootproc = $null
    if ($out -match '(?m)^\s*hypervisorschedulertype\s+(\S+)') { $sched = $Matches[1].ToLower() }
    if ($out -match '(?m)^\s*hypervisorrootproc\s+(\S+)') {
        $v = $Matches[1]
        if ($v -match '^0x') { $rootproc = [Convert]::ToInt32($v.Substring(2), 16) } else { $rootproc = [int]$v }
    }
    [pscustomobject]@{ SchedulerType = $sched; RootProc = $rootproc }
}

function Update-Environment {
    $script:HyperVOk  = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    $script:Scheduler = Get-HvSchedulerType
    try { $script:Bcd = Get-BcdHvSettings } catch { $script:Bcd = [pscustomobject]@{ SchedulerType = $null; RootProc = $null } }
    $script:VisibleLps = [Environment]::ProcessorCount
    $script:Vm = $null
    $script:Vcpu = 0
    if ($script:HyperVOk -and $script:VmNameSel) {
        $script:Vm = Get-VM -Name $script:VmNameSel -ErrorAction SilentlyContinue
        if ($script:Vm) {
            try { $script:Vcpu = [int](Get-VMProcessor -VMName $script:VmNameSel).Count } catch { $script:Vcpu = 0 }
        }
    }
    # メモリ: PC 全体と EdgeBox の設定値
    $script:MemTotalGB = 0.0; $script:MemVmGB = 0.0; $script:MemDynamic = $false
    try { $script:MemTotalGB = [Math]::Round(([double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory) / 1GB, 1) } catch { }
    if ($script:Vm) {
        try {
            $m = Get-VMMemory -VMName $script:VmNameSel -ErrorAction Stop
            $script:MemVmGB   = [Math]::Round(([double]$m.Startup) / 1GB, 1)
            $script:MemDynamic = [bool]$m.DynamicMemoryEnabled
        } catch { }
    }
}

# ============================================================
#  起動時の状態づくり
# ============================================================
$script:VmNameSel = $VMName
Update-Environment
# その名前の登録が無ければ (名前を変えた等)、EdgeBox の物理ディスクを持つ登録か 1 つしかない登録を選ぶ
if ($script:HyperVOk -and -not $script:Vm) {
    try {
        $all = @(Get-VM -ErrorAction SilentlyContinue)
        $found = @($all | Where-Object { @(Get-VMHardDiskDrive -VMName $_.Name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.DiskNumber }).Count -gt 0 })
        $pick = $null
        if ($found.Count -eq 1) { $pick = $found[0].Name } elseif ($all.Count -eq 1) { $pick = $all[0].Name }
        if ($pick) { $script:VmNameSel = $pick; Update-Environment }
    } catch { }
}

# minroot 適用中は Windows から一部のコアが見えないため、初回に保存した構成を使う
$live = Get-LiveTopology
$snap = Read-Snapshot
if ($snap -and ((Get-LpCount $snap) -gt (Get-LpCount $live))) {
    $script:Cores = $snap
    $script:UsedSnapshot = $true
} else {
    $script:Cores = $live
    $script:UsedSnapshot = $false
    Save-Snapshot $live
}
$script:TotalLps    = Get-LpCount $script:Cores
$script:UnderMinroot = ($script:VisibleLps -lt $script:TotalLps)
$script:Hybrid      = @($script:Cores | Where-Object { $_.Kind -eq "E" }).Count -gt 0
$script:Tiles       = @{}

# 保存済みの割り当てがあれば、それを初期表示にする
$script:SavedCfg = $null
if (Test-Path $ConfigFile) {
    try { $script:SavedCfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
# 混成 CPU の既定の割り当て: 末尾の E コアを $MinGuestCores 個 (足りなければ全部) EdgeBox に、残りは Windows に
function Set-DefaultHybridPlan {
    foreach ($c in $script:Cores) { $c.State = "Host" }
    $eTail = @($script:Cores | Where-Object { $_.Kind -eq "E" } | Sort-Object Id -Descending | Select-Object -First $MinGuestCores)
    foreach ($c in $eTail) { $c.State = "Guest" }
}
function Set-StatesFromLps($HostLps, $GuestLps) {
    foreach ($c in $script:Cores) {
        $inHost  = @($c.Lps | Where-Object { $HostLps  -contains $_ }).Count -gt 0
        $inGuest = @($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0
        if ($inGuest) { $c.State = "Guest" } elseif ($inHost) { $c.State = "Host" } else { $c.State = "None" }
    }
}
if ($script:SavedCfg) {
    Set-StatesFromLps @([int[]]$script:SavedCfg.HostLps) @([int[]]$script:SavedCfg.GuestLps)
} else {
    # 既定の初期表示: 混成 CPU なら「末尾の E コア 8 個 = EdgeBox / 残り (P コア全部 + 先頭の E コア) = Windows」、
    # それ以外は前半/後半で半分ずつ
    if ($script:Hybrid) {
        Set-DefaultHybridPlan
    } else {
        $half = [Math]::Max(1, [int]($script:Cores.Count / 2))
        foreach ($c in $script:Cores) { $c.State = $(if ($c.Id -lt $half) { "Host" } else { "Guest" }) }
    }
}

# ============================================================
#  画面の組み立て
# ============================================================
$ColHost  = [System.Drawing.Color]::FromArgb(207, 226, 250)
$ColGuest = [System.Drawing.Color]::FromArgb(206, 238, 206)
$ColNone  = [System.Drawing.Color]::FromArgb(232, 232, 232)

$form = New-Object System.Windows.Forms.Form
$form.Text = "CPU コア割り当て"
$form.ClientSize = New-Object System.Drawing.Size(964, 862)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Meiryo UI", 9)

function New-Lbl([string]$Text, [int]$X, [int]$Y, [int]$W = 0) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $l.Size = New-Object System.Drawing.Size($W, 20) } else { $l.AutoSize = $true }
    return $l
}

# --- この PC ---
$grpPc = New-Object System.Windows.Forms.GroupBox
$grpPc.Text = "この PC の CPU"
$grpPc.Location = New-Object System.Drawing.Point(12, 8)
$grpPc.Size = New-Object System.Drawing.Size(940, 98)
$script:lblCpu1 = New-Lbl "" 14 22 770
$script:lblCpu2 = New-Lbl "" 14 44 770
$script:lblCpu3 = New-Lbl "" 14 66 910
$script:btnMon = New-Object System.Windows.Forms.Button
$script:btnMon.Text = "リアルタイム監視"
$script:btnMon.Location = New-Object System.Drawing.Point(792, 24)
$script:btnMon.Size = New-Object System.Drawing.Size(134, 28)
$grpPc.Controls.AddRange(@($script:lblCpu1, $script:lblCpu2, $script:lblCpu3, $script:btnMon))
$form.Controls.Add($grpPc)

# --- 対象 ---
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = "対象"
$grpMode.Location = New-Object System.Drawing.Point(12, 90)
$grpMode.Size = New-Object System.Drawing.Size(940, 58)

$grpMode.Controls.Add((New-Lbl "対象の登録名:" 14 26))
$script:cmbVm = New-Object System.Windows.Forms.ComboBox
$script:cmbVm.Location = New-Object System.Drawing.Point(100, 23)
$script:cmbVm.Size = New-Object System.Drawing.Size(200, 24)
$script:cmbVm.DropDownStyle = "DropDown"   # 未作成の 登録名も入力できるようにする
if ($script:HyperVOk) {
    foreach ($n in @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)) {
        [void]$script:cmbVm.Items.Add($n)
    }
}
if ($script:cmbVm.Items.Contains($script:VmNameSel)) { $script:cmbVm.SelectedItem = $script:VmNameSel }
$script:cmbVm.Text = $script:VmNameSel
$grpMode.Controls.Add($script:cmbVm)
$script:lblVm = New-Lbl "" 314 26 610
$grpMode.Controls.Add($script:lblVm)

# 方式は「完全分離」固定 (選択肢は出さない)
$form.Controls.Add($grpMode)

# --- コアのタイル ---
function New-Tile($Core) {
    $b = New-Object System.Windows.Forms.Button
    $b.Size = New-Object System.Drawing.Size(86, 46)
    $b.Margin = New-Object System.Windows.Forms.Padding(3)
    $b.FlatStyle = "Flat"
    $b.Font = New-Object System.Drawing.Font("Meiryo UI", 8)
    $b.TextAlign = "MiddleCenter"
    $b.Tag = $Core.Id
    $b.Add_Click({
        param($s, $e)
        $c = $script:Cores[[int]$s.Tag]
        if ($script:Hybrid -and $c.Kind -eq "P") {
            # P コアは Windows 専用 (EdgeBox には割り当てない): Windows 用 ⇔ 未割当
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
    return $b
}

function Sync-Tile($Core) {
    $t = $script:Tiles[$Core.Id]
    if (-not $t) { return }
    $lpText = ConvertTo-LpRangeText $Core.Lps
    switch ($Core.State) {
        "Host"  { $t.BackColor = $ColHost;  $t.ForeColor = [System.Drawing.Color]::FromArgb(20, 50, 110); $side = "Windows" }
        "Guest" { $t.BackColor = $ColGuest; $t.ForeColor = [System.Drawing.Color]::FromArgb(20, 90, 30);  $side = "EdgeBox" }
        default { $t.BackColor = $ColNone;  $t.ForeColor = [System.Drawing.Color]::Gray;                  $side = "未割当" }
    }
    $t.Text = "{0}  ({1})`r`nCPU {2}" -f $Core.Label, $side, $lpText
}

function Sync-AllTiles {
    foreach ($c in $script:Cores) { Sync-Tile $c }
}

function New-CoreGroup([string]$Title, [int]$Y, [int]$H) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Title
    $g.Location = New-Object System.Drawing.Point(12, $Y)
    $g.Size = New-Object System.Drawing.Size(940, $H)
    $fp = New-Object System.Windows.Forms.FlowLayoutPanel
    $fp.Location = New-Object System.Drawing.Point(10, 18)
    $fp.Size = New-Object System.Drawing.Size(920, ($H - 28))
    $fp.AutoScroll = $true
    $fp.WrapContents = $true
    $fp.FlowDirection = "LeftToRight"
    $g.Controls.Add($fp)
    $g.Tag = $fp
    return $g
}

if ($script:Hybrid) {
    $pCores = @($script:Cores | Where-Object { $_.Kind -eq "P" })
    $eCores = @($script:Cores | Where-Object { $_.Kind -ne "P" })
    $pThreads = [int]((@($pCores | ForEach-Object { $_.Lps.Count }) | Measure-Object -Sum).Sum)
    $eThreads = [int]((@($eCores | ForEach-Object { $_.Lps.Count }) | Measure-Object -Sum).Sum)
    $grpP = New-CoreGroup ("P コア (性能重視) — {0} コア / {1} スレッド" -f $pCores.Count, $pThreads) 224 96
    $grpE = New-CoreGroup ("E コア (効率重視) — {0} コア / {1} スレッド" -f $eCores.Count, $eThreads) 324 148
    foreach ($c in $pCores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpP.Tag.Controls.Add($t) }
    foreach ($c in $eCores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpE.Tag.Controls.Add($t) }
    $form.Controls.AddRange(@($grpP, $grpE))
} else {
    $allThreads = Get-LpCount $script:Cores
    $grpA = New-CoreGroup ("CPU コア — {0} コア / {1} スレッド" -f $script:Cores.Count, $allThreads) 224 248
    foreach ($c in $script:Cores) { $t = New-Tile $c; $script:Tiles[$c.Id] = $t; $grpA.Tag.Controls.Add($t) }
    $form.Controls.Add($grpA)
}

# --- 割り当ての要約 ---
$grpSum = New-Object System.Windows.Forms.GroupBox
$grpSum.Text = "この内容で割り当てます"
$grpSum.Location = New-Object System.Drawing.Point(12, 498)
$grpSum.Size = New-Object System.Drawing.Size(940, 74)
$script:lblSumH = New-Lbl "" 14 22 910
$script:lblSumG = New-Lbl "" 14 44 910
$grpSum.Controls.AddRange(@($script:lblSumH, $script:lblSumG))
$form.Controls.Add($grpSum)

# --- 検査結果 ---
$grpChk = New-Object System.Windows.Forms.GroupBox
$grpChk.Text = "検査結果"
$grpChk.Location = New-Object System.Drawing.Point(12, 578)
$grpChk.Size = New-Object System.Drawing.Size(940, 118)
$script:rtb = New-Object System.Windows.Forms.RichTextBox
$script:rtb.Location = New-Object System.Drawing.Point(10, 18)
$script:rtb.Size = New-Object System.Drawing.Size(920, 90)
$script:rtb.ReadOnly = $true
$script:rtb.BorderStyle = "None"
$script:rtb.BackColor = [System.Drawing.Color]::White
$script:rtb.Font = New-Object System.Drawing.Font("Meiryo UI", 9)
$grpChk.Controls.Add($script:rtb)
$form.Controls.Add($grpChk)

# --- メモリの割り当て ---
$grpMem = New-Object System.Windows.Forms.GroupBox
$grpMem.Text = "メモリの割り当て (PC 全体のメモリを Windows と EdgeBox で分ける)"
$grpMem.Location = New-Object System.Drawing.Point(12, 700)
$grpMem.Size = New-Object System.Drawing.Size(940, 66)
$script:lblMemPc = New-Lbl "" 14 24 240
$grpMem.Controls.Add($script:lblMemPc)
$script:lblMemVm = New-Lbl "" 258 24 120
$grpMem.Controls.Add($script:lblMemVm)
$script:numMem = New-Object System.Windows.Forms.NumericUpDown
$script:numMem.Location = New-Object System.Drawing.Point(380, 21)
$script:numMem.Size = New-Object System.Drawing.Size(64, 24)
$script:numMem.Minimum = 1
$script:numMem.Maximum = 4096
$script:numMem.Value = 8
$grpMem.Controls.Add($script:numMem)
$grpMem.Controls.Add((New-Lbl "GB" 448 24))
$script:lblMemHost = New-Lbl "" 480 24 280
$grpMem.Controls.Add($script:lblMemHost)
$script:btnMem = New-Object System.Windows.Forms.Button
$script:btnMem.Text = "メモリを適用"
$script:btnMem.Location = New-Object System.Drawing.Point(776, 19)
$script:btnMem.Size = New-Object System.Drawing.Size(150, 28)
$grpMem.Controls.Add($script:btnMem)
$script:lblMemNote = New-Lbl "" 14 44 910
$script:lblMemNote.ForeColor = [System.Drawing.Color]::DimGray
$grpMem.Controls.Add($script:lblMemNote)
$form.Controls.Add($grpMem)

# --- アプリの割り当て (Windows 側アプリを特定コアに固定する) ---
$grpApps = New-Object System.Windows.Forms.GroupBox
$grpApps.Text = "アプリの割り当て (Windows 側のアプリを決めたコアで動かす)"
$grpApps.Location = New-Object System.Drawing.Point(12, 772)
$grpApps.Size = New-Object System.Drawing.Size(940, 56)
$script:btnApps = New-Object System.Windows.Forms.Button
$script:btnApps.Text = "アプリの割り当てを編集..."
$script:btnApps.Location = New-Object System.Drawing.Point(14, 20)
$script:btnApps.Size = New-Object System.Drawing.Size(200, 28)
$grpApps.Controls.Add($script:btnApps)
$script:lblApps = New-Lbl "" 228 26 700
$grpApps.Controls.Add($script:lblApps)
$form.Controls.Add($grpApps)

# --- 操作ボタン ---
$script:btnFix = New-Object System.Windows.Forms.Button
$script:btnFix.Text = "完全分離用に並べ直す"
$script:btnFix.Location = New-Object System.Drawing.Point(308, 834)
$script:btnFix.Size = New-Object System.Drawing.Size(160, 32)
$script:btnFix.Visible = $false

$script:chkTools = New-Object System.Windows.Forms.CheckBox
$script:chkTools.Text = "CpuGroups.exe を自動取得"
$script:chkTools.Location = New-Object System.Drawing.Point(476, 839)
$script:chkTools.Size = New-Object System.Drawing.Size(180, 24)
$script:chkTools.Checked = $true
$script:chkTools.Visible = $false   # 常に自動取得する (仕組みの名前は画面に出さない)

$script:btnApply = New-Object System.Windows.Forms.Button
$script:btnApply.Text = "この内容で適用"
$script:btnApply.Location = New-Object System.Drawing.Point(660, 834)
$script:btnApply.Size = New-Object System.Drawing.Size(170, 32)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "閉じる"
$btnClose.Location = New-Object System.Drawing.Point(838, 834)
$btnClose.Size = New-Object System.Drawing.Size(114, 32)
$btnClose.DialogResult = "Cancel"
$form.CancelButton = $btnClose
$form.Controls.AddRange(@($script:btnFix, $script:chkTools, $script:btnApply, $btnClose))

# ============================================================
#  アプリの割り当て (cpu-apps.json / cpu-apps.ps1)
# ============================================================
function Read-AppsFile {
    if (-not (Test-Path $AppsFile)) { return @() }
    try { return @(Get-Content $AppsFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
}

function Save-AppsFile($Apps) {
    $arr = @($Apps)
    if ($arr.Count -eq 0) {
        Set-Content -Path $AppsFile -Value "[]" -Encoding UTF8
    } else {
        (ConvertTo-Json -InputObject ([object[]]$arr) -Depth 4) | Set-Content -Path $AppsFile -Encoding UTF8
    }
}

$script:Apps = Read-AppsFile

# ============================================================
#  検査 (矛盾・不可能な設定を洗い出し、適用の可否を決める)
# ============================================================
function Get-Selection {
    $h = New-Object System.Collections.Generic.List[int]
    $g = New-Object System.Collections.Generic.List[int]
    $hc = 0; $gc = 0; $nc = 0
    foreach ($c in $script:Cores) {
        if ($c.State -eq "Host")       { $hc++; foreach ($l in $c.Lps) { [void]$h.Add($l) } }
        elseif ($c.State -eq "Guest")  { $gc++; foreach ($l in $c.Lps) { [void]$g.Add($l) } }
        else                           { $nc++ }
    }
    [pscustomobject]@{
        HostLps = @($h | Sort-Object); GuestLps = @($g | Sort-Object)
        HostCores = $hc; GuestCores = $gc; NoneCores = $nc
    }
}

function Update-Header {
    $name = ""
    try { $name = ((Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() }) -join " / ") } catch { }
    $t = "{0}  —  {1} コア / {2} スレッド" -f $name, $script:Cores.Count, $script:TotalLps
    if ($script:Hybrid) {
        $pC = @($script:Cores | Where-Object { $_.Kind -eq "P" }).Count
        $eC = @($script:Cores | Where-Object { $_.Kind -eq "E" }).Count
        $t += "  (P コア {0} + E コア {1})" -f $pC, $eC
    }
    $script:lblCpu1.Text = $t
    # 仕組みの名前 (方式・固定の手段など) は画面に出さない。状態だけを出す
    $mr = if ($script:UnderMinroot) { "Windows が使う CPU: $($script:VisibleLps) 論理 (分離が有効)" } else { "Windows が使う CPU: $($script:VisibleLps) 論理 (全部)" }
    $fs = ""
    if ($script:SavedCfg -and $script:SavedCfg.Mode -eq "full") {
        $st = $null
        try { $f = Join-Path $PSScriptRoot "cpu-full-status.json"; if (Test-Path $f) { $st = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
        if (-not $st) { $fs = "完全分離: 準備中 (再起動待ち)" }
        elseif ($st.Bound) { $fs = "完全分離: ○ 成立   Windows は CPU $($st.HostLps) に固定 / $($script:VmNameSel) は CPU $($st.GuestLps) に固定" }
        elseif (-not $st.MinrootOk) { $fs = "完全分離: △ 未成立 (再起動待ち)" }
        else { $fs = "完全分離: △ 未成立 (『EdgeBox 再起動』で直ることがあります。『EdgeBox 監視』で確認)" }
    } elseif ($script:SavedCfg -and $script:SavedCfg.Mode -eq "runtime") {
        $fs = "簡易分離: 適用済み (Windows と $($script:VmNameSel) のプロセスをそれぞれのコアに固定)"
    }
    $script:lblCpu2.Text = $mr
    $script:lblCpu3.Text = $fs
    if ($script:Vm) {
        $script:lblVm.Text = "状態: {0}    プロセッサ: {1}    メモリ: {2} GB{3}" -f $script:Vm.State, $script:Vcpu,
            $script:MemVmGB, $(if ($script:MemDynamic) { " (動的)" } else { "" })
    } elseif ($script:HyperVOk) {
        $script:lblVm.Text = "この名前の EdgeBox が見つかりません"
    } else {
        $script:lblVm.Text = "Hyper-V が有効ではありません"
    }
}

function Format-Side($Cores, [int[]]$Lps) {
    $p = @($Cores | Where-Object { $_.Kind -eq "P" }).Count
    $e = @($Cores | Where-Object { $_.Kind -eq "E" }).Count
    $mix = ""
    if ($script:Hybrid) { $mix = "  (P {0} / E {1})" -f $p, $e }
    return "{0} コア / {1} スレッド{2}   CPU {3}" -f $Cores.Count, $Lps.Count, $mix, (ConvertTo-LpRangeText $Lps)
}

function Update-Validation {
    $sel = Get-Selection
    $mode = "full"          # 方式は完全分離のみ
    $errors = @(); $warnings = @()

    $hostCoreObjs  = @($script:Cores | Where-Object { $_.State -eq "Host" })
    $guestCoreObjs = @($script:Cores | Where-Object { $_.State -eq "Guest" })
    $script:lblSumH.Text = "Windows : " + (Format-Side $hostCoreObjs $sel.HostLps)
    $script:lblSumG.Text = "{0} : {1}" -f $script:VmNameSel, (Format-Side $guestCoreObjs $sel.GuestLps)

    # --- 環境そのものが整っていない ---
    if (-not $script:HyperVOk) {
        $errors += "Hyper-V が有効ではありません。先に Hyper-V を有効化して再起動してください。"
    }
    $script:VmMissing = ($script:HyperVOk -and -not $script:Vm)
    if ($script:VmMissing) {
        if (-not $script:VmNameSel) {
            $errors += "対象の 登録名を入力してください。"
        } else {
            $warnings += "登録『$($script:VmNameSel)』はまだ見つかりません。この内容は保存され、EdgeBox を作成して起動した時点で自動的に適用されます。"
        }
    }

    # --- 割り当ての量 ---
    if ($sel.GuestCores -lt 1) {
        $errors += "$($script:VmNameSel) にコアが 1 つも割り当てられていません。このままでは $($script:VmNameSel) を起動できません (コアを 1 つ以上、EdgeBox 用にしてください)。"
    }
    if ($sel.HostCores -lt 2) {
        $errors += "Windows 側が $($sel.HostCores) コアです。最低 2 コア必要です (EdgeBox のディスク/ネットワーク処理も Windows 側で動くため)。"
    } elseif ($sel.HostCores -lt 4) {
        $warnings += "Windows 側が 4 コア未満です。EdgeBox の I/O 処理も Windows 側コアで動くため、$($script:VmNameSel) の通信・保存まで遅くなることがあります。"
    }
    if ($sel.NoneCores -gt 0) {
        $warnings += "未割当のコアが $($sel.NoneCores) 個あります (どちらからも積極的には使われません)。"
    }
    if ($sel.GuestLps.Count -gt 0 -and $sel.GuestLps.Count -lt 8) {
        $warnings += "$($script:VmNameSel) 側が $($sel.GuestLps.Count) スレッドです (EdgeBox の元の構成 4 コア 8 スレッドを下回ります)。"
    }
    if ($script:Hybrid) {
        # EdgeBox は E コア専用。P コアは Windows 側に残す (混ざらない・速さの違うコアを混ぜない)
        $gp0 = @($guestCoreObjs | Where-Object { $_.Kind -eq "P" })
        if ($gp0.Count -gt 0) { $errors += "$($script:VmNameSel) に P コアは割り当てられません ($(($gp0 | ForEach-Object { $_.Label }) -join ', '))。EdgeBox は E コア専用です。" }
        # EdgeBox 用の E コアは末尾に固めておく (full の minroot 条件 = Windows は先頭から連番 を満たすため)
        $eAll = @($script:Cores | Where-Object { $_.Kind -eq "E" } | Sort-Object Id)
        $firstGuest = -1
        for ($k = 0; $k -lt $eAll.Count; $k++) { if ($eAll[$k].State -eq "Guest") { $firstGuest = $k; break } }
        if ($firstGuest -ge 0) {
            $gap = @($eAll | Select-Object -Skip $firstGuest | Where-Object { $_.State -ne "Guest" })
            if ($gap.Count -gt 0) { $errors += "$($script:VmNameSel) 用の E コアは末尾に続けて並べてください (間に Windows 用・未割当の E コアがあります: $(($gap | ForEach-Object { $_.Label }) -join ', '))。" }
        }
    }

    # --- 完全分離の成立条件 ---
    # minroot は「先頭から N 個」の論理 CPU を Windows に割り当てる方式
    $script:btnFix.Visible = $false
    $ok = $true
    for ($i = 0; $i -lt $sel.HostLps.Count; $i++) {
        if ($sel.HostLps[$i] -ne $i) { $ok = $false; break }
    }
    if (-not $ok -or $sel.HostLps.Count -eq 0) {
        $errors += "完全分離では Windows 側が CPU 0 から続き番号である必要があります。現在: CPU $(ConvertTo-LpRangeText $sel.HostLps)"
        $script:btnFix.Visible = $true
    }
    $warnings += "完全分離は再起動が 1 回必要です (適用 → 再起動。再起動後は自動で完了します)。"

    # --- 分割の質 ---
    foreach ($c in $script:Cores) {
        if ($c.Lps.Count -lt 2) { continue }
        $sides = @($c.Lps | ForEach-Object { $l = $_
            if ($sel.HostLps -contains $l) { "H" } elseif ($sel.GuestLps -contains $l) { "G" } else { "N" } } | Sort-Object -Unique)
        if (($sides -contains "H") -and ($sides -contains "G")) {
            $warnings += "同じコア ($($c.Label)) の 2 スレッドが Windows と $($script:VmNameSel) に分かれています。実行資源を共有するため分割効果が下がります。"
            break
        }
    }
    if ($script:Hybrid -and $guestCoreObjs.Count -gt 0) {
        $gp = @($guestCoreObjs | Where-Object { $_.Kind -eq "P" }).Count
        $ge = @($guestCoreObjs | Where-Object { $_.Kind -eq "E" }).Count
        if ($gp -gt 0 -and $ge -gt 0) {
            $warnings += "$($script:VmNameSel) 側に P コアと E コアが混在しています (速さの違うコアが混ざると動作が不均一になることがあります)。"
        }
    }
    if ($script:Vm -and $sel.GuestLps.Count -gt 0 -and $script:Vcpu -ne $sel.GuestLps.Count) {
        if ($script:Vm.State -eq "Off") {
            $warnings += "プロセッサ数を $($script:Vcpu) から $($sel.GuestLps.Count) に自動調整します。"
        } else {
            $warnings += "プロセッサ数 ($($script:Vcpu)) と割り当てスレッド数 ($($sel.GuestLps.Count)) が違います。EdgeBox 停止中に適用すると自動調整されます。"
        }
    }
    if ($script:UsedSnapshot) {
        $warnings += "一部のコアが Windows から見えないため、保存済みのコア構成を表示しています。"
    }
    $appOnGuest = @()
    foreach ($a in $script:Apps) {
        $al = @([int[]]$a.Lps)
        if (@($al | Where-Object { $sel.GuestLps -contains $_ }).Count -gt 0) { $appOnGuest += [string]$a.Name }
    }
    if ($appOnGuest.Count -gt 0) {
        $warnings += "アプリ『$($appOnGuest -join '、')』が $($script:VmNameSel) 用コアに割り当てられています (EdgeBox と取り合いになります)。"
    }
    $script:lblApps.Text = "登録: $($script:Apps.Count) 件" +
        $(if ($script:Apps.Count -gt 0) { "  (" + ((@($script:Apps | Select-Object -First 3 | ForEach-Object { $_.Name }) -join "、")) + $(if ($script:Apps.Count -gt 3) { " ほか" } else { "" }) + ")" } else { "" })

    # --- 表示 ---
    $script:rtb.Clear()
    function Add-Line([string]$Text, $Color) {
        $script:rtb.SelectionStart = $script:rtb.TextLength
        $script:rtb.SelectionLength = 0
        $script:rtb.SelectionColor = $Color
        $script:rtb.AppendText($Text + "`r`n")
    }
    foreach ($e in $errors)   { Add-Line ("[不可] " + $e) ([System.Drawing.Color]::Firebrick) }
    foreach ($w in $warnings) { Add-Line ("[注意] " + $w) ([System.Drawing.Color]::FromArgb(180, 95, 0)) }
    if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
        Add-Line "問題ありません。この内容で適用できます。" ([System.Drawing.Color]::FromArgb(20, 120, 40))
    } elseif ($errors.Count -eq 0) {
        Add-Line "適用できます (上の注意点をご確認ください)。" ([System.Drawing.Color]::FromArgb(20, 120, 40))
    }
    $script:btnApply.Enabled = ($errors.Count -eq 0)
    if ($script:VmMissing) { $script:btnApply.Text = "保存 (EdgeBox 検出後に自動適用)" }
    else { $script:btnApply.Text = "この内容で適用" }
}

# ============================================================
#  操作 (適用・解除・実測はすべて cpu-partition.ps1 に任せる)
# ============================================================
# --- メモリ欄の表示と検査 (適用そのものは cpu-partition.ps1 -MemoryGB に任せる) ---
function Update-MemoryUi {
    $total = [double]$script:MemTotalGB
    $script:lblMemPc.Text = if ($total -gt 0) { "この PC のメモリ: $total GB" } else { "この PC のメモリ: (取得できません)" }
    $script:lblMemVm.Text = "$($script:VmNameSel) に:"
    if (-not $script:Vm) {
        $script:lblMemHost.Text = ""
        $script:lblMemNote.Text = "EdgeBox が見つからないため、メモリは変更できません (EdgeBox を作成・検出してから)。"
        $script:lblMemNote.ForeColor = [System.Drawing.Color]::DimGray
        $script:btnMem.Enabled = $false; $script:numMem.Enabled = $false
        return
    }
    $script:numMem.Enabled = $true
    $g = [int]$script:numMem.Value
    $hostGB = [Math]::Round($total - $g, 1)
    $script:lblMemHost.Text = if ($total -gt 0) { "→ Windows に残る: $hostGB GB" } else { "" }
    $errs = @(); $warns = @()
    if ($g -lt $MemGuestMinGB) { $errs += "最低 $MemGuestMinGB GB 必要" }
    if ($total -gt 0 -and $hostGB -lt $MemHostReserveGB) {
        $errs += "Windows 側に最低 $MemHostReserveGB GB 残す必要 (最大 $([int][Math]::Floor($total - $MemHostReserveGB)) GB まで)"
    }
    if ($g -lt $MemGuestRecGB) { $warns += "推奨は $MemGuestRecGB GB 以上" }
    if ($total -gt 0 -and $g -gt ($total / 2)) { $warns += "PC の半分以上を割り当てています" }
    $cur  = "現在の設定: $($script:MemVmGB) GB" + $(if ($script:MemDynamic) { " (動的)" } else { "" })
    $same = ($g -eq [int][Math]::Round($script:MemVmGB) -and -not $script:MemDynamic)
    if ($errs.Count -gt 0) {
        $script:lblMemNote.Text = "$cur    [不可] " + ($errs -join " / ")
        $script:lblMemNote.ForeColor = [System.Drawing.Color]::Firebrick
        $script:btnMem.Enabled = $false
        return
    }
    $st = if ($same) { "変更なし" }
          elseif ([string]$script:Vm.State -ne "Off") { "EdgeBox は実行中のため、反映には EdgeBox の再起動が必要です (適用時に確認します)" }
          else { "EdgeBox は停止中のため、すぐに反映できます" }
    $script:lblMemNote.Text = "$cur    " + $(if ($warns.Count -gt 0) { "[注意] " + ($warns -join " / ") + "    " } else { "" }) + $st
    $script:lblMemNote.ForeColor = if ($warns.Count -gt 0) { [System.Drawing.Color]::FromArgb(180, 95, 0) } else { [System.Drawing.Color]::DimGray }
    $script:btnMem.Enabled = (-not $same)
}

function Sync-MemoryControl {
    # 読み直した値を入力欄に反映する (上限は PC の実メモリ)
    if ($script:MemTotalGB -gt 0) { $script:numMem.Maximum = [Math]::Max(1, [int][Math]::Floor($script:MemTotalGB)) }
    if ($script:MemVmGB -gt 0) {
        $v = [int][Math]::Round($script:MemVmGB)
        $script:numMem.Value = [Math]::Max([int]$script:numMem.Minimum, [Math]::Min([int]$script:numMem.Maximum, $v))
    }
    Update-MemoryUi
}

function Invoke-Engine([string[]]$EngineArgs) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`" " + ($EngineArgs -join " ")
    $p = Start-Process powershell.exe -ArgumentList $argLine -WindowStyle Normal -PassThru -Wait
    return [int]$p.ExitCode
}

function Refresh-All {
    Update-Environment                       # スケジューラ・bcd・EdgeBox 状態・メモリを読み直す
    $script:UnderMinroot = ($script:VisibleLps -lt $script:TotalLps)
    Update-Header
    Sync-MemoryControl
    Update-Validation
}

$script:btnApps.Add_Click({ Show-AppsDialog })

# 各コアの負荷とメモリをリアルタイム表示する別ウィンドウ (cpu-monitor.ps1)
$script:btnMon.Add_Click({
    $mon = Join-Path $PSScriptRoot "cpu-monitor.ps1"
    if (-not (Test-Path $mon)) { Show-Info "cpu-monitor.ps1 が見つかりません。update.cmd で更新してください。" "Warning"; return }
    try {
        Start-Process powershell.exe -ArgumentList (
            "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$mon`" -VMName `"$($script:VmNameSel)`"")
    } catch { Show-Info "監視ウィンドウを開けませんでした: $($_.Exception.Message)" "Warning" }
})

$script:cmbVm.Add_SelectedIndexChanged({
    if ($script:cmbVm.SelectedItem) { $script:VmNameSel = [string]$script:cmbVm.SelectedItem }
    Refresh-All
})
# 一覧に無い 登録名 (これから作る EdgeBox) も入力できるようにする
$script:cmbVm.Add_Leave({
    $t = ([string]$script:cmbVm.Text).Trim()
    if ($t -and $t -ne $script:VmNameSel) { $script:VmNameSel = $t; Refresh-All }
})
$script:numMem.Add_ValueChanged({ Update-MemoryUi })

$script:btnMem.Add_Click({
    $g = [int]$script:numMem.Value
    $running = ($script:Vm -and ([string]$script:Vm.State -ne "Off"))
    $hostGB = [Math]::Round($script:MemTotalGB - $g, 1)
    $msg = "登録『$($script:VmNameSel)』のメモリを $($script:MemVmGB) GB → $g GB に変更します。`n" +
           "Windows 側に残るメモリ: $hostGB GB`n`n"
    if ($running) {
        $msg += "EdgeBox は実行中です。反映には EdgeBox の再起動が必要です。`n" +
                "今すぐ『停止 → 設定 → 起動』を行いますか?`n" +
                "(収集が数分止まります。正常にシャットダウンできない場合は何も変更せず中止します)"
    } else {
        $msg += "EdgeBox は停止中のため、すぐに反映されます。よろしいですか?"
    }
    $r = [System.Windows.Forms.MessageBox]::Show($msg, "メモリの割り当て",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $a = @("-MemoryGB", "$g", "-VMName", "`"$($script:VmNameSel)`"", "-NoConfirm")
    if ($running) { $a += "-RestartVM" }
    $form.Enabled = $false
    try { $code = Invoke-Engine $a } finally { $form.Enabled = $true }
    Refresh-All
    if ($code -eq 0) {
        Show-Info "メモリを設定しました。`n`n  Windows            : $hostGB GB`n  $($script:VmNameSel) : $g GB"
    } else {
        $tail = ""
        try {
            $lp = Join-Path $PSScriptRoot "cpu-partition-log.txt"
            if (Test-Path $lp) { $tail = ((Get-Content $lp -Encoding UTF8 -Tail 6) -join "`n") }
        } catch { }
        Show-Info ("メモリを変更できませんでした (終了コード $code)。`n表示されたウィンドウの内容をご確認ください。" +
            $(if ($tail) { "`n`n--- 記録の末尾 ---`n$tail" } else { "" })) "Warning"
    }
})

$script:btnFix.Add_Click({
    $n = @($script:Cores | Where-Object { $_.State -eq "Host" }).Count
    if ($n -lt 1) { $n = 1 }
    foreach ($c in $script:Cores) { $c.State = $(if ($c.Id -lt $n) { "Host" } else { "Guest" }) }
    Sync-AllTiles
    Update-Validation
})

$script:btnApply.Add_Click({
    $sel = Get-Selection
    $mode = "full"          # 方式は完全分離のみ
    $hostText  = ConvertTo-LpRangeText $sel.HostLps
    $guestText = ConvertTo-LpRangeText $sel.GuestLps
    $verb = if ($script:VmMissing) { "保存します (EdgeBox を作成・起動した時点で自動適用)" } else { "適用します" }
    $confirm = "次の内容で${verb}。`n`n" +
        "  Windows            : CPU $hostText  ($($sel.HostCores) コア)`n" +
        "  $($script:VmNameSel) : CPU $guestText  ($($sel.GuestCores) コア)`n`n" +
        "この後 PC の再起動が 1 回必要です (再起動後は自動で完了します)。`n`n" +
        "よろしいですか?"
    $r = [System.Windows.Forms.MessageBox]::Show($confirm, "CPU コア割り当て",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $a = @("-Apply", "-Mode", $mode, "-VMName", "`"$($script:VmNameSel)`"",
           "-HostLps", "`"$hostText`"", "-GuestLps", "`"$guestText`"", "-NoConfirm")
    if ($mode -eq "full" -and $script:chkTools.Checked) { $a += "-AutoGetTools" }
    if ($script:VmMissing) { $a += "-AllowMissingVM" }
    $form.Enabled = $false
    try { $code = Invoke-Engine $a } finally { $form.Enabled = $true }
    Refresh-All

    if ($code -ne 0) {
        # 失敗の理由はエンジンがログへ必ず書くので、その末尾をここに出す
        $tail = ""
        try {
            $logPath = Join-Path $PSScriptRoot "cpu-partition-log.txt"
            if (Test-Path $logPath) {
                $tail = ((Get-Content $logPath -Encoding UTF8 -Tail 8) -join "`n")
            }
        } catch { }
        $msg = "適用できませんでした (終了コード $code)。"
        if ($tail) { $msg += "`n`n--- cpu-partition-log.txt の末尾 ---`n$tail" }
        else { $msg += "`n`n表示されたウィンドウの内容をご確認ください。" }
        Show-Info $msg "Warning"
        return
    }
    # full の第 1 段階 (設定書き込み済み・未反映) なら再起動を案内する
    $pending = $script:Bcd -and ($script:Bcd.RootProc -gt 0) -and ($script:VisibleLps -ne $script:Bcd.RootProc)
    if ($mode -eq "full" -and $pending) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "設定を書き込みました。`n`n" +
            "PC を再起動すると、EdgeBox を割り当てたコアに固定してから起動します (以後、起動のたびに自動)。`n" +
            "成立したかは、この画面の上部か『EdgeBox 監視』の「分離の状態」で確認できます。`n`n" +
            "今すぐ再起動しますか?", "CPU コア割り当て",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
        return
    }
    if ($script:VmMissing) {
        Show-Info ("保存しました。`n`n  Windows            : CPU $hostText`n  $($script:VmNameSel) : CPU $guestText`n`n" +
            "登録『$($script:VmNameSel)』を作成して起動すると、この割り当てが自動で適用されます。`n" +
            "(EdgeBox の起動を検出して自動で適用します)")
    } else {
    Show-Info ("適用しました。`n`n  Windows            : CPU $hostText`n  $($script:VmNameSel) : CPU $guestText`n`n" +
        "『EdgeBox 監視』の「分離の状態」で、実際にどのコアで動いているか確認できます。")
    }
})


# ============================================================
#  コアを選ぶダイアログ (アプリ用)
# ============================================================
function Show-CoreChooser([int[]]$Preselect, [string]$Title, [int[]]$GuestLps) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $Title
    $d.ClientSize = New-Object System.Drawing.Size(700, 470)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.Font = New-Object System.Drawing.Font("Meiryo UI", 9)

    $lbl = New-Lbl "このアプリを動かすコアを選びます (複数選択可)。EdgeBox 用のコアは選べないため表示していません。" 12 10 660
    $d.Controls.Add($lbl)

    $fp = New-Object System.Windows.Forms.FlowLayoutPanel
    $fp.Location = New-Object System.Drawing.Point(12, 36)
    $fp.Size = New-Object System.Drawing.Size(676, 340)
    $fp.AutoScroll = $true
    $fp.WrapContents = $true
    $d.Controls.Add($fp)

    $boxes = @{}
    foreach ($c in $script:Cores) {
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { continue }   # EdgeBox 用は選ばせない
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "{0}  (CPU {1})" -f $c.Label, (ConvertTo-LpRangeText $c.Lps)
        $cb.Size = New-Object System.Drawing.Size(158, 24)
        $cb.Margin = New-Object System.Windows.Forms.Padding(3)
        $cb.Tag = $c.Id
        $cb.Checked = (@($c.Lps | Where-Object { $Preselect -contains $_ }).Count -gt 0)
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { $cb.BackColor = $ColGuest }
        $boxes[$c.Id] = $cb
        $fp.Controls.Add($cb)
    }

    $setBoxes = {
        param([string]$Kind)
        foreach ($c in $script:Cores) {
            $b = $boxes[$c.Id]
            if (-not $b) { continue }
            switch ($Kind) {
                "host"  { $b.Checked = ($c.State -eq "Host") }
                "p"     { $b.Checked = ($c.Kind -eq "P" -and $c.State -ne "Guest") }
                "e"     { $b.Checked = ($c.Kind -eq "E" -and $c.State -ne "Guest") }
                default { $b.Checked = $false }
            }
        }
    }
    $qx = 12
    foreach ($q in @(
        @{ T = "Windows 側すべて"; K = "host"; W = 150 },
        @{ T = "P コアのみ";       K = "p";    W = 110 },
        @{ T = "E コアのみ";       K = "e";    W = 110 },
        @{ T = "クリア";           K = "none"; W = 90  })) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $q.T
        $b.Location = New-Object System.Drawing.Point($qx, 386)
        $b.Size = New-Object System.Drawing.Size($q.W, 28)
        $kind = $q.K
        $b.Add_Click({ & $setBoxes $kind }.GetNewClosure())
        $d.Controls.Add($b)
        $qx += $q.W + 8
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"; $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(464, 428)
    $ok.Size = New-Object System.Drawing.Size(110, 30)
    $ng = New-Object System.Windows.Forms.Button
    $ng.Text = "キャンセル"; $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(580, 428)
    $ng.Size = New-Object System.Drawing.Size(108, 30)
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

    if ($d.ShowDialog() -ne "OK") { return $null }
    $lps = @()
    foreach ($c in $script:Cores) { if ($boxes[$c.Id] -and $boxes[$c.Id].Checked) { $lps += $c.Lps } }
    $lps = @($lps | Sort-Object -Unique)
    if ($lps.Count -eq 0) {
        Show-Info "コアが 1 つも選ばれていません。変更しませんでした。" "Warning"
        return $null
    }
    return ,$lps
}

# ============================================================
#  実行中のアプリから選ぶダイアログ
# ============================================================
function Show-ProcessPicker {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = "実行中のアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(660, 460)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.Font = New-Object System.Drawing.Font("Meiryo UI", 9)
    $d.Controls.Add((New-Lbl "登録したいアプリを選んでください (ウィンドウを持つアプリを上に表示します)。" 12 10 630))

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = New-Object System.Drawing.Point(12, 34)
    $lb.Size = New-Object System.Drawing.Size(636, 370)
    $d.Controls.Add($lb)

    $entries = @()
    $groups = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -notmatch '^(Idle|System|Registry|Memory Compression)$' } |
        Group-Object ProcessName)
    foreach ($g in $groups) {
        $path = $null
        $titled = $false
        foreach ($pr in $g.Group) {
            try { if (-not $path -and $pr.Path) { $path = $pr.Path } } catch { }
            try { if ($pr.MainWindowHandle -ne 0) { $titled = $true } } catch { }
        }
        $entries += [pscustomobject]@{
            Name = $g.Name; Exe = $path; Count = $g.Count; Titled = $titled
        }
    }
    $entries = @($entries | Sort-Object @{ Expression = "Titled"; Descending = $true }, Name)
    foreach ($e in $entries) {
        [void]$lb.Items.Add(("{0}  ({1} 個)   {2}" -f $e.Name, $e.Count, $(if ($e.Exe) { $e.Exe } else { "(パス不明)" })))
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "追加"; $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(424, 416)
    $ok.Size = New-Object System.Drawing.Size(110, 30)
    $ng = New-Object System.Windows.Forms.Button
    $ng.Text = "キャンセル"; $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(540, 416)
    $ng.Size = New-Object System.Drawing.Size(108, 30)
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

    if ($d.ShowDialog() -ne "OK" -or $lb.SelectedIndex -lt 0) { return $null }
    return $entries[$lb.SelectedIndex]
}

# ============================================================
#  インストール済みアプリの一覧 (スタートメニュー・デスクトップのショートカット +
#  レジストリの「プログラムのアンインストール」情報から実行ファイルを集める)
# ============================================================
function Get-InstalledApps {
    $shell = New-Object -ComObject WScript.Shell
    $found = @{}   # 実行ファイルのパス (小文字) → エントリ

    function Add-Found([string]$Name, [string]$Exe, [string]$Source) {
        if (-not $Exe) { return }
        $Exe = $Exe.Trim('"')
        if ($Exe -notmatch '\.exe$') { return }
        if (-not (Test-Path -LiteralPath $Exe)) { return }
        $key = $Exe.ToLowerInvariant()
        # アンインストーラーや自分自身の起動用ラッパーは除外
        if ($Name -match '(?i)uninstall|アンインストール|削除') { return }
        if ($key -match '\\(wscript|cscript|schtasks|powershell|cmd|msiexec|rundll32|explorer)\.exe$') { return }
        if ($found.ContainsKey($key)) {
            if ($Name.Length -lt $found[$key].Name.Length) { $found[$key].Name = $Name }   # 短い名前を採用
            return
        }
        $found[$key] = [pscustomobject]@{ Name = $Name; Exe = $Exe; Source = $Source }
    }

    # a) ショートカット (.lnk)
    $dirs = @(
        [Environment]::GetFolderPath("CommonPrograms"),
        [Environment]::GetFolderPath("Programs"),
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        [Environment]::GetFolderPath("Desktop")
    )
    foreach ($dir in $dirs) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        foreach ($f in @(Get-ChildItem -Path $dir -Filter *.lnk -Recurse -File -ErrorAction SilentlyContinue)) {
            try {
                $lnk = $shell.CreateShortcut($f.FullName)
                $target = [string]$lnk.TargetPath
                if ($target) {
                    $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                    Add-Found $name $target "ショートカット"
                }
            } catch { }
        }
    }

    # b) レジストリ (DisplayIcon が実行ファイルを指しているもの)
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($rp in $regPaths) {
        foreach ($k in @(Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue)) {
            try {
                $dn = [string]$k.DisplayName
                $ic = [string]$k.DisplayIcon
                if (-not $dn -or -not $ic) { continue }
                $ic = ($ic -split ',')[0].Trim().Trim('"')
                Add-Found $dn $ic "インストール情報"
            } catch { }
        }
    }
    return @($found.Values | Sort-Object Name)
}

function Show-InstalledAppPicker {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = "インストール済みのアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(760, 520)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "Sizable"
    $d.MinimumSize = New-Object System.Drawing.Size(520, 360)
    $d.Font = New-Object System.Drawing.Font("Meiryo UI", 9)

    $d.Controls.Add((New-Lbl "登録したいアプリを選んでください。名前の一部を入力すると絞り込めます。" 12 10 700))
    $d.Controls.Add((New-Lbl "絞り込み:" 12 38))
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(80, 35)
    $tb.Size = New-Object System.Drawing.Size(400, 24)
    $tb.Anchor = "Top,Left,Right"
    $d.Controls.Add($tb)
    $lblCount = New-Lbl "" 490 38 250
    $lblCount.Anchor = "Top,Right"
    $d.Controls.Add($lblCount)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 64)
    $lv.Size = New-Object System.Drawing.Size(736, 400)
    $lv.Anchor = "Top,Bottom,Left,Right"
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $true
    [void]$lv.Columns.Add("アプリ名", 260)
    [void]$lv.Columns.Add("実行ファイル", 400)
    [void]$lv.Columns.Add("情報源", 70)
    $d.Controls.Add($lv)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "追加"; $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(524, 476)
    $ok.Size = New-Object System.Drawing.Size(110, 30)
    $ok.Anchor = "Bottom,Right"
    $ng = New-Object System.Windows.Forms.Button
    $ng.Text = "キャンセル"; $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(640, 476)
    $ng.Size = New-Object System.Drawing.Size(108, 30)
    $ng.Anchor = "Bottom,Right"
    $d.Controls.AddRange(@($ok, $ng))
    $d.AcceptButton = $ok; $d.CancelButton = $ng

    $d.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $all = @(Get-InstalledApps)
    $d.Cursor = [System.Windows.Forms.Cursors]::Default

    $script:InstShown = @()
    function Fill-List([string]$Filter) {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $script:InstShown = @()
        foreach ($e in $all) {
            if ($Filter -and ($e.Name -notlike "*$Filter*") -and ($e.Exe -notlike "*$Filter*")) { continue }
            $it = New-Object System.Windows.Forms.ListViewItem($e.Name)
            [void]$it.SubItems.Add($e.Exe)
            [void]$it.SubItems.Add($e.Source)
            [void]$lv.Items.Add($it)
            $script:InstShown += $e
        }
        $lv.EndUpdate()
        $lblCount.Text = "{0} 件 / 全 {1} 件" -f $script:InstShown.Count, $all.Count
    }
    Fill-List ""
    $tb.Add_TextChanged({ Fill-List $tb.Text.Trim() })
    $lv.Add_DoubleClick({ if ($lv.SelectedIndices.Count -gt 0) { $d.DialogResult = "OK"; $d.Close() } })

    if ($d.ShowDialog() -ne "OK" -or $lv.SelectedIndices.Count -eq 0) { return $null }
    return $script:InstShown[$lv.SelectedIndices[0]]
}

# ============================================================
#  アプリの割り当てダイアログ
# ============================================================
function Show-AppsDialog {
    $sel = Get-Selection
    $work = New-Object System.Collections.ArrayList
    foreach ($a in $script:Apps) {
        [void]$work.Add([pscustomobject]@{
            Name = [string]$a.Name; Exe = [string]$a.Exe; Match = [string]$a.Match
            Lps = @([int[]]$a.Lps); Priority = $(if ($a.Priority) { [string]$a.Priority } else { "通常" })
        })
    }

    $d = New-Object System.Windows.Forms.Form
    $d.Text = "アプリの割り当て"
    $d.ClientSize = New-Object System.Drawing.Size(880, 540)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.Font = New-Object System.Drawing.Font("Meiryo UI", 9)

    $d.Controls.Add((New-Lbl "登録したアプリは、起動のたびに指定したコアへ自動で固定されます (1 分ごとに確認)。" 12 10 850))

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 34)
    $lv.Size = New-Object System.Drawing.Size(856, 330)
    $lv.View = "Details"
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.GridLines = $true
    [void]$lv.Columns.Add("アプリ名", 190)
    [void]$lv.Columns.Add("実行ファイル", 380)
    [void]$lv.Columns.Add("割り当てコア", 170)
    [void]$lv.Columns.Add("優先度", 80)
    $d.Controls.Add($lv)

    function Sync-AppList {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($a in $work) {
            $it = New-Object System.Windows.Forms.ListViewItem([string]$a.Name)
            [void]$it.SubItems.Add($(if ($a.Exe) { [string]$a.Exe } else { "(名前で照合: " + $a.Match + ")" }))
            [void]$it.SubItems.Add((ConvertTo-LpRangeText @([int[]]$a.Lps)))
            [void]$it.SubItems.Add([string]$a.Priority)
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()
    }

    function Get-SelectedApp {
        if ($lv.SelectedIndices.Count -eq 0) { return $null }
        return $work[$lv.SelectedIndices[0]]
    }

    function Add-App([string]$Name, [string]$Exe, [string]$Match) {
        $defaultLps = @($sel.HostLps)
        if ($defaultLps.Count -eq 0) { $defaultLps = @(0) }
        [void]$work.Add([pscustomobject]@{
            Name = $Name; Exe = $Exe; Match = $Match; Lps = $defaultLps; Priority = "通常"
        })
        Sync-AppList
        $lv.Items[$work.Count - 1].Selected = $true
    }

    $bx = 12
    $btnInst = New-Object System.Windows.Forms.Button
    $btnInst.Text = "インストール済みから追加..."
    $btnInst.Location = New-Object System.Drawing.Point($bx, 374)
    $btnInst.Size = New-Object System.Drawing.Size(210, 30)
    $btnInst.Add_Click({
        $e = Show-InstalledAppPicker
        if ($e) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($e.Exe)
            Add-App $e.Name $e.Exe $base
        }
    })
    $bx += 218

    $btnFile = New-Object System.Windows.Forms.Button
    $btnFile.Text = "ファイルから追加..."
    $btnFile.Location = New-Object System.Drawing.Point($bx, 374)
    $btnFile.Size = New-Object System.Drawing.Size(150, 30)
    $btnFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "実行ファイル (*.exe)|*.exe|すべてのファイル (*.*)|*.*"
        $ofd.Title = "登録するアプリの実行ファイルを選んでください"
        if ($ofd.ShowDialog() -eq "OK") {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName)
            Add-App $base $ofd.FileName $base
        }
    })
    $bx += 158

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "実行中から追加..."
    $btnRun.Location = New-Object System.Drawing.Point($bx, 374)
    $btnRun.Size = New-Object System.Drawing.Size(150, 30)
    $btnRun.Add_Click({
        $e = Show-ProcessPicker
        if ($e) { Add-App $e.Name $(if ($e.Exe) { $e.Exe } else { "" }) $e.Name }
    })
    $bx += 158

    $btnCores = New-Object System.Windows.Forms.Button
    $btnCores.Text = "コアを編集..."
    $btnCores.Location = New-Object System.Drawing.Point($bx, 374)
    $btnCores.Size = New-Object System.Drawing.Size(130, 30)
    $btnCores.Add_Click({
        $a = Get-SelectedApp
        if (-not $a) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $lps = Show-CoreChooser @([int[]]$a.Lps) ("コアの選択 - " + $a.Name) @($sel.GuestLps)
        if ($lps) { $a.Lps = @($lps); Sync-AppList }
    })
    $bx += 138

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text = "削除"
    $btnDel.Location = New-Object System.Drawing.Point($bx, 374)
    $btnDel.Size = New-Object System.Drawing.Size(90, 30)
    $btnDel.Add_Click({
        if ($lv.SelectedIndices.Count -eq 0) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $work.RemoveAt($lv.SelectedIndices[0])
        Sync-AppList
    })
    $d.Controls.AddRange(@($btnInst, $btnFile, $btnRun, $btnCores, $btnDel))

    $d.Controls.Add((New-Lbl "選んだアプリの優先度:" 12 418))
    $cmbPri = New-Object System.Windows.Forms.ComboBox
    $cmbPri.Location = New-Object System.Drawing.Point(170, 415)
    $cmbPri.Size = New-Object System.Drawing.Size(120, 24)
    $cmbPri.DropDownStyle = "DropDownList"
    [void]$cmbPri.Items.AddRange(@("通常", "高", "低"))
    $cmbPri.SelectedIndex = 0
    $cmbPri.Add_SelectedIndexChanged({
        $a = Get-SelectedApp
        if ($a -and $a.Priority -ne [string]$cmbPri.SelectedItem) {
            $a.Priority = [string]$cmbPri.SelectedItem
            Sync-AppList
        }
    })
    $d.Controls.Add($cmbPri)
    $lv.Add_SelectedIndexChanged({
        $a = Get-SelectedApp
        if ($a) { $cmbPri.SelectedItem = [string]$a.Priority }
    })

    $note = New-Lbl "『高』は取り合いになったときに優先されます。EdgeBox 用のコアは避けてください (EdgeBox と取り合いになります)。" 12 448 850
    $note.ForeColor = [System.Drawing.Color]::DimGray
    $d.Controls.Add($note)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "保存して適用"; $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(624, 490)
    $ok.Size = New-Object System.Drawing.Size(130, 32)
    $ng = New-Object System.Windows.Forms.Button
    $ng.Text = "キャンセル"; $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(760, 490)
    $ng.Size = New-Object System.Drawing.Size(108, 32)
    $d.Controls.AddRange(@($ok, $ng))
    $d.CancelButton = $ng

    Sync-AppList
    if ($d.ShowDialog() -ne "OK") { return }

    # --- 一覧から外したアプリは、いま動いている分の固定を解除しておく ---
    $keep = @($work | ForEach-Object { [string]$_.Match })
    $total = [Math]::Min($script:TotalLps, 63)
    $allMask = [int64]0
    for ($i = 0; $i -lt $total; $i++) { $allMask = $allMask -bor ([int64]1 -shl $i) }
    foreach ($old in $script:Apps) {
        if ($keep -contains [string]$old.Match) { continue }
        foreach ($pr in @(Get-Process -Name ([string]$old.Match) -ErrorAction SilentlyContinue)) {
            try {
                $pr.ProcessorAffinity = [IntPtr]$allMask
                $pr.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
            } catch { }
        }
    }

    # --- 保存して即適用 (以後は自動タスクが 1 分ごとに適用し直す) ---
    $script:Apps = @($work)
    Save-AppsFile $script:Apps
    # 適用エンジンの結果は必ず確認する。失敗を握りつぶすと
    # 「自動で固定します」と表示しているのに何も設定されていない、という状態になる
    $engineErr = ""
    if (Test-Path $AppsEngine) {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$AppsEngine`" -Apply -Quiet"
        if ($script:Apps.Count -gt 0) { $argLine += " -Install" }
        try {
            $pApply = Start-Process powershell.exe -ArgumentList $argLine `
                -WindowStyle Hidden -Wait -PassThru
            if ($pApply.ExitCode -ne 0) { $engineErr = "適用エンジンが終了コード $($pApply.ExitCode) で終了しました" }
        } catch {
            $engineErr = $_.Exception.Message
        }
        if ($script:Apps.Count -eq 0) {
            try {
                Start-Process powershell.exe -WindowStyle Hidden -Wait -ArgumentList (
                    "-NoProfile -ExecutionPolicy Bypass -File `"$AppsEngine`" -Uninstall -Quiet") | Out-Null
            } catch { }
        }
    } else {
        $engineErr = "適用エンジン cpu-apps.ps1 が見つかりません"
    }
    Update-Validation

    if ($engineErr) {
        $tail = ""
        if (Test-Path $AppsLog) {
            try { $tail = "`n`n[記録の末尾]`n" + ((Get-Content $AppsLog -Tail 5) -join "`n") } catch { }
        }
        Show-Info ("登録内容は保存しましたが、適用できませんでした。`n$engineErr" +
            "`n`n自動で固定し直す設定は入っていません。" + $tail) "Warning"
    } else {
        Show-Info "アプリの割り当てを保存しました ($($script:Apps.Count) 件)。`n実行中のアプリには今すぐ反映し、以後は起動のたびに自動で固定します。"
    }
}

# ============================================================
#  表示
# ============================================================
Sync-AllTiles
Update-Header
Sync-MemoryControl
$form.Add_Shown({ Update-Validation })
# 画面の並べ直し: 「この PC の CPU」を 1 行増やし (+22)、かんたん設定の行を無くした (-34) 分を詰める
foreach ($ctl in @($form.Controls)) {
    if ($ctl -eq $grpMode) { $ctl.Top += 22 }
    elseif ($ctl.Top -ge 498) { $ctl.Top -= 66 }   # 12 + 34 (方式欄) + 20 (説明行)
    elseif ($ctl.Top -ge 224) { $ctl.Top -= 46 }   # 12 + 34 (方式欄)
}
$maxBottom = 0
foreach ($ctl in @($form.Controls)) { if ($ctl.Bottom -gt $maxBottom) { $maxBottom = $ctl.Bottom } }
$form.ClientSize = New-Object System.Drawing.Size($form.ClientSize.Width, ($maxBottom + 16))

[void]$form.ShowDialog()
