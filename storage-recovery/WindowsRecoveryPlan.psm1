#requires -Version 5.1
# Pure assessment/profile generation. Does not access devices, registry, VM services, or keys.
Set-StrictMode -Version Latest
function Get-WRPValue($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $null
}
function Test-WRPTrue($Value){return ($Value -is [bool] -and $Value -eq $true)}
function Test-WRPInteger($Value){return ($Value -isnot [bool] -and ([string]$Value) -cmatch '^[0-9]+$')}
function Test-WindowsRecoverySuitability {
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)]$RawManifest,$Evidence)
    $r=[Collections.Generic.List[string]]::new()
    $preservation=[Collections.Generic.List[string]]::new()
    $meta=Get-WRPValue $RawManifest Metadata;$src=Get-WRPValue $meta Source
    $hash=[string](Get-WRPValue $RawManifest Sha256)
    $size=Get-WRPValue $RawManifest Size
    if((Get-WRPValue $RawManifest SchemaVersion) -ne 1 -or (Get-WRPValue $RawManifest State) -cne 'verified' -or $hash -cnotmatch '^[0-9a-f]{64}$'){$preservation.Add('VERIFIED_RAW_MANIFEST_REQUIRED')}
    if(-not(Test-WRPTrue (Get-WRPValue $meta FullSectorImage)) -or (Get-WRPValue $meta AcquisitionMode) -cne 'offline-block' -or -not(Test-WRPTrue (Get-WRPValue $meta SourceWriteProtected))){$preservation.Add('OFFLINE_WRITE_PROTECTED_FULL_SECTOR_IMAGE_REQUIRED')}
    if(-not(Test-WRPInteger $size) -or [decimal]$size -le 0 -or [decimal]$size % 512 -ne 0 -or (Get-WRPValue $src Size) -ne $size){$preservation.Add('SOURCE_SIZE_INVALID')}
    foreach($key in @('SerialNumber','UniqueId')){if([string]::IsNullOrWhiteSpace([string](Get-WRPValue $src $key))){$preservation.Add('SOURCE_IDENTITY_REQUIRED: '+$key)}}
    if((Get-WRPValue $src LogicalSectorSize) -notin @(512,4096)){$preservation.Add('SOURCE_SECTOR_UNKNOWN')}
    foreach($reason in $preservation){$r.Add($reason)}
    if((Get-WRPValue $Inventory SchemaVersion) -ne 1 -or (Get-WRPValue $Inventory Kind) -cne 'WindowsHostRecovery'){$r.Add('WINDOWS_INVENTORY_SCHEMA_REQUIRED')}
    if(-not(Test-WRPTrue (Get-WRPValue $Inventory SnapshotComplete)) -or @(Get-WRPValue $Inventory Errors).Count -gt 0){$r.Add('INVENTORY_INCOMPLETE')}
    $os=Get-WRPValue $Inventory OS
    $build=[string](Get-WRPValue $os BuildNumber);$product=Get-WRPValue $os ProductType
    $arch=[string](Get-WRPValue $os Architecture)
    $osSupported=$false
    if((Get-WRPValue $os Status) -ceq 'Known' -and ([string](Get-WRPValue $os Version)) -ceq ('10.0.'+$build) -and $arch -in @('64-bit','x64','AMD64')) {
        if($product -eq 1 -and $build -in @('19044','19045')){$osSupported=$true}
        if($product -eq 3 -and $build -in @('14393','17763','20348')){$osSupported=$true}
    }
    if($product -eq 1 -and (Test-WRPInteger $build) -and [decimal]$build -ge 22000){$r.Add('WINDOWS11_VTPM_NOT_IMPLEMENTED')}
    elseif(-not $osSupported){$r.Add('WINDOWS_VERSION_ARCHITECTURE_UNSUPPORTED_OR_UNKNOWN')}
    $parts=@(Get-WRPValue $Inventory Partitions)
    $systemDrive=([string](Get-WRPValue $os SystemDrive)).TrimEnd(':')
    $osp=@($parts|Where-Object {([string](Get-WRPValue $_ DriveLetter)) -ieq $systemDrive -and -not [string]::IsNullOrEmpty($systemDrive)})
    $disk=$null
    if($osp.Count -ne 1){$r.Add('OS_DISK_MAPPING_AMBIGUOUS')}else{
        $number=Get-WRPValue $osp[0] DiskNumber
        $matches=@((Get-WRPValue $Inventory Disks)|Where-Object {(Get-WRPValue $_ Number) -eq $number})
        if($matches.Count -ne 1){$r.Add('OS_DISK_MAPPING_AMBIGUOUS')}else{$disk=$matches[0]}
    }
    if($null -ne $disk){
        $sameIdentity=@((Get-WRPValue $Inventory Disks)|Where-Object {
            [string](Get-WRPValue $_ SerialNumber) -ceq [string](Get-WRPValue $src SerialNumber) -and
            [string](Get-WRPValue $_ Size) -ceq [string](Get-WRPValue $src Size) -and
            [string](Get-WRPValue $_ LogicalSectorSize) -ceq [string](Get-WRPValue $src LogicalSectorSize)
        })
        if($sameIdentity.Count -ne 1){$r.Add('SOURCE_IDENTITY_AMBIGUOUS_IN_INVENTORY')}
        foreach($key in @('SerialNumber','Size','LogicalSectorSize')){
            if([string](Get-WRPValue $disk $key) -cne [string](Get-WRPValue $src $key)){$r.Add('SOURCE_INVENTORY_BINDING_MISMATCH: '+$key)}
        }
        # Windows UniqueId can be partition-table ID while Linux UniqueId is /dev/disk/by-id.
        # Serial + exact bytes + geometry bind across operating systems; both IDs are retained.
        if([string]::IsNullOrWhiteSpace([string](Get-WRPValue $disk UniqueId))){$r.Add('INVENTORY_DISK_ID_REQUIRED')}
    }
    if((Get-WRPValue $src LogicalSectorSize) -ne 512){$r.Add('VHDX_512_LOGICAL_SECTOR_REQUIRED')}
    $boot=Get-WRPValue $Inventory BootDependencies
    $required=@(Get-WRPValue $boot RequiredDiskNumbers);$potential=@(Get-WRPValue $boot PotentialBootDiskNumbers)
    if((Get-WRPValue $boot Status) -cne 'Known' -or (Get-WRPValue $boot MultipleDisksRequired) -isnot [bool] -or (Get-WRPValue $boot MultipleDisksRequired) -ne $false -or $required.Count -ne 1 -or $null -eq $disk -or $required[0] -ne (Get-WRPValue $disk Number) -or $potential.Count -lt 1 -or @($potential|Where-Object {$_ -ne (Get-WRPValue $disk Number)}).Count -gt 0){$r.Add('SINGLE_DISK_BOOT_DEPENDENCIES_UNPROVEN')}
    $fw=Get-WRPValue $Inventory Firmware;$sb=Get-WRPValue $fw SecureBoot
    $generation=0;$secure='Off'
    if((Get-WRPValue $fw Status) -ceq 'Known' -and (Get-WRPValue $fw Type) -ceq 'Uefi' -and (Get-WRPValue $disk PartitionStyle) -ceq 'GPT'){
        $generation=2
        if((Get-WRPValue $sb Status) -cne 'Known' -or (Get-WRPValue $sb Enabled) -isnot [bool]){$r.Add('SECURE_BOOT_STATE_UNKNOWN')}
        elseif((Get-WRPValue $sb Enabled) -eq $true){$secure='On'}
    }elseif((Get-WRPValue $fw Status) -ceq 'Known' -and (Get-WRPValue $fw Type) -ceq 'Bios' -and (Get-WRPValue $disk PartitionStyle) -ceq 'MBR'){$generation=1}
    else{$r.Add('FIRMWARE_PARTITION_STYLE_UNSUPPORTED_OR_UNKNOWN')}
    if($generation -eq 1 -and [decimal]$size -gt 2TB){$r.Add('GEN1_BOOT_DISK_EXCEEDS_2TB')}
    $enc=Get-WRPValue $Inventory Encryption;$volumes=@(Get-WRPValue $enc Volumes)
    if((Get-WRPValue $enc Status) -cne 'Known' -or $volumes.Count -lt 1){$r.Add('ENCRYPTION_STATE_UNKNOWN')}
    else {
        foreach($v in $volumes){
            if((Get-WRPValue $v Status) -cne 'Known' -or (Get-WRPValue $v EncryptionMethod) -cne 'None' -or (Get-WRPValue $v EncryptionPercentage) -is [bool] -or (Get-WRPValue $v EncryptionPercentage) -ne 0 -or $null -eq (Get-WRPValue $v EncryptionPercentage) -or (Get-WRPValue $v ConversionStatus) -cne 'FullyDecrypted' -or (Get-WRPValue $v ProtectionStatus) -cne 'Off' -or (Get-WRPValue $v LockStatus) -cne 'Unlocked'){$r.Add('ENCRYPTED_LOCKED_OR_UNKNOWN_VOLUME_UNSUPPORTED');break}
        }
        if(@($volumes|Where-Object {([string](Get-WRPValue $_ MountPoint)).TrimEnd('\') -ieq ($systemDrive+':')}).Count -ne 1){$r.Add('OS_ENCRYPTION_COVERAGE_UNPROVEN')}
    }
    foreach($flag in @('FullShutdownVerified','FastStartupNotUsed','NotHibernated','AllApplicationDataOnSourceDisk','NoExternalStorageDependencies','TpmDependencyAbsent','IdentityChangeAccepted')){
        if(-not(Test-WRPTrue (Get-WRPValue $Evidence $flag))){$r.Add('OPERATOR_EVIDENCE_REQUIRED: '+$flag)}
    }
    if((Get-WRPValue $Evidence SchemaVersion) -ne 1 -or [string]::IsNullOrWhiteSpace([string](Get-WRPValue $Evidence Operator))){$r.Add('OPERATOR_IDENTITY_REQUIRED')}
    foreach($key in @('SourceImageSha256','SerialNumber','Size')){
        $expected=switch($key){'SourceImageSha256'{$hash};default{Get-WRPValue $src $key}}
        if([string](Get-WRPValue $Evidence $key) -cne [string]$expected){$r.Add('EVIDENCE_IMAGE_BINDING_MISMATCH: '+$key)}
    }
    $when=[DateTimeOffset]::MinValue;$collected=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string](Get-WRPValue $Evidence RecordedUtc),[ref]$when) -or -not [DateTimeOffset]::TryParse([string](Get-WRPValue $Inventory CollectedUtc),[ref]$collected) -or $when -lt $collected -or $when -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){$r.Add('EVIDENCE_TIME_INVALID')}
    $safeDisk=$null
    if($null -ne $disk){
        $safeDisk=[pscustomobject]@{Number=[int](Get-WRPValue $disk Number);UniqueId=[string](Get-WRPValue $disk UniqueId);SerialNumber=[string](Get-WRPValue $disk SerialNumber);Size=[uint64](Get-WRPValue $disk Size);LogicalSectorSize=[int](Get-WRPValue $disk LogicalSectorSize);PartitionStyle=[string](Get-WRPValue $disk PartitionStyle)}
    }
    [pscustomobject]@{
        AssessmentVersion=1;State='PlanOnly';BackupPreservationSupported=($preservation.Count -eq 0)
        RecoveryProfileAllowed=($r.Count -eq 0);PreservationReasons=$preservation.ToArray();Reasons=$r.ToArray()
        Generation=$generation;SecureBoot=$secure;SourceImageSha256=$hash;SourceDisk=$safeDisk
        BootTested=$false;RestoreTested=$false;LicenseValidated=$false;DataCompletenessVerified=$false
        Warnings=@('Manifest integrity metadata is not authenticated; this assessment does not rehash the image or authorize acquisition.','Operator evidence is an attestation, not machine proof of clean shutdown or complete application dependencies.','Live inventory cannot prove later shutdown. Capture a full non-hybrid shutdown before offline acquisition.','Installed programs, settings and user data on the source disk are preserved as sectors; external storage, cloud data, keys and hardware-bound activation are not recreated.','OS build eligibility describes this tool only, not Microsoft support lifecycle. Physical-hardware restoration is not provided.')
    }
}
function New-WindowsRecoveryVmProfile {
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)]$RawManifest,[Parameter(Mandatory)]$Evidence,
        [ValidateRange(2147483648,1099511627776)][long]$MemoryStartupBytes=4GB,[ValidateRange(1,256)][int]$ProcessorCount=2)
    $a=Test-WindowsRecoverySuitability $Inventory $RawManifest $Evidence
    if(-not $a.RecoveryProfileAllowed){throw ('WINDOWS_RECOVERY_PROFILE_BLOCKED: '+($a.Reasons -join ', '))}
    [pscustomobject]@{
        ProfileVersion=1;SourceDiskCount=1;NetworkAdapterCount=1;SourceImageSha256=$a.SourceImageSha256
        Generation=$a.Generation;MemoryStartupBytes=$MemoryStartupBytes;ProcessorCount=$ProcessorCount
        SecureBoot=$a.SecureBoot;SecureBootTemplate='MicrosoftWindows';TpmRequired=$false;EncryptionDependenciesResolved=$true
        IdentityPolicy='NewVmId';MacPolicy='New';SourceType='WindowsPhysical';SourceInventoryDiskId=(Get-WRPValue $a.SourceDisk UniqueId)
        SourceSerialNumber=(Get-WRPValue $a.SourceDisk SerialNumber);SourceSize=(Get-WRPValue $a.SourceDisk Size)
        OperatorEvidenceRecordedUtc=(Get-WRPValue $Evidence RecordedUtc);BootTested=$false;RestoreTested=$false;LicenseValidated=$false
    }
}
Export-ModuleMember -Function Test-WindowsRecoverySuitability,New-WindowsRecoveryVmProfile
