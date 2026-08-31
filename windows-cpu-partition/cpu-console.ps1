<#
.SYNOPSIS
    CPU コア割り当ての設定コンソール (GUI)。
    P コア / E コアを画面で直接選んで、Windows とゲスト VM に振り分けます。

.DESCRIPTION
    - この PC の実際のコア構成を検出して 1 コア = 1 タイルで表示します
      (Intel 12世代以降の P コア/E コアは、CPU が申告する効率クラスで判別)
    - タイルをクリックするたびに Windows 用 → ゲスト用 → 未割当 と切り替わります
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
    # ゲスト VM に最低限割り当てるべき物理コア数 (安全装置)
    [int]$MinGuestCores = 4
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$EnginePath   = Join-Path $PSScriptRoot "cpu-partition.ps1"
$ConfigFile   = Join-Path $PSScriptRoot "cpu-partition.json"
$SnapshotFile = Join-Path $PSScriptRoot "cpu-topology.json"
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

    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "CPU割り当て.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$TaskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,27"
    $lnk.Description  = "CPU コア割り当ての設定コンソール"
    $lnk.Save()
    Write-Host "デスクトップに『CPU割り当て』アイコンを作成しました (UAC 確認なしで開けます)。" -ForegroundColor Green
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

function Save-Snapshot($Cores) {
    try {
        $obj = @($Cores | ForEach-Object { [pscustomobject]@{ Eff = $_.Eff; Lps = @($_.Lps) } })
        $obj | ConvertTo-Json -Depth 4 | Set-Content -Path $SnapshotFile -Encoding UTF8
    } catch { }
}

