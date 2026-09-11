<#
.SYNOPSIS
    EdgeBox の入出力を素通しに近づけます: メモリの固定 + LAN の直結 (SR-IOV)。

.DESCRIPTION
    -Check (既定) : 何も変えずに、現状と「あと何が必要か」を表示します。
    -Apply        : メモリを固定にし、この PC で SR-IOV が使えるなら EdgeBox の LAN に適用します。
                    変更には EdgeBox の停止が必要なため、正常シャットダウン → 適用 → 起動 の順に進みます
                    (強制電源断は行いません)。

    SR-IOV とは: LAN アダプターがハードウェアで持つ「分身」を EdgeBox に直接渡す仕組みです。
    有効になると、EdgeBox の通信が Windows 側の CPU を経由しなくなります。
    EdgeBox 側に対応ドライバーが無い場合は従来の経路のまま動き続けます (悪化はしません)。

.EXAMPLE
    .\11-io-passthrough.ps1            # 現状の確認だけ (何も変えない)
    .\11-io-passthrough.ps1 -Apply     # メモリ固定 + SR-IOV を適用 (確認あり)
    .\11-io-passthrough.ps1 -Apply -MemoryGB 8   # 固定にするメモリ量を指定

.NOTES
    管理者権限が必要です。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Apply,
    [int]$MemoryGB = 0,       # 0 = 今の起動時メモリ量のまま固定にする
    [switch]$NoConfirm,
    [switch]$NoRestart        # 適用後に EdgeBox を起動しない
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) { Write-Error "管理者権限で実行してください (管理者の PowerShell)。"; exit 1 }

# 登録名が EdgeBox でなくても、EdgeBox のディスク (物理ディスク直結) を持つ登録を探す
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
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Error "登録 '$VMName' が見つかりません。"; exit 1 }

function Line([string]$Text, [string]$Color = "Gray") { Write-Host $Text -ForegroundColor $Color }
function Mark([bool]$Ok, [string]$Text, [string]$Hint = "") {
    if ($Ok) { Write-Host ("  ○ " + $Text) -ForegroundColor Green }
    else {
        Write-Host ("  × " + $Text) -ForegroundColor Yellow
        if ($Hint) { Write-Host ("      → " + $Hint) -ForegroundColor Yellow }
    }
}

# 英語の理由文を、BIOS で触る項目名に翻訳する (Get-VMHost / Get-VMSwitch の IovSupportReasons)
function ConvertTo-BiosHint([string[]]$Reasons) {
    $hints = @()
    $all = ($Reasons -join " ")
    if ($all -match "IOMMU|I/O virtualization|DMA remap|VT-d") {
        $hints += "BIOS で『Intel VT-d』(IOMMU / Intel Virtualization Technology for Directed I/O) を Enabled にする"
    }
    if ($all -match "SR-IOV.*(BIOS|firmware|hardware)|not support SR-IOV|SR-IOV support") {
        $hints += "BIOS で『SR-IOV Support』を Enabled にする (項目が無い機種は非対応)"
    }
    if ($all -match "ACS|Access Control Services") {
        $hints += "チップセットが ACS 非対応 (BIOS に『ACS Enable』があれば Enabled、無ければこの機種では使えません)"
    }
    if ($all -match "interrupt remapping") {
        $hints += "BIOS で『Interrupt Remapping』を Enabled にする (VT-d の下にあることが多い)"
    }
    if ($hints.Count -eq 0 -and $Reasons.Count -gt 0) {
        $hints += "上の理由 (英語) をそのまま検索してください。多くは BIOS の VT-d / SR-IOV の設定です"
    }
    return $hints
}

# ------------------------------------------------------------ 現状の収集

$mem     = Get-VMMemory -VMName $VMName
$host_   = Get-VMHost
$vmNics  = @(Get-VMNetworkAdapter -VMName $VMName)
$vmNic   = if ($vmNics.Count -gt 0) { $vmNics[0] } else { $null }
$sw      = $null
if ($vmNic -and $vmNic.SwitchName) { $sw = Get-VMSwitch -Name $vmNic.SwitchName -ErrorAction SilentlyContinue }
$pfDesc  = if ($sw) { [string]$sw.NetAdapterInterfaceDescription } else { "" }
$pf      = $null
if ($pfDesc) { $pf = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -eq $pfDesc } | Select-Object -First 1 }
$sriovAll = @(Get-NetAdapterSriov -ErrorAction SilentlyContinue)
$pfSriov  = $null
if ($pf) { $pfSriov = $sriovAll | Where-Object { $_.Name -eq $pf.Name } | Select-Object -First 1 }

