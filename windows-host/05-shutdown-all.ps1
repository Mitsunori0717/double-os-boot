<#
.SYNOPSIS
    Edge Box を正常終了し、選択した場合は Windows のシャットダウン・再起動を行います。

.DESCRIPTION
    1. Edge Box に ACPI シャットダウン要求を送る (物理機の電源ボタン短押しと同じ)
       → Edge Box 自身が正規の終了処理を実行する
    2. 完全に停止するのを待つ (最大3分)
    3. Windows のシャットダウン・再起動を選んだ場合は、他の VM の停止も確かめて実行する

.EXAMPLE
    .\05-shutdown-all.ps1              # 確認あり
    .\05-shutdown-all.ps1 -NoConfirm   # 操作選択を省略し、Windows のシャットダウンを要求
    .\05-shutdown-all.ps1 -Setup       # デスクトップに『全部シャットダウン』ショートカットを作成
#>
[CmdletBinding()]
param(
    [string]$VMName = "EdgeBox",
    [switch]$NoConfirm,
    [switch]$Setup,
    [ValidateRange(1,1800)][int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"

if ($Setup) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "管理者権限で実行してください (PowerShell を右クリック →『管理者として実行』)。"
        exit 1
    }

    # UAC 確認なしで実行できるよう、管理者権限付きタスク + それを起動するアイコンを作成
    $taskName = "EdgeBox-Shutdown-All"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "全部シャットダウン.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$taskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7   # 最小化 (schtasks の黒い窓を見せない)
    $lnk.IconLocation = "shell32.dll,27"
    $lnk.Description  = "Edge Box を正常終了し、Windows のシャットダウン・再起動または Edge Box のみ終了を選択"
    $lnk.Save()
    Write-Host "デスクトップに『全部シャットダウン』ショートカットを作成しました (UAC 確認なしで実行できます)。" -ForegroundColor Green
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
function Select-ShutdownAction {
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=[Windows.Forms.Form]::new()
    try {
        $form.Text='Edge Box の終了'
        $form.FormBorderStyle='FixedDialog'
        $form.StartPosition='CenterScreen'
        $form.AutoScaleMode='Dpi'
        $form.MaximizeBox=$false
        $form.MinimizeBox=$false
        $form.ClientSize=[Drawing.Size]::new(390,233)
        $label=[Windows.Forms.Label]::new()
        $label.Text='Edge Box の正常終了後に行う操作を選んでください。'
        $label.SetBounds(16,15,360,24)
        $form.Controls.Add($label)
        $choices=[ordered]@{
            Shutdown='Windows をシャットダウン'
            Restart='Windows を再起動'
            GuestOnly='Edge Box だけ終了'
            Cancel='キャンセル'
        }
        $y=44
        foreach ($key in $choices.Keys) {
            $button=[Windows.Forms.Button]::new()
            $button.Text=$choices[$key]
            $button.Tag=$key
            $button.SetBounds(16,$y,358,37)
            $button.Add_Click({$window=$this.FindForm(); $window.Tag=$this.Tag; $window.Close()})
            $form.Controls.Add($button)
            $y+=45
            if ($key -eq 'Cancel') { $form.CancelButton=$button; $form.ActiveControl=$button }
        }
        $null=$form.ShowDialog()
        return $form.Tag
    } finally { $form.Dispose() }
}
$shutdownChoice=if ($NoConfirm) { 'Shutdown' } else { Select-ShutdownAction }
if ($shutdownChoice -notin @('Shutdown','Restart','GuestOnly')) { exit 0 }
$shutdownWindows=$shutdownChoice -in @('Shutdown','Restart')

Import-Module (Join-Path $PSScriptRoot 'vm-shutdown.psm1') -Force
$shutdownLog = Join-Path $PSScriptRoot 'shutdown-log.txt'
function Write-ShutdownLog([string]$Message) {
    Write-Host $Message
    try { Add-Content -LiteralPath $shutdownLog -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$Message) } catch { }
}
function Assert-ShutdownTargetOff([string]$ExpectedVmId,[switch]$WholeHost) {
    if ([string]::IsNullOrWhiteSpace($ExpectedVmId)) { throw '停止対象の Edge Box の ID を確認できません。' }
    if ($WholeHost) {
        $all=@(Get-VM -ErrorAction Stop)
        $active=@($all | Where-Object { [string]$_.Id -ne $ExpectedVmId -and $_.State -ne 'Off' })
        if ($active.Count) { throw "VM '$($active[0].Name)' の状態は $($active[0].State) です。Windows の終了を保留します。" }
        $matches=@($all | Where-Object { [string]$_.Id -eq $ExpectedVmId })
    } else { $matches=@(Get-VM -Id $ExpectedVmId -ErrorAction Stop) }
    if ($matches.Count -ne 1 -or [string]$matches[0].Id -ne $ExpectedVmId -or [string]$matches[0].Name -ne $VMName -or [string]$matches[0].State -ne 'Off') {
        throw '選択した Edge Box の停止を再確認できません。Windows の終了を中止します。'
    }
}
function Invoke-ConfirmedWindowsShutdown([string]$ExpectedVmId,[switch]$Restart) {
    Assert-ShutdownTargetOff $ExpectedVmId -WholeHost
    # /t > 0 は強制終了を伴うため、手動で選択した操作を待ち時間 0 で要求する。
    if ($Restart) {
        Write-ShutdownLog 'Windows へ手動の再起動を要求します。'
        shutdown.exe /r /t 0 /c "Edge Box の停止を確認しました。保守担当者が Windows の再起動を選択しました。"
    } else {
        Write-ShutdownLog 'Windows へ通常のシャットダウンを要求します。'
        shutdown.exe /s /t 0 /c "Edge Box の停止を確認しました。Windows をシャットダウンします。"
    }
    if ($LASTEXITCODE -ne 0) { throw ('Windows の終了要求に失敗。終了コード: '+$LASTEXITCODE) }
}
Write-ShutdownLog '===== 終了開始 ====='
$operationTime=[Diagnostics.Stopwatch]::StartNew()
function Test-ShutdownConsoleTarget([string]$CommandLine,$VM) {
    $hostPattern='(?:localhost|\.|'+[regex]::Escape($env:COMPUTERNAME)+')'
    $name=[regex]::Escape([string]$VM.Name)
    $id=[regex]::Escape([string]$VM.Id)
    $namePattern='"'+$name+'"'
    if ($VM.Name -notmatch '\s') { $namePattern+='|'+$name }
    $target='(?:'+$namePattern+'|-G\s+"?\{?'+$id+'\}?"?)'
    return $CommandLine -match ('^\s*(?:"[^"]+"|\S+)\s+(?:"'+$hostPattern+'"|'+$hostPattern+')\s+'+$target+'(?=\s|$)')
}
function Close-ShutdownConsole($VM) {
    $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
    $views=@(Get-Process -Name vmconnect -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session)
    if (-not $views.Count) { return }
    foreach ($entry in @(Get-CimInstance Win32_Process -Filter "Name='vmconnect.exe' AND SessionId=$session" -ErrorAction SilentlyContinue)) {
        if (Test-ShutdownConsoleTarget $entry.CommandLine $VM) {
            $view=$views | Where-Object Id -eq $entry.ProcessId
            if ($view) { try { [void]$view.CloseMainWindow() } catch {} }
        }
    }
}
try {
    $nextAction=switch ($shutdownChoice) {
        Shutdown { '停止を確認すると Windows をシャットダウンします。' }
        Restart  { '停止を確認すると Windows を再起動します。' }
        GuestOnly { '停止を確認すると完了を表示します。Windows は引き続き使えます。' }
    }
    $shutdownVmId=Wait-EdgeBoxShutdown -VMName $VMName -TimeoutSec $TimeoutSec -PassThruId -ManualStop -NextAction $nextAction -Log {param($m) Write-ShutdownLog $m} -AfterRequest {param($target) Close-ShutdownConsole $target}
    Assert-ShutdownTargetOff $shutdownVmId
} catch {
    Write-ShutdownLog ('失敗: '+$_.Exception.Message)
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Edge Box の終了を中止しました', 'OK', 'Warning') | Out-Null
    exit 1
}