function Read-Snapshot {
    if (-not (Test-Path $SnapshotFile)) { return $null }
    try {
        $raw = @(Get-Content $SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json)
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
}

# ============================================================
#  起動時の状態づくり
# ============================================================
$script:VmNameSel = $VMName
Update-Environment

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
    # 既定の初期表示: 混成 CPU なら P=Windows / E=ゲスト、それ以外は前半/後半で半分ずつ
    if ($script:Hybrid) {
        foreach ($c in $script:Cores) { $c.State = $(if ($c.Kind -eq "E") { "Guest" } else { "Host" }) }
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
$form.ClientSize = New-Object System.Drawing.Size(964, 742)
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
$grpPc.Size = New-Object System.Drawing.Size(940, 76)
$script:lblCpu1 = New-Lbl "" 14 22 910
$script:lblCpu2 = New-Lbl "" 14 44 910
$grpPc.Controls.AddRange(@($script:lblCpu1, $script:lblCpu2))
$form.Controls.Add($grpPc)

# --- 対象と方式 ---
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = "対象と方式"
$grpMode.Location = New-Object System.Drawing.Point(12, 90)
$grpMode.Size = New-Object System.Drawing.Size(940, 92)

$grpMode.Controls.Add((New-Lbl "対象の VM:" 14 26))
$script:cmbVm = New-Object System.Windows.Forms.ComboBox
$script:cmbVm.Location = New-Object System.Drawing.Point(100, 23)
$script:cmbVm.Size = New-Object System.Drawing.Size(200, 24)
$script:cmbVm.DropDownStyle = "DropDownList"
if ($script:HyperVOk) {
    foreach ($n in @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)) {
        [void]$script:cmbVm.Items.Add($n)
    }
}
if ($script:cmbVm.Items.Contains($script:VmNameSel)) { $script:cmbVm.SelectedItem = $script:VmNameSel }
elseif ($script:cmbVm.Items.Count -gt 0) { $script:cmbVm.SelectedIndex = 0 }
$grpMode.Controls.Add($script:cmbVm)
$script:lblVm = New-Lbl "" 314 26 610
$grpMode.Controls.Add($script:lblVm)

$grpMode.Controls.Add((New-Lbl "方式:" 14 58))
$script:rbRuntime = New-Object System.Windows.Forms.RadioButton
$script:rbRuntime.Text = "runtime (再起動なし・すぐ反映)"
$script:rbRuntime.Location = New-Object System.Drawing.Point(96, 55)
$script:rbRuntime.Size = New-Object System.Drawing.Size(250, 24)
$script:rbFull = New-Object System.Windows.Forms.RadioButton
$script:rbFull.Text = "full (完全分割・再起動が必要)"
$script:rbFull.Location = New-Object System.Drawing.Point(356, 55)
$script:rbFull.Size = New-Object System.Drawing.Size(240, 24)
if ($script:SavedCfg -and $script:SavedCfg.Mode -eq "full") { $script:rbFull.Checked = $true } else { $script:rbRuntime.Checked = $true }
$grpMode.Controls.AddRange(@($script:rbRuntime, $script:rbFull))

$grpMode.Controls.Add((New-Lbl "VM 側の最低コア数:" 646 58))
$script:numMin = New-Object System.Windows.Forms.NumericUpDown
$script:numMin.Location = New-Object System.Drawing.Point(790, 55)
$script:numMin.Size = New-Object System.Drawing.Size(56, 24)
$script:numMin.Minimum = 1
$script:numMin.Maximum = 32
$script:numMin.Value = [Math]::Max(1, [Math]::Min(32, $MinGuestCores))
$grpMode.Controls.Add($script:numMin)
$grpMode.Controls.Add((New-Lbl "コア" 852 58))
$form.Controls.Add($grpMode)

# --- かんたん設定 (プリセット) ---
$form.Controls.Add((New-Lbl "かんたん設定:" 16 194))
function New-Preset([string]$Text, [int]$X, [int]$W, $OnClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, 190)
    $b.Size = New-Object System.Drawing.Size($W, 27)
    $b.Add_Click($OnClick)
    return $b
}
function Set-AllStates([string]$State) {
    foreach ($c in $script:Cores) { $c.State = $State }
}
$presetX = 112
if ($script:Hybrid) {
    $form.Controls.Add((New-Preset "P コア = Windows / E コア = EdgeBox (推奨)" $presetX 280 {
        foreach ($c in $script:Cores) { $c.State = $(if ($c.Kind -eq "E") { "Guest" } else { "Host" }) }
        Sync-AllTiles; Update-Validation
    }))
    $presetX += 288
}
$form.Controls.Add((New-Preset "EdgeBox は最低数だけ" $presetX 160 {
    $need = [int]$script:numMin.Value
    Set-AllStates "Host"
    # 後ろのコアから必要数だけゲストへ (混成 CPU なら E コアが後ろに並ぶ)
    $tail = @($script:Cores | Sort-Object Id -Descending | Select-Object -First $need)
    foreach ($c in $tail) { $c.State = "Guest" }
    Sync-AllTiles; Update-Validation
}))
$presetX += 168
$form.Controls.Add((New-Preset "半分ずつ" $presetX 100 {
    $half = [Math]::Max(1, [int]($script:Cores.Count / 2))
    foreach ($c in $script:Cores) { $c.State = $(if ($c.Id -lt $half) { "Host" } else { "Guest" }) }
    Sync-AllTiles; Update-Validation
}))
$presetX += 108
$form.Controls.Add((New-Preset "全部 Windows (分割なし)" $presetX 180 {
    Set-AllStates "Host"; Sync-AllTiles; Update-Validation
}))

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
        switch ($c.State) {
            "Host"  { $c.State = "Guest" }
            "Guest" { $c.State = "None" }
            default { $c.State = "Host" }
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

$lblHint = New-Lbl "タイルをクリックするたびに  Windows 用 → EdgeBox 用 → 未割当  と切り替わります" 16 478 700
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblHint)

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

# --- 操作ボタン ---
$script:btnUndo = New-Object System.Windows.Forms.Button
$script:btnUndo.Text = "分割を解除"
$script:btnUndo.Location = New-Object System.Drawing.Point(12, 702)
$script:btnUndo.Size = New-Object System.Drawing.Size(140, 32)

