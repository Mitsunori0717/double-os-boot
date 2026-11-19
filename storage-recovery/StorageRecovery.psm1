#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-RecoveryProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if($Object -is [Collections.IDictionary]) { return $Object[$Name] }; $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}
function Test-RecoveryHasProperty($Object,[string]$Name) {
    if($null -eq $Object) { return $false }
    if($Object -is [Collections.IDictionary]) { return $Object.Contains($Name) }
    return ($null -ne $Object.PSObject.Properties[$Name])
}
function Test-DiskIdentity($Disk) {
    return ($null -ne $Disk -and
        -not [string]::IsNullOrWhiteSpace([string](Get-RecoveryProperty $Disk UniqueId)) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-RecoveryProperty $Disk SerialNumber)) -and
        (Get-RecoveryProperty $Disk Size) -gt 0 -and
        (Get-RecoveryProperty $Disk LogicalSectorSize) -in @(512,4096))
}
function Test-SameDisk($A, $B) {
    return (([string](Get-RecoveryProperty $A UniqueId)).Trim() -eq ([string](Get-RecoveryProperty $B UniqueId)).Trim() -and
        ([string](Get-RecoveryProperty $A SerialNumber)).Trim() -eq ([string](Get-RecoveryProperty $B SerialNumber)).Trim() -and
        (Get-RecoveryProperty $A Size) -eq (Get-RecoveryProperty $B Size) -and
        (Get-RecoveryProperty $A LogicalSectorSize) -eq (Get-RecoveryProperty $B LogicalSectorSize))
}
function Get-RecoveryInventory {
    [CmdletBinding()]param()
    $errors = [Collections.Generic.List[string]]::new()
    $disks = @(); $vms = @(); $complete = $true
    try {
        $disks = @(Get-Disk -ErrorAction Stop | Select-Object Number,FriendlyName,UniqueId,SerialNumber,Size,LogicalSectorSize,PhysicalSectorSize,IsOffline,IsReadOnly,IsBoot,IsSystem,PartitionStyle)
    } catch { $errors.Add('DISK_INVENTORY_UNAVAILABLE: ' + $_.Exception.Message); $complete=$false }
    try {
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop | Select-Object DiskNumber,Path,ControllerType,ControllerNumber,ControllerLocation)
            $nics = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop | Select-Object Name,SwitchName,MacAddress,DynamicMacAddressEnabled,IPAddresses)
            $assigned = @(Get-VMAssignableDevice -VMName $vm.Name -ErrorAction Stop)
            if ($assigned.Count -gt 0) { $errors.Add('ASSIGNED_DEVICE_UNSUPPORTED: ' + $vm.Name); $complete=$false }
            $firmware=$null; $bios=$null; $security=$null
            if($vm.Generation -eq 2){
                $f=Get-VMFirmware -VM $vm -ErrorAction Stop
                $firmware=[pscustomobject]@{SecureBoot=[string]$f.SecureBoot;SecureBootTemplate=$f.SecureBootTemplate;BootOrder=@($f.BootOrder|Select-Object BootType,Description,FirmwarePath)}
                $sec=Get-VMSecurity -VM $vm -ErrorAction Stop
                $security=[pscustomobject]@{TpmEnabled=(Get-RecoveryProperty $sec TpmEnabled);EncryptStateAndVmMigrationTraffic=(Get-RecoveryProperty $sec EncryptStateAndVmMigrationTraffic);Shielded=(Get-RecoveryProperty $sec Shielded);BindToHostTpm=(Get-RecoveryProperty $sec BindToHostTpm)}
            } else {
                $bios=Get-VMBios -VM $vm -ErrorAction Stop|Select-Object StartupOrder
                $security=[pscustomobject]@{TpmEnabled=$false;EncryptStateAndVmMigrationTraffic=$false;Shielded=$false;BindToHostTpm=$false}
            }
            $vlans=@(Get-VMNetworkAdapterVlan -VMName $vm.Name -ErrorAction Stop|Select-Object OperationMode,AccessVlanId,NativeVlanId,AllowedVlanIdList)
            $vms += [pscustomobject]@{Name=$vm.Name;Id=[string]$vm.Id;State=[string]$vm.State;Generation=$vm.Generation;Version=$vm.Version;MemoryStartup=$vm.MemoryStartup;ProcessorCount=$vm.ProcessorCount;Disks=$drives;NetworkAdapters=$nics;Firmware=$firmware;Bios=$bios;Security=$security;Vlans=$vlans;CheckpointType=[string]$vm.CheckpointType}
        }
    } catch { $errors.Add('VM_INVENTORY_UNAVAILABLE: ' + $_.Exception.Message); $complete=$false }
    [pscustomobject]@{SchemaVersion=1;Host=$env:COMPUTERNAME;CapturedUtc=[DateTime]::UtcNow.ToString('o');Disks=$disks;VirtualMachines=$vms;VmInventoryComplete=$complete;Errors=$errors.ToArray();PhysicalAcquisitionEnabled=$false}
}
function Test-RecoveryPlan {
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][int]$DestinationDiskNumber,[Parameter(Mandatory)][uint64]$FreeBytes)
    $reasons=[Collections.Generic.List[string]]::new(); $disk=$null
    if ((Get-RecoveryProperty $Inventory VmInventoryComplete) -ne $true) { $reasons.Add('VM_INVENTORY_UNAVAILABLE') }
    if(-not (Test-RecoveryHasProperty $Inventory VirtualMachines) -or $null -eq $Inventory.VirtualMachines) { $reasons.Add('VM_LIST_MISSING') }
    if (-not (Test-DiskIdentity $Source)) { $reasons.Add('SOURCE_IDENTITY_INCOMPLETE') }
    $matches=@((Get-RecoveryProperty $Inventory Disks) | Where-Object { Test-SameDisk $_ $Source })
    if ($matches.Count -ne 1) { $reasons.Add('SOURCE_MISSING_OR_AMBIGUOUS') } else {
        $disk=$matches[0]
        if($null -eq (Get-RecoveryProperty $disk Number)) { $reasons.Add('SOURCE_NUMBER_UNKNOWN') }
        foreach($p in @('IsBoot','IsSystem','IsOffline')) { if ((Get-RecoveryProperty $disk $p) -isnot [bool]) { $reasons.Add('SOURCE_STATE_UNKNOWN') } }
        if ((Get-RecoveryProperty $disk IsBoot) -or (Get-RecoveryProperty $disk IsSystem)) { $reasons.Add('SOURCE_IS_HOST_SYSTEM') }
        if ((Get-RecoveryProperty $disk IsOffline) -ne $true) { $reasons.Add('SOURCE_NOT_OFFLINE') }
        if ((Get-RecoveryProperty $disk Number) -eq $DestinationDiskNumber) { $reasons.Add('SOURCE_EQUALS_DESTINATION') }
        foreach($vm in @((Get-RecoveryProperty $Inventory VirtualMachines))) {
            if ($null -eq $vm) { continue }
            if (-not (Test-RecoveryHasProperty $vm Disks) -or $null -eq $vm.Disks) { $reasons.Add('VM_DISK_MAPPING_UNKNOWN'); continue }
            foreach($drive in @($vm.Disks)) {
                $num=Get-RecoveryProperty $drive DiskNumber
                if($null -eq $num -and [string]::IsNullOrWhiteSpace([string](Get-RecoveryProperty $drive Path))) { $reasons.Add('VM_DISK_MAPPING_UNKNOWN') }
                if ($null -ne $num -and $num -eq $disk.Number -and ([string](Get-RecoveryProperty $vm State)) -ne 'Off') { $reasons.Add('SOURCE_VM_NOT_OFF: ' + [string]$vm.Name) }
            }
        }
    }
    $dest=@((Get-RecoveryProperty $Inventory Disks) | Where-Object { (Get-RecoveryProperty $_ Number) -eq $DestinationDiskNumber })
    if ($dest.Count -ne 1) { $reasons.Add('DESTINATION_DISK_UNKNOWN') } else {
        if(-not (Test-DiskIdentity $dest[0])) { $reasons.Add('DESTINATION_IDENTITY_INCOMPLETE') }
        if((Get-RecoveryProperty $dest[0] IsOffline) -isnot [bool] -or (Get-RecoveryProperty $dest[0] IsReadOnly) -isnot [bool]) { $reasons.Add('DESTINATION_STATE_UNKNOWN') }
        if((Get-RecoveryProperty $dest[0] IsOffline) -ne $false -or (Get-RecoveryProperty $dest[0] IsReadOnly) -ne $false) { $reasons.Add('DESTINATION_NOT_WRITABLE') }
    }
    $required=[uint64]0
    if ((Get-RecoveryProperty $Source Size) -gt 0) {
        try { $required=[uint64]([decimal]$Source.Size + 1GB) } catch { $reasons.Add('SOURCE_SIZE_INVALID') }
        if ($FreeBytes -lt $required) { $reasons.Add('DESTINATION_CAPACITY_INSUFFICIENT') }
    }
    [pscustomobject]@{Allowed=($reasons.Count -eq 0);Reasons=$reasons.ToArray();SourceDisk=$disk;RequiredBytes=$required;PhysicalAcquisitionEnabled=$false;State='PreflightOnly';Notice='Offline is not proof of quiescence. Physical disk acquisition is disabled in this release.'}
}
function Resolve-RegularImagePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^(\\\\|//)' -or $Path -match '^\\\?\?' -or $Path -match '[\x00-\x1f]') { throw 'UNSUPPORTED_IMAGE_PATH: only local ordinary files are supported' }
    foreach($component in ($Path -split '[\\/]')) {
        if($component -match '[ .]$' -or $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'UNSUPPORTED_IMAGE_PATH' }
    }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'UNSUPPORTED_IMAGE_PATH' }
    foreach($component in $full.Substring(3).Split('\')) {
        if($component -match '[<>"|?*]' -or $component -match '[ .]$' -or $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'UNSUPPORTED_IMAGE_PATH' }
    }
    $parent=[IO.Path]::GetDirectoryName($full)
    if (-not [IO.Directory]::Exists($parent)) { throw 'IMAGE_PARENT_MISSING' }
    $walk=$parent
    while ($walk) {
        $item=Get-Item -LiteralPath $walk -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'REPARSE_POINT_NOT_ALLOWED' }
        $walk=[IO.Path]::GetDirectoryName($walk.TrimEnd('\'))
    }
    if (Test-Path -LiteralPath $full) {
        $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NOT_REGULAR_IMAGE_FILE' }
    }
    return $full
}
function Write-RecoveryEvent([string]$Path,[string]$State,[string]$Detail) {
    $entry=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');State=$State;Detail=$Detail}
    [IO.File]::AppendAllText($Path, (($entry|ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
function Get-StreamDigest([IO.Stream]$Stream,[uint64]$ExpectedSize) {
    $hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] (4MB);$count=[uint64]0
    try {
        while(($n=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $count += [uint64]$n
            if ($count -gt $ExpectedSize) { throw 'IMAGE_LENGTH_MISMATCH' }
            $null=$hash.TransformBlock($buffer,0,$n,$null,0)
        }
        if($count -ne $ExpectedSize) { throw 'IMAGE_LENGTH_MISMATCH' }
        $null=$hash.TransformFinalBlock((New-Object byte[] 0),0,0)
        return ([BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant())
    } finally { $hash.Dispose() }
}
function Write-ImageFromStream {
    [CmdletBinding()]param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][uint64]$Size,
        [Parameter(Mandatory)][string]$ImagePath,[Parameter(Mandatory)]$ManifestMetadata,[string]$ExpectedSha256)
    if ($Size -eq 0 -or -not $Stream.CanRead) { throw 'INVALID_SOURCE_STREAM' }
    $full=Resolve-RegularImagePath $ImagePath
    foreach($suffix in @('','.partial','.manifest.json','.manifest.json.partial','.events.jsonl')) {
        if(Test-Path -LiteralPath ($full+$suffix)) { throw 'OUTPUT_ALREADY_EXISTS' }
    }
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if($drive.AvailableFreeSpace -lt ([decimal]$Size + 1MB)) { throw 'DESTINATION_CAPACITY_INSUFFICIENT' }
    if($ExpectedSha256 -and $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'EXPECTED_HASH_INVALID' }
    $partial=$full+'.partial';$log=$full+'.events.jsonl';$output=$null;$hash=$null;$count=[uint64]0
    $manifestPath=$full+'.manifest.json'
    try {
        $output=[IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        Write-RecoveryEvent $log 'partial' 'Copy started. Not a verified backup.'
        $hash=[Security.Cryptography.SHA256]::Create();$buffer=New-Object byte[] (4MB)
        while($count -lt $Size) {
            $want=[int][Math]::Min([uint64]$buffer.Length,($Size-$count))
            $n=$Stream.Read($buffer,0,$want)
            if($n -le 0) { throw 'SOURCE_SHORT_READ' }
            $output.Write($buffer,0,$n)
            $null=$hash.TransformBlock($buffer,0,$n,$null,0)
            $count += [uint64]$n
        }
        if($Stream.ReadByte() -ne -1) { throw 'SOURCE_LONGER_THAN_DECLARED' }
        $output.Flush($true);$output.Dispose();$output=$null
        $null=$hash.TransformFinalBlock((New-Object byte[] 0),0,0)
        $digest=[BitConverter]::ToString($hash.Hash).Replace('-','').ToLowerInvariant()
        Write-RecoveryEvent $log 'copied' ('Bytes='+$count+'; read-back pending')
        $reader=[IO.File]::Open($partial,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $readback=Get-StreamDigest $reader $Size } finally { $reader.Dispose() }
        if($readback -cne $digest) { throw 'READBACK_HASH_MISMATCH' }
        if($ExpectedSha256 -and $digest -cne $ExpectedSha256) { throw 'SOURCE_CHANGED_SINCE_VERIFICATION' }
        $manifest=[ordered]@{SchemaVersion=1;State='verified';Size=$Size;Sha256=$digest;CreatedUtc=[DateTime]::UtcNow.ToString('o');RestoreTested=$false;Metadata=$ManifestMetadata;IntegrityOnly=$true}
        $manifestStream=[IO.File]::Open($manifestPath+'.partial',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 12));$manifestStream.Write($bytes,0,$bytes.Length);$manifestStream.Flush($true) } finally { $manifestStream.Dispose() }
        [IO.File]::Move($partial,$full)
        [IO.File]::Move($manifestPath+'.partial',$manifestPath)
        Write-RecoveryEvent $log 'verified' 'Stored bytes passed read-back SHA-256. Restore NOT tested; source authenticity NOT established.'
        [pscustomobject]@{Verified=$true;ImagePath=$full;ManifestPath=$manifestPath;Size=$Size;Sha256=$digest;RestoreTested=$false}
    } catch {
        try { Write-RecoveryEvent $log 'failed' ('BytesCompleted='+$count+'; ExpectedBytes='+$Size+'; ImagePath='+$full+'; HResult='+$_.Exception.HResult+'; '+$_.Exception.GetType().FullName+': '+$_.Exception.Message) } catch { }
        throw
    } finally { if($null -ne $output){$output.Dispose()};if($null -ne $hash){$hash.Dispose()} }
}
function Test-RecoveryImage {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ImagePath)
    $full=Resolve-RegularImagePath $ImagePath
    $manifestPath=Resolve-RegularImagePath ($full+'.manifest.json')
    if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'MANIFEST_MISSING' }
    $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if((Get-RecoveryProperty $m SchemaVersion) -ne 1 -or (Get-RecoveryProperty $m State) -cne 'verified' -or
       (Get-RecoveryProperty $m Size) -le 0 -or ([string](Get-RecoveryProperty $m Sha256)) -cnotmatch '^[0-9a-f]{64}$') { throw 'MANIFEST_INVALID' }
    $reader=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $digest=Get-StreamDigest $reader ([uint64]$m.Size) } finally { $reader.Dispose() }
    if($digest -cne $m.Sha256) { throw 'IMAGE_HASH_MISMATCH' }
    [pscustomobject]@{Verified=$true;Size=[uint64]$m.Size;Sha256=$digest;Metadata=(Get-RecoveryProperty $m Metadata);RestoreTested=$false;IntegrityOnly=$true}
}
function New-RestorePlan {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ImagePath,[Parameter(Mandatory)]$TargetDisk,[Parameter(Mandatory)]$SourceFingerprint,[Nullable[int]]$ImageDiskNumber,$Inventory)
    $image=Test-RecoveryImage $ImagePath;$reasons=[Collections.Generic.List[string]]::new()
    if($null -eq $ImageDiskNumber) { $reasons.Add('IMAGE_STORAGE_DISK_UNKNOWN') }
    elseif($ImageDiskNumber -eq (Get-RecoveryProperty $TargetDisk Number)) { $reasons.Add('IMAGE_STORAGE_DISK_PROTECTED') }
    if($null -eq $Inventory -or (Get-RecoveryProperty $Inventory VmInventoryComplete) -ne $true -or -not (Test-RecoveryHasProperty $Inventory VirtualMachines) -or $null -eq $Inventory.VirtualMachines) { $reasons.Add('VM_INVENTORY_UNAVAILABLE') }
    else {
        foreach($vm in @($Inventory.VirtualMachines)) {
            if(-not (Test-RecoveryHasProperty $vm Disks) -or $null -eq $vm.Disks) { $reasons.Add('VM_DISK_MAPPING_UNKNOWN');continue }
            foreach($d in @($vm.Disks)) {
                $num=Get-RecoveryProperty $d DiskNumber
                if($null -eq $num -and [string]::IsNullOrWhiteSpace([string](Get-RecoveryProperty $d Path))) { $reasons.Add('VM_DISK_MAPPING_UNKNOWN') }
                if($null -ne $num -and $num -eq (Get-RecoveryProperty $TargetDisk Number)) { $reasons.Add('TARGET_ATTACHED_TO_VM') }
            }
        }
    }
    $targets=@((Get-RecoveryProperty $Inventory Disks) | Where-Object { (Get-RecoveryProperty $_ Number) -eq (Get-RecoveryProperty $TargetDisk Number) -and (Test-SameDisk $_ $TargetDisk) })
    if($targets.Count -ne 1) { $reasons.Add('TARGET_INVENTORY_MISMATCH') } else {
        foreach($p in @('IsOffline','IsReadOnly','IsBoot','IsSystem')) {
            if((Get-RecoveryProperty $targets[0] $p) -isnot [bool] -or (Get-RecoveryProperty $targets[0] $p) -ne (Get-RecoveryProperty $TargetDisk $p)) { $reasons.Add('TARGET_STATE_CHANGED') }
        }
    }
    $stores=@((Get-RecoveryProperty $Inventory Disks) | Where-Object { $null -ne $ImageDiskNumber -and (Get-RecoveryProperty $_ Number) -eq $ImageDiskNumber })
    if($stores.Count -ne 1) { $reasons.Add('IMAGE_STORAGE_DISK_UNKNOWN') } elseif(-not (Test-DiskIdentity $stores[0])) { $reasons.Add('IMAGE_STORAGE_DISK_UNKNOWN') }
    $recordedSource=Get-RecoveryProperty $image.Metadata Source
    if(-not (Test-DiskIdentity $recordedSource) -or -not (Test-SameDisk $recordedSource $SourceFingerprint)) { $reasons.Add('MANIFEST_SOURCE_MISMATCH') }
    if(-not (Test-DiskIdentity $TargetDisk) -or -not (Test-DiskIdentity $SourceFingerprint)) { $reasons.Add('IDENTITY_INCOMPLETE') }
    if(Test-SameDisk $TargetDisk $SourceFingerprint) { $reasons.Add('ORIGINAL_SOURCE_PROTECTED') }
    if((Get-RecoveryProperty $TargetDisk UniqueId) -eq (Get-RecoveryProperty $SourceFingerprint UniqueId) -or
       (Get-RecoveryProperty $TargetDisk SerialNumber) -eq (Get-RecoveryProperty $SourceFingerprint SerialNumber)) { $reasons.Add('SOURCE_IDENTITY_COLLISION') }
    foreach($p in @('IsBoot','IsSystem','IsOffline','IsReadOnly')) { if((Get-RecoveryProperty $TargetDisk $p) -isnot [bool]) { $reasons.Add('TARGET_STATE_UNKNOWN') } }
    if((Get-RecoveryProperty $TargetDisk IsBoot) -or (Get-RecoveryProperty $TargetDisk IsSystem)) { $reasons.Add('HOST_SYSTEM_PROTECTED') }
    if((Get-RecoveryProperty $TargetDisk IsOffline) -ne $true) { $reasons.Add('TARGET_NOT_OFFLINE') }
    if((Get-RecoveryProperty $TargetDisk IsReadOnly) -ne $false) { $reasons.Add('TARGET_READONLY_OR_UNKNOWN') }
    if((Get-RecoveryProperty $TargetDisk Size) -lt $image.Size) { $reasons.Add('TARGET_TOO_SMALL') }
    if((Get-RecoveryProperty $SourceFingerprint Size) -ne $image.Size) { $reasons.Add('SOURCE_IMAGE_SIZE_MISMATCH') }
    if((Get-RecoveryProperty $TargetDisk LogicalSectorSize) -ne (Get-RecoveryProperty $SourceFingerprint LogicalSectorSize)) { $reasons.Add('SECTOR_SIZE_MISMATCH') }
    [pscustomobject]@{Allowed=($reasons.Count -eq 0);Reasons=$reasons.ToArray();State='PlanOnly';PhysicalWriteEnabled=$false;RestoreTested=$false;TargetDisk=$TargetDisk;Image=$image;Warnings=@('Target VM attachment and destination hosting disk must be checked again before any future writer is implemented.','Manifest hash is not a signature. Keep a separately trusted copy.','Edge Box licensing, TPM/encryption keys, guest consistency and other-PC bootability are not verified.')}
}
function Test-RecoveryMediaHash {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$IsoPath,[Parameter(Mandatory)][string]$ExpectedSha256)
    if($ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'EXPECTED_HASH_INVALID' }
    $full=Resolve-RegularImagePath $IsoPath
    if([IO.Path]::GetExtension($full) -ine '.iso') { throw 'ISO_FILE_REQUIRED' }
    $reader=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { if($reader.Length -le 0) { throw 'EMPTY_ISO' };$digest=Get-StreamDigest $reader ([uint64]$reader.Length) } finally { $reader.Dispose() }
    if($digest -cne $ExpectedSha256.ToLowerInvariant()) { throw 'ISO_HASH_MISMATCH' }
    [pscustomobject]@{HashMatches=$true;Sha256=$digest;AuthenticityVerified=$false;BootTested=$false;Notice='Authenticate the official checksum signature separately. No software was installed or booted.'}
}
Export-ModuleMember -Function Get-RecoveryInventory,Test-RecoveryPlan,Write-ImageFromStream,Test-RecoveryImage,New-RestorePlan,Test-RecoveryMediaHash