$memFixed   = -not [bool]$mem.DynamicMemoryEnabled
$hostIov    = [bool]$host_.IovSupport
$hostWhy    = @($host_.IovSupportReasons | Where-Object { $_ })
$pfOk       = ($null -ne $pfSriov) -and ([string]$pfSriov.SriovSupport -eq "Supported")
$pfEnabled  = ($null -ne $pfSriov) -and [bool]$pfSriov.Enabled
$swIov      = ($null -ne $sw) -and [bool]$sw.IovEnabled
$swWhy      = if ($sw) { @($sw.IovSupportReasons | Where-Object { $_ }) } else { @() }
$nicWeight  = if ($vmNic) { [int]$vmNic.IovWeight } else { 0 }
$vfActive   = ($null -ne $vmNic) -and [bool]$vmNic.VFDataPathActive

# ------------------------------------------------------------ 表示

Line ""
Line ("==== EdgeBox ('{0}') の入出力: 現状 ====" -f $VMName) "Cyan"
Line ""
Line "[メモリ]" "White"
$memText = if ($memFixed) { "固定 {0:N1} GB" -f ($mem.Startup / 1GB) }
           else { "動的 (起動 {0:N1} GB / 最小 {1:N1} GB / 最大 {2:N1} GB)" -f ($mem.Startup / 1GB), ($mem.Minimum / 1GB), ($mem.Maximum / 1GB) }
Mark $memFixed ("メモリは " + $memText) "-Apply で固定にします (起動時の量で固定。-MemoryGB で変更可)"

Line ""
Line "[LAN の直結 (SR-IOV)]" "White"
Mark $hostIov ("この PC (Hyper-V) で SR-IOV が使える: " + $(if ($hostIov) { "はい" } else { "いいえ" }))
if (-not $hostIov) {
    foreach ($r in $hostWhy) { Line ("      理由: " + $r) "DarkYellow" }
    foreach ($h in (ConvertTo-BiosHint $hostWhy)) { Line ("      → " + $h) "Yellow" }
}
if (-not $vmNic) {
    Mark $false "EdgeBox に LAN アダプターがありません" "01-create-field-vm.ps1 / 00-field-launcher.ps1 で作り直してください"
} elseif (-not $sw) {
    Mark $false ("EdgeBox の LAN が接続されていません (スイッチ '{0}')" -f $vmNic.SwitchName)
} else {
    Line ("  EdgeBox の LAN: スイッチ '{0}' ← 物理アダプター '{1}'" -f $sw.Name, $(if ($pf) { $pf.Name } else { $pfDesc }))
    if ($pf) {
        if (-not $pfSriov) {
            Mark $false ("物理アダプター '{0}' は SR-IOV 非対応 (ドライバーが対応していません)" -f $pf.Name) `
                "SR-IOV 対応の LAN カード (Intel I350 / X550 / I210 など) を足し、そのポートを EdgeBox 用にします"
        } else {
            Mark $pfOk ("物理アダプター '{0}' の SR-IOV: {1}" -f $pf.Name, $pfSriov.SriovSupport) `
                "SriovSupport が Supported 以外のときは BIOS の VT-d / SR-IOV、または PCIe スロットの位置が原因です"
            Mark $pfEnabled ("物理アダプター側の有効化: " + $(if ($pfEnabled) { "有効 (VF {0} 個)" -f $pfSriov.NumVFs } else { "無効" })) "-Apply で有効にします"
        }
    }
    Mark $swIov ("スイッチ '{0}' の SR-IOV: {1}" -f $sw.Name, $(if ($swIov) { "有効" } else { "無効" })) `
        "スイッチは作り直しが必要です (-Apply が同じ名前・同じ設定で作り直します)"
    if (-not $swIov -and $swWhy.Count -gt 0) { foreach ($r in $swWhy) { Line ("      理由: " + $r) "DarkYellow" } }
    Mark ($nicWeight -gt 0) ("EdgeBox 側の LAN の SR-IOV 要求 (IovWeight): " + $nicWeight) "-Apply で 100 にします"
    Mark $vfActive ("EdgeBox が実際に直結で通信中 (VFDataPathActive): " + $(if ($vfActive) { "はい" } else { "いいえ" })) `
        "上が全部 ○ でもここが × なら、EdgeBox 側に対応ドライバーが無いか、起動直後です (通信は従来経路で継続)"
}
if ($sriovAll.Count -gt 0) {
    Line ""
    Line "  参考: この PC で SR-IOV に対応している LAN アダプター" "DarkGray"
    foreach ($s in $sriovAll) { Line ("    - {0}: {1} (有効: {2})" -f $s.Name, $s.SriovSupport, $s.Enabled) "DarkGray" }
}
Line ""

