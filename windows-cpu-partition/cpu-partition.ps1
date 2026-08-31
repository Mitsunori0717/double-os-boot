<#
.SYNOPSIS
    Windows ホストと Hyper-V ゲスト VM の間で CPU コアを分割し、固定割り当て (ピンニング) します。
    主構成 (Linux ホスト) の isolcpus + vcpupin に相当する機能の Windows ホスト版です。

.DESCRIPTION
    2 つの分割モードがあります。どちらも -Undo で完全に元へ戻せます。

    ■ runtime モード (推奨の入口。再起動不要・Windows 標準構成のまま)
        クライアント版 Windows の Hyper-V は既定で「root スケジューラ」で動いており、
        ゲスト VM の仮想プロセッサは vmmem プロセスのスレッドとして Windows の
        スケジューラが実行しています。この性質を利用して:
          - vmmem (= ゲストの CPU 実行の実体) をゲスト用コアへ物理固定
          - vmwp (= VM のディスク/ネットワーク処理) をホスト用コアへ固定
          - vmmem の優先度を High に昇格 (ゲスト用コアを Windows 側の処理が
            奪いにくくする = ホスト側の締め出しを優先度で担保)
        VM の起動を検出して自動で再適用するタスクも登録するため、一度 -Apply
        すれば電源 ON だけの運用でも効き続けます。

    ■ full モード (完全分割。要再起動 + 設定変更 2 段階)
        ハイパーバイザーのスケジューラを core に切り替えたうえで:
          - minroot (bcdedit hypervisorrootproc) で Windows ホスト自体を
            下位コアへ封じ込める (Linux の isolcpus 相当。Windows のプロセス・
            割り込みはゲスト用コアに一切載らなくなる)
          - CPU グループ (Microsoft 製 CpuGroups.exe) でゲストを上位コアへ
            固定する (Linux の vcpupin 相当)
        両方向とも物理的な分割になります。CpuGroups.exe が使えない環境では
        minroot + 処理能力予約 (-Reserve) までの「準分割」で止まり、その旨を
        正直に報告します。
        ※ スケジューラ変更はクライアント版 Windows では Microsoft の公式
           サポート外の構成です (動作実績は広くあります)。工場 PC のような
           専用用途向けで、-Undo でいつでも既定へ戻せます。

.EXAMPLE
    .\cpu-partition.ps1                                   # 現状の確認 (何も変更しない)
    .\cpu-partition.ps1 -HostCores 4                      # 分割案のプレビュー (何も変更しない)
    .\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4 # 再起動なしで分割 (ホストに物理4コア)
    .\cpu-partition.ps1 -Apply -Mode full    -HostCores 4 # 完全分割 (再起動→もう一度同じコマンド)
    .\cpu-partition.ps1 -Verify                           # 実測: 各コアで誰が実行されているか
    .\cpu-partition.ps1 -Undo                             # 全て元に戻す

.EXAMPLE
    # P/E コア混成 CPU (Intel 12世代以降) や、割り当てを番号で決めたい場合
    .\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-11" -GuestLps "12-19"

.NOTES
    管理者権限の PowerShell で実行してください (-Verify と現状確認は管理者なしでも可)。
    設定は cpu-partition.json に保存され、自動タスクが参照します。
    対象 VM は -VMName で指定します (既定: EdgeBox)。どの Hyper-V VM にも使えます。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",

    # --- 適用 ---
    [switch]$Apply,
    [ValidateSet("runtime", "full")]
    [string]$Mode = "",

    # ホスト Windows に残す物理コア数 (SMT 有効なら論理 CPU は 2 倍になる)
    [int]$HostCores = 0,
    # ゲスト VM に渡す物理コア数 (省略時: 残り全部)
    [int]$GuestCores = 0,
    # 論理 CPU 番号での明示指定 (例: "0-7" や "0-3,8-11")。指定時は -HostCores より優先
    [string]$HostLps = "",
    [string]$GuestLps = "",

    # full モードで使うハイパーバイザースケジューラ (core 推奨。classic は旧方式)
    [ValidateSet("core", "classic")]
    [string]$Scheduler = "core",

    [switch]$NoPriorityBoost,   # runtime: vmmem の優先度昇格をしない
    [switch]$NoReserve,         # full: CPU グループ不成立時の処理能力予約をしない
    [switch]$AutoGetTools,      # full: CpuGroups.exe を確認なしで取得する (設定コンソール用)
    [switch]$AllowMissingVM,    # VM が未作成でも計画を保存する (作成・起動後に自動タスクが適用)

    # --- 確認・解除 ---
    [switch]$Verify,            # 実測 (各論理 CPU のゲスト/合計実行率を採取)
    [int]$Seconds = 5,          # -Verify の採取時間
    [switch]$Undo,              # 全設定の解除

    # --- 内部用 (自動タスクが呼ぶ) ---
    [switch]$ApplyRuntime,
    [switch]$Quiet,
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

$ConfigFile  = Join-Path $PSScriptRoot "cpu-partition.json"
$LogFile     = Join-Path $PSScriptRoot "cpu-partition-log.txt"
$ToolsDir    = Join-Path $PSScriptRoot "tools"
$PinTaskName = "CpuPartition-Pin"
$GroupId     = "b0edb0ed-c01e-4a11-8000-0000000000e1"   # 本ツール専用の CPU グループ固定 ID
$NullGroupId = "00000000-0000-0000-0000-000000000000"
$CpuGroupsUrl = "https://go.microsoft.com/fwlink/?linkid=865968"  # Microsoft 公式配布の CpuGroups.exe

# ============================================================ 共通ヘルパー

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-PinLog([string]$Text) {
    try {
        $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
        $lines = @(Get-Content $LogFile -Encoding UTF8)
        if ($lines.Count -gt 400) {
            $lines | Select-Object -Last 200 | Set-Content -Path $LogFile -Encoding UTF8
        }
    } catch { }
}

