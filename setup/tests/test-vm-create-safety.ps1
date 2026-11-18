#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$module=Import-Module (Join-Path $project 'windows-host\vm-create-safety.psm1') -PassThru -Force
try {
    $parseErrors=$null
    $createAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'windows-host\01-create-field-vm.ps1'),[ref]$null,[ref]$parseErrors)
    if ($parseErrors.Count) { throw 'VM creation script has parse errors.' }
    $transaction=@($createAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })
    if ($transaction.Count -ne 1) { throw 'VM creation transaction could not be located for mock verification.' }
    $bodyText=$transaction[0].Body.Extent.Text
    & $module {
        param($TransactionBody)
        function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
        function Assert-Throws([scriptblock]$Action,[string]$Message) {
            $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }
            Assert $failed $Message
        }
        function Reset-Fixture {
            $script:Disk=[pscustomobject]@{Number=7;UniqueId='original';Size=[UInt64]1048576;SerialNumber='serial';IsBoot=$false;IsSystem=$false;IsOffline=$true}
            $script:Disks=@($script:Disk);$script:Vms=@();$script:Partitions=@();$script:AttachmentCount=1
            $script:Switches=@([pscustomobject]@{Name='CreatedSwitch';Id='switch-created'})
            $script:QueryFailure='';$script:RemoveBehavior='success';$script:OnlineCalls=0;$script:RemoveCalls=0;$script:SwitchRemoveCalls=0
            $script:SystemDisk=0;$script:LastDriveLetter='';$script:OnlineFailure=$false
        }
        function Get-Disk { if ($script:QueryFailure -eq 'disk') { throw 'disk query failed' }; $script:Disks }
        function Get-Partition {
            param($DriveLetter,$DiskNumber)
            if ($script:QueryFailure -eq 'partition') { throw 'partition query failed' }
            if ($DriveLetter) { $script:LastDriveLetter=$DriveLetter; [pscustomobject]@{DiskNumber=$script:SystemDisk} } else { $script:Partitions }
        }
        function Get-VM { if ($script:QueryFailure -eq 'vm') { throw 'VM query denied' }; $script:Vms }
        function Get-VMHardDiskDrive {
            param($VMName,$VM)
            if ($script:QueryFailure -eq 'attachment') { throw 'VM disk query denied' }
            if ($null -ne $VM) { Assert-CreatedVmTarget $VM 'Get-VMHardDiskDrive' }
            for ($i=0;$i -lt $script:AttachmentCount;$i++) { [pscustomobject]@{DiskNumber=7} }
        }
        function Get-VMSwitch { $script:Switches }
        function Get-VMNetworkAdapter { @() }
        function Remove-VM {
            param($VM,[switch]$Force)
            $script:RemoveCalls++
            if ($script:RemoveBehavior -eq 'failure') { throw 'VM removal failed' }
            if ($script:RemoveBehavior -eq 'success') { $script:Vms=@($script:Vms | Where-Object Id -ne $VM.Id) }
        }
        function Set-Disk {
            param($Number,[bool]$IsOffline)
            if ($IsOffline) { throw 'rollback must not offline a disk' }
            $script:OnlineCalls++
            if ($script:OnlineFailure) { throw 'online request failed' }
            $script:Disk.IsOffline=$false
        }
        function Remove-VMSwitch { param($VMSwitch,[switch]$Force) $script:SwitchRemoveCalls++;$script:Switches=@() }
        function Stop-VM { throw 'tests and rollback must never stop a VM' }
        function Restart-Computer { throw 'tests must never restart a host' }

        Reset-Fixture
        $snapshot=Get-EdgeBoxCreateDisk -DiskNumber 7 -ExpectedUniqueId original -ExpectedSize 1048576 -ExpectedSerialNumber serial
        Assert ($snapshot.UniqueId -eq 'original') 'valid unmounted unused disk must remain supported'
        Assert ($script:LastDriveLetter -eq $env:SystemDrive.Substring(0,1)) 'system-drive detection must use the actual Windows drive'
        foreach ($flag in @('IsBoot','IsSystem')) {
            Reset-Fixture;$script:Disk.$flag=$true
            Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'boot and system flags must independently block disk use'
        }
        Reset-Fixture;$script:SystemDisk=7
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'current Windows partition must block disk use even if flags are false'
        foreach ($failure in @('disk','partition','vm','attachment')) {
            Reset-Fixture;$script:Vms=@([pscustomobject]@{Name='Other';Id='other';State='Off'});$script:QueryFailure=$failure
            Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'unreadable disk-use state must never be treated as unused'
        }
        Reset-Fixture
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 -ExpectedUniqueId replacement } 'stale unique ID must be rejected'
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 -ExpectedSize 123 } 'stale capacity must be rejected'
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 -ExpectedSerialNumber replacement } 'stale serial must be rejected'
        $script:Disk.UniqueId=''
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'blank unique ID must be rejected'
        Reset-Fixture;$script:Disks+=([pscustomobject]@{Number=8;UniqueId='original'})
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'duplicate unique IDs must be rejected'
        Reset-Fixture;$script:Partitions=@([pscustomobject]@{DriveLetter='D';AccessPaths=@()})
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'drive-letter mounts must be rejected'
        $script:Partitions=@([pscustomobject]@{DriveLetter='';AccessPaths=@('C:\Mount\')})
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'folder mounts must be rejected'
        $script:Partitions=@([pscustomobject]@{DriveLetter='';AccessPaths=@('\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\')})
        Assert ((Get-EdgeBoxCreateDisk -DiskNumber 7).Number -eq 7) 'volume GUID namespace alone must not be treated as a user mount'
        Reset-Fixture;$script:Vms=@([pscustomobject]@{Name='Selected';Id='selected';State='Off'})
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 } 'any existing VM attachment must block new VM creation'
        Assert ((Get-EdgeBoxCreateDisk -DiskNumber 7 -AllowedVmId selected).Number -eq 7) 'an explicit existing VM identity may retain its own disk'
        $script:AttachmentCount=2
        Assert-Throws { Get-EdgeBoxCreateDisk -DiskNumber 7 -AllowedVmId selected } 'duplicate disk attachments must not be silently repaired'
        Write-Host 'PASS: VM creation disk identity, system/mount guards and closed-on-error use checks'

        foreach ($behavior in @('failure','no-effect')) {
            Reset-Fixture;$snapshot=$script:Disk.PSObject.Copy();$script:Vms=@([pscustomobject]@{Name='NewVm';Id='created';State='Off'});$script:RemoveBehavior=$behavior
            $result=Undo-EdgeBoxVmCreation -DiskSnapshot $snapshot -CreatedVmId created -CreatedSwitchId switch-created -RestoreDiskOnline -WarningAction SilentlyContinue
            Assert (-not $result.VmRemoved -and $script:OnlineCalls -eq 0 -and $script:SwitchRemoveCalls -eq 0) 'unconfirmed VM removal must keep disk offline and switch intact'
        }
        Reset-Fixture;$snapshot=$script:Disk.PSObject.Copy();$script:Vms=@([pscustomobject]@{Name='NewVm';Id='created';State='Running'})
        $result=Undo-EdgeBoxVmCreation -DiskSnapshot $snapshot -CreatedVmId created -RestoreDiskOnline -WarningAction SilentlyContinue
        Assert ($script:RemoveCalls -eq 0 -and $script:OnlineCalls -eq 0) 'rollback must never delete or power off a running VM'
        Reset-Fixture;$snapshot=$script:Disk.PSObject.Copy();$script:Disk.UniqueId='replacement'
        $result=Undo-EdgeBoxVmCreation -DiskSnapshot $snapshot -RestoreDiskOnline -WarningAction SilentlyContinue
        Assert ($script:OnlineCalls -eq 0) 'rollback must not online a replacement disk at the same number'
        Reset-Fixture;$snapshot=$script:Disk.PSObject.Copy();$script:Vms=@([pscustomobject]@{Name='NewVm';Id='created';State='Off'})
        $result=Undo-EdgeBoxVmCreation -DiskSnapshot $snapshot -CreatedVmId created -CreatedSwitchId switch-created -RestoreDiskOnline
        Assert ($result.VmRemoved -and $result.DiskOnline -and $result.SwitchRemoved -and $script:OnlineCalls -eq 1) 'rollback may restore only its confirmed unused original disk and switch'
        Reset-Fixture;$snapshot=$script:Disk.PSObject.Copy();$script:OnlineFailure=$true
        $result=Undo-EdgeBoxVmCreation -DiskSnapshot $snapshot -RestoreDiskOnline -WarningAction SilentlyContinue
        Assert (-not $result.DiskOnline) 'failed online requests must not be reported as successful rollback'
        Write-Host 'PASS: VM creation rollback failures, identity changes and safe cleanup'

        # Execute the production transaction body with every mutating command mocked.
        # The entry point (which checks real privileges) is never executed.
        $transaction=[scriptblock]::Create($TransactionBody.Substring(1,$TransactionBody.Length-2))
        function Reset-Transaction {
            Reset-Fixture
            $script:Disk.IsOffline=$false;$script:AttachmentCount=0
            $script:CreateCalls=0;$script:OfflineCalls=0;$script:AttachCalls=0;$script:ChangeDiskAfterVm=$false
            $script:ReuseNameAfterVm=$false;$script:CreatedVm=$null;$script:HardwareTargets=@()
        }
        function New-VM {
            param($Name,$Generation,$MemoryStartupBytes,[switch]$NoVHD,$SwitchName)
            $script:CreateCalls++
            $script:CreatedVm=[pscustomobject]@{Name=$Name;Id='created';State='Off'}
            $script:Vms=@($script:CreatedVm)
            if ($script:ReuseNameAfterVm) {
                $script:CreatedVm.Name='RenamedOriginal'
                $script:Vms+=@([pscustomobject]@{Name=$Name;Id='unrelated';State='Off'})
            }
            if ($script:ChangeDiskAfterVm) { $script:Disk.UniqueId='replacement' }
            $script:CreatedVm
        }
        function Assert-CreatedVmTarget($VM,[string]$Operation) {
            Assert ($null -ne $VM -and $VM.Id -eq 'created' -and [object]::ReferenceEquals($VM,$script:CreatedVm)) ($Operation+' must receive the New-VM object, never resolve a reused name')
            $script:HardwareTargets+=@{Operation=$Operation;Id=$VM.Id}
        }
        function Set-VMFirmware {
            [CmdletBinding()]param($VM,$EnableSecureBoot,$FirstBootDevice)
            Assert-CreatedVmTarget $VM 'Set-VMFirmware'
        }
        function Set-VMProcessor {
            [CmdletBinding()]param($VM,$Count)
            Assert-CreatedVmTarget $VM 'Set-VMProcessor'
        }
        function Set-VM {
            [CmdletBinding()]param($VM,$CheckpointType,$AutomaticStopAction)
            Assert-CreatedVmTarget $VM 'Set-VM'
        }
        function Set-Disk { param($Number,[bool]$IsOffline) $script:OfflineCalls++;$script:Disk.IsOffline=$IsOffline }
        function Add-VMHardDiskDrive {
            [CmdletBinding()]param($VM,$DiskNumber)
            Assert-CreatedVmTarget $VM 'Add-VMHardDiskDrive'
            $script:AttachCalls++;$script:AttachmentCount=1
        }
        function New-VMSwitch { throw 'this fixture must not create a network switch' }
        $DiskNumber=7;$VMName='NewVm';$MemoryGB=8;$CpuCount=6;$useSwitch='CreatedSwitch';$createFrom='';$selectedSwitchId='switch-created'
        Reset-Transaction
        $selectedDisk=$script:Disk.PSObject.Copy()
        . $transaction
        Assert ($script:CreateCalls -eq 1 -and $script:OfflineCalls -eq 1 -and $script:AttachCalls -eq 1) 'valid creation must still create and attach exactly once'
        Reset-Transaction
        $selectedDisk=$script:Disk.PSObject.Copy();$script:ReuseNameAfterVm=$true
        . $transaction
        Assert (@($script:Vms|Where-Object { $_.Name -eq $VMName -and $_.Id -eq 'unrelated' }).Count -eq 1) 'fixture reuses the original name for a different VM'
        Assert ($script:HardwareTargets.Count -eq 6 -and @($script:HardwareTargets|Where-Object Id -ne 'created').Count -eq 0) 'all configuration, attachment and boot readback remain bound to created VM after name reuse'
        Reset-Transaction
        $selectedDisk=$script:Disk.PSObject.Copy();$script:Disk.UniqueId='replacement'
        Assert-Throws { . $transaction } 'a disk replaced before the first mutation must stop the production transaction'
        Assert ($script:CreateCalls -eq 0 -and $script:OfflineCalls -eq 0 -and $script:AttachCalls -eq 0) 'stale identity must prevent all host mutation'
        Reset-Transaction
        $selectedDisk=$script:Disk.PSObject.Copy();$script:ChangeDiskAfterVm=$true
        Assert-Throws { . $transaction } 'a disk changed during VM creation must stop before disk mutation'
        Assert ($script:CreateCalls -eq 1 -and $script:OfflineCalls -eq 0 -and $script:AttachCalls -eq 0) 'fresh disk checks must precede offline and attachment'
        Write-Host 'PASS: production VM-creation transaction under mocks, including mid-operation disk replacement'
    } $bodyText
} finally { Remove-Module $module -ErrorAction SilentlyContinue }
