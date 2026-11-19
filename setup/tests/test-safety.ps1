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
        param($ProjectRoot)
        function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
        function Assert-Throws([scriptblock]$Action,[string]$Message) {
            $failed=$false
            try { & $Action | Out-Null } catch { $failed=$true }
            Assert $failed $Message
        }
        function Test-SetupAdmin { $true }
        $script:MockVm=[pscustomobject]@{Name='OtherProductionVm';Id='original-vm';State='Off';AutomaticStopAction='ShutDown';CheckpointType='Disabled'}
        $script:MockDisk=[pscustomobject]@{Number=7;UniqueId='disk-original';IsBoot=$false;IsSystem=$false;IsOffline=$true;BusType='SATA'}
        $script:MockSwitch=[pscustomobject]@{Id='switch-original';Name='Production';SwitchType='External';NetAdapterInterfaceGuid=[guid[]]@('11111111-1111-1111-1111-111111111111')}
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
        $script:Settings.NetAdapterGuid='{22222222-2222-2222-2222-222222222222}'
        Assert ((Get-SetupStepState '05').State -eq 'Unknown') 'a changed switch-to-NIC binding must not be reported as done'
        $script:Settings.NetAdapterGuid='{11111111-1111-1111-1111-111111111111}'
        Assert ((Get-SetupStepState '05').State -eq 'Done') 'matching VM, disk, switch and NIC identities must still pass'
        $script:Settings.Remove('SwitchId')
        Assert ((Resolve-SetupSwitch).SwitchName -eq 'Production') 'a saved brace-wrapped NIC GUID must match Hyper-V Guid[] bindings'
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
        $createAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'windows-host\01-create-field-vm.ps1'),[ref]$null,[ref]$null)
        foreach ($helperName in @('ConvertTo-CreateNicGuid','Get-SwitchByPhysicalNic')) {
            $helper=@($createAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName},$true))
            Assert ($helper.Count -eq 1) 'VM creation NIC helpers must be uniquely identifiable'
            . ([scriptblock]::Create($helper[0].Extent.Text))
        }
        $nic=[pscustomobject]@{InterfaceGuid='{11111111-1111-1111-1111-111111111111}'}
        Assert ((Get-SwitchByPhysicalNic $nic).Id -eq 'switch-original') 'VM creation must reuse a Guid[]-bound switch for the same brace-wrapped NIC'
        $nic.InterfaceGuid='{22222222-2222-2222-2222-222222222222}'
        Assert ($null -eq (Get-SwitchByPhysicalNic $nic)) 'normalization must not merge different physical NIC identities'
        Assert-Throws { ConvertTo-CreateNicGuid 'not-a-guid' } 'malformed NIC identities must fail closed'
        Write-Host 'PASS: real NIC GUID normalizers support Windows adapter strings and Hyper-V Guid arrays'

        $savedRoot=$script:Root
        $script:Root=Join-Path $savedRoot 'source with spaces'
        $taskScript='windows-host\05-shutdown-all.ps1'
        $taskPath=Join-Path $script:Root $taskScript
        $VMName='Custom Field Box'
        $expectedVm='-VMName '+(ConvertTo-SetupArgument $VMName)
        $script:MockTask=[pscustomobject]@{
            Settings=[pscustomobject]@{Enabled=$true};Principal=[pscustomobject]@{RunLevel='Highest'}
            Actions=@([pscustomobject]@{Execute='powershell.exe';Arguments=('-NoProfile -File "'+$taskPath+'" '+$expectedVm)})
        }
        function Get-SetupTask { $script:MockTask }
        Assert (Test-SetupTask 'fixture' $taskScript $expectedVm) 'the explicitly selected custom VM task must pass'
        $script:MockTask.Actions[0].Arguments='-NoProfile -File "'+$taskPath+'"'
        Assert (-not (Test-SetupTask 'fixture' $taskScript $expectedVm)) 'legacy tasks that lose the selected VM must require repair'
        $script:MockTask.Actions[0].Arguments='-NoProfile -File "'+$taskPath+'" -VMName "EdgeBox"'
        Assert (-not (Test-SetupTask 'fixture' $taskScript $expectedVm)) 'tasks targeting another VM must require repair'
        $script:MockTask.Actions[0].Arguments='-NoProfile -File "'+$taskPath+'.old" '+$expectedVm
        Assert (-not (Test-SetupTask 'fixture' $taskScript $expectedVm)) 'a script path prefix must not satisfy task validation'
        $script:MockTask.Actions[0].Arguments='-NoProfile -File '+$taskPath+' '+$expectedVm
        Assert (-not (Test-SetupTask 'fixture' $taskScript $expectedVm)) 'an unquoted script path containing spaces is not executable'
        $script:MockTask.Actions[0].Arguments='-NoProfile -File "'+$taskPath+'" '+$expectedVm
        $script:MockTask.Actions[0].Execute='notepad.exe'
        Assert (-not (Test-SetupTask 'fixture' $taskScript $expectedVm)) 'matching arguments with the wrong executable must not pass'
        $script:MockTask.Actions[0].Execute=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Assert (Test-SetupTask 'fixture' $taskScript $expectedVm) 'full Windows PowerShell executable paths remain supported'
        $script:Root=$savedRoot
        function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
        foreach ($relative in @('windows-host\05-shutdown-all.ps1','windows-host\08-settings-console.ps1')) {
            $parseErrors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot $relative),[ref]$null,[ref]$parseErrors)
            Assert (-not $parseErrors.Count) 'shortcut registration script must parse'
            $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$action'},$true))
            Assert ($assignments.Count -eq 1) 'the production task action must be uniquely identifiable'
            # Evaluate only the real action expression with a mocked constructor.
            . ([scriptblock]::Create($assignments[0].Extent.Text))
            Assert ($action.Arguments.Contains($expectedVm)) ('the registered action must retain custom VMName: '+$relative)
        }
        Write-Host 'PASS: custom VM shortcut registration, old task repair and exact executable/script validation'

        $shutdownAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'windows-host\05-shutdown-all.ps1'),[ref]$null,[ref]$null)
        foreach ($helperName in @('Assert-ShutdownTargetOff','Invoke-ConfirmedWindowsShutdown')) {
            $helper=@($shutdownAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName},$true))
            Assert ($helper.Count -eq 1) 'shutdown guards must be uniquely identifiable'
            . ([scriptblock]::Create($helper[0].Extent.Text))
        }
        $script:ShutdownCalls=0;$script:ShutdownExit=0
        function shutdown.exe { $script:ShutdownCalls++; $global:LASTEXITCODE=$script:ShutdownExit }
        function Write-ShutdownLog {}
        $VMName='Selected';$script:MockVm.Name=$VMName;$script:MockVm.State='Off'
        Invoke-ConfirmedWindowsShutdown 'original-vm'
        Assert ($script:ShutdownCalls -eq 1) 'confirmed original VM Off may request normal host shutdown'
        foreach ($scenario in @('restarted','same-name-replacement','renamed','missing')) {
            $script:ShutdownCalls=0
            $script:MockVm=[pscustomobject]@{Id='original-vm';Name=$VMName;State='Off'}
            switch ($scenario) {
                'restarted' {$script:MockVm.State='Running'}
                'same-name-replacement' {$script:MockVm.Id='replacement'}
                'renamed' {$script:MockVm.Name='Other'}
                'missing' {$script:MockVm=$null}
            }
            Assert-Throws { Invoke-ConfirmedWindowsShutdown 'original-vm' } ('host shutdown must reject '+$scenario)
            Assert ($script:ShutdownCalls -eq 0) 'unconfirmed guest stop must never reach shutdown.exe'
        }
        $script:MockVm=[pscustomobject]@{Id='original-vm';Name=$VMName;State='Off'}
        $script:ShutdownExit=23
        Assert-Throws { Invoke-ConfirmedWindowsShutdown 'original-vm' } 'host shutdown command failure must remain a failure'
        Write-Host 'PASS: actual host-shutdown guard under mocks, including guest restart and identity replacement'

        $script:MockVm=[pscustomobject]@{Id='33333333-3333-3333-3333-333333333333';Name='CpuVm';State='Off';AutomaticStartAction='Nothing'}
        $script:CpuBoot=[datetime]::UtcNow.AddHours(-1)
        $script:CpuResult=[pscustomobject]@{ExitCode=0;Output=''}
        function Get-SetupVM {$script:MockVm}
        function Get-SetupCpuConfig { [pscustomobject]@{Mode='full';VMName='CpuVm';HostLps=@(0..([Environment]::ProcessorCount-1));Scheduler='core';ManageVmStart=$true} }
        function Get-SetupBcd { [pscustomobject]@{RootProc=[Environment]::ProcessorCount;Scheduler='core'} }
        function Test-SetupTask {$true}
        function Get-SetupScheduler {'core'}
        function Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq 'Win32_Processor') { [pscustomobject]@{NumberOfCores=[Environment]::ProcessorCount;NumberOfLogicalProcessors=[Environment]::ProcessorCount} }
            else { [pscustomobject]@{LastBootUpTime=$script:CpuBoot} }
        }
        function Read-SetupJson { [pscustomobject]@{At=[datetime]::UtcNow;MinrootOk=$true;Bound=$true} }
        function Get-SetupCpuGroupOutput {$script:CpuResult}
        function Test-Path {
            param($LiteralPath,$PathType)
            if ($LiteralPath -eq (Join-Path $script:Root 'windows-cpu-partition\tools\CpuGroups.exe')) {return $true}
            Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        $vmId=$script:MockVm.Id;$groupId='b0edb0ed-c01e-4a11-8000-0000000000e1';$otherVm='44444444-4444-4444-4444-444444444444'
        $script:CpuResult.Output="VmName VmId CpuGroupId`r`nCpuVm $vmId $groupId"
        Assert ((Get-SetupCpuState).State -eq 'Done') 'the target VM and expected CPU group on one unambiguous row may pass'
        foreach ($badOutput in @("OtherVm $otherVm $groupId", "$vmId`n$groupId", "group $groupId", "CpuVm $vmId $groupId`nCpuVm $vmId $groupId", "CpuVm $vmId 00000000-0000-0000-0000-000000000000")) {
            $script:CpuResult.Output=$badOutput
            Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'unrelated, split, duplicate or unbound group evidence must not report CPU separation complete'
        }
        $script:CpuResult.Output="CpuVm $vmId $groupId";$script:CpuResult.ExitCode=23
        Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'tool failure must not be overridden by matching output'
        Write-Host 'PASS: real CPU completion predicate binds one output row to the selected VM ID'

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
    } $project
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'EdgeBoxSafetyTests_*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
