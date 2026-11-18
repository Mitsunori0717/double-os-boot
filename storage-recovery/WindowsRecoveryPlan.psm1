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
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)]$RawManifest,$Evidence,[object[]]$AdditionalRawManifests=@())
    if((Get-WRPValue $Evidence SchemaVersion) -eq 2){return Test-WRPExpanded $Inventory $RawManifest $Evidence $AdditionalRawManifests}
    if(@($AdditionalRawManifests).Count -gt 0){throw 'EXPANDED_EVIDENCE_SCHEMA_REQUIRED'}
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
        [ValidateRange(2147483648,1099511627776)][long]$MemoryStartupBytes=4GB,[ValidateRange(1,256)][int]$ProcessorCount=2,[object[]]$AdditionalRawManifests=@())
    $a=Test-WindowsRecoverySuitability $Inventory $RawManifest $Evidence -AdditionalRawManifests $AdditionalRawManifests
    if(-not $a.RecoveryProfileAllowed){throw ('WINDOWS_RECOVERY_PROFILE_BLOCKED: '+($a.Reasons -join ', '))}
    if((Get-WRPValue $Evidence SchemaVersion) -eq 2){return New-WRPExpandedProfile $a $Evidence $MemoryStartupBytes $ProcessorCount}
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

# Expanded planning remains pure. IDs and hashes are bindings, not authentication.
function Test-WRPExpanded($Inventory,$RawManifest,$Evidence,[object[]]$AdditionalRawManifests){
    $r=[Collections.Generic.List[string]]::new();$p=[Collections.Generic.List[string]]::new()
    $evidenceFields=@('SchemaVersion','Operator','RecordedUtc','NoWritesDuringAcquisition','QuiescentStartUtc','QuiescentEndUtc','SourceSetComplete','SourceSetQuiescedTogether','SourceSetSha256','Sources','FullShutdownVerified','FastStartupNotUsed','NotHibernated','AllDependentDisksBackedUp','BasicStorageTopologyVerified','AllApplicationDataIncluded','NoExternalStorageDependencies','IdentityChangeAccepted','AcceptNewTpmIdentity','OriginalTpmSecretsRequired','HostWindows11CpuSupported','BitLockerVolumes','RecoveryKeyStoredSeparately','RecoveryKeyMatchesSource','AcceptManualUnlock')
    if(-not(Test-WRPAllowedFields $Evidence $evidenceFields)){$r.Add('EVIDENCE_UNKNOWN_OR_SECRET_FIELD')}
    foreach($binding in @(Get-WRPValue $Evidence Sources)){if(-not(Test-WRPAllowedFields $binding @('SourceImageSha256','SerialNumber','Size','LogicalSectorSize','Role','ControllerLocation'))){$r.Add('SOURCE_EVIDENCE_UNKNOWN_OR_SECRET_FIELD')}}
    foreach($proof in @(Get-WRPValue $Evidence BitLockerVolumes)){if($null -ne $proof -and -not(Test-WRPAllowedFields $proof @('MountPoint','SourceImageSha256','RecoveryKeyId','SeparateStorageVerified','RecoveryKeyIdMatched'))){$r.Add('BITLOCKER_EVIDENCE_UNKNOWN_OR_SECRET_FIELD')}}
    $sources=@();$numbers=@();$hashes=@();$serials=@();$manifests=@($RawManifest)+@($AdditionalRawManifests)
    if($manifests.Count -lt 1 -or $manifests.Count -gt 8){$r.Add('SOURCE_SET_COUNT_INVALID')}
    if((Get-WRPValue $Inventory SchemaVersion) -ne 1 -or (Get-WRPValue $Inventory Kind) -cne 'WindowsHostRecovery' -or -not(Test-WRPTrue (Get-WRPValue $Inventory SnapshotComplete)) -or @(Get-WRPValue $Inventory Errors).Count -gt 0){$r.Add('INVENTORY_INCOMPLETE_OR_UNKNOWN')}
    $disks=@(Get-WRPValue $Inventory Disks);$parts=@(Get-WRPValue $Inventory Partitions);$i=0
    foreach($m in $manifests){
        $meta=Get-WRPValue $m Metadata;$src=Get-WRPValue $meta Source;$hash=[string](Get-WRPValue $m Sha256);$size=Get-WRPValue $m Size;$serial=[string](Get-WRPValue $src SerialNumber);$sector=Get-WRPValue $src LogicalSectorSize
        $valid=$true
        if((Get-WRPValue $m SchemaVersion) -ne 1 -or (Get-WRPValue $m State) -cne 'verified' -or $hash -cnotmatch '^[0-9a-f]{64}$'){$valid=$false}
        if(-not(Test-WRPTrue (Get-WRPValue $meta FullSectorImage)) -or -not(Test-WRPTrue (Get-WRPValue $meta SourceWriteProtected)) -or (Get-WRPValue $meta AcquisitionMode) -cne 'offline-block'){$valid=$false}
        if(-not(Test-WRPInteger $size) -or [decimal]$size -le 0 -or [decimal]$size -gt [uint64]::MaxValue -or [decimal]$size % 512 -ne 0 -or [string](Get-WRPValue $src Size) -cne [string]$size -or [string]::IsNullOrWhiteSpace($serial) -or [string]::IsNullOrWhiteSpace([string](Get-WRPValue $src UniqueId)) -or $sector -notin @(512,4096)){$valid=$false}
        if(-not $valid){$p.Add('VERIFIED_OFFLINE_SOURCE_MANIFEST_REQUIRED');$i++;continue}
        if($sector -ne 512){$r.Add('VHDX_512_LOGICAL_SECTOR_REQUIRED')}
        if($hashes -contains $hash -or $serials -contains $serial){$r.Add('DUPLICATE_SOURCE_IDENTITY')};$hashes+= $hash;$serials+=$serial
        $matches=@($disks|Where-Object {[string](Get-WRPValue $_ SerialNumber) -ceq $serial -and [string](Get-WRPValue $_ Size) -ceq [string]$size -and [string](Get-WRPValue $_ LogicalSectorSize) -ceq [string]$sector})
        if($matches.Count -ne 1){$r.Add('SOURCE_INVENTORY_BINDING_AMBIGUOUS');$i++;continue}
        $d=$matches[0];$num=Get-WRPValue $d Number
        if(-not(Test-WRPInteger $num) -or $numbers -contains $num -or [string]::IsNullOrWhiteSpace([string](Get-WRPValue $d UniqueId))){$r.Add('SOURCE_INVENTORY_ID_INVALID')}
        if((Get-WRPValue $d BusType) -cnotin @('SATA','NVMe','USB','SCSI','ATA','SAS')){$r.Add('BASIC_STORAGE_TOPOLOGY_REQUIRED')}
        if((Get-WRPValue $d PartitionStyle) -cne 'GPT'){$r.Add('EXPANDED_RECOVERY_REQUIRES_GPT')}
        $numbers+=$num
        $sources+=[pscustomobject]@{SourceImageSha256=$hash;SerialNumber=$serial;Size=[uint64]$size;LogicalSectorSize=[int]$sector;Role=$(if($i -eq 0){'Boot'}else{'Data'});ControllerLocation=$i}
        $i++
    }
    foreach($reason in $p){$r.Add($reason)}
    $os=Get-WRPValue $Inventory OS;$build=[string](Get-WRPValue $os BuildNumber);$product=Get-WRPValue $os ProductType;$guest='Unknown'
    if((Get-WRPValue $os Status) -ceq 'Known' -and [string](Get-WRPValue $os Version) -ceq ('10.0.'+$build) -and (Get-WRPValue $os Architecture) -in @('64-bit','x64','AMD64')){
        if($product -eq 1 -and $build -in @('19044','19045')){$guest='Windows10'}
        if($product -eq 1 -and $build -in @('22000','22621','22631','26100','26200')){$guest='Windows11'}
        if($product -eq 3 -and $build -in @('14393','17763','20348','26100')){$guest='WindowsServer'}
    }
    if($guest -eq 'Unknown'){$r.Add('WINDOWS_VERSION_ARCHITECTURE_UNSUPPORTED_OR_UNKNOWN')}
    $drive=([string](Get-WRPValue $os SystemDrive)).TrimEnd(':')
    $osp=@($parts|Where-Object {([string](Get-WRPValue $_ DriveLetter)).TrimEnd(':') -ieq $drive -and $drive -match '^[A-Za-z]$'})
    if($osp.Count -ne 1 -or $numbers -notcontains (Get-WRPValue $osp[0] DiskNumber)){$r.Add('OS_DISK_NOT_IN_VERIFIED_SOURCE_SET')}
    $boot=Get-WRPValue $Inventory BootDependencies;$required=@(Get-WRPValue $boot RequiredDiskNumbers);$potential=@(Get-WRPValue $boot PotentialBootDiskNumbers)
    if((Get-WRPValue $boot Status) -cne 'Known' -or $required.Count -lt 1 -or $potential.Count -ne 1 -or $numbers.Count -lt 1){$r.Add('BOOT_DEPENDENCIES_UNPROVEN')}
    else{
        foreach($n in @($required)+@($potential)){if(-not(Test-WRPInteger $n) -or $numbers -notcontains $n){$r.Add('BOOT_DEPENDENCY_SOURCE_MISSING')}}
        if($potential[0] -ne $numbers[0]){$r.Add('PRIMARY_SOURCE_MUST_CONTAIN_BOOT_PARTITION')}
    }
    $fw=Get-WRPValue $Inventory Firmware;$sb=Get-WRPValue $fw SecureBoot
    if((Get-WRPValue $fw Status) -cne 'Known' -or (Get-WRPValue $fw Type) -cne 'Uefi' -or (Get-WRPValue $sb Status) -cne 'Known' -or (Get-WRPValue $sb Enabled) -isnot [bool]){$r.Add('UEFI_SECURE_BOOT_STATE_REQUIRED')}
    if($guest -eq 'Windows11'){
        if(-not(Test-WRPTrue (Get-WRPValue $sb Enabled))){$r.Add('WINDOWS11_SECURE_BOOT_REQUIRED')}
        if(-not(Test-WRPTrue (Get-WRPValue $Evidence HostWindows11CpuSupported))){$r.Add('WINDOWS11_HOST_CPU_ATTESTATION_REQUIRED')}
        if($sources.Count -lt 1 -or $sources[0].Size -lt 64GB){$r.Add('WINDOWS11_MINIMUM_DISK_SIZE_REQUIRED')}
    }
    foreach($flag in @('NoWritesDuringAcquisition','SourceSetComplete','SourceSetQuiescedTogether','FullShutdownVerified','FastStartupNotUsed','NotHibernated','AllDependentDisksBackedUp','BasicStorageTopologyVerified','AllApplicationDataIncluded','NoExternalStorageDependencies','IdentityChangeAccepted','AcceptNewTpmIdentity')){
        if(-not(Test-WRPTrue (Get-WRPValue $Evidence $flag))){$r.Add('OPERATOR_EVIDENCE_REQUIRED: '+$flag)}
    }
    if((Get-WRPValue $Evidence OriginalTpmSecretsRequired) -isnot [bool] -or (Get-WRPValue $Evidence OriginalTpmSecretsRequired) -ne $false){$r.Add('ORIGINAL_TPM_SECRETS_UNRESOLVED')}
    if([string]::IsNullOrWhiteSpace([string](Get-WRPValue $Evidence Operator))){$r.Add('OPERATOR_IDENTITY_REQUIRED')}
    $when=[DateTimeOffset]::MinValue;$collected=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParse([string](Get-WRPValue $Evidence RecordedUtc),[ref]$when) -or -not[DateTimeOffset]::TryParse([string](Get-WRPValue $Inventory CollectedUtc),[ref]$collected) -or $when -lt $collected -or $when -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){$r.Add('EVIDENCE_TIME_INVALID')}
    $start=[DateTimeOffset]::MinValue;$end=[DateTimeOffset]::MinValue
    $window=([DateTimeOffset]::TryParse([string](Get-WRPValue $Evidence QuiescentStartUtc),[ref]$start) -and [DateTimeOffset]::TryParse([string](Get-WRPValue $Evidence QuiescentEndUtc),[ref]$end) -and $start -ge $collected -and $end -ge $start -and $end -le $when)
    if(-not $window){$r.Add('QUIESCENCE_WINDOW_INVALID')}
    foreach($m in $manifests){$created=[DateTimeOffset]::MinValue;if(-not[DateTimeOffset]::TryParse([string](Get-WRPValue $m CreatedUtc),[ref]$created) -or -not $window -or $created -lt $start -or $created -gt $end){$r.Add('IMAGE_OUTSIDE_QUIESCENCE_WINDOW')}}
    $setHash='';if($sources.Count -gt 0){$setHash=Get-WRPSourceSetHash $sources}
    if([string](Get-WRPValue $Evidence SourceSetSha256) -cne $setHash){$r.Add('SOURCE_SET_HASH_MISMATCH')}
    if(-not(Test-WRPArrayProperty $Evidence Sources) -or -not(Test-WRPArrayProperty $Evidence BitLockerVolumes)){$r.Add('EVIDENCE_ARRAY_REQUIRED')}
    $bindings=@(Get-WRPValue $Evidence Sources)
    if($bindings.Count -ne $sources.Count){$r.Add('EVIDENCE_SOURCE_SET_MISMATCH')}
    foreach($s in $sources){
        $match=@($bindings|Where-Object {[string](Get-WRPValue $_ SourceImageSha256) -ceq $s.SourceImageSha256})
        if($match.Count -ne 1){$r.Add('EVIDENCE_SOURCE_BINDING_MISMATCH');continue}
        foreach($key in @('SerialNumber','Size','LogicalSectorSize','Role','ControllerLocation')){if([string](Get-WRPValue $match[0] $key) -cne [string](Get-WRPValue $s $key)){$r.Add('EVIDENCE_SOURCE_BINDING_MISMATCH')}}
    }
    $encrypted=$false;$enc=Get-WRPValue $Inventory Encryption;$volumes=@(Get-WRPValue $enc Volumes);$seen=@();$keyIds=@()
    if((Get-WRPValue $enc Status) -cne 'Known' -or $volumes.Count -lt 1){$r.Add('ENCRYPTION_STATE_UNKNOWN')}
    foreach($v in $volumes){
        $mount=([string](Get-WRPValue $v MountPoint)).TrimEnd('\');$mapping=@($parts|Where-Object {([string](Get-WRPValue $_ DriveLetter)).TrimEnd(':') -ieq $mount.TrimEnd(':')})
        if($mount -notmatch '^[A-Za-z]:$' -or $seen -contains $mount -or $mapping.Count -ne 1 -or $numbers -notcontains (Get-WRPValue $mapping[0] DiskNumber)){$r.Add('VOLUME_SOURCE_MAPPING_UNPROVEN');continue};$seen+=$mount
        $pct=Get-WRPValue $v EncryptionPercentage;$conversion=Get-WRPValue $v ConversionStatus;$method=Get-WRPValue $v EncryptionMethod;$protect=Get-WRPValue $v ProtectionStatus;$lock=Get-WRPValue $v LockStatus
        if((Get-WRPValue $v Status) -cne 'Known' -or $pct -is [bool] -or $null -eq $pct -or $lock -notin @('Locked','Unlocked')){$r.Add('ENCRYPTION_STATE_UNKNOWN');continue}
        if($conversion -ceq 'FullyDecrypted' -and $method -ceq 'None' -and $pct -eq 0 -and $protect -ceq 'Off' -and $lock -ceq 'Unlocked'){continue}
        if($conversion -cne 'FullyEncrypted' -or $pct -ne 100 -or $method -cnotin @('Aes128WithDiffuser','Aes256WithDiffuser','Aes128','Aes256','XtsAes128','XtsAes256') -or $protect -notin @('On','Off')){$r.Add('ENCRYPTION_TRANSITION_OR_UNKNOWN_UNSUPPORTED');continue}
        $encrypted=$true
        $proofs=@((Get-WRPValue $Evidence BitLockerVolumes)|Where-Object {([string](Get-WRPValue $_ MountPoint)) -ieq $mount})
        if($proofs.Count -ne 1){$r.Add('BITLOCKER_VOLUME_EVIDENCE_REQUIRED');continue}
        $proof=$proofs[0];$id=[string](Get-WRPValue $proof RecoveryKeyId)
        if((Get-WRPValue $proof RecoveryKeyId) -isnot [string] -or $id -cnotmatch '^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\})$' -or $keyIds -contains $id.Trim('{}')){$r.Add('RECOVERY_KEY_IDENTIFIER_INVALID_OR_DUPLICATE')};$keyIds+=$id.Trim('{}')
        foreach($flag in @('SeparateStorageVerified','RecoveryKeyIdMatched')){if(-not(Test-WRPTrue (Get-WRPValue $proof $flag))){$r.Add('BITLOCKER_KEY_ATTESTATION_REQUIRED')}}
        $md=@($sources|Where-Object {$_.ControllerLocation -eq [array]::IndexOf($numbers,(Get-WRPValue $mapping[0] DiskNumber))})
        if($md.Count -ne 1 -or [string](Get-WRPValue $proof SourceImageSha256) -cne $md[0].SourceImageSha256){$r.Add('BITLOCKER_SOURCE_BINDING_MISMATCH')}
    }
    foreach($part in $parts){
        $letter=([string](Get-WRPValue $part DriveLetter)).TrimEnd(':')
        if($numbers -contains (Get-WRPValue $part DiskNumber) -and $letter -match '^[A-Za-z]$' -and $seen -notcontains ($letter+':')){$r.Add('DEPENDENT_VOLUME_ENCRYPTION_COVERAGE_UNPROVEN')}
    }
    if(@((Get-WRPValue $Evidence BitLockerVolumes)|Where-Object {$null -ne $_}).Count -ne $keyIds.Count){$r.Add('BITLOCKER_EVIDENCE_SET_MISMATCH')}
    if($seen -notcontains ($drive+':')){$r.Add('OS_ENCRYPTION_COVERAGE_UNPROVEN')}
    if($encrypted){foreach($flag in @('RecoveryKeyStoredSeparately','RecoveryKeyMatchesSource','AcceptManualUnlock')){if(-not(Test-WRPTrue (Get-WRPValue $Evidence $flag))){$r.Add('BITLOCKER_MANUAL_RECOVERY_ATTESTATION_REQUIRED')}}}
    [pscustomobject]@{AssessmentVersion=2;InventoryCollectedUtc=[string](Get-WRPValue $Inventory CollectedUtc);SourceSetSha256=$setHash;State='PlanOnly';BackupPreservationSupported=($p.Count -eq 0);RecoveryProfileAllowed=($r.Count -eq 0);PreservationReasons=$p.ToArray();Reasons=$r.ToArray();Generation=2;SecureBoot=$(if(Test-WRPTrue (Get-WRPValue $sb Enabled)){'On'}else{'Off'});Sources=$sources;GuestOS=$guest;BitLockerState=$(if($encrypted){'Encrypted'}else{'Clear'});BootTested=$false;RestoreTested=$false;LicenseValidated=$false;DataCompletenessVerified=$false;OriginalTpmSecretsRecreated=$false;Warnings=@('Operator attestations and unsigned metadata are not machine proof.','Every dependent disk requires an offline image and independent verification.','A new TPM cannot recreate old TPM secrets, Windows Hello or hardware-bound activation.','Enter recovery secrets yourself in the isolated guest console only. Never place keys in JSON, command lines, logs or chat.','Boot, unlock, applications and licensing remain untested.')}
}
function New-WRPExpandedProfile($a,$Evidence,[long]$MemoryStartupBytes,[int]$ProcessorCount){
    if($a.GuestOS -eq 'Windows11' -and ($MemoryStartupBytes -lt 4GB -or $ProcessorCount -lt 2)){throw 'WINDOWS11_MINIMUM_MEMORY_CPU_REQUIRED'}
    [pscustomobject]@{ProfileVersion=2;EvidenceRecordedUtc=[string](Get-WRPValue $Evidence RecordedUtc);InventoryCollectedUtc=$a.InventoryCollectedUtc;NoWritesDuringAcquisition=$true;QuiescentStartUtc=[string](Get-WRPValue $Evidence QuiescentStartUtc);QuiescentEndUtc=[string](Get-WRPValue $Evidence QuiescentEndUtc);SourceSetComplete=$true;SourceSetQuiescedTogether=$true;SourceSetSha256=$a.SourceSetSha256;SourceDiskCount=@($a.Sources).Count;Sources=$a.Sources;SourceImageSha256=$a.Sources[0].SourceImageSha256;NetworkAdapterCount=1;Generation=2;MemoryStartupBytes=$MemoryStartupBytes;ProcessorCount=$ProcessorCount;SecureBoot=$a.SecureBoot;SecureBootTemplate='MicrosoftWindows';TpmRequired=$true;TpmPolicy='NewLocalProtector';OriginalTpmSecretsRequired=$false;AcceptNewTpmIdentity=$true;HostWindows11CpuSupported=(Test-WRPTrue (Get-WRPValue $Evidence HostWindows11CpuSupported));GuestOS=$a.GuestOS;BitLockerState=$a.BitLockerState;RecoveryKeyStoredSeparately=(Test-WRPTrue (Get-WRPValue $Evidence RecoveryKeyStoredSeparately));RecoveryKeyMatchesSource=(Test-WRPTrue (Get-WRPValue $Evidence RecoveryKeyMatchesSource));AcceptManualUnlock=(Test-WRPTrue (Get-WRPValue $Evidence AcceptManualUnlock));RecoveryUnlockPolicy='UserConsoleOnly';EncryptionDependenciesResolved=$true;IdentityPolicy='NewVmId';MacPolicy='New';SourceType='WindowsPhysical';BootTested=$false;RestoreTested=$false;LicenseValidated=$false;OriginalTpmSecretsRecreated=$false}
}

