<#
.SYNOPSIS
    ダブルクリックで「EdgeBox 単独起動」に切り替えます (次回のみ)。
    次に電源を入れたときは、自動的に Windows に戻ります。

.DESCRIPTION
    UEFI の「次回起動のみの起動先指定 (bootsequence)」を使います:
      1. EdgeBox VM を安全に停止
      2. 次回起動先を EdgeBox のディスクに設定 (1回だけ有効)
      3. PC を再起動 → EdgeBox がネイティブ (単独) 起動
      4. その利用を終えて次に電源を入れると、既定の Windows が起動 (戻し操作不要)

.EXAMPLE
    .\04-reboot-to-field-native.ps1 -Setup   # 初回のみ: 起動エントリの選択とショートカット作成
    .\04-reboot-to-field-native.ps1          # 実行: EdgeBox 単独起動へ切り替え

.NOTES
    管理者権限が必要です (-Setup が作るショートカットは管理者実行フラグ付き)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$Setup,
    [switch]$NoConfirm
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
$ConfFile = Join-Path $PSScriptRoot "field-boot-entry.conf"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限で実行してください (ショートカットからの起動なら自動で管理者になります)。"
    exit 1
}

# --- UEFI のファームウェア起動エントリを列挙する ---
function Get-FirmwareEntries {
    $raw = (bcdedit /enum firmware | Out-String) -split "(\r?\n){2,}"
    $entries = @()
    foreach ($block in $raw) {
        if ($block -notmatch '\{[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}\}') { continue }
        $guid = [regex]::Match($block, '\{[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}\}').Value
        $desc = ""
        foreach ($line in ($block -split "\r?\n")) {
            if ($line -match '^(description|説明)\s+(.+)$') { $desc = $Matches[2].Trim(); break }
        }
        if ($desc -match 'Windows Boot Manager') { continue }
        $entries += [pscustomobject]@{ Guid = $guid; Description = $desc }
    }
    return $entries
}

if (-not $Setup -and -not (Test-Path $ConfFile)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "初期設定がまだ済んでいません。`n管理者 PowerShell で次を実行してください:`n`n.\04-reboot-to-field-native.ps1 -Setup",
        "EdgeBox 単独起動",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 1
}

if ($Setup) {
    if (Test-Path $ConfFile) {
        # すでに選択済みなら聞き直さない (アイコン・タスクの作り直しだけ行う)
        Write-Host "起動先は選択済みのため、そのまま使います: $((Get-Content $ConfFile -First 1).Trim())" -ForegroundColor Cyan
        Write-Host "  (選び直したい場合は field-boot-entry.conf を削除してから -Setup を実行)"
    } else {
        Write-Host "UEFI の起動エントリから EdgeBox のものを選択します。" -ForegroundColor Cyan
        $entries = Get-FirmwareEntries
        if ($entries.Count -eq 0) {
            Write-Error "ファームウェア起動エントリが見つかりません。'bcdedit /enum firmware' の出力を確認してください。"
            exit 1
        }
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host ("  [{0}] {1}  {2}" -f $i, $entries[$i].Description, $entries[$i].Guid)
        }
        Write-Host ""
        Write-Host "ヒント: EdgeBox は 'UEFI OS' や 'ubuntu'、KIOXIA のディスク名などの表記です。"
        Write-Host "        どれか不明な場合は、この一覧を貼り付けて相談してください。"
        $sel = Read-Host "EdgeBox の番号"
        $entry = $entries[[int]$sel]
        $entry.Guid | Set-Content -Path $ConfFile -Encoding ASCII
        Write-Host "保存しました: $($entry.Description) $($entry.Guid)" -ForegroundColor Green
    }

    # --- UAC 確認なしで実行できるよう、管理者権限付きタスク + それを起動するアイコンを作成 ---
    $taskName = "EdgeBox-Native-Boot"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "EdgeBox 単独起動.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,238"
    $lnk.Description  = "EdgeBox をネイティブ単独起動 (次回のみ。次の電源投入では Windows に戻る)"
    $lnk.Save()
    Write-Host "デスクトップに『EdgeBox 単独起動』ショートカットを作成しました (UAC 確認なしで実行できます)。" -ForegroundColor Green
    if ($Setup) { exit 0 }
}

$guid = (Get-Content $ConfFile -First 1).Trim()

Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " EdgeBox を単独起動します (Windows は終了)"
Write-Host "  - 実行中の作業は保存してください"
Write-Host "  - EdgeBox の利用終了後、次に電源を入れると Windows に戻ります"
Write-Host "==============================================" -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
if (-not $NoConfirm) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "EdgeBox を単独起動します (Windows は終了して再起動します)。`n`n" +
        "・実行中の作業は保存してください`n" +
        "・EdgeBox の利用終了後、次に電源を入れると自動的に Windows に戻ります`n`n" +
        "実行しますか?",
        "EdgeBox 単独起動",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
}

# --- VM を安全に停止 (実行中なら) ---
# コンソール画面 (vmconnect) を先に閉じる (停止後の自動再起動を防ぐ)
Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Start-Sleep -Seconds 2
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and $vm.State -eq "Running") {
    Write-Host "EdgeBox VM をシャットダウンしています..."
    Stop-VM -Name $VMName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        [System.Windows.Forms.MessageBox]::Show(
            "EdgeBox が3分以内に停止しませんでした。`n単独起動を中止します。コンソール画面で状態を確認してから再実行してください。",
            "EdgeBox 単独起動",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        exit 1
    }
}

# --- 次回のみの起動先を設定して再起動 ---
bcdedit /set "{fwbootmgr}" bootsequence $guid | Out-Null
Write-Host "次回起動先を EdgeBox に設定しました。5秒後に再起動します..." -ForegroundColor Green
shutdown /r /t 5 /c "EdgeBox 単独起動のため再起動します"
