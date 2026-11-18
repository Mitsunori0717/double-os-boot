#requires -Version 5.1
Set-StrictMode -Version Latest
$script:StorageModule=Import-Module (Join-Path $PSScriptRoot 'StorageRecovery.psm1') -PassThru -Force
function Get-RVProperty($Object,[string]$Name) {
    if($null -eq $Object){return $null}; if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $null
}
function Test-RecoveryVmProfile {
    [CmdletBinding()]param([Parameter(Mandatory)]$Profile)
    $r=[Collections.Generic.List[string]]::new()
    if((Get-RVProperty $Profile ProfileVersion) -ne 1){$r.Add('PROFILE_VERSION_REQUIRED')}
    if((Get-RVProperty $Profile SourceDiskCount) -ne 1){$r.Add('SINGLE_SOURCE_DISK_REQUIRED')}
    if((Get-RVProperty $Profile NetworkAdapterCount) -ne 1){$r.Add('SINGLE_NETWORK_ADAPTER_REQUIRED')}
    if((Get-RVProperty $Profile Generation) -notin @(1,2)){$r.Add('GENERATION_REQUIRED')}
    if((Get-RVProperty $Profile MemoryStartupBytes) -lt 512MB -or (Get-RVProperty $Profile MemoryStartupBytes) -gt 1TB){$r.Add('MEMORY_OUT_OF_RANGE')}
    if((Get-RVProperty $Profile ProcessorCount) -lt 1 -or (Get-RVProperty $Profile ProcessorCount) -gt 256){$r.Add('CPU_OUT_OF_RANGE')}
    if(([string](Get-RVProperty $Profile SourceImageSha256)) -cnotmatch '^[0-9a-f]{64}$'){$r.Add('SOURCE_IMAGE_HASH_REQUIRED')}
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
        [Parameter(Mandatory)][string]$VMName,[Parameter(Mandatory)][string]$VMRoot,[switch]$Create,[switch]$StartIsolated)
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
    $hostState=Get-RecoveryHostState
    if($null -eq $hostState.PSObject.Properties['VMs'] -or $null -eq $hostState.VMs){throw 'HOST_VM_INVENTORY_UNKNOWN'}
    if(@($hostState.VMs|Where-Object Name -eq $VMName).Count -gt 0){throw 'VM_NAME_ALREADY_EXISTS'}
    if($Profile.ProcessorCount -gt $hostState.ProcessorCount -or $Profile.MemoryStartupBytes -gt $hostState.AvailableMemoryBytes){throw 'HOST_RESOURCES_INSUFFICIENT'}
    if($Profile.MacPolicy -ceq 'Preserve' -and $Profile.MacAddress -in $hostState.MacAddresses){throw 'MAC_ALREADY_PRESENT_ON_HOST'}
    Assert-RecoveryVhdInfo (Get-RecoveryVhdInfo $source) $m
    $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
    $requiredSpace=[Math]::Max([decimal]$m.Size,[decimal]$m.VirtualSize)+2GB
    if($drive.AvailableFreeSpace -lt $requiredSpace){throw 'WORKING_COPY_SPACE_INSUFFICIENT'}
    $sourceStream=$null;$output=$null;$created=$null;$log=$null;$offset=[uint64]0;$working=Join-Path $root 'os.vhdx'
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
        $created=New-RecoveryVM -Name $VMName -Generation $Profile.Generation -Memory $Profile.MemoryStartupBytes -Path $root
        if($null -eq $created -or [string]::IsNullOrEmpty([string]$created.Id) -or $created.Name -ne $VMName){throw 'NEW_VM_RESULT_INVALID'}
        if([string]$created.Id -in @($latest.VMs|ForEach-Object{[string]$_.Id})){throw 'NEW_VM_ID_COLLISION'}
        Write-RVEvent $log 'vm-created' ('VMId='+$created.Id)
        $initial=Get-RecoveryVmIsolation $created
        if($initial.State -ne 'Off' -or -not $initial.Isolated -or [string]$initial.Id -ne [string]$created.Id){throw 'NEW_VM_NOT_OFF_AND_ISOLATED'}
        Set-RecoveryVmHardware -VM $created -Profile $Profile -VhdxPath $working
        $state=Get-RecoveryVmIsolation $created
        if(-not $state.Isolated -or $state.State -ne 'Off' -or $state.PhysicalDiskCount -ne 0 -or @($state.DiskPaths).Count -ne 1 -or $state.DiskPaths[0] -ne $working){throw 'CONFIGURED_VM_ISOLATION_OR_DISK_MISMATCH'}
        if($Profile.MacPolicy -ceq 'Preserve' -and $Profile.MacAddress -notin $state.MacAddresses){throw 'MAC_CONFIGURATION_MISMATCH'}
        if($StartIsolated){Start-RecoveryVM $created;$state=Get-RecoveryVmIsolation $created;if(-not $state.Isolated){throw 'VM_ISOLATION_LOST'}}
        $result=[pscustomobject]@{State=$(if($StartIsolated){'StartRequestedUnverified'}else{'VMCreatedOff'});VMId=[string]$created.Id;VMName=$VMName;ObservedVMState=$state.State;VMRoot=$root;WorkingCopy=$working;Network='Disconnected';SourceSha256=$m.Sha256;NewVmId=$true;BootTested=$false;RestoreTested=$false;LicenseValidated=$false}
        $result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root 'recovery-result.json') -Encoding UTF8 -ErrorAction Stop
        Write-RVEvent $log 'completed-unverified-guest' 'VM lifecycle only; OS boot, FSBP and licensing remain unverified.'
        return $result
    }catch{
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
        Generation=$vm.Generation;MemoryStartupBytes=$vm.MemoryStartup;ProcessorCount=$vm.ProcessorCount;
        SecureBoot=(Get-RVProperty (Get-RVProperty $vm Firmware) SecureBoot);SecureBootTemplate=(Get-RVProperty (Get-RVProperty $vm Firmware) SecureBootTemplate);
        TpmRequired=$tpmRequired;EncryptionDependenciesResolved=[bool]$EncryptionDependenciesResolved;
        IdentityPolicy=$(if($AcceptNewVmId){'NewVmId'}else{'Unconfirmed'});MacPolicy=$MacPolicy;MacAddress=$mac;
        GuestBootValidated=$false;LicenseValidated=$false;Notice='Operator must match this source VM inventory to the selected disk image. Network is always disconnected.'}
}
Export-ModuleMember -Function Test-RecoveryVmProfile,Invoke-IsolatedVmRecovery,New-RecoveryVmProfile
