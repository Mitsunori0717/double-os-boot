#requires -Version 5.1
# Independent integration: provider fixtures -> sanitized inventory -> pure plan -> profile schema.
# No physical device, registry, OS query, Hyper-V operation, or settings change is executed.
$ErrorActionPreference='Stop'
$dir=Split-Path $PSScriptRoot -Parent
$im=Import-Module (Join-Path $dir 'WindowsRecoveryInventory.psm1') -Force -PassThru
$pm=Import-Module (Join-Path $dir 'WindowsRecoveryPlan.psm1') -Force -PassThru
$hm=Import-Module (Join-Path $dir 'HyperVRecovery.psm1') -Force -PassThru
$script:Count=0
function Assert-True($value,[string]$message){if(-not $value){throw "TEST FAILED: $message"};$script:Count++}
function Assert-Throws([scriptblock]$action,[string]$message){$threw=$false;try{& $action|Out-Null}catch{$threw=$true};Assert-True $threw $message}
$secret='SECRET_FIXTURE_DO_NOT_EXPORT_94723'
& $im {
    function script:Get-WriPlatform {$true}
    function script:Get-WriHost {'INTEGRATION-FIXTURE'}
    function script:Get-WriDisks {if($script:F.Fail -eq 'Disks'){throw ('provider error '+$script:F.Secret)};$script:F.Disks}
    function script:Get-WriPhysicalDisks {if($script:F.Fail -eq 'Physical'){throw 'provider failed'};$script:F.Physical}
    function script:Get-WriPartitions {if($script:F.Fail -eq 'Partitions'){throw 'provider failed'};$script:F.Partitions}
    function script:Get-WriOS {if($script:F.Fail -eq 'OS'){throw 'provider failed'};$script:F.OS}
    function script:Get-WriFirmware {if($script:F.Fail -eq 'Firmware'){throw 'provider failed'};$script:F.Firmware}
    function script:Get-WriSecureBoot {if($script:F.Fail -eq 'SecureBoot'){throw 'provider failed'};$script:F.SecureBoot}
    function script:Get-WriPower {if($script:F.Fail -eq 'Power'){throw ('provider error '+$script:F.Secret)};$script:F.Power}
    function script:Get-WriEncryptionStates {if($script:F.Fail -eq 'Encryption'){throw ('provider error '+$script:F.Secret)};$script:F.Encryption}
    foreach($cmd in @('Get-Disk','Get-Partition','Get-CimInstance','Invoke-CimMethod','Get-ComputerInfo','Confirm-SecureBootUEFI','Get-ItemProperty','Get-BitLockerVolume','Get-Tpm','Get-VM','New-VM','Set-Disk','Start-VM','Stop-VM')) {
        Set-Item -Path ('Function:script:'+$cmd) -Value {throw 'Real system query or mutation forbidden in integration test'}
    }
}
function Reset-Fixture {
    & $im {param($secret)
        $script:F=[pscustomobject]@{
            Secret=$secret;Fail='';Firmware='Uefi';SecureBoot=$true
            Disks=@([pscustomobject]@{Number=0;FriendlyName='Fixture SSD';SerialNumber='FIXTURE-SERIAL';UniqueId='WINDOWS-DISK-ID';Size=1048576;LogicalSectorSize=512;PhysicalSectorSize=4096;PartitionStyle='GPT';IsBoot=$true;IsSystem=$true;IsOffline=$false;IsReadOnly=$false;BusType='NVMe';RecoveryPassword=$secret})
            Physical=@([pscustomobject]@{Index=0;Secret=$secret})
            Partitions=@(
                [pscustomobject]@{DiskNumber=0;PartitionNumber=1;DriveLetter='';Size=65536;Offset=512;GptType='c12a7328-f81f-11d2-ba4b-00a0c93ec93b';MbrType=0;Type='System';IsBoot=$false;IsSystem=$true;IsActive=$false;Secret=$secret},
                [pscustomobject]@{DiskNumber=0;PartitionNumber=2;DriveLetter='C';Size=524288;Offset=66048;GptType='ebd0a0a2-b9e5-4433-87c0-68b6b72699c7';MbrType=0;Type='Basic';IsBoot=$true;IsSystem=$false;IsActive=$false;Secret=$secret})
            OS=[pscustomobject]@{SystemDrive='C:';Caption='Windows 10 Pro';Version='10.0.19045';BuildNumber='19045';OSArchitecture='64-bit';ProductType=1;ProductKey=$secret;SerialNumber=$secret}
            Power=[pscustomobject]@{FastStartup=0;Hibernation=0;Errors=@();Secret=$secret}
            Encryption=[pscustomobject]@{Volumes=@([pscustomobject]@{MountPoint='C:';ProtectionStatus=0;ConversionStatus=0;EncryptionPercentage=0;EncryptionMethod=0;LockStatus=0;QueryComplete=$true;RecoveryPassword=$secret;KeyProtector=$secret;TpmOwnerAuth=$secret});Errors=@();Secret=$secret}
        }
    } $secret
}
$raw=[pscustomobject]@{SchemaVersion=1;State='verified';Size=1048576;Sha256=('a'*64);Metadata=[pscustomobject]@{AcquisitionMode='offline-block';FullSectorImage=$true;SourceWriteProtected=$true;Source=[pscustomobject]@{SerialNumber='FIXTURE-SERIAL';UniqueId='linux-by-id-fixture';Size=1048576;LogicalSectorSize=512}}}
function New-Evidence($inventory) {
    [pscustomobject]@{SchemaVersion=1;Operator='fixture operator';RecordedUtc=[DateTime]::UtcNow.ToString('o');SourceImageSha256=('a'*64);SerialNumber='FIXTURE-SERIAL';Size=1048576;FullShutdownVerified=$true;FastStartupNotUsed=$true;NotHibernated=$true;AllApplicationDataOnSourceDisk=$true;NoExternalStorageDependencies=$true;TpmDependencyAbsent=$true;IdentityChangeAccepted=$true}
}
function Inspect-Current {
    $inventory=Get-WindowsRecoveryInventory
    $evidence=New-Evidence $inventory
    $assessment=Test-WindowsRecoverySuitability -Inventory $inventory -RawManifest $raw -Evidence $evidence
    [pscustomobject]@{Inventory=$inventory;Evidence=$evidence;Assessment=$assessment}
}
try {
    Reset-Fixture
    $r=Inspect-Current
    Assert-True $r.Inventory.SnapshotComplete 'provider fixtures produce complete inventory'
    Assert-True $r.Assessment.BackupPreservationSupported 'verified offline full-sector manifest is preservable'
    Assert-True $r.Assessment.RecoveryProfileAllowed ('Windows10 complete inventory accepted: '+($r.Assessment.Reasons -join ','))
    Assert-True (-not (($r|ConvertTo-Json -Depth 20).Contains($secret))) 'provider secret fields never reach inventory or assessment JSON'
    Assert-True (-not $r.Inventory.Encryption.RecoveryKeysCollected -and -not $r.Inventory.Encryption.ProtectorIdentifiersCollected -and -not $r.Inventory.Tpm.KeyMaterialCollected) 'no keys or protector identifiers collected'
    Assert-True (-not $r.Inventory.ShutdownConfirmed -and $r.Inventory.Power.ShutdownState -eq 'Unknown') 'live inventory does not claim later clean shutdown'
    $profile=New-WindowsRecoveryVmProfile -Inventory $r.Inventory -RawManifest $raw -Evidence $r.Evidence
    Assert-True (Test-RecoveryVmProfile $profile).Allowed 'generated Windows profile accepted by isolated Hyper-V profile validator'
    Assert-True ($profile.Generation -eq 2 -and $profile.SecureBoot -eq 'On') 'UEFI and secure boot retained in profile'
    Assert-True (-not $profile.BootTested -and -not $profile.RestoreTested -and -not $profile.LicenseValidated) 'generated profile makes no guest recovery claim'
    Assert-True (-not (($profile|ConvertTo-Json -Depth 12).Contains($secret))) 'profile JSON excludes provider secrets'
    foreach($component in @('Disks','Physical','Partitions','OS','Firmware','SecureBoot','Power','Encryption')) {
        Reset-Fixture;& $im {param($c)$script:F.Fail=$c} $component
        $r=Inspect-Current
        Assert-True (-not $r.Inventory.SnapshotComplete) "$component query failure remains incomplete"
        Assert-True (-not $r.Assessment.RecoveryProfileAllowed) "$component unknown fails closed across modules"
        Assert-True (-not (($r|ConvertTo-Json -Depth 20).Contains($secret))) "$component exception message does not leak secret"
    }
    Reset-Fixture
    & $im {$script:F.OS.Caption='Windows 11 Pro';$script:F.OS.Version='10.0.22631';$script:F.OS.BuildNumber='22631'}
    $r=Inspect-Current
    Assert-True $r.Inventory.SnapshotComplete 'Windows11 inventory can be complete'
    Assert-True ($r.Assessment.BackupPreservationSupported -and -not $r.Assessment.RecoveryProfileAllowed) 'Windows11 byte preservation distinct from unsupported VM path'
    Assert-True ('WINDOWS11_VTPM_NOT_IMPLEMENTED' -in $r.Assessment.Reasons) 'Windows11 blocker explicit'
    Assert-Throws {New-WindowsRecoveryVmProfile -Inventory $r.Inventory -RawManifest $raw -Evidence $r.Evidence} 'Windows11 profile creation refused'
    Reset-Fixture
    & $im {$v=$script:F.Encryption.Volumes[0];$v.ProtectionStatus=1;$v.ConversionStatus=1;$v.EncryptionPercentage=100;$v.EncryptionMethod=6}
    $r=Inspect-Current
    Assert-True $r.Inventory.SnapshotComplete 'known BitLocker state is not misreported as query failure'
    Assert-True ($r.Inventory.Encryption.Volumes[0].ConversionStatus -eq 'FullyEncrypted') 'provider numeric encryption state maps to plan string schema'
    Assert-True ($r.Assessment.BackupPreservationSupported -and -not $r.Assessment.RecoveryProfileAllowed) 'encrypted byte preservation does not imply unlocked VM recovery'
    Assert-Throws {New-WindowsRecoveryVmProfile -Inventory $r.Inventory -RawManifest $raw -Evidence $r.Evidence} 'BitLocker profile creation refused'
    Reset-Fixture
    & $im {$script:F.Encryption.Volumes[0].QueryComplete=$false}
    $r=Inspect-Current
    Assert-True (-not $r.Assessment.RecoveryProfileAllowed) 'partial encryption state refused'
    Reset-Fixture
    & $im {$script:F.Encryption.Volumes[0].MountPoint='D:'}
    $r=Inspect-Current
    Assert-True (-not $r.Assessment.RecoveryProfileAllowed) 'OS volume encryption coverage required'
    Reset-Fixture
    & $im {$script:F.Power.FastStartup=$null}
    $r=Inspect-Current
    Assert-True (-not $r.Assessment.RecoveryProfileAllowed) 'unknown fast startup state does not pass'
    Reset-Fixture
    & $im {$script:F.Disks[0].BusType='RAID'}
    $r=Inspect-Current
    Assert-True (-not $r.Assessment.RecoveryProfileAllowed) 'unvalidated RAID topology refused'
    Reset-Fixture
    $r=Inspect-Current
    foreach($flag in @('FullShutdownVerified','FastStartupNotUsed','NotHibernated','AllApplicationDataOnSourceDisk','NoExternalStorageDependencies','TpmDependencyAbsent','IdentityChangeAccepted')) {
        $e=New-Evidence $r.Inventory;$e.$flag='true'
        $a=Test-WindowsRecoverySuitability -Inventory $r.Inventory -RawManifest $raw -Evidence $e
        Assert-True (-not $a.RecoveryProfileAllowed) "string true is not operator attestation $flag"
    }
    $e=New-Evidence $r.Inventory;$e.SourceImageSha256=('b'*64)
    Assert-True (-not (Test-WindowsRecoverySuitability -Inventory $r.Inventory -RawManifest $raw -Evidence $e).RecoveryProfileAllowed) 'attestation bound to different image rejected'
    $e=New-Evidence $r.Inventory;$e.RecordedUtc='2000-01-01T00:00:00Z'
    Assert-True (-not (Test-WindowsRecoverySuitability -Inventory $r.Inventory -RawManifest $raw -Evidence $e).RecoveryProfileAllowed) 'attestation older than inventory rejected'
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxWindowsIntegration_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp|Out-Null
    try {
        Reset-Fixture;$r=Inspect-Current
        $ip=Join-Path $temp 'inventory.json';$mp=Join-Path $temp 'raw.json';$ep=Join-Path $temp 'evidence.json'
        [IO.File]::WriteAllText($ip,($r.Inventory|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($mp,($raw|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($ep,($r.Evidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $cli=Join-Path $dir 'windows-recovery.ps1'
        function Invoke-TestCli([string]$Action,[string]$Output) {
            $ErrorActionPreference='Continue'
            $text=(& powershell -NoProfile -File $cli -Action $Action -InventoryPath $ip -RawManifestPath $mp -EvidencePath $ep -OutputPath $Output 2>&1|Out-String)
            [pscustomobject]@{Code=$LASTEXITCODE;Text=$text}
        }
        $assess=Join-Path $temp 'assessment.json';$profileOut=Join-Path $temp 'profile.json'
        $result=Invoke-TestCli Assess $assess
        Assert-True ($result.Code -eq 0) 'CLI Assess reads fixture JSON without host queries'
        $a=Get-Content -LiteralPath $assess -Raw|ConvertFrom-Json
        Assert-True $a.RecoveryProfileAllowed 'CLI assessment schema agrees with module output'
        $result=Invoke-TestCli Profile $profileOut
        Assert-True ($result.Code -eq 0) 'CLI Profile creates new profile JSON'
        $profile=Get-Content -LiteralPath $profileOut -Raw|ConvertFrom-Json
        Assert-True (Test-RecoveryVmProfile $profile).Allowed 'CLI profile accepted by Hyper-V schema validator'
        $oldHash=(Get-FileHash -LiteralPath $profileOut).Hash
        $result=Invoke-TestCli Profile $profileOut
        Assert-True ($result.Code -ne 0) 'CLI existing output refuses replacement'
        Assert-True ((Get-FileHash -LiteralPath $profileOut).Hash -eq $oldHash) 'existing output stays byte-for-byte unchanged'
        [IO.File]::WriteAllText($ip,('{"Private":"'+$secret+'",INVALID_JSON'))
        $invalidOut=Join-Path $temp 'invalid-result.json'
        $result=Invoke-TestCli Assess $invalidOut
        Assert-True ($result.Code -ne 0) 'CLI invalid JSON fails'
        Assert-True (-not $result.Text.Contains($secret)) 'CLI parser failure stderr excludes secret input'
        Assert-True ($result.Text.Contains('WINDOWS_RECOVERY_ACTION_FAILED')) 'CLI parser failure provides fixed status code'
        Assert-True (([IO.FileInfo]$invalidOut).Length -eq 0) 'reserved invalid output is empty, not success JSON'
        Assert-True (-not ([IO.File]::ReadAllText($profileOut).Contains($secret))) 'CLI generated profile excludes secrets'
    } finally {
        $resolved=[IO.Path]::GetFullPath($temp);$root=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxWindowsIntegration_[0-9a-f]{32}$'){throw 'Unsafe test cleanup path'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Write-Host ("PASS: {0} Windows inventory/plan/profile integration assertions; fixtures only" -f $script:Count)
} finally {Remove-Module $im,$pm,$hm -Force}
