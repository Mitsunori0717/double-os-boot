<#
.SYNOPSIS
    EdgeBox のメモリが足りているかを測り、適切な割り当て量を決めます。

.DESCRIPTION
    今の EdgeBox はメモリを「固定」で使っているため、外からは
    「何 GB 渡したか」しか分かりません。中でどれだけ使っているかは見えません。

    そこで、いったん「動的メモリ」に切り替えて測ります。動的メモリにすると
    Hyper-V が EdgeBox 自身から次の値を受け取れるようになります。

      要求 (Demand)   : EdgeBox が今ほしがっている量
      圧力 (Pressure) : 要求 ÷ 渡している量。100% に近いほど足りていない
      内部の空き      : EdgeBox の中から見た空き容量

    測り終えたら、分かった量に基づいて固定に戻します。
    測定中も下限は今と同じなので、**今より減ることはありません**。

    流れ:
      1. .\13-edgebox-memory.ps1 -Measure        測定を始める (動的メモリへ)
      2. 1 週間ほど普段どおり使う                 5 分ごとに自動で記録します
      3. .\13-edgebox-memory.ps1 -Report         結果と、おすすめの割り当て量
      4. .\13-edgebox-memory.ps1 -Fix -GB 12     決めた量で固定に戻す

.EXAMPLE
    .\13-edgebox-memory.ps1                  # 今の状態 (測定できるかどうかも表示)
    .\13-edgebox-memory.ps1 -Measure         # 測定開始 (上限は既定で 16 GB)
    .\13-edgebox-memory.ps1 -Measure -MaxGB 24
    .\13-edgebox-memory.ps1 -Report
    .\13-edgebox-memory.ps1 -Fix -GB 12      # 固定に戻す

.NOTES
    - 管理者権限が必要です。
    - メモリの変更は EdgeBox の停止中にしかできません。動作中に指示した場合は、
      次に EdgeBox が止まったとき (『全部シャットダウン』など) に自動で反映します。
    - 測定中はメモリが動的になるため、LAN の直結 (SR-IOV) のメモリ固定は外れます。
      測定を終えて -Fix したあと、.\11-io-passthrough.ps1 -Apply をやり直してください。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Measure,
    [switch]$Report,
    [switch]$Fix,
    [int]$GB = 0,
    [int]$MaxGB = 16,
    [switch]$Log,             # (内部用) 1 回分の記録。予約タスクから呼ばれる
    [switch]$ApplyPending,    # (内部用) 予約を反映する。停止中のときだけ何かをする
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$CsvFile     = Join-Path $PSScriptRoot "edgebox-memory.csv"
$PendingFile = Join-Path $PSScriptRoot "memory-pending.json"
$TaskName    = "EdgeBox-Memory-Log"

# -VMName を明示していない場合、既定名が無ければ EdgeBox のディスクを持つものを探す
if (-not $PSBoundParameters.ContainsKey("VMName") -and
    -not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    $found = @()
    foreach ($v in @(Get-VM -ErrorAction SilentlyContinue)) {
        $pt = @(Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.DiskNumber })
        if ($pt.Count -gt 0) { $found += $v }
    }
    if ($found.Count -eq 1) { $VMName = $found[0].Name }
}

function Say([string]$t, [string]$c = "Gray") { if (-not $Quiet) { Write-Host $t -ForegroundColor $c } }

# 動的メモリの詳しい値を持つ CIM クラス (版によって名前が違う)
$script:DmClass = $null
foreach ($n in "Msvm_MemoryState", "Msvm_DynamicMemoryVM") {
    $c = Get-CimClass -Namespace root\virtualization\v2 -ClassName $n -ErrorAction SilentlyContinue
    if ($c) { $script:DmClass = $n; break }
}

function Get-MemorySnapshot {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $o = [ordered]@{
        時刻         = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        状態         = [string]$vm.State
        動的         = [bool]$vm.DynamicMemoryEnabled
        割り当てGB   = [Math]::Round([double]$vm.MemoryAssigned / 1GB, 2)
        要求GB       = [Math]::Round([double]$vm.MemoryDemand / 1GB, 2)
        圧力         = 0.0
        内部の空きGB = 0.0
        メモリ状態   = [string]$vm.MemoryStatus
    }
    if ($script:DmClass) {
        foreach ($d in @(Get-CimInstance -Namespace root\virtualization\v2 -ClassName $script:DmClass -ErrorAction SilentlyContinue)) {
            if ([string]$d.Name -ne $VMName -and [string]$d.ElementName -ne $VMName) { continue }
            if ($d.PSObject.Properties["CurrentPressure"])       { $o.圧力 = [double]$d.CurrentPressure }
            if ($d.PSObject.Properties["GuestAvailableMemory"])  { $o.内部の空きGB = [Math]::Round([double]$d.GuestAvailableMemory / 1024.0, 2) }
        }
    }
    if ($o.圧力 -le 0 -and $o.割り当てGB -gt 0 -and $o.要求GB -gt 0) {
        $o.圧力 = [Math]::Round(100.0 * $o.要求GB / $o.割り当てGB, 0)
    }
    return [pscustomobject]$o
}

