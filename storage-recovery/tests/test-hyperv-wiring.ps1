#requires -Version 5.1
# Command wiring tests. Native Hyper-V cmdlets are shadowed; no real VM is used.
$ErrorActionPreference='Stop'
# Where the real module is installed, validate command metadata before replacing
# commands. This catches invalid parameters/parameter sets that permissive mocks
# cannot detect. Get-Command imports metadata only; no VM cmdlet is invoked.
if(Get-Module -ListAvailable -Name Hyper-V){
    $contracts=@{
        'New-VM'=@('Name','Generation','MemoryStartupBytes','NoVHD','Path')
        'Set-VMProcessor'=@('VM','Count','CompatibilityForMigrationEnabled')
        'Set-VMMemory'=@('VM','DynamicMemoryEnabled')
        'Set-VM'=@('VM','AutomaticStartAction','AutomaticStopAction','CheckpointType')
        'Add-VMHardDiskDrive'=@('VM','ControllerType','ControllerNumber','ControllerLocation','Path')
        'Set-VMFirmware'=@('VM','EnableSecureBoot','FirstBootDevice','SecureBootTemplate')
        'Set-VMBios'=@('VM','StartupOrder')
        'Set-VMNetworkAdapter'=@('VMNetworkAdapter','StaticMacAddress')
        'Set-VMKeyProtector'=@('VM','NewLocalKeyProtector')
        'Enable-VMTPM'=@('VM')
        'Get-VMSecurity'=@('VM')
        'Get-VMMemory'=@('VM')
        'Get-VMProcessor'=@('VM')
        'Get-VMHardDiskDrive'=@('VM')
        'Get-VMNetworkAdapter'=@('VM')
        'Get-VHD'=@('Path')
        'Start-VM'=@('VM')
    }
    foreach($name in $contracts.Keys){
        $command=Get-Command -Name ('Hyper-V\'+$name) -CommandType Cmdlet -ErrorAction Stop
        $expected=$contracts[$name]
        $sets=@($command.ParameterSets|Where-Object {$names=$_.Parameters.Name;@($expected|Where-Object{$names -notcontains $_}).Count -eq 0})
        if($sets.Count -eq 0){throw ('NATIVE_CMDLET_CONTRACT_MISMATCH: '+$name)}
    }
    Write-Host ('PASS: '+$contracts.Count+' installed Hyper-V command metadata contracts; no VM commands invoked')
}else{Write-Host 'SKIP: installed Hyper-V command metadata unavailable; mock wiring tests still run'}
$m=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HyperVRecovery.psm1') -Force -PassThru
& $m {
    $script:N=0;$script:Calls=[Collections.Generic.List[object]]::new();$script:Disk=$null;$script:Connected=$false
    $script:VM=[pscustomobject]@{Id='new-test-vm';Name='Recovery-Test';State='Off';Generation=2}
    function A($Value,[string]$Message){if(-not $Value){throw "WIRING TEST FAILED: $Message"};$script:N++}
    function Guard($VM){if($VM.Id -ne 'new-test-vm'){throw 'EXISTING_VM_MUST_NOT_CHANGE'}}
    function New-VM { param($Name,$Generation,$MemoryStartupBytes,[switch]$NoVHD,$Path,$SwitchName,$ErrorAction)
        A $NoVHD 'new VM starts without archive attached';A (-not $PSBoundParameters.ContainsKey('SwitchName')) 'no virtual switch passed'
        $script:VM.Generation=$Generation;return $script:VM
    }
    function Set-VMProcessor {param($VM,$Count,$ErrorAction) Guard $VM;A ($Count -eq 2) 'CPU count forwarded'}
    function Set-VMMemory {param($VM,$DynamicMemoryEnabled,$ErrorAction) Guard $VM;A ($DynamicMemoryEnabled -eq $false) 'dynamic memory disabled'}
    function Set-VM {param($VM,$AutomaticStartAction,$AutomaticStopAction,$CheckpointType,$ErrorAction)
        Guard $VM;A ($AutomaticStartAction -eq 'Nothing') 'no automatic boot';A ($AutomaticStopAction -eq 'ShutDown') 'graceful stop';A ($CheckpointType -eq 'Disabled') 'checkpoint policy explicit'
    }
    function Add-VMHardDiskDrive {param($VM,$ControllerType,$ControllerNumber,$ControllerLocation,$Path,$ErrorAction)
        Guard $VM;A ($Path -eq 'C:\fixture\working.vhdx') 'only working VHDX attached'
        A ($ControllerNumber -eq 0 -and $ControllerLocation -eq 0) 'boot disk slot fixed'
        $script:Disk=[pscustomobject]@{Path=$Path;DiskNumber=$null;ControllerType=$ControllerType}
    }
    function Get-VMHardDiskDrive {param($VM,$ErrorAction) Guard $VM;return $script:Disk}
    function Set-VMFirmware {param($VM,$EnableSecureBoot,$FirstBootDevice,$SecureBootTemplate,$ErrorAction)
        Guard $VM;A ($FirstBootDevice -eq $script:Disk) 'use newly attached boot disk object'
        A ($script:Disk.ControllerType -eq 'SCSI') 'generation 2 uses SCSI'
        $script:Calls.Add([pscustomobject]@{Operation='Firmware';SecureBoot=$EnableSecureBoot;Template=$SecureBootTemplate})
    }
    function Set-VMBios {param($VM,$StartupOrder,$ErrorAction)
        Guard $VM;A ($script:Disk.ControllerType -eq 'IDE') 'generation 1 uses IDE'
        A ($StartupOrder[0] -eq 'IDE') 'generation 1 boots IDE first';$script:Calls.Add([pscustomobject]@{Operation='Bios'})
    }
    function Get-VMNetworkAdapter {param($VM,$ErrorAction) Guard $VM;[pscustomobject]@{SwitchName=$(if($script:Connected){'External'}else{''});MacAddress='00155D112233';VMId='new-test-vm'}}
    function Set-VMNetworkAdapter {param($VMNetworkAdapter,$StaticMacAddress,$ErrorAction)
        A ($VMNetworkAdapter.VMId -eq 'new-test-vm') 'MAC affects new VM only';A ($StaticMacAddress -eq '00155D112233') 'preserved MAC forwarded'
        $script:Calls.Add([pscustomobject]@{Operation='MAC'})
    }
    function Get-VM {param($Id,$ErrorAction) A ($Id -eq 'new-test-vm') 'isolation read bound to ID';return $script:VM}
    function Start-VM {param($VM,$ErrorAction) Guard $VM;$script:VM.State='Running';$script:Calls.Add([pscustomobject]@{Operation='Start'})}
    function Remove-VM {throw 'DESTRUCTIVE_CMD_FORBIDDEN'}
    function Connect-VMNetworkAdapter {throw 'NETWORK_CONNECT_FORBIDDEN'}
    function New-VMSwitch {throw 'NETWORK_CHANGE_FORBIDDEN'}
    function Mount-VHD {throw 'MOUNT_FORBIDDEN'}
    function Set-Disk {throw 'DISK_CHANGE_FORBIDDEN'}
    function Initialize-Disk {throw 'DISK_ERASE_FORBIDDEN'}
    function Stop-VM {throw 'EXISTING_VM_STOP_FORBIDDEN'}
    $p=[pscustomobject]@{ProcessorCount=2;Generation=2;SecureBoot='On';SecureBootTemplate='MicrosoftUEFICertificateAuthority';MacPolicy='Preserve';MacAddress='00155D112233'}
    $vm=New-RecoveryVM -Name 'Recovery-Test' -Generation 2 -Memory 1GB -Path 'C:\fixture'
    Set-RecoveryVmHardware -VM $vm -Profile $p -VhdxPath 'C:\fixture\working.vhdx'
    $fw=@($script:Calls|Where-Object Operation -eq 'Firmware')[0]
    A ($fw.SecureBoot -eq 'On' -and $fw.Template -eq 'MicrosoftUEFICertificateAuthority') 'secure boot template preserved'
    $s=Get-RecoveryVmIsolation $vm
    A ($s.Isolated -and $s.PhysicalDiskCount -eq 0 -and $s.DiskPaths[0] -eq 'C:\fixture\working.vhdx') 'isolation and no physical attachment'
    $p.Generation=1;$p.MacPolicy='New';$vm.Generation=1
    Set-RecoveryVmHardware -VM $vm -Profile $p -VhdxPath 'C:\fixture\working.vhdx'
    A (@($script:Calls|Where-Object Operation -eq 'Bios').Count -eq 1) 'generation 1 BIOS configured'
    A (@($script:Calls|Where-Object Operation -eq 'MAC').Count -eq 1) 'new MAC policy does not overwrite adapter MAC'
    Start-RecoveryVM $vm
    A ($script:VM.State -eq 'Running') 'explicit start wrapper only'
    $script:Connected=$true;$s=Get-RecoveryVmIsolation $vm
    A (-not $s.Isolated) 'connected adapter detected'
    $p.Generation=2;$failed=$false
    try{Set-RecoveryVmHardware -VM $vm -Profile $p -VhdxPath 'C:\fixture\working.vhdx'}catch{$failed=$true}
    A $failed 'connected newly created VM rejected'
    Write-Host ("PASS: {0} Hyper-V command-wiring assertions (native commands mocked)" -f $script:N)
}
