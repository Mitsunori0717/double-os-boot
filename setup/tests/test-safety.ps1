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
    $cpuDir=New-Item -ItemType Directory -Path (Join-Path $temp 'windows-cpu-partition')
    Copy-Item -LiteralPath (Join-Path $project 'windows-cpu-partition\cpu-tool.psm1') -Destination $cpuDir.FullName
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
        $script:MockTask.Principal | Add-Member NoteProperty UserId 'S-1-5-18'
        $bootTrigger=[pscustomobject]@{Enabled=$true;CimClass=[pscustomobject]@{CimClassName='MSFT_TaskBootTrigger'}}
        $script:MockTask | Add-Member NoteProperty Triggers @($bootTrigger)
        $script:MockTask.Actions[0].Arguments='-NoProfile -File "'+$taskPath+'" -BootApply -Quiet'
        Assert (Test-SetupTask 'fixture' $taskScript '-BootApply' -Boot) 'SYSTEM boot task runs at startup'
        $bootTrigger.Enabled=$false
        Assert (-not (Test-SetupTask 'fixture' $taskScript '-BootApply' -Boot)) 'a disabled boot trigger cannot take ownership of VM startup'
        $bootTrigger.Enabled=$true
        $script:MockTask.Actions[0].Arguments+=' -PrepareOnly'
        Assert (-not (Test-SetupTask 'fixture' $taskScript '-BootApply' -Boot)) 'a preparation-only task cannot start the VM'
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
        foreach ($helperName in @('Assert-ShutdownTargetOff','Invoke-ConfirmedWindowsShutdown','Test-ShutdownConsoleTarget')) {
            $helper=@($shutdownAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName},$true))
            Assert ($helper.Count -eq 1) 'shutdown guards must be uniquely identifiable'
            . ([scriptblock]::Create($helper[0].Extent.Text))
        }
        $script:ShutdownCalls=0;$script:ShutdownExit=0
        function shutdown.exe { $script:ShutdownArgs=@($args); $script:ShutdownCalls++; $global:LASTEXITCODE=$script:ShutdownExit }
        function Write-ShutdownLog {}
        $VMName='Selected';$script:MockVm.Name=$VMName;$script:MockVm.State='Off'
        Invoke-ConfirmedWindowsShutdown 'original-vm'
        Assert ($script:ShutdownCalls -eq 1) 'confirmed original VM Off may request normal host shutdown'
        Assert ($script:ShutdownArgs[0] -eq '/s' -and '/f' -notin $script:ShutdownArgs) 'shutdown choice must never force applications closed'
        Invoke-ConfirmedWindowsShutdown 'original-vm' -Restart
        Assert ($script:ShutdownArgs[0] -eq '/r' -and ($script:ShutdownArgs[1..2] -join ' ') -eq '/t 0' -and '/f' -notin $script:ShutdownArgs) 'manual restart must use zero additional delay after confirmed stop'
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
        $target=$script:MockVm
        $other=[pscustomobject]@{Id='other';Name='Unrelated';State='Running'}
        $script:MockVm=@($target,$other)
        Assert-Throws { Invoke-ConfirmedWindowsShutdown 'original-vm' } 'a running unrelated VM must block Windows shutdown'
        Assert ($script:ShutdownCalls -eq 0) 'host shutdown must leave unrelated VMs running'
        $script:MockVm=$target
        $consoleVm=[pscustomobject]@{Name='Selected Box';Id='11111111-1111-1111-1111-111111111111'}
        Assert (Test-ShutdownConsoleTarget 'vmconnect.exe localhost "Selected Box"' $consoleVm) 'local console for a custom VM must match'
        Assert (Test-ShutdownConsoleTarget 'vmconnect.exe . -G {11111111-1111-1111-1111-111111111111} -C 1' $consoleVm) 'local manager console with target ID must match'
        foreach ($line in @('vmconnect.exe other-host "Selected Box"', 'vmconnect.exe localhost "Selected Box 2"', 'vmconnect.exe localhost "Other"', 'vmconnect.exe localhost Selected Box')) {
            Assert (-not (Test-ShutdownConsoleTarget $line $consoleVm)) 'unrelated or ambiguous VMConnect windows must remain open'
        }
        $script:ShutdownExit=23
        Assert-Throws { Invoke-ConfirmedWindowsShutdown 'original-vm' } 'host shutdown command failure must remain a failure'
        Write-Host 'PASS: actual host-shutdown guard under mocks, including guest restart and identity replacement'

        & {
            function Get-EdgeBoxHypervisorLpCount { [Environment]::ProcessorCount + 8 }
            Assert (@(Get-SetupCpuTopology).Count -eq 0) 'restricted running host topology is incomplete even with a pending BCD reset'
        }
        & {
            $SnapshotFile=Join-Path $script:Root 'windows-cpu-partition\cpu-topology.json'
            $gui=[Management.Automation.Language.Parser]::ParseFile((Join-Path $ProjectRoot 'windows-cpu-partition\cpu-console.ps1'),[ref]$null,[ref]$null)
            foreach ($definition in $gui.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Read-Snapshot','Set-CoreLabels','New-Core','Get-CpuName','Get-LpCount')},$false)) {
                . ([scriptblock]::Create($definition.Extent.Text))
            }
            $fullCores=@(
                foreach ($i in 0..3) { [pscustomobject]@{Eff=1;Lps=@((2*$i),(2*$i+1))} }
                foreach ($i in 8..15) { [pscustomobject]@{Eff=0;Lps=@($i)} }
            )
            function Get-SetupCpuTopology { $fullCores }
            function Get-CimInstance { [pscustomobject]@{Name='  Fixture CPU  '} }
            function Get-SetupBcd { [pscustomobject]@{RootProc=0} }
            function Get-SetupVM { [pscustomobject]@{Name='FixtureVM'} }
            function Get-SetupCpuConfig { $requestedConfig }
            function Invoke-SetupChild($relativePath,$arguments) {
                Assert ($relativePath -eq 'windows-cpu-partition\cpu-partition.ps1') 'exercise the real step 10 entry without changing the host'
                $snap=Read-Snapshot
                Assert ((Get-LpCount $snap) -eq 16 -and $snap.Count -eq 12) 'CPU GUI reads all cores before the child can apply minroot'
                Assert ($snap[0].Kind -eq 'P' -and ($snap[0].Lps -join ',') -eq '0,1' -and $snap[-1].Kind -eq 'E') 'GUI retains physical SMT and efficiency class'
                $index=[array]::IndexOf($arguments,'-GuestLps')
                Assert ($index -ge 0 -and $arguments[$index+1] -eq $expectedGuest) 'step 10 preserves the selected guest assignment'
            }
            foreach ($mode in @('auto','settings','saved')) {
                [IO.File]::Delete($SnapshotFile)
                $requestedConfig=$null
                $script:Settings=@{}
                $expectedGuest=(8..15) -join ','
                if ($mode -eq 'settings') {
                    $script:Settings=@{HostLps=@(0..5);GuestLps=@(6..15)}
                    $expectedGuest=(6..15) -join ','
                } elseif ($mode -eq 'saved') {
                    $requestedConfig=[pscustomobject]@{Mode='full';HostLps=@(0..3);GuestLps=@(4..15);Scheduler='core'}
                    $expectedGuest=(4..15) -join ','
                }
                Invoke-SetupStep '10'
            }
            $before=(Get-FileHash -LiteralPath $SnapshotFile).Hash
            $fullCores=@()
            Invoke-SetupStep '10'
            Assert ((Get-FileHash -LiteralPath $SnapshotFile).Hash -eq $before) 'reapplying with a restricted view preserves the full GUI snapshot'
            $requestedConfig=$null
            Assert-Throws { Invoke-SetupStep '10' } 'an automatic plan cannot use only the host partition'
        }
        Write-Host 'PASS: setup without prior GUI captures full P/E and SMT topology for automatic and explicit CPU plans'

        $script:MockVm=[pscustomobject]@{Id='33333333-3333-3333-3333-333333333333';Name='CpuVm';State='Off';AutomaticStartAction='Nothing'}
        $script:CpuBoot=[datetime]::UtcNow.AddHours(-1)
        $script:CpuResult=[pscustomobject]@{ExitCode=0;Output=''}
        function Get-SetupVM {$script:MockVm}
        $guestStart=[Environment]::ProcessorCount
        $script:CpuConfig=[pscustomobject]@{Mode='full';VMName='CpuVm';VMId=$script:MockVm.Id;HostLps=@(0..($guestStart-1));GuestLps=@($guestStart,($guestStart+1));Scheduler='core';ManageVmStart=$true}
        $script:VcpuCount=2
        function Get-VMProcessor { [pscustomobject]@{Count=$script:VcpuCount} }
        function Get-SetupCpuConfig { $script:CpuConfig }
        function Get-SetupBcd { [pscustomobject]@{RootProc=[Environment]::ProcessorCount;Scheduler='core'} }
        function Test-SetupTask {$true}
        function Get-SetupScheduler {'core'}
        function Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq 'Win32_Processor') { [pscustomobject]@{NumberOfCores=[Environment]::ProcessorCount;NumberOfLogicalProcessors=[Environment]::ProcessorCount} }
            else { [pscustomobject]@{LastBootUpTime=$script:CpuBoot} }
        }
        function Read-SetupJson { [pscustomobject]@{At=[datetime]::UtcNow;MinrootOk=$true;Bound=$true} }
        function Get-SetupCpuGroupOutput([string]$Exe,[string[]]$Arguments) {
            switch ($Arguments[0]) {
                'GetVmGroup' { Assert ($Arguments[1] -eq '/VmName:CpuVm') 'query the selected VM'; $script:CpuResult }
                'GetGroups' { $script:Groups }
                default { throw 'Unexpected CpuGroups invocation' }
            }
        }
        function Test-Path {
            param($LiteralPath,$PathType)
            if ($LiteralPath -eq (Join-Path $script:Root 'windows-cpu-partition\tools\CpuGroups.exe')) {return $true}
            Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        }
        $vmId=$script:MockVm.Id;$groupId='b0edb0ed-c01e-4a11-8000-0000000000e1';$otherVm='44444444-4444-4444-4444-444444444444'
        $script:Groups=[pscustomobject]@{ExitCode=0;Output="CpuGroupId CpuCap LpIndexes`n$groupId 65536 $($guestStart+1),$guestStart"}
        $script:CpuResult.Output="VmName VmId CpuGroupId`r`nCpuVm $vmId $groupId"
        Assert ((Get-SetupCpuState).State -eq 'Done') 'the target VM and expected CPU group on one unambiguous row may pass'
        foreach ($badOutput in @("OtherVm $otherVm $groupId", "$vmId`n$groupId", "group $groupId", "CpuVm $vmId $groupId`nCpuVm $vmId $groupId", "CpuVm $vmId 00000000-0000-0000-0000-000000000000")) {
            $script:CpuResult.Output=$badOutput
            Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'unrelated, split, duplicate or unbound group evidence must not report CPU separation complete'
        }
        $script:CpuResult.Output="CpuVm $vmId $groupId";$script:CpuResult.ExitCode=23
        Assert-Throws { Get-SetupCpuState } 'tool failure must stop automatic repair despite matching output'
        $script:CpuResult.ExitCode=0
        $script:Groups.ExitCode=1
        Assert-Throws { Get-SetupCpuState } 'failed affinity query must not approve or mutate a plan'
        $script:Groups.ExitCode=0
        $validAffinity=$script:Groups.Output
        $script:Groups.Output="CpuGroupId CpuCap LpIndexes`n$groupId 65536 0,1"
        Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'matching group ID with wrong LP membership must require repair'
        $script:Groups.Output=$validAffinity
        $script:VcpuCount=3
        Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'vCPU count must agree with guest LPs'
        $script:VcpuCount=2
        $script:CpuConfig.ManageVmStart=$false
        Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'legacy unmanaged boot order must require repair'
        $script:CpuConfig.ManageVmStart=$true
        $script:MockVm.AutomaticStartAction='Start'
        Assert ((Get-SetupCpuState).State -eq 'NeedsWork') 'direct Hyper-V start must not race the boot task'
        $script:CpuConfig.VMId=$otherVm
        Assert-Throws { Get-SetupCpuState } 'a replaced VM cannot inherit CPU-plan identity'
        Write-Host 'PASS: target identity, group membership, live LP set, vCPU count and boot ownership'

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
        Write-Host 'PASS: logon resumes setup without any unattended restart argument'
    } $project
    $restartPolicy=Import-Module (Join-Path $project 'windows-host\host-restart-policy.psm1') -PassThru -Force
    & $restartPolicy {
        $script:value=1;$script:writes=0;$script:ignoreWrite=$false
        function Get-ItemProperty { [pscustomobject]@{AutoReboot=$script:value} }
        function New-ItemProperty($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force) {
            if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -or
                $Name -ne 'AutoReboot' -or $PropertyType -ne 'DWord' -or $Value -ne 0) { throw 'Unexpected crash setting' }
            $script:writes++
            if (-not $script:ignoreWrite) { $script:value=$Value }
        }
        if (Test-EdgeBoxCrashRestartBlocked) { throw 'Initially enabled crash restart must be detected' }
        Set-EdgeBoxCrashRestartPolicy
        Set-EdgeBoxCrashRestartPolicy
        if (-not (Test-EdgeBoxCrashRestartBlocked) -or $script:writes -ne 1) { throw 'Crash restart prevention must be verified and idempotent' }
        $script:value=$null;$script:ignoreWrite=$true;$failed=$false
        try { Set-EdgeBoxCrashRestartPolicy } catch { $failed=$true }
        if (-not $failed) { throw 'An ineffective registry write must fail the postcheck' }
        Write-Host 'PASS: crash restart prevention, idempotence and readback with mocked registry'
    }
    Remove-Module $restartPolicy
    & {
        $fixture=Join-Path $temp 'shutdown-diagnostics.ps1'
        Copy-Item (Join-Path $project 'windows-host\shutdown-diagnostics.ps1') $fixture
        Set-Content (Join-Path $temp 'shutdown-log.txt') @('2026-02-01 01:02:00 Edge Box の停止を確認: 9.5 秒','personal text MUST_NOT_LEAK') -Encoding UTF8
        function New-TestEvent($Record,[int]$Id,[string]$Provider,[int]$Second) {
            [pscustomobject]@{RecordId=$Record;Id=$Id;ProviderName=$Provider;TimeCreated=([datetime]'2026-02-01').AddSeconds($Second)}
        }
        $kernel='Microsoft-Windows-Kernel-General'
        $events=@(
            New-TestEvent 1 12 $kernel 0
            New-TestEvent 2 1074 'User32' 10
            New-TestEvent 3 13 $kernel 22
            New-TestEvent 4 12 $kernel 33
            New-TestEvent 5 1074 'User32' 42
            New-TestEvent 6 1074 'User32' 44
            New-TestEvent 7 13 $kernel 65
            New-TestEvent 8 12 $kernel 80
            New-TestEvent 9 1074 'User32' 85
            New-TestEvent 10 13 $kernel 94
            New-TestEvent 11 12 $kernel 99
            New-TestEvent 12 6008 'EventLog' 105
            New-TestEvent 13 1074 'User32' 106
            New-TestEvent 14 1075 'User32' 109
            New-TestEvent 15 13 $kernel 160
            New-TestEvent 16 12 $kernel 185
        )
        $diag=@(foreach ($id in @(200,203)) {
            $body=if ($id -eq 200) { '<Data Name="ShutdownStartTime">2026-02-01T00:00:00Z</Data><Data Name="ShutdownServicesTime">9000</Data>' }
                else { '<Data Name="StartTime">2026-02-01T00:00:00Z</Data><Data Name="Name">vmms</Data><Data Name="TotalTime">8200</Data><Data Name="Path">MUST_NOT_LEAK</Data>' }
            $record=[pscustomobject]@{Id=$id;TimeCreated=[datetime]'2026-02-01';Body=$body}
            $record | Add-Member ScriptMethod ToXml { '<Event><EventData>'+$this.Body+'</EventData></Event>' }
            $record
        })
        $deny=$false
        function Get-WinEvent($ListLog,$FilterHashtable) {
            if ($ListLog) {
                if ($deny -and $ListLog -ne 'System') { throw [UnauthorizedAccessException]::new() }
                return [pscustomobject]@{IsEnabled=$true}
            }
            if ($FilterHashtable.LogName -eq 'System') { return $events }
            return $diag
        }
        $text=(& $fixture 3>&1 | Out-String)
        if ($text -notmatch 'カーネル終了まで 12[,.]0 秒' -or $text -match 'カーネル終了まで 54[,.]0 秒' -or $text -notmatch '複数' -or $text -notmatch '異常終了の記録' -or
            $text -notmatch 'サービス終了 9[,.]0秒' -or $text -notmatch 'vmms' -or $text -notmatch '停止を確認 9.5 秒' -or $text -match 'MUST_NOT_LEAK') {
            throw 'Shutdown diagnostics failed interval, diagnostic phase, service or privacy check'
        }
        $deny=$true
        $text=(& $fixture 3>&1 | Out-String)
        if ($text -notmatch '読み取り権限' -or $text -notmatch '停止を確認 9.5 秒') { throw 'Inaccessible channel must preserve independent diagnostics' }
        Write-Host 'PASS: shutdown diagnostics, boot boundaries, dirty and ambiguous cycles, protected logs and private fields'
    }
} finally {
    if ($module) { Remove-Module $module -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'EdgeBoxSafetyTests_*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

# Run the production update predicates and apply/manual/restore paths with no OS writes.
& {
    $source=Join-Path $project 'windows-host\12-windows-update.ps1'
    $tree=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
    foreach ($function in $tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function Check($condition,$message) { if (-not $condition) { throw "UPDATE TEST FAILED: $message" } }
    & {
        $WatchFiles=@('12-windows-update.ps1','host-restart-policy.psm1','service-restart-policy.psm1','service-restart-policy.cs')
        $dir=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxWatchFixture_'+[guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($dir)
        try {
            $Source=Join-Path $dir 'distribution'
            $null=[IO.Directory]::CreateDirectory($Source)
            & {
                function Get-Acl {
                    $fixtureAcl=[Security.AccessControl.DirectorySecurity]::new()
                    $fixtureAcl.SetSecurityDescriptorSddlForm($sddl)
                    return $fixtureAcl
                }
                $sddl='O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;BU)'
                Assert-UpdateWatchPath $Source
                foreach ($sddl in @('O:BAG:BAD:P(A;;FA;;;BA)(A;;FW;;;BU)','O:BUG:BAD:P(A;;FA;;;BA)(A;;FR;;;BU)')) {
                    $failed=$false; try { Assert-UpdateWatchPath $Source } catch { $failed=$true }
                    Check $failed 'a writable or untrusted-owner SYSTEM payload must be rejected'
                }
            }
            $ProgramRoot=Join-Path $dir 'program-files'
            $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $admin) {
                # CI users cannot assign an Administrators owner. Exercise publication with a synthetic ACL.
                function New-UpdateWatchDirectory($Path) { $null=[IO.Directory]::CreateDirectory($Path) }
                function Assert-UpdateWatchPath($Path) { if (-not (Test-Path -LiteralPath $Path)) { throw 'fixture path missing' } }
                function Get-Acl { [Security.AccessControl.FileSecurity]::new() }
                function Set-Acl {}
            }
            New-UpdateWatchDirectory $ProgramRoot
            $WatchRoot=Join-Path $ProgramRoot 'EdgeBox-WindowsUpdate-Lock'
            foreach ($name in $WatchFiles) { [IO.File]::WriteAllText((Join-Path $Source $name),'original fixture') }
            [IO.File]::WriteAllText((Join-Path $Source 'device-private.json'),'fixture only')
            $WatchVersion=Get-UpdateWatchVersion $Source
            $WatchDirectory=Join-Path $WatchRoot $WatchVersion
            Install-UpdateWatchPayload $Source
            Check (Test-UpdateWatchPayload) 'published payload must match source hashes and protected destination'
            Check (@(Get-ChildItem -LiteralPath $WatchDirectory -Force).Count -eq $WatchFiles.Count) 'watchdog must copy only four allowlisted sources'
            $first=$WatchDirectory
            [IO.File]::WriteAllText((Join-Path $Source $WatchFiles[1]),'updated fixture')
            $WatchVersion=Get-UpdateWatchVersion $Source; $WatchDirectory=Join-Path $WatchRoot $WatchVersion
            Check ($first -ne $WatchDirectory -and -not (Test-UpdateWatchPayload)) 'dependency changes must require a new protected version'
            $Quiet=$true; $failed=$false
            try { Install-UpdateWatchPayload $Source } catch { $failed=$true }
            Check ($failed -and -not (Test-Path -LiteralPath $WatchDirectory)) 'SYSTEM maintenance cannot publish an uninstalled version'
            $Quiet=$false; Install-UpdateWatchPayload $Source
            Check ((Test-UpdateWatchPayload) -and [IO.File]::ReadAllText((Join-Path $first $WatchFiles[1])) -eq 'original fixture') 'upgrades publish atomically and preserve running version'
            if ($admin) {
                $acl=Get-Acl -LiteralPath $WatchDirectory
                $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Modify','Allow')
                $acl.AddAccessRule($rule); Set-Acl -LiteralPath $WatchDirectory -AclObject $acl
                $failed=$false; try { Test-UpdateWatchPayload | Out-Null } catch { $failed=$true }
                Check $failed 'user-writable watchdog paths must be rejected'
            }
        } finally {
            $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
            if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($dir)) -eq $parent -and [IO.Path]::GetFileName($dir) -match '^EdgeBoxWatchFixture_[0-9a-f]{32}$') {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }
    Write-Host 'PASS: protected SYSTEM watchdog publication, versioned dependencies and read-only maintenance'
    function Write-UpdateLog {}
    $AU='au'; $WU='wu'; $MDM='mdm'; $WatchTask='EdgeBox-WindowsUpdate-Lock'; $WatchExe='fixture.exe'; $WatchArgs='fixture -Quiet'
    $RequiredAU=[ordered]@{NoAutoUpdate=1;AUOptions=2;NoAutoRebootWithLoggedOnUsers=1;AlwaysAutoRebootAtScheduledTime=0}
    $keys=@{au=([pscustomobject]$RequiredAU);wu=([pscustomobject]@{});mdm=([pscustomobject]@{})}
    $fixture=[pscustomobject]@{Pending=$false;Crash=$true;Denied=$false;Opens=0;Installs=0;SetCalls=0;Removes=@();WatchValid=$true;ApplyWrites=@()}
    $watch=[pscustomobject]@{TaskName=$WatchTask;TaskPath='\';State='Ready';Settings=@{Enabled=$true};
        Principal=@{UserId='S-1-5-18';RunLevel='Highest';LogonType='ServiceAccount'};Actions=@(@{Execute=$WatchExe;Arguments=$WatchArgs});
        Triggers=@([pscustomobject]@{Enabled=$true;CimClass=@{CimClassName='MSFT_TaskBootTrigger'}},[pscustomobject]@{Enabled=$true;DaysInterval=1;CimClass=@{CimClassName='MSFT_TaskDailyTrigger'}})}
    $restartTask=[pscustomobject]@{TaskName='Reboot_AC';TaskPath='\Microsoft\Windows\UpdateOrchestrator\';State='Disabled'}
    $service=[pscustomobject]@{StartType='Disabled';Status='Stopped'}
    $recovery=[pscustomobject]@{Compliant=$true;RebootServices=@();UnreadableServices=@();Errors=@();ReviewTasks=@()}
    function Read-UpdateKey($Path) { $keys[$Path] }
    function Test-EdgeBoxCrashRestartBlocked { $fixture.Crash }
    function Get-EdgeBoxServiceRestartPolicy { $recovery }
    function Get-Service { $service }
    function Get-ScheduledTask { @($watch,$restartTask) }
    function Test-Path { $fixture.Pending }
    function Install-UpdateWatchPayload { if ($Quiet) { throw 'quiet must not publish or copy source files' } }
    function Test-UpdateWatchPayload { $true }
    function Set-EdgeBoxCrashRestartPolicy { $fixture.SetCalls++ }
    function Set-EdgeBoxServiceRestartPolicy { param([switch]$PreviouslyVerifiedOnly)
        Check ([bool]$PreviouslyVerifiedOnly -eq [bool]$Quiet) 'SYSTEM maintenance may repair only previously verified services and tasks'
        $recovery
    }
    function Set-UpdateValue($Path,$Name,$Value) { $fixture.ApplyWrites+=@("$Path/$Name=$Value") }
    function Register-UpdateWatch { throw 'unexpected task registration' }
    function Disable-ScheduledTask { param($InputObject) if ($fixture.Denied) {throw 'access denied'}; $InputObject.State='Disabled' }
    function Set-Service { throw 'unexpected service write' }
    function Stop-Service { throw 'unexpected service stop' }
    function Get-Item { [IO.FileInfo]::new((Join-Path $project 'fixture.msu')) }
    function Add-WindowsPackage { [CmdletBinding()]param([switch]$Online,$PackagePath,[switch]$NoRestart,[switch]$PreventPending)
        Check ($Online -and $NoRestart -and $PreventPending) 'manual installation must retain restart and pending-operation protection'
        $fixture.Installs++; [pscustomobject]@{RestartNeeded=$true}
    }
    function Start-Process { param($FilePath) Check ($FilePath -eq 'https://www.catalog.update.microsoft.com/') 'only the update catalog may open'; $fixture.Opens++ }
    function Remove-ItemProperty { param($LiteralPath,$Name) $fixture.Removes+=$Name }
    Check ((Get-UpdateLockState).State -eq 'Done') 'verified lock and both watchdog triggers'
    $watch.Actions[0].Arguments='-Restore'
    Check ((Get-UpdateLockState).State -eq 'NeedsWork') 'a watchdog invoking the wrong mode must fail verification'
    $watch.Actions[0].Arguments=$WatchArgs
    $restartTask.State='Ready'; $fixture.Denied=$true
    $failed=$false; try { Set-UpdateLock } catch {$failed=$true}
    Check ($failed -and (Get-UpdateLockState).State -eq 'NeedsWork') 'a protected restart task must be reported and left to its administrator'
    $fixture.Denied=$false; Set-UpdateLock
    $fixture.Crash=$false
    Check ((Get-UpdateLockState).State -ne 'Done') 'crash restart enabled'
    $fixture.Crash=$true
    $UpdateNow=$true; $Restore=$false; $PackagePath='fixture.msu'
    foreach ($entry in @(@('mdm','ConfigureDeadlineForQualityUpdates',0),@('mdm','AllowAutoUpdate',4),@('wu','SetComplianceDeadlineForFU',1))) {
        $key=$keys[$entry[0]]; $key | Add-Member NoteProperty $entry[1] $entry[2]
        $state=Get-UpdateLockState
        Check ($state.State -eq 'Unknown' -and $state.Detail.Contains($entry[1])) 'managed deadlines and conflicting MDM policy must name the blocker'
        $failed=$false; try { Invoke-UpdateLockMode } catch {$failed=$true}
        Check ($failed -and $fixture.Installs -eq 0) 'never start manual installation with a conflicting policy'
        $key.PSObject.Properties.Remove($entry[1])
    }
    $fixture.Pending=$true
    Check ((Get-UpdateLockState).State -eq 'Unknown') 'existing restart pending must be reported'
    $fixture.Pending=$false
    Check ((Invoke-UpdateLockMode) -eq 3010 -and $fixture.Installs -eq 1) 'manual .msu requests manual restart only'
    $PackagePath=''
    Check ((Invoke-UpdateLockMode) -eq 0 -and $fixture.Opens -eq 1) 'manual catalog keeps update lock'
    $UpdateNow=$false; $Restore=$true
    $keys.wu | Add-Member NoteProperty TargetReleaseVersionInfo 'fixture'
    Check ((Invoke-UpdateLockMode) -eq 0 -and ($fixture.Removes -join ',') -eq 'TargetReleaseVersionInfo') 'restore only releases version/deferral policies'
    Check ('au/NoAutoUpdate=1' -in $fixture.ApplyWrites -and 'au/NoAutoUpdate=0' -notin $fixture.ApplyWrites) 'all modes retain automatic-update protection'
    $Quiet=$true; $Restore=$false
    Check ((Invoke-UpdateLockMode) -eq 0) 'maintenance must not republish the payload or authorize new service changes'
    Write-Host 'PASS: update lock, deadline and MDM conflicts, protected tasks, restart pending, catalog/NoRestart servicing and guarded restore'
}