function Say([string]$Text, [string]$Color = "Gray") {
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

# 途中で失敗しても、必ず理由をログと画面に残す (設定コンソールはこのログを表示する)
trap {
    $msg = $_.Exception.Message
    $at  = ""
    try { $at = ($_.InvocationInfo.PositionMessage -split "`n")[0].Trim() } catch { }
    try { Write-PinLog "エラー: $msg  $at" } catch { }
    Write-Host ""
    Write-Host "エラー: $msg" -ForegroundColor Red
    if ($at) { Write-Host "  $at" -ForegroundColor DarkGray }
    exit 1
}

# --- CPU トポロジ (物理コア数・論理 CPU 数・SMT・P/E 混成の疑い) ---
function Get-CpuTopology {
    $procs = @(Get-CimInstance Win32_Processor)
    $cores = [int](($procs | Measure-Object -Property NumberOfCores -Sum).Sum)
    $lps   = [int](($procs | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
    $smt = 1
    if ($cores -gt 0 -and ($lps % $cores) -eq 0) { $smt = [int]($lps / $cores) }
    # 全コア SMT (lps=2*cores) でも SMT なし (lps=cores) でもない → P/E 混成の可能性
    $hybrid = ($cores -gt 0) -and ($lps -ne $cores) -and ($lps -ne 2 * $cores)
    [pscustomobject]@{
        Cores = $cores; Lps = $lps; SmtPerCore = $smt; HybridSuspected = $hybrid
        Name = (($procs | ForEach-Object { $_.Name.Trim() }) -join " / ")
    }
}

# --- "0-3,8" 形式 → 論理 CPU 番号の配列 ---
function ConvertTo-LpArray([string]$Spec, [int]$Max) {
    $list = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Spec -split ",")) {
        $p = $part.Trim()
        if ($p -eq "") { continue }
        if ($p -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
        } elseif ($p -match '^\d+$') {
            $a = [int]$p; $b = [int]$p
        } else {
            throw "CPU 番号の書式が不正です: '$p' (例: 0-3,8,10-11)"
        }
        if ($b -lt $a) { throw "範囲が逆順です: '$p'" }
        for ($i = $a; $i -le $b; $i++) { [void]$list.Add($i) }
    }
    $arr = @($list | Sort-Object -Unique)
    foreach ($i in $arr) {
        if ($i -ge $Max) { throw "論理 CPU $i は存在しません (この PC にあるのは 0〜$($Max - 1))" }
    }
    return ,$arr
}

# --- 論理 CPU 番号の配列 → "0-3,8" 形式 ---
function ConvertTo-LpRangeText([int[]]$Lps) {
    if (-not $Lps -or $Lps.Count -eq 0) { return "(なし)" }
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

function Get-LpMask([int[]]$Lps) {
    $mask = [int64]0
    foreach ($i in $Lps) {
        if ($i -ge 63) { throw "論理 CPU 63 以上のピン留めは本スクリプト未対応です" }
        $mask = $mask -bor ([int64]1 -shl $i)
    }
    return $mask
}

# --- 現在のハイパーバイザースケジューラ種別 (起動イベントの値から判定) ---
function Get-HvSchedulerType {
    try {
        $ev = Get-WinEvent -FilterHashtable @{ ProviderName = "Microsoft-Windows-Hyper-V-Hypervisor"; Id = 2 } `
            -MaxEvents 1 -ErrorAction Stop
        $val = 0
        if ($ev.Properties.Count -ge 1) { $val = [int]$ev.Properties[0].Value }
        if ($val -eq 0 -and $ev.Message -match '0x([0-9a-fA-F]+)') {
            $val = [Convert]::ToInt32($Matches[1], 16)
        }
        switch ($val) {
            1 { return "classic" }   # classic (SMT 無効)
            2 { return "classic" }
            3 { return "core" }
            4 { return "root" }
        }
        return "unknown"
    } catch {
        return "unknown"   # ハイパーバイザー未起動 (Hyper-V 無効) 等
    }
}

# --- bcdedit に書かれているハイパーバイザー設定 (要管理者) ---
# 注: 各関数の先頭で $ErrorActionPreference を Continue に戻しているのは、
#     Stop のまま外部コマンドの stderr を 2>&1 で拾うと、その時点でスクリプト全体が
#     停止してしまう (Windows PowerShell 5.1 の仕様) ため。
function Get-BcdHvSettings {
    $ErrorActionPreference = "Continue"
    $out = (bcdedit /enum "{current}" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "bcdedit を実行できません (管理者権限が必要です)" }
    $sched = $null; $rootproc = $null
    if ($out -match '(?m)^\s*hypervisorschedulertype\s+(\S+)') { $sched = $Matches[1].ToLower() }
    if ($out -match '(?m)^\s*hypervisorrootproc\s+(\S+)') {
        $v = $Matches[1]
        if ($v -match '^0x') { $rootproc = [Convert]::ToInt32($v.Substring(2), 16) }
        else { $rootproc = [int]$v }
    }
    [pscustomobject]@{ SchedulerType = $sched; RootProc = $rootproc }
}

function Invoke-Bcdedit([string[]]$BcdArgs) {
    $ErrorActionPreference = "Continue"
    $out = (& bcdedit $BcdArgs 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($BcdArgs -join ' ') が失敗しました: $out" }
}

# 値が存在しない場合も正常系として扱う削除 (戻り値: 削除したか)
function Invoke-BcdDeleteValue([string]$Name) {
    $ErrorActionPreference = "Continue"
    bcdedit /deletevalue $Name 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# --- 保存済み設定 ---
function Get-SavedConfig {
    if (-not (Test-Path $ConfigFile)) { return $null }
    try { return (Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-Config($Obj) {
    $Obj | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigFile -Encoding UTF8
}

# --- VM に対応する vmwp / vmmem プロセスを探す ---
function Get-VmProcesses([string]$Name) {
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { return [pscustomobject]@{ Vm = $null; Vmwp = $null; Vmmem = $null } }
    $vmId = $vm.Id.Guid
    $vmwp = $null; $vmmem = $null
    foreach ($w in @(Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'")) {
        if ($w.CommandLine -and $w.CommandLine -match [regex]::Escape($vmId)) { $vmwp = $w; break }
    }
    $mems = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'vmmem%'")
    if ($vmwp) {
        foreach ($m in $mems) {
            if ($m.ParentProcessId -eq $vmwp.ProcessId) { $vmmem = $m; break }
        }
    }
    if (-not $vmmem -and $mems.Count -eq 1) { $vmmem = $mems[0] }
    [pscustomobject]@{ Vm = $vm; Vmwp = $vmwp; Vmmem = $vmmem }
}

# --- CpuGroups.exe を探す ---
function Find-CpuGroupsExe {
    $local = Join-Path $ToolsDir "CpuGroups.exe"
    if (Test-Path $local) { return $local }
    $cmd = Get-Command "CpuGroups.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-CpuGroups([string]$Exe, [string[]]$CgArgs) {
    $ErrorActionPreference = "Continue"   # 失敗も戻り値で扱う (stderr で停止させない)
    $out = (& $Exe $CgArgs 2>&1 | Out-String).Trim()
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); ExitCode = $LASTEXITCODE; Output = $out }
}

# ============================================================ 分割案の決定

# 戻り値: @{ HostLps=[int[]]; GuestLps=[int[]] }
function Resolve-Plan([object]$Topo, [string]$PlanMode) {
    $total = $Topo.Lps

    if ($HostLps -ne "") {
        $h = ConvertTo-LpArray $HostLps $total
    } elseif ($HostCores -gt 0) {
        if ($Topo.HybridSuspected) {
            throw ("この CPU は P コア/E コア混成の可能性があります (物理 {0} コア / 論理 {1})。`n" -f $Topo.Cores, $total) +
                  "コア数指定では意図しない割り当てになるため、-HostLps / -GuestLps で論理 CPU 番号を明示してください。`n" +
                  "番号の対応はタスクマネージャーのパフォーマンスタブ、または CpuGroups.exe GetCpuTopology で確認できます。"
        }
        $n = $HostCores * $Topo.SmtPerCore
        if ($n -ge $total) { throw "ホストに $HostCores コア (論理 $n) を残すとゲスト用が残りません (全論理 $total)" }
        $h = @(0..($n - 1))
    } else {
        throw "分割の指定がありません。-HostCores <残す物理コア数> か -HostLps `"0-7`" の形式で指定してください。"
    }

    if ($GuestLps -ne "") {
        $g = ConvertTo-LpArray $GuestLps $total
    } elseif ($GuestCores -gt 0) {
        if ($Topo.HybridSuspected) { throw "P/E コア混成の可能性があるため -GuestLps で明示してください。" }
        $n = $GuestCores * $Topo.SmtPerCore
        $rest = @(0..($total - 1) | Where-Object { $h -notcontains $_ })
        if ($n -gt $rest.Count) { throw "ゲスト用に $GuestCores コア (論理 $n) は確保できません (残り論理 $($rest.Count))" }
        $g = @($rest | Select-Object -First $n)
    } else {
        $g = @(0..($total - 1) | Where-Object { $h -notcontains $_ })
    }

    # --- 妥当性 ---
    foreach ($i in $g) {
        if ($h -contains $i) { throw "論理 CPU $i がホストとゲストの両方に指定されています" }
    }
    if ($h.Count -lt 2) { throw "ホスト側は最低 2 論理 CPU 必要です (VM のディスク/ネットワーク処理もホスト側で動くため 4 以上を推奨)" }
    if ($g.Count -lt 1) { throw "ゲスト側の論理 CPU がありません" }

    if ($PlanMode -eq "full") {
        # minroot はホストを「先頭から N 個」の論理 CPU に閉じ込める方式のため、
        # full モードのホスト側は 0 始まりの連番であることが必須
        $expected = @(0..($h.Count - 1))
        $diff = Compare-Object $h $expected
        if ($diff) {
            throw "full モードのホスト側は 0 から始まる連番 (例: 0-7) である必要があります (minroot の仕様)。`n" +
                  "指定: $(ConvertTo-LpRangeText $h)  → 例えば -HostLps `"0-$($h.Count - 1)`" としてください。"
        }
    }

    if (($h.Count + $g.Count) -lt $total) {
        $rest = @(0..($total - 1) | Where-Object { ($h -notcontains $_) -and ($g -notcontains $_) })
        Say ("注意: 論理 CPU {0} はどちらにも割り当てられず遊びます。" -f (ConvertTo-LpRangeText $rest)) "Yellow"
    }
    if ($h.Count -lt 4) {
        Say "注意: ホスト側が論理 4 未満です。VM のディスク/ネットワーク処理はホスト側コアで動くため、細くしすぎると VM の I/O も遅くなります。" "Yellow"
    }
    # SMT 境界チェック (同一物理コアの 2 スレッドが両側にまたがると分割が甘くなる)
    if (-not $Topo.HybridSuspected -and $Topo.SmtPerCore -eq 2) {
        foreach ($i in $h) {
            $sib = $i -bxor 1
            if ($g -contains $sib) {
                Say ("注意: 論理 CPU {0} と {1} は同じ物理コアの SMT ペアの可能性が高く、両側にまたがっています (キャッシュ/実行資源を共有するため分割効果が下がります)。" -f $i, $sib) "Yellow"
                break
            }
        }
    }

    return [pscustomobject]@{ HostLps = $h; GuestLps = $g }
}

# ============================================================ runtime モードの実体

# vmmem をゲスト用コアへ、vmwp をホスト用コアへ固定する。戻り値: 結果の説明文字列
function Set-RuntimePin([int[]]$HostArr, [int[]]$GuestArr, [bool]$Boost) {
    $procs = Get-VmProcesses $VMName
    if (-not $procs.Vm) {
        return "skip: VM '$VMName' はまだ作成されていません (作成して起動すれば自動で適用します)"
    }
    if ($procs.Vm.State -ne "Running") {
        return "skip: VM '$VMName' が実行中でないため何もしませんでした ($($procs.Vm.State))"
    }
    if (-not $procs.Vmmem) {
        return "fail: vmmem プロセスが見つかりません (VM 起動直後なら数十秒後に自動タスクが再適用します)"
    }
    $results = @()

    $guestMask = Get-LpMask $GuestArr
    $p = Get-Process -Id $procs.Vmmem.ProcessId -ErrorAction Stop
    try {
        if ([int64]$p.ProcessorAffinity -ne $guestMask) {
            $p.ProcessorAffinity = [IntPtr]$guestMask
        }
        $results += "vmmem(PID $($p.Id)) → CPU $(ConvertTo-LpRangeText $GuestArr)"
    } catch {
        return "fail: vmmem へのコア固定が拒否されました: $($_.Exception.Message)"
    }
    if ($Boost) {
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            $results += "vmmem 優先度=High"
        } catch {
            $results += "vmmem 優先度昇格は不可でした (固定は有効)"
        }
    }

    if ($procs.Vmwp) {
        try {
            $hostMask = Get-LpMask $HostArr
            $w = Get-Process -Id $procs.Vmwp.ProcessId -ErrorAction Stop
            if ([int64]$w.ProcessorAffinity -ne $hostMask) {
                $w.ProcessorAffinity = [IntPtr]$hostMask
            }
            $results += "vmwp(PID $($w.Id)) → CPU $(ConvertTo-LpRangeText $HostArr)"
        } catch {
            $results += "vmwp の固定は不可でした (影響は小)"
        }
    }
    return "ok: " + ($results -join " / ")
}

# VM 起動を検出して自動で再適用するタスク (SYSTEM 権限)
# 戻り値: 使えたトリガーの説明 (環境によりイベント検出が作れない場合は定期実行で代替)
function Register-PinTask {
    $triggers = @()
    $note = ""

    # VM 起動イベント (最速で反映される)。作れない環境ではスキップする
    try {
        $xml = '<QueryList><Query Id="0" Path="Microsoft-Windows-Hyper-V-Worker-Admin">' +
               '<Select Path="Microsoft-Windows-Hyper-V-Worker-Admin">' +
               "*[System[Provider[@Name='Microsoft-Windows-Hyper-V-Worker'] and EventID=18500]]" +
               '</Select></Query></QueryList>'
        $evClass = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" `
            -ClassName "MSFT_TaskEventTrigger" -ErrorAction Stop
        $triggers += New-CimInstance -CimClass $evClass -ClientOnly `
            -Property @{ Enabled = $true; Subscription = $xml } -ErrorAction Stop
    } catch {
        $note = "VM 起動イベントのトリガーは作れなかったため、定期実行で補います"
        Write-PinLog "Register-PinTask: イベントトリガー不可 ($($_.Exception.Message))"
    }

    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    try { $bootTrigger.Delay = "PT2M" } catch { }
    $triggers += $bootTrigger

    # ログオン時 + 2 分ごとの再適用 (取りこぼしと、上のイベント不可を補う保険)
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    try {
        $logonTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 2) `
            -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
    } catch {
        try {
            $logonTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
                -RepetitionInterval (New-TimeSpan -Minutes 2) `
                -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
        } catch { }
    }
    $triggers += $logonTrigger

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ApplyRuntime -Quiet"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $PinTaskName -Trigger $triggers `
        -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    return $note
}

# ============================================================ -ApplyRuntime (内部用)

if ($ApplyRuntime) {
    $cfg = Get-SavedConfig
    if (-not $cfg) { Write-PinLog "ApplyRuntime: 設定ファイルなし。何もしません"; exit 0 }
    if ($cfg.Mode -ne "runtime") { exit 0 }   # full モード時はハイパーバイザー側で固定済み
    if ($cfg.VMName) { $VMName = [string]$cfg.VMName }

    # VM 起動直後は vmmem が出そろうまで少し待つ (最大 60 秒)
    $msg = ""
    for ($try = 1; $try -le 12; $try++) {
        try {
            $msg = Set-RuntimePin @([int[]]$cfg.HostLps) @([int[]]$cfg.GuestLps) (-not [bool]$cfg.NoPriorityBoost)
        } catch {
            $msg = "fail: $($_.Exception.Message)"
        }
        if ($msg -like "ok:*" -or $msg -like "skip:*") { break }
        Start-Sleep -Seconds 5
    }
    Write-PinLog "ApplyRuntime: $msg"
    if (-not $Quiet) {
        if ($msg -like "ok:*") { Write-Host "CPU コア固定を適用: $msg" -ForegroundColor Green }
        elseif ($msg -like "skip:*") { Write-Host $msg }
        else { Write-Host "CPU コア固定に失敗: $msg" -ForegroundColor Yellow }
    }
    if ($msg -like "fail:*") { exit 1 }
    exit 0
}

# ============================================================ -Undo

if ($Undo) {
    if (-not (Test-Admin)) { Write-Error "管理者権限の PowerShell で実行してください。"; exit 1 }

    Write-Host "CPU コア分割の設定を全て解除します。" -ForegroundColor Cyan
    if (-not $NoConfirm) {
        $ans = Read-Host "よろしいですか? (y/N)"
        if ($ans -ne "y") { exit 0 }
    }

    # 1) 自動タスク
    try {
        Unregister-ScheduledTask -TaskName $PinTaskName -Confirm:$false -ErrorAction Stop
        Write-Host "  自動タスク '$PinTaskName' を削除しました" -ForegroundColor Green
    } catch { Write-Host "  自動タスク: 登録なし" }

    # 2) vmmem / vmwp のコア固定と優先度を戻す (VM 実行中のみ意味がある)
    try {
        $topo = Get-CpuTopology
        $allMask = Get-LpMask @(0..([Math]::Min($topo.Lps, 63) - 1))
        $procs = Get-VmProcesses $VMName
        if ($procs.Vmmem) {
            $p = Get-Process -Id $procs.Vmmem.ProcessId -ErrorAction Stop
            $p.ProcessorAffinity = [IntPtr]$allMask
            try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal } catch { }
            Write-Host "  vmmem のコア固定を解除しました" -ForegroundColor Green
        }
        if ($procs.Vmwp) {
            $w = Get-Process -Id $procs.Vmwp.ProcessId -ErrorAction Stop
            $w.ProcessorAffinity = [IntPtr]$allMask
            Write-Host "  vmwp のコア固定を解除しました" -ForegroundColor Green
        }
    } catch { Write-Host "  プロセスのコア固定: 対象なし ($($_.Exception.Message))" }

    # 3) CPU グループ
    $exe = Find-CpuGroupsExe
    if ($exe) {
        $r1 = Invoke-CpuGroups $exe @("SetVmGroup", "/VmName:$VMName", "/GroupId:$NullGroupId")
        $r2 = Invoke-CpuGroups $exe @("DeleteGroup", "/GroupId:$GroupId")
        if ($r1.Ok -or $r2.Ok) { Write-Host "  CPU グループを解除・削除しました" -ForegroundColor Green }
        else { Write-Host "  CPU グループ: 登録なし" }
    }

    # 4) 処理能力予約を戻す (VM 停止中のみ変更可能)
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ((Get-VMProcessor -VMName $VMName).Reserve -gt 0) {
            if ($vm.State -eq "Off") {
                Set-VMProcessor -VMName $VMName -Reserve 0
                Write-Host "  処理能力予約 (Reserve) を 0 に戻しました" -ForegroundColor Green
            } else {
                Write-Host "  処理能力予約 (Reserve) は VM 停止中に次で戻せます: Set-VMProcessor -VMName $VMName -Reserve 0" -ForegroundColor Yellow
            }
        }
    } catch { }

    # 5) bcdedit (minroot・スケジューラ) を既定へ
    $bcdTouched = $false
    foreach ($name in @("hypervisorrootproc", "hypervisorschedulertype")) {
        if (Invoke-BcdDeleteValue $name) {
            Write-Host "  bcdedit: $name を削除しました (既定に戻ります)" -ForegroundColor Green
            $bcdTouched = $true
        }
    }

    # 6) 設定ファイル
    if (Test-Path $ConfigFile) { Remove-Item $ConfigFile -Force }
    Write-PinLog "Undo: 全設定を解除"

    Write-Host ""
    if ($bcdTouched) {
        Write-Host "解除しました。ハイパーバイザー設定を完全に戻すため、PC を再起動してください。" -ForegroundColor Yellow
    } else {
        Write-Host "解除しました。" -ForegroundColor Green
    }
    exit 0
}

# ============================================================ -Verify (実測)

if ($Verify) {
    $topo = Get-CpuTopology
    $cfg = Get-SavedConfig
    $planHost = @(); $planGuest = @()
    if ($cfg) { $planHost = @([int[]]$cfg.HostLps); $planGuest = @([int[]]$cfg.GuestLps) }

    Write-Host ""
    Write-Host "=== CPU コア分割の実測 (${Seconds}秒間の採取) ===" -ForegroundColor Cyan
    Write-Host "  ホスト Windows から見える論理 CPU 数: $([Environment]::ProcessorCount) / 物理には $($topo.Lps)"
    if ($cfg) {
        Write-Host "  計画: ホスト = CPU $(ConvertTo-LpRangeText $planHost) / ゲスト = CPU $(ConvertTo-LpRangeText $planGuest) ($($cfg.Mode) モード)"
    } else {
        Write-Host "  計画: 未適用 (cpu-partition.json なし)"
    }

    # ハイパーバイザーの論理プロセッサ性能カウンター (言語非依存の CIM クラス経由)
    $cls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorLogicalProcessor" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cls) {
        Write-Host ""
        Write-Host "ハイパーバイザーの性能カウンターが見つかりません (Hyper-V 無効か、カウンター破損)。" -ForegroundColor Yellow
        Write-Host "代わりの確認手段: タスクマネージャーで vmmem の CPU 使用がゲスト用コアに寄っているか (詳細タブ→列に「CPU」追加)。"
        exit 1
    }
    Write-Host "  採取中... (ゲスト VM に負荷がかかっているほど分かりやすい結果になります)"
    $s1 = @(Get-CimInstance -ClassName $cls.CimClassName)
    Start-Sleep -Seconds $Seconds
    $s2 = @(Get-CimInstance -ClassName $cls.CimClassName)

    $rows = @()
    foreach ($b in $s2) {
        if ($b.Name -notmatch '(\d+)\s*$') { continue }   # "_Total" は除外
        $lp = [int]$Matches[1]
        $a = $s1 | Where-Object { $_.Name -eq $b.Name } | Select-Object -First 1
        if (-not $a) { continue }
        $dt = [double]($b.Timestamp_Sys100NS - $a.Timestamp_Sys100NS)
        if ($dt -le 0) { continue }
        $guest = [Math]::Max(0, [Math]::Min(100, 100.0 * ($b.PercentGuestRunTime - $a.PercentGuestRunTime) / $dt))
        $total = [Math]::Max(0, [Math]::Min(100, 100.0 * ($b.PercentTotalRunTime - $a.PercentTotalRunTime) / $dt))
        $side = ""
        if ($planGuest -contains $lp) { $side = "ゲスト用" }
        elseif ($planHost -contains $lp) { $side = "ホスト用" }
        $rows += [pscustomobject]@{ LP = $lp; PlanSide = $side; GuestPct = $guest; HostEtcPct = [Math]::Max(0, $total - $guest) }
    }
    $rows = @($rows | Sort-Object LP)
    if ($rows.Count -eq 0) {
        Write-Host "カウンターの採取に失敗しました。" -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host ("  {0,4} {1,-10} {2,12} {3,16}" -f "CPU", "割り当て", "ゲスト実行%", "ホスト他実行%")
    foreach ($r in $rows) {
        $mark = ""
        if ($r.PlanSide -eq "ホスト用" -and $r.GuestPct -ge 5) { $mark = " ← ゲストが載っている" }
        if ($r.PlanSide -eq "ゲスト用" -and $r.HostEtcPct -ge 20) { $mark = " ← ホスト側の処理が多い" }
        Write-Host ("  {0,4} {1,-10} {2,12:N1} {3,16:N1}{4}" -f $r.LP, $r.PlanSide, $r.GuestPct, $r.HostEtcPct, $mark)
    }

    if ($planGuest.Count -gt 0) {
        $gAll = [double](($rows | Measure-Object -Property GuestPct -Sum).Sum)
        $gOn  = [double](($rows | Where-Object { $planGuest -contains $_.LP } | Measure-Object -Property GuestPct -Sum).Sum)
        Write-Host ""
        if ($gAll -gt 1) {
            $pct = [Math]::Round(100.0 * $gOn / $gAll, 1)
            Write-Host "  ゲスト ($VMName) の CPU 実行のうち、計画どおりゲスト用コア上で実行された割合: $pct%" -ForegroundColor Cyan
            if ($pct -ge 95) { Write-Host "  → 分割は効いています。" -ForegroundColor Green }
            elseif ($pct -ge 70) { Write-Host "  → おおむね効いていますが、完全ではありません (runtime モードの場合は正常範囲。full モードで厳密化できます)。" -ForegroundColor Yellow }
            else { Write-Host "  → 分割が効いていません。-Apply の実行状況と再起動の要否を確認してください。" -ForegroundColor Red }
        } else {
            Write-Host "  ゲストの CPU 使用がほぼゼロのため判定できません。ゲスト VM の稼働中にもう一度実行してください。" -ForegroundColor Yellow
        }
    }
    exit 0
}

# ============================================================ 現状表示 / プレビュー / -Apply

$topo = Get-CpuTopology
$isAdmin = Test-Admin

# --- 現状の収集 ---
$schedNow = Get-HvSchedulerType
$bcd = $null
if ($isAdmin) { try { $bcd = Get-BcdHvSettings } catch { } }
$cfg = Get-SavedConfig
$vm = $null
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
}
$exe = Find-CpuGroupsExe

