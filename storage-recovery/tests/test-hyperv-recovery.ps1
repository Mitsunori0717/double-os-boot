#requires -Version 5.1
# Synthetic files only. Every Hyper-V wrapper is replaced before invocation.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HyperVRecovery.psm1') -Force -PassThru
$script:Count=0
function Assert-True($Condition,[string]$Message) { if(-not $Condition){throw "TEST FAILED: $Message"};$script:Count++ }
function Assert-Throws([scriptblock]$Action,[string]$Message) { $failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert-True $failed $Message }
function New-TestProfile {
    [pscustomobject]@{ProfileVersion=1;SourceDiskCount=1;NetworkAdapterCount=1;SourceImageSha256=('a'*64);SourceSerialNumber='SOURCE-SERIAL';SourceSize=16384;SourceLogicalSectorSize=512;Generation=2;MemoryStartupBytes=[uint64]1GB;ProcessorCount=2;SecureBoot='Off';SecureBootTemplate='';TpmRequired=$false;EncryptionDependenciesResolved=$true;IdentityPolicy='NewVmId';MacPolicy='New';SourceVmId='11111111-2222-3333-4444-555555555555'}
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxHyperVTests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $vhd=Join-Path $temp 'fixture.vhdx'
    [IO.File]::WriteAllBytes($vhd,(New-Object byte[] 4096))
    $hash=(Get-FileHash -LiteralPath $vhd -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest=[ordered]@{SchemaVersion=1;SourceSha256=('a'*64);State='verified';Format='vhdx';Size=4096;VirtualSize=16384;Sha256=$hash;LogicalSectorSize=512;SourceAcquisitionMode='offline-block';Metadata=@{SourceWriteProtected=$true;Source=@{SerialNumber='SOURCE-SERIAL';Size=16384;LogicalSectorSize=512}};FullSectorImage=$true;Verification=@{VirtualSize=$true;QemuCheck=$true;LogicalCompare=$true;ReadbackSha256=$true;LogicalSectorSize=$true};RestoreTested=$false;BootTested=$false}
    $manifestPath=$vhd+'.manifest.json'
    $manifestJson=$manifest|ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($manifestPath,$manifestJson,[Text.UTF8Encoding]::new($false))
    $vmRoot=Join-Path $temp 'vms'

    & $module {
        function script:Get-RecoveryHostState { if($script:F.HostFailure){throw 'fixture host inventory failure'}; $script:F.HostReads++;if($script:F.LoseMemory -and $script:F.HostReads -gt 1){$script:F.Host.AvailableMemoryBytes=256MB};$script:F.Host }
        function script:Get-RecoveryVhdInfo([string]$Path) { $script:F.Vhd }
        function script:New-RecoveryVM([string]$Name,[int]$Generation,[long]$Memory,[string]$Path) {
            $script:F.Calls.Add('New')
            if($script:F.CreateFailure){throw 'fixture create failure'}
            $script:F.Root=$Path;$script:F.VM=[pscustomobject]@{Name=$Name;Id='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
            $script:F.VM
        }
        function script:Set-RecoveryVmHardware($VM,$Profile,[string]$VhdxPath) {
            $script:F.Calls.Add('Set')
            if($VM.Id -ne $script:F.VM.Id){throw 'wrong VM touched'}
            $script:F.DiskPaths=@($VhdxPath);$script:F.Generation=$Profile.Generation
            if($Profile.MacPolicy -eq 'Preserve'){$script:F.Macs=@($Profile.MacAddress)}
            if($script:F.HardwareFailure){throw 'fixture hardware failure'}
            if($script:F.LoseIsolation){$script:F.Isolated=$false}
        }
        function script:Get-RecoveryVmIsolation($VM) {
            [pscustomobject]@{Id=$VM.Id;Name=$VM.Name;State=$script:F.State;Generation=$script:F.Generation;Isolated=$script:F.Isolated;MacAddresses=$script:F.Macs;DiskPaths=$script:F.DiskPaths;PhysicalDiskCount=0}
        }
        function script:Start-RecoveryVM($VM) {
            if(-not $script:F.Isolated){throw 'attempted start without isolation'}
            $script:F.Calls.Add('Start');$script:F.State='Running'
        }
        # Defense in depth: any accidental bypass of wrappers fails, not a real host action.
        foreach($name in @('Get-VM','Get-VMHost','Get-VHD','New-VM','Set-VM','Set-VMProcessor','Set-VMMemory','Add-VMHardDiskDrive','Get-VMHardDiskDrive','Set-VMFirmware','Set-VMBios','Get-VMNetworkAdapter','Set-VMNetworkAdapter','Start-VM','Stop-VM','Remove-VM','Get-CimInstance')) {
            Set-Item -Path ('Function:script:'+ $name) -Value { throw 'Real Hyper-V/system cmdlet forbidden in this test' }
        }
    }
    function Reset-Fixture {
        & $module {
            $script:F=[pscustomobject]@{
                Host=[pscustomobject]@{VMs=@();MacAddresses=@();ProcessorCount=8;AvailableMemoryBytes=[uint64]8GB}
                Vhd=[pscustomobject]@{VhdFormat='VHDX';VhdType='Dynamic';Attached=$false;Size=16384;LogicalSectorSize=512;ParentPath=''}
                Calls=[Collections.Generic.List[string]]::new();VM=$null;Root='';State='Off';Generation=2;Isolated=$true;Macs=@('00155D123456');DiskPaths=@()
                HostFailure=$false;CreateFailure=$false;HardwareFailure=$false;LoseIsolation=$false;HostReads=0;LoseMemory=$false
            }
        }
    }
    function Calls { @(& $module { $script:F.Calls.ToArray() }) }
    function Run-Recovery([switch]$Create,[switch]$Start,[switch]$WhatIfOnly,$Profile=(New-TestProfile)) {
        $args=@{VhdxPath=$vhd;Profile=$Profile;VMName='Recovery-Test';VMRoot=$vmRoot;Confirm=$false}
        if($Create){$args.Create=$true};if($Start){$args.StartIsolated=$true};if($WhatIfOnly){$args.WhatIf=$true}
        Invoke-IsolatedVmRecovery @args
    }
    Reset-Fixture
    $sourceVM=[pscustomobject]@{Name='SourceVM';Id='source-vm-id';Generation=2;MemoryStartup=[uint64]1GB;ProcessorCount=2;Firmware=[pscustomobject]@{SecureBoot='Off';SecureBootTemplate=''};Security=[pscustomobject]@{TpmEnabled=$false;Shielded=$false;BindToHostTpm=$false};Disks=@([pscustomobject]@{DiskNumber=0;Path=$null});NetworkAdapters=@([pscustomobject]@{MacAddress='00155D654321'})}
    $fingerprint=[pscustomobject]@{SerialNumber='SOURCE-SERIAL';Size=16384;LogicalSectorSize=512}
    $inventory=[pscustomobject]@{VmInventoryComplete=$true;Disks=@([pscustomobject]@{Number=0;SerialNumber='SOURCE-SERIAL';Size=16384;LogicalSectorSize=512});VirtualMachines=@($sourceVM)}
    $generated=New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)
    Assert-True (-not (Test-RecoveryVmProfile $generated).Allowed) 'generated profile requires explicit identity/MAC/encryption decisions'
    $generated=New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64) -AcceptNewVmId -MacPolicy Preserve -EncryptionDependenciesResolved
    Assert-True (Test-RecoveryVmProfile $generated).Allowed 'fully confirmed known source profile validates'
    Assert-True ($generated.MacAddress -eq '00155D654321' -and $generated.SourceVmId -eq 'source-vm-id') 'source identity and MAC carried into profile'
    Assert-True (-not $generated.GuestBootValidated -and -not $generated.LicenseValidated) 'profile generation does not validate guest or license'
    foreach($securityField in @('TpmEnabled','Shielded','BindToHostTpm')) {
        $sourceVM.Security.$securityField=$null
        Assert-Throws { New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64) -AcceptNewVmId -MacPolicy New -EncryptionDependenciesResolved } 'unknown hardware security dependency rejected'
        $sourceVM.Security.$securityField=$true
        $generated=New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64) -AcceptNewVmId -MacPolicy New -EncryptionDependenciesResolved
        Assert-True (-not (Test-RecoveryVmProfile $generated).Allowed) 'enabled TPM or host binding fails validation'
        $sourceVM.Security.$securityField=$false
    }    $sourceVM.Security.TpmEnabled=$false
    $inventory.VmInventoryComplete=$false
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'profile generation from incomplete inventory rejected'
    $inventory.VmInventoryComplete=$true
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName Missing -SourceImageSha256 ('a'*64)} 'unknown source VM rejected'
    $sourceVM.Disks+= [pscustomobject]@{DiskNumber=2;Path=$null}
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'multiple source disks rejected'
    $sourceVM.Disks=@([pscustomobject]@{DiskNumber=0;Path=$null})
    $sourceVM.NetworkAdapters+= [pscustomobject]@{MacAddress='00155D987654'}
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'multiple source NICs rejected'
    $sourceVM.NetworkAdapters=@([pscustomobject]@{MacAddress='00155D654321'})
    foreach($field in @('SerialNumber','Size','LogicalSectorSize')) {
        $wrong=$fingerprint.PSObject.Copy();$wrong.$field='different'
        Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $wrong -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} "source disk $field mismatch rejected"
    }
    Assert-Throws {New-RecoveryVmProfile -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'missing source fingerprint rejected'
    $inventory.Disks+= [pscustomobject]@{Number=9;SerialNumber='SOURCE-SERIAL';Size=16384;LogicalSectorSize=512}
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'ambiguous serial identity rejected'
    $inventory.Disks=@($inventory.Disks|Where-Object Number -ne 9)
    $sourceVM.Disks[0].DiskNumber=$null
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'unknown passthrough source mapping rejected'
    $sourceVM.Disks[0].DiskNumber=0
    $inventory.VirtualMachines=@($sourceVM,$sourceVM)
    Assert-Throws {New-RecoveryVmProfile -SourceFingerprint $fingerprint -Inventory $inventory -SourceVMName SourceVM -SourceImageSha256 ('a'*64)} 'duplicate source VM rejected'
    $cli=Join-Path (Split-Path $PSScriptRoot -Parent) 'restore-vm.ps1'
    $tokens=$null;$parseErrors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($cli,[ref]$tokens,[ref]$parseErrors)|Out-Null
    Assert-True (@($parseErrors).Count -eq 0) 'restore CLI syntax parses without executing Hyper-V'
    Assert-True (Test-RecoveryVmProfile (New-TestProfile)).Allowed 'valid profile'
    foreach($field in @('SourceDiskCount','NetworkAdapterCount','SourceImageSha256','SourceSerialNumber','SourceSize','SourceLogicalSectorSize','ProfileVersion','Generation','MemoryStartupBytes','ProcessorCount','SecureBoot','TpmRequired','EncryptionDependenciesResolved','IdentityPolicy','MacPolicy')) {
        $profile=New-TestProfile;$profile.PSObject.Properties.Remove($field)
        Assert-True (-not (Test-RecoveryVmProfile $profile).Allowed) "unknown profile field $field rejected"
    }
    $profile=New-TestProfile;$profile.TpmRequired=$true
    Assert-True (-not (Test-RecoveryVmProfile $profile).Allowed) 'TPM dependency rejected'
    $profile=New-TestProfile;$profile.MacPolicy='Preserve';$profile|Add-Member MacAddress '01005E000001'
    Assert-True (-not (Test-RecoveryVmProfile $profile).Allowed) 'multicast MAC rejected'
    $profile=New-TestProfile;$profile.SourceImageSha256=('b'*64)
    Assert-Throws {Run-Recovery -Create -Profile $profile} 'profile bound to different source image rejected'
    & $module {$script:F.Host.VMs=$null}
    Assert-Throws {Run-Recovery -Create} 'null VM inventory cannot mean empty host'
    Reset-Fixture
    & $module {$script:F.Host.ProcessorCount=1}
    Assert-Throws {Run-Recovery -Create} 'insufficient CPU capacity rejected'
    Reset-Fixture
    & $module {$script:F.Host.AvailableMemoryBytes=256MB}
    Assert-Throws {Run-Recovery -Create} 'insufficient memory rejected'
    Reset-Fixture
    $plan=Run-Recovery
    Assert-True ($plan.State -eq 'PlanOnly') 'default is plan only'
    Assert-True ((Calls).Count -eq 0) 'plan performs no VM mutations'
    Assert-True (-not (Test-Path -LiteralPath $vmRoot)) 'plan creates no working directory'
    $plan=Run-Recovery -Create -WhatIfOnly
    Assert-True ($plan.State -eq 'PlanOnly' -and (Calls).Count -eq 0) 'WhatIf performs no VM mutations'
    Assert-True (-not (Test-Path -LiteralPath $vmRoot)) 'WhatIf copies no image'
    Assert-Throws {Run-Recovery -Start} 'start without explicit create rejected'
    & $module { $script:F.Host.VMs=@([pscustomobject]@{Name='Recovery-Test';Id='existing-id'}) }
    Assert-Throws {Run-Recovery -Create} 'existing VM name rejected'
    Assert-True ((Calls).Count -eq 0) 'existing VM not changed'
    Reset-Fixture
    & $module {$script:F.HostFailure=$true}
    Assert-Throws {Run-Recovery -Create} 'unreadable host rejected'
    Reset-Fixture
    foreach($field in @('VirtualSize','QemuCheck','LogicalCompare','ReadbackSha256')) {
        $m=$manifestJson|ConvertFrom-Json;$m.Verification.$field=$false
        [IO.File]::WriteAllText($manifestPath,($m|ConvertTo-Json -Depth 8))
        Assert-Throws {Run-Recovery -Create} "verification $field false rejected"
    }
    $m=$manifestJson|ConvertFrom-Json;$m.FullSectorImage='true'
    [IO.File]::WriteAllText($manifestPath,($m|ConvertTo-Json -Depth 8))
    Assert-Throws {Run-Recovery -Create} 'string true cannot stand for verified full-sector image'
    $m=$manifestJson|ConvertFrom-Json;$m.SourceAcquisitionMode='fixture'
    [IO.File]::WriteAllText($manifestPath,($m|ConvertTo-Json -Depth 8))
    Assert-Throws {Run-Recovery -Create} 'fixture acquisition cannot create VM'
    [IO.File]::WriteAllText($manifestPath,$manifestJson)
    # A correctly hashed archive from a different source must not pass a profile
    # generated for the intended source merely because an operator copied its hash.
    foreach($field in @('SerialNumber','Size','LogicalSectorSize')){
        $m=$manifestJson|ConvertFrom-Json
        $m.Metadata.Source.$field=$(if($field -eq 'SerialNumber'){'OTHER-SERIAL'}else{4096})
        [IO.File]::WriteAllText($manifestPath,($m|ConvertTo-Json -Depth 8))
        Assert-Throws {Run-Recovery -Create} ('manifest source binding rejected: '+$field)
        Assert-True ((Calls).Count -eq 0 -and -not(Test-Path -LiteralPath $vmRoot)) 'wrong source refused before any copy or VM mutation'
    }
    [IO.File]::WriteAllText($manifestPath,$manifestJson)
    foreach($case in @('Attached','ParentPath','Size','LogicalSectorSize','VhdType')) {
        Reset-Fixture
        & $module {param($case) switch($case){Attached{$script:F.Vhd.Attached=$true};ParentPath{$script:F.Vhd.ParentPath='parent.vhdx'};Size{$script:F.Vhd.Size=9999};LogicalSectorSize{$script:F.Vhd.LogicalSectorSize=4096};VhdType{$script:F.Vhd.VhdType='Differencing'}}} $case
        Assert-Throws {Run-Recovery -Create} "invalid VHD property $case rejected"
        Assert-True ((Calls).Count -eq 0) "invalid VHD $case causes no VM mutation"
    }
    Reset-Fixture
    $profile=New-TestProfile;$profile.MacPolicy='Preserve';$profile|Add-Member MacAddress '00155D123456'
    & $module {$script:F.Host.MacAddresses=@('00155D123456')}
    Assert-Throws {Run-Recovery -Create -Profile $profile} 'existing MAC collision rejected'
    Reset-Fixture
    [IO.File]::WriteAllBytes($vhd,(New-Object byte[] 4095))
    Assert-Throws {Run-Recovery -Create} 'truncated archive rejected'
    [IO.File]::WriteAllBytes($vhd,(New-Object byte[] 4096))
    $bad=New-Object byte[] 4096;$bad[0]=1;[IO.File]::WriteAllBytes($vhd,$bad)
    Assert-Throws {Run-Recovery -Create} 'tampered archive rejected'
    [IO.File]::WriteAllBytes($vhd,(New-Object byte[] 4096))
    Assert-True ((Calls).Count -eq 0) 'invalid archives cause no mutations'
    Reset-Fixture
    & $module {$script:F.LoseMemory=$true}
    Assert-Throws {Run-Recovery -Create} 'host resources rechecked after potentially long copy'
    Assert-True ((Calls).Count -eq 0) 'resource loss prevents VM creation'
    $failure=Get-Content -LiteralPath (Join-Path $vmRoot 'recovery-failure.json') -Raw|ConvertFrom-Json
    Assert-True ($failure.State -eq 'Failed' -and $failure.ArtifactsRetained -and -not $failure.BootTested) 'failed copy workflow records retained artifacts without a success claim'
    $vmRoot=Join-Path $temp 'creation-failure'
    Reset-Fixture
    & $module {$script:F.CreateFailure=$true}
    Assert-Throws {Run-Recovery -Create} 'VM creation failure propagated'
    Assert-True ((Get-Content -LiteralPath (Join-Path $vmRoot 'recovery.events.jsonl') -Raw).Contains('fixture create failure')) 'creation failure logged'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $vmRoot 'recovery-result.json'))) 'failure cannot publish success result'
    $failure=Get-Content -LiteralPath (Join-Path $vmRoot 'recovery-failure.json') -Raw|ConvertFrom-Json
    Assert-True ($failure.Stage -eq 'CreatingVM' -and $failure.State -eq 'Failed') 'VM creation failure has machine-readable stage'
    Assert-True ((Get-FileHash -LiteralPath $vhd).Hash.ToLowerInvariant() -eq $hash) 'failure leaves original archive unchanged'
    $vmRoot=Join-Path $temp 'isolated-failure'
    Reset-Fixture
    & $module {$script:F.LoseIsolation=$true}
    Assert-Throws {Run-Recovery -Create -Start} 'network isolation loss blocks start'
    Assert-True ('Start' -notin (Calls)) 'disconnected requirement verified before start'
    $vmRoot=Join-Path $temp 'success-off'
    Reset-Fixture
    $result=Run-Recovery -Create
    Assert-True ($result.State -eq 'VMCreatedOff') 'created VM remains off by default'
    Assert-True ((Calls) -join ',' -eq 'New,Set') 'only newly created VM configured'
    Assert-True ($result.WorkingCopy -eq (Join-Path $vmRoot 'os.vhdx')) 'VM uses dedicated working copy'
    Assert-True ($result.WorkingCopy -ne $vhd) 'archive never attached'
    Assert-True (-not $result.BootTested -and -not $result.RestoreTested -and -not $result.LicenseValidated) 'creation makes no guest validation claim'
    Assert-True ((Get-FileHash -LiteralPath $vhd).Hash.ToLowerInvariant() -eq $hash) 'creation leaves archive unchanged'
    Assert-True ((Get-FileHash -LiteralPath $result.WorkingCopy).Hash.ToLowerInvariant() -eq $hash) 'working copy verified identical'
    Assert-Throws {Run-Recovery -Create} 'existing output directory never overwritten'
    $vmRoot=Join-Path $temp 'success-start'
    Reset-Fixture
    $result=Run-Recovery -Create -Start
    Assert-True ((Calls) -join ',' -eq 'New,Set,Start') 'start only after new VM setup'
    Assert-True ($result.ObservedVMState -eq 'Running' -and $result.State -eq 'StartRequestedUnverified') 'running recorded separately from boot verification'
    Assert-True (-not $result.BootTested -and -not $result.RestoreTested -and -not $result.LicenseValidated) 'running does not imply boot, FSBP or license verification'
    Assert-True ((Get-FileHash -LiteralPath $vhd).Hash.ToLowerInvariant() -eq $hash) 'start flow leaves archive unchanged'
    $vmRoot=Join-Path $temp 'preserve-mac'
    Reset-Fixture
    $profile=New-TestProfile;$profile.MacPolicy='Preserve';$profile|Add-Member MacAddress '00155D654321'
    $result=Run-Recovery -Create -Profile $profile
    $macs=& $module {$script:F.Macs}
    Assert-True ('00155D654321' -in $macs) 'explicit preserve MAC passed to new isolated VM only'
    Assert-True (-not $result.LicenseValidated) 'preserving MAC does not claim valid license'
    Write-Host ("PASS: {0} isolated Hyper-V recovery assertions; mock Hyper-V, synthetic files only" -f $script:Count)
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxHyperVTests_[0-9a-f]{32}$'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Remove-Module $module -Force
}
