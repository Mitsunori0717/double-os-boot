<#
.SYNOPSIS
    ダブルクリックで「FIELD system 単独起動」に切り替えます (次回のみ)。
    次に電源を入れたときは、自動的に Windows に戻ります。

.DESCRIPTION
    UEFI の「次回起動のみの起動先指定 (bootsequence)」を使います:
      1. FIELD system VM を安全に停止
      2. 次回起動先を FIELD system のディスクに設定 (1回だけ有効)
      3. PC を再起動 → FIELD system がネイティブ (単独) 起動
      4. その利用を終えて次に電源を入れると、既定の Windows が起動 (戻し操作不要)

.EXAMPLE
    .\04-reboot-to-field-native.ps1 -Setup   # 初回のみ: 起動エントリの選択とショートカット作成
    .\04-reboot-to-field-native.ps1          # 実行: FIELD 単独起動へ切り替え

.NOTES
    管理者権限が必要です (-Setup が作るショートカットは管理者実行フラグ付き)。
#>
[CmdletBinding()]
param(
    [string]$VMName = "FIELDsystem",
    [switch]$Setup,
    [switch]$NoConfirm
)

$ErrorActionPreference = "Stop"
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

if ($Setup -or -not (Test-Path $ConfFile)) {
    Write-Host "UEFI の起動エントリから FIELD system のものを選択します。" -ForegroundColor Cyan
    $entries = Get-FirmwareEntries
    if ($entries.Count -eq 0) {
        Write-Error "ファームウェア起動エントリが見つかりません。'bcdedit /enum firmware' の出力を確認してください。"
        exit 1
    }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        Write-Host ("  [{0}] {1}  {2}" -f $i, $entries[$i].Description, $entries[$i].Guid)
    }
    Write-Host ""
    Write-Host "ヒント: FIELD system は 'UEFI OS' や 'ubuntu'、KIOXIA のディスク名などの表記です。"
    Write-Host "        どれか不明な場合は、この一覧を貼り付けて相談してください。"
    $sel = Read-Host "FIELD system の番号"
    $entry = $entries[[int]$sel]
    $entry.Guid | Set-Content -Path $ConfFile -Encoding ASCII
    Write-Host "保存しました: $($entry.Description) $($entry.Guid)" -ForegroundColor Green

    # --- デスクトップに管理者実行フラグ付きショートカットを作成 ---
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "FIELD system 単独起動.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,238"
    $lnk.Description  = "FIELD system をネイティブ単独起動 (次回のみ。次の電源投入では Windows に戻る)"
    $lnk.Save()
    # 「管理者として実行」フラグを立てる
    $bytes = [IO.File]::ReadAllBytes($lnkPath)
    $bytes[0x15] = $bytes[0x15] -bor 0x20
    [IO.File]::WriteAllBytes($lnkPath, $bytes)
    Write-Host "デスクトップに『FIELD system 単独起動』ショートカットを作成しました。" -ForegroundColor Green
    if ($Setup) { exit 0 }
}

$guid = (Get-Content $ConfFile -First 1).Trim()

Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " FIELD system を単独起動します (Windows は終了)"
Write-Host "  - 実行中の作業は保存してください"
Write-Host "  - FIELD system の利用終了後、次に電源を入れると Windows に戻ります"
Write-Host "==============================================" -ForegroundColor Yellow
if (-not $NoConfirm) {
    $ans = Read-Host "実行しますか? (y/N)"
    if ($ans -ne "y") { exit 0 }
}

# --- VM を安全に停止 (実行中なら) ---
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and $vm.State -eq "Running") {
    Write-Host "FIELD system VM をシャットダウンしています..."
    Stop-VM -Name $VMName
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        Write-Error "VM が3分以内に停止しませんでした。VM の状態を確認してから再実行してください。"
        exit 1
    }
}

# --- 次回のみの起動先を設定して再起動 ---
bcdedit /set "{fwbootmgr}" bootsequence $guid | Out-Null
Write-Host "次回起動先を FIELD system に設定しました。5秒後に再起動します..." -ForegroundColor Green
shutdown /r /t 5 /c "FIELD system 単独起動のため再起動します"
