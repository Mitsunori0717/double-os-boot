<#
.SYNOPSIS
    EdgeBox VM を起動し、コンソール画面を開きます。

.EXAMPLE
    .\02-start-field-vm.ps1              # 起動 + コンソール表示
    .\02-start-field-vm.ps1 -Stop       # 通常シャットダウン要求
    .\02-start-field-vm.ps1 -Status     # 状態表示
    .\02-start-field-vm.ps1 -Repair     # ディスクの取り合いを診断して直せる範囲を直す
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Stop,
    [switch]$Status,
    # ディスクが「別のプロセスが使用中」で起動できないときの自動修復
    # (重複した接続の削除 / ディスクのオフライン化。他 VM の設定には触れない)
    [switch]$Repair,

    # -Repair と併用。同じディスクを掴んでいる他の VM から、その接続だけを外す
    # (VM 自体もディスクの中身も消しません。対象 VM が停止中のときのみ実行)
    [switch]$DetachOthers
)

$ErrorActionPreference = "Stop"

# -VMName を明示していない場合、既定名の VM が無ければ、EdgeBox のディスク
# (物理ディスクのパススルー) を持つ VM を探して使う。00-field-launcher.ps1 と
# 同じ考え方で、VM 名が「EdgeBox」でなくても (旧名称のままでも) そのまま動くようにする
if (-not $PSBoundParameters.ContainsKey("VMName") -and
    -not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    $foundVms = @()
    foreach ($v in @(Get-VM -ErrorAction SilentlyContinue)) {
        $pt = @(Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.DiskNumber })
        if ($pt.Count -gt 0) { $foundVms += $v }
    }
    if ($foundVms.Count -eq 1) { $VMName = $foundVms[0].Name }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Hyper-V の操作とディスクのオフライン化には管理者権限が要る。
# 無いまま進むと途中で分かりにくいエラーになるため先に止める
if (-not (Test-Admin)) {
    Write-Error ("管理者権限の PowerShell で実行してください。`n" +
        "field-start.cmd をダブルクリックすれば自動で昇格します。")
    exit 1
}

# Windows のシステムディスク (C:)。ディスクをオフラインにする前の安全確認に使う
$SysDisk = -1
try { $SysDisk = [int](Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber } catch { $SysDisk = -1 }

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Error "VM '$VMName' がありません。01-create-field-vm.ps1 で作成してください。"
    exit 1
}

if ($Status) {
    $vm | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime
    exit 0
}

if ($Stop) {
    if ($vm.State -eq "Running") {
        Stop-VM -Name $VMName   # ACPI シャットダウン要求 (EdgeBox 側が正常終了処理を行う)
        Write-Host "シャットダウンを要求しました。"
    } else {
        Write-Host "VM は起動していません ($($vm.State))。"
    }
    exit 0
}

# ============================================================
#  物理ディスクの取り合いを調べる
#  (パススルー ディスクは「Windows からオフライン」かつ「1 つの VM だけが接続」
#   でないと開けず、Start-VM が 0x80070020 で失敗する)
# ============================================================
function Get-PassthroughDisks([string]$Name) {
    @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.DiskNumber })
}

function Test-DiskReady([switch]$Fix) {
    $problems = @()
    $mine = Get-PassthroughDisks $VMName
    if ($mine.Count -eq 0) { return $problems }   # 仮想ディスク運用なら対象外

    # 1) 同じディスクを二重に接続していないか (作成をやり直したときに起きやすい)
    foreach ($g in ($mine | Group-Object DiskNumber)) {
        if ($g.Count -le 1) { continue }
        $problems += "ディスク $($g.Name) が $($g.Count) 回接続されています (二重接続)"
        if ($Fix) {
            foreach ($extra in @($g.Group | Select-Object -Skip 1)) {
                Remove-VMHardDiskDrive -VMName $VMName `
                    -ControllerType $extra.ControllerType `
                    -ControllerNumber $extra.ControllerNumber `
                    -ControllerLocation $extra.ControllerLocation
                Write-Host "  余分な接続を外しました (ディスク $($g.Name))" -ForegroundColor Green
            }
        }
    }

    $diskNums = @($mine | Select-Object -ExpandProperty DiskNumber -Unique)

    # 2) 他の VM が同じ物理ディスクを掴んでいないか (旧構成の VM が残っている等)
    foreach ($other in @(Get-VM | Where-Object { $_.Name -ne $VMName })) {
        foreach ($d in (Get-PassthroughDisks $other.Name)) {
            if ($diskNums -notcontains $d.DiskNumber) { continue }
            if ($Fix -and $DetachOthers) {
                if ($other.State -ne "Off") {
                    $problems += "VM『$($other.Name)』が動作中のため接続を外せません (先に停止してください)"
                    continue
                }
                Remove-VMHardDiskDrive -VMName $other.Name `
                    -ControllerType $d.ControllerType `
                    -ControllerNumber $d.ControllerNumber `
                    -ControllerLocation $d.ControllerLocation
                Write-Host "  VM『$($other.Name)』からディスク $($d.DiskNumber) の接続を外しました (VM とデータは残ります)" -ForegroundColor Green
            } else {
                $problems += "VM『$($other.Name)』も同じディスク $($d.DiskNumber) を使っています (同時には使えません)"
            }
        }
    }

    # 3) Windows 側でオンラインのままになっていないか
    foreach ($n in $diskNums) {
        $d = Get-Disk -Number $n -ErrorAction SilentlyContinue
        if ($d -and -not $d.IsOffline) {
            $problems += "ディスク $n が Windows でオンラインのままです"
            if ($Fix) {
                # 万一 VM に誤ったディスクが接続されていても、Windows 自身の
                # ディスクだけは絶対にオフラインにしない
                if ($n -eq $SysDisk) {
                    $problems += "ディスク $n は Windows のシステムディスクです。オフラインにしません (VM の設定を見直してください)"
                } else {
                    Set-Disk -Number $n -IsOffline $true
                    Write-Host "  ディスク $n をオフラインにしました" -ForegroundColor Green
                }
            }
        }
    }
    return $problems
}

