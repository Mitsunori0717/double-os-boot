<#
.SYNOPSIS
    Windows と Hyper-V EdgeBox の間で CPU コアを分割し、固定割り当て (ピンニング) します。
    主構成 (Linux Windows) の isolcpus + vcpupin に相当する機能の Windows版です。

.DESCRIPTION
    2 つの分割モードがあります。どちらも -Undo で完全に元へ戻せます。

    ■ runtime モード (推奨の入口。再起動不要・Windows 標準構成のまま)
        クライアント版 Windows の Hyper-V は既定で「root スケジューラ」で動いており、
        EdgeBox のプロセッサは vmmem プロセスのスレッドとして Windows の
        スケジューラが実行しています。この性質を利用して:
          - vmmem (= EdgeBox の CPU 実行の実体) をEdgeBox 用コアへ物理固定
          - vmwp (= EdgeBox のディスク/ネットワーク処理) をWindows 用コアへ固定
          - vmmem の優先度を High に昇格 (EdgeBox 用コアを Windows 側の処理が
            奪いにくくする)
          - 常駐 'CpuPartition-Watch' が 3 秒ごとに、vmmem 以外の全プロセス
            (Windows 側のすべて) を Windows 用コアへ固定し直す = Windows 側の締め出し。
            新しく起動したプロセスも数秒以内に Windows 用コアへ戻される
        EdgeBox の起動を検出して自動で再適用するタスクも登録するため、一度 -Apply
        すれば電源 ON だけの運用でも効き続けます。
        残る混ざりは、固定できない保護されたシステムプロセス (csrss 等) とカーネル・
        割り込みの分だけ (通常 1% 未満)。それも無くすには full モード。

    ■ full モード (完全分割。要再起動 + 設定変更 2 段階)
        ハイパーバイザーのスケジューラを core に切り替えたうえで:
          - minroot (bcdedit hypervisorrootproc) で Windows自体を
            下位コアへ封じ込める (Linux の isolcpus 相当。Windows のプロセス・
            割り込みはEdgeBox 用コアに一切載らなくなる)
          - CPU グループ (Microsoft 製 CpuGroups.exe) でEdgeBox を上位コアへ
            固定する (Linux の vcpupin 相当)
        両方向とも物理的な分割になります。CpuGroups.exe が使えない環境では
        minroot + 処理能力予約 (-Reserve) までの「準分割」で止まり、その旨を
        正直に報告します。
        手順は「-Apply -Mode full → 再起動」だけ。再起動後は起動タスク 'CpuPartition-Boot' が
        CPU グループの作成と EdgeBox の固定を自動で行い、以後も起動のたびに作り直します
        (CPU グループは再起動で消えるため)。成立状態は cpu-full-status.json に書き、
        『EdgeBox 監視』と設定コンソールに表示します。
        ※ スケジューラ変更はクライアント版 Windows では Microsoft の公式
           サポート外の構成です (動作実績は広くあります)。工場 PC のような
           専用用途向けで、-Undo でいつでも既定へ戻せます。

.EXAMPLE
    .\cpu-partition.ps1                                   # 現状の確認 (何も変更しない)
    .\cpu-partition.ps1 -HostCores 4                      # 分割案のプレビュー (何も変更しない)
    .\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4 # 再起動なしで分割 (Windows に物理4コア)
    .\cpu-partition.ps1 -Apply -Mode full    -HostCores 4 # 完全分割 (再起動→もう一度同じコマンド)
    .\cpu-partition.ps1 -Verify                           # 実測: 各コアで誰が実行されているか
    .\cpu-partition.ps1 -SelfTest                         # 撤退手順の予行 (収集は止まらない)
    .\cpu-partition.ps1 -MemoryGB 12                      # EdgeBox のメモリを 12 GB に (EdgeBox 停止中に反映)
    .\cpu-partition.ps1 -MemoryGB 12 -RestartVM           # 今すぐ反映 (EdgeBox を停止→設定→起動)
    .\cpu-partition.ps1 -Undo                             # 全て元に戻す

.EXAMPLE
    # P/E コア混成 CPU (Intel 12世代以降) や、割り当てを番号で決めたい場合
    .\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-11" -GuestLps "12-19"

.NOTES
    管理者権限の PowerShell で実行してください (-Verify と現状確認は管理者なしでも可)。
    設定は cpu-partition.json に保存され、自動タスクが参照します。
    対象 は -VMName で指定します (既定: EdgeBox)。どの Hyper-V EdgeBox にも使えます。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",

    # --- 適用 ---
    [switch]$Apply,
    [ValidateSet("runtime", "full")]
    [string]$Mode = "",

    # Windows に残す物理コア数 (SMT 有効なら論理 CPU は 2 倍になる)
    [int]$HostCores = 0,
    # EdgeBox に渡す物理コア数 (省略時: 残り全部)
    [int]$GuestCores = 0,
    # 論理 CPU 番号での明示指定 (例: "0-7" や "0-3,8-11")。指定時は -HostCores より優先
    [string]$HostLps = "",
    [string]$GuestLps = "",

    # full モードで使うハイパーバイザースケジューラ (core 推奨。classic は旧方式)
    [ValidateSet("core", "classic")]
    [string]$Scheduler = "core",

    [switch]$NoPriorityBoost,   # runtime: vmmem の優先度昇格をしない
    [switch]$NoContain,         # runtime: Windows 側のプロセスを Windows 用コアへ締め出す常駐 (CpuPartition-Watch) を使わない
    [switch]$NoReserve,         # full: CPU グループ不成立時の処理能力予約をしない
    [switch]$AutoGetTools,      # full: CpuGroups.exe を確認なしで取得する (設定コンソール用)
    [switch]$AllowMissingVM,    # EdgeBox が未作成でも計画を保存する (作成・起動後に自動タスクが適用)

    # --- 確認・解除 ---
    [switch]$Verify,            # 実測 (各論理 CPU のEdgeBox/合計実行率を採取)
    [int]$Seconds = 5,          # -Verify の採取時間
    [switch]$Undo,              # 全設定の解除
    [switch]$SelfTest,          # 撤退手順の予行 (-Undo → 再適用 まで自動。収集は止まらない)

    # --- メモリ ---
    [int]$MemoryGB = 0,         # EdgeBox に割り当てるメモリ (GB)。0 = 変更しない
    [switch]$RestartVM,         # -MemoryGB: EdgeBox が実行中なら 停止→設定→起動 で今すぐ反映する

    # --- 内部用 (自動タスクが呼ぶ) ---
    [switch]$ApplyRuntime,
    [switch]$Watch,             # 常駐: vmmem を EdgeBox 用コアへ、それ以外の全プロセスを Windows 用コアへ固定し続ける
    [switch]$BootApply,         # full モードの起動時処理: CPU グループを作り直して EdgeBox を固定し、EdgeBox を起動する
    [switch]$Quiet,
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"

$ConfigFile  = Join-Path $PSScriptRoot "cpu-partition.json"
$LogFile     = Join-Path $PSScriptRoot "cpu-partition-log.txt"
$ToolsDir    = Join-Path $PSScriptRoot "tools"
$PinTaskName = "CpuPartition-Pin"
$WatchTaskName = "CpuPartition-Watch"                        # 締め出しの常駐タスク
$BootTaskName  = "CpuPartition-Boot"                         # full モード: 起動のたびに CPU グループを作り直すタスク
$FullStatusFile = Join-Path $PSScriptRoot "cpu-full-status.json"   # full モードの成立状態 (監視画面・設定コンソールが読む)
$ContainStatusFile = Join-Path $PSScriptRoot "cpu-contain-status.json"   # 常駐の状態 (監視画面が読む)
$AppsFile    = Join-Path $PSScriptRoot "cpu-apps.json"       # アプリ単位の割り当て (締め出しの例外)
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

# --- メモリ ---
# PC 全体のメモリを Windows と EdgeBox で分ける。EdgeBox は固定メモリ (動的メモリは
# 専用機のような装置には向かない: バルーン ドライバー前提で、収集中の挙動が読めない)
$MemHostReserveGB = 8    # Windows 側に最低限残す量 (Windows 11 + アプリ + Hyper-V 自身)
$MemGuestMinGB    = 4    # EdgeBox の最低量
$MemGuestRecGB    = 8    # EdgeBox の推奨量 (EdgeBox の元の構成に相当)

function Get-MemoryInfo([string]$Name) {
    # 戻り値: TotalGB (PC 全体) / VmGB (EdgeBox の設定値) / Dynamic (動的メモリか) / Vm
    $totalGB = 0.0
    try { $totalGB = [Math]::Round(([double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory) / 1GB, 1) } catch { }
    $vmGB = 0.0; $dyn = $false; $vm = $null
    if (Get-Command Get-VMMemory -ErrorAction SilentlyContinue) {
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        if ($vm) {
            try {
                $m = Get-VMMemory -VMName $Name -ErrorAction Stop
                $vmGB = [Math]::Round(([double]$m.Startup) / 1GB, 1)
                $dyn  = [bool]$m.DynamicMemoryEnabled
            } catch { }
        }
    }
    return [pscustomobject]@{ TotalGB = $totalGB; VmGB = $vmGB; Dynamic = $dyn; Vm = $vm }
}

function Test-MemoryPlan([double]$TotalGB, [int]$GuestGB, [string]$Name) {
    # PC の実メモリに対して、その割り当てが成り立つかを検査する
    $errors = @(); $warnings = @()
    $hostGB = [Math]::Round($TotalGB - $GuestGB, 1)
    if ($GuestGB -lt $MemGuestMinGB) {
        $errors += "登録 '$Name' には最低 $MemGuestMinGB GB 必要です (指定: $GuestGB GB)"
    }
    if ($TotalGB -gt 0 -and $hostGB -lt $MemHostReserveGB) {
        $errors += ("Windows 側に最低 $MemHostReserveGB GB 残す必要があります " +
                    "(この PC は $TotalGB GB のため、EdgeBox は最大 $([int][Math]::Floor($TotalGB - $MemHostReserveGB)) GB まで)")
    }
    if ($GuestGB -lt $MemGuestRecGB) { $warnings += "登録 '$Name' の推奨は $MemGuestRecGB GB 以上です" }
    if ($TotalGB -gt 0 -and $GuestGB -gt ($TotalGB / 2)) {
        $warnings += "EdgeBox に PC の半分以上を割り当てています (Windows 側が窮屈になるかもしれません)"
    }
    return [pscustomobject]@{ Errors = $errors; Warnings = $warnings; HostGB = $hostGB }
}

# --- EdgeBox に対応する vmwp / vmmem プロセスを探す ---
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

# --- CpuGroups.exe の取得 (Microsoft Download Center)。戻り値: パス (取れなければ $null) ---
function Get-CpuGroupsExe {
    $exe = Find-CpuGroupsExe
    if ($exe) { return $exe }
    try {
        if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir | Out-Null }
        $dest = Join-Path $ToolsDir "CpuGroups.exe"
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        Invoke-WebRequest -Uri $CpuGroupsUrl -OutFile $dest -UseBasicParsing
        $head = [System.IO.File]::ReadAllBytes($dest)[0..1]
        if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) {   # "MZ" = 実行ファイルの印
            Remove-Item $dest -Force
            throw "取得したファイルが実行ファイルではありません (リンク先が変更された可能性)"
        }
        Write-PinLog "CpuGroups.exe を取得: $dest"
        return $dest
    } catch {
        Write-PinLog "CpuGroups.exe の取得に失敗: $($_.Exception.Message)"
        return $null
    }
}

