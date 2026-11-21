<#
.SYNOPSIS
    ダブルクリックで「Edge Box 単独起動」に切り替えます (次回のみ)。
    次に電源を入れたときは、自動的に Windows に戻ります。

.DESCRIPTION
    UEFI の「次回起動のみの起動先指定 (bootsequence)」を使います:
      1. Edge Box を安全に停止
      2. 次回起動先を Edge Box のディスクに設定 (1回だけ有効)
      3. PC を再起動 → Edge Box がネイティブ (単独) 起動
      4. その利用を終えて次に電源を入れると、既定の Windows が起動 (戻し操作不要)

.EXAMPLE
    .\04-reboot-to-field-native.ps1 -Setup   # 初回のみ: 起動エントリの選択とショートカット作成
    .\04-reboot-to-field-native.ps1 -Setup -VMName "Field VM"   # 登録名が EdgeBox と異なる場合
    .\04-reboot-to-field-native.ps1          # 実行: Edge Box 単独起動へ切り替え

.NOTES
    管理者権限が必要です (-Setup が作るショートカットは管理者実行フラグ付き)。
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[^"\r\n]+$')][string]$VMName = "EdgeBox",
    [string]$ExpectedVmId,
    [switch]$Setup,
    [switch]$NoConfirm,
    [switch]$FromCpuConsole
)

$ErrorActionPreference = "Stop"

if ($FromCpuConsole -and ($Setup -or $NoConfirm)) { throw '単独起動の引数が正しくありません。' }

$ConfFile = Join-Path $PSScriptRoot "field-boot-entry.conf"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "管理者権限で実行してください (ショートカットからの起動なら自動で管理者になります)。"
    exit 1
}

function Get-NativeBootTaskArguments([string]$ScriptPath, [string]$TargetName, [string]$TargetId) {
    '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -VMName "{1}" -ExpectedVmId {2}' -f $ScriptPath, $TargetName, $TargetId
}

# field-boot-entry.conf only contains an entry GUID. Do not assume it belongs to the selected VM.
function Assert-NativeBootConsoleTarget([string]$ScriptPath, [string]$TargetName, [string]$TargetId) {
    $id = [guid]::Empty
    if (-not [guid]::TryParse($TargetId, [ref]$id) -or $id -eq [guid]::Empty) {
        throw '対象の Edge Box を確認できません。'
    }
    $task = Get-ScheduledTask -TaskPath '\' -TaskName 'EdgeBox-Native-Boot' -ErrorAction SilentlyContinue
    $actions = @($task.Actions)
    $expected = Get-NativeBootTaskArguments $ScriptPath $TargetName ($id.ToString('D'))
    if (-not $task -or $task.State -eq 'Disabled' -or $actions.Count -ne 1 -or
        $actions[0].Execute -ne 'powershell.exe' -or $actions[0].Arguments -cne $expected) {
        throw '選択した Edge Box の単独起動が設定されていません。'
    }
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

function Get-NativeBootConsoleEntry([string]$ScriptPath, [string]$TargetName, [string]$TargetId, [string]$ConfigPath) {
    Assert-NativeBootConsoleTarget $ScriptPath $TargetName $TargetId
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw '単独起動が設定されていません。' }
    $entry = ([guid]::Parse((Get-Content -LiteralPath $ConfigPath -First 1).Trim())).ToString('B')
    if ($entry -eq [guid]::Empty.ToString('B') -or $entry -notin @(Get-FirmwareEntries | ForEach-Object Guid)) {
        throw '単独起動先を確認できません。'
    }
    $entry
}

if (-not $Setup -and -not $FromCpuConsole -and -not (Test-Path $ConfFile)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "初期設定がまだ済んでいません。`n管理者 PowerShell で次を実行してください:`n`n.\04-reboot-to-field-native.ps1 -Setup",
        "Edge Box 単独起動",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 1
}