function Show-DiskHelp($Problems) {
    Write-Host ""
    Write-Host "ディスクを開けないため起動できません。考えられる原因:" -ForegroundColor Red
    foreach ($p in $Problems) { Write-Host "  - $p" -ForegroundColor Yellow }
    if ($Problems.Count -eq 0) {
        Write-Host "  - WSL がディスクを掴んでいる可能性があります" -ForegroundColor Yellow
        Write-Host "  - バックアップ・暗号化・ディスク管理ツールが使用中の可能性があります" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "対処:" -ForegroundColor Cyan
    Write-Host "  1. 自動で直せる分を直す : .\02-start-field-vm.ps1 -Repair"
    Write-Host "     他 VM の接続も外す   : .\02-start-field-vm.ps1 -Repair -DetachOthers"
    Write-Host "                            (その VM とディスクの中身は消えません)"
    Write-Host "  2. WSL を切り離す       : wsl --unmount \\.\PHYSICALDRIVE0   (その後 wsl --shutdown)"
    Write-Host "  3. 他 VM が使っている場合: その VM を停止し、Hyper-V マネージャーでディスク接続を外す"
    Write-Host "  4. それでも駄目なら PC を再起動すると、掴んでいたプロセスごと解放されます"
}

if ($Repair) {
    Write-Host "ディスクの取り合いを診断しています..." -ForegroundColor Cyan
    $before = Test-DiskReady -Fix
    if ($before.Count -eq 0) {
        Write-Host "自動で直せる問題は見つかりませんでした (接続は 1 つ・オフライン済み)。" -ForegroundColor Green
        Show-DiskHelp @()
    } else {
        Write-Host "見つかった問題:" -ForegroundColor Yellow
        foreach ($p in $before) { Write-Host "  - $p" }
        $after = Test-DiskReady
        if ($after.Count -eq 0) {
            Write-Host "直しました。起動してみてください: .\02-start-field-vm.ps1" -ForegroundColor Green
        } else {
            Show-DiskHelp $after
        }
    }
    exit 0
}

$wasOff = ($vm.State -ne "Running")
if ($vm.State -ne "Running") {
    # 『EdgeBox表示設定』で指定されたコンソール解像度を、起動前に反映する
    $cfgFile = Join-Path $PSScriptRoot "display-config.json"
    if (Test-Path $cfgFile) {
        try {
            $resText = [string](Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).ConsoleResolution
            if ($resText -match '^(auto|自動)') {
                Add-Type -AssemblyName System.Windows.Forms
                $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
                $rw = $b.Width; $rh = $b.Height
            } elseif ($resText -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
                $rw = [int]$Matches[1]; $rh = [int]$Matches[2]
            }
            if ($rw) {
                Set-VMVideo -VMName $VMName -ResolutionType Single `
                    -HorizontalResolution $rw -VerticalResolution $rh -ErrorAction SilentlyContinue
                Write-Host "コンソールの解像度: ${rw}x${rh}"
            }
        } catch { }
    }
    Write-Host "EdgeBox を起動しています..." -ForegroundColor Cyan
    try {
        Start-VM -Name $VMName -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "起動に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Message -match '0x80070020|使用中|in use') {
            Show-DiskHelp (Test-DiskReady)
        }
        exit 1
    }
}

# コンソール画面 (起動ログ・EdgeBox の画面) を表示。モニター2に置いて監視用に
Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName

# いま起動したときだけ: EdgeBox の起動を確認したら監視画面を自動で閉じる
# (起動後のコンソールは黒い画面が残るだけのため。『設定』の[画面表示]でオフにできる)
$autoCloseNote = ""
if ($wasOff) {
    try {
        $dispFile = Join-Path $PSScriptRoot "display-config.json"
        $dispCfg = $null
        if (Test-Path $dispFile) { $dispCfg = Get-Content $dispFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        if (-not $dispCfg -or $dispCfg.ConsoleAutoClose -ne $false) {
            $waitUrl = ""
            foreach ($u in @([string]$dispCfg.RightUrl, [string]$dispCfg.LeftUrl)) {
                if ($u -match '^https?://') { $waitUrl = $u; break }
            }
            # 管理画面 URL があれば応答確認後 30 秒で、無ければ起動が確実に終わる 5 分後に閉じる
            $closeDelay = if ($waitUrl) { 30 } else { 300 }
            $closerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\03-field-display-kiosk.ps1`" " +
                "-ConsoleCloser -CloserDelaySec $closeDelay -VMName `"$VMName`""
            if ($waitUrl) { $closerArgs += " -CloserWaitUrl `"$waitUrl`"" }
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $closerArgs
            $autoCloseNote = "  - 起動の完了を確認したら、コンソール窓は自動で閉じます (『設定』の[画面表示]で変更可)"
        }
    } catch { }
}

Write-Host ""
Write-Host "起動しました。" -ForegroundColor Green
Write-Host "  - コンソール窓が開きます。モニター2に移動して監視用にどうぞ"
if ($autoCloseNote) { Write-Host $autoCloseNote }
Write-Host "  - 管理画面 (Web UI) は、VM の IP アドレスにブラウザでアクセスしてください"
Write-Host "    IP の確認: Get-VMNetworkAdapter -VMName $VMName | Select -Expand IPAddresses"
Write-Host "    (表示されるまで起動から数分かかることがあります)"
