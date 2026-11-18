#requires -Version 5.1
Set-StrictMode -Version Latest
$script:StorageModule=Import-Module (Join-Path $PSScriptRoot 'StorageRecovery.psm1') -PassThru -Force
function Get-RVProperty($Object,[string]$Name) {
    if($null -eq $Object){return $null}; if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $null
}
function Test-RecoveryVmProfile {
    [CmdletBinding()]param([Parameter(Mandatory)]$Profile)
    if((Get-RVProperty $Profile ProfileVersion) -eq 2){return (Test-RecoveryV2Profile $Profile)}
    $r=[Collections.Generic.List[string]]::new()
    if((Get-RVProperty $Profile ProfileVersion) -ne 1){$r.Add('PROFILE_VERSION_REQUIRED')}
    if((Get-RVProperty $Profile SourceDiskCount) -ne 1){$r.Add('SINGLE_SOURCE_DISK_REQUIRED')}
    if((Get-RVProperty $Profile NetworkAdapterCount) -ne 1){$r.Add('SINGLE_NETWORK_ADAPTER_REQUIRED')}
    if((Get-RVProperty $Profile Generation) -notin @(1,2)){$r.Add('GENERATION_REQUIRED')}
    if((Get-RVProperty $Profile MemoryStartupBytes) -lt 512MB -or (Get-RVProperty $Profile MemoryStartupBytes) -gt 1TB){$r.Add('MEMORY_OUT_OF_RANGE')}
    if((Get-RVProperty $Profile ProcessorCount) -lt 1 -or (Get-RVProperty $Profile ProcessorCount) -gt 256){$r.Add('CPU_OUT_OF_RANGE')}
    if(([string](Get-RVProperty $Profile SourceImageSha256)) -cnotmatch '^[0-9a-f]{64}$'){$r.Add('SOURCE_IMAGE_HASH_REQUIRED')}
    if([string]::IsNullOrWhiteSpace([string](Get-RVProperty $Profile SourceSerialNumber))){$r.Add('SOURCE_SERIAL_REQUIRED')}
    $sourceSize=Get-RVProperty $Profile SourceSize
    $sourceBytes=[uint64]0
    if($sourceSize -is [bool] -or ([string]$sourceSize) -cnotmatch '^[0-9]+$' -or -not [uint64]::TryParse([string]$sourceSize,[ref]$sourceBytes) -or $sourceBytes -eq 0 -or $sourceBytes % 512 -ne 0){$r.Add('SOURCE_SIZE_INVALID')}
    if((Get-RVProperty $Profile SourceLogicalSectorSize) -ne 512){$r.Add('SOURCE_512_LOGICAL_SECTOR_REQUIRED')}
    if((Get-RVProperty $Profile IdentityPolicy) -cne 'NewVmId'){$r.Add('NEW_VM_ID_CONSENT_REQUIRED')}
    if((Get-RVProperty $Profile TpmRequired) -isnot [bool] -or (Get-RVProperty $Profile TpmRequired) -ne $false){$r.Add('TPM_DEPENDENCY_UNSUPPORTED_OR_UNKNOWN')}
    if((Get-RVProperty $Profile EncryptionDependenciesResolved) -isnot [bool] -or (Get-RVProperty $Profile EncryptionDependenciesResolved) -ne $true){$r.Add('ENCRYPTION_DEPENDENCY_UNRESOLVED')}
    if((Get-RVProperty $Profile Generation) -eq 2){
        if((Get-RVProperty $Profile SecureBoot) -cnotin @('On','Off')){$r.Add('SECURE_BOOT_REQUIRED')}
        if((Get-RVProperty $Profile SecureBoot) -ceq 'On' -and [string]::IsNullOrWhiteSpace([string](Get-RVProperty $Profile SecureBootTemplate))){$r.Add('SECURE_BOOT_TEMPLATE_REQUIRED')}
    }
    foreach($field in @('MemoryStartupBytes','ProcessorCount','Generation')){if(([string](Get-RVProperty $Profile $field)) -notmatch '^[0-9]+$'){$r.Add('INTEGER_PROFILE_FIELD_REQUIRED: '+$field)}}
    $policy=Get-RVProperty $Profile MacPolicy
    if($policy -cnotin @('New','Preserve')){$r.Add('MAC_POLICY_REQUIRED')}
    if($policy -ceq 'Preserve'){
        $mac=[string](Get-RVProperty $Profile MacAddress)
        if($mac -notmatch '^[0-9a-fA-F]{12}$' -or $mac -eq '000000000000' -or ($mac.Length -eq 12 -and ([Convert]::ToByte($mac.Substring(0,2),16) -band 1) -ne 0)){$r.Add('UNICAST_MAC_REQUIRED')}
    }
    [pscustomobject]@{Allowed=($r.Count -eq 0);Reasons=$r.ToArray()}
}
function Get-RecoveryHostState {
    $who=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'HYPERV_ADMIN_REQUIRED'}
    $hostInfo=Get-VMHost -ErrorAction Stop
    $vms=@(Get-VM -ErrorAction Stop | Select-Object Name,Id)
    $macs=@(Get-VM -ErrorAction Stop | Get-VMNetworkAdapter -ErrorAction Stop | Select-Object -ExpandProperty MacAddress)
    $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpu=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    [pscustomobject]@{VMs=$vms;MacAddresses=$macs;ProcessorCount=$cpu.NumberOfLogicalProcessors;AvailableMemoryBytes=([uint64]$os.FreePhysicalMemory*1KB)}
}
function Get-RecoveryVhdInfo([string]$Path){Get-VHD -Path $Path -ErrorAction Stop}
function New-RecoveryVM([string]$Name,[int]$Generation,[long]$Memory,[string]$Path){
    # No SwitchName is supplied. No existing VM object is accepted by this entry point.
    New-VM -Name $Name -Generation $Generation -MemoryStartupBytes $Memory -NoVHD -Path $Path -ErrorAction Stop
}
function Set-RecoveryVmHardware($VM,$Profile,[string]$VhdxPath){
    Set-VMProcessor -VM $VM -Count $Profile.ProcessorCount -ErrorAction Stop
    if((Get-RVProperty $Profile ProfileVersion) -eq 2){Set-VMProcessor -VM $VM -CompatibilityForMigrationEnabled $false -ErrorAction Stop}
    Set-VMMemory -VM $VM -DynamicMemoryEnabled $false -ErrorAction Stop
    Set-VM -VM $VM -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled -ErrorAction Stop
    if($Profile.Generation -eq 2){
        Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $VhdxPath -ErrorAction Stop
        $disk=@(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop | Where-Object Path -eq $VhdxPath)
        if($disk.Count -ne 1){throw 'NEW_VM_DISK_MAPPING_MISMATCH'}
        $fw=@{VM=$VM;EnableSecureBoot=$Profile.SecureBoot;FirstBootDevice=$disk[0];ErrorAction='Stop'}
        if($Profile.SecureBoot -ceq 'On'){$fw.SecureBootTemplate=$Profile.SecureBootTemplate}
        Set-VMFirmware @fw
    }else{
        Add-VMHardDiskDrive -VM $VM -ControllerType IDE -ControllerNumber 0 -ControllerLocation 0 -Path $VhdxPath -ErrorAction Stop
        Set-VMBios -VM $VM -StartupOrder @('IDE','CD','LegacyNetworkAdapter','Floppy') -ErrorAction Stop
    }
    $nics=@(Get-VMNetworkAdapter -VM $VM -ErrorAction Stop)
    if($nics.Count -ne 1 -or -not [string]::IsNullOrEmpty([string]$nics[0].SwitchName)){throw 'NEW_VM_NETWORK_NOT_ISOLATED'}
    if($Profile.MacPolicy -ceq 'Preserve'){Set-VMNetworkAdapter -VMNetworkAdapter $nics[0] -StaticMacAddress $Profile.MacAddress -ErrorAction Stop}
}
function Get-RecoveryVmIsolation($VM){
    $current=Get-VM -Id $VM.Id -ErrorAction Stop
    $nics=@(Get-VMNetworkAdapter -VM $current -ErrorAction Stop)
    $disks=@(Get-VMHardDiskDrive -VM $current -ErrorAction Stop)
    [pscustomobject]@{Id=[string]$current.Id;Name=$current.Name;State=[string]$current.State;Generation=$current.Generation;Isolated=(@($nics|Where-Object{-not [string]::IsNullOrEmpty([string]$_.SwitchName)}).Count -eq 0);MacAddresses=@($nics|Select-Object -ExpandProperty MacAddress);DiskPaths=@($disks|Select-Object -ExpandProperty Path);PhysicalDiskCount=@($disks|Where-Object{$null -ne $_.DiskNumber}).Count}
}
function Start-RecoveryVM($VM){Start-VM -VM $VM -ErrorAction Stop}
function Write-RVEvent([string]$Path,[string]$Stage,[string]$Detail){
    $row=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Stage=$Stage;Detail=$Detail}
    [IO.File]::AppendAllText($Path,($row|ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}
function Write-RecoveryFailure([string]$Root,[string]$Stage,$VM,[string[]]$WorkingPaths,[uint64]$Offset,$Failure){
    # A failed create/configure/start may leave useful artifacts. Record them, but
    # never delete, stop, or otherwise alter a VM while handling another error.
    $observed=$null;$observationError=$null
    if($null -ne $VM){
        try{$observed=Get-RecoveryVmIsolation $VM}catch{$observationError=$_.Exception.GetType().FullName}
    }
    $record=[ordered]@{State='Failed';Stage=$Stage;Utc=[DateTime]::UtcNow.ToString('o');VMId=[string](Get-RVProperty $VM Id);VMName=[string](Get-RVProperty $VM Name);ObservedVM=$observed;ObservationErrorType=$observationError;WorkingCopies=$WorkingPaths;BytesCopiedInCurrentDisk=$Offset;ExceptionType=$Failure.Exception.GetType().FullName;HResult=$Failure.Exception.HResult;ArtifactsRetained=$true;AutomaticCleanupPerformed=$false;BootTested=$false;RestoreTested=$false;LicenseValidated=$false}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 8))
    $stream=[IO.File]::Open((Join-Path $Root 'recovery-failure.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-RVHash([IO.Stream]$Stream){
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $value=$sha.ComputeHash($Stream);[BitConverter]::ToString($value).Replace('-','').ToLowerInvariant() }finally{$sha.Dispose()}
}
function Assert-RecoveryVhdInfo($Info,$Manifest){
    if((Get-RVProperty $Info VhdFormat) -ne 'VHDX' -or (Get-RVProperty $Info VhdType) -notin @('Dynamic','Fixed') -or -not [string]::IsNullOrEmpty([string](Get-RVProperty $Info ParentPath))){throw 'VHDX_TYPE_UNSUPPORTED'}
    if((Get-RVProperty $Info Attached) -isnot [bool] -or $Info.Attached -ne $false){throw 'VHDX_ALREADY_ATTACHED_OR_UNKNOWN'}
    if((Get-RVProperty $Info Size) -ne $Manifest.VirtualSize -or (Get-RVProperty $Info LogicalSectorSize) -ne 512){throw 'VHDX_GEOMETRY_MISMATCH'}
}
function Invoke-IsolatedVmRecovery {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$VhdxPath,[Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$VMName,[Parameter(Mandatory)][string]$VMRoot,[switch]$Create,[switch]$StartIsolated,[string[]]$DataVhdxPaths=@())
    if((Get-RVProperty $Profile ProfileVersion) -eq 2){
        $v2=@{VhdxPaths=@($VhdxPath)+@($DataVhdxPaths);Profile=$Profile;VMName=$VMName;VMRoot=$VMRoot;Create=$Create;StartIsolated=$StartIsolated}
        if($WhatIfPreference){$v2.WhatIf=$true};if($PSBoundParameters.ContainsKey('Confirm')){$v2.Confirm=$PSBoundParameters['Confirm']}
        return (Invoke-RecoveryV2 @v2)
    }
    if($DataVhdxPaths.Count -gt 0){throw 'MULTI_DISK_REQUIRES_PROFILE_V2'}
    $check=Test-RecoveryVmProfile $Profile
    if(-not $check.Allowed){throw ('INVALID_PROFILE: '+($check.Reasons -join ', '))}
    if($VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}[A-Za-z0-9_-]$'){throw 'INVALID_NEW_VM_NAME'}
    if($StartIsolated -and -not $Create){throw 'START_REQUIRES_CREATE'}
    $source=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} $VhdxPath
    if([IO.Path]::GetExtension($source) -ine '.vhdx'){throw 'VHDX_FILE_REQUIRED'}
    $root=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} $VMRoot
    if(Test-Path -LiteralPath $root){throw 'VM_ROOT_ALREADY_EXISTS'}
    $manifestPath=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} ($source+'.manifest.json')
    $m=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if((Get-RVProperty $m SchemaVersion) -ne 1 -or (Get-RVProperty $m State) -cne 'verified' -or (Get-RVProperty $m Format) -cne 'vhdx' -or (Get-RVProperty $m FullSectorImage) -ne $true -or (Get-RVProperty $m SourceAcquisitionMode) -cne 'offline-block') {throw 'VERIFIED_FULL_SECTOR_VHDX_REQUIRED'}
    if((Get-RVProperty $m Size) -le 0 -or (Get-RVProperty $m VirtualSize) -le 0 -or (Get-RVProperty $m LogicalSectorSize) -ne 512 -or ([string](Get-RVProperty $m Sha256)) -cnotmatch '^[0-9a-f]{64}$'){throw 'VHDX_MANIFEST_INVALID'}
    foreach($field in @('VirtualSize','QemuCheck','LogicalCompare','ReadbackSha256','LogicalSectorSize')){if((Get-RVProperty (Get-RVProperty $m Verification) $field) -isnot [bool] -or (Get-RVProperty $m.Verification $field) -ne $true){throw ('VHDX_VERIFICATION_MISSING: '+$field)}}
    if(([string](Get-RVProperty $m SourceSha256)) -cnotmatch '^[0-9a-f]{64}$' -or $Profile.SourceImageSha256 -cne $m.SourceSha256){throw 'PROFILE_IMAGE_BINDING_MISMATCH'}
    if((Get-RVProperty $m FullSectorImage) -isnot [bool]){throw 'MANIFEST_BOOLEAN_REQUIRED'}
    if((Get-RVProperty (Get-RVProperty $m Metadata) SourceWriteProtected) -isnot [bool] -or (Get-RVProperty $m.Metadata SourceWriteProtected) -ne $true){throw 'SOURCE_WRITE_PROTECTION_UNVERIFIED'}
    $origin=Get-RVProperty (Get-RVProperty $m Metadata) Source
    foreach($binding in @(@('SerialNumber','SourceSerialNumber'),@('Size','SourceSize'),@('LogicalSectorSize','SourceLogicalSectorSize'))){
        if(([string](Get-RVProperty $origin $binding[0])).Trim() -cne ([string](Get-RVProperty $Profile $binding[1])).Trim()){throw 'PROFILE_SOURCE_IDENTITY_MISMATCH'}
    }
    if($m.VirtualSize -ne $Profile.SourceSize){throw 'PROFILE_SOURCE_SIZE_MISMATCH'}
    $hostState=Get-RecoveryHostState
    if($null -eq $hostState.PSObject.Properties['VMs'] -or $null -eq $hostState.VMs){throw 'HOST_VM_INVENTORY_UNKNOWN'}
    if(@($hostState.VMs|Where-Object Name -eq $VMName).Count -gt 0){throw 'VM_NAME_ALREADY_EXISTS'}
    if($Profile.ProcessorCount -gt $hostState.ProcessorCount -or $Profile.MemoryStartupBytes -gt $hostState.AvailableMemoryBytes){throw 'HOST_RESOURCES_INSUFFICIENT'}
    if($Profile.MacPolicy -ceq 'Preserve' -and $Profile.MacAddress -in $hostState.MacAddresses){throw 'MAC_ALREADY_PRESENT_ON_HOST'}
    Assert-RecoveryVhdInfo (Get-RecoveryVhdInfo $source) $m
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    $requiredSpace=[Math]::Max([decimal]$m.Size,[decimal]$m.VirtualSize)+2GB
    if($drive.AvailableFreeSpace -lt $requiredSpace){throw 'WORKING_COPY_SPACE_INSUFFICIENT'}
    $sourceStream=$null;$output=$null;$created=$null;$log=$null;$offset=[uint64]0;$working=Join-Path $root 'os.vhdx';$stage='Validating'
    try {
        # Read sharing excludes writers and delete for the entire hash+copy stage.
        $sourceStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($sourceStream.Length -ne $m.Size -or (Get-RVHash $sourceStream) -cne $m.Sha256){throw 'VHDX_ARCHIVE_HASH_MISMATCH'}
        $sourceStream.Position=0
        $plan=[pscustomobject]@{State='PlanOnly';VMName=$VMName;VMRoot=$root;Source=$source;WorkingCopy=$working;IdentityPolicy='NewVmId';Network='Disconnected';Generation=$Profile.Generation;PhysicalWrites=$false;BootTested=$false;RestoreTested=$false;LicenseValidated=$false;Warnings=@('A new VM ID is allocated; original VM ID preservation is unsupported.','MAC preservation does not guarantee FSBP activation.','The archive remains untouched; only a fresh working copy is attached.')}
        if(-not $Create){return $plan}
        if(-not $PSCmdlet.ShouldProcess($root,"Create NEW isolated VM '$VMName' and working VHDX copy; optional start=$StartIsolated")){return $plan}
        New-Item -ItemType Directory -Path $root -ErrorAction Stop|Out-Null
        $log=Join-Path $root 'recovery.events.jsonl'
        $stage='Copying'
        Write-RVEvent $log 'copying' ('Archive='+$source+'; expected bytes='+$m.Size)
        $output=[IO.File]::Open(($working+'.partial'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $buffer=New-Object byte[] (4MB)
        while(($n=$sourceStream.Read($buffer,0,$buffer.Length)) -gt 0){$output.Write($buffer,0,$n);$offset+=[uint64]$n}
        if($offset -ne $m.Size){throw 'WORKING_COPY_LENGTH_MISMATCH'}
        $output.Flush($true);$output.Dispose();$output=$null
        $reader=[IO.File]::Open(($working+'.partial'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {if((Get-RVHash $reader) -cne $m.Sha256){throw 'WORKING_COPY_HASH_MISMATCH'}}finally{$reader.Dispose()}
        [IO.File]::Move(($working+'.partial'),$working)
        $sourceStream.Dispose();$sourceStream=$null
        Assert-RecoveryVhdInfo (Get-RecoveryVhdInfo $working) $m
        Write-RVEvent $log 'working-copy-verified' 'Original archive not attached to VM.'
        # Recheck inventory immediately before creation; never change an existing VM.
        $latest=Get-RecoveryHostState
        if($null -eq $latest.PSObject.Properties['VMs'] -or $null -eq $latest.VMs){throw 'HOST_VM_INVENTORY_UNKNOWN'}
        if(@($latest.VMs|Where-Object Name -eq $VMName).Count -gt 0){throw 'VM_NAME_CREATED_CONCURRENTLY'}
        if($Profile.MacPolicy -ceq 'Preserve' -and $Profile.MacAddress -in $latest.MacAddresses){throw 'MAC_ALREADY_PRESENT_ON_HOST'}
        if($Profile.MemoryStartupBytes -gt $latest.AvailableMemoryBytes -or $Profile.ProcessorCount -gt $latest.ProcessorCount){throw 'HOST_RESOURCES_CHANGED'}
        $stage='CreatingVM'
        $created=New-RecoveryVM -Name $VMName -Generation $Profile.Generation -Memory $Profile.MemoryStartupBytes -Path $root
        if($null -eq $created -or [string]::IsNullOrEmpty([string]$created.Id) -or $created.Name -ne $VMName){throw 'NEW_VM_RESULT_INVALID'}
        if([string]$created.Id -in @($latest.VMs|ForEach-Object{[string]$_.Id})){throw 'NEW_VM_ID_COLLISION'}
        Write-RVEvent $log 'vm-created' ('VMId='+$created.Id)
        $initial=Get-RecoveryVmIsolation $created
        if($initial.State -ne 'Off' -or -not $initial.Isolated -or [string]$initial.Id -ne [string]$created.Id){throw 'NEW_VM_NOT_OFF_AND_ISOLATED'}
        $stage='ConfiguringVM'
        Set-RecoveryVmHardware -VM $created -Profile $Profile -VhdxPath $working
        $state=Get-RecoveryVmIsolation $created
        if([string]$state.Id -ne [string]$created.Id -or $state.Generation -ne $Profile.Generation -or -not $state.Isolated -or $state.State -ne 'Off' -or $state.PhysicalDiskCount -ne 0 -or @($state.DiskPaths).Count -ne 1 -or $state.DiskPaths[0] -ne $working){throw 'CONFIGURED_VM_ISOLATION_OR_DISK_MISMATCH'}
        if($Profile.MacPolicy -ceq 'Preserve' -and $Profile.MacAddress -notin $state.MacAddresses){throw 'MAC_CONFIGURATION_MISMATCH'}
        if($StartIsolated){$stage='StartingVM';Start-RecoveryVM $created;$state=Get-RecoveryVmIsolation $created;if(-not $state.Isolated){throw 'VM_ISOLATION_LOST'}}
        $result=[pscustomobject]@{State=$(if($StartIsolated){'StartRequestedUnverified'}else{'VMCreatedOff'});VMId=[string]$created.Id;VMName=$VMName;ObservedVMState=$state.State;VMRoot=$root;WorkingCopy=$working;Network='Disconnected';SourceSha256=$m.Sha256;NewVmId=$true;BootTested=$false;RestoreTested=$false;LicenseValidated=$false}
        $result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root 'recovery-result.json') -Encoding UTF8 -ErrorAction Stop
        Write-RVEvent $log 'completed-unverified-guest' 'VM lifecycle only; OS boot, FSBP and licensing remain unverified.'
        return $result
    }catch{
        if($log){try{Write-RecoveryFailure $root $stage $created @($working) $offset $_}catch{}}
        if($log){try{Write-RVEvent $log 'failed' ('Offset='+$offset+'; HResult='+$_.Exception.HResult+'; '+$_.Exception.Message+'; created VM retained, no automatic cleanup')}catch{}}
        throw
    }finally{if($null -ne $sourceStream){$sourceStream.Dispose()};if($null -ne $output){$output.Dispose()}}
}
function New-RecoveryVmProfile {
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][string]$SourceVMName,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SourceImageSha256,
        [switch]$AcceptNewVmId,[ValidateSet('Unconfirmed','New','Preserve')][string]$MacPolicy='Unconfirmed',
        [switch]$EncryptionDependenciesResolved,$SourceFingerprint)
    if((Get-RVProperty $Inventory VmInventoryComplete) -ne $true){throw 'SOURCE_INVENTORY_INCOMPLETE'}
    $vms=@((Get-RVProperty $Inventory VirtualMachines)|Where-Object Name -eq $SourceVMName)
    if($vms.Count -ne 1){throw 'SOURCE_VM_NOT_UNIQUE'}
    $vm=$vms[0];$nics=@((Get-RVProperty $vm NetworkAdapters));$sourceDisks=@((Get-RVProperty $vm Disks))
    if($nics.Count -ne 1 -or $sourceDisks.Count -ne 1 -or $null -eq (Get-RVProperty $sourceDisks[0] DiskNumber)){throw 'SINGLE_PASSTHROUGH_DISK_AND_NIC_REQUIRED'}
    $identity=@((Get-RVProperty $Inventory Disks)|Where-Object Number -eq $sourceDisks[0].DiskNumber)
    if($identity.Count -ne 1 -or $null -eq $SourceFingerprint){throw 'SOURCE_DISK_IDENTITY_UNKNOWN'}
    foreach($field in @('SerialNumber','Size','LogicalSectorSize')){
        $left=Get-RVProperty $identity[0] $field;$right=Get-RVProperty $SourceFingerprint $field
        if($null -eq $left -or $null -eq $right -or [string]::IsNullOrWhiteSpace([string]$left) -or ([string]$left).Trim() -cne ([string]$right).Trim()){throw ('SOURCE_DISK_IDENTITY_MISMATCH: '+$field)}
    }
    $sameIdentity=@((Get-RVProperty $Inventory Disks)|Where-Object {
        ([string](Get-RVProperty $_ SerialNumber)).Trim() -ceq ([string]$SourceFingerprint.SerialNumber).Trim() -and
        (Get-RVProperty $_ Size) -eq $SourceFingerprint.Size -and (Get-RVProperty $_ LogicalSectorSize) -eq $SourceFingerprint.LogicalSectorSize
    })
    if($sameIdentity.Count -ne 1){throw 'SOURCE_DISK_IDENTITY_AMBIGUOUS'}
    $security=Get-RVProperty $vm Security
    $tpmRequired=$false
    foreach($field in @('TpmEnabled','Shielded','BindToHostTpm')){
        $value=Get-RVProperty $security $field
        if($value -isnot [bool]){throw ('SOURCE_SECURITY_UNKNOWN: '+$field)}
        if($value){$tpmRequired=$true}
    }
    $mac=if($nics.Count -eq 1){[string](Get-RVProperty $nics[0] MacAddress)}else{''}
    [pscustomobject]@{ProfileVersion=1;SourceDiskCount=1;NetworkAdapterCount=1;SourceVmId=[string]$vm.Id;SourceVmName=$vm.Name;SourceImageSha256=$SourceImageSha256;
        SourceSerialNumber=([string]$SourceFingerprint.SerialNumber).Trim();SourceSize=$SourceFingerprint.Size;SourceLogicalSectorSize=$SourceFingerprint.LogicalSectorSize;
        Generation=$vm.Generation;MemoryStartupBytes=$vm.MemoryStartup;ProcessorCount=$vm.ProcessorCount;
        SecureBoot=(Get-RVProperty (Get-RVProperty $vm Firmware) SecureBoot);SecureBootTemplate=(Get-RVProperty (Get-RVProperty $vm Firmware) SecureBootTemplate);
        TpmRequired=$tpmRequired;EncryptionDependenciesResolved=[bool]$EncryptionDependenciesResolved;
        IdentityPolicy=$(if($AcceptNewVmId){'NewVmId'}else{'Unconfirmed'});MacPolicy=$MacPolicy;MacAddress=$mac;
        GuestBootValidated=$false;LicenseValidated=$false;Notice='Operator must match this source VM inventory to the selected disk image. Network is always disconnected.'}
}