if (-not $Apply) {
    # ---------- 現状表示 (+ 指定があれば分割案プレビュー) ----------
    Write-Host ""
    Write-Host "=== CPU コア分割の現状 ===" -ForegroundColor Cyan
    Write-Host "  CPU               : $($topo.Name)"
    Write-Host ("  物理コア / 論理CPU : {0} / {1} (SMT x{2}{3})" -f $topo.Cores, $topo.Lps, $topo.SmtPerCore,
        $(if ($topo.HybridSuspected) { "・P/E混成の可能性" } else { "" }))
    Write-Host "  スケジューラ       : $schedNow $(if ($schedNow -eq 'root') { '(クライアント既定。ゲストはホストのスレッドとして実行)' })"
    if ($bcd) {
        Write-Host "  bcdedit 設定      : hypervisorschedulertype=$(if ($bcd.SchedulerType) { $bcd.SchedulerType } else { '(既定)' })  hypervisorrootproc=$(if ($bcd.RootProc) { $bcd.RootProc } else { '(既定)' })"
    } else {
        Write-Host "  bcdedit 設定      : (管理者権限がないため未取得)"
    }
    Write-Host "  ホストから見えるCPU: $([Environment]::ProcessorCount) 論理 $(if ([Environment]::ProcessorCount -lt $topo.Lps) { '← minroot が有効 (ホスト封じ込め中)' })"
    if ($vm) {
        Write-Host ("  VM '{0}'      : {1} / 仮想プロセッサ {2} / 予約 {3}%" -f $VMName, $vm.State,
            (Get-VMProcessor -VMName $VMName).Count, (Get-VMProcessor -VMName $VMName).Reserve)
        if ($vm.State -eq "Running") {
            try {
                $procs = Get-VmProcesses $VMName
                if ($procs.Vmmem) {
                    $p = Get-Process -Id $procs.Vmmem.ProcessId
                    $aff = [int64]$p.ProcessorAffinity
                    $lps = @(0..([Math]::Min($topo.Lps, 63) - 1) | Where-Object { ($aff -band ([int64]1 -shl $_)) -ne 0 })
                    Write-Host "  vmmem のコア固定   : CPU $(ConvertTo-LpRangeText $lps) (優先度 $($p.PriorityClass))"
                }
            } catch { }
        }
    } else {
        Write-Host "  VM '$VMName'      : (未作成)"
    }
    Write-Host "  CpuGroups.exe     : $(if ($exe) { $exe } else { '(なし。full モードの完全固定時に使用)' })"
    if ($cfg) {
        Write-Host ""
        Write-Host "  適用済みの計画    : $($cfg.Mode) モード / ホスト = CPU $(ConvertTo-LpRangeText @([int[]]$cfg.HostLps)) / ゲスト = CPU $(ConvertTo-LpRangeText @([int[]]$cfg.GuestLps))" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  適用済みの計画    : なし" -ForegroundColor Yellow
    }

    if ($HostCores -gt 0 -or $HostLps -ne "") {
        Write-Host ""
        Write-Host "=== 分割案プレビュー (まだ適用しません) ===" -ForegroundColor Cyan
        $previewMode = $Mode
        if ($previewMode -eq "") { $previewMode = "runtime" }
        $plan = Resolve-Plan $topo $previewMode
        Write-Host "  ホスト Windows : CPU $(ConvertTo-LpRangeText $plan.HostLps) ($($plan.HostLps.Count) 論理)"
        Write-Host "  ゲスト VM      : CPU $(ConvertTo-LpRangeText $plan.GuestLps) ($($plan.GuestLps.Count) 論理)"
        Write-Host ""
        Write-Host "  適用するには: .\cpu-partition.ps1 -Apply -Mode runtime $(if ($HostLps) { "-HostLps `"$HostLps`"" } else { "-HostCores $HostCores" })$(if ($GuestLps) { " -GuestLps `"$GuestLps`"" })" -ForegroundColor Cyan
        Write-Host "    -Mode runtime : 再起動不要。ゲスト VM を専用コアへ固定 (まず推奨)"
        Write-Host "    -Mode full    : 再起動 2 回で完全分割 (ホスト側もコアから締め出す)"
    } else {
        Write-Host ""
        Write-Host "使い方: .\cpu-partition.ps1 -HostCores 4        ← 分割案を見る" -ForegroundColor Cyan
        Write-Host "        Get-Help .\cpu-partition.ps1 -Full      ← 説明"
    }
    exit 0
}

# ---------- -Apply ----------
if (-not $isAdmin) { Write-Error "管理者権限の PowerShell で実行してください。"; exit 1 }
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V が有効になっていません。管理者 PowerShell で Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All を実行して再起動してください。"
    exit 1
}
if ($Mode -eq "") {
    Write-Error "-Apply には -Mode runtime か -Mode full を指定してください (違いはヘルプ参照)。迷ったら runtime。"
    exit 1
}
if (-not $vm -and -not $AllowMissingVM) {
    Write-Error ("VM '$VMName' がありません。-VMName で対象の VM 名を指定してください (一覧: Get-VM)。`n" +
        "まだ VM を作っていない場合は -AllowMissingVM を付けると、計画だけ保存して VM の作成・起動後に自動適用します。")
    exit 1
}
if (-not $vm) {
    Write-Host "VM '$VMName' は未作成です。計画を保存し、VM を作成・起動した時点で自動適用します。" -ForegroundColor Yellow
}

