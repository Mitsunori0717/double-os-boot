#requires -Version 5.1
# Exercise the SCM transformation and policy orchestration without touching live services or tasks.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../service-restart-policy.psm1') -Force -PassThru
& $module {
    function Check($condition, $message) { if (-not $condition) {throw $message} }
    Initialize-ServiceRecoveryApi
    function New-State([int[]]$types) {
        $state=New-Object EdgeBox.ServiceRecoveryState
        $state.ResetPeriod=[uint32]::MaxValue
        $state.Types=$types
        $state.Delays=[uint32[]]@(foreach ($i in 1..$types.Count) { $i * 1000 })
        $state.MessageAndCommandDigest='fixture'; $state.ServiceIdentityDigest='fixture-identity'
        $state
    }
    $wanted=New-State @(2,3,2,1,0)
    $read=New-State @(2,3,2,1,0)
    $types=[EdgeBox.ServiceRecovery]::GetReplacementTypes($read,$wanted)
    Check (($types -join ',') -eq '1,3,1,1,0') 'native conversion changes only host reboot actions'
    $read.Delays[1]++
    $refused=$false
    try { [void][EdgeBox.ServiceRecovery]::GetReplacementTypes($read,$wanted) } catch { $refused=$true }
    Check $refused 'concurrent change must cancel apply'

    function New-Task($name, $arguments, $triggers) {
        [pscustomobject]@{TaskPath='\';TaskName=$name;Settings=@{Enabled=$true};Triggers=$triggers;Actions=@(@{Execute='shutdown.exe';Arguments=$arguments})}
    }
    function Get-ScheduledTask {
        New-Task 'automatic' '/r /t 0' @(@{Enabled=$true})
        New-Task 'demand-reboot' '/r /t 0' @()
        New-Task 'disabled-trigger' '/r /t 0' @(@{Enabled=$false})
        New-Task 'remote' '/r /m \\server' @(@{Enabled=$true})
        New-Task 'logoff' '/l' @(@{Enabled=$true})
    }
    Check ((@(Get-AutomaticRestartTaskReview) -join ',') -ceq '\automatic') 'only enabled local automatic restart is flagged'
    & {
        $script:taskBackup=$null; $script:approvedTask=$null; $script:taskXml='<Task><Triggers><BootTrigger/></Triggers><Actions><Exec/></Actions></Task>'; $script:setCalls=0
        $task=New-Task 'dedicated fixture' '/r /t 30' @([pscustomobject]@{Enabled=$true})
        $task.Actions[0].Execute=Join-Path $env:SystemRoot 'System32\shutdown.exe'
        $task.Settings.AllowDemandStart=$true
        function Export-ScheduledTask { $script:taskXml }
        function Get-ScheduledTask {$task}
        function Save-PolicyBackup($category,$name,$record) {
            if ($category -eq 'ApprovedTask') { $script:approvedTask=$record; return }
            Check ($category -eq 'TaskTriggerBackup' -and $name -eq '\dedicated fixture') 'backup category and original task identity'
            $script:taskBackup=$record
        }
        function Test-PolicyApproval($kind,$name,$record) { $kind -eq 'Task' -and $script:approvedTask -ceq $record }
        function Set-ScheduledTask($TaskName,$TaskPath,$Trigger) {
            Check ($script:taskBackup -eq '<Task><Triggers><BootTrigger/></Triggers><Actions><Exec/></Actions></Task>') 'original registration saved before task change'
            $script:setCalls++
            $task.Triggers=$Trigger
        }
        $issues=New-Object 'System.Collections.Generic.List[string]'
        $toReview=@(Get-AutomaticRestartTaskReview -Apply -TaskErrors $issues)
        Check ($script:setCalls -eq 1 -and $issues.Count -eq 0 -and $toReview.Count -eq 0 -and $task.Settings.AllowDemandStart -and -not $task.Triggers[0].Enabled) 'disable only automatic trigger and retain demand start'
        $task.Triggers[0].Enabled=$true
        $script:taskXml='<Task><Actions><Other/></Actions></Task>'
        $toReview=@(Get-AutomaticRestartTaskReview -Apply -PreviouslyVerifiedOnly -TaskErrors $issues)
        Check ($script:setCalls -eq 1 -and $task.Triggers[0].Enabled -and $toReview.Count -eq 1) 'changed task identity cannot be enforced in maintenance'
        $script:taskXml='<Task><Triggers><BootTrigger/></Triggers><Actions><Exec/></Actions></Task>'
        [void](Get-AutomaticRestartTaskReview -Apply -PreviouslyVerifiedOnly -TaskErrors $issues)
        Check ($script:setCalls -eq 2 -and -not $task.Triggers[0].Enabled) 'exact previously approved original task can be maintained'
    }
    $script:services=@{A=(New-State @(2,3,2,0));B=(New-State @(2));OK=(New-State @(1,0))}
    $script:backups=@{}; $script:approved=@{}; $script:attempts=0
    function Get-RecoveryServiceNames { $script:services.Keys }
    function Read-RecoveryService($name) { $script:services[$name] }
    function Test-PolicyApproval($kind,$name,$record) { $kind -eq 'Service' -and $script:approved[$name] -ceq $record }
    function Save-PolicyBackup($category,$name,$record) {
        if ($category -eq 'ApprovedService') { $script:approved[$name]=$record; return }
        Check (-not $script:backups.ContainsKey($name) -or $script:backups[$name] -ceq $record) 'original backup stays identical'
        $script:backups[$name]=$record
    }
    function Set-RecoveryService($name,$state) {
        Check ($script:backups.ContainsKey($name)) 'backup must exist before any SCM write'
        $script:attempts++
        if ($name -eq 'B') { throw 'protected' }
        $script:services[$name]=New-State ([EdgeBox.ServiceRecovery]::GetReplacementTypes($script:services[$name],$state))
    }
    $before=Get-EdgeBoxServiceRestartPolicy
    Check (-not $before.Compliant -and $before.RebootServices.Count -eq 2 -and $script:backups.Count -eq 0 -and $script:attempts -eq 0) 'status only reads'
    $done=Invoke-ServiceRestartPolicy -Apply
    Check (($done.RebootServices -join ',') -eq 'B' -and $done.Errors.Count -eq 2 -and $done.ReviewTasks.Count -eq 1) 'protected services and ambiguous tasks remain visible'
    Check (($script:services.A.Types -join ',') -eq '1,3,1,0') 'mixed sequence remains intact'
    $originalBackup=$script:backups.A
    [void](Invoke-ServiceRestartPolicy -Apply)
    Check ($script:backups.A -ceq $originalBackup -and $script:attempts -eq 3) 'repeated apply retains original baseline'
    $script:services.A=New-State @(2,3,2,0)
    $script:services.A.ServiceIdentityDigest='replacement-service'
    [void](Invoke-ServiceRestartPolicy -Apply -PreviouslyVerifiedOnly)
    Check ($script:attempts -eq 3 -and $script:services.A.Types[0] -eq 2 -and -not $script:approved.ContainsKey('B')) 'new identity and forbidden original are not pre-approved'
    $script:services.A.ServiceIdentityDigest='fixture-identity'
    [void](Invoke-ServiceRestartPolicy -Apply -PreviouslyVerifiedOnly)
    Check ($script:attempts -eq 4 -and $script:services.A.Types[0] -eq 1 -and $script:services.B.Types[0] -eq 2) 'maintenance can reapply only a previously successful identical registration'
    $script:services.Remove('B')
    function Get-ScheduledTask {}
    Check (-not (Get-EdgeBoxServiceRestartPolicy).Compliant) 'external failure command remains explicitly unverified'
    $script:services.A=New-State @(1,0)
    Check (Get-EdgeBoxServiceRestartPolicy).Compliant 'confirmed compliant after verified repair'
    $script:services.A=New-State @(2,3,2,0)
    function Set-RecoveryService($name,$state) { } # simulate successful API call without effect
    Check (-not (Invoke-ServiceRestartPolicy -Apply).Compliant) 'unverified post-write state must fail'
    function Get-RecoveryServiceNames { throw 'unreadable SCM' }
    Check (-not (Get-EdgeBoxServiceRestartPolicy).Compliant) 'enumeration failure must not be success'
}
Write-Output 'PASS service recovery and scheduled restart checks with mock OS interfaces'