function Test-WRPAllowedFields($Object,[string[]]$Allowed){
    if($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType] -or $Object -is [array]){return $false}
    $names=if($Object -is [Collections.IDictionary]){@($Object.Keys)}else{@($Object.PSObject.Properties.Name)}
    foreach($name in $names){
        if($Allowed -cnotcontains [string]$name){return $false}
        $v=Get-WRPValue $Object $name
        if($v -is [string] -and $v -match '(?:[0-9]{6}-){7}[0-9]{6}|[0-9]{48}') {return $false}
    }
    return $true
}

function Get-WRPSourceSetHash($Sources){
    # Shared pure canonical projection. Import alone performs no Hyper-V query.
    $path=Join-Path $PSScriptRoot 'HyperVRecovery.psm1'
    $module=@(Get-Module HyperVRecovery|Where-Object Path -eq $path)|Select-Object -First 1
    if($null -eq $module){$module=Import-Module $path -PassThru}
    & $module {param($s) Get-RecoverySourceSetHash -Sources $s} $Sources
}

function Test-WRPArrayProperty($Object,[string]$Name){
    if($Object -is [Collections.IDictionary]){return ($Object[$Name] -is [array])}
    $p=$Object.PSObject.Properties[$Name];return ($null -ne $p -and $p.Value -is [array])
}
