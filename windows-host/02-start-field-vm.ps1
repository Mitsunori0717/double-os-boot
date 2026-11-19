<#
.SYNOPSIS
    Edge Box を起動し、コンソール画面を開きます。

.EXAMPLE
    .\02-start-field-vm.ps1              # 起動 + コンソール表示
    .\02-start-field-vm.ps1 -Stop       # 通常シャットダウン要求
    .\02-start-field-vm.ps1 -Status     # 状態表示
    .\02-start-field-vm.ps1 -Repair     # ディスクの取り合いを診断して直せる範囲を直す
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [string]$ExpectedVmId,
    [switch]$Stop,
    [switch]$Status,
    # ディスクが「別のプロセスが使用中」で起動できないときの自動修復
    # (重複した接続の削除 / ディスクのオフライン化。他 Edge Box の設定には触れない)
    [switch]$Repair,

    # -Repair と併用。同じディスクを掴んでいる他の Edge Box から、その接続だけを外す
    # (Edge Box 自体もディスクの中身も消しません。対象 が停止中のときのみ実行)
    [switch]$DetachOthers
)

$ErrorActionPreference = "Stop"

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

Import-Module (Join-Path $PSScriptRoot 'vm-create-safety.psm1') -Force -ErrorAction Stop

# CPU コア分割ツール (別フォルダ windows-cpu-partition) が full モードなら、Edge Box を起動する前に
# 起動タスクと同じ処理を呼び、CPU グループに固定してから起動する (固定は Edge Box 停止中に確実に効く)。
# ツールが無ければ何もしない (互いに独立。あるときだけ順番を譲る)。戻り値: 呼んだか
function Invoke-CpuPartitionBoot {
    Import-Module (Join-Path $PSScriptRoot 'cpu-boot.psm1') -Force -ErrorAction Stop
    Invoke-EdgeBoxCpuPreparation -VMName $VMName
}

$matches = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -eq $VMName })
if ($matches.Count -ne 1) {
    Write-Error "登録 '$VMName' がありません。01-create-field-vm.ps1 で作成してください。"
    exit 1
}
$vm=$matches[0]
if ($ExpectedVmId -and [string]$vm.Id -ne $ExpectedVmId) { throw 'SELECTED_VM_ID_CHANGED' }

if ($Status) {
    $vm | Format-Table Name, State, CPUUsage, MemoryAssigned, Uptime
    exit 0
}

if ($Stop) {
    Import-Module (Join-Path $PSScriptRoot 'vm-shutdown.psm1') -Force -ErrorAction Stop
    Wait-EdgeBoxShutdown -VMName $VMName -ExpectedVmId ([string]$vm.Id)
    exit 0
}

# ============================================================
#  物理ディスクの取り合いを調べる
#  (パススルー ディスクは「Windows からオフライン」かつ「1 つの Edge Box だけが接続」
#   でないと開けず、Start-VM が 0x80070020 で失敗する)
# ============================================================
function Get-PassthroughDisks($VM) {
    @(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber })
}