function Test-RVTrue($Value){return ($Value -is [bool] -and $Value -eq $true)}
function Get-RecoverySourceSetHash {
    [CmdletBinding()]param([Parameter(Mandatory)][object[]]$Sources)
    $rows=@(foreach($source in $Sources){[ordered]@{Role=[string](Get-RVProperty $source Role);ControllerLocation=[int](Get-RVProperty $source ControllerLocation);SourceImageSha256=[string](Get-RVProperty $source SourceImageSha256);SerialNumber=[string](Get-RVProperty $source SerialNumber);Size=[uint64](Get-RVProperty $source Size);LogicalSectorSize=[int](Get-RVProperty $source LogicalSectorSize)}})
    $json=ConvertTo-Json -InputObject $rows -Depth 4 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Test-RecoveryV2Profile($Profile) {
    $r=[Collections.Generic.List[string]]::new();$sources=@(Get-RVProperty $Profile Sources)
    if((Get-RVProperty $Profile ProfileVersion) -ne 2){$r.Add('PROFILE_V2_REQUIRED')}
    if((Get-RVProperty $Profile Generation) -ne 2){$r.Add('V2_GENERATION2_REQUIRED')}
    if((Get-RVProperty $Profile SourceDiskCount) -ne $sources.Count -or $sources.Count -lt 1 -or $sources.Count -gt 8){$r.Add('SOURCE_SET_COUNT_INVALID')}
    if((Get-RVProperty $Profile NetworkAdapterCount) -ne 1 -or (Get-RVProperty $Profile MacPolicy) -cne 'New' -or (Get-RVProperty $Profile IdentityPolicy) -cne 'NewVmId'){$r.Add('V2_NEW_IDENTITY_AND_ONE_NIC_REQUIRED')}
    if((Get-RVProperty $Profile OriginalTpmSecretsRequired) -isnot [bool] -or (Get-RVProperty $Profile OriginalTpmSecretsRequired) -ne $false){$r.Add('ORIGINAL_TPM_SECRETS_UNSUPPORTED_OR_UNKNOWN')}
    $tpm=Get-RVProperty $Profile TpmPolicy
    if($tpm -cnotin @('None','NewLocalProtector')){$r.Add('TPM_POLICY_REQUIRED')}
    if($tpm -ceq 'NewLocalProtector' -and -not(Test-RVTrue (Get-RVProperty $Profile AcceptNewTpmIdentity))){$r.Add('NEW_TPM_IDENTITY_ACCEPTANCE_REQUIRED')}
    if((Get-RVProperty $Profile BitLockerState) -cnotin @('Clear','Encrypted')){$r.Add('BITLOCKER_STATE_UNKNOWN')}
    if((Get-RVProperty $Profile BitLockerState) -ceq 'Encrypted'){
        foreach($field in @('RecoveryKeyStoredSeparately','RecoveryKeyMatchesSource','AcceptManualUnlock')){if(-not(Test-RVTrue (Get-RVProperty $Profile $field))){$r.Add('BITLOCKER_ATTESTATION_REQUIRED: '+$field)}}
        if((Get-RVProperty $Profile RecoveryUnlockPolicy) -cne 'UserConsoleOnly'){$r.Add('MANUAL_CONSOLE_UNLOCK_REQUIRED')}
    }
    if((Get-RVProperty $Profile GuestOS) -cnotin @('Windows11','Windows10','WindowsServer')){$r.Add('V2_GUEST_OS_REQUIRED')}
    foreach($field in @('Generation','SourceDiskCount','MemoryStartupBytes','ProcessorCount')){
        $v=Get-RVProperty $Profile $field
        if($v -is [bool] -or ([string]$v) -cnotmatch '^[0-9]+$'){$r.Add('INTEGER_REQUIRED: '+$field)}
    }
    if((Get-RVProperty $Profile MemoryStartupBytes) -lt 2GB -or (Get-RVProperty $Profile MemoryStartupBytes) -gt 1TB -or (Get-RVProperty $Profile ProcessorCount) -lt 1 -or (Get-RVProperty $Profile ProcessorCount) -gt 256){$r.Add('V2_RESOURCES_INVALID')}
    if((Get-RVProperty $Profile SecureBoot) -cnotin @('On','Off')){$r.Add('SECURE_BOOT_POLICY_REQUIRED')}
    if((Get-RVProperty $Profile SecureBoot) -ceq 'On' -and (Get-RVProperty $Profile SecureBootTemplate) -cne 'MicrosoftWindows'){$r.Add('WINDOWS_SECURE_BOOT_TEMPLATE_REQUIRED')}
    foreach($field in @('SourceSetComplete','SourceSetQuiescedTogether')){if(-not(Test-RVTrue (Get-RVProperty $Profile $field))){$r.Add('SOURCE_SET_ATTESTATION_REQUIRED: '+$field)}}
    if(([string](Get-RVProperty $Profile SourceSetSha256)) -cnotmatch '^[0-9a-f]{64}$'){$r.Add('SOURCE_SET_HASH_REQUIRED')}
    elseif((Get-RecoverySourceSetHash -Sources $sources) -cne (Get-RVProperty $Profile SourceSetSha256)){$r.Add('SOURCE_SET_HASH_MISMATCH')}
    if(-not(Test-RVTrue (Get-RVProperty $Profile NoWritesDuringAcquisition))){$r.Add('SOURCE_SET_NO_WRITES_ATTESTATION_REQUIRED')}
    $start=[DateTimeOffset]::MinValue;$end=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string](Get-RVProperty $Profile QuiescentStartUtc),[ref]$start) -or -not [DateTimeOffset]::TryParse([string](Get-RVProperty $Profile QuiescentEndUtc),[ref]$end) -or $start -gt $end -or $end -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){$r.Add('SOURCE_QUIESCENCE_WINDOW_INVALID')}
    $inventoryTime=[DateTimeOffset]::MinValue;$evidenceTime=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string](Get-RVProperty $Profile InventoryCollectedUtc),[ref]$inventoryTime) -or -not [DateTimeOffset]::TryParse([string](Get-RVProperty $Profile EvidenceRecordedUtc),[ref]$evidenceTime) -or $start -lt $inventoryTime -or $end -gt $evidenceTime -or $evidenceTime -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){$r.Add('SOURCE_SET_EVIDENCE_TIME_ORDER_INVALID')}
    $hashes=@();$serials=@()
    for($i=0;$i -lt $sources.Count;$i++){
        $s=$sources[$i];$size=Get-RVProperty $s Size;$hash=[string](Get-RVProperty $s SourceImageSha256);$serial=[string](Get-RVProperty $s SerialNumber)
        if($hash -cnotmatch '^[0-9a-f]{64}$' -or $hash -in $hashes){$r.Add('SOURCE_HASH_INVALID_OR_DUPLICATED')};$hashes+=$hash
        if([string]::IsNullOrWhiteSpace($serial) -or $serial -in $serials){$r.Add('SOURCE_SERIAL_INVALID_OR_DUPLICATED')};$serials+=$serial
        if($size -is [bool] -or ([string]$size) -cnotmatch '^[0-9]+$' -or [decimal]$size -le 0 -or [decimal]$size % 512 -ne 0 -or (Get-RVProperty $s LogicalSectorSize) -ne 512){$r.Add('SOURCE_GEOMETRY_UNSUPPORTED')}
        if((Get-RVProperty $s Role) -cne $(if($i -eq 0){'Boot'}else{'Data'}) -or (Get-RVProperty $s ControllerLocation) -ne $i){$r.Add('SOURCE_ROLE_OR_LOCATION_INVALID')}
    }
    if((Get-RVProperty $Profile GuestOS) -ceq 'Windows11'){
        if((Get-RVProperty $Profile MemoryStartupBytes) -lt 4GB -or (Get-RVProperty $Profile ProcessorCount) -lt 2 -or $sources.Count -lt 1 -or (Get-RVProperty $sources[0] Size) -lt 64GB){$r.Add('WINDOWS11_MINIMUM_RESOURCES_REQUIRED')}
        if($tpm -cne 'NewLocalProtector' -or (Get-RVProperty $Profile SecureBoot) -cne 'On'){$r.Add('WINDOWS11_TPM_AND_SECURE_BOOT_REQUIRED')}
        if(-not(Test-RVTrue (Get-RVProperty $Profile HostWindows11CpuSupported))){$r.Add('HOST_CPU_COMPATIBILITY_ATTESTATION_REQUIRED')}
    }
    [pscustomobject]@{Allowed=($r.Count -eq 0);Reasons=$r.ToArray()}
}
function Add-RecoveryDataDisk($VM,[string]$Path,[int]$Location){
    Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $Location -Path $Path -ErrorAction Stop
}
function Set-RecoveryNewTpm($VM) {
    $state=Get-RecoveryVmIsolation $VM
    if($state.State -ne 'Off' -or -not $state.Isolated -or [string]$state.Id -ne [string]$VM.Id){throw 'NEW_TPM_VM_NOT_OFF_ISOLATED'}
    Set-VMKeyProtector -VM $VM -NewLocalKeyProtector -ErrorAction Stop
    Enable-VMTPM -VM $VM -ErrorAction Stop
}
function Get-RecoveryTpmState($VM) {
    $s=Get-VMSecurity -VM $VM -ErrorAction Stop
    [pscustomobject]@{TpmEnabled=$s.TpmEnabled}
}
function Get-RecoveryV2HardwareState($VM) {
    $firmware=Get-VMFirmware -VM $VM -ErrorAction Stop
    $memory=Get-VMMemory -VM $VM -ErrorAction Stop
    $processor=Get-VMProcessor -VM $VM -ErrorAction Stop
    [pscustomobject]@{SecureBoot=[string]$firmware.SecureBoot;SecureBootTemplate=[string]$firmware.SecureBootTemplate;MemoryStartupBytes=$memory.Startup;ProcessorCount=$processor.Count;DynamicMemoryEnabled=$memory.DynamicMemoryEnabled;ProcessorCompatibilityEnabled=$processor.CompatibilityForMigrationEnabled;Disks=@(Get-VMHardDiskDrive -VM $VM -ErrorAction Stop|Select-Object Path,ControllerType,ControllerNumber,ControllerLocation)}
}
function Assert-RecoverySetState($VM,[string[]]$Paths,$Profile) {
    $state=Get-RecoveryVmIsolation $VM
    if($state.State -ne 'Off' -or -not $state.Isolated -or [string]$state.Id -ne [string]$VM.Id -or $state.Generation -ne 2 -or $state.PhysicalDiskCount -ne 0 -or @($state.DiskPaths).Count -ne $Paths.Count){throw 'V2_VM_CONFIGURATION_MISMATCH'}
    foreach($path in $Paths){if(@($state.DiskPaths|Where-Object{$_ -ceq $path}).Count -ne 1){throw 'V2_VM_DISK_SET_MISMATCH'}}
    $hardware=Get-RecoveryV2HardwareState $VM
    if($hardware.SecureBoot -cne $Profile.SecureBoot -or ($Profile.SecureBoot -ceq 'On' -and $hardware.SecureBootTemplate -cne $Profile.SecureBootTemplate) -or $hardware.MemoryStartupBytes -ne $Profile.MemoryStartupBytes -or $hardware.ProcessorCount -ne $Profile.ProcessorCount){throw 'V2_HARDWARE_READBACK_MISMATCH'}
    if((Get-RVProperty $hardware DynamicMemoryEnabled) -isnot [bool] -or $hardware.DynamicMemoryEnabled -ne $false -or (Get-RVProperty $hardware ProcessorCompatibilityEnabled) -isnot [bool] -or $hardware.ProcessorCompatibilityEnabled -ne $false){throw 'V2_MEMORY_OR_CPU_MODE_MISMATCH'}
    for($i=0;$i -lt $Paths.Count;$i++){
        $mapping=@($hardware.Disks|Where-Object Path -eq $Paths[$i])
        if($mapping.Count -ne 1 -or $mapping[0].ControllerType -ne 'SCSI' -or $mapping[0].ControllerNumber -ne 0 -or $mapping[0].ControllerLocation -ne $i){throw 'V2_DISK_CONTROLLER_MAPPING_MISMATCH'}
    }
    if($Profile.TpmPolicy -ceq 'NewLocalProtector' -and -not(Test-RVTrue (Get-RVProperty (Get-RecoveryTpmState $VM) TpmEnabled))){throw 'NEW_VTPM_NOT_ENABLED'}
    return $state
}
function Read-RecoverySetManifest([string]$Path,$Source) {
    $mp=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} ($Path+'.manifest.json')
    $m=Get-Content -LiteralPath $mp -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if($m.SchemaVersion -ne 1 -or $m.State -cne 'verified' -or $m.Format -cne 'vhdx' -or -not(Test-RVTrue $m.FullSectorImage) -or $m.SourceAcquisitionMode -cne 'offline-block' -or -not(Test-RVTrue $m.Metadata.SourceWriteProtected)){throw 'V2_VERIFIED_ARCHIVE_REQUIRED'}
    foreach($key in @('VirtualSize','QemuCheck','LogicalCompare','ReadbackSha256','LogicalSectorSize')){if(-not(Test-RVTrue (Get-RVProperty $m.Verification $key))){throw 'V2_ARCHIVE_VERIFICATION_MISSING'}}
    if($m.Size -le 0 -or ([string]$m.Sha256) -cnotmatch '^[0-9a-f]{64}$' -or $m.SourceSha256 -cne $Source.SourceImageSha256 -or $m.VirtualSize -ne $Source.Size -or $m.LogicalSectorSize -ne 512){throw 'V2_ARCHIVE_BINDING_MISMATCH'}
    $origin=Get-RVProperty (Get-RVProperty $m Metadata) Source
    foreach($key in @('SerialNumber','Size','LogicalSectorSize')){
        if([string](Get-RVProperty $origin $key) -cne [string](Get-RVProperty $Source $key)){throw 'V2_SOURCE_GEOMETRY_OR_SERIAL_MISMATCH'}
    }
    return $m
}
function Invoke-RecoveryV2 {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([string[]]$VhdxPaths,$Profile,[string]$VMName,[string]$VMRoot,[switch]$Create,[switch]$StartIsolated)
    $check=Test-RecoveryV2Profile $Profile
    if(-not $check.Allowed){throw ('INVALID_V2_PROFILE: '+($check.Reasons -join ', '))}
    if($VMName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}[A-Za-z0-9_-]$'){throw 'INVALID_NEW_VM_NAME'}
    if($StartIsolated -and -not $Create){throw 'START_REQUIRES_CREATE'}
    if($VhdxPaths.Count -ne $Profile.Sources.Count){throw 'V2_ARCHIVE_COUNT_MISMATCH'}
    $root=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} $VMRoot
    if(Test-Path -LiteralPath $root){throw 'VM_ROOT_ALREADY_EXISTS'}
    $archives=@();$working=@();$manifests=@();$streams=@();$log=$null;$created=$null;$offset=[uint64]0;$index=-1;$stage='Validating'
    try{
        $required=[decimal]2GB
        for($i=0;$i -lt $VhdxPaths.Count;$i++){
            $path=& $script:StorageModule {param($p) Resolve-RegularImagePath $p} $VhdxPaths[$i]
            if([IO.Path]::GetExtension($path) -ine '.vhdx' -or $path -in $archives){throw 'V2_UNIQUE_VHDX_FILES_REQUIRED'}
            $manifest=Read-RecoverySetManifest $path $Profile.Sources[$i]
            Assert-RecoveryVhdInfo (Get-RecoveryVhdInfo $path) $manifest
            $reader=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $streams+=,$reader
            if($reader.Length -ne $manifest.Size -or (Get-RVHash $reader) -cne $manifest.Sha256){throw 'V2_ARCHIVE_HASH_MISMATCH'}
            $reader.Position=0
            $archives+=$path;$manifests+=$manifest;$working+=(Join-Path $root ('disk-'+$i+'.vhdx'))
            $required+=[Math]::Max([decimal]$manifest.Size,[decimal]$manifest.VirtualSize)
        }
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
        if($drive.AvailableFreeSpace -lt $required){throw 'V2_WORKING_SPACE_INSUFFICIENT'}
        $hostState=Get-RecoveryHostState
        if($null -eq $hostState.PSObject.Properties['VMs'] -or $null -eq $hostState.VMs){throw 'HOST_VM_INVENTORY_UNKNOWN'}
        if(@($hostState.VMs|Where-Object Name -eq $VMName).Count -gt 0){throw 'VM_NAME_ALREADY_EXISTS'}
        if($Profile.MemoryStartupBytes -gt $hostState.AvailableMemoryBytes -or $Profile.ProcessorCount -gt $hostState.ProcessorCount){throw 'HOST_RESOURCES_INSUFFICIENT'}
        $plan=[pscustomobject]@{State='PlanOnly';VMName=$VMName;VMRoot=$root;Archives=$archives;WorkingCopies=$working;Network='Disconnected';TpmPolicy=$Profile.TpmPolicy;OriginalTpmSecretsRestored=$false;CpuCompatibility='OperatorAttestationNotMeasured';BootTested=$false;RestoreTested=$false;LicenseValidated=$false;BitLockerUnlock='UserConsoleOnlyNoKeysCollected'}
        if(-not $Create){return $plan}
        if(-not $PSCmdlet.ShouldProcess($root,('Create NEW isolated VM and '+$working.Count+' working disk copies; TPM='+$Profile.TpmPolicy+' (new secrets, not original); optional start='+$StartIsolated))){return $plan}
        New-Item -ItemType Directory -Path $root -ErrorAction Stop|Out-Null
        $log=Join-Path $root 'recovery.events.jsonl'
        $stage='Copying'
        for($i=0;$i -lt $streams.Count;$i++){
            $index=$i;$offset=0;$out=$null
            Write-RVEvent $log 'copying' ('DiskIndex='+$i+'; expected bytes='+$manifests[$i].Size)
            try{
                $out=[IO.File]::Open(($working[$i]+'.partial'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $buffer=New-Object byte[] (4MB)
                while(($n=$streams[$i].Read($buffer,0,$buffer.Length)) -gt 0){$out.Write($buffer,0,$n);$offset+=[uint64]$n}
                if($offset -ne $manifests[$i].Size){throw 'V2_WORKING_COPY_SHORT'}
                $out.Flush($true);$out.Dispose();$out=$null
                $verify=[IO.File]::Open(($working[$i]+'.partial'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
                try{if((Get-RVHash $verify) -cne $manifests[$i].Sha256){throw 'V2_WORKING_COPY_HASH_MISMATCH'}}finally{$verify.Dispose()}
                [IO.File]::Move(($working[$i]+'.partial'),$working[$i])
                Assert-RecoveryVhdInfo (Get-RecoveryVhdInfo $working[$i]) $manifests[$i]
                Write-RVEvent $log 'working-copy-verified' ('DiskIndex='+$i)
            }finally{if($null -ne $out){$out.Dispose()}}
        }
        $latest=Get-RecoveryHostState
        if($null -eq $latest.PSObject.Properties['VMs'] -or $null -eq $latest.VMs -or @($latest.VMs|Where-Object Name -eq $VMName).Count -gt 0){throw 'HOST_INVENTORY_CHANGED_OR_NAME_COLLISION'}
        if($Profile.MemoryStartupBytes -gt $latest.AvailableMemoryBytes -or $Profile.ProcessorCount -gt $latest.ProcessorCount){throw 'HOST_RESOURCES_CHANGED'}
        $stage='CreatingVM'
        $created=New-RecoveryVM -Name $VMName -Generation 2 -Memory $Profile.MemoryStartupBytes -Path $root
        if($null -eq $created -or [string]::IsNullOrWhiteSpace([string]$created.Id) -or $created.Name -ne $VMName -or [string]$created.Id -in @($latest.VMs|ForEach-Object{[string]$_.Id})){throw 'NEW_VM_IDENTITY_INVALID'}
        Write-RVEvent $log 'vm-created' ('VMId='+$created.Id)
        $initial=Get-RecoveryVmIsolation $created
        if($initial.State -ne 'Off' -or -not $initial.Isolated -or [string]$initial.Id -ne [string]$created.Id){throw 'NEW_VM_NOT_OFF_AND_ISOLATED'}
        $stage='ConfiguringVM'
        Set-RecoveryVmHardware -VM $created -Profile $Profile -VhdxPath $working[0]
        for($i=1;$i -lt $working.Count;$i++){Add-RecoveryDataDisk -VM $created -Path $working[$i] -Location $i}
        if($Profile.TpmPolicy -ceq 'NewLocalProtector'){Set-RecoveryNewTpm $created;Write-RVEvent $log 'new-local-vtpm-configured' 'New TPM identity only; original TPM secrets are NOT recovered.'}
        $state=Assert-RecoverySetState $created $working $Profile
        if($StartIsolated){$stage='StartingVM';Start-RecoveryVM $created;$state=Get-RecoveryVmIsolation $created;if(-not $state.Isolated){throw 'VM_ISOLATION_LOST'}}
        $result=[pscustomobject]@{State=$(if($StartIsolated){'StartRequestedUnverified'}else{'VMCreatedOff'});VMId=[string]$created.Id;VMName=$VMName;WorkingCopies=$working;Network='Disconnected';TpmPolicy=$Profile.TpmPolicy;OriginalTpmSecretsRestored=$false;CpuCompatibility='OperatorAttestationNotMeasured';RecoveryKeysCollected=$false;BootTested=$false;RestoreTested=$false;LicenseValidated=$false}
        $result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'recovery-result.json') -Encoding UTF8 -ErrorAction Stop
        Write-RVEvent $log 'completed-unverified-guest' 'VM lifecycle only. User must verify guest boot and manually unlock encrypted volumes if needed.'
        return $result
    }catch{
        if($log){try{Write-RecoveryFailure $root $stage $created $working $offset $_}catch{}}
        if($log){try{Write-RVEvent $log 'failed' ('DiskIndex='+$index+'; Offset='+$offset+'; HResult='+$_.Exception.HResult+'; '+$_.Exception.Message+'; artifacts retained; no automatic cleanup')}catch{}}
        throw
    }finally{foreach($stream in $streams){$stream.Dispose()}}
}

Export-ModuleMember -Function Test-RecoveryVmProfile,Invoke-IsolatedVmRecovery,New-RecoveryVmProfile,Get-RecoverySourceSetHash
