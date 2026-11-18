#requires -Version 5.1
# Real safety predicates with mocked operating-system reads. No host/VM changes.
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxSafetyTests_'+[guid]::NewGuid().ToString('N'))
$module=$null
try {
    New-Item -ItemType Directory -Path (Join-Path $temp 'setup') -Force | Out-Null
    foreach ($name in @('setup-engine.psm1','setup-all.ps1','run-child.ps1')) {
        Copy-Item -LiteralPath (Join-Path $project ('setup\'+$name)) -Destination (Join-Path $temp ('setup\'+$name))
    }
    $module=Import-Module (Join-Path $temp 'setup\setup-engine.psm1') -PassThru -Force
    & $module {
        function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
        function Assert-Throws([scriptblock]$Action,[string]$Message) {
            $failed=$false
            try { & $Action | Out-Null } catch { $failed=$true }
            Assert $failed $Message
        }
        function Test-SetupAdmin { $true }
        $script:MockVm=[pscustomobject]@{Name='OtherProductionVm';Id='original-vm';State='Off';AutomaticStopAction='ShutDown';CheckpointType='Disabled'}
        $script:MockDisk=[pscustomobject]@{Number=7;UniqueId='disk-original';IsBoot=$false;IsSystem=$false;IsOffline=$true;BusType='SATA'}
        $script:MockSwitch=[pscustomobject]@{Id='switch-original';Name='Production';SwitchType='External';NetAdapterInterfaceGuid='nic-original'}
        $script:MockPartitions=@()
        $script:SaveCalls=0
        function Get-VM { $script:MockVm }
        function Get-VMHardDiskDrive { [pscustomobject]@{DiskNumber=7} }
        function Get-Disk { $script:MockDisk }
        function Get-Partition {
            param($DriveLetter,$DiskNumber)
            if ($DriveLetter) { [pscustomobject]@{DiskNumber=0} } else { $script:MockPartitions }
        }
        function Get-VMNetworkAdapter { [pscustomobject]@{SwitchName='Production'} }
        function Get-VMSwitch { $script:MockSwitch }
        function Get-VMFirmware { [pscustomobject]@{SecureBoot='Off'} }
        function Save-SetupSettings { $script:SaveCalls++ }
        function Set-Disk { throw 'Tests must never change disks' }
        function Set-VM { throw 'Tests must never change VMs' }
        function Set-VMFirmware { throw 'Tests must never change firmware' }
        function New-VMSwitch { throw 'Tests must never change networking' }
        function Restart-Computer { throw 'Tests must never restart the host' }
        function Register-ScheduledTask { throw 'Tests must never register real tasks' }
        function Unregister-ScheduledTask { throw 'Tests must never remove real tasks' }

        $script:Settings=@{}
        Assert-Throws { Get-SetupVM } 'an unrelated passthrough VM must never be adopted automatically'
        $script:MockVm.Name='EdgeBox'
        Assert-Throws { Get-SetupVM } 'the default name alone must not authorize adoption of an existing VM'
        $script:Settings=@{VMName='EdgeBox'}
        Assert ((Get-SetupVM).Id -eq 'original-vm') 'an explicitly selected existing VM remains supported'
        Assert ($script:Settings.VMId -eq 'original-vm') 'the selected VM must be bound to its persistent ID'
        $script:MockVm.Id='replacement-vm'
        Assert-Throws { Get-SetupVM } 'a same-name replacement VM must not be adopted'
        $script:MockVm.Id='original-vm'
        $script:Settings=@{VMName='EdgeBox';VMId='original-vm';DiskUniqueId='disk-expected'}
        Assert ((Get-SetupStepState '05').State -eq 'Unknown') 'a mismatched saved disk ID must not be reported as done or repaired'
        Assert-Throws { Resolve-SetupDisk $script:MockVm } 'an attached disk must not override the saved disk identity'
        Assert ($script:SaveCalls -eq 0) 'a disk mismatch must not overwrite saved identity'
        $script:Settings.DiskUniqueId='disk-original'
        $script:Settings.SwitchId='switch-expected'
        Assert ((Get-SetupStepState '05').State -eq 'Unknown') 'a different external switch must not satisfy saved network identity'
        Assert-Throws { Resolve-SetupSwitch } 'a missing saved switch must not be replaced automatically'
        $script:Settings.SwitchId='switch-original'
        $script:Settings.NetAdapterGuid='nic-expected'
        Assert ((Get-SetupStepState '05').State -eq 'Unknown') 'a changed switch-to-NIC binding must not be reported as done'
        $script:Settings.NetAdapterGuid='nic-original'
        Assert ((Get-SetupStepState '05').State -eq 'Done') 'matching VM, disk, switch and NIC identities must still pass'
        $script:MockDisk.Number=23
        Assert ((Resolve-SetupDisk $null).Number -eq 23) 'saved unique disk identity must survive disk-number changes'
        $script:MockDisk.Number=7
        $script:MockPartitions=@([pscustomobject]@{DriveLetter='';AccessPaths=@('C:\MountedData\')})
        Assert-Throws { Resolve-SetupDisk $script:MockVm } 'folder mounts must block taking a selected disk offline'
        $script:MockPartitions=@([pscustomobject]@{DriveLetter='R';AccessPaths=@('R:\')})
        Assert-Throws { Resolve-SetupDisk $script:MockVm } 'saved disk identity does not permit taking mounted data volumes offline'
        Assert (-not (Test-SetupMountedPartition ([pscustomobject]@{DriveLetter='';AccessPaths=@('\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\')}))) 'a volume GUID path alone is not a user mount point'
        $script:MockPartitions=@()
        $script:MockDisk.UniqueId=''
        Assert-Throws { Resolve-SetupDisk $script:MockVm } 'blank disk identifiers must be rejected'
        Write-Host 'PASS: real VM/disk/network identity checks and mounted-disk guards'

        # Test the actual missing-file predicate before any OS or setup operation.
        $script:Applied=0
        function Get-SetupStepState { throw 'preflight must run before any OS inspection' }
        function Invoke-SetupStep { $script:Applied++ }
        $missing=@(Get-SetupMissingFiles 'All')
        Assert ('windows-host\01-create-field-vm.ps1' -in $missing) 'incomplete distributions must name missing source files'
        Assert (-not @($missing | Where-Object { $_ -like '*CpuGroups.exe' }).Count) 'downloaded tools must not be required in source distributions'
        Assert ((Invoke-EdgeBoxSetup -NoConfirm) -eq 1) 'incomplete all-steps packages must stop before applying Hyper-V'
        Assert ((Invoke-EdgeBoxSetup -Status) -eq 2) 'status must expose incomplete packages without applying changes'
        Assert ($script:Applied -eq 0) 'package failure must not apply any setup step'
        Assert (-not (Test-Path (Join-Path $script:Root 'setup\logs'))) 'preflight failure must not create setup logs'
        Assert (@(Get-SetupMissingFiles '02').Count -eq 0) 'numbered Hyper-V inspection must not depend on unrelated modules'
        Write-Host 'PASS: incomplete-package preflight, read-only status and numbered dependencies'
        function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
        function New-ScheduledTaskPrincipal { [pscustomobject]@{} }
        function New-ScheduledTaskTrigger { [pscustomobject]@{Delay=''} }
        function New-ScheduledTaskSettingsSet { [pscustomobject]@{} }
        function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force) $script:ResumeArguments=$Action.Arguments }
        Register-SetupResume 'All'
        Assert ($script:ResumeArguments -notmatch '-RestartIfNeeded') 'real resume task arguments must preserve manual restart mode'
        Register-SetupResume 'All' -RestartIfNeeded
        Assert ($script:ResumeArguments -match '-RestartIfNeeded') 'explicit automatic restart mode must remain supported'
        Write-Host 'PASS: real resume task arguments preserve restart preference'
    }
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'EdgeBoxSafetyTests_*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