# ============================================================
#  記録 (予約タスクから 5 分ごとに呼ばれる)
# ============================================================
if ($Log) {
    try {
        $s = Get-MemorySnapshot
        if ($s.状態 -eq "Running") {
            if (-not (Test-Path $CsvFile)) { $s | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8 }
            else { $s | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8 -Append }
        }
    } catch { }
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
#  予約の反映 (停止中のときだけ。05 のシャットダウンから呼ばれる)
# ============================================================
if ($ApplyPending) {
    if (-not (Test-Path $PendingFile)) { exit 0 }
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        if ($vm.State -ne "Off") { exit 0 }
        $p = Get-Content $PendingFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($p.Mode -eq "dynamic") {
            Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true `
                -MinimumBytes ([int64]$p.MinGB * 1GB) `
                -StartupBytes ([int64]$p.MinGB * 1GB) `
                -MaximumBytes ([int64]$p.MaxGB * 1GB)
            Say "予約していたメモリの測定設定を反映しました (下限 $($p.MinGB) GB / 上限 $($p.MaxGB) GB)。" "Green"
        } else {
            Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$p.GB * 1GB)
            Say "予約していたメモリの固定を反映しました ($($p.GB) GB)。" "Green"
        }
        Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue
    } catch { }
    exit 0
}

# ============================================================
#  結果のまとめ
# ============================================================
if ($Report) {
    if (-not (Test-Path $CsvFile)) {
        Write-Host "まだ記録がありません。先に測定を始めてください:" -ForegroundColor Yellow
        Write-Host "  .\13-edgebox-memory.ps1 -Measure"
        exit 1
    }
    $rows = @(Import-Csv $CsvFile -Encoding UTF8 | Where-Object { [double]$_.要求GB -gt 0 })
    if ($rows.Count -eq 0) {
        Write-Host "記録はありますが、EdgeBox からの報告がありません。" -ForegroundColor Yellow
        Write-Host "  EdgeBox の OS が Hyper-V への報告に対応していない可能性があります。"
        Write-Host "  この場合、中のメモリ使用量を外から知ることはできません。"
        Write-Host "  『EdgeBox 監視』のディスク動作 (退避が起きると読み書きが増える) で間接的に見るか、"
        Write-Host "  余裕をみて割り当てを増やす判断になります。"
        exit 1
    }
    $dem = @($rows | ForEach-Object { [double]$_.要求GB })
    $asg = @($rows | ForEach-Object { [double]$_.割り当てGB })
    $prs = @($rows | ForEach-Object { [double]$_.圧力 })
    $maxDem = ($dem | Measure-Object -Maximum).Maximum
    $avgDem = [Math]::Round((($dem | Measure-Object -Average).Average), 2)
    $maxPrs = ($prs | Measure-Object -Maximum).Maximum
    $span = "{0} 〜 {1}" -f $rows[0].時刻, $rows[-1].時刻
    $days = [Math]::Round(((Get-Date $rows[-1].時刻) - (Get-Date $rows[0].時刻)).TotalDays, 1)

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " EdgeBox のメモリ測定結果"
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "期間     : $span  ($days 日 / $($rows.Count) 回の記録)"
    Write-Host ""
    Write-Host ("いちばん多く要求した量 : {0:N1} GB" -f $maxDem)
    Write-Host ("ふだん要求している量   : {0:N1} GB" -f $avgDem)
    Write-Host ("いちばん高かった圧力   : {0:N0} %" -f $maxPrs)
    Write-Host ("渡していた量           : {0:N1} GB" -f (($asg | Measure-Object -Maximum).Maximum))
    Write-Host ""

    # おすすめ: 最大要求の 1.3 倍を 2 GB 単位に切り上げ (最低 4 GB)
    $rec = [Math]::Max(4, [Math]::Ceiling(($maxDem * 1.3) / 2) * 2)
    if ($maxPrs -ge 90) {
        Write-Host "判定: 足りていません。圧力が 90% を超えた時間があります。" -ForegroundColor Red
    } elseif ($maxPrs -ge 75) {
        Write-Host "判定: 余裕が少ないです。増やしておくことをおすすめします。" -ForegroundColor Yellow
    } else {
        Write-Host "判定: 足りています。" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host ("おすすめの割り当て: {0} GB  (いちばん多く要求した量の 1.3 倍)" -f $rec) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "この量で固定に戻すには:"
    Write-Host "  .\13-edgebox-memory.ps1 -Fix -GB $rec" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "記録の実体: $CsvFile"
    exit 0
}

# ============================================================
#  測定を始める / 固定に戻す
# ============================================================
if ($Measure -or $Fix) {
    if (-not $isAdmin) {
        Write-Error "管理者権限で実行してください (スタートボタンを右クリック →『ターミナル (管理者)』)。"
        exit 1
    }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Error "EdgeBox '$VMName' が見つかりません。"; exit 1 }
    $mem = Get-VMMemory -VMName $VMName
    $curGB = [int][Math]::Round([double]$mem.Startup / 1GB)

    if ($Measure) {
        $minGB = $curGB
        if ($MaxGB -le $minGB) { $MaxGB = $minGB * 2 }
        $plan = @{ Mode = "dynamic"; MinGB = $minGB; MaxGB = $MaxGB }
        $desc = "測定のため動的メモリにします (下限 $minGB GB = 今と同じ / 上限 $MaxGB GB)"
    } else {
        if ($GB -le 0) { Write-Error "固定する量を指定してください (例: -Fix -GB 12)。"; exit 1 }
        $plan = @{ Mode = "static"; GB = $GB }
        $desc = "メモリを $GB GB で固定します"
    }

    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " $desc"
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "今の設定: $(if ($mem.DynamicMemoryEnabled) { "動的 (下限 $([int]($mem.Minimum/1GB)) GB / 上限 $([int]($mem.Maximum/1GB)) GB)" } else { "固定 $curGB GB" })"
    Write-Host ""

    if ($vm.State -eq "Off") {
        if ($plan.Mode -eq "dynamic") {
            Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true `
                -MinimumBytes ([int64]$plan.MinGB * 1GB) `
                -StartupBytes ([int64]$plan.MinGB * 1GB) `
                -MaximumBytes ([int64]$plan.MaxGB * 1GB)
        } else {
            Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$plan.GB * 1GB)
        }
        Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue
        Write-Host "反映しました。次に EdgeBox を起動したときから有効です。" -ForegroundColor Green
    } else {
        $plan | ConvertTo-Json | Set-Content -Path $PendingFile -Encoding UTF8
        Write-Host "EdgeBox が動作中のため、今は変更できません (メモリの変更は停止中のみ)。" -ForegroundColor Yellow
        Write-Host "予約しました。次に EdgeBox が止まったとき (『全部シャットダウン』など) に自動で反映します。" -ForegroundColor Green
        Write-Host "  すぐ反映したい場合: デスクトップの『EdgeBox 再起動』" -ForegroundColor Cyan
    }

    # 記録タスクの登録 / 解除
    if ($Measure) {
        $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Log -VMName `"$VMName`""
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
        $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::FromDays(3650))
        $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $pr = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trg `
            -Settings $ts -Principal $pr -Force | Out-Null
        Write-Host ""
        Write-Host "5 分ごとに記録します。1 週間ほど普段どおり使ってから、結果を見てください:" -ForegroundColor Cyan
        Write-Host "  .\13-edgebox-memory.ps1 -Report" -ForegroundColor Yellow
    } else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host "測定の記録を止めました。" -ForegroundColor Green
        Write-Host "LAN の直結 (SR-IOV) を使っている場合は、固定に戻したあとやり直してください:" -ForegroundColor Yellow
        Write-Host "  .\11-io-passthrough.ps1 -Apply"
    }
    exit 0
}

# ============================================================
#  今の状態 (引数なし)
# ============================================================
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Error "EdgeBox '$VMName' が見つかりません。"; exit 1 }
$mem = Get-VMMemory -VMName $VMName
$s = Get-MemorySnapshot

Write-Host ""
Write-Host "EdgeBox: $VMName  ($($s.状態))"
Write-Host ""
if ($mem.DynamicMemoryEnabled) {
    Write-Host ("メモリ: 動的  下限 {0} GB / 上限 {1} GB" -f [int]($mem.Minimum/1GB), [int]($mem.Maximum/1GB))
} else {
    Write-Host ("メモリ: 固定  {0} GB" -f [int]($mem.Startup/1GB))
}
Write-Host ("  今 渡している量 : {0:N1} GB" -f $s.割り当てGB)

if ($s.要求GB -gt 0) {
    Write-Host ("  EdgeBox の要求  : {0:N1} GB" -f $s.要求GB)
    Write-Host ("  圧力            : {0:N0} %  ({1})" -f $s.圧力, $(
        if ($s.圧力 -ge 90) { "足りていません" } elseif ($s.圧力 -ge 75) { "余裕が少ない" } else { "足りています" }))
    if ($s.内部の空きGB -gt 0) { Write-Host ("  内部の空き      : {0:N1} GB" -f $s.内部の空きGB) }
    Write-Host ""
    Write-Host "測定できています。" -ForegroundColor Green
    if (Test-Path $CsvFile) { Write-Host "  結果のまとめ: .\13-edgebox-memory.ps1 -Report" }
} else {
    Write-Host ""
    Write-Host "中でどれだけ使っているかは、今は分かりません。" -ForegroundColor Yellow
    Write-Host "  メモリが『固定』のため、Hyper-V が EdgeBox から報告を受け取れないためです。"
    Write-Host ""
    Write-Host "測定を始めるには (今より減ることはありません):" -ForegroundColor Cyan
    Write-Host "  .\13-edgebox-memory.ps1 -Measure" -ForegroundColor Yellow
}
if (Test-Path $PendingFile) {
    Write-Host ""
    Write-Host "予約あり: 次に EdgeBox が止まったときに反映します。" -ForegroundColor Cyan
}
Write-Host ""
