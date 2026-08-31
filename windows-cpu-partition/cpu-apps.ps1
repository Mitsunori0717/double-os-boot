<#
.SYNOPSIS
    Windows 側のアプリを、指定した CPU コアに固定します (アプリ単位のピンニング)。

.DESCRIPTION
    cpu-apps.json に登録したアプリを、起動のたびに指定コアへ固定し直します。
    VM のコア分割 (cpu-partition.ps1) とは独立して動き、対象は Windows 側のアプリだけです。

      - 割り当て: 選んだ論理 CPU にプロセスを固定 (プロセッサ アフィニティ)
      - 優先度  : 通常 / 高 / 低 を指定可能 (取り合いになったときの順番)
      - 自動化  : タスク 'CpuPartition-Apps' が一定間隔で登録内容を適用し直すため、
                  アプリを起動し直しても効き続けます

    登録・編集は設定コンソール (cpu-console.ps1) の『アプリの割り当て』から行います。

.EXAMPLE
    .\cpu-apps.ps1 -Show                 # 登録内容と現在の状態を表示
    .\cpu-apps.ps1 -Apply                # 今すぐ適用
    .\cpu-apps.ps1 -Install              # 自動適用タスクを登録 (既定 1 分間隔)
    .\cpu-apps.ps1 -Uninstall            # 自動適用を解除し、固定も外す

.NOTES
    管理者権限で実行してください (他ユーザー・昇格されたアプリにも適用するため)。
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Show,
    [int]$IntervalMinutes = 1,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$AppsFile = Join-Path $PSScriptRoot "cpu-apps.json"
$LogFile  = Join-Path $PSScriptRoot "cpu-apps-log.txt"
$TaskName = "CpuPartition-Apps"

function Write-AppLog([string]$Text) {
    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text)
        $lines = @(Get-Content $LogFile -Encoding UTF8)
        if ($lines.Count -gt 400) { $lines | Select-Object -Last 200 | Set-Content -Path $LogFile -Encoding UTF8 }
    } catch { }
}

