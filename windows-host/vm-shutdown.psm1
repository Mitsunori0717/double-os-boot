#requires -Version 5.1
function Wait-EdgeBoxShutdown {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$VMName,
          [ValidateRange(1,1800)][int]$TimeoutSec=180,
          [scriptblock]$Log={param($m) Write-Host $m},
          [scriptblock]$AfterRequest={})
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $job=$null
    try {
        $vm=Get-VM -Name $VMName -ErrorAction Stop
        $state=[string]$vm.State
        if ($state -eq 'Off') { & $Log 'Edge Box は停止済みです。'; return }
        if ($state -notin @('Running','Stopping')) { throw "VM の状態は $state です。Hyper-V マネージャーで状態を確認し、正常終了してください。" }
        if ($state -eq 'Running') {
            & $Log 'Edge Box へ正常終了を要求します。'
            # 同期 Stop-VM では呼出し自体の待ち時間が上限に含まれなかった。要求時から計測する。
            $job=Stop-VM -Name $VMName -AsJob -Confirm:$false -ErrorAction Stop
        }
        & $AfterRequest
        do {
            if ([string](Get-VM -Name $VMName -ErrorAction Stop).State -eq 'Off') {
                & $Log ('Edge Box の停止を確認: {0:N1} 秒' -f $watch.Elapsed.TotalSeconds)
                return
            }
            if ($job -and $job.State -eq 'Failed') { Receive-Job $job -ErrorAction Stop | Out-Null; throw 'Hyper-V が正常終了要求を受け付けませんでした。' }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "Edge Box が $TimeoutSec 秒以内に停止しませんでした。Windows の終了を中止します。FSBP の管理画面で停止状況を確認してください（強制電源断はしません）。" }
            Start-Sleep -Milliseconds 500
        } while ($true)
    } finally {
        if ($job) {
            # 管理ジョブの監視だけを終える。VM の電源断・vmwp の強制終了は行わない。
            if ($job.State -in @('Running','NotStarted')) { Stop-Job $job -ErrorAction SilentlyContinue }
            Remove-Job $job -ErrorAction SilentlyContinue
        }
    }
}
Export-ModuleMember -Function Wait-EdgeBoxShutdown