# 適用のたびに指定がなければ、保存済み計画を引き継ぐ (full の 2 段階目で同じ指定を省略可能に)
if ($HostCores -eq 0 -and $HostLps -eq "" -and $cfg -and $cfg.Mode -eq $Mode) {
    $HostLps  = ConvertTo-LpRangeText @([int[]]$cfg.HostLps)
    $GuestLps = ConvertTo-LpRangeText @([int[]]$cfg.GuestLps)
    Say "保存済みの計画を使用します (ホスト = $HostLps / ゲスト = $GuestLps)" "Cyan"
}
$plan = Resolve-Plan $topo $Mode
$hostText  = ConvertTo-LpRangeText $plan.HostLps
$guestText = ConvertTo-LpRangeText $plan.GuestLps

# NUMA 複数ノードの注意 (工場 PC ではまれだが正直に案内)
try {
    $numa = @(Get-CimInstance Win32_Processor).Count
    if ($numa -ge 2) {
        Say "注意: マルチソケット構成です。NUMA ノードをまたぐ割り当ては性能が落ちることがあります。" "Yellow"
    }
} catch { }

Write-Host ""
Write-Host "=== CPU コア分割の適用 ($Mode モード) ===" -ForegroundColor Cyan
Write-Host "  ホスト Windows : CPU $hostText ($($plan.HostLps.Count) 論理)"
Write-Host "  ゲスト VM      : CPU $guestText ($($plan.GuestLps.Count) 論理)"