# --- 停止中のいまのうちに、予約していた入出力の設定 (メモリの固定など) を反映しておく ---
$s11 = Join-Path $PSScriptRoot "11-io-passthrough.ps1"
if ((Test-Path -LiteralPath (Join-Path $PSScriptRoot 'io-pending.json')) -and (Test-Path -LiteralPath $s11)) {
    try { & $s11 -VMName $VMName -ApplyPending } catch { Write-ShutdownLog ('入出力設定の反映を保留: '+$_.Exception.Message) }
}

# --- 停止中のいまのうちに、『Edge Box表示設定』のコンソール解像度を反映しておく ---
# (Edge Box は Windows 起動時に自動起動するため、解像度変更はここが唯一の機会)
try {
    $cfgFile = Join-Path $PSScriptRoot "display-config.json"
    if (Test-Path -LiteralPath $cfgFile) {
        $resText = [string](Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).ConsoleResolution
        $rw = 0; $rh = 0
        if ($resText -match '^(auto|自動)' -or -not $resText) {
            $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
            $rw = $b.Width; $rh = $b.Height
        } elseif ($resText -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
            $rw = [int]$Matches[1]; $rh = [int]$Matches[2]
        }
        if ($rw -gt 0) {
            $current=Get-VM -Id $shutdownVmId -ErrorAction Stop
            if ($current.State -eq 'Off' -and $current.Name -eq $VMName) {
                $video=Get-VMVideo -VM $current -ErrorAction Stop
                if ($video.ResolutionType -ne 'Single' -or $video.HorizontalResolution -ne $rw -or $video.VerticalResolution -ne $rh) {
                    Set-VMVideo -VM $current -ResolutionType Single -HorizontalResolution $rw -VerticalResolution $rh -ErrorAction Stop
                }
            }
        }
    }
} catch { Write-ShutdownLog ('解像度の反映を保留: '+$_.Exception.Message) }

if ($shutdownWindows) {
    Write-ShutdownLog ('開始から Windows 終了要求直前まで: {0:N1} 秒' -f $operationTime.Elapsed.TotalSeconds)
    try { Invoke-ConfirmedWindowsShutdown $shutdownVmId -Restart:($shutdownChoice -eq 'Restart') }
    catch {
        Write-ShutdownLog ('失敗: '+$_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Edge Box の終了を中止しました', 'OK', 'Warning') | Out-Null
        exit 1
    }
} else {
    try { Assert-ShutdownTargetOff $shutdownVmId }
    catch {
        Write-ShutdownLog ('失敗: '+$_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Edge Box の終了を確認できません','OK','Warning') | Out-Null
        exit 1
    }
    Write-ShutdownLog ('Edge Box の終了完了: 開始から {0:N1} 秒' -f $operationTime.Elapsed.TotalSeconds)
    [System.Windows.Forms.MessageBox]::Show("Edge Box のみ終了しました。Windows はそのまま使えます。","Edge Box の終了") | Out-Null
}