function Say([string]$Text, [string]$Color = "Gray") {
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Get-Apps {
    if (-not (Test-Path $AppsFile)) { return @() }
    try {
        $raw = Get-Content $AppsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($raw)
    } catch { return @() }
}

function ConvertTo-LpRangeText([int[]]$Lps) {
    if (-not $Lps -or $Lps.Count -eq 0) { return "(なし)" }
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

function Get-LpMask([int[]]$Lps) {
    $mask = [int64]0
    foreach ($i in $Lps) {
        if ($i -ge 63) { continue }   # 論理 CPU 63 以上は対象外 (アフィニティの表現上の制限)
        $mask = $mask -bor ([int64]1 -shl $i)
    }
    return $mask
}

function Resolve-Priority([string]$Name) {
    switch ($Name) {
        "高"   { return [System.Diagnostics.ProcessPriorityClass]::High }
        "High" { return [System.Diagnostics.ProcessPriorityClass]::High }
        "低"   { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        "Low"  { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        "BelowNormal" { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        default { return [System.Diagnostics.ProcessPriorityClass]::Normal }
    }
}

# 登録されたアプリに対応する実行中プロセスを探す
function Get-MatchingProcesses($App) {
    $name = [string]$App.Match
    if (-not $name) { return @() }
    $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    $exe = [string]$App.Exe
    if ($exe) {
        # 同名の別アプリを巻き込まないよう、パスが取れるものはパスで絞り込む
        $filtered = @()
        foreach ($p in $procs) {
            $path = $null
            try { $path = $p.Path } catch { $path = $null }
            if (-not $path -or $path -eq $exe) { $filtered += $p }
        }
        return $filtered
    }
    return $procs
}

# ============================================================ 表示

if ($Show) {
    $apps = Get-Apps
    Write-Host ""
    Write-Host "=== アプリのコア割り当て ===" -ForegroundColor Cyan
    if ($apps.Count -eq 0) {
        Write-Host "  登録なし (設定コンソールの『アプリの割り当て』から追加できます)"
    }
    foreach ($a in $apps) {
        $lps = @([int[]]$a.Lps)
        $procs = Get-MatchingProcesses $a
        $state = if ($procs.Count -eq 0) { "未起動" } else { "$($procs.Count) 個 実行中" }
        Write-Host ("  {0,-24} CPU {1,-12} 優先度 {2,-6} [{3}]" -f $a.Name, (ConvertTo-LpRangeText $lps), $a.Priority, $state)
        foreach ($p in $procs) {
            $aff = 0
            try { $aff = [int64]$p.ProcessorAffinity } catch { }
            $cur = @(0..62 | Where-Object { ($aff -band ([int64]1 -shl $_)) -ne 0 })
            Write-Host ("      PID {0,-6} 現在の固定: CPU {1}" -f $p.Id, (ConvertTo-LpRangeText $cur))
        }
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  自動適用タスク: $(if ($task) { '登録済み (' + $task.State + ')' } else { '未登録' })"
    exit 0
}

# ============================================================ 解除

if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Say "自動適用タスク '$TaskName' を削除しました。" "Green"
    } catch { Say "自動適用タスク: 登録なし" }

    # 固定を外す (全 CPU を使える状態に戻す)
    $total = [Environment]::ProcessorCount
    $allMask = Get-LpMask @(0..([Math]::Min($total, 63) - 1))
    foreach ($a in (Get-Apps)) {
        foreach ($p in (Get-MatchingProcesses $a)) {
            try {
                $p.ProcessorAffinity = [IntPtr]$allMask
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
                Say "  $($a.Name) (PID $($p.Id)) の固定を解除しました" "Green"
            } catch { }
        }
    }
    Write-AppLog "Uninstall: タスク削除と固定解除"
    Say "解除しました (登録内容 cpu-apps.json は残しています)。" "Green"
    exit 0
}

# ============================================================ 自動適用タスクの登録

if ($Install) {
    $interval = [Math]::Max(1, $IntervalMinutes)
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply -Quiet"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # 繰り返し設定 (環境によっては MaxValue が拒否されるため、その場合は十分長い期間で代用)
    try {
        $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $interval) `
            -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
    } catch {
        $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $interval) `
            -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition
    }
    $trigger.Repetition = $rep
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $bootTrigger.Delay = "PT1M"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Trigger @($trigger, $bootTrigger) `
        -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Say "自動適用タスク '$TaskName' を登録しました ($interval 分ごとに適用し直します)。" "Green"
    if (-not $Apply) { exit 0 }
}

# ============================================================ 適用

$apps = Get-Apps
if ($apps.Count -eq 0) {
    Write-AppLog "Apply: 登録なし"
    Say "登録されたアプリがありません。"
    exit 0
}

$done = 0; $miss = 0; $fail = @()
foreach ($a in $apps) {
    $lps = @([int[]]$a.Lps)
    if ($lps.Count -eq 0) { continue }
    $mask = Get-LpMask $lps
    if ($mask -eq 0) { continue }
    $pri = Resolve-Priority ([string]$a.Priority)
    $procs = Get-MatchingProcesses $a
    if ($procs.Count -eq 0) { $miss++; continue }
    foreach ($p in $procs) {
        try {
            if ([int64]$p.ProcessorAffinity -ne $mask) { $p.ProcessorAffinity = [IntPtr]$mask }
            if ($p.PriorityClass -ne $pri) { $p.PriorityClass = $pri }
            $done++
            Say "  $($a.Name) (PID $($p.Id)) → CPU $(ConvertTo-LpRangeText $lps) / 優先度 $($a.Priority)" "Green"
        } catch {
            $fail += "$($a.Name) (PID $($p.Id)): $($_.Exception.Message)"
        }
    }
}

$summary = "Apply: 固定 $done 件 / 未起動 $miss 件 / 失敗 $($fail.Count) 件"
Write-AppLog $summary
foreach ($f in $fail) { Write-AppLog "  失敗: $f" }
Say $summary
if ($fail.Count -gt 0 -and -not $Quiet) {
    Write-Host "失敗した項目 (保護されたプロセスなどは固定できません):" -ForegroundColor Yellow
    foreach ($f in $fail) { Write-Host "  $f" -ForegroundColor Yellow }
}
exit 0