$script:btnVerify = New-Object System.Windows.Forms.Button
$script:btnVerify.Text = "効き具合を実測"
$script:btnVerify.Location = New-Object System.Drawing.Point(160, 702)
$script:btnVerify.Size = New-Object System.Drawing.Size(140, 32)

$script:btnFix = New-Object System.Windows.Forms.Button
$script:btnFix.Text = "full 用に並べ直す"
$script:btnFix.Location = New-Object System.Drawing.Point(308, 702)
$script:btnFix.Size = New-Object System.Drawing.Size(160, 32)
$script:btnFix.Visible = $false

$script:chkTools = New-Object System.Windows.Forms.CheckBox
$script:chkTools.Text = "CpuGroups.exe を自動取得"
$script:chkTools.Location = New-Object System.Drawing.Point(476, 707)
$script:chkTools.Size = New-Object System.Drawing.Size(180, 24)
$script:chkTools.Checked = $true
$script:chkTools.Visible = $false

$script:btnApply = New-Object System.Windows.Forms.Button
$script:btnApply.Text = "この内容で適用"
$script:btnApply.Location = New-Object System.Drawing.Point(660, 702)
$script:btnApply.Size = New-Object System.Drawing.Size(170, 32)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "閉じる"
$btnClose.Location = New-Object System.Drawing.Point(838, 702)
$btnClose.Size = New-Object System.Drawing.Size(114, 32)
$btnClose.DialogResult = "Cancel"
$form.CancelButton = $btnClose
$form.Controls.AddRange(@($script:btnUndo, $script:btnVerify, $script:btnFix, $script:chkTools, $script:btnApply, $btnClose))

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
    $mr = if ($script:UnderMinroot) { "有効 — Windows は $($script:VisibleLps) 論理 CPU に封じ込め中" } else { "未使用" }
    $script:lblCpu2.Text = "ハイパーバイザーのスケジューラ: {0}    minroot: {1}" -f $script:Scheduler, $mr
    if ($script:Vm) {
        $script:lblVm.Text = "状態: {0}    仮想プロセッサ: {1}" -f $script:Vm.State, $script:Vcpu
    } elseif ($script:HyperVOk) {
        $script:lblVm.Text = "この名前の VM が見つかりません"
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
    $mode = if ($script:rbFull.Checked) { "full" } else { "runtime" }
    $minGuest = [int]$script:numMin.Value
    $errors = @(); $warnings = @()

    $hostCoreObjs  = @($script:Cores | Where-Object { $_.State -eq "Host" })
    $guestCoreObjs = @($script:Cores | Where-Object { $_.State -eq "Guest" })
    $script:lblSumH.Text = "Windows : " + (Format-Side $hostCoreObjs $sel.HostLps)
    $script:lblSumG.Text = "{0} : {1}" -f $script:VmNameSel, (Format-Side $guestCoreObjs $sel.GuestLps)

    # --- 環境そのものが整っていない ---
    if (-not $script:HyperVOk) {
        $errors += "Hyper-V が有効ではありません。先に Hyper-V を有効化して再起動してください。"
    }
    if ($script:HyperVOk -and -not $script:Vm) {
        $errors += "VM『$($script:VmNameSel)』が見つかりません。対象の VM を選び直してください。"
    }

    # --- 割り当ての量 ---
    if ($sel.GuestCores -lt $minGuest) {
        $errors += "$($script:VmNameSel) 側が $($sel.GuestCores) コアです。最低 $minGuest コア必要です (右上の設定で変更可)。"
    }
    if ($sel.HostCores -lt 2) {
        $errors += "Windows 側が $($sel.HostCores) コアです。最低 2 コア必要です (VM のディスク/ネットワーク処理も Windows 側で動くため)。"
    } elseif ($sel.HostCores -lt 4) {
        $warnings += "Windows 側が 4 コア未満です。VM の I/O 処理も Windows 側コアで動くため、$($script:VmNameSel) の通信・保存まで遅くなることがあります。"
    }
    if ($sel.NoneCores -gt 0) {
        $warnings += "未割当のコアが $($sel.NoneCores) 個あります (どちらからも積極的には使われません)。"
    }
    if ($sel.GuestLps.Count -gt 0 -and $sel.GuestLps.Count -lt 8) {
        $warnings += "$($script:VmNameSel) 側が $($sel.GuestLps.Count) スレッドです (専用機によくある 4 コア 8 スレッド構成を下回ります)。"
    }

    # --- 方式ごとの成立条件 ---
    $script:btnFix.Visible = $false
    $script:chkTools.Visible = ($mode -eq "full")
    if ($mode -eq "runtime") {
        if ($script:Scheduler -ne "root") {
            $errors += "runtime は Windows 標準の root スケジューラ専用ですが、現在は『$($script:Scheduler)』です。full を選ぶか、[分割を解除] 後に再起動してください。"
        }
        if ($script:Bcd -and ($script:Bcd.SchedulerType -or $script:Bcd.RootProc)) {
            $errors += "full モード用の設定が書き込み済みです (次の再起動で有効になり runtime と矛盾します)。full を続けるか、[分割を解除] してください。"
        }
        if ($script:UnderMinroot) {
            $errors += "minroot が有効なため、隠れているコアには runtime 方式の固定ができません。[分割を解除] して再起動してから使ってください。"
        }
        $over = @($sel.HostLps + $sel.GuestLps | Where-Object { $_ -ge 63 })
        if ($over.Count -gt 0) {
            $errors += "論理 CPU 63 以上は runtime 方式では扱えません。full を使ってください。"
        }
    } else {
        # minroot は「先頭から N 個」の論理 CPU をホストに割り当てる方式
        $ok = $true
        for ($i = 0; $i -lt $sel.HostLps.Count; $i++) {
            if ($sel.HostLps[$i] -ne $i) { $ok = $false; break }
        }
        if (-not $ok -or $sel.HostLps.Count -eq 0) {
            $errors += "full では Windows 側が CPU 0 から続き番号である必要があります (minroot の仕様)。現在: CPU $(ConvertTo-LpRangeText $sel.HostLps)"
            $script:btnFix.Visible = $true
        }
        $warnings += "full は再起動が必要です (設定を書き込み → 再起動 → もう一度 [この内容で適用] で完了)。"
    }

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
            $warnings += "仮想プロセッサ数を $($script:Vcpu) から $($sel.GuestLps.Count) に自動調整します。"
        } else {
            $warnings += "仮想プロセッサ数 ($($script:Vcpu)) と割り当てスレッド数 ($($sel.GuestLps.Count)) が違います。VM 停止中に適用すると自動調整されます。"
        }
    }
    if ($script:UsedSnapshot) {
        $warnings += "一部のコアが Windows から見えないため、保存済みのコア構成を表示しています。"
    }

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
}

