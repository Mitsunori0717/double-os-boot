<#
.SYNOPSIS
    CPU コア割り当ての設定コンソール (GUI)。
    P コア / E コアを画面で直接選んで、Windows とEdge Box に振り分けます。

.DESCRIPTION
    - この PC の実際のコア構成を検出して 1 コア = 1 タイルで表示します
      (Intel 12世代以降の P コア/E コアは、CPU が申告する効率クラスで判別)
    - 各コアは Windows 用か Edge Box 用のどちらか。クリックで切り替えられるのは分割の境目の両側のタイルだけです
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
    # Edge Box に最低限割り当てるべき物理コア数 (安全装置)。E コア 8 個を Edge Box 専用にする運用が既定
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
$MemGuestMinGB    = 4    # Edge Box の最低量
$MemGuestRecGB    = 8    # Edge Box の推奨量
$TaskName     = "CpuPartition-Console"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Info([string]$Text, [string]$Icon = "Information") {
    # 画面の部品 (cpu-ui-theme.ps1) を読み込んだ後は、画面と同じ見た目のダイアログで出す
    if ("CoreUi.MessageDialog" -as [type]) {
        [void](Show-UiMessage $Text "CPU コア割り当て" "OK" $Icon)
        return
    }
    $ic = [System.Windows.Forms.MessageBoxIcon]::Information
    if     ($Icon -eq "Warning") { $ic = [System.Windows.Forms.MessageBoxIcon]::Warning }
    elseif ($Icon -eq "Error")   { $ic = [System.Windows.Forms.MessageBoxIcon]::Error }
    [System.Windows.Forms.MessageBox]::Show($Text, "CPU コア割り当て",
        [System.Windows.Forms.MessageBoxButtons]::OK, $ic) | Out-Null
}