if ($Setup) {
    $selected=@(Get-VM -ErrorAction Stop | Where-Object Name -eq $VMName)
    if ($selected.Count -ne 1 -or -not $selected[0].Id -or ($ExpectedVmId -and [string]$selected[0].Id -ne $ExpectedVmId)) {
        throw '対象の Edge Box を一意に確認できません。登録名を -VMName で指定してください。'
    }
    $ExpectedVmId=([guid]$selected[0].Id).ToString('D')
    if (Test-Path $ConfFile) {
        # すでに選択済みなら聞き直さない (アイコン・タスクの作り直しだけ行う)
        Write-Host "起動先は選択済みのため、そのまま使います: $((Get-Content $ConfFile -First 1).Trim())" -ForegroundColor Cyan
        Write-Host "  (選び直したい場合は field-boot-entry.conf を削除してから -Setup を実行)"
    } else {
        Write-Host "UEFI の起動エントリから Edge Box のものを選択します。" -ForegroundColor Cyan
        $entries = Get-FirmwareEntries
        if ($entries.Count -eq 0) {
            Write-Error "ファームウェア起動エントリが見つかりません。'bcdedit /enum firmware' の出力を確認してください。"
            exit 1
        }
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host ("  [{0}] {1}  {2}" -f $i, $entries[$i].Description, $entries[$i].Guid)
        }
        Write-Host ""
        Write-Host "ヒント: Edge Box は 'UEFI OS' や 'ubuntu'、KIOXIA のディスク名などの表記です。"
        Write-Host "        どれか不明な場合は、この一覧を貼り付けて相談してください。"
        # 一覧にある番号だけ受け付ける (空・文字・負数・範囲外は聞き直す。
        # PowerShell では -1 が末尾の要素を指すため、負数も必ず弾く)
        $entry = $null
        while (-not $entry) {
            $sel = (Read-Host "Edge Box の番号 (0-$($entries.Count - 1))").Trim()
            if ($sel -match '^\d+$' -and [int]$sel -lt $entries.Count) {
                $entry = $entries[[int]$sel]
            } else {
                Write-Host "  0 から $($entries.Count - 1) の番号を入力してください。" -ForegroundColor Yellow
            }
        }
        $entry.Guid | Set-Content -Path $ConfFile -Encoding ASCII
        Write-Host "保存しました: $($entry.Description) $($entry.Guid)" -ForegroundColor Green
    }

    # --- UAC 確認なしで実行できるよう、管理者権限付きタスク + それを起動するアイコンを作成 ---
    $taskName = "EdgeBox-Native-Boot"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument (Get-NativeBootTaskArguments $PSCommandPath $VMName $ExpectedVmId)
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    Remove-Item (Join-Path ([Environment]::GetFolderPath("Desktop")) "EdgeBox 単独起動.lnk") -Force -ErrorAction SilentlyContinue   # 旧名のアイコン
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Edge Box 単独起動.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,238"
    $lnk.Description  = "Edge Box をネイティブ単独起動 (次回のみ。次の電源投入では Windows に戻る)"
    $lnk.Save()
    Write-Host "デスクトップに『Edge Box 単独起動』ショートカットを作成しました (UAC 確認なしで実行できます)。" -ForegroundColor Green
    if ($Setup) { exit 0 }
}

if ($FromCpuConsole) {
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $selectedId = [guid]::Empty
        if (-not [guid]::TryParse($ExpectedVmId, [ref]$selectedId) -or $selectedId -eq [guid]::Empty) {
            throw '対象の Edge Box を確認できません。'
        }
        $selected = @(Get-VM -Id $selectedId -ErrorAction Stop)
        if ($selected.Count -ne 1 -or $selected[0].Id -ne $selectedId) { throw '対象の Edge Box を確認できません。' }
        $VMName = [string]$selected[0].Name
        $guid = Get-NativeBootConsoleEntry $PSCommandPath $VMName $ExpectedVmId $ConfFile
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Edge Box 単独起動', 'OK', 'Warning') | Out-Null
        exit 1
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Windows を再起動して『$VMName』を単独起動しますか？", 'Edge Box 単独起動',
        'YesNo', 'Warning', 'Button2')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
} else {
    $guid = ([guid]::Parse((Get-Content $ConfFile -First 1).Trim())).ToString('B')
}