# ============================================================
#  操作 (適用・解除・実測はすべて cpu-partition.ps1 に任せる)
# ============================================================
function Invoke-Engine([string[]]$EngineArgs) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$EnginePath`" " + ($EngineArgs -join " ")
    $p = Start-Process powershell.exe -ArgumentList $argLine -WindowStyle Normal -PassThru -Wait
    return [int]$p.ExitCode
}

function Refresh-All {
    Update-Environment                       # スケジューラ・bcd・VM 状態を読み直す
    $script:UnderMinroot = ($script:VisibleLps -lt $script:TotalLps)
    Update-Header
    Update-Validation
}

$script:cmbVm.Add_SelectedIndexChanged({
    if ($script:cmbVm.SelectedItem) { $script:VmNameSel = [string]$script:cmbVm.SelectedItem }
    Refresh-All
})
$script:rbRuntime.Add_CheckedChanged({ Update-Validation })
$script:rbFull.Add_CheckedChanged({ Update-Validation })
$script:numMin.Add_ValueChanged({ Update-Validation })

$script:btnFix.Add_Click({
    $n = @($script:Cores | Where-Object { $_.State -eq "Host" }).Count
    if ($n -lt 1) { $n = 1 }
    foreach ($c in $script:Cores) { $c.State = $(if ($c.Id -lt $n) { "Host" } else { "Guest" }) }
    Sync-AllTiles
    Update-Validation
})

$script:btnApply.Add_Click({
    $sel = Get-Selection
    $mode = if ($script:rbFull.Checked) { "full" } else { "runtime" }
    $hostText  = ConvertTo-LpRangeText $sel.HostLps
    $guestText = ConvertTo-LpRangeText $sel.GuestLps
    $confirm = "次の内容で適用します。`n`n" +
        "  Windows            : CPU $hostText  ($($sel.HostCores) コア)`n" +
        "  $($script:VmNameSel) : CPU $guestText  ($($sel.GuestCores) コア)`n" +
        "  方式               : $mode`n`n" +
        $(if ($mode -eq "full") { "この後 PC の再起動が必要です。`n`n" } else { "" }) +
        "よろしいですか? (いつでも [分割を解除] で元に戻せます)"
    $r = [System.Windows.Forms.MessageBox]::Show($confirm, "CPU コア割り当て",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $a = @("-Apply", "-Mode", $mode, "-VMName", "`"$($script:VmNameSel)`"",
           "-HostLps", "`"$hostText`"", "-GuestLps", "`"$guestText`"", "-NoConfirm")
    if ($mode -eq "full" -and $script:chkTools.Checked) { $a += "-AutoGetTools" }
    $form.Enabled = $false
    try { $code = Invoke-Engine $a } finally { $form.Enabled = $true }
    Refresh-All

    if ($code -ne 0) {
        Show-Info "適用できませんでした (終了コード $code)。`n`n表示されたウィンドウの内容と cpu-partition-log.txt をご確認ください。" "Warning"
        return
    }
    # full の第 1 段階 (設定書き込み済み・未反映) なら再起動を案内する
    $pending = $script:Bcd -and ($script:Bcd.RootProc -gt 0) -and ($script:VisibleLps -ne $script:Bcd.RootProc)
    if ($mode -eq "full" -and $pending) {
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            "設定を書き込みました (第 1 段階)。`n`n" +
            "PC を再起動したあと、もう一度この画面で [この内容で適用] を押すと完了します。`n`n" +
            "今すぐ再起動しますか?", "CPU コア割り当て",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Computer -Force }
        return
    }
    Show-Info "適用しました。`n`n  Windows            : CPU $hostText`n  $($script:VmNameSel) : CPU $guestText`n`n[効き具合を実測] で、実際にどのコアで動いているか確認できます。"
})