# vCPU 数とゲスト用コア数の一致を確認 (1 論理 CPU = 1 仮想プロセッサが理想形)
$vcpu = 0
if ($vm) { $vcpu = [int](Get-VMProcessor -VMName $VMName).Count }
if ($vm -and $vcpu -ne $plan.GuestLps.Count) {
    if ($vm.State -eq "Off") {
        Write-Host "  仮想プロセッサ数を $vcpu → $($plan.GuestLps.Count) に合わせます (1 コア = 1 仮想プロセッサが理想のため)" -ForegroundColor Cyan
        Set-VMProcessor -VMName $VMName -Count $plan.GuestLps.Count
    } else {
        Write-Host "  注意: 仮想プロセッサ数 ($vcpu) がゲスト用論理 CPU 数 ($($plan.GuestLps.Count)) と不一致です。" -ForegroundColor Yellow
        Write-Host "        VM 停止中に再度 -Apply すると自動調整します (ずれたままでも動きますが理想は 1:1)。" -ForegroundColor Yellow
    }
}

if ($Mode -eq "runtime") {
    # ======================== runtime モード ========================
    if ($schedNow -ne "root") {
        Write-Error ("runtime モードは root スケジューラ (クライアント既定) 専用ですが、現在は '$schedNow' です。`n" +
            "full モードを使うか、.\cpu-partition.ps1 -Undo で既定に戻して再起動してください。")
        exit 1
    }
    if (-not $bcd) { try { $bcd = Get-BcdHvSettings } catch { } }
    if ($bcd -and ($bcd.SchedulerType -or $bcd.RootProc)) {
        Write-Error ("full モード用のハイパーバイザー設定が書き込み済みです (次回再起動で有効化され、runtime モードと矛盾します)。`n" +
            "full を続けるなら再起動して '-Apply -Mode full' を、runtime にするなら先に '-Undo' を実行してください。")
        exit 1
    }
    if (-not $NoConfirm) {
        $ans = Read-Host "適用します (再起動不要・-Undo でいつでも解除可)。よろしいですか? (y/N)"
        if ($ans -ne "y") { exit 0 }
    }

    Save-Config ([pscustomobject]@{
        Mode = "runtime"; VMName = $VMName
        HostLps = $plan.HostLps; GuestLps = $plan.GuestLps
        NoPriorityBoost = [bool]$NoPriorityBoost
        PendingVM = (-not $vm)     # VM 未作成のまま保存した計画かどうか
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
    Write-PinLog "Apply(runtime): ホスト=$hostText ゲスト=$guestText"

    $taskNote = Register-PinTask
    Write-Host "  VM 起動時に自動で固定し直すタスク '$PinTaskName' を登録しました" -ForegroundColor Green
    if ($taskNote) { Write-Host "  ($taskNote)" -ForegroundColor Yellow }

    if ($vm -and $vm.State -eq "Running") {
        $msg = Set-RuntimePin $plan.HostLps $plan.GuestLps (-not $NoPriorityBoost)
        Write-PinLog "Apply(runtime) 即時適用: $msg"
        if ($msg -like "ok:*") { Write-Host "  即時適用: $($msg.Substring(4))" -ForegroundColor Green }
        else { Write-Host "  即時適用: $msg" -ForegroundColor Yellow }
    } elseif ($vm) {
        Write-Host "  VM は停止中です。次回起動時に自動タスクが適用します。"
    } else {
        Write-Host "  VM が未作成のため、作成して起動した時点で自動タスクが適用します。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "適用しました (runtime モード)。" -ForegroundColor Green
    Write-Host "  - ゲスト ($VMName) の CPU 実行は CPU $guestText に物理固定されました"
    Write-Host "  - Windows 側の処理は優先度で押し出されます (完全な締め出しは -Mode full)"
    Write-Host "  - 効き具合の実測: .\cpu-partition.ps1 -Verify" -ForegroundColor Cyan
    exit 0
}

# ======================== full モード ========================
$wantRootProc = $plan.HostLps.Count
if (-not $bcd) { $bcd = Get-BcdHvSettings }
$bcdReady = ($bcd.SchedulerType -eq $Scheduler) -and ($bcd.RootProc -eq $wantRootProc)

if (-not $bcdReady) {
    # ---- 第 1 段階: ハイパーバイザー設定の書き込み (要再起動) ----
    Write-Host ""
    Write-Host "【第 1 段階】ハイパーバイザー設定を書き込みます (反映には再起動が必要):" -ForegroundColor Cyan
    Write-Host "    bcdedit /set hypervisorschedulertype $Scheduler"
    Write-Host "    bcdedit /set hypervisorrootproc $wantRootProc   (ホストを先頭 $wantRootProc 論理 CPU に封じ込め)"
    Write-Host ""
    Write-Host "  ※ クライアント版 Windows でのスケジューラ変更は Microsoft 公式サポート外の構成です。" -ForegroundColor Yellow
    Write-Host "  ※ 万一 Windows 起動後に Hyper-V が動かない等の問題が出た場合の復旧手順 (控えておくこと):" -ForegroundColor Yellow
    Write-Host "       bcdedit /deletevalue hypervisorschedulertype"
    Write-Host "       bcdedit /deletevalue hypervisorrootproc"
    Write-Host "     (Windows 自体は通常どおり起動します。回復環境からでも同じコマンドで戻せます)"
    if (-not $NoConfirm) {
        $ans = Read-Host "書き込みます。よろしいですか? (y/N)"
        if ($ans -ne "y") { exit 0 }
    }

    Invoke-Bcdedit @("/set", "hypervisorschedulertype", $Scheduler)
    Invoke-Bcdedit @("/set", "hypervisorrootproc", "$wantRootProc")

    Save-Config ([pscustomobject]@{
        Mode = "full"; VMName = $VMName
        HostLps = $plan.HostLps; GuestLps = $plan.GuestLps
        Scheduler = $Scheduler; NoPriorityBoost = $false
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
    Write-PinLog "Apply(full) 第1段階: sched=$Scheduler rootproc=$wantRootProc"

    Write-Host ""
    Write-Host "書き込みました。PC を再起動してから、もう一度同じコマンドを実行してください:" -ForegroundColor Green
    Write-Host "    .\cpu-partition.ps1 -Apply -Mode full" -ForegroundColor Cyan
    Write-Host "  (計画は保存済みのため、コア指定の再入力は不要です)"
    exit 0
}

# ---- 第 2 段階: 再起動後の確認とゲストのコア固定 ----
Write-Host ""
Write-Host "【第 2 段階】再起動後の反映確認とゲスト VM のコア固定を行います。" -ForegroundColor Cyan

$visibleLps = [Environment]::ProcessorCount
# SMT なしの CPU では core 指定でも classic として動作・報告される (仕様) ため同一視する
$schedOk = ($schedNow -eq $Scheduler) -or
    ($Scheduler -eq "core" -and $schedNow -eq "classic" -and $topo.SmtPerCore -eq 1)
if (-not $schedOk -or $visibleLps -ne $wantRootProc) {
    Write-Host ""
    Write-Host "設定はまだ反映されていません:" -ForegroundColor Yellow
    Write-Host "  現在のスケジューラ: $schedNow (期待: $Scheduler)"
    Write-Host "  ホストから見える論理 CPU: $visibleLps (期待: $wantRootProc)"
    if ($schedNow -eq "root") {
        Write-Host "PC をまだ再起動していない場合は、再起動してから再実行してください。" -ForegroundColor Yellow
    } else {
        Write-Host "再起動済みでこの表示の場合、この PC では minroot が効いていません。" -ForegroundColor Red
        Write-Host "  → .\cpu-partition.ps1 -Undo で戻したうえで、-Mode runtime をご利用ください。" -ForegroundColor Red
    }
    exit 1
}
Write-Host "  反映を確認: スケジューラ=$schedNow / ホストは論理 $visibleLps 個に封じ込め済み" -ForegroundColor Green
Write-Host "  → Windows のプロセス・割り込みは CPU $hostText の外には出られません (isolcpus 相当)"

# runtime 用の自動タスクが残っていたら外す (full では不要)
try { Unregister-ScheduledTask -TaskName $PinTaskName -Confirm:$false -ErrorAction Stop } catch { }

# --- CpuGroups.exe の用意 ---
if (-not $exe) {
    Write-Host ""
    Write-Host "ゲスト側の完全固定には Microsoft 製 CpuGroups.exe が必要です (未検出)。" -ForegroundColor Yellow
    $dl = "n"
    if (-not $NoConfirm) { $dl = Read-Host "Microsoft Download Center から取得しますか? (y/N)" }
    if ($AutoGetTools) { $dl = "y" }
    if ($dl -eq "y") {
        try {
            if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
            $dest = Join-Path $ToolsDir "CpuGroups.exe"
            Invoke-WebRequest -Uri $CpuGroupsUrl -OutFile $dest -UseBasicParsing
            $head = [System.IO.File]::ReadAllBytes($dest)[0..1]
            if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) {   # "MZ" = 実行ファイルの印
                Remove-Item $dest -Force
                throw "取得したファイルが実行ファイルではありません (リンク先が変更された可能性)"
            }
            $exe = $dest
            Write-Host "  取得しました: $dest" -ForegroundColor Green
        } catch {
            Write-Host "  取得できませんでした: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  手動で入手する場合: $CpuGroupsUrl をブラウザで開き、CpuGroups.exe を windows-host\tools\ に置いてください。"
        }
    }
}

$groupBound = $false
if ($exe) {
    Write-Host ""
    Write-Host "CPU グループで VM '$VMName' を CPU $guestText に固定します..." -ForegroundColor Cyan
    # 作り直しに備えて一旦ほどく (存在しなければ単に失敗し、無視してよい)
    Invoke-CpuGroups $exe @("SetVmGroup", "/VmName:$VMName", "/GroupId:$NullGroupId") | Out-Null
    Invoke-CpuGroups $exe @("DeleteGroup", "/GroupId:$GroupId") | Out-Null

    $affinityArg = ($plan.GuestLps -join ",")
    $rCreate = Invoke-CpuGroups $exe @("CreateGroup", "/GroupId:$GroupId", "/GroupAffinity:$affinityArg")
    $rBind = $null
    if ($rCreate.Ok -and $vm) {
        $rBind = Invoke-CpuGroups $exe @("SetVmGroup", "/VmName:$VMName", "/GroupId:$GroupId")
    } elseif ($rCreate.Ok) {
        Write-Host "  CPU グループを作成しました (VM 未作成のため割り当ては VM 作成後に -Apply し直してください)" -ForegroundColor Yellow
    }
    if ($rCreate.Ok -and $rBind -and $rBind.Ok) {
        $groupBound = $true
        Write-Host "  CPU グループを作成し、VM '$VMName' を割り当てました" -ForegroundColor Green
        $rShow = Invoke-CpuGroups $exe @("GetGroups")
        if ($rShow.Ok -and $rShow.Output) { Write-Host ($rShow.Output -replace "(?m)^", "    ") }
    } else {
        $failOut = ""
        if (-not $rCreate.Ok) { $failOut = $rCreate.Output } elseif ($rBind) { $failOut = $rBind.Output }
        Write-Host "  CPU グループの作成に失敗しました: $failOut" -ForegroundColor Yellow
        Write-Host "  (CPU グループは Windows Server の機能で、クライアント版では動かない環境もあります)" -ForegroundColor Yellow
        if ($vm -and $vm.State -ne "Off") {
            Write-Host "  VM 実行中が原因の可能性もあります。VM を停止して再実行してみてください: Stop-VM $VMName" -ForegroundColor Yellow
        }
    }
}

# --- CPU グループが使えない場合の処理能力予約 (準分割の仕上げ) ---
if (-not $groupBound -and -not $NoReserve -and $vm) {
    if ($vm.State -eq "Off") {
        Set-VMProcessor -VMName $VMName -Reserve 100
        Write-Host "  代わりに処理能力予約 (Reserve 100%) を設定しました ($Scheduler スケジューラでは有効に機能します)" -ForegroundColor Green
    } else {
        Write-Host "  処理能力予約は VM 停止中に設定できます: Set-VMProcessor -VMName $VMName -Reserve 100" -ForegroundColor Yellow
    }
}

Save-Config ([pscustomobject]@{
    Mode = "full"; VMName = $VMName
    HostLps = $plan.HostLps; GuestLps = $plan.GuestLps
    Scheduler = $Scheduler; GroupBound = $groupBound; NoPriorityBoost = $false
    PendingVM = (-not $vm)
    UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
})
Write-PinLog "Apply(full) 第2段階: groupBound=$groupBound"

Write-Host ""
if ($groupBound) {
    Write-Host "完全分割が成立しました (Linux 主構成の isolcpus + vcpupin 相当)。" -ForegroundColor Green
    Write-Host "  - ホスト Windows : CPU $hostText から出られません (minroot)"
    Write-Host "  - ゲスト VM      : CPU $guestText から出られません (CPU グループ)"
} else {
    Write-Host "準分割で適用しました。" -ForegroundColor Yellow
    Write-Host "  - ホスト Windows : CPU $hostText から出られません (minroot) ← ここは完全"
    Write-Host "  - ゲスト VM      : 空いている CPU $guestText 上でほぼ実行されます (ハイパーバイザー任せ + 予約で保証)"
}
Write-Host ""
Write-Host "VM を起動して実測してください: Start-VM $VMName → .\cpu-partition.ps1 -Verify" -ForegroundColor Cyan
