<#
.SYNOPSIS
    EdgeBox VM を起動し、コンソール画面を開きます。

.EXAMPLE
    .\02-start-field-vm.ps1              # 起動 + コンソール表示
    .\02-start-field-vm.ps1 -Stop       # 通常シャットダウン要求
    .\02-start-field-vm.ps1 -Status     # 状態表示
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Stop,
    [switch]$Status
)

$ErrorActionPreference = "Stop"

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
        Stop-VM -Name $VMName   # ACPI シャットダウン要求 (専用機側が正常終了処理を行う)
        Write-Host "シャットダウンを要求しました。"
    } else {
        Write-Host "VM は起動していません ($($vm.State))。"
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
    Start-VM -Name $VMName
}

# コンソール画面 (起動ログ・専用機の画面) を表示。モニター2に置いて監視用に
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