# はい / いいえ の確認 (戻り値は MessageBox と同じ DialogResult)
function Show-Ask([string]$Text, [string]$Caption = "CPU コア割り当て", [string]$Icon = "Question") {
    if ("CoreUi.MessageDialog" -as [type]) { return (Show-UiMessage $Text $Caption "YesNo" $Icon) }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]$Icon)
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

    # アイコン: 濃いパッケージ (画面の配色とは別)、Windows = 青 / Edge Box = 橙
    $body = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 24, 32))
    $pins = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(138, 152, 168))
    $win  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(86, 180, 255))
    $vm   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(242, 166, 90))

    foreach ($i in 0..3) {                      # CPU の足
        $o = 62 + $i * 40
        $g.FillRectangle($pins, $o, 18, 18, 30)
        $g.FillRectangle($pins, $o, 208, 18, 30)
        $g.FillRectangle($pins, 18, $o, 30, 18)
        $g.FillRectangle($pins, 208, $o, 30, 18)
    }
    $g.FillRectangle($body, 46, 46, 164, 164)   # パッケージ
    $g.DrawRectangle((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(53, 67, 82), 4)), 48, 48, 160, 160)
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

    # --- リアルタイム監視『Edge Box 監視』も同じ仕組みで登録する ---
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
                "' Edge Box 監視 — 起動用ラッパー (黒い窓を出さない)",
                "CreateObject(""WScript.Shell"").Run ""schtasks.exe /run /tn """"$monTask"""""", 0, False")
            $micoPath = Join-Path $PSScriptRoot "cpu-monitor.ico"
            $miconRef = "shell32.dll,22"
            try { New-ConsoleIcon $micoPath "monitor"; if (Test-Path $micoPath) { $miconRef = "$micoPath,0" } } catch { }
            foreach ($dir in @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))) {
                Remove-Item (Join-Path $dir "EdgeBox 監視.lnk") -Force -ErrorAction SilentlyContinue   # 旧名のアイコン
            }
            foreach ($lnkPath in @((Join-Path ([Environment]::GetFolderPath("Desktop"))  "Edge Box 監視.lnk"),
                                   (Join-Path ([Environment]::GetFolderPath("Programs")) "Edge Box 監視.lnk"))) {
                $lnk = $shell.CreateShortcut($lnkPath)
                $lnk.TargetPath       = Join-Path $env:SystemRoot "System32\wscript.exe"
                $lnk.Arguments        = "`"$mvbs`""
                $lnk.WorkingDirectory = $PSScriptRoot
                $lnk.IconLocation     = $miconRef
                $lnk.Description      = "各コアの負荷をリアルタイムで表示"
                $lnk.Save()
            }
            $monOk = $true
        } catch {
            Write-Host "  (『Edge Box 監視』の登録に失敗しました: $($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    Write-Host "『CPU割り当て』を登録しました。" -ForegroundColor Green
    Write-Host "  - デスクトップのアイコン" -ForegroundColor Green
    Write-Host "  - スタートメニュー (「CPU」で検索しても出ます)" -ForegroundColor Green
    if ($monOk) { Write-Host "『Edge Box 監視』(各コアの負荷のリアルタイム表示) も同じ場所に登録しました。" -ForegroundColor Green }
    Write-Host "  PowerShell を開く必要はありません。黒い窓も出ません。" -ForegroundColor Green
    Write-Host "  タスクバーに置くには、スタートメニューで右クリック →『タスクバーにピン留めする』" -ForegroundColor Cyan
    exit 0
}

# 画面の見た目 (配色・文字・部品)。設定の処理は持たない
try {
    . (Join-Path $PSScriptRoot "cpu-ui-theme.ps1")
} catch {
    Show-Info ("画面の部品 (cpu-ui-theme.ps1) を読み込めませんでした。update.cmd で更新してください。`n`n" + $_.Exception.Message) "Error"
    exit 1
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
    # メモリ: PC 全体と Edge Box の設定値
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
# その名前の登録が無ければ (名前を変えた等)、Edge Box の物理ディスクを持つ登録か 1 つしかない登録を選ぶ
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
# 混成 CPU の既定の割り当て: 末尾の E コアを $MinGuestCores 個 (足りなければ全部) Edge Box に、残りは Windows に
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
    # 既定の初期表示: 混成 CPU なら「末尾の E コア 8 個 = Edge Box / 残り (P コア全部 + 先頭の E コア) = Windows」、
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
#  左メニュー (アプリ名・HOME・SETTING・MONITOR) / 各画面 / 下の操作バー。
#  見た目は cpu-ui-theme.ps1 の部品が描く。ここでは配置と、既存の処理とのつなぎだけを行う
# ============================================================
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

# --- 左メニュー (最上部にアプリ名。ヘッダーは置かず、メニューを上端まで伸ばす) ---
$script:sidebar = New-Object CoreUi.Strip
$script:sidebar.BackColor = [CoreUi.Theme]::Sidebar
$script:sidebar.Line = "Right"
$script:sidebar.Dock = "Left"
$script:sidebar.Width = 220
$script:sidebar.Padding = New-Object System.Windows.Forms.Padding(0, 14, 1, 0)

$script:brand = New-Object CoreUi.SideBrand
$script:brand.Text = $UiAppName

$script:Pages = [ordered]@{}
$script:NavItems = @{}
$navDefs = @(
    @{ Key = "core";     Text = "HOME";    Glyph = "cores" },
    @{ Key = "settings"; Text = "SETTING"; Glyph = "settings" }
)
$navList = @()
$k = 1
foreach ($nd in $navDefs) {
    $n = New-Object CoreUi.NavItem
    $n.Height = 46
    $n.Text = $nd.Text
    $n.Glyph = $nd.Glyph
    $n.Tag = $nd.Key
    $n.Add_Click({ param($s, $e) Show-Page ([string]$s.Tag) })
    $script:Tip.SetToolTip($n, ("{0}   (Ctrl+{1})" -f $nd.Text, $k))
    $script:NavItems[$nd.Key] = $n
    $navList += $n
    $k++
}
# 監視は別ウィンドウを開く項目 (画面の切り替えではないため選択状態にはならない)
$script:btnMon = New-Object CoreUi.NavItem
$script:btnMon.Height = 46
$script:btnMon.Text = "MONITOR"
$script:btnMon.Glyph = "monitor"
$script:Tip.SetToolTip($script:btnMon, "各コアの負荷を毎秒表示する別ウィンドウ (『Edge Box 監視』) を開きます")
Add-Stack $script:sidebar (@($script:brand) + $navList + @($script:btnMon)) 2

$navFoot = New-Object System.Windows.Forms.Panel
$navFoot.Dock = "Bottom"
$navFoot.Height = 44
$navFoot.BackColor = [CoreUi.Theme]::Sidebar
$navHint = New-UiLabel "Ctrl+1 / Ctrl+2 で画面を切り替え" 18 12 188 "small"
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

# 後から追加したものほど先に場所を取る: 左メニュー (上端から下端まで) → 操作バー → 画面
$form.Controls.Add($script:content)
$form.Controls.Add($script:footer)
$form.Controls.Add($script:sidebar)

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
#  HOME (Core Split) — コアのタイル・検査結果
# ============================================================
New-Page "core" "HOME" ""

# --- コアのタイル ---
# 分割の境界は 1 か所: 並びの先頭側が Windows 用、末尾側が Edge Box 用 (完全分離の条件と同じ形)。
# 混成 CPU では P コアは Windows 専用のため並びに入れず、E コアだけを並べる
function Get-SplitLine {
    return @($script:Cores | Where-Object { -not $script:Hybrid -or $_.Kind -ne "P" } | Sort-Object Id)
}

# 未割当は使わない。読み込んだ割り当てが境界 1 か所の形でなければ、Edge Box 用の数を保ったまま末尾へ寄せる
function Initialize-SplitStates {
    foreach ($c in $script:Cores) { if ($script:Hybrid -and $c.Kind -eq "P") { $c.State = "Host" } }
    $line = Get-SplitLine
    $guest = @($line | Where-Object { $_.State -eq "Guest" }).Count
    for ($i = 0; $i -lt $line.Count; $i++) { $line[$i].State = $(if ($i -ge $line.Count - $guest) { "Guest" } else { "Host" }) }
}
Initialize-SplitStates

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
        # 切り替えられるのは境界の両側の 2 枚だけ (Windows 用の末尾 → Edge Box 用 / Edge Box 用の先頭 → Windows 用)。
        # それ以外を押しても何も変えない。適用できない形 (Edge Box 0 コア・Windows 2 コア未満) にもしない
        $line = Get-SplitLine
        $i = -1
        for ($j = 0; $j -lt $line.Count; $j++) { if ($line[$j].Id -eq $c.Id) { $i = $j; break } }
        $edge = @($line | Where-Object { $_.State -eq "Host" }).Count   # 境界の位置 (先頭から Windows 用の数)
        $hostTotal  = @($script:Cores | Where-Object { $_.State -eq "Host" }).Count
        $guestTotal = @($script:Cores | Where-Object { $_.State -eq "Guest" }).Count
        if ($i -ge 0 -and $i -eq $edge - 1 -and $hostTotal -gt 2) { $c.State = "Guest" }
        elseif ($i -ge 0 -and $i -eq $edge -and $guestTotal -gt 1) { $c.State = "Host" }
        else { return }
        Sync-Tile $c
        Update-Validation
    })
    $script:Tip.SetToolTip($b, ("{0}  —  CPU {1}" -f $Core.Label, (ConvertTo-LpRangeText $Core.Lps)))
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
$grpChk = New-Card "検査結果" "" 214
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
New-Page "settings" "SETTING" ""

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
$grpMem = New-Card "メモリの割り当て" "" 172
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

# ============================================================
#  表示の同期 (既存の検査・状態の結果を、各画面の表示に写すだけ)
# ============================================================
# 適用済みの割り当て (cpu-partition.json)。表示の「変更の有無」にだけ使う
function Get-AppliedPlan {
    if (-not (Test-Path $ConfigFile)) { return $null }
    try {
        $wt = (Get-Item -LiteralPath $ConfigFile).LastWriteTimeUtc
        if (-not $script:AppliedCache -or $script:AppliedCache.At -ne $wt) {
            $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:AppliedCache = [pscustomobject]@{
                At    = $wt
                Host  = ((@([int[]]$j.HostLps) | Sort-Object) -join ",")
                Guest = ((@([int[]]$j.GuestLps) | Sort-Object) -join ",")
            }
        }
        return $script:AppliedCache
    } catch { return $null }
}

# 下の操作バーの表示: 検査の結果・変更の有無
function Update-SplitViews($Sel, [int]$ErrorCount = -1, [int]$WarnCount = 0) {
    if ($ErrorCount -lt 0) {
        $script:chipVerdict.Tone = "Muted"; $script:chipVerdict.Text = "確認中"
    } elseif ($ErrorCount -gt 0) {
        $script:chipVerdict.Tone = "Err"; $script:chipVerdict.Text = "適用できません  ·  不可 $ErrorCount 件"
    } else {
        $script:chipVerdict.Tone = "Ok"
        $script:chipVerdict.Text = "適用できます" + $(if ($WarnCount -gt 0) { "  ·  注意 $WarnCount 件" } else { "" })
    }
    $applied = Get-AppliedPlan
    $now = [pscustomobject]@{ Host = (@($Sel.HostLps) -join ","); Guest = (@($Sel.GuestLps) -join ",") }
    if (-not $applied) {
        $script:chipChange.Tone = "Muted"; $chg = "まだ適用していません"
    } elseif ($applied.Host -eq $now.Host -and $applied.Guest -eq $now.Guest) {
        $script:chipChange.Tone = "Muted"; $chg = "適用済みの内容と同じです"
    } else {
        $script:chipChange.Tone = "Warn"; $chg = "未適用の変更があります"
    }
    $script:chipChange.Text = $chg
    Update-FooterLayout
}

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

# 対象の Edge Box の状態 (Settings の「対象」に出す)
function Update-Header {
    if ($script:Vm) {
        $script:lblVm.Text = "状態: {0}    プロセッサ: {1}    メモリ: {2} GB{3}" -f $script:Vm.State, $script:Vcpu,
            $script:MemVmGB, $(if ($script:MemDynamic) { " (動的)" } else { "" })
    } elseif ($script:HyperVOk) {
        $script:lblVm.Text = "この名前の Edge Box が見つかりません"
    } else {
        $script:lblVm.Text = "Hyper-V が有効ではありません"
    }
}

function Update-Validation {
    $sel = Get-Selection
    $mode = "full"          # 方式は完全分離のみ
    $errors = @(); $warnings = @()

    $guestCoreObjs = @($script:Cores | Where-Object { $_.State -eq "Guest" })

    # --- 環境そのものが整っていない ---
    if (-not $script:HyperVOk) {
        $errors += "Hyper-V が有効ではありません。先に Hyper-V を有効化して再起動してください。"
    }
    $script:VmMissing = ($script:HyperVOk -and -not $script:Vm)
    if ($script:VmMissing) {
        if (-not $script:VmNameSel) {
            $errors += "対象の 登録名を入力してください。"
        } else {
            $warnings += "登録『$($script:VmNameSel)』はまだ見つかりません。この内容は保存され、Edge Box を作成して起動した時点で自動的に適用されます。"
        }
    }

    # --- 割り当ての量 ---
    if ($sel.GuestCores -lt 1) {
        $errors += "$($script:VmNameSel) にコアが 1 つも割り当てられていません。このままでは $($script:VmNameSel) を起動できません (コアを 1 つ以上、Edge Box 用にしてください)。"
    }
    if ($sel.HostCores -lt 2) {
        $errors += "Windows 側が $($sel.HostCores) コアです。最低 2 コア必要です (Edge Box のディスク/ネットワーク処理も Windows 側で動くため)。"
    } elseif ($sel.HostCores -lt 4) {
        $warnings += "Windows 側が 4 コア未満です。Edge Box の I/O 処理も Windows 側コアで動くため、$($script:VmNameSel) の通信・保存まで遅くなることがあります。"
    }
    if ($sel.NoneCores -gt 0) {
        $warnings += "未割当のコアが $($sel.NoneCores) 個あります (どちらからも積極的には使われません)。"
    }
    if ($sel.GuestLps.Count -gt 0 -and $sel.GuestLps.Count -lt 8) {
        $warnings += "$($script:VmNameSel) 側が $($sel.GuestLps.Count) スレッドです (Edge Box の元の構成 4 コア 8 スレッドを下回ります)。"
    }
    if ($script:Hybrid) {
        # Edge Box は E コア専用。P コアは Windows 側に残す (混ざらない・速さの違うコアを混ぜない)
        $gp0 = @($guestCoreObjs | Where-Object { $_.Kind -eq "P" })
        if ($gp0.Count -gt 0) { $errors += "$($script:VmNameSel) に P コアは割り当てられません ($(($gp0 | ForEach-Object { $_.Label }) -join ', '))。Edge Box は E コア専用です。" }
        # Edge Box 用の E コアは末尾に固めておく (full の minroot 条件 = Windows は先頭から連番 を満たすため)
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
    $script:FixVisible = $false
    $ok = $true
    for ($i = 0; $i -lt $sel.HostLps.Count; $i++) {
        if ($sel.HostLps[$i] -ne $i) { $ok = $false; break }
    }
    if (-not $ok -or $sel.HostLps.Count -eq 0) {
        $errors += "完全分離では Windows 側が CPU 0 から続き番号である必要があります。現在: CPU $(ConvertTo-LpRangeText $sel.HostLps)"
        $script:btnFix.Visible = $true
        $script:FixVisible = $true
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
            $warnings += "プロセッサ数 ($($script:Vcpu)) と割り当てスレッド数 ($($sel.GuestLps.Count)) が違います。Edge Box 停止中に適用すると自動調整されます。"
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
        $warnings += "アプリ『$($appOnGuest -join '、')』が $($script:VmNameSel) 用コアに割り当てられています (Edge Box と取り合いになります)。"
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
    foreach ($e in $errors)   { Add-Line ("[不可] " + $e) ([CoreUi.Theme]::ErrText) }
    foreach ($w in $warnings) { Add-Line ("[注意] " + $w) ([CoreUi.Theme]::WarnText) }
    if ($errors.Count -eq 0 -and $warnings.Count -eq 0) {
        Add-Line "問題ありません。この内容で適用できます。" ([CoreUi.Theme]::OkText)
    } elseif ($errors.Count -eq 0) {
        Add-Line "適用できます (上の注意点をご確認ください)。" ([CoreUi.Theme]::OkText)
    }
    # 先頭 ([不可] の行) が見えるように戻す
    $script:rtb.SelectionStart = 0
    $script:rtb.ScrollToCaret()
    $script:btnApply.Enabled = ($errors.Count -eq 0)
    if ($script:VmMissing) { $script:btnApply.Text = "保存 (Edge Box 検出後に自動適用)" }
    else { $script:btnApply.Text = "この内容で適用" }
    # 表示だけの更新。ここで失敗しても検査・適用の動作には影響させない
    try { Update-SplitViews $sel $errors.Count $warnings.Count } catch { }
}

# ============================================================
#  操作 (適用・解除・実測はすべて cpu-partition.ps1 に任せる)
# ============================================================
# --- メモリ欄の表示と検査 (適用そのものは cpu-partition.ps1 -MemoryGB に任せる) ---
function Update-MemoryUi {
    $total = [double]$script:MemTotalGB
    $script:lblMemPc.Text = if ($total -gt 0) { "この PC のメモリ: $total GB" } else { "この PC のメモリ: (取得できません)" }
    $script:lblMemVm.Text = "$($script:VmNameSel) に:"
    # 配分の帯 (Windows に残る量 / Edge Box に渡す量)。表示だけ
    try { $script:memBar.SetValues($total, $(if ($script:Vm) { [double]$script:numMem.Value } else { 0.0 })) } catch { }
    if (-not $script:Vm) {
        $script:lblMemHost.Text = ""
        $script:lblMemNote.Text = "Edge Box が見つからないため、メモリは変更できません (Edge Box を作成・検出してから)。"
        $script:lblMemNote.ForeColor = [CoreUi.Theme]::SubText
        $script:lblMemNote.Font = [CoreUi.Theme]::Ui
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
        # カード (#757475) の上では色付きの文字は読みにくいため白で出し、[不可] は太字で目立たせる
        $script:lblMemNote.ForeColor = [CoreUi.Theme]::Text
        $script:lblMemNote.Font = [CoreUi.Theme]::UiBold
        $script:btnMem.Enabled = $false
        return
    }
    $st = if ($same) { "変更なし" }
          elseif ([string]$script:Vm.State -ne "Off") { "Edge Box は実行中のため、反映には Edge Box の再起動が必要です (適用時に確認します)" }
          else { "Edge Box は停止中のため、すぐに反映できます" }
    $script:lblMemNote.Text = "$cur    " + $(if ($warns.Count -gt 0) { "[注意] " + ($warns -join " / ") + "    " } else { "" }) + $st
    $script:lblMemNote.ForeColor = [CoreUi.Theme]::Text   # [注意] の有無は文字で示す (色付きの文字はカードの上で読みにくい)
    $script:lblMemNote.Font = [CoreUi.Theme]::Ui
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
    Update-Environment                       # スケジューラ・bcd・Edge Box 状態・メモリを読み直す
    $script:UnderMinroot = ($script:VisibleLps -lt $script:TotalLps)
    Update-Header
    Sync-MemoryControl
    Update-Validation
}

$script:btnApps.Add_Click({ Show-AppsDialog })

# 各コアの負荷をリアルタイム表示する別ウィンドウ (cpu-monitor.ps1)
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
# 一覧に無い 登録名 (これから作る Edge Box) も入力できるようにする
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
        $msg += "Edge Box は実行中です。反映には Edge Box の再起動が必要です。`n" +
                "今すぐ『停止 → 設定 → 起動』を行いますか?`n" +
                "(収集が数分止まります。正常にシャットダウンできない場合は何も変更せず中止します)"
    } else {
        $msg += "Edge Box は停止中のため、すぐに反映されます。よろしいですか?"
    }
    $r = Show-Ask $msg "メモリの割り当て"
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
    $verb = if ($script:VmMissing) { "保存します (Edge Box を作成・起動した時点で自動適用)" } else { "適用します" }
    $confirm = "次の内容で${verb}。`n`n" +
        "  Windows            : CPU $hostText  ($($sel.HostCores) コア)`n" +
        "  $($script:VmNameSel) : CPU $guestText  ($($sel.GuestCores) コア)`n`n" +
        "この後 PC の再起動が 1 回必要です (再起動後は自動で完了します)。`n`n" +
        "よろしいですか?"
    $r = Show-Ask $confirm "CPU コア割り当て"
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
        $r2 = Show-Ask ("設定を書き込みました。`n`n" +
            "PC を再起動すると、Edge Box を割り当てたコアに固定してから起動します (以後、起動のたびに自動)。`n" +
            "再起動後の各コアの動きは『Edge Box 監視』で確認できます。`n`n" +
            "今すぐ再起動しますか?") "CPU コア割り当て"
        if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
        return
    }
    if ($script:VmMissing) {
        Show-Info ("保存しました。`n`n  Windows            : CPU $hostText`n  $($script:VmNameSel) : CPU $guestText`n`n" +
            "登録『$($script:VmNameSel)』を作成して起動すると、この割り当てが自動で適用されます。`n" +
            "(Edge Box の起動を検出して自動で適用します)")
    } else {
    Show-Info ("適用しました。`n`n  Windows            : CPU $hostText`n  $($script:VmNameSel) : CPU $guestText`n`n" +
        "『Edge Box 監視』で、実際にどのコアで動いているか確認できます。")
    }
})

$script:btnUndo.Add_Click({
    $r = Show-Ask "分割を解除すると、Edge Box が起動しなくなります。`n分割を解除しますか?" "CPU コア割り当て" "Warning"
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $form.Enabled = $false
    try { $code = Invoke-Engine @("-Undo", "-VMName", "`"$($script:VmNameSel)`"", "-NoConfirm") } finally { $form.Enabled = $true }
    Refresh-All
    if ($code -eq 0) {
        Show-Info "解除しました。`n(PC の再起動で完全に元へ戻ります)"
    } else {
        Show-Info "解除の途中で問題が起きました (終了コード $code)。表示されたウィンドウの内容をご確認ください。" "Warning"
    }
})


# ============================================================
#  コアを選ぶダイアログ (アプリ用)
# ============================================================
function Show-CoreChooser([int[]]$Preselect, [string]$Title, [int[]]$GuestLps) {
    $d = New-Object System.Windows.Forms.Form
    Initialize-UiForm $d
    $d.Text = $Title
    $d.ClientSize = New-Object System.Drawing.Size(700, 480)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false

    $lbl = New-Lbl "このアプリを動かすコアを選びます (複数選択可)。Edge Box 用のコアは選べないため表示していません。" 16 14 668
    $lbl.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($lbl)

    $fpFrame = New-Object CoreUi.Card
    $fpFrame.HeaderHeight = 1
    $fpFrame.Padding = New-Object System.Windows.Forms.Padding(10)
    $fpFrame.Location = New-Object System.Drawing.Point(16, 44)
    $fpFrame.Size = New-Object System.Drawing.Size(668, 326)
    $fp = New-Object System.Windows.Forms.FlowLayoutPanel
    $fp.Dock = "Fill"
    $fp.BackColor = [CoreUi.Theme]::Panel
    $fp.AutoScroll = $true
    $fp.WrapContents = $true
    $fpFrame.Controls.Add($fp)
    $d.Controls.Add($fpFrame)

    $boxes = @{}
    foreach ($c in $script:Cores) {
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { continue }   # Edge Box 用は選ばせない
        $cb = New-Object CoreUi.DarkCheckBox
        $cb.Text = "{0}  (CPU {1})" -f $c.Label, (ConvertTo-LpRangeText $c.Lps)
        $cb.Size = New-Object System.Drawing.Size(156, 28)
        $cb.Margin = New-Object System.Windows.Forms.Padding(3)
        $cb.Accent = $ColHost   # 選べるのは Windows 用のコアだけ
        $cb.Tag = $c.Id
        $cb.Checked = (@($c.Lps | Where-Object { $Preselect -contains $_ }).Count -gt 0)
        if (@($c.Lps | Where-Object { $GuestLps -contains $_ }).Count -gt 0) { $cb.Accent = $ColGuest }
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
    $qx = 14
    foreach ($q in @(
        @{ T = "Windows 側すべて"; K = "host"; W = 150 },
        @{ T = "P コアのみ";       K = "p";    W = 112 },
        @{ T = "E コアのみ";       K = "e";    W = 112 },
        @{ T = "クリア";           K = "none"; W = 92  })) {
        $b = New-UiButton $q.T $q.W
        $b.Location = New-Object System.Drawing.Point($qx, 380)
        $kind = $q.K
        $b.Add_Click({ & $setBoxes $kind }.GetNewClosure())
        $d.Controls.Add($b)
        $qx += $q.W + 8
    }

    $ok = New-UiButton "OK" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(456, 432)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(574, 432)
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
    Initialize-UiForm $d
    $d.Text = "実行中のアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(660, 470)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false
    $hint = New-Lbl "登録したいアプリを選んでください (ウィンドウを持つアプリを上に表示します)。" 16 14 628
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($hint)

    $lbFrame = New-Object CoreUi.Card
    $lbFrame.HeaderHeight = 1
    $lbFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lbFrame.Location = New-Object System.Drawing.Point(16, 42)
    $lbFrame.Size = New-Object System.Drawing.Size(628, 366)
    $lb = New-Object CoreUi.DarkListBox
    $lb.Dock = "Fill"
    $lbFrame.Controls.Add($lb)
    $d.Controls.Add($lbFrame)

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

    $ok = New-UiButton "追加" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(416, 422)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(534, 422)
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
    Initialize-UiForm $d
    $d.Text = "インストール済みのアプリから選ぶ"
    $d.ClientSize = New-Object System.Drawing.Size(760, 530)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "Sizable"
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false
    $d.MinimumSize = New-Object System.Drawing.Size(520, 360)

    $hint = New-Lbl "登録したいアプリを選んでください。名前の一部を入力すると絞り込めます。" 16 14 728
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $hint.Anchor = "Top,Left,Right"
    $d.Controls.Add($hint)
    $d.Controls.Add((New-Lbl "絞り込み" 16 52))
    $tb = New-Object System.Windows.Forms.TextBox
    $tbFrame = New-UiField $tb 84 46 400 30
    $tbFrame.Anchor = "Top,Left,Right"
    $d.Controls.Add($tbFrame)
    $lblCount = New-Lbl "" 496 52 248
    $lblCount.ForeColor = [CoreUi.Theme]::SubText
    $lblCount.TextAlign = "MiddleRight"
    $lblCount.Anchor = "Top,Right"
    $d.Controls.Add($lblCount)

    $lvFrame = New-Object CoreUi.Card
    $lvFrame.HeaderHeight = 1
    $lvFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lvFrame.Location = New-Object System.Drawing.Point(16, 88)
    $lvFrame.Size = New-Object System.Drawing.Size(728, 380)
    $lvFrame.Anchor = "Top,Bottom,Left,Right"
    $lv = New-Object CoreUi.DarkListView
    $lv.Dock = "Fill"
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.GridLines = $false
    [void]$lv.Columns.Add("アプリ名", 260)
    [void]$lv.Columns.Add("実行ファイル", 380)
    [void]$lv.Columns.Add("情報源", 84)
    $lvFrame.Controls.Add($lv)
    $d.Controls.Add($lvFrame)

    $ok = New-UiButton "追加" 110 "Primary"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(516, 482)
    $ok.Anchor = "Bottom,Right"
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(634, 482)
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
    Initialize-UiForm $d
    $d.Text = "アプリの割り当て"
    $d.ClientSize = New-Object System.Drawing.Size(880, 560)
    $d.StartPosition = "CenterParent"
    $d.FormBorderStyle = "FixedDialog"
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false

    $hint = New-Lbl "登録したアプリは、起動のたびに指定したコアへ自動で固定されます (1 分ごとに確認)。" 16 14 848
    $hint.ForeColor = [CoreUi.Theme]::SubText
    $d.Controls.Add($hint)

    $lvFrame = New-Object CoreUi.Card
    $lvFrame.HeaderHeight = 1
    $lvFrame.Padding = New-Object System.Windows.Forms.Padding(1)
    $lvFrame.Location = New-Object System.Drawing.Point(16, 42)
    $lvFrame.Size = New-Object System.Drawing.Size(848, 324)
    $lv = New-Object CoreUi.DarkListView
    $lv.Dock = "Fill"
    $lv.View = "Details"
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.GridLines = $false
    [void]$lv.Columns.Add("アプリ名", 190)
    [void]$lv.Columns.Add("実行ファイル", 380)
    [void]$lv.Columns.Add("割り当てコア", 170)
    [void]$lv.Columns.Add("優先度", 90)
    $lvFrame.Controls.Add($lv)
    $d.Controls.Add($lvFrame)

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

    $bx = 14
    $btnInst = New-UiButton "インストール済みから追加..." 216
    $btnInst.Location = New-Object System.Drawing.Point($bx, 376)
    $btnInst.Add_Click({
        $e = Show-InstalledAppPicker
        if ($e) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($e.Exe)
            Add-App $e.Name $e.Exe $base
        }
    })
    $bx += 222

    $btnFile = New-UiButton "ファイルから追加..." 160
    $btnFile.Location = New-Object System.Drawing.Point($bx, 376)
    $btnFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "実行ファイル (*.exe)|*.exe|すべてのファイル (*.*)|*.*"
        $ofd.Title = "登録するアプリの実行ファイルを選んでください"
        if ($ofd.ShowDialog() -eq "OK") {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($ofd.FileName)
            Add-App $base $ofd.FileName $base
        }
    })
    $bx += 166

    $btnRun = New-UiButton "実行中から追加..." 160
    $btnRun.Location = New-Object System.Drawing.Point($bx, 376)
    $btnRun.Add_Click({
        $e = Show-ProcessPicker
        if ($e) { Add-App $e.Name $(if ($e.Exe) { $e.Exe } else { "" }) $e.Name }
    })
    $bx += 166

    $btnCores = New-UiButton "コアを編集..." 140 "Default" "edit"
    $btnCores.Location = New-Object System.Drawing.Point($bx, 376)
    $btnCores.Add_Click({
        $a = Get-SelectedApp
        if (-not $a) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $lps = Show-CoreChooser @([int[]]$a.Lps) ("コアの選択 - " + $a.Name) @($sel.GuestLps)
        if ($lps) { $a.Lps = @($lps); Sync-AppList }
    })
    $bx += 146

    $btnDel = New-UiButton "削除" 96 "Danger"
    $btnDel.Location = New-Object System.Drawing.Point($bx, 376)
    $btnDel.Add_Click({
        if ($lv.SelectedIndices.Count -eq 0) { Show-Info "一覧からアプリを選んでください。" "Warning"; return }
        $work.RemoveAt($lv.SelectedIndices[0])
        Sync-AppList
    })
    $d.Controls.AddRange(@($btnInst, $btnFile, $btnRun, $btnCores, $btnDel))

    $d.Controls.Add((New-Lbl "選んだアプリの優先度" 16 428))
    $cmbPri = New-Object CoreUi.DarkComboBox
    $cmbPri.Location = New-Object System.Drawing.Point(176, 422)
    $cmbPri.Size = New-Object System.Drawing.Size(130, 30)
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

    $note = New-Lbl "『高』は取り合いになったときに優先されます。Edge Box 用のコアは避けてください (Edge Box と取り合いになります)。" 16 466 848
    $note.ForeColor = [CoreUi.Theme]::SubText
    $note.Font = [CoreUi.Theme]::UiSmall
    $d.Controls.Add($note)

    $ok = New-UiButton "保存して適用" 140 "Primary" "check"
    $ok.DialogResult = "OK"
    $ok.Location = New-Object System.Drawing.Point(606, 508)
    $ng = New-UiButton "キャンセル" 110
    $ng.DialogResult = "Cancel"
    $ng.Location = New-Object System.Drawing.Point(754, 508)
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
Update-SplitViews (Get-Selection)      # 検査結果は Shown で出す (下の Update-Validation)
Show-Page "core"
$form.Add_Shown({
    Update-Validation
    try { Update-CoreLayout } catch { }
})

[void]$form.ShowDialog()