Write-Host "==============================================" -ForegroundColor Yellow
Write-Host " Edge Box を単独起動します (Windows は終了)"
Write-Host "  - 実行中の作業は保存してください"
Write-Host "  - Edge Box の利用終了後、次に電源を入れると Windows に戻ります"
Write-Host "==============================================" -ForegroundColor Yellow
Add-Type -AssemblyName System.Windows.Forms
if (-not $NoConfirm -and -not $FromCpuConsole) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Edge Box を単独起動します (Windows は終了して再起動します)。`n`n" +
        "・実行中の作業は保存してください`n" +
        "・Edge Box の利用終了後、次に電源を入れると自動的に Windows に戻ります`n`n" +
        "実行しますか?",
        "Edge Box 単独起動",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
}

function Get-NativeBootSequence {
    $output=(& bcdedit.exe /enum '{fwbootmgr}' /v | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'UEFI の現在の起動順を確認できません。' }
    if ($output -notmatch '(?im)^\s*bootsequence\b') { return }
    $guidPattern='\{[0-9a-fA-F-]{36}\}'
    $sequence=[regex]::Match($output,"(?im)^[ \t]*bootsequence[ \t]+($guidPattern(?:[ \t]*\r?\n[ \t]+$guidPattern)*)[ \t]*\r?$")
    if (-not $sequence.Success) { throw 'UEFI の次回起動順を読み取れません。' }
    foreach ($id in [regex]::Matches($sequence.Groups[1].Value,$guidPattern)) { ([guid]::Parse($id.Value)).ToString('B') }
}
function Invoke-EdgeBoxNativeRestart([string]$BootEntry,[string]$TargetName,[string]$TargetId) {
    $change=@{Applied=$false;Previous=@()}
    try {
        Invoke-EdgeBoxHostRestart -VMName $TargetName -ExpectedVmId $TargetId -BeforeRestart {
            $change.Previous=@(Get-NativeBootSequence)
            if ($change.Previous.Count -eq 1 -and $change.Previous[0] -eq $BootEntry) { return }
            & bcdedit.exe /set '{fwbootmgr}' bootsequence $BootEntry | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'UEFI の次回起動先を設定できません。' }
            $change.Applied=$true
        }
    } catch {
        $reason=$_.Exception.Message
        if ($change.Applied) {
            $current=@(Get-NativeBootSequence)
            if ($current.Count -ne 1 -or $current[0] -ne $BootEntry) { throw "$reason 次回起動先が変更されています。UEFI 設定を確認してください。" }
            if ($change.Previous.Count) {
                $previous=$change.Previous
                & bcdedit.exe /set '{fwbootmgr}' bootsequence @previous | Out-Null
            } else { & bcdedit.exe /deletevalue '{fwbootmgr}' bootsequence | Out-Null }
            if ($LASTEXITCODE -ne 0) { throw "$reason 次回起動先を元に戻せません。UEFI 設定を確認してください。" }
        }
        throw $reason
    }
}
Import-Module (Join-Path $PSScriptRoot 'vm-shutdown.psm1') -ErrorAction Stop
try {
    if ($FromCpuConsole -and $guid -ne (Get-NativeBootConsoleEntry $PSCommandPath $VMName $ExpectedVmId $ConfFile)) {
        throw '確認中に単独起動先が変更されました。'
    }
    Invoke-EdgeBoxNativeRestart $guid $VMName $ExpectedVmId
}
catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Edge Box 単独起動','OK','Warning') | Out-Null
    exit 1
}