# --- CpuGroups.exe の出力から GUID を拾う (小文字) ---
function Get-GuidsInText([string]$Text) {
    $list = @()
    foreach ($m in [regex]::Matches([string]$Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) { $list += $m.Value.ToLower() }
    return $list
}

# --- EdgeBox がいまどの CPU グループに属しているか (GUID 小文字。無し/不明は "") ---
# 実機の出力: "VmName VmId CpuGroupId / EdgeBox CB46099F-... B0EDB0ED-..." のように
# EdgeBox 自身の ID (VmId) も GUID で出るため、それを除いた最後の GUID をグループ ID とみなす
function Get-VmGroupId([string]$Exe, [string]$Name) {
    $r = Invoke-CpuGroups $Exe @("GetVmGroup", "/VmName:$Name")
    if (-not $r.Ok) { return "" }
    $vmid = ""
    try { $vmid = ([string](Get-VM -Name $Name -ErrorAction Stop).Id).ToLower() } catch { }
    $g = @(Get-GuidsInText $r.Output)
    if ($g.Count -eq 0) { return "" }
    $last = $g[-1]                                          # 表の最後の列 = CpuGroupId
    if ($last -eq $NullGroupId) { return "none" }           # 照会できて「未所属」
    if ($last -eq $vmid) { return "" }                      # 列が読めない (不明)
    return $last
}

# --- 本ツールの CPU グループが存在するか ---
$script:GroupsLogged = $false
function Test-OurGroupExists([string]$Exe) {
    $r = Invoke-CpuGroups $Exe @("GetGroups")
    if (-not $r.Ok) { return $false }
    $found = ((@(Get-GuidsInText $r.Output)) -contains $GroupId.ToLower())
    if (-not $found -and -not $script:GroupsLogged) {
        $script:GroupsLogged = $true
        Write-PinLog ("CpuGroups GetGroups (本ツールのグループが見当たらない): 出力=" + (([string]$r.Output) -replace '\s+', ' ').Trim())
    }
    return $found
}

# --- CPU グループを作り直して EdgeBox を固定する (何度呼んでも同じ結果になる) ---
# 実行中の EdgeBox は SetVmGroup が失敗する (実機: 0x80048007) ため、
#   ・所属が本ツールのグループ → 何もしない
#   ・グループはあるが所属を照会できない → 実行中なら触らない (ほどくと固定が外れる瞬間ができる)。停止中なら付け直す
#   ・グループが無い → 作って割り当てる (実行中なら失敗することがある。次に停止したとき = 再起動時に付く)
# 戻り値: @{ Bound = 成立したか; Message = 説明 }
function Invoke-FullBind([string]$Exe, [int[]]$GuestArr, $VmObj) {
    if (-not $Exe) { return [pscustomobject]@{ Bound = $false; Message = "CpuGroups.exe がありません" } }
    if (-not $VmObj) {
        $names = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        return [pscustomobject]@{ Bound = $false; Message = ("登録 '$VMName' が見つかりません (ある登録: " + $(if ($names.Count -gt 0) { $names -join ", " } else { "なし" }) + ")") }
    }
    $running = ([string]$VmObj.State -ne "Off")
    $lpText = ConvertTo-LpRangeText $GuestArr
    $cur = Get-VmGroupId $Exe $VMName      # "" = 不明 / "none" = 未所属 / GUID = 所属グループ
    if ($cur -eq $GroupId.ToLower()) {
        return [pscustomobject]@{ Bound = $true; Message = "EdgeBox は CPU グループ (CPU $lpText) に固定済み" }
    }
    $exists = Test-OurGroupExists $Exe
    if ($cur -eq "" -and $exists -and $running) {
        return [pscustomobject]@{ Bound = $true; Message = "CPU グループ (CPU $lpText) は作成済み (所属の照会は不可。実行中のため付け直しはしない)" }
    }
    if ($cur -ne "" -and $cur -ne "none" -and $running) {
        # 別のグループに属している (通常は起きない)。実行中は付け替えられないので次の停止時に直す
        return [pscustomobject]@{ Bound = $false; Message = "EdgeBox が別の CPU グループ ($cur) に属しています。EdgeBox の停止時に付け直します" }
    }
    # ここからは (未所属) か (グループが無い) か (停止中で付け直す)。
    # 実行中の EdgeBox の所属は決してほどかない (ほどいた瞬間に Windows 用コアへ載る)
    if (-not $running -and $cur -ne "" -and $cur -ne "none") {
        Invoke-CpuGroups $Exe @("SetVmGroup", "/VmName:$VMName", "/GroupId:$NullGroupId") | Out-Null
    }
    if ($exists -and -not $running) { Invoke-CpuGroups $Exe @("DeleteGroup", "/GroupId:$GroupId") | Out-Null; $exists = $false }
    if (-not $exists) {
        $rCreate = Invoke-CpuGroups $Exe @("CreateGroup", "/GroupId:$GroupId", "/GroupAffinity:$($GuestArr -join ',')")
        if (-not $rCreate.Ok) {
            return [pscustomobject]@{ Bound = $false; Message = "CPU グループを作成できません: $($rCreate.Output)" }
        }
    }
    $rBind = Invoke-CpuGroups $Exe @("SetVmGroup", "/VmName:$VMName", "/GroupId:$GroupId")
    if (-not $rBind.Ok) {
        $why = $rBind.Output
        if ($running) { $why += " (EdgeBox 実行中は割り当てられません。次に停止したとき = 再起動時に自動で付きます)" }
        return [pscustomobject]@{ Bound = $false; Message = "EdgeBox を CPU グループに割り当てられません: $why" }
    }
    # 照会できる環境なら、結果を 1 回だけ記録に残す (出力の書式を知るため)
    $chk = Invoke-CpuGroups $Exe @("GetVmGroup", "/VmName:$VMName")
    Write-PinLog ("CpuGroups GetVmGroup: ok=" + $chk.Ok + " 出力=" + (([string]$chk.Output) -replace '\s+', ' ').Trim())
    return [pscustomobject]@{ Bound = $true; Message = "CPU グループを作成し、EdgeBox を CPU $lpText に固定しました" }
}

function Write-FullStatus([hashtable]$H) {
    try {
        $H["At"] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        [pscustomobject]$H | ConvertTo-Json -Depth 3 | Set-Content -Path $FullStatusFile -Encoding UTF8
    } catch { }
}

# full モードの起動時タスク (SYSTEM・起動時に開始・その後 5 分ごとに確かめ直す)
function Register-BootTask {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -BootApply -Quiet"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $logonRep = New-ScheduledTaskTrigger -AtLogOn
    try {
        $logonRep.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
    } catch { }
    $logonPlain = New-ScheduledTaskTrigger -AtLogOn
    $lastErr = $null
    foreach ($trig in @(@($boot, $logonRep), @($boot, $logonPlain), @($boot))) {
        try {
            Register-ScheduledTask -TaskName $BootTaskName -Trigger $trig -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            return
        } catch { $lastErr = $_ }
    }
    throw "起動タスク '$BootTaskName' を登録できませんでした: $($lastErr.Exception.Message)"
}
function Unregister-BootTask {
    try { Unregister-ScheduledTask -TaskName $BootTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Remove-Item $FullStatusFile -Force -ErrorAction SilentlyContinue
}

# full モードの成立状態 (状態ファイルから)。戻り値: 表示用の 1 行
function Get-FullStatusText {
    $st = $null
    try { if (Test-Path $FullStatusFile) { $st = Get-Content $FullStatusFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    if (-not $st) { return "まだ起動タスクが動いていません (再起動後に自動で行います)" }
    if ($st.Bound) { return ("完全分割 成立 — Windows は CPU {0} に封じ込め (minroot) / EdgeBox は CPU {1} に固定 (CPU グループ)  最終確認 {2}" -f $st.HostLps, $st.GuestLps, $st.At) }
    if (-not $st.MinrootOk) { return ("未反映 — {0}  最終確認 {1}" -f $st.Message, $st.At) }
    return ("準分割 (EdgeBox の固定が効いていません: {0})  最終確認 {1}" -f $st.Message, $st.At)
}

# full モードの第 2 段階 (再起動後): minroot の反映を確かめ、CPU グループで EdgeBox を固定し、
# 状態を記録して、自動起動を任されていれば EdgeBox を起動する。起動タスクからも手動 -Apply からも呼ぶ。
# 何度呼んでも同じ結果になる。戻り値: 完全分割が成立したか
function Invoke-FullStage2([int[]]$HostArr, [int[]]$GuestArr, [bool]$Interactive) {
    $hostText = ConvertTo-LpRangeText $HostArr
    $guestText = ConvertTo-LpRangeText $GuestArr
    $wantRootProc = $HostArr.Count
    $topo2 = Get-CpuTopology
    $schedNow2 = Get-HvSchedulerType
    $visibleLps = [Environment]::ProcessorCount
    # SMT なしの CPU では core 指定でも classic として動作・報告される (仕様) ため同一視する
    $schedOk = ($schedNow2 -eq $Scheduler) -or
        ($Scheduler -eq "core" -and $schedNow2 -eq "classic" -and $topo2.SmtPerCore -eq 1)
    if (-not $schedOk -or $visibleLps -ne $wantRootProc) {
        $msg = "ハイパーバイザー設定が未反映 (スケジューラ=$schedNow2 期待=$Scheduler / Windows から見える論理 CPU=$visibleLps 期待=$wantRootProc)"
        Write-FullStatus @{ MinrootOk = $false; Bound = $false; Message = $msg; HostLps = $hostText; GuestLps = $guestText; Scheduler = $schedNow2; VisibleLps = $visibleLps }
        Write-PinLog "Full: $msg"
        if ($Interactive) {
            Write-Host ""
            Write-Host "設定はまだ反映されていません:" -ForegroundColor Yellow
            Write-Host "  現在のスケジューラ: $schedNow2 (期待: $Scheduler)"
            Write-Host "  Windows から見える論理 CPU: $visibleLps (期待: $wantRootProc)"
            if ($schedNow2 -eq "root") {
                Write-Host "PC をまだ再起動していない場合は、再起動してください (再起動後は起動タスクが自動で完了します)。" -ForegroundColor Yellow
            } else {
                Write-Host "再起動済みでこの表示の場合、この PC では minroot が効いていません。" -ForegroundColor Red
                Write-Host "  → .\cpu-partition.ps1 -Undo で戻したうえで、-Mode runtime をご利用ください。" -ForegroundColor Red
            }
        }
        return $false
    }
    Say "  反映を確認: スケジューラ=$schedNow2 / Windows は論理 $visibleLps 個に封じ込め済み" "Green"
    Say "  → Windows のプロセス・割り込みは CPU $hostText の外には出られません (isolcpus 相当)"

    # runtime 用の自動タスク・常駐は不要 (minroot が Windows を封じ込める)
    try { Unregister-ScheduledTask -TaskName $PinTaskName -Confirm:$false -ErrorAction Stop } catch { }
    Stop-WatchTask

    # CpuGroups.exe
    $exe2 = Find-CpuGroupsExe
    if (-not $exe2) {
        $get = (-not $Interactive) -or $AutoGetTools
        if (-not $get -and $Interactive -and -not $NoConfirm) {
            Write-Host ""
            Write-Host "EdgeBox 側の完全固定には Microsoft 製 CpuGroups.exe が必要です (未検出)。" -ForegroundColor Yellow
            $get = ((Read-Host "Microsoft Download Center から取得しますか? (y/N)") -eq "y")
        }
        if ($get) { $exe2 = Get-CpuGroupsExe }
        if ($exe2) { Say "  CpuGroups.exe を取得しました: $exe2" "Green" }
        elseif ($Interactive) { Write-Host "  CpuGroups.exe がありません。手動で入手する場合: $CpuGroupsUrl をブラウザで開き、tools\ に置いてください。" -ForegroundColor Yellow }
    }

    $vm2 = $null
    try { $vm2 = Get-VM -Name $VMName -ErrorAction Stop } catch { }
    # vCPU 数と EdgeBox 用コア数を合わせる (停止中のみ変更可能)
    if ($vm2 -and [string]$vm2.State -eq "Off") {
        try {
            $vcpu2 = [int](Get-VMProcessor -VMName $VMName).Count
            if ($vcpu2 -ne $GuestArr.Count) {
                Set-VMProcessor -VMName $VMName -Count $GuestArr.Count
                Write-PinLog "Full: プロセッサ数を $vcpu2 → $($GuestArr.Count) に合わせました"
            }
        } catch { }
    }

    $bind = Invoke-FullBind $exe2 $GuestArr $vm2
    Write-PinLog "Full: $($bind.Message)"
    if ($bind.Bound) {
        Say "  $($bind.Message)" "Green"
    } else {
        Say "  $($bind.Message)" "Yellow"
        if ($Interactive) {
            Write-Host "  (CPU グループは Windows Server の機能で、クライアント版では動かない環境もあります)" -ForegroundColor Yellow
        }
        # 準分割の仕上げ: 処理能力予約 (停止中のみ設定可能)
        if (-not $NoReserve -and $vm2 -and [string]$vm2.State -eq "Off") {
            try { Set-VMProcessor -VMName $VMName -Reserve 100; Say "  代わりに処理能力予約 (Reserve 100%) を設定しました" "Yellow" } catch { }
        }
    }

    $cfg2 = Get-SavedConfig
    if ($cfg2) {
        $cfg2 | Add-Member -NotePropertyName GroupBound -NotePropertyValue ([bool]$bind.Bound) -Force
        $cfg2 | Add-Member -NotePropertyName PendingReboot -NotePropertyValue $false -Force
        Save-Config $cfg2
    }
    Write-FullStatus @{ MinrootOk = $true; Bound = [bool]$bind.Bound; Message = $bind.Message; HostLps = $hostText; GuestLps = $guestText; Scheduler = $schedNow2; VisibleLps = $visibleLps }

    # EdgeBox の自動起動を任されている場合は、固定したあとに起動する (固定できなくても止めたままにはしない)
    if ($vm2 -and [string]$vm2.State -eq "Off" -and $cfg2 -and $cfg2.ManageVmStart) {
        try { Start-VM -Name $VMName -ErrorAction Stop; Write-PinLog "Full: EdgeBox を起動しました" }
        catch { Write-PinLog "Full: EdgeBox の起動に失敗: $($_.Exception.Message)" }
    }
    return [bool]$bind.Bound
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
        if ($n -ge $total) { throw "Windows に $HostCores コア (論理 $n) を残すとEdgeBox 用が残りません (全論理 $total)" }
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
        if ($n -gt $rest.Count) { throw "EdgeBox 用に $GuestCores コア (論理 $n) は確保できません (残り論理 $($rest.Count))" }
        $g = @($rest | Select-Object -First $n)
    } else {
        $g = @(0..($total - 1) | Where-Object { $h -notcontains $_ })
    }

    # --- 妥当性 ---
    foreach ($i in $g) {
        if ($h -contains $i) { throw "論理 CPU $i がWindows とEdgeBox の両方に指定されています" }
    }
    if ($h.Count -lt 2) { throw "Windows 側は最低 2 論理 CPU 必要です (EdgeBox のディスク/ネットワーク処理もWindows 側で動くため 4 以上を推奨)" }
    if ($g.Count -lt 1) { throw "EdgeBox 側の論理 CPU がありません" }

    if ($PlanMode -eq "full") {
        # minroot はWindows を「先頭から N 個」の論理 CPU に閉じ込める方式のため、
        # full モードのWindows 側は 0 始まりの連番であることが必須
        $expected = @(0..($h.Count - 1))
        $diff = Compare-Object $h $expected
        if ($diff) {
            throw "full モードのWindows 側は 0 から始まる連番 (例: 0-7) である必要があります (minroot の仕様)。`n" +
                  "指定: $(ConvertTo-LpRangeText $h)  → 例えば -HostLps `"0-$($h.Count - 1)`" としてください。"
        }
    }

    if (($h.Count + $g.Count) -lt $total) {
        $rest = @(0..($total - 1) | Where-Object { ($h -notcontains $_) -and ($g -notcontains $_) })
        Say ("注意: 論理 CPU {0} はどちらにも割り当てられず遊びます。" -f (ConvertTo-LpRangeText $rest)) "Yellow"
    }
    if ($h.Count -lt 4) {
        Say "注意: Windows 側が論理 4 未満です。EdgeBox のディスク/ネットワーク処理はWindows 側コアで動くため、細くしすぎると EdgeBox の I/O も遅くなります。" "Yellow"
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

# vmmem をEdgeBox 用コアへ、vmwp をWindows 用コアへ固定する。戻り値: 結果の説明文字列
function Set-RuntimePin([int[]]$HostArr, [int[]]$GuestArr, [bool]$Boost) {
    $procs = Get-VmProcesses $VMName
    if (-not $procs.Vm) {
        return "skip: 登録 '$VMName' はまだ作成されていません (作成して起動すれば自動で適用します)"
    }
    if ($procs.Vm.State -ne "Running") {
        return "skip: 登録 '$VMName' が実行中でないため何もしませんでした ($($procs.Vm.State))"
    }
    if (-not $procs.Vmmem) {
        return "fail: vmmem プロセスが見つかりません (EdgeBox 起動直後なら数十秒後に自動タスクが再適用します)"
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

# ============================================================ Windows 側の締め出し (runtime モードの常駐)
#   vmmem 以外の全プロセスを Windows 用コアに固定し直す。EdgeBox 用コアには Windows のプロセスが
#   載らなくなる (minroot 無しでできる範囲の締め出し)。固定できないのは保護されたシステムプロセス
#   (csrss, wininit, services, Registry, System など) とカーネルの処理だけで、それらは記録に残す。

# アプリ単位の割り当て (cpu-apps.json) に登録されたプロセスは、そちらの指定を優先して触らない
function Get-AppExceptionPids {
    $set = @{}
    if (-not (Test-Path $AppsFile)) { return $set }
    try {
        foreach ($a in @(Get-Content $AppsFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
            if (-not $a.Match) { continue }
            foreach ($p in @(Get-Process -Name ([string]$a.Match) -ErrorAction SilentlyContinue)) { $set[[int]$p.Id] = $true }
        }
    } catch { }
    return $set
}

# 1 回の見回り: EdgeBox 用コアに掛かっている Windows 側のプロセスを Windows 用コアへ固定する
# $Skip = 固定できなかった PID → 時刻 (5 分は再試行しない)。戻り値: 件数と固定できなかった名前
function Invoke-HostContainment([int64]$HostMask, [int64]$GuestMask, [hashtable]$Skip, [hashtable]$Except) {
    $contained = 0; $pinned = 0; $unpin = @{}
    $now = Get-Date
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $id = [int]$p.Id
        if ($id -le 4) { continue }                       # Idle / System (固定不可)
        $n = [string]$p.ProcessName
        if ($n -like 'vmmem*') { continue }              # EdgeBox の CPU 実行そのもの (EdgeBox 用コアに固定済み)
        if ($Except.ContainsKey($id)) { continue }
        if ($Skip.ContainsKey($id) -and (($now - $Skip[$id]).TotalSeconds -lt 300)) { continue }
        try {
            $aff = [int64]$p.ProcessorAffinity
            if (($aff -band $GuestMask) -ne 0) {
                $p.ProcessorAffinity = [IntPtr]$HostMask
                $pinned++
            }
            $contained++
        } catch {
            $gone = $false
            try { $gone = $p.HasExited } catch { }
            if ($gone) { continue }
            $Skip[$id] = $now
            $unpin[$n] = $true
        }
    }
    return [pscustomobject]@{ Contained = $contained; Pinned = $pinned; Unpinnable = @($unpin.Keys | Sort-Object) }
}

function Get-WatchProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'cpu-partition\.ps1' -and $_.CommandLine -match '-Watch' -and $_.ProcessId -ne $PID })
}

# 常駐タスクの登録 (SYSTEM 権限・起動時とログオン時に開始・実行時間の制限なし・落ちたら再開)
function Register-WatchTask {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Watch -Quiet"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
    $boot = New-ScheduledTaskTrigger -AtStartup
    try { $boot.Delay = "PT1M" } catch { }
    $logon = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $WatchTaskName -Trigger @($boot, $logon) `
        -Action $action -Principal $principal -Settings $settings -Force | Out-Null
}

# 常駐が動いていなければ起動する。戻り値: 起動したか
function Start-WatchTask {
    $t = Get-ScheduledTask -TaskName $WatchTaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    if ($t.State -eq "Running") { return $false }
    Start-ScheduledTask -TaskName $WatchTaskName -ErrorAction Stop
    return $true
}

function Stop-WatchTask {
    try { Stop-ScheduledTask -TaskName $WatchTaskName -ErrorAction SilentlyContinue } catch { }
    try { Unregister-ScheduledTask -TaskName $WatchTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    foreach ($w in (Get-WatchProcesses)) { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $ContainStatusFile -Force -ErrorAction SilentlyContinue
}

# 常駐の状態 (状態ファイルから)。戻り値: 表示用の 1 行
function Get-ContainStatusText {
    $t = Get-ScheduledTask -TaskName $WatchTaskName -ErrorAction SilentlyContinue
    if (-not $t) { return "未設定 (runtime モードを適用すると常駐 '$WatchTaskName' が登録されます)" }
    $st = $null
    try { if (Test-Path $ContainStatusFile) { $st = Get-Content $ContainStatusFile -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    if (-not $st) { return ("タスクは登録済み (" + $t.State + ") ですが、まだ状態の記録がありません") }
    $age = ((Get-Date) - [datetime]$st.At).TotalSeconds
    $alive = ($age -lt 30)
    $unp = @($st.Unpinnable)
    return ("{0} — Windows のプロセス {1} 個を CPU {2} に固定中 (固定不可: {3}) 最終確認 {4}" -f
        $(if ($alive) { "動作中" } else { "停止中? (最終確認から " + [int]$age + " 秒)" }),
        $st.Contained, $st.HostLps, $(if ($unp.Count -gt 0) { $unp -join ", " } else { "なし" }), $st.At)
}

# EdgeBox 起動を検出して自動で再適用するタスク (SYSTEM 権限)
# 戻り値: 制限があった場合の説明 (無ければ空文字)
function Register-PinTask {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ApplyRuntime -Quiet"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    # 1) EdgeBox 起動イベント (最速で反映される)。作れない環境ではスキップ
    $evTrigger = $null
    try {
        $xml = '<QueryList><Query Id="0" Path="Microsoft-Windows-Hyper-V-Worker-Admin">' +
               '<Select Path="Microsoft-Windows-Hyper-V-Worker-Admin">' +
               "*[System[Provider[@Name='Microsoft-Windows-Hyper-V-Worker'] and EventID=18500]]" +
               '</Select></Query></QueryList>'
        $evClass = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" `
            -ClassName "MSFT_TaskEventTrigger" -ErrorAction Stop
        $evTrigger = New-CimInstance -CimClass $evClass -ClientOnly `
            -Property @{ Enabled = $true; Subscription = $xml } -ErrorAction Stop
    } catch {
        Write-PinLog "Register-PinTask: イベントトリガー不可 ($($_.Exception.Message))"
    }

    $boot = New-ScheduledTaskTrigger -AtStartup
    try { $boot.Delay = "PT2M" } catch { }

    # 2) ログオン + 2 分ごとの再適用。
    #    繰り返し期間は指定しない (無期限扱い)。[TimeSpan]::MaxValue は
    #    タスク XML の範囲外としてタスクスケジューラに拒否される環境がある
    $logonRep = New-ScheduledTaskTrigger -AtLogOn
    try {
        $logonRep.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 2)).Repetition
    } catch { }
    $logonPlain = New-ScheduledTaskTrigger -AtLogOn

    # 受け付けられる組み合わせは環境によって違うため、
    # 機能の多い順に試し、必ずどれかで登録できるようにする
    $plans = @()
    if ($evTrigger) { $plans += [pscustomobject]@{ T = @($evTrigger, $boot, $logonRep);   N = "" } }
    $plans += [pscustomobject]@{ T = @($boot, $logonRep)
                                 N = "EdgeBox 起動イベントのトリガーが使えないため、2 分ごとの再適用で補います" }
    if ($evTrigger) { $plans += [pscustomobject]@{ T = @($evTrigger, $boot, $logonPlain)
                                                   N = "定期実行が使えないため、EdgeBox 起動イベントと起動/ログオン時に適用します" } }
    $plans += [pscustomobject]@{ T = @($boot, $logonPlain)
                                 N = "この環境では起動時とログオン時のみの適用になります (EdgeBox 起動時の即時反映は不可)" }

    $lastErr = $null
    foreach ($plan in $plans) {
        try {
            Register-ScheduledTask -TaskName $PinTaskName -Trigger $plan.T `
                -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            if ($plan.N) { Write-PinLog "Register-PinTask: $($plan.N)" }
            return $plan.N
        } catch {
            $lastErr = $_
        }
    }
    throw "自動タスク '$PinTaskName' を登録できませんでした: $($lastErr.Exception.Message)"
}

# -VMName を明示していない場合は、保存済み計画の 登録名を採用する。
# 既定値 (EdgeBox) のまま -Undo すると別 EdgeBox を対象にしてしまい、
# 「タスクは消えたが vmmem の固定は外れていない」という中途半端な状態になる。
if (-not $PSBoundParameters.ContainsKey("VMName")) {
    $cfgVm = Get-SavedConfig
    if ($cfgVm -and $cfgVm.VMName) { $VMName = [string]$cfgVm.VMName }
}

# 登録名が実在しない場合 (名前を変えた・旧名のまま保存されていた等) は、EdgeBox の物理ディスクを持つ
# 登録か、1 つしかない登録を対象にする (windows-host 側と同じ考え方)。見つけたら設定ファイルも直す
function Resolve-VMName([string]$Name) {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $Name }
    if ($Name -and (Get-VM -Name $Name -ErrorAction SilentlyContinue)) { return $Name }
    $all = @(Get-VM -ErrorAction SilentlyContinue)
    $found = @()
    foreach ($v in $all) {
        $pt = @(Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.DiskNumber })
        if ($pt.Count -gt 0) { $found += $v }
    }
    $pick = $null
    if ($found.Count -eq 1) { $pick = $found[0].Name } elseif ($all.Count -eq 1) { $pick = $all[0].Name }
    if ($pick -and $pick -ne $Name) {
        Write-PinLog "登録名 '$Name' が見つからないため、'$pick' を対象にします (設定ファイルも書き換え)"
        try {
            $c = Get-SavedConfig
            if ($c -and [string]$c.VMName -eq $Name) { $c.VMName = $pick; Save-Config $c }
        } catch { }
        return $pick
    }
    return $Name
}
if (-not $PSBoundParameters.ContainsKey("VMName")) { $VMName = Resolve-VMName $VMName }

# ============================================================ -MemoryGB (EdgeBox のメモリ)
#
# メモリは EdgeBox の停止中にしか変更できない (固定メモリ)。実行中に指定された場合は
# -RestartVM があるときだけ 停止→設定→起動 を行う。停止は正常シャットダウンのみで、
# 強制電源断は行わない (収集中のデータやファイルシステムを壊しうるため)。

if ($MemoryGB -gt 0) {
    if (-not (Test-Admin)) { Write-Error "管理者権限の PowerShell で実行してください。"; exit 1 }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { Write-Error "Hyper-V が有効になっていません。"; exit 1 }
    $mi = Get-MemoryInfo $VMName
    if (-not $mi.Vm) { Write-Error "登録 '$VMName' がありません。-VMName で対象の 登録名を指定してください。"; exit 1 }

    Write-Host ""
    Write-Host "=== EdgeBox のメモリ割り当て ===" -ForegroundColor Cyan
    Write-Host ("  この PC のメモリ : {0} GB" -f $mi.TotalGB)
    Write-Host ("  現在の設定       : {0} GB{1}" -f $mi.VmGB, $(if ($mi.Dynamic) { " (動的)" } else { " (固定)" }))
    $chk = Test-MemoryPlan $mi.TotalGB $MemoryGB $VMName
    Write-Host ("  新しい設定       : {0} GB (固定) → Windows 側に {1} GB" -f $MemoryGB, $chk.HostGB)
    foreach ($w in $chk.Warnings) { Write-Host "  注意: $w" -ForegroundColor Yellow }
    if ($chk.Errors.Count -gt 0) {
        foreach ($e in $chk.Errors) { Write-Host "  不可: $e" -ForegroundColor Red }
        exit 2
    }
    if ($mi.VmGB -eq $MemoryGB -and -not $mi.Dynamic) {
        Write-Host "  既に同じ設定です。変更はありません。" -ForegroundColor Green
        exit 0
    }

    $state = [string]$mi.Vm.State
    if ($state -ne "Off") {
        if (-not $RestartVM) {
            Write-Host ""
            Write-Host "  登録 '$VMName' は $state のため、メモリは停止中にしか変更できません。" -ForegroundColor Yellow
            Write-Host "  今すぐ反映するには (収集が数分止まります): .\cpu-partition.ps1 -MemoryGB $MemoryGB -RestartVM" -ForegroundColor Cyan
            exit 3
        }
        if (-not $NoConfirm) {
            $ans = Read-Host "  EdgeBox を 停止 → 設定 → 起動 します (収集が数分止まります)。よろしいですか? (y/N)"
            if ($ans -ne "y") { exit 0 }
        }
        Write-Host "  EdgeBox を停止しています (正常シャットダウン)..."
        try { Stop-VM -Name $VMName -ErrorAction Stop } catch {
            Write-PinLog "Memory: 停止失敗 $($_.Exception.Message)"
            Write-Error ("EdgeBox を停止できませんでした: $($_.Exception.Message)`n" +
                "EdgeBox の管理画面から先にシャットダウンし、停止後にもう一度 -MemoryGB $MemoryGB を実行してください。")
            exit 1
        }
        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-VM -Name $VMName).State -ne "Off") {
            if ((Get-Date) -gt $deadline) {
                Write-Error "EdgeBox が 180 秒以内に停止しませんでした。メモリは変更していません。"
                exit 1
            }
            Start-Sleep -Seconds 3
        }
        Write-Host "  停止しました。"
    }

    try {
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGB * 1GB) -ErrorAction Stop
        Write-PinLog "Memory: 登録 '$VMName' を $MemoryGB GB に変更"
        Write-Host "  メモリを $MemoryGB GB に設定しました。" -ForegroundColor Green
    } catch {
        Write-PinLog "Memory: 設定失敗 $($_.Exception.Message)"
        if ($state -ne "Off") { try { Start-VM -Name $VMName } catch { } }   # 止めた EdgeBox は必ず起動し直す
        Write-Error "メモリを設定できませんでした: $($_.Exception.Message)"
        exit 1
    }
    if ($state -ne "Off") {
        Write-Host "  EdgeBox を起動しています..."
        try {
            Start-VM -Name $VMName -ErrorAction Stop
            Write-Host "  起動しました。コア固定は自動タスクが数秒後に適用し直します。" -ForegroundColor Green
        } catch {
            Write-Error "EdgeBox を起動できませんでした: $($_.Exception.Message)"
            exit 1
        }
    }
    exit 0
}

# ============================================================ -BootApply (full モードの起動時処理・内部用)
#   CPU グループは再起動で消えるため、起動のたびに作り直して EdgeBox を固定し、そのあと EdgeBox を起動する。
#   5 分ごとにも呼ばれ、固定が外れていれば作り直す (何度呼んでも同じ結果)

if ($BootApply) {
    $cfgB = Get-SavedConfig
    if (-not $cfgB -or $cfgB.Mode -ne "full") { exit 0 }
    if ($cfgB.VMName) { $VMName = [string]$cfgB.VMName }
    if ($cfgB.Scheduler) { $Scheduler = [string]$cfgB.Scheduler }
    # Hyper-V の管理サービスが上がるまで待つ (最大 3 分)
    for ($i = 0; $i -lt 36; $i++) {
        $svc = Get-Service vmms -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { break }
        Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds 3
    $VMName = Resolve-VMName $VMName
    try {
        Invoke-FullStage2 @([int[]]$cfgB.HostLps) @([int[]]$cfgB.GuestLps) $false | Out-Null
    } catch {
        Write-PinLog "BootApply: エラー $($_.Exception.Message)"
        Write-FullStatus @{ MinrootOk = $false; Bound = $false; Message = ("起動時処理でエラー: " + $_.Exception.Message); HostLps = (ConvertTo-LpRangeText @([int[]]$cfgB.HostLps)); GuestLps = (ConvertTo-LpRangeText @([int[]]$cfgB.GuestLps)) }
    }
    exit 0
}

# ============================================================ -Watch (常駐・内部用)
#   3 秒ごとに見回り: (1) 10 秒に 1 回 vmmem / vmwp の固定を確かめ直す
#                     (2) EdgeBox 用コアに掛かっている Windows 側のプロセスを Windows 用コアへ戻す
#   状態は cpu-contain-status.json に書き、監視画面『EdgeBox 監視』がそれを表示する

if ($Watch) {
    Write-PinLog "Watch: 常駐を開始 (PID $PID)"
    $skip = @{}; $except = @{}
    $cfgW = $null; $lastCfgRead = [datetime]::MinValue
    $hostArr = @(); $guestArr = @(); $hostMask = [int64]0; $guestMask = [int64]0
    $vmMsg = ""; $lastVmMsg = ""; $lastVmAt = [datetime]::MinValue
    $acc = 0; $lastAccLog = Get-Date; $lastUnpin = ""
    while ($true) {
        try {
            if (((Get-Date) - $lastCfgRead).TotalSeconds -gt 30) {
                $lastCfgRead = Get-Date
                $cfgW = Get-SavedConfig
                if (-not $cfgW -or $cfgW.Mode -ne "runtime" -or $cfgW.HostContain -eq $false) {
                    Write-PinLog "Watch: 締め出しの対象外 (設定なし / full モード / 締め出しオフ) のため終了します"
                    Remove-Item $ContainStatusFile -Force -ErrorAction SilentlyContinue
                    exit 0
                }
                if ($cfgW.VMName) { $VMName = Resolve-VMName ([string]$cfgW.VMName) }
                $hostArr = @([int[]]$cfgW.HostLps); $guestArr = @([int[]]$cfgW.GuestLps)
                $hostMask = Get-LpMask $hostArr; $guestMask = Get-LpMask $guestArr
                $except = Get-AppExceptionPids
                try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]$hostMask } catch { }   # 自分も Windows 用コアで動く
            }
            # (1) vmmem / vmwp
            if (((Get-Date) - $lastVmAt).TotalSeconds -ge 10) {
                $lastVmAt = Get-Date
                try { $vmMsg = Set-RuntimePin $hostArr $guestArr (-not [bool]$cfgW.NoPriorityBoost) } catch { $vmMsg = "fail: " + $_.Exception.Message }
                if ($vmMsg -ne $lastVmMsg) { Write-PinLog "Watch: $vmMsg"; $lastVmMsg = $vmMsg }
            }
            # (2) 締め出し
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-HostContainment $hostMask $guestMask $skip $except
            $sw.Stop()
            $acc += $r.Pinned
            if ($acc -gt 0 -and ((Get-Date) - $lastAccLog).TotalSeconds -ge 60) {
                Write-PinLog "Watch: この 1 分で $acc 個のプロセスを Windows 用コア (CPU $(ConvertTo-LpRangeText $hostArr)) へ戻しました (固定中 $($r.Contained) 個)"
                $acc = 0; $lastAccLog = Get-Date
            }
            $unpinText = ($r.Unpinnable -join ", ")
            if ($unpinText -and $unpinText -ne $lastUnpin) {
                Write-PinLog "Watch: 固定できないプロセス (保護されたシステムプロセス。カーネルと同様に固定の対象外): $unpinText"
                $lastUnpin = $unpinText
            }
            [pscustomobject]@{
                At = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Pid = $PID; VMName = $VMName
                HostLps = (ConvertTo-LpRangeText $hostArr); GuestLps = (ConvertTo-LpRangeText $guestArr)
                Contained = $r.Contained; Pinned = $r.Pinned; Unpinnable = $r.Unpinnable
                Vm = $vmMsg; SweepMs = $sw.ElapsedMilliseconds
            } | ConvertTo-Json -Depth 3 | Set-Content -Path $ContainStatusFile -Encoding UTF8
        } catch {
            Write-PinLog ("Watch: エラー " + $_.Exception.Message)
        }
        Start-Sleep -Seconds 3
    }
}

# ============================================================ -ApplyRuntime (内部用)

if ($ApplyRuntime) {
    $cfg = Get-SavedConfig
    if (-not $cfg) { Write-PinLog "ApplyRuntime: 設定ファイルなし。何もしません"; exit 0 }
    if ($cfg.Mode -ne "runtime") { exit 0 }   # full モード時はハイパーバイザー側で固定済み
    if ($cfg.VMName) { $VMName = Resolve-VMName ([string]$cfg.VMName) }

    # EdgeBox 起動直後は vmmem が出そろうまで少し待つ (最大 60 秒)
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
    # 締め出しの常駐が止まっていれば起こす (2 分ごとのこのタスクが保険になる)
    if ($cfg.HostContain -ne $false) {
        try { if (Start-WatchTask) { Write-PinLog "ApplyRuntime: 常駐 '$WatchTaskName' を起動し直しました" } } catch { Write-PinLog "ApplyRuntime: 常駐の起動に失敗: $($_.Exception.Message)" }
    }
    if (-not $Quiet) {
        if ($msg -like "ok:*") { Write-Host "CPU コア固定を適用: $msg" -ForegroundColor Green }
        elseif ($msg -like "skip:*") { Write-Host $msg }
        else { Write-Host "CPU コア固定に失敗: $msg" -ForegroundColor Yellow }
    }
    if ($msg -like "fail:*") { exit 1 }
    exit 0
}

# ============================================================ -Undo

# ============================================================ -SelfTest (撤退手順の予行)
#
# 「いざというとき -Undo で戻せる」ことを、実際に戻して確かめる。
# 手作業だと途中で中断したときに分割が外れたまま残るため、
# 何があっても最後に必ず再適用する (finally)。
# 収集は止まらない (EdgeBox は動いたまま。変わるのはコアの割り当てだけ)。

if ($SelfTest) {
    if (-not (Test-Admin)) { Write-Error "管理者権限の PowerShell で実行してください。"; exit 1 }

    $cfg = Get-SavedConfig
    if (-not $cfg) {
        Write-Error "適用済みの設定がありません。先に -Apply してから予行してください。"
        exit 1
    }
    if ([string]$cfg.Mode -ne "runtime") {
        Write-Error ("予行できるのは runtime モードの設定だけです (現在: $($cfg.Mode))。`n" +
            "full モードの解除は bcdedit を書き換えるため再起動が必要で、無人での予行に向きません。")
        exit 1
    }

    # -Undo は cpu-partition.json を消すため、復元に必要な情報を先に控える
    $tVm    = [string]$cfg.VMName
    $tHost  = ConvertTo-LpRangeText @([int[]]$cfg.HostLps)
    $tGuest = ConvertTo-LpRangeText @([int[]]$cfg.GuestLps)
    $tBoost = [bool]$cfg.NoPriorityBoost
    $guestMask = Get-LpMask @([int[]]$cfg.GuestLps)

    function Get-VmmemAffinity([string]$Name) {
        # 戻り値: vmmem の現在のアフィニティ (EdgeBox 停止中など取得できない場合は $null)
        try {
            $pr = Get-VmProcesses $Name
            if (-not $pr.Vmmem) { return $null }
            return [int64](Get-Process -Id $pr.Vmmem.ProcessId -ErrorAction Stop).ProcessorAffinity
        } catch { return $null }
    }
    # 呼び出した子プロセスの出力は、NG が出たときだけ見せる (普段は邪魔なので伏せる)
    $script:lastOut = ""
    $script:lastOutShown = $true
    function Show-LastOutput {
        if ($script:lastOutShown -or -not $script:lastOut) { return }
        Write-Host "      --- 呼び出したコマンドの出力 ---" -ForegroundColor DarkGray
        foreach ($l in ($script:lastOut -split "`r?`n")) {
            if ($l.Trim()) { Write-Host "      | $l" -ForegroundColor DarkGray }
        }
        $script:lastOutShown = $true
    }

    function Invoke-Self([string[]]$ScriptArgs) {
        # 実際に運用者が打つのと同じ形で呼び出す (別プロセス・終了コードで判定)
        #
        # 引数名に $Args は使えない。PowerShell の自動変数と衝突し、
        # 渡したはずの引数が空になって「素の状態表示」が走ってしまう
        # (この予行自体が最初それで誤判定した)。
        $q = '"' + $PSCommandPath + '"'
        $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $q) + $ScriptArgs
        $tmp = Join-Path $env:TEMP ("cpu-selftest-" + [Guid]::NewGuid().ToString("N") + ".txt")
        try {
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList $all -Wait -PassThru `
                -NoNewWindow -RedirectStandardOutput $tmp
            $script:lastOut = ""
            if (Test-Path $tmp) {
                try { $script:lastOut = [string](Get-Content $tmp -Raw -Encoding UTF8) } catch { }
            }
            $script:lastOutShown = $false
            return $p.ExitCode
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    $results = @()
    function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
        $script:results += [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail }
        $mark = if ($Ok) { "OK  " } else { "NG  " }
        $col  = if ($Ok) { "Green" } else { "Red" }
        Write-Host ("  {0}{1}{2}" -f $mark, $Name, $(if ($Detail) { " — $Detail" } else { "" })) -ForegroundColor $col
        if (-not $Ok) { Show-LastOutput }
    }

    Write-Host ""
    Write-Host "=== 撤退手順の予行 (-Undo → 再適用) ===" -ForegroundColor Cyan
    Write-Host "  対象  : $tVm"
    Write-Host "  戻す計画 : Windows = CPU $tHost / EdgeBox = CPU $tGuest"
    Write-Host "  収集は止まりません (EdgeBox は動いたまま)。最後に必ず元の割り当てへ戻します。"
    Write-Host ""

    $affBefore = Get-VmmemAffinity $tVm
    if ($affBefore -eq $null) {
        Write-Host "  注意: vmmem が見つからないため (EdgeBox 停止中?)、コア固定の確認は省略します。" -ForegroundColor Yellow
    }

    try {
        # --- 1) 解除 ---
        Write-Host "[1/3] 解除 (-Undo)" -ForegroundColor Cyan
        $rc = Invoke-Self @("-Undo", "-VMName", $tVm, "-NoConfirm")
        Add-Check "-Undo が正常終了する" ($rc -eq 0) "終了コード $rc"
        Add-Check "自動タスクが削除される" `
            (-not (Get-ScheduledTask -TaskName $PinTaskName -ErrorAction SilentlyContinue)) $PinTaskName
        Add-Check "設定ファイルが削除される" (-not (Test-Path $ConfigFile)) "cpu-partition.json"
        if ($affBefore -ne $null) {
            $affUndo = Get-VmmemAffinity $tVm
            Add-Check "vmmem のコア固定が解除される" `
                ($affUndo -ne $null -and $affUndo -ne $guestMask) "全コアで実行可能な状態に戻る"
        }
    } finally {
        # --- 2) 再適用 (途中で失敗しても必ず通す) ---
        Write-Host ""
        Write-Host "[2/3] 再適用 (元の割り当てへ復帰)" -ForegroundColor Cyan
        $applyArgs = @("-Apply", "-Mode", "runtime", "-VMName", $tVm,
                       "-HostLps", $tHost, "-GuestLps", $tGuest, "-NoConfirm", "-Quiet")
        if ($tBoost) { $applyArgs += "-NoPriorityBoost" }
        $rc2 = Invoke-Self $applyArgs
        Add-Check "再適用が正常終了する" ($rc2 -eq 0) "終了コード $rc2"
        Add-Check "自動タスクが再登録される" `
            ([bool](Get-ScheduledTask -TaskName $PinTaskName -ErrorAction SilentlyContinue)) $PinTaskName
        Add-Check "設定ファイルが復元される" (Test-Path $ConfigFile) "cpu-partition.json"
        if ($affBefore -ne $null) {
            $affAfter = Get-VmmemAffinity $tVm
            Add-Check "vmmem が元のコアへ固定し直される" ($affAfter -eq $guestMask) "CPU $tGuest"
        }
    }

    # --- 3) 自動タスクが本当に固定し直せるか ---
    #
    # ここがいちばん静かに失敗する。分割が外れても Windows も EdgeBox も普通に動くため
    # 誰も気付かない。再起動せずに、タスクの「中身」だけを試す
    # (再起動が確かめるのは引き金の方で、それは別途 1-5 で行う)。
    if ($affBefore -ne $null) {
        Write-Host ""
        Write-Host "[3/3] 自動タスクによる復元 (再起動せずに動作だけ確認)" -ForegroundColor Cyan
        try {
            $wideMask = Get-LpMask @(0..([Math]::Min([Environment]::ProcessorCount, 63) - 1))
            $pr = Get-VmProcesses $tVm
            $pp = Get-Process -Id $pr.Vmmem.ProcessId -ErrorAction Stop
            $pp.ProcessorAffinity = [IntPtr]$wideMask
            Add-Check "固定を一旦外す" ((Get-VmmemAffinity $tVm) -ne $guestMask) "わざと分割が外れた状態を作る"

            Start-ScheduledTask -TaskName $PinTaskName -ErrorAction Stop
            $restored = $false
            for ($i = 0; $i -lt 45; $i++) {
                Start-Sleep -Seconds 2
                if ((Get-VmmemAffinity $tVm) -eq $guestMask) { $restored = $true; break }
            }
            Add-Check "自動タスクが固定し直す" $restored `
                $(if ($restored) { "CPU $tGuest に復帰 (約 $($i * 2) 秒)" } else { "90 秒待っても復帰しませんでした" })
        } catch {
            Add-Check "自動タスクによる復元" $false $_.Exception.Message
        } finally {
            # 何があっても計画どおりの状態で終える
            $msg = Set-RuntimePin @([int[]]$cfg.HostLps) @([int[]]$cfg.GuestLps) (-not $tBoost)
            if ($msg -notlike "ok:*") { Write-Host "  最終確認: $msg" -ForegroundColor Yellow }
        }
    }

    $ng = @($results | Where-Object { -not $_.Ok })
    Write-Host ""
    Write-PinLog "SelfTest: $($results.Count) 項目中 $($ng.Count) 件 NG"
    if ($ng.Count -eq 0) {
        Write-Host "予行 合格 ($($results.Count)/$($results.Count))。いつでも安全に撤退できます。" -ForegroundColor Green
        Write-Host "  実運用での撤退: .\cpu-partition.ps1 -Undo -VMName $tVm" -ForegroundColor Cyan
        exit 0
    } else {
        Write-Host "予行 不合格 ($($ng.Count) 件)。撤退手順が確実でないため、本番運用に進まないでください。" -ForegroundColor Red
        foreach ($x in $ng) { Write-Host "  - $($x.Name)" -ForegroundColor Red }
        Write-Host "  現在の状態: .\cpu-partition.ps1 -Verify -VMName $tVm  で確認してください。" -ForegroundColor Yellow
        exit 1
    }
}

if ($Undo) {
    if (-not (Test-Admin)) { Write-Error "管理者権限の PowerShell で実行してください。"; exit 1 }

    Write-Host "CPU コア分割の設定を全て解除します。" -ForegroundColor Cyan
    if (-not $NoConfirm) {
        $ans = Read-Host "よろしいですか? (y/N)"
        if ($ans -ne "y") { exit 0 }
    }

    $cfgU = Get-SavedConfig

    # 0) 締め出しの常駐を止める (先に止めないと固定し直されてしまう)。固定していたプロセスを全コアへ戻す
    $hadWatch = [bool](Get-ScheduledTask -TaskName $WatchTaskName -ErrorAction SilentlyContinue)
    Stop-WatchTask
    if ($hadWatch) { Write-Host "  常駐 '$WatchTaskName' を停止・削除しました" -ForegroundColor Green }
    if (Get-ScheduledTask -TaskName $BootTaskName -ErrorAction SilentlyContinue) {
        Unregister-BootTask
        Write-Host "  起動タスク '$BootTaskName' を削除しました" -ForegroundColor Green
    }
    # full モードで EdgeBox の自動起動を起動タスクに任せていた場合は、元の自動起動設定に戻す
    if ($cfgU -and $cfgU.VmAutoStart -and $cfgU.VmAutoStart.Action) {
        try {
            $vmA = Get-VM -Name $VMName -ErrorAction Stop
            Set-VM -Name $VMName -AutomaticStartAction ([string]$cfgU.VmAutoStart.Action) -AutomaticStartDelay ([int]$cfgU.VmAutoStart.Delay)
            Write-Host "  EdgeBox の自動起動設定を元に戻しました ($($cfgU.VmAutoStart.Action))" -ForegroundColor Green
        } catch { }
    }
    try {
        if ($cfgU -and $cfgU.HostLps) {
            $topoU = Get-CpuTopology
            $allMaskU = Get-LpMask @(0..([Math]::Min($topoU.Lps, 63) - 1))
            $hostMaskU = Get-LpMask @([int[]]$cfgU.HostLps)
            $released = 0
            foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                if ($p.Id -le 4 -or $p.ProcessName -like 'vmmem*') { continue }
                try { if ([int64]$p.ProcessorAffinity -eq $hostMaskU) { $p.ProcessorAffinity = [IntPtr]$allMaskU; $released++ } } catch { }
            }
            if ($released -gt 0) { Write-Host "  Windows 側のプロセス $released 個のコア固定を解除しました" -ForegroundColor Green }
        }
    } catch { }

    # 1) 自動タスク
    try {
        Unregister-ScheduledTask -TaskName $PinTaskName -Confirm:$false -ErrorAction Stop
        Write-Host "  自動タスク '$PinTaskName' を削除しました" -ForegroundColor Green
    } catch { Write-Host "  自動タスク: 登録なし" }

    # 2) vmmem / vmwp のコア固定と優先度を戻す (EdgeBox 実行中のみ意味がある)
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

    # 4) 処理能力予約を戻す (EdgeBox 停止中のみ変更可能)
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ((Get-VMProcessor -VMName $VMName).Reserve -gt 0) {
            if ($vm.State -eq "Off") {
                Set-VMProcessor -VMName $VMName -Reserve 0
                Write-Host "  処理能力予約 (Reserve) を 0 に戻しました" -ForegroundColor Green
            } else {
                Write-Host "  処理能力予約 (Reserve) は EdgeBox 停止中に次で戻せます: Set-VMProcessor -VMName $VMName -Reserve 0" -ForegroundColor Yellow
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
    Write-Host "  Windows から見える論理 CPU 数: $([Environment]::ProcessorCount) / 物理には $($topo.Lps)"
    if ($cfg) {
        Write-Host "  計画: Windows = CPU $(ConvertTo-LpRangeText $planHost) / EdgeBox = CPU $(ConvertTo-LpRangeText $planGuest) ($($cfg.Mode) モード)"
    } else {
        Write-Host "  計画: 未適用 (cpu-partition.json なし)"
    }

    # ハイパーバイザーの性能カウンター (言語非依存の CIM クラス経由)
    #
    # 重要: 論理プロセッサ カウンターの PercentGuestRunTime は
    #       「EdgeBox の実行時間」ではなく「パーティションの実行時間」で、
    #       Windows 自身 (ルート パーティション) の実行も含まれる。
    #       Hyper-V を有効にした Windows は素のハードウェア上ではなく
    #       ルート パーティションとして動くため、ここを引き算しないと
    #       Windows の処理まで「EdgeBox実行」として数えてしまう。
    #
    #       LP の Guest = ルート VP (Windows) + すべての EdgeBox の VP
    #       ルート VP は論理 CPU と 1:1 で固定 (移動しない) ため、
    #       EdgeBox の実行 = LP の Guest − 同番号のルート VP の Guest で求まる。
    $lpCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorLogicalProcessor" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $lpCls) {
        Write-Host ""
        Write-Host "ハイパーバイザーの性能カウンターが見つかりません (Hyper-V 無効か、カウンター破損)。" -ForegroundColor Yellow
        Write-Host "代わりの確認手段: タスクマネージャーで vmmem の CPU 使用がEdgeBox 用コアに寄っているか (詳細タブ→列に「CPU」追加)。"
        exit 1
    }
    $rvCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorRootVirtualProcessor" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $vpCls = Get-CimClass -ClassName "Win32_PerfRawData_*HyperVHypervisorVirtualProcessor" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    # 現在のコア固定 (実測の前に「設定として何が入っているか」を示す)
    $procsNow = Get-VmProcesses $VMName
    if ($procsNow.Vmmem) {
        try {
            $pm = Get-Process -Id $procsNow.Vmmem.ProcessId -ErrorAction Stop
            $affNow = [int64]$pm.ProcessorAffinity
            $lpsNow = @(0..62 | Where-Object { ($affNow -band ([int64]1 -shl $_)) -ne 0 })
            Write-Host "  現在の固定: vmmem(PID $($pm.Id)) = CPU $(ConvertTo-LpRangeText $lpsNow)  ← OS が保証する実行可能範囲"
        } catch { }
    }

    # 自動タスクの状態。
    # LastRunTime / LastTaskResult は Get-ScheduledTask ではなく
    # Get-ScheduledTaskInfo 側にあるため、ここで一緒に出しておく
    # (Get-ScheduledTask | Select LastRunTime は常に空欄になり、
    #  「一度も実行されていない」ように見えてしまう)。
    $pinTask = Get-ScheduledTask -TaskName $PinTaskName -ErrorAction SilentlyContinue
    if ($pinTask) {
        $tinfo = $null
        try { $tinfo = Get-ScheduledTaskInfo -TaskName $PinTaskName -ErrorAction Stop } catch { }
        if ($tinfo -and $tinfo.LastRunTime -and $tinfo.LastRunTime.Year -gt 1999) {
            $rtext = if ($tinfo.LastTaskResult -eq 0) { "成功" } else { "結果コード $($tinfo.LastTaskResult)" }
            $rcol  = if ($tinfo.LastTaskResult -eq 0) { "Gray" } else { "Yellow" }
            Write-Host ("  自動タスク: {0} / 前回実行 {1} ({2})" -f `
                $pinTask.State, $tinfo.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss"), $rtext) -ForegroundColor $rcol
        } else {
            Write-Host "  自動タスク: $($pinTask.State) / まだ一度も実行されていません (再起動・ログオン・EdgeBox 起動で走ります)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  自動タスク: 未登録 — 再起動すると分割は外れます" -ForegroundColor Yellow
    }

    Write-Host "  採取中... (EdgeBox に負荷がかかっているほど分かりやすい結果になります)"

    function Get-CounterMap($ClassName) {
        # 末尾の数字をインスタンス番号として取り出す (_Total は数字で終わらないので除外)
        $map = @{}
        if (-not $ClassName) { return $map }
        foreach ($x in @(Get-CimInstance -ClassName $ClassName -ErrorAction SilentlyContinue)) {
            if ($x.Name -notmatch '(\d+)\s*$') { continue }
            $map[[int]$Matches[1]] = $x
        }
        return $map
    }
    function Get-VmVpTotals($ClassName) {
        # インスタンス名 "<登録名>:Hv VP 0" を 登録名ごとにまとめる
        $map = @{}
        if (-not $ClassName) { return $map }
        foreach ($x in @(Get-CimInstance -ClassName $ClassName -ErrorAction SilentlyContinue)) {
            $n = [string]$x.Name
            if ($n -notmatch '^(.+?):') { continue }
            $vmn = $Matches[1]
            if (-not $map.ContainsKey($vmn)) { $map[$vmn] = @() }
            $map[$vmn] += $x
        }
        return $map
    }

    $lpName = $lpCls.CimClassName
    $rvName = $null; if ($rvCls) { $rvName = $rvCls.CimClassName }
    $vpName = $null; if ($vpCls) { $vpName = $vpCls.CimClassName }

    $lp1 = Get-CounterMap $lpName
    $rv1 = Get-CounterMap $rvName
    Start-Sleep -Seconds $Seconds
    $lp2 = Get-CounterMap $lpName
    $rv2 = Get-CounterMap $rvName
    $vp2 = Get-VmVpTotals $vpName

    function Get-DeltaPct($A, $B, [string]$Prop) {
        if (-not $A -or -not $B) { return 0.0 }
        $dt = [double]($B.Timestamp_Sys100NS - $A.Timestamp_Sys100NS)
        if ($dt -le 0) { return 0.0 }
        return [Math]::Max(0, [Math]::Min(100, 100.0 * ($B.$Prop - $A.$Prop) / $dt))
    }

    $rows = @()
    foreach ($lp in @($lp2.Keys | Sort-Object)) {
        $lpGuest = Get-DeltaPct $lp1[$lp] $lp2[$lp] "PercentGuestRunTime"
        $lpTotal = Get-DeltaPct $lp1[$lp] $lp2[$lp] "PercentTotalRunTime"
        $winPct  = 0.0
        if ($rv2.ContainsKey($lp)) { $winPct = Get-DeltaPct $rv1[$lp] $rv2[$lp] "PercentGuestRunTime" }
        $vmPct = [Math]::Max(0, $lpGuest - $winPct)
        $side = ""
        if ($planGuest -contains $lp) { $side = "EdgeBox 用" }
        elseif ($planHost -contains $lp) { $side = "Windows 用" }
        $rows += [pscustomobject]@{
            LP = $lp; PlanSide = $side; VmPct = $vmPct; WinPct = $winPct
            HvPct = [Math]::Max(0, $lpTotal - $lpGuest)
        }
    }
    if ($rows.Count -eq 0) {
        Write-Host "カウンターの採取に失敗しました。" -ForegroundColor Yellow
        exit 1
    }

    if (-not $rvCls) {
        Write-Host ""
        Write-Host "注意: ルートプロセッサのカウンターが無いため、Windows 自身の実行を分離できません。" -ForegroundColor Yellow
        Write-Host "      下表の『EdgeBox 実行%』には Windows の処理も混ざります (判定は参考値)。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host ("  {0,4} {1,-10} {2,10} {3,14} {4,12}" -f "CPU", "割り当て", "EdgeBox実行%", "Windows実行%", "HV内部%")
    foreach ($r in $rows) {
        $mark = ""
        if ($r.PlanSide -eq "Windows 用" -and $r.VmPct -ge 3)  { $mark = " ← EdgeBox がはみ出している" }
        if ($r.PlanSide -eq "EdgeBox 用" -and $r.WinPct -ge 20) { $mark = " ← Windows 側の処理が多い" }
        Write-Host ("  {0,4} {1,-10} {2,10:N1} {3,14:N1} {4,12:N1}{5}" -f $r.LP, $r.PlanSide, $r.VmPct, $r.WinPct, $r.HvPct, $mark)
    }

    # 他の EdgeBox が動いていると、その実行も上の「EdgeBox 実行%」に混ざる
    $others = @($vp2.Keys | Where-Object { $_ -ne $VMName -and $_ -notmatch '^_Total' })
    if ($others.Count -gt 0) {
        Write-Host ""
        Write-Host "注意: 他にも稼働中の EdgeBox があります: $($others -join ', ')" -ForegroundColor Yellow
        Write-Host "      その分も『EdgeBox 実行%』に含まれるため、判定がぶれることがあります。" -ForegroundColor Yellow
    }

    if ($planGuest.Count -gt 0) {
        $gAll = [double](($rows | Measure-Object -Property VmPct -Sum).Sum)
        $gOn  = [double](($rows | Where-Object { $planGuest -contains $_.LP } | Measure-Object -Property VmPct -Sum).Sum)
        Write-Host ""
        if ($gAll -gt 2) {
            $pct = [Math]::Round(100.0 * $gOn / $gAll, 1)
            Write-Host "  EdgeBox の CPU 実行のうち、計画どおりEdgeBox 用コア上で実行された割合: $pct%" -ForegroundColor Cyan
            if ($pct -ge 95) { Write-Host "  → 分割は効いています。" -ForegroundColor Green }
            elseif ($pct -ge 70) { Write-Host "  → おおむね効いていますが、完全ではありません (EdgeBox 起動後に -Apply した場合は、EdgeBox を再起動すると揃います)。" -ForegroundColor Yellow }
            else { Write-Host "  → 分割が効いていません。-Apply の実行状況と、上の『現在の固定』の範囲を確認してください。" -ForegroundColor Red }
        } else {
            Write-Host "  EdgeBox の CPU 使用がほぼゼロのため判定できません (計 $([Math]::Round($gAll,1))%)。" -ForegroundColor Yellow
            Write-Host "  上の『現在の固定』が計画どおりなら、割り当て自体は OS に受理されています。" -ForegroundColor Yellow
        }
        $winTotal = [double](($rows | Measure-Object -Property WinPct -Sum).Sum)
        Write-Host "  (参考) Windows 自身の実行合計: $([Math]::Round($winTotal,1))% / EdgeBox の実行合計: $([Math]::Round($gAll,1))%"
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
    Write-Host "  スケジューラ       : $schedNow $(if ($schedNow -eq 'root') { '(クライアント既定。EdgeBox はWindows のスレッドとして実行)' })"
    if ($bcd) {
        Write-Host "  bcdedit 設定      : hypervisorschedulertype=$(if ($bcd.SchedulerType) { $bcd.SchedulerType } else { '(既定)' })  hypervisorrootproc=$(if ($bcd.RootProc) { $bcd.RootProc } else { '(既定)' })"
    } else {
        Write-Host "  bcdedit 設定      : (管理者権限がないため未取得)"
    }
    Write-Host "  Windows から見えるCPU: $([Environment]::ProcessorCount) 論理 $(if ([Environment]::ProcessorCount -lt $topo.Lps) { '← minroot が有効 (Windows封じ込め中)' })"
    if ($vm) {
        Write-Host ("  登録 '{0}'      : {1} / プロセッサ {2} / 予約 {3}%" -f $VMName, $vm.State,
            (Get-VMProcessor -VMName $VMName).Count, (Get-VMProcessor -VMName $VMName).Reserve)
        try {
            $mi0 = Get-MemoryInfo $VMName
            Write-Host ("  メモリ            : EdgeBox {0} GB{1} / この PC {2} GB (Windows 側 {3} GB)" -f $mi0.VmGB,
                $(if ($mi0.Dynamic) { " (動的)" } else { "" }), $mi0.TotalGB, [Math]::Round($mi0.TotalGB - $mi0.VmGB, 1))
        } catch { }
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
        Write-Host "  登録 '$VMName'      : (未作成)"
    }
    Write-Host "  CpuGroups.exe     : $(if ($exe) { $exe } else { '(なし。full モードの完全固定時に使用)' })"
    if ($cfg) {
        Write-Host ""
        Write-Host "  適用済みの計画    : $($cfg.Mode) モード / Windows = CPU $(ConvertTo-LpRangeText @([int[]]$cfg.HostLps)) / EdgeBox = CPU $(ConvertTo-LpRangeText @([int[]]$cfg.GuestLps))" -ForegroundColor Green
        if ($cfg.Mode -eq "runtime") { Write-Host "  Windows の締め出し : $(Get-ContainStatusText)" }
        if ($cfg.Mode -eq "full")    { Write-Host "  完全分割の状態    : $(Get-FullStatusText)" }
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
        Write-Host "  Windows : CPU $(ConvertTo-LpRangeText $plan.HostLps) ($($plan.HostLps.Count) 論理)"
        Write-Host "  EdgeBox      : CPU $(ConvertTo-LpRangeText $plan.GuestLps) ($($plan.GuestLps.Count) 論理)"
        Write-Host ""
        # 文字列の中に $( ... "..." ... ) を書くと Windows PowerShell 5.1 が解釈できないため、
        # 引数の文面は先に組み立ててから埋め込む
        $applyHint = if ($HostLps) { "-HostLps `"$HostLps`"" } else { "-HostCores $HostCores" }
        if ($GuestLps) { $applyHint += " -GuestLps `"$GuestLps`"" }
        Write-Host "  適用するには: .\cpu-partition.ps1 -Apply -Mode runtime $applyHint" -ForegroundColor Cyan
        Write-Host "    -Mode runtime : 再起動不要。EdgeBox を専用コアへ固定 (まず推奨)"
        Write-Host "    -Mode full    : 再起動 2 回で完全分割 (Windows 側もコアから締め出す)"
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
    Write-Error ("登録 '$VMName' がありません。-VMName で対象の 登録名を指定してください (一覧: Get-VM)。`n" +
        "まだ EdgeBox を作っていない場合は -AllowMissingVM を付けると、計画だけ保存して EdgeBox の作成・起動後に自動適用します。")
    exit 1
}
if (-not $vm) {
    Write-Host "登録 '$VMName' は未作成です。計画を保存し、EdgeBox を作成・起動した時点で自動適用します。" -ForegroundColor Yellow
}

# 適用のたびに指定がなければ、保存済み計画を引き継ぐ (full の 2 段階目で同じ指定を省略可能に)
if ($HostCores -eq 0 -and $HostLps -eq "" -and $cfg -and $cfg.Mode -eq $Mode) {
    $HostLps  = ConvertTo-LpRangeText @([int[]]$cfg.HostLps)
    $GuestLps = ConvertTo-LpRangeText @([int[]]$cfg.GuestLps)
    Say "保存済みの計画を使用します (Windows = $HostLps / EdgeBox = $GuestLps)" "Cyan"
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
Write-Host "  Windows : CPU $hostText ($($plan.HostLps.Count) 論理)"
Write-Host "  EdgeBox      : CPU $guestText ($($plan.GuestLps.Count) 論理)"

# vCPU 数とEdgeBox 用コア数の一致を確認 (1 論理 CPU = 1 プロセッサが理想形)
$vcpu = 0
if ($vm) { $vcpu = [int](Get-VMProcessor -VMName $VMName).Count }
if ($vm -and $vcpu -ne $plan.GuestLps.Count) {
    if ($vm.State -eq "Off") {
        Write-Host "  プロセッサ数を $vcpu → $($plan.GuestLps.Count) に合わせます (1 コア = 1 プロセッサが理想のため)" -ForegroundColor Cyan
        Set-VMProcessor -VMName $VMName -Count $plan.GuestLps.Count
    } else {
        Write-Host "  注意: プロセッサ数 ($vcpu) がEdgeBox 用論理 CPU 数 ($($plan.GuestLps.Count)) と不一致です。" -ForegroundColor Yellow
        Write-Host "        EdgeBox 停止中に再度 -Apply すると自動調整します (ずれたままでも動きますが理想は 1:1)。" -ForegroundColor Yellow
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
        HostContain = (-not $NoContain)   # Windows 側のプロセスを Windows 用コアへ締め出す常駐を使う
        PendingVM = (-not $vm)     # EdgeBox 未作成のまま保存した計画かどうか
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
    Write-PinLog "Apply(runtime): Windows=$hostText EdgeBox=$guestText contain=$(-not $NoContain)"

    $taskNote = Register-PinTask
    Write-Host "  EdgeBox 起動時に自動で固定し直すタスク '$PinTaskName' を登録しました" -ForegroundColor Green
    if ($taskNote) { Write-Host "  ($taskNote)" -ForegroundColor Yellow }

    if ($NoContain) {
        Stop-WatchTask
        Write-Host "  Windows 側の締め出し (常駐) は使いません (-NoContain)" -ForegroundColor Yellow
    } else {
        # 設定が変わった場合に備えて常駐は作り直す (古い常駐は設定を 30 秒ごとに読み直すが、確実に)
        Stop-WatchTask
        Register-WatchTask
        Start-WatchTask | Out-Null
        Write-Host "  Windows 側のプロセスを CPU $hostText へ締め出す常駐 '$WatchTaskName' を登録して起動しました" -ForegroundColor Green
    }

    if ($vm -and $vm.State -eq "Running") {
        $msg = Set-RuntimePin $plan.HostLps $plan.GuestLps (-not $NoPriorityBoost)
        Write-PinLog "Apply(runtime) 即時適用: $msg"
        if ($msg -like "ok:*") { Write-Host "  即時適用: $($msg.Substring(4))" -ForegroundColor Green }
        else { Write-Host "  即時適用: $msg" -ForegroundColor Yellow }
    } elseif ($vm) {
        Write-Host "  EdgeBox は停止中です。次回起動時に自動タスクが適用します。"
    } else {
        Write-Host "  EdgeBox が未作成のため、作成して起動した時点で自動タスクが適用します。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "適用しました (runtime モード)。" -ForegroundColor Green
    Write-Host "  - $VMName の CPU 実行は CPU $guestText に物理固定されました"
    if ($NoContain) {
        Write-Host "  - Windows 側の処理は優先度で押し出されます (締め出しは -NoContain を外すか、完全分割は -Mode full)"
    } else {
        Write-Host "  - Windows 側のプロセスは常駐が 3 秒ごとに CPU $hostText へ固定し直します (新しいプロセスも数秒で戻る)"
        Write-Host "  - 残るのは固定できない保護プロセスとカーネル・割り込みの分だけ (通常 1% 未満)。それも無くすには -Mode full"
    }
    Write-Host "  - 効き具合の実測: .\cpu-partition.ps1 -Verify  / 常時の確認: 『EdgeBox 監視』の「分離の状態」" -ForegroundColor Cyan
    exit 0
}

# ======================== full モード ========================
$wantRootProc = $plan.HostLps.Count
if (-not $bcd) { $bcd = Get-BcdHvSettings }
$bcdReady = ($bcd.SchedulerType -eq $Scheduler) -and ($bcd.RootProc -eq $wantRootProc)

if (-not $bcdReady) {
    # ---- 第 1 段階: ハイパーバイザー設定の書き込み (要再起動)。再起動後は起動タスクが残りを自動で行う ----
    Write-Host ""
    Write-Host "【第 1 段階】ハイパーバイザー設定を書き込みます (反映には再起動が必要):" -ForegroundColor Cyan
    Write-Host "    bcdedit /set hypervisorschedulertype $Scheduler"
    Write-Host "    bcdedit /set hypervisorrootproc $wantRootProc   (Windows を先頭 $wantRootProc 論理 CPU に封じ込め)"
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

    # CpuGroups.exe は再起動前に用意しておく (起動直後はネットワークが無いことがある)
    if (-not $exe) {
        $get = [bool]$AutoGetTools
        if (-not $get -and -not $NoConfirm) {
            Write-Host "EdgeBox 側の完全固定には Microsoft 製 CpuGroups.exe が必要です (未検出)。" -ForegroundColor Yellow
            $get = ((Read-Host "Microsoft Download Center から取得しますか? (y/N)") -eq "y")
        }
        if ($get) {
            $exe = Get-CpuGroupsExe
            if ($exe) { Write-Host "  CpuGroups.exe を取得しました: $exe" -ForegroundColor Green }
            else { Write-Host "  CpuGroups.exe を取得できませんでした。手動で入手する場合: $CpuGroupsUrl をブラウザで開き、tools\ に置いてください。" -ForegroundColor Yellow }
        }
    }

    Invoke-Bcdedit @("/set", "hypervisorschedulertype", $Scheduler)
    Invoke-Bcdedit @("/set", "hypervisorrootproc", "$wantRootProc")

    # EdgeBox の自動起動は起動タスクに任せる (CPU グループに固定してから起動するため)。元の設定は控えて -Undo で戻す
    $auto = $null
    if ($vm) {
        try {
            $auto = @{ Action = [string]$vm.AutomaticStartAction; Delay = [int]$vm.AutomaticStartDelay }
            Set-VM -Name $VMName -AutomaticStartAction Nothing
            Write-Host "  EdgeBox の自動起動は起動タスク '$BootTaskName' が行います (固定してから起動)" -ForegroundColor Green
        } catch { $auto = $null }
    }

    Save-Config ([pscustomobject]@{
        Mode = "full"; VMName = $VMName
        HostLps = $plan.HostLps; GuestLps = $plan.GuestLps
        Scheduler = $Scheduler; NoPriorityBoost = $false
        VmAutoStart = $auto; ManageVmStart = [bool]$auto
        PendingReboot = $true; GroupBound = $false
        PendingVM = (-not $vm)
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
    Write-PinLog "Apply(full) 第1段階: sched=$Scheduler rootproc=$wantRootProc"

    # runtime 用の自動タスク・常駐は外し、full 用の起動タスクを登録する
    try { Unregister-ScheduledTask -TaskName $PinTaskName -Confirm:$false -ErrorAction Stop } catch { }
    Stop-WatchTask
    Register-BootTask
    Write-FullStatus @{ MinrootOk = $false; Bound = $false; Message = "再起動待ち (再起動後に起動タスクが CPU グループを作成します)"; HostLps = $hostText; GuestLps = $guestText }
    Write-Host "  起動タスク '$BootTaskName' を登録しました (再起動後、EdgeBox の固定まで自動で完了します)" -ForegroundColor Green

    Write-Host ""
    Write-Host "書き込みました。PC を再起動してください。再起動後は自動で完了します。" -ForegroundColor Green
    Write-Host "  成立の確認: .\cpu-partition.ps1 (現状表示) または『EdgeBox 監視』の「分離の状態」" -ForegroundColor Cyan
    exit 0
}

# ---- 第 2 段階: 再起動後の確認と EdgeBox のコア固定 (起動タスクと同じ処理を手動で行う) ----
Write-Host ""
Write-Host "【第 2 段階】再起動後の反映確認と EdgeBox のコア固定を行います。" -ForegroundColor Cyan
Register-BootTask   # 旧版で登録されていない場合に備えて (再登録は無害)
$bound = Invoke-FullStage2 $plan.HostLps $plan.GuestLps $true
$cfgF = Get-SavedConfig
if (-not $cfgF -or $cfgF.Mode -ne "full") {
    Save-Config ([pscustomobject]@{
        Mode = "full"; VMName = $VMName
        HostLps = $plan.HostLps; GuestLps = $plan.GuestLps
        Scheduler = $Scheduler; GroupBound = $bound; NoPriorityBoost = $false
        PendingVM = (-not $vm); PendingReboot = $false
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    })
}
Write-PinLog "Apply(full) 第2段階: groupBound=$bound"

Write-Host ""
if ($bound) {
    Write-Host "完全分割が成立しました (Linux 主構成の isolcpus + vcpupin 相当)。" -ForegroundColor Green
    Write-Host "  - Windows : CPU $hostText から出られません (minroot)"
    Write-Host "  - EdgeBox      : CPU $guestText から出られません (CPU グループ。起動のたびに '$BootTaskName' が作り直します)"
} else {
    Write-Host "準分割で適用しました。" -ForegroundColor Yellow
    Write-Host "  - Windows : CPU $hostText から出られません (minroot) ← ここは完全"
    Write-Host "  - EdgeBox      : 空いている CPU $guestText 上でほぼ実行されます (ハイパーバイザー任せ + 予約で保証)"
    Write-Host "  - 起動タスク '$BootTaskName' が 5 分ごとに固定を試し直します。EdgeBox 停止中に効くこともあります"
}
Write-Host ""
Write-Host "確認: 『EdgeBox 監視』の「分離の状態」、または .\cpu-partition.ps1 -Verify" -ForegroundColor Cyan