$canSriov = $hostIov -and $pfOk
$needMem  = -not $memFixed -or ($MemoryGB -gt 0 -and [long]($MemoryGB * 1GB) -ne [long]$mem.Startup)
$needSw   = $canSriov -and -not $swIov
$needPf   = $canSriov -and -not $pfEnabled
$needNic  = $canSriov -and ($nicWeight -le 0)

if (-not $Apply) {
    Line "==== 判定 ====" "Cyan"
    if (-not $needMem -and -not $needSw -and -not $needPf -and -not $needNic) {
        if ($canSriov -or -not $vmNic) { Line "  設定はすべて済んでいます。" "Green" }
        else { Line "  メモリは固定済みです。SR-IOV はこの PC では今のところ使えません (上の → を参照)。" "Yellow" }
    } else {
        Line "  -Apply を付けて実行すると、次を行います:" "White"
        if ($needMem) { Line "    - メモリを固定にする (EdgeBox を一度停止)" }
        if ($needPf)  { Line ("    - 物理アダプター '{0}' の SR-IOV を有効にする" -f $pf.Name) }
        if ($needSw)  { Line ("    - スイッチ '{0}' を SR-IOV 有効で作り直す (EdgeBox を一度停止)" -f $sw.Name) }
        if ($needNic) { Line "    - EdgeBox の LAN に SR-IOV を要求する (IovWeight 100)" }
        if (-not $canSriov -and $needMem) { Line "  SR-IOV は今のところ使えないため、メモリの固定だけ行います。" "Yellow" }
    }
    Line ""
    exit 0
}

# ------------------------------------------------------------ -Apply

if (-not $needMem -and -not $needSw -and -not $needPf -and -not $needNic) {
    Line "変更するものがありません。" "Green"; exit 0
}
$needStop = $needMem -or $needSw
if (-not $NoConfirm) {
    $msg = "次を適用します:`n"
    if ($needMem) { $msg += "  - メモリを固定にする`n" }
    if ($needPf)  { $msg += "  - 物理アダプターの SR-IOV を有効にする (LAN が数秒切れます)`n" }
    if ($needSw)  { $msg += "  - スイッチを SR-IOV 有効で作り直す (LAN が数秒切れます)`n" }
    if ($needNic) { $msg += "  - EdgeBox の LAN に SR-IOV を要求する`n" }
    if ($needStop) { $msg += "`nEdgeBox を正常シャットダウンしてから適用し、終わったら起動します。収集が数分止まります。" }
    $msg += "`n続けますか? [y/N] "
    $ans = Read-Host $msg
    if ($ans -notmatch '^[yY]') { Line "中止しました (何も変更していません)。"; exit 0 }
}

# --- EdgeBox の停止 (必要なときだけ。強制電源断はしない) ---
$wasRunning = ([string](Get-VM -Name $VMName).State -ne "Off")
if ($needStop -and $wasRunning) {
    Line "EdgeBox にシャットダウン要求を送ります..." "White"
    Stop-VM -Name $VMName -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-VM -Name $VMName).State -ne "Off") {
        if ((Get-Date) -gt $deadline) { Write-Error "EdgeBox が 180 秒以内に停止しませんでした。中止します (何も変更していません)。"; exit 1 }
        Start-Sleep -Seconds 3
    }
    Line "EdgeBox が停止しました。" "Green"
}

# --- メモリの固定 ---
if ($needMem) {
    $bytes = if ($MemoryGB -gt 0) { [long]$MemoryGB * 1GB } else { [long]$mem.Startup }
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $bytes
    Line ("メモリを固定 {0:N1} GB にしました。" -f ($bytes / 1GB)) "Green"
}

# --- 物理アダプターの SR-IOV ---
if ($needPf) {
    Enable-NetAdapterSriov -Name $pf.Name -ErrorAction Stop
    Start-Sleep -Seconds 5
    Line ("物理アダプター '{0}' の SR-IOV を有効にしました。" -f $pf.Name) "Green"
}