$script:btnUndo.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "CPU コア分割の設定をすべて解除して、元の状態に戻します。`nよろしいですか?", "CPU コア割り当て",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $form.Enabled = $false
    try { $code = Invoke-Engine @("-Undo", "-VMName", "`"$($script:VmNameSel)`"", "-NoConfirm") } finally { $form.Enabled = $true }
    Refresh-All
    if ($code -eq 0) {
        Show-Info "解除しました。`n(minroot やスケジューラを使っていた場合は、PC の再起動で完全に元へ戻ります)"
    } else {
        Show-Info "解除の途中で問題が起きました (終了コード $code)。表示されたウィンドウの内容をご確認ください。" "Warning"
    }
})

$script:btnVerify.Add_Click({
    if (-not $script:Vm -or $script:Vm.State -ne "Running") {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "$($script:VmNameSel) が動いていないため、実測してもゲスト側の数値はほぼ 0 になります。`nそれでも実行しますか?",
            "CPU コア割り当て",
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    # 結果を読める状態で残すため、閉じないウィンドウで実行する
    Start-Process powershell.exe -ArgumentList (
        "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$EnginePath`" -Verify -VMName `"$($script:VmNameSel)`"")
})

# ============================================================
#  表示
# ============================================================
Sync-AllTiles
Update-Header
$form.Add_Shown({ Update-Validation })
[void]$form.ShowDialog()
