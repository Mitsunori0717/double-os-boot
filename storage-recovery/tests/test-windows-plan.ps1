#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WindowsRecoveryPlan.psm1') -Force
$script:Count=0
function Assert-True($Value,$Message){if(-not $Value){throw "FAILED: $Message"};$script:Count++}
function New-Fixture {
    @{
        I=@{SchemaVersion=1;Kind='WindowsHostRecovery';CollectedUtc='2026-01-01T00:00:00Z';SnapshotComplete=$true;Errors=@()
            OS=@{Status='Known';SystemDrive='C:';BuildNumber='19045';Version='10.0.19045';Architecture='64-bit';ProductType=1}
            Disks=@(@{Number=0;SerialNumber='SERIAL';UniqueId='WINDOWS-ID';Size=4096;LogicalSectorSize=512;PartitionStyle='GPT'})
            Partitions=@(@{DiskNumber=0;DriveLetter='C'})
            BootDependencies=@{Status='Known';RequiredDiskNumbers=@(0);PotentialBootDiskNumbers=@(0);MultipleDisksRequired=$false}
            Firmware=@{Type='Uefi';Status='Known';SecureBoot=@{Status='Known';Enabled=$true}}
            Encryption=@{Status='Known';Volumes=@(@{MountPoint='C:';Status='Known';EncryptionMethod='None';EncryptionPercentage=0;ConversionStatus='FullyDecrypted';ProtectionStatus='Off';LockStatus='Unlocked'})}
        }
        M=@{SchemaVersion=1;State='verified';Size=4096;Sha256=('a'*64);Metadata=@{AcquisitionMode='offline-block';FullSectorImage=$true;SourceWriteProtected=$true;Source=@{SerialNumber='SERIAL';UniqueId='LINUX-ID';Size=4096;LogicalSectorSize=512}}}
        E=@{SchemaVersion=1;Operator='fixture';RecordedUtc='2026-01-01T01:00:00Z';SourceImageSha256=('a'*64);SerialNumber='SERIAL';Size=4096;FullShutdownVerified=$true;FastStartupNotUsed=$true;NotHibernated=$true;AllApplicationDataOnSourceDisk=$true;NoExternalStorageDependencies=$true;TpmDependencyAbsent=$true;IdentityChangeAccepted=$true}
    }
}
function Assess($f){Test-WindowsRecoverySuitability $f.I $f.M $f.E}
$f=New-Fixture;$a=Assess $f
Assert-True $a.RecoveryProfileAllowed ('valid UEFI: '+($a.Reasons -join ','))
Assert-True $a.BackupPreservationSupported 'preservation assessment'
$p=New-WindowsRecoveryVmProfile $f.I $f.M $f.E
Assert-True ($p.Generation -eq 2 -and $p.SecureBoot -eq 'On' -and $p.MacPolicy -eq 'New') 'generation2 profile'
Assert-True (-not $p.BootTested -and -not $p.RestoreTested) 'not recovery claim'
$f=New-Fixture;$f.I.Firmware.Type='Bios';$f.I.Disks[0].PartitionStyle='MBR'
Assert-True ((New-WindowsRecoveryVmProfile $f.I $f.M $f.E).Generation -eq 1) 'BIOS MBR generation1'
$f=New-Fixture;$f.I.OS.BuildNumber='22631'
$a=Assess $f;Assert-True (-not $a.RecoveryProfileAllowed -and $a.BackupPreservationSupported -and $a.Reasons -contains 'WINDOWS11_VTPM_NOT_IMPLEMENTED') 'Win11 preservation only'
$f=New-Fixture;$f.I.OS.BuildNumber='20348';$f.I.OS.Version='10.0.20348';$f.I.OS.ProductType=3
Assert-True (Assess $f).RecoveryProfileAllowed 'Server2022 supported'
foreach($mutate in @(
    {$f.I.OS.BuildNumber='99999'},{$f.I.OS.ProductType=2},{$f.I.OS.Architecture='ARM64'},
    {$f.I.OS.Status='Unknown'},{$f.I.SnapshotComplete=$false},{$f.I.Errors=@('QUERY_FAILED')},
    {$f.I.Disks[0].SerialNumber='WRONG'},{$f.I.Disks[0].Size=8192},
    {$f.I.Disks[0].LogicalSectorSize=4096},{$f.I.Partitions=@()},
    {$f.I.BootDependencies.RequiredDiskNumbers=@(0,1)},{$f.I.BootDependencies.PotentialBootDiskNumbers=@(0,1)},
    {$f.I.BootDependencies.Status='Unknown'},{$f.I.Firmware.Type='Unknown'},
    {$f.I.Firmware.SecureBoot.Enabled='false'},{$f.I.Disks[0].PartitionStyle='MBR'},
    {$f.I.Encryption.Status='Unknown'},{$f.I.Encryption.Volumes[0].ConversionStatus='FullyEncrypted'},
    {$f.I.Encryption.Volumes[0].LockStatus='Locked'},{$f.I.Encryption.Volumes[0].MountPoint='D:'},
    {$f.E.SourceImageSha256=('b'*64)},{$f.E.SerialNumber='OTHER'},{$f.E.Size=8192},
    {$f.E.RecordedUtc='2025-01-01T00:00:00Z'},{$f.E.RecordedUtc='bad'},{$f.E.Operator=''},
    {$f.M.State='copied'},{$f.M.Sha256='bad'},{$f.M.Metadata.SourceWriteProtected=$false},
    {$f.M.Metadata.AcquisitionMode='fixture-file'},{$f.M.Metadata.FullSectorImage=$false},
    {$f.M.Size=0},{$f.M.Size=$true},{$f.M.Metadata.Source.UniqueId=''}
)){
    $f=New-Fixture;& $mutate
    Assert-True (-not(Assess $f).RecoveryProfileAllowed) ('rejected '+$mutate)
    $blocked=$false;try{New-WindowsRecoveryVmProfile $f.I $f.M $f.E|Out-Null}catch{$blocked=$true}
    Assert-True $blocked 'profile refuses'
}
foreach($flag in @('FullShutdownVerified','FastStartupNotUsed','NotHibernated','AllApplicationDataOnSourceDisk','NoExternalStorageDependencies','TpmDependencyAbsent','IdentityChangeAccepted')){
    foreach($value in @($false,'true',1)){
        $f=New-Fixture;$f.E[$flag]=$value;Assert-True (-not(Assess $f).RecoveryProfileAllowed) ('strict evidence '+$flag)
    }
}
$f=New-Fixture;$f.E=$null;Assert-True (-not(Assess $f).RecoveryProfileAllowed) 'no operator evidence'
$f=New-Fixture;$f.M.Metadata.Source.LogicalSectorSize=4096;$f.I.Disks[0].LogicalSectorSize=4096
Assert-True ((Assess $f).BackupPreservationSupported -and -not (Assess $f).RecoveryProfileAllowed) '4kn preservation only'
$f=New-Fixture;$f.I.Disks[0].RecoveryPassword='DO_NOT_OUTPUT'
Assert-True ((Assess $f | ConvertTo-Json -Depth 10) -notmatch 'DO_NOT_OUTPUT') 'source projection hides unexpected properties'
$f=New-Fixture;$f.I.Disks+=@{Number=1;SerialNumber='SERIAL';Size=4096;LogicalSectorSize=512}
Assert-True (-not(Assess $f).RecoveryProfileAllowed) 'duplicate source identity rejected'
foreach($change in @({$f.I.Encryption.Volumes[0].Status='Unknown'},{$f.I.Encryption.Volumes[0].EncryptionMethod='XtsAes256'},{$f.I.Encryption.Volumes[0].EncryptionPercentage=20})){
    $f=New-Fixture;& $change;Assert-True (-not(Assess $f).RecoveryProfileAllowed) 'encryption consistency'
}
$f=New-Fixture;$rejected=$false;try{New-WindowsRecoveryVmProfile $f.I $f.M $f.E -MemoryStartupBytes 1GB|Out-Null}catch{$rejected=$true};Assert-True $rejected 'Windows x64 minimum memory'
$f=New-Fixture;$f.I.Firmware.Type='Bios';$f.I.Disks[0].PartitionStyle='MBR'
$large=2TB+512;$f.M.Size=$large;$f.M.Metadata.Source.Size=$large;$f.I.Disks[0].Size=$large;$f.E.Size=$large
$a=Assess $f;Assert-True (-not $a.RecoveryProfileAllowed -and $a.Reasons -contains 'GEN1_BOOT_DISK_EXCEEDS_2TB') 'Gen1 boot size boundary'
Write-Output ("PASS WindowsRecoveryPlan assertions="+$script:Count)