function Test-DiskReady([switch]$Fix) {
    $current=Get-VM -Id $vm.Id -ErrorAction Stop
    if([string]$current.Id -ne [string]$vm.Id){throw 'SELECTED_VM_IDENTITY_CHANGED'}
    $mine=@(Get-PassthroughDisks $current)
    if($mine.Count -eq 0){return @()} # VHD/VHDX-backed guests need no physical repair.
    if($Fix -and [string]$current.State -ne 'Off'){throw 'REPAIR_REQUIRES_SELECTED_VM_OFF'}
    $problems=@();$detach=@();$snapshots=@{};$blocked=$false
    $diskNumbers=@($mine|Select-Object -ExpandProperty DiskNumber -Unique)

    # Complete every read-only host/disk/owner check before changing any attachment.
    foreach($number in $diskNumbers){
        $disk=Get-EdgeBoxHostDisk -DiskNumber $number
        $snapshots[[string]$number]=[pscustomobject]@{Number=$disk.Number;UniqueId=$disk.UniqueId;Size=$disk.Size;SerialNumber=$disk.SerialNumber}
        if(-not $disk.IsOffline){$problems+=('ディスク '+$number+' が Windows でオンラインです')}
    }
    foreach($group in @($mine|Group-Object DiskNumber)){
        if($group.Count -gt 1){
            $problems+=('ディスク '+$group.Name+' が重複接続されています')
            foreach($extra in @($group.Group|Select-Object -Skip 1)){$detach+=@{VMId=[string]$current.Id;Drive=$extra}}
        }
    }
    foreach($other in @(Get-VM -ErrorAction Stop|Where-Object {[string]$_.Id -ne [string]$current.Id})){
        foreach($drive in @(Get-PassthroughDisks $other)){
            if($diskNumbers -notcontains $drive.DiskNumber){continue}
            $problems+=('登録『'+$other.Name+'』もディスク '+$drive.DiskNumber+' を使用しています')
            if($Fix -and $DetachOthers -and [string]$other.State -eq 'Off'){
                $detach+=@{VMId=[string]$other.Id;Drive=$drive}
            }else{$blocked=$true}
        }
    }
    if(-not $Fix -or $blocked){return $problems}
    foreach($item in $detach){
        if([string]::IsNullOrWhiteSpace([string]$item.Drive.Id)){throw 'DISK_ATTACHMENT_ID_UNKNOWN'}
    }

    foreach($item in $detach){
        $owner=Get-VM -Id $item.VMId -ErrorAction Stop
        if([string]$owner.Id -ne $item.VMId -or [string]$owner.State -ne 'Off'){throw 'DISK_OWNER_CHANGED_OR_RUNNING'}
        $snapshot=$snapshots[[string]$item.Drive.DiskNumber]
        $null=Get-EdgeBoxHostDisk -DiskNumber $snapshot.Number -ExpectedUniqueId $snapshot.UniqueId -ExpectedSize $snapshot.Size -ExpectedSerialNumber $snapshot.SerialNumber
        $matches=@(Get-PassthroughDisks $owner|Where-Object {
            [string]$_.Id -ceq [string]$item.Drive.Id -and $_.DiskNumber -eq $snapshot.Number
        })
        if($matches.Count -ne 1){throw 'DISK_ATTACHMENT_CHANGED'}
        Remove-VMHardDiskDrive -VMHardDiskDrive $matches[0] -ErrorAction Stop
        Write-Host ('  確認済みの重複・指定接続を外しました: '+$owner.Name+' / ディスク '+$snapshot.Number) -ForegroundColor Green
    }
    foreach($snapshot in $snapshots.Values){
        $owner=Get-VM -Id $current.Id -ErrorAction Stop
        if([string]$owner.Id -ne [string]$current.Id -or [string]$owner.State -ne 'Off'){throw 'SELECTED_VM_CHANGED_OR_RUNNING'}
        # Full ownership guard is required after detach and immediately before offline.
        $disk=Get-EdgeBoxCreateDisk -DiskNumber $snapshot.Number -ExpectedUniqueId $snapshot.UniqueId -ExpectedSize $snapshot.Size -ExpectedSerialNumber $snapshot.SerialNumber -AllowedVmId ([string]$current.Id)
        if(-not $disk.IsOffline){
            Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
            $disk=Get-EdgeBoxCreateDisk -DiskNumber $snapshot.Number -ExpectedUniqueId $snapshot.UniqueId -ExpectedSize $snapshot.Size -ExpectedSerialNumber $snapshot.SerialNumber -AllowedVmId ([string]$current.Id)
            if(-not $disk.IsOffline){throw 'DISK_OFFLINE_NOT_CONFIRMED'}
            Write-Host ('  ディスク '+$disk.Number+' をオフラインにしました') -ForegroundColor Green
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
    Write-Host "     他 Edge Box の接続も外す   : .\02-start-field-vm.ps1 -Repair -DetachOthers"
    Write-Host "                            (その Edge Box とディスクの中身は消えません)"
    Write-Host "  2. WSL に接続している場合: 使用を終え、対象ディスクの ID と番号を照合してからそのディスクを切り離してください。"
    Write-Host "  3. 他 Edge Box が使っている場合: その Edge Box を停止し、Hyper-V マネージャーでディスク接続を外す"
    Write-Host "  4. それでも駄目なら PC を再起動すると、掴んでいたプロセスごと解放されます"
}

if ($Repair) {
    Write-Host "ディスクの取り合いを診断しています..." -ForegroundColor Cyan
    $before = @(Test-DiskReady -Fix)
    if ($before.Count -eq 0) {
        Write-Host "自動で直せる問題は見つかりませんでした (接続は 1 つ・オフライン済み)。" -ForegroundColor Green
    } else {
        Write-Host "見つかった問題:" -ForegroundColor Yellow
        foreach ($p in $before) { Write-Host "  - $p" }
        $after = @(Test-DiskReady)
        if ($after.Count -eq 0) {
            Write-Host "直しました。起動してみてください: .\02-start-field-vm.ps1" -ForegroundColor Green
        } else {
            Show-DiskHelp $after
            exit 1
        }
    }
    exit 0
}

$wasOff = ($vm.State -ne "Running")
if ($vm.State -ne "Running") {
    if ([string]$vm.State -ne 'Off') { throw ('VM_NOT_OFF_OR_RUNNING: '+$vm.State) }
    $diskProblems=@(Test-DiskReady)
    if ($diskProblems.Count) { Show-DiskHelp $diskProblems; exit 1 }
    # 『設定』の [画面表示] で指定されたコンソール解像度 (既定: 左のモニターに合わせる) を、起動前に反映する。
    # 判定は表示処理 (03) と共通 (モニターの大きさは拡大率に関係なく実ピクセルで測る)
    $s03 = Join-Path $PSScriptRoot "03-field-display-kiosk.ps1"
    if (Test-Path $s03) {
        try { & $s03 -VMName $VMName -ApplyResolution } catch { }
    } else {
        $cfgFile = Join-Path $PSScriptRoot "display-config.json"
        if (Test-Path $cfgFile) {
            try {
                $resText = [string](Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).ConsoleResolution
                if ($resText -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
                    Set-VMVideo -VMName $VMName -ResolutionType Single `
                        -HorizontalResolution ([int]$Matches[1]) -VerticalResolution ([int]$Matches[2]) -ErrorAction SilentlyContinue
                    Write-Host "コンソールの解像度: $($Matches[1])x$($Matches[2])"
                }
            } catch { }
        }
    }
    Write-Host "Edge Box を起動しています..." -ForegroundColor Cyan
    $s11 = Join-Path $PSScriptRoot "11-io-passthrough.ps1"   # 予約された設定 (メモリの固定など) を停止中に反映
    if (Test-Path $s11) { try { & $s11 -VMName $VMName -ApplyPending } catch { } }
    if (Invoke-CpuPartitionBoot) { Write-Host "  CPU コア分割 (full): CPU グループに固定してから起動します" -ForegroundColor Cyan }
    try {
        $null=Test-DiskReady | ForEach-Object { throw $_ }
        Start-VM -VM $vm -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "起動に失敗しました: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Message -match '0x80070020|使用中|in use') {
            Show-DiskHelp (Test-DiskReady)
        }
        exit 1
    }
}

# コンソール画面 (起動ログ・Edge Box の画面) を表示。モニター2に置いて監視用に
Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName

# いま起動したときだけ: Edge Box の起動を確認したら監視画面を自動で閉じる
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
Write-Host "  - 管理画面 (Web UI) は、Edge Box の IP アドレスにブラウザでアクセスしてください"
Write-Host "    IP の確認: Get-VMNetworkAdapter -VMName $VMName | Select -Expand IPAddresses"
Write-Host "    (表示されるまで起動から数分かかることがあります)"
