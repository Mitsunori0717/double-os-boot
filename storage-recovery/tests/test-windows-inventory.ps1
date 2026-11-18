#requires -Version 5.1
# Only mock query adapters; never read this machine's disks, registry, encryption or firmware.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WindowsRecoveryInventory.psm1') -Force -PassThru
$script:Count=0
function Assert($Value,[string]$Message){if(-not $Value){throw "TEST FAILED: $Message"};$script:Count++}
function Has-Error($Result,[string]$Code){return @($Result.Errors|Where-Object{$_.Code -eq $Code}).Count -gt 0}
& $module {
    $script:OriginalEncryptionAdapter=${function:Get-WriEncryptionStates}
    $script:F=$null
    function script:Get-Disk {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Get-Partition {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Get-CimInstance {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Invoke-CimMethod {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Get-ComputerInfo {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Confirm-SecureBootUEFI {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Get-ItemProperty {throw 'REAL_QUERY_FORBIDDEN'}
    function script:Fixture-Read([string]$Name){$script:F.Calls.Add($Name);if($Name -in $script:F.Fail){throw 'SECRET_RECOVERY_KEY_MUST_NOT_ESCAPE'};return $script:F[$Name]}
    function script:Get-WriPlatform {Fixture-Read 'Platform'}
    function script:Get-WriHost {Fixture-Read 'Host'}
    function script:Get-WriDisks {Fixture-Read 'Disks'}
    function script:Get-WriPhysicalDisks {Fixture-Read 'Physical'}
    function script:Get-WriPartitions {Fixture-Read 'Partitions'}
    function script:Get-WriOS {Fixture-Read 'OS'}
    function script:Get-WriFirmware {Fixture-Read 'Firmware'}
    function script:Get-WriSecureBoot {Fixture-Read 'SecureBoot'}
    function script:Get-WriPower {Fixture-Read 'Power'}
    function script:Get-WriEncryptionStates {Fixture-Read 'Encryption'}
    function script:Reset-Fixture {
        $script:F=@{
            Calls=[Collections.Generic.List[string]]::new();Fail=@();Platform=$true;Host='fixture-host'
            Disks=@([pscustomobject]@{Number=0;FriendlyName='Fixture';SerialNumber='SERIAL-0';UniqueId='ID-0';Size=[uint64]4GB;LogicalSectorSize=512;PhysicalSectorSize=4096;PartitionStyle='GPT';IsBoot=$true;IsSystem=$true;IsOffline=$false;IsReadOnly=$false;BusType='NVMe';Secret='DO_NOT_EXPORT'})
            Physical=@([pscustomobject]@{Index=0})
            Partitions=@([pscustomobject]@{DiskNumber=0;PartitionNumber=1;DriveLetter=$null;Size=[uint64]100MB;Offset=[uint64]1MB;GptType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}';MbrType=$null;Type='System';IsBoot=$false;IsSystem=$true;IsActive=$false},[pscustomobject]@{DiskNumber=0;PartitionNumber=2;DriveLetter='C';Size=[uint64]3GB;Offset=[uint64]101MB;GptType='basic';MbrType=$null;Type='Basic';IsBoot=$true;IsSystem=$false;IsActive=$false})
            OS=[pscustomobject]@{SystemDrive='C:';Caption='Windows fixture';Version='10.0.26200';BuildNumber='26200';OSArchitecture='64-bit';ProductType=1;Secret='DO_NOT_EXPORT'}
            Firmware='Uefi';SecureBoot=$true
            Power=[pscustomobject]@{FastStartup=0;Hibernation=0;Errors=@()}
            Encryption=[pscustomobject]@{Volumes=@([pscustomobject]@{MountPoint='C:';ProtectionStatus=0;ConversionStatus=0;EncryptionPercentage=0;EncryptionMethod=0;LockStatus=0;QueryComplete=$true;KeyProtector='DO_NOT_EXPORT';RecoveryPassword='DO_NOT_EXPORT'});Errors=@()}
        }
    }
    Reset-Fixture
}
function Reset {& $module {Reset-Fixture}}
$r=Get-WindowsRecoveryInventory
Assert $r.SnapshotComplete 'normal fixture observations complete'
Assert ($r.Kind -eq 'WindowsHostRecovery' -and $r.SchemaVersion -eq 1) 'schema'
Assert ($r.ReadOnly -and -not $r.ShutdownConfirmed -and -not $r.RestoreValidated) 'no readiness overclaim'
Assert ($r.OS.ProductType -eq 1 -and $r.OS.Architecture -eq '64-bit') 'OS fields'
Assert ($r.OsDiskNumber -eq 0 -and $r.BootDependencies.RequiredDiskNumbers.Count -eq 1) 'OS disk mapping'
Assert ($r.BootDependencies.Status -eq 'Known' -and -not $r.BootDependencies.MultipleDisksRequired) 'single disk boot dependencies'
Assert ($r.Firmware.Type -eq 'Uefi' -and $r.Firmware.SecureBoot.Enabled) 'UEFI secure boot'
Assert ($r.Encryption.Status -eq 'Known' -and $r.Encryption.Volumes[0].ConversionStatus -eq 'FullyDecrypted') 'clear encryption state'
Assert ($r.Power.FastStartupConfigured -eq $false -and $r.Power.ShutdownState -eq 'Unknown') 'config not shutdown evidence'
Assert ($r.Tpm.Dependency -eq 'Unknown' -and $r.Tpm.Presence -eq 'NotCollected') 'TPM absence not inferred'
Assert (($r|ConvertTo-Json -Depth 12) -notmatch 'DO_NOT_EXPORT|KeyProtector|RecoveryPassword') 'no secret property export'
Assert ($r.BootDependencies.ApplicationDataDependencies -eq 'Unknown' -and $r.BootDependencies.CloudOnlineOnlyData -eq 'Unknown') 'external application data not guessed'
Reset;& $module {$script:F.Platform=$false}
$r=Get-WindowsRecoveryInventory
Assert (-not $r.SnapshotComplete -and (Has-Error $r 'WINDOWS_REQUIRED')) 'unsupported platform'
Assert ((& $module {$script:F.Calls.Count}) -eq 1) 'no query adapters after platform refusal'
foreach($stage in @('Disks','Physical','Partitions','OS','Firmware','SecureBoot','Power','Encryption')){
    Reset;& $module {param($x)$script:F.Fail=@($x)} $stage
    $r=Get-WindowsRecoveryInventory
    Assert (-not $r.SnapshotComplete) "stage failure incomplete $stage"
    Assert (($r|ConvertTo-Json -Depth 12) -notmatch 'SECRET_RECOVERY_KEY_MUST_NOT_ESCAPE') "error sanitized $stage"
}
Reset;& $module {$script:F.Firmware='Bios'};$r=Get-WindowsRecoveryInventory
Assert ($r.Firmware.Type -eq 'Bios' -and $r.Firmware.SecureBoot.Status -eq 'NotApplicable') 'BIOS secure boot not false inference'
Assert (-not ((& $module {$script:F.Calls.ToArray()}) -contains 'SecureBoot')) 'do not probe UEFI on BIOS'
Reset;& $module {$script:F.Firmware='Unknown'};$r=Get-WindowsRecoveryInventory
Assert ($r.Firmware.Status -eq 'Unknown' -and -not $r.SnapshotComplete) 'unknown firmware'
Reset;& $module {$script:F.SecureBoot='False'};$r=Get-WindowsRecoveryInventory
Assert ($r.Firmware.SecureBoot.Status -eq 'Unknown') 'string secure boot not boolean'
Reset;& $module {$script:F.Power.FastStartup=$null};$r=Get-WindowsRecoveryInventory
Assert ($null -eq $r.Power.FastStartupConfigured -and $r.Power.Status -eq 'Partial') 'missing power value not disabled'
Reset;& $module {$script:F.Power.FastStartup=1;$script:F.Power.Hibernation=1};$r=Get-WindowsRecoveryInventory
Assert ($r.Power.FastStartupConfigured -and $r.Power.HibernationConfigured) 'power enabled flags'
Reset;& $module {$script:F.Encryption.Volumes[0].ProtectionStatus=1;$script:F.Encryption.Volumes[0].ConversionStatus=1;$script:F.Encryption.Volumes[0].EncryptionPercentage=100;$script:F.Encryption.Volumes[0].EncryptionMethod=7};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Volumes[0].ConversionStatus -eq 'FullyEncrypted' -and $r.Encryption.Volumes[0].EncryptionMethod -eq 'XtsAes256') 'encrypted states'
Assert ($r.Encryption.TpmDependency -eq 'Unknown') 'encrypted does not imply TPM dependency'
Reset;& $module {$script:F.Encryption.Volumes[0].ConversionStatus=2;$script:F.Encryption.Volumes[0].EncryptionPercentage=40};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Volumes[0].ConversionStatus -eq 'EncryptionInProgress') 'conversion underway visible'
Reset;& $module {$script:F.Encryption.Volumes=@()};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Status -eq 'Unknown' -and (Has-Error $r 'BITLOCKER_COVERAGE_UNKNOWN')) 'empty encryption query not clear'
Reset;& $module {$script:F.Encryption.Volumes[0].MountPoint='D:'};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Status -eq 'Partial' -and (Has-Error $r 'OS_ENCRYPTION_COVERAGE_UNKNOWN')) 'OS encryption coverage required'
Reset;& $module {$script:F.Encryption.Volumes[0].EncryptionMethod='SECRET_DATA';$script:F.Encryption.Volumes[0].EncryptionPercentage=101};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Volumes[0].EncryptionMethod -eq 'Unknown' -and $null -eq $r.Encryption.Volumes[0].EncryptionPercentage) 'unknown encryption values'
Assert (($r|ConvertTo-Json -Depth 12) -notmatch 'SECRET_DATA') 'no arbitrary encryption provider string'
Reset;& $module {$script:F.Encryption.Volumes[0].QueryComplete='true'};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Status -eq 'Partial') 'querycomplete must be boolean'
Reset;& $module {$script:F.Disks=@()};$r=Get-WindowsRecoveryInventory
Assert ($r.BootDependencies.Status -eq 'Unknown' -and -not $r.SnapshotComplete) 'empty disks fail closed'
Reset;& $module {$script:F.Disks[0].SerialNumber=''};$r=Get-WindowsRecoveryInventory
Assert (-not $r.SnapshotComplete -and $r.BootDependencies.Status -eq 'Unknown') 'missing disk identity'
Reset;& $module {$script:F.Partitions[1].DiskNumber=99};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'orphan partition fails closed'
Reset;& $module {$script:F.Physical+=([pscustomobject]@{Index=2})};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PHYSICAL_DISK_COVERAGE_UNKNOWN')) 'Get-Disk omissions flagged'
Reset;& $module {$script:F.Partitions[1].DriveLetter='D'};$r=Get-WindowsRecoveryInventory
Assert ($null -eq $r.OsDiskNumber -and $r.BootDependencies.Status -eq 'Partial') 'OS drive cannot be guessed'
Reset;& $module {
    $d=$script:F.Disks[0].PSObject.Copy();$d.Number=1;$d.SerialNumber='SERIAL-1';$d.UniqueId='ID-1';$d.IsBoot=$false;$d.IsSystem=$true
    $script:F.Disks[0].IsSystem=$false;$script:F.Disks+=$d;$script:F.Physical+=([pscustomobject]@{Index=1});$script:F.Partitions[0].DiskNumber=1
};$r=Get-WindowsRecoveryInventory
Assert ($r.BootDependencies.MultipleDisksRequired -and ($r.BootDependencies.RequiredDiskNumbers -join ',') -eq '0,1') 'boot manager on other disk included'
Reset;& $module {$script:F.Disks[0].BusType='Spaces'};$r=Get-WindowsRecoveryInventory
Assert (-not $r.SnapshotComplete -and $r.BootDependencies.Status -eq 'Partial') 'nonstandard topology not ready'
Reset;& $module {$script:F.Disks[0].PartitionStyle=2;$script:F.Disks[0].BusType=17;$script:F.Partitions[0].IsActive=$null;$script:F.Partitions[1].IsActive=$null};$r=Get-WindowsRecoveryInventory
Assert ($r.SnapshotComplete -and $r.Disks[0].PartitionStyle -ceq 'GPT' -and $r.Disks[0].BusType -ceq 'NVMe') 'numeric storage enums normalize to strings; GPT IsActive null valid'
$j=$r|ConvertTo-Json -Depth 12|ConvertFrom-Json
Assert ($j.Disks[0].PartitionStyle -is [string] -and $j.Disks[0].BusType -is [string]) 'JSON roundtrip enum names preserved'
Reset;& $module {$script:F.Disks[0].BusType=16};$r=Get-WindowsRecoveryInventory
Assert ($r.Disks[0].BusType -eq 'Spaces' -and (Has-Error $r 'STORAGE_TOPOLOGY_NOT_VALIDATED')) 'numeric Spaces detected'
Reset;& $module {$script:F.Disks[0].BusType=999};$r=Get-WindowsRecoveryInventory
Assert (-not $r.SnapshotComplete -and $r.Disks[0].BusType -eq 'Unknown') 'unknown bus enum fail closed'
Reset;& $module {$script:F.Disks[0].PartitionStyle=999};$r=Get-WindowsRecoveryInventory
Assert (-not $r.SnapshotComplete) 'unknown partition enum fail closed'
Reset;& $module {$script:F.Disks[0].PartitionStyle='MBR';$script:F.Partitions[0].IsActive=$null};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'MBR active unknown fail closed'
Reset;& $module {$script:F.Partitions[1].Size=[uint64]5GB};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'partition beyond disk extent rejected'
Reset;& $module {$script:F.Partitions[1].Offset=[uint64]50MB};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'overlapping partitions rejected'
Reset;& $module {$script:F.Partitions[1].Offset=[uint64]106954753};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'unaligned partition rejected'
Reset;& $module {$script:F.Partitions[1].PartitionNumber=1};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PARTITION_INVENTORY_INCOMPLETE')) 'duplicate partition number rejected'
Reset;& $module {$script:F.Encryption.Errors=@([pscustomobject]@{Code='SECRET_DO_NOT_EXPORT';Message='DO_NOT_EXPORT'})};$r=Get-WindowsRecoveryInventory
Assert ((Has-Error $r 'PROVIDER_STATE_UNAVAILABLE') -and ($r|ConvertTo-Json -Depth 12) -notmatch 'DO_NOT_EXPORT') 'provider errors strict allowlist'
Reset;& $module {$script:F.Encryption.Volumes[0].ConversionStatus=1;$script:F.Encryption.Volumes[0].ProtectionStatus=0;$script:F.Encryption.Volumes[0].EncryptionPercentage=100};$r=Get-WindowsRecoveryInventory
Assert ($r.Encryption.Volumes[0].ConversionStatus -eq 'FullyEncrypted' -and $r.Encryption.Volumes[0].ProtectionStatus -eq 'Off') 'suspended encryption not labelled decrypted'
# Test the real encryption adapter with mocked CIM only; prove the allowed method list.
& $module {
    $script:CimMethods=[Collections.Generic.List[string]]::new();$script:CimProperties=@()
    function script:Get-CimInstance {param($Namespace,$ClassName,$Property,$ErrorAction)
        if($ClassName -ne 'Win32_EncryptableVolume'){throw 'UNEXPECTED_QUERY'}
        $script:CimProperties=$Property
        [pscustomobject]@{DriveLetter='C:';HiddenSecret='NEVER_EXPORT_THIS'}
    }
    function script:Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction)
        $script:CimMethods.Add($MethodName)
        switch($MethodName){
            'GetProtectionStatus'{[pscustomobject]@{ReturnValue=0;ProtectionStatus=0}}
            'GetConversionStatus'{[pscustomobject]@{ReturnValue=0;ConversionStatus=0;EncryptionPercentage=0}}
            'GetEncryptionMethod'{[pscustomobject]@{ReturnValue=0;EncryptionMethod=0}}
            'GetLockStatus'{[pscustomobject]@{ReturnValue=0;LockStatus=0}}
            default{throw 'SECRET_API_FORBIDDEN'}
        }
    }
    $script:AdapterResult=& $script:OriginalEncryptionAdapter
}
Assert ((& $module {$script:CimProperties -join ','}) -eq 'DriveLetter') 'CIM projection only drive letter'
Assert ((& $module {$script:CimMethods -join ','}) -eq 'GetProtectionStatus,GetConversionStatus,GetEncryptionMethod,GetLockStatus') 'only approved read-only state methods'
Assert (((& $module {$script:AdapterResult})|ConvertTo-Json -Depth 8) -notmatch 'NEVER_EXPORT_THIS|HiddenSecret') 'adapter sanitizes raw CIM object'
Write-Host ("PASS: {0} Windows inventory assertions (all queries mocked; no machine inventory read)" -f $script:Count)
