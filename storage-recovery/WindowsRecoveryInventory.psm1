#requires -Version 5.1
Set-StrictMode -Version Latest

# No command runs on import. These adapters are read-only and replaceable in tests.
function Get-WriPlatform { return ($env:OS -eq 'Windows_NT') }
function Get-WriHost { return $env:COMPUTERNAME }
function Get-WriDisks {
    Get-Disk -ErrorAction Stop | Select-Object Number,FriendlyName,SerialNumber,UniqueId,Size,LogicalSectorSize,PhysicalSectorSize,PartitionStyle,IsBoot,IsSystem,IsOffline,IsReadOnly,BusType
}
function Get-WriPhysicalDisks {
    Get-CimInstance -ClassName Win32_DiskDrive -Property Index -ErrorAction Stop | Select-Object Index
}
function Get-WriPartitions {
    Get-Partition -ErrorAction Stop | Select-Object DiskNumber,PartitionNumber,DriveLetter,Size,Offset,GptType,MbrType,Type,IsBoot,IsSystem,IsActive
}
function Get-WriOS {
    Get-CimInstance -ClassName Win32_OperatingSystem -Property SystemDrive,Caption,Version,BuildNumber,OSArchitecture,ProductType -ErrorAction Stop |
        Select-Object SystemDrive,Caption,Version,BuildNumber,OSArchitecture,ProductType
}
function Get-WriFirmware {
    (Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop).BiosFirmwareType
}
function Get-WriSecureBoot { Confirm-SecureBootUEFI -ErrorAction Stop }
function Get-WriPower {
    $fast=$null;$hibernate=$null;$errors=[Collections.Generic.List[object]]::new()
    try { $fast=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled }
    catch { $errors.Add((New-WriError 'FAST_STARTUP_QUERY_FAILED' $_)) }
    try { $hibernate=(Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled }
    catch { $errors.Add((New-WriError 'HIBERNATION_QUERY_FAILED' $_)) }
    [pscustomobject]@{FastStartup=$fast;Hibernation=$hibernate;Errors=$errors.ToArray()}
}
function Get-WriEncryptionStates {
    # Restrict CIM projection to a drive letter; only state-returning methods below.
    # Never invoke protector, recovery-password, key export, unlock or TPM-owner APIs.
    $errors=[Collections.Generic.List[object]]::new();$volumes=@()
    $items=@(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Property DriveLetter -ErrorAction Stop)
    foreach($item in $items){
        $protection=$null;$conversion=$null;$percentage=$null;$method=$null;$lock=$null;$known=$true
        try {
            $r=Invoke-CimMethod -InputObject $item -MethodName GetProtectionStatus -ErrorAction Stop
            if($r.ReturnValue -ne 0){throw 'BITLOCKER_STATE_METHOD_FAILED'}
            $protection=$r.ProtectionStatus
            $r=Invoke-CimMethod -InputObject $item -MethodName GetConversionStatus -ErrorAction Stop
            if($r.ReturnValue -ne 0){throw 'BITLOCKER_STATE_METHOD_FAILED'}
            $conversion=$r.ConversionStatus;$percentage=$r.EncryptionPercentage
            $r=Invoke-CimMethod -InputObject $item -MethodName GetEncryptionMethod -ErrorAction Stop
            if($r.ReturnValue -ne 0){throw 'BITLOCKER_STATE_METHOD_FAILED'}
            $method=$r.EncryptionMethod
            $r=Invoke-CimMethod -InputObject $item -MethodName GetLockStatus -ErrorAction Stop
            if($r.ReturnValue -ne 0){throw 'BITLOCKER_STATE_METHOD_FAILED'}
            $lock=$r.LockStatus
        } catch {$known=$false;$errors.Add((New-WriError 'BITLOCKER_VOLUME_STATE_UNAVAILABLE' $_))}
        $volumes += [pscustomobject]@{MountPoint=(Get-WriProperty $item DriveLetter);ProtectionStatus=$protection;ConversionStatus=$conversion;EncryptionPercentage=$percentage;EncryptionMethod=$method;LockStatus=$lock;QueryComplete=$known}
    }
    [pscustomobject]@{Volumes=$volumes;Errors=$errors.ToArray()}
}
function Get-WriProperty($Object,[string]$Name){
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $null
}
function New-WriError([string]$Code,$Record){
    # Exception messages and raw records could contain credentials from an upstream
    # provider. Emit only fixed codes, numeric HRESULT and the exception type name.
    $hr=$null;$type=$null
    if($null -ne $Record){$hr=$Record.Exception.HResult;$type=$Record.Exception.GetType().FullName}
    [pscustomobject]@{Code=$Code;HResult=$hr;ExceptionType=$type}
}
function Get-WriSafeError($Record){
    $code=[string](Get-WriProperty $Record Code)
    if($code -notin @('FAST_STARTUP_QUERY_FAILED','HIBERNATION_QUERY_FAILED','BITLOCKER_VOLUME_STATE_UNAVAILABLE')){$code='PROVIDER_STATE_UNAVAILABLE'}
    [pscustomobject]@{Code=$code;HResult=$null;ExceptionType=$null}
}
function Select-WriFields($Object,[string[]]$Fields){
    $result=[ordered]@{}
    foreach($field in $Fields){
        $v=Get-WriProperty $Object $field
        if($null -eq $v -or $v -is [string] -or $v -is [char] -or $v -is [ValueType]){$result[$field]=$v}
        else {$result[$field]=$null}
    }
    [pscustomobject]$result
}
function Convert-WriBooleanFlag($Value){
    if($null -eq $Value){return $null}
    if($Value -is [bool]){return $Value}
    if($Value -is [byte] -or $Value -is [int] -or $Value -is [long] -or $Value -is [uint32]){
        if($Value -eq 0){return $false};if($Value -eq 1){return $true}
    }
    return $null
}
function Convert-WriEnum($Value,[string[]]$Names){
    if($null -eq $Value -or $Value -is [bool]){return 'Unknown'}
    $n=0
    if([int]::TryParse([string]$Value,[ref]$n) -and $n -ge 0 -and $n -lt $Names.Count){return $Names[$n]}
    return 'Unknown'
}
function Convert-WriNamedEnum($Value,[string[]]$Names){
    if($null -eq $Value -or $Value -is [bool]){return 'Unknown'}
    $text=[string]$Value
    foreach($name in $Names){if($text -ieq $name){return $name}}
    return (Convert-WriEnum $Value $Names)
}
function Test-WriInteger($Value){
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
}
function Get-WindowsRecoveryInventory {
    [CmdletBinding()]param()
    $errors=[Collections.Generic.List[object]]::new();$warnings=[Collections.Generic.List[string]]::new()
    $disks=@();$partitions=@();$physical=@();$os=[pscustomobject]@{Status='Unknown';SystemDrive=$null;Caption=$null;Version=$null;BuildNumber=$null;Architecture=$null;ProductType=$null}
    $firmware=[pscustomobject]@{Status='Unknown';Type='Unknown';SecureBoot=[pscustomobject]@{Status='Unknown';Enabled=$null}}
    $power=[pscustomobject]@{Status='Unknown';FastStartupConfigured=$null;HibernationConfigured=$null;ShutdownState='Unknown';HibernatedState='Unknown'}
    $encryption=[pscustomobject]@{Status='Unknown';Volumes=@();RecoveryKeysCollected=$false;ProtectorIdentifiersCollected=$false;TpmDependency='Unknown'}
    $storageKnown=$true;$osKnown=$false;$physicalKnown=$true;$hostName=$null
    $supported=Get-WriPlatform
    if($supported -ne $true){$errors.Add((New-WriError 'WINDOWS_REQUIRED' $null));$storageKnown=$false;$physicalKnown=$false}
    else {
        $hostName=Get-WriHost
        try {
            $raw=@(Get-WriDisks)
            foreach($d in $raw){$disks+=Select-WriFields $d @('Number','FriendlyName','SerialNumber','UniqueId','Size','LogicalSectorSize','PhysicalSectorSize','PartitionStyle','IsBoot','IsSystem','IsOffline','IsReadOnly','BusType')}
            if($disks.Count -eq 0){throw 'DISK_INVENTORY_EMPTY'}
            $numbers=@($disks|ForEach-Object{$_.Number})
            if(@($numbers|Select-Object -Unique).Count -ne $numbers.Count){throw 'DISK_NUMBERS_AMBIGUOUS'}
            foreach($d in $disks){
                $d.PartitionStyle=Convert-WriNamedEnum $d.PartitionStyle @('RAW','MBR','GPT')
                if([string]$d.BusType -in @('Storage Spaces','StorageSpaces')){$d.BusType='Spaces'}
                if([string]$d.BusType -eq 'FileBackedVirtual'){$d.BusType='File Backed Virtual'}
                $d.BusType=Convert-WriNamedEnum $d.BusType @('Unknown','SCSI','ATAPI','ATA','1394','SSA','Fibre Channel','USB','RAID','iSCSI','SAS','SATA','SD','MMC','Virtual','File Backed Virtual','Spaces','NVMe')
                if($d.PartitionStyle -eq 'Unknown' -or $d.BusType -eq 'Unknown' -or -not (Test-WriInteger $d.Number) -or $d.Number -lt 0 -or -not (Test-WriInteger $d.Size)){throw 'DISK_ENUM_OR_GEOMETRY_UNKNOWN'}
                if($null -eq $d.Number -or $d.Size -le 0 -or $d.LogicalSectorSize -notin @(512,4096) -or [string]::IsNullOrWhiteSpace([string]$d.SerialNumber) -or [string]::IsNullOrWhiteSpace([string]$d.UniqueId) -or $d.IsBoot -isnot [bool] -or $d.IsSystem -isnot [bool] -or $d.IsOffline -isnot [bool] -or $d.IsReadOnly -isnot [bool]){throw 'DISK_FIELDS_INCOMPLETE'}
                if([string]$d.BusType -in @('RAID','Spaces','iSCSI','Virtual','File Backed Virtual')){$warnings.Add('NONSTANDARD_STORAGE_TOPOLOGY_REQUIRES_REVIEW')}
            }
        } catch {$storageKnown=$false;$errors.Add((New-WriError 'DISK_INVENTORY_INCOMPLETE' $_))}
        try {
            $physical=@(Get-WriPhysicalDisks|ForEach-Object{Select-WriFields $_ @('Index')})
            if($physical.Count -eq 0 -or @($physical|Where-Object{$null -eq $_.Index}).Count -gt 0 -or @($physical.Index|Select-Object -Unique).Count -ne $physical.Count){throw 'PHYSICAL_DISK_INDEX_UNKNOWN'}
            $a=@($physical|ForEach-Object{[int]$_.Index}|Sort-Object -Unique);$b=@($disks|ForEach-Object{[int]$_.Number}|Sort-Object -Unique)
            if(($a -join ',') -ne ($b -join ',')){throw 'PHYSICAL_DISK_ENUMERATION_MISMATCH'}
        } catch {$physicalKnown=$false;$errors.Add((New-WriError 'PHYSICAL_DISK_COVERAGE_UNKNOWN' $_))}
        try {
            foreach($p in @(Get-WriPartitions)){$partitions+=Select-WriFields $p @('DiskNumber','PartitionNumber','DriveLetter','Size','Offset','GptType','MbrType','Type','IsBoot','IsSystem','IsActive')}
            if($partitions.Count -eq 0){throw 'PARTITION_INVENTORY_EMPTY'}
            foreach($p in $partitions){
                if($null -eq $p.DiskNumber -or $null -eq $p.PartitionNumber -or @($disks|Where-Object{$_.Number -eq $p.DiskNumber}).Count -ne 1 -or $p.IsBoot -isnot [bool] -or $p.IsSystem -isnot [bool] -or $p.Size -le 0 -or $null -eq $p.Offset -or $p.Offset -lt 0){throw 'PARTITION_MAPPING_INCOMPLETE'}
            }
            $keys=@($partitions|ForEach-Object{[string]$_.DiskNumber+':'+[string]$_.PartitionNumber})
            if(@($keys|Select-Object -Unique).Count -ne $keys.Count){throw 'PARTITION_NUMBERS_AMBIGUOUS'}
            foreach($disk in $disks){
                $previousEnd=[decimal]0
                foreach($part in @($partitions|Where-Object{$_.DiskNumber -eq $disk.Number}|Sort-Object Offset)){
                    if(-not (Test-WriInteger $part.PartitionNumber) -or $part.PartitionNumber -le 0 -or -not (Test-WriInteger $part.Size) -or -not (Test-WriInteger $part.Offset)){throw 'PARTITION_GEOMETRY_UNKNOWN'}
                    if($disk.PartitionStyle -eq 'MBR' -and $part.IsActive -isnot [bool]){throw 'MBR_ACTIVE_STATE_UNKNOWN'}
                    $end=[decimal]$part.Offset+[decimal]$part.Size
                    if($end -gt [decimal]$disk.Size -or [decimal]$part.Offset -lt $previousEnd -or ([decimal]$part.Offset % $disk.LogicalSectorSize) -ne 0 -or ([decimal]$part.Size % $disk.LogicalSectorSize) -ne 0){throw 'PARTITION_GEOMETRY_INCONSISTENT'}
                    $previousEnd=$end
                }
            }
        } catch {$storageKnown=$false;$errors.Add((New-WriError 'PARTITION_INVENTORY_INCOMPLETE' $_))}
        try {
            $rawOS=@(Get-WriOS);if($rawOS.Count -ne 1){throw 'OS_AMBIGUOUS'}
            $s=Select-WriFields $rawOS[0] @('SystemDrive','Caption','Version','BuildNumber','OSArchitecture','ProductType')
            if([string]$s.SystemDrive -notmatch '^[A-Za-z]:$' -or $s.ProductType -notin @(1,2,3) -or [string]::IsNullOrWhiteSpace([string]$s.Version) -or [string]::IsNullOrWhiteSpace([string]$s.BuildNumber) -or [string]::IsNullOrWhiteSpace([string]$s.OSArchitecture)){throw 'OS_FIELDS_MISSING'}
            $os=[pscustomobject]@{Status='Known';SystemDrive=([string]$s.SystemDrive).ToUpperInvariant();Caption=$s.Caption;Version=$s.Version;BuildNumber=$s.BuildNumber;Architecture=$s.OSArchitecture;ProductType=$s.ProductType};$osKnown=$true
        } catch {$errors.Add((New-WriError 'OS_INVENTORY_UNKNOWN' $_))}
        try {
            $f=[string](Get-WriFirmware)
            if($f -in @('Uefi','2')){$firmware.Type='Uefi';$firmware.Status='Known'}
            elseif($f -in @('Bios','1')){$firmware.Type='Bios';$firmware.Status='Known';$firmware.SecureBoot.Status='NotApplicable'}
            else {throw 'FIRMWARE_UNKNOWN'}
        } catch {$errors.Add((New-WriError 'FIRMWARE_UNKNOWN' $_))}
        if($firmware.Type -eq 'Uefi'){
            try{$sb=Get-WriSecureBoot;if($sb -isnot [bool]){throw 'SECURE_BOOT_NOT_BOOLEAN'};$firmware.SecureBoot.Enabled=$sb;$firmware.SecureBoot.Status='Known'}
            catch{$errors.Add((New-WriError 'SECURE_BOOT_UNKNOWN' $_))}
        }
        try {
            $rawPower=Get-WriPower
            $power.FastStartupConfigured=Convert-WriBooleanFlag (Get-WriProperty $rawPower FastStartup)
            $power.HibernationConfigured=Convert-WriBooleanFlag (Get-WriProperty $rawPower Hibernation)
            foreach($err in @(Get-WriProperty $rawPower Errors)){if($null -ne $err){$errors.Add((Get-WriSafeError $err))}}
            if($null -ne $power.FastStartupConfigured -and $null -ne $power.HibernationConfigured){$power.Status='Known'}
            else {$power.Status='Partial';$errors.Add((New-WriError 'POWER_CONFIGURATION_UNKNOWN' $null))}
        } catch {$errors.Add((New-WriError 'POWER_CONFIGURATION_UNKNOWN' $_))}
        try {
            $rawEncryption=Get-WriEncryptionStates;$volumes=@();$complete=$true
            foreach($v in @(Get-WriProperty $rawEncryption Volumes)){
                if($null -eq $v){continue}
                $prot=Convert-WriEnum (Get-WriProperty $v ProtectionStatus) @('Off','On','Unknown')
                $conv=Convert-WriEnum (Get-WriProperty $v ConversionStatus) @('FullyDecrypted','FullyEncrypted','EncryptionInProgress','DecryptionInProgress','EncryptionPaused','DecryptionPaused')
                $method=Convert-WriEnum (Get-WriProperty $v EncryptionMethod) @('None','Aes128WithDiffuser','Aes256WithDiffuser','Aes128','Aes256','HardwareEncryption','XtsAes128','XtsAes256')
                $lock=Convert-WriEnum (Get-WriProperty $v LockStatus) @('Unlocked','Locked')
                $pct=Get-WriProperty $v EncryptionPercentage
                if($pct -isnot [ValueType] -or $pct -is [bool] -or $pct -lt 0 -or $pct -gt 100){$pct=$null}
                $point=[string](Get-WriProperty $v MountPoint)
                if($point -notmatch '^[A-Za-z]:$'){$point=$null}
                $known=((Get-WriProperty $v QueryComplete) -is [bool] -and (Get-WriProperty $v QueryComplete) -eq $true -and $prot -ne 'Unknown' -and $conv -ne 'Unknown' -and $method -ne 'Unknown' -and $lock -ne 'Unknown' -and $null -ne $pct)
                if(-not $known){$complete=$false}
                $volumes += [pscustomobject]@{MountPoint=$point;ProtectionStatus=$prot;ConversionStatus=$conv;EncryptionPercentage=$pct;EncryptionMethod=$method;LockStatus=$lock;Status=$(if($known){'Known'}else{'Unknown'})}
            }
            foreach($err in @(Get-WriProperty $rawEncryption Errors)){if($null -ne $err){$errors.Add((Get-WriSafeError $err));$complete=$false}}
            $encryption.Volumes=$volumes
            if($volumes.Count -eq 0){$encryption.Status='Unknown';$errors.Add((New-WriError 'BITLOCKER_COVERAGE_UNKNOWN' $null))}
            elseif($complete){$encryption.Status='Known'}else{$encryption.Status='Partial';$errors.Add((New-WriError 'BITLOCKER_STATES_PARTIAL' $null))}
            if($osKnown -and @($volumes|Where-Object{$_.MountPoint -eq $os.SystemDrive}).Count -ne 1){if($volumes.Count -gt 0){$encryption.Status='Partial'};$errors.Add((New-WriError 'OS_ENCRYPTION_COVERAGE_UNKNOWN' $null))}
        } catch {$errors.Add((New-WriError 'BITLOCKER_INVENTORY_UNKNOWN' $_))}
    }
    $required=[Collections.Generic.List[int]]::new();$potential=[Collections.Generic.List[int]]::new();$osDisk=$null;$depStatus='Unknown'
    if($storageKnown -and $physicalKnown -and $osKnown){
        $osParts=@($partitions|Where-Object{([string]$_.DriveLetter).TrimEnd(':') -ieq $os.SystemDrive.TrimEnd(':')})
        if($osParts.Count -eq 1){$osDisk=[int]$osParts[0].DiskNumber;$required.Add($osDisk)}else{$errors.Add((New-WriError 'OS_DISK_MAPPING_UNKNOWN' $null))}
        foreach($d in $disks){if($d.IsBoot -or $d.IsSystem){$required.Add([int]$d.Number)}}
        foreach($p in $partitions){
            if($p.IsBoot -or $p.IsSystem){$required.Add([int]$p.DiskNumber)}
            if($p.IsActive -eq $true -or ([string]$p.GptType).Trim('{}') -ieq 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'){$potential.Add([int]$p.DiskNumber)}
        }
        $systemFound=(@($disks|Where-Object{$_.IsSystem}).Count -gt 0 -or @($partitions|Where-Object{$_.IsSystem}).Count -gt 0)
        if($null -ne $osDisk -and $systemFound){$depStatus='Known'}else{$depStatus='Partial';$errors.Add((New-WriError 'BOOT_DEPENDENCY_INCOMPLETE' $null))}
    }
    $requiredNumbers=@($required.ToArray()|Sort-Object -Unique)
    $multi=$null;if($depStatus -eq 'Known'){$multi=($requiredNumbers.Count -gt 1)}
    if($multi -eq $true){$warnings.Add('MULTIPLE_DISKS_REQUIRED_FOR_CURRENT_WINDOWS_BOOT')}
    if($warnings.Contains('NONSTANDARD_STORAGE_TOPOLOGY_REQUIRES_REVIEW')){$depStatus='Partial';$errors.Add((New-WriError 'STORAGE_TOPOLOGY_NOT_VALIDATED' $null))}
    [pscustomobject]@{
        SchemaVersion=1;Kind='WindowsHostRecovery';CollectedUtc=[DateTime]::UtcNow.ToString('o');Host=$hostName
        SnapshotComplete=($errors.Count -eq 0);ReadOnly=$true;BackupReadiness='NotEvaluated';RestoreValidated=$false;ShutdownConfirmed=$false
        Disks=$disks;Partitions=$partitions;PhysicalDiskIndexes=@($physical|ForEach-Object{$_.Index});OS=$os;OsDiskNumber=$osDisk
        Firmware=$firmware;Power=$power;Encryption=$encryption
        Tpm=[pscustomobject]@{Dependency='Unknown';Presence='NotCollected';KeyMaterialCollected=$false;Reason='Protector and application dependencies are intentionally not inspected.'}
        BootDependencies=[pscustomobject]@{Status=$depStatus;Scope='CurrentWindowsOnly';RequiredDiskNumbers=$requiredNumbers;PotentialBootDiskNumbers=@($potential.ToArray()|Sort-Object -Unique);MultipleDisksRequired=$multi;ApplicationDataDependencies='Unknown';OtherOSBootDependencies='Unknown';FolderMountPointDataDependencies='Unknown';NetworkStorageDependencies='Unknown';CloudOnlineOnlyData='Unknown'}
        Warnings=@($warnings.ToArray()|Select-Object -Unique);Errors=$errors.ToArray()
    }
}
Export-ModuleMember -Function Get-WindowsRecoveryInventory