# --- スイッチの作り直し (SR-IOV は作成時にしか指定できない) ---
if ($needSw) {
    $swName  = $sw.Name
    $allowMg = [bool]$sw.AllowManagementOS
    $hostNic = Get-NetAdapter -Name ("vEthernet ($swName)") -ErrorAction SilentlyContinue
    # Windows 側の IP が固定なら控えておき、作り直した後に戻す (DHCP なら何もしない)
    $saved = $null
    if ($hostNic) {
        $ip = Get-NetIPAddress -InterfaceIndex $hostNic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.PrefixOrigin -eq "Manual" } | Select-Object -First 1
        if ($ip) {
            $gw  = Get-NetRoute -InterfaceIndex $hostNic.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
            $dns = @((Get-DnsClientServerAddress -InterfaceIndex $hostNic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            $saved = @{ IP = $ip.IPAddress; Prefix = $ip.PrefixLength; Gw = $(if ($gw) { $gw.NextHop } else { $null }); Dns = $dns }
            Line ("Windows 側の固定 IP {0}/{1} を控えました (作り直し後に戻します)。" -f $saved.IP, $saved.Prefix) "DarkGray"
        }
    }
    Line ("スイッチ '{0}' を SR-IOV 有効で作り直します..." -f $swName) "White"
    Remove-VMSwitch -Name $swName -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    New-VMSwitch -Name $swName -NetAdapterInterfaceDescription $pfDesc -AllowManagementOS $allowMg -EnableIov $true -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 5
    Connect-VMNetworkAdapter -VMName $VMName -SwitchName $swName -ErrorAction Stop
    if ($saved) {
        $hostNic2 = Get-NetAdapter -Name ("vEthernet ($swName)") -ErrorAction SilentlyContinue
        if ($hostNic2) {
            try {
                if ($saved.Gw) { New-NetIPAddress -InterfaceIndex $hostNic2.ifIndex -IPAddress $saved.IP -PrefixLength $saved.Prefix -DefaultGateway $saved.Gw -ErrorAction Stop | Out-Null }
                else { New-NetIPAddress -InterfaceIndex $hostNic2.ifIndex -IPAddress $saved.IP -PrefixLength $saved.Prefix -ErrorAction Stop | Out-Null }
                if ($saved.Dns.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $hostNic2.ifIndex -ServerAddresses $saved.Dns -ErrorAction SilentlyContinue }
                Line "Windows 側の固定 IP を戻しました。" "DarkGray"
            } catch { Line ("Windows 側の固定 IP を戻せませんでした: " + $_.Exception.Message + " (手で設定してください)") "Yellow" }
        }
    }
    $sw2 = Get-VMSwitch -Name $swName
    Mark ([bool]$sw2.IovEnabled) ("スイッチ '{0}' の SR-IOV: {1}" -f $swName, $(if ($sw2.IovEnabled) { "有効" } else { "無効" }))
    if (-not $sw2.IovEnabled) { foreach ($r in @($sw2.IovSupportReasons | Where-Object { $_ })) { Line ("      理由: " + $r) "DarkYellow" } }
}

# --- EdgeBox の LAN に要求 ---
if ($canSriov) {
    Set-VMNetworkAdapter -VMName $VMName -IovWeight 100 -IovQueuePairsRequested 1 -ErrorAction Stop
    Line "EdgeBox の LAN に SR-IOV を要求しました (IovWeight 100)。" "Green"
}

# --- 起動 (停止したときだけ。CPU 完全分離の起動処理と同じ順番で) ---
if ($needStop -and $wasRunning -and -not $NoRestart) {
    try {
        $cpuDir = Join-Path (Split-Path $PSScriptRoot -Parent) "windows-cpu-partition"
        $cfgF = Join-Path $cpuDir "cpu-partition.json"; $ps1 = Join-Path $cpuDir "cpu-partition.ps1"
        if ((Test-Path $cfgF) -and (Test-Path $ps1)) {
            $c = Get-Content $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.Mode -eq "full") {
                $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -BootApply -Quiet"
                if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { } }
            }
        }
    } catch { }
    Line "EdgeBox を起動します..." "White"
    Start-VM -Name $VMName -ErrorAction Stop
    $s03 = Join-Path $PSScriptRoot "03-field-display-kiosk.ps1"
    if (Test-Path $s03) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$s03`" -VMName `"$VMName`" -NoSplash"
    }
    if ($canSriov) {
        Line "EdgeBox が直結で通信を始めるかを最大 120 秒待ちます (EdgeBox 側のドライバー次第)..." "White"
        $deadline = (Get-Date).AddSeconds(120); $active = $false
        while ((Get-Date) -lt $deadline) {
            $n = @(Get-VMNetworkAdapter -VMName $VMName)[0]
            if ($n -and $n.VFDataPathActive) { $active = $true; break }
            Start-Sleep -Seconds 5
        }
        Mark $active ("EdgeBox が直結で通信中 (VFDataPathActive): " + $(if ($active) { "はい" } else { "いいえ" })) `
            "EdgeBox 側に対応ドライバーが無い可能性があります。通信は従来経路で続きます。しばらく後にもう一度 (引数なしで) 確認してください"
    }
}
Line ""
Line "完了。引数なしで実行すると現状を確認できます。" "Green"
exit 0
