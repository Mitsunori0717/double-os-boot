#requires -Version 5.1
function New-EdgeBoxShutdownProgressForm([string]$NextAction) {
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=[Windows.Forms.Form]::new()
    $form.Text='Edge Box の終了'
    $form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $form.TopMost=$true
    $form.AutoScaleMode='Dpi'
    $form.ClientSize=[Drawing.Size]::new(480,148)
    $title=[Windows.Forms.Label]::new()
    $title.Text='Edge Box を終了しています'
    $title.Font=[Drawing.Font]::new('Meiryo UI',13,[Drawing.FontStyle]::Bold)
    $title.SetBounds(16,14,448,32)
    $next=[Windows.Forms.Label]::new()
    $next.Text=$NextAction
    $next.SetBounds(17,52,446,30)
    $bar=[Windows.Forms.ProgressBar]::new()
    $bar.Style='Marquee'
    $bar.SetBounds(17,88,446,12)
    $elapsed=[Windows.Forms.Label]::new()
    $elapsed.Name='Elapsed'
    $elapsed.SetBounds(17,113,446,24)
    $elapsed.Text='経過 0 秒'
    $form.Controls.AddRange(@($title,$next,$bar,$elapsed))
    return $form
}
function Show-EdgeBoxShutdownProgress([string]$EventName,[int]$ParentId,[long]$Started,[string]$NextAction) {
    $signal=$null; $parent=$null; $form=$null; $timer=$null
    try {
        $signal=[Threading.EventWaitHandle]::OpenExisting($EventName)
        $parent=[Diagnostics.Process]::GetProcessById($ParentId)
        if ($signal.WaitOne(0) -or $parent.HasExited) { return }
        $form=New-EdgeBoxShutdownProgressForm $NextAction
        $elapsed=$form.Controls['Elapsed']
        $timer=[Windows.Forms.Timer]::new()
        $timer.Interval=200
        $timer.Add_Tick({
            if ($signal.WaitOne(0) -or $parent.HasExited) { $form.Close(); return }
            $seconds=([Diagnostics.Stopwatch]::GetTimestamp()-$Started)/[Diagnostics.Stopwatch]::Frequency
            $elapsed.Text='経過 '+[int][Math]::Floor($seconds)+' 秒'
        })
        $timer.Start()
        if (-not $signal.WaitOne(0)) { [Windows.Forms.Application]::Run($form) }
    } catch {
        # A finished request or noninteractive desktop needs no progress window.
    } finally {
        foreach ($resource in @($timer,$form,$parent,$signal)) { if ($resource) { $resource.Dispose() } }
    }
}
function Start-EdgeBoxShutdownProgress([string]$NextAction) {
    $signal=$null
    try {
        if (-not $NextAction -or -not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { return }
        $name='Local\EdgeBoxShutdown-'+[guid]::NewGuid().ToString('N')
        $signal=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$name)
        $body=${function:Show-EdgeBoxShutdownProgress}.ToString()
        $formBody=${function:New-EdgeBoxShutdownProgressForm}.ToString()
        $command="function New-EdgeBoxShutdownProgressForm { $formBody }; & { $body } '$name' $PID $([Diagnostics.Stopwatch]::GetTimestamp()) '$($NextAction.Replace("'","''"))'"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process $exe -ArgumentList @('-NoProfile','-NonInteractive','-STA','-EncodedCommand',$encoded) -WindowStyle Hidden -ErrorAction Stop
        return $signal
    } catch { if ($signal) { $signal.Dispose() } }
}
function Wait-EdgeBoxShutdown {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VMName,
          [string]$ExpectedVmId='',
          [ValidateRange(1,1800)][int]$TimeoutSec=180,
          [scriptblock]$Log={param($m) Write-Host $m},
          [scriptblock]$AfterRequest={}, [string]$NextAction, [switch]$PassThruId, [switch]$ManualStop)
    $job=$null; $progress=$null
    try {
        if ($NextAction) { $progress=Start-EdgeBoxShutdownProgress $NextAction }
        $matches=@(Get-VM -ErrorAction Stop | Where-Object { $_.Name -eq $VMName })
        if($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$matches[0].Id)){throw '対象の Edge Box を一意に確認できません。'}
        $vm=$matches[0];$vmId=[string]$vm.Id
        if($ExpectedVmId -and $vmId -ne $ExpectedVmId){throw '選択した Edge Box の ID が変わりました。終了を中止します。'}
        $state=[string]$vm.State
        if ($state -notin @('Running','Stopping','Off')) { throw "VM の状態は $state です。Hyper-V マネージャーで状態を確認し、正常終了してください。" }
        if ($ManualStop) {
            $cpu=Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-cpu-partition'
            if (Test-Path -LiteralPath (Join-Path $cpu 'cpu-partition.json')) {
                Import-Module (Join-Path $cpu 'cpu-tool.psm1') -ErrorAction Stop
                Set-EdgeBoxManualCpuStop -VM $vm
                # A CPU task that already owned the plan lock may have started this guest.
                $current=@(Get-VM -Id $vmId -ErrorAction Stop)
                if ($current.Count -ne 1 -or [string]$current[0].Id -ne $vmId -or $current[0].Name -ne $VMName) { throw '手動停止の準備中に対象 VM が変わりました。' }
                $vm=$current[0]; $state=[string]$vm.State
                if ($state -notin @('Off','Running','Stopping')) { throw "対象 VM の状態は $state です。正常終了できません。" }
            }
        }
        if ($state -eq 'Off') { & $Log 'Edge Box は停止済みです。'; if ($PassThruId) { $vmId }; return }
        $watch=[Diagnostics.Stopwatch]::StartNew()
        if ($state -eq 'Running') {
            & $Log 'Edge Box へ正常終了を要求します。'
            # 同期 Stop-VM では呼出し自体の待ち時間が上限に含まれなかった。要求時から計測する。
            $job=Stop-VM -VM $vm -AsJob -Confirm:$false -ErrorAction Stop
        }
        & $AfterRequest $vm
        do {
            $observed=@(Get-VM -Id $vmId -ErrorAction Stop)
            if($observed.Count -ne 1 -or [string]$observed[0].Id -ne $vmId){throw '停止待機中に Edge Box の ID を確認できなくなりました。Windows の終了を中止します。'}
            if ([string]$observed[0].State -eq 'Off') {
                & $Log ('Edge Box の停止を確認: {0:N1} 秒' -f $watch.Elapsed.TotalSeconds)
                if ($PassThruId) { $vmId }
                return
            }
            if ($job -and $job.State -eq 'Failed') { Receive-Job $job -ErrorAction Stop | Out-Null; throw 'Hyper-V が正常終了要求を受け付けませんでした。' }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "Edge Box が $TimeoutSec 秒以内に停止しませんでした。Windows の終了を中止します。Edge Box の管理画面で停止状況を確認してください（強制電源断はしません）。" }
            Start-Sleep -Milliseconds 500
        } while ($true)
    } finally {
        if ($progress) { try { $null=$progress.Set() } catch {} finally { $progress.Dispose() } }
        if ($job) {
            # 管理ジョブの監視だけを終える。VM の電源断・vmwp の強制終了は行わない。
            if ($job.State -in @('Running','NotStarted')) { Stop-Job $job -ErrorAction SilentlyContinue }
            Remove-Job $job -ErrorAction SilentlyContinue
        }
    }
}
function Invoke-EdgeBoxHostRestart {
    [CmdletBinding()]
    param([string]$VMName, [string]$ExpectedVmId,
          [scriptblock]$BeforeRestart={})
    if ($ExpectedVmId -and -not $VMName) { throw '再起動前に停止対象の VM 名を確認してください。' }
    $vms=@(Get-VM -ErrorAction Stop)
    $targetId=$null
    if ($VMName) {
        $target=@($vms | Where-Object Name -eq $VMName)
        if ($target.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$target[0].Id) -or
            ($ExpectedVmId -and [string]$target[0].Id -ne $ExpectedVmId)) { throw '再起動前に対象の Edge Box の ID を確認できません。' }
        $targetId=[string]$target[0].Id
    }
    foreach ($vm in $vms) {
        if ($vm.State -ne 'Off' -and (-not $targetId -or [string]$vm.Id -ne $targetId)) {
            throw "VM '$($vm.Name)' の状態は $($vm.State) です。正常終了してから再実行してください。"
        }
    }
    if ($targetId) { Wait-EdgeBoxShutdown -VMName $VMName -ExpectedVmId $targetId -NextAction '停止を確認すると Windows を再起動します。' }
    & $BeforeRestart
    $vms=@(Get-VM -ErrorAction Stop)
    if (($targetId -and @($vms | Where-Object { $_.Name -eq $VMName -and [string]$_.Id -eq $targetId }).Count -ne 1) -or
        @($vms | Where-Object { $_.State -ne 'Off' }).Count) { throw 'Windows の再起動直前に VM の停止を再確認できません。' }
    Restart-Computer -ErrorAction Stop
}
Export-ModuleMember -Function Wait-EdgeBoxShutdown,Invoke-EdgeBoxHostRestart
