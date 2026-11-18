#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'test-windows-plan.ps1')
$count=0
function Check($v,$s){if(-not $v){throw ('FAIL expanded: '+$s)};$script:count++}
function Expanded {
 $f=New-Fixture
 $f.I.OS.BuildNumber='26100';$f.I.OS.Version='10.0.26100';$f.I.Disks[0].Size=80GB;$f.I.Disks[0].BusType='NVMe';$f.M.Size=80GB;$f.M.Metadata.Source.Size=80GB
 $f.E=@{SchemaVersion=2;Operator='fixture';RecordedUtc='2026-01-01T01:00:00Z';Sources=@(@{SourceImageSha256=('a'*64);SerialNumber='SERIAL';Size=80GB;LogicalSectorSize=512;Role='Boot';ControllerLocation=0});FullShutdownVerified=$true;FastStartupNotUsed=$true;NotHibernated=$true;AllDependentDisksBackedUp=$true;AllApplicationDataIncluded=$true;BasicStorageTopologyVerified=$true;NoExternalStorageDependencies=$true;IdentityChangeAccepted=$true;AcceptNewTpmIdentity=$true;OriginalTpmSecretsRequired=$false;HostWindows11CpuSupported=$true;BitLockerVolumes=@();RecoveryKeyStoredSeparately=$false;RecoveryKeyMatchesSource=$false;AcceptManualUnlock=$false}
 $f.M.CreatedUtc='2026-01-01T00:30:00Z';$f.E.NoWritesDuringAcquisition=$true;$f.E.QuiescentStartUtc='2026-01-01T00:10:00Z';$f.E.QuiescentEndUtc='2026-01-01T00:50:00Z'
 $f.E.SourceSetComplete=$true;$f.E.SourceSetQuiescedTogether=$true
 $f.More=@();BindSet $f;return $f
}
function BindSet($f){$f.E.SourceSetSha256= & (Get-Module WindowsRecoveryPlan) {param($s) Get-WRPSourceSetHash $s} $f.E.Sources}
function Encrypt($f){
 $v=$f.I.Encryption.Volumes[0];$v.ConversionStatus='FullyEncrypted';$v.ProtectionStatus='On';$v.EncryptionPercentage=100;$v.EncryptionMethod='XtsAes256';$v.LockStatus='Locked'
 $f.E.RecoveryKeyStoredSeparately=$true;$f.E.RecoveryKeyMatchesSource=$true;$f.E.AcceptManualUnlock=$true
 $f.E.BitLockerVolumes=@(@{MountPoint='C:';SourceImageSha256=('a'*64);RecoveryKeyId='{11111111-1111-1111-1111-111111111111}';SeparateStorageVerified=$true;RecoveryKeyIdMatched=$true})
}
function AddDisk($f){
 $f.I.Disks+=@{Number=1;SerialNumber='DATA';UniqueId='WINDOWS-DATA';Size=16GB;LogicalSectorSize=512;PartitionStyle='GPT';BusType='SATA'}
 $f.I.Partitions+=@{DiskNumber=1;DriveLetter='D'}
 $f.I.Encryption.Volumes+=@{MountPoint='D:';Status='Known';ConversionStatus='FullyDecrypted';ProtectionStatus='Off';LockStatus='Unlocked';EncryptionPercentage=0;EncryptionMethod='None'}
 $f.More=@(@{SchemaVersion=1;State='verified';CreatedUtc='2026-01-01T00:40:00Z';Sha256=('b'*64);Size=16GB;Metadata=@{Source=@{SerialNumber='DATA';UniqueId='LINUX-DATA';Size=16GB;LogicalSectorSize=512};AcquisitionMode='offline-block';FullSectorImage=$true;SourceWriteProtected=$true}})
 $f.E.Sources+=@{SourceImageSha256=('b'*64);SerialNumber='DATA';Size=16GB;LogicalSectorSize=512;Role='Data';ControllerLocation=1}
 BindSet $f
}
function Assess2($f){Test-WindowsRecoverySuitability $f.I $f.M $f.E -AdditionalRawManifests $f.More}
function Profile2($f){New-WindowsRecoveryVmProfile $f.I $f.M $f.E -AdditionalRawManifests $f.More}
$f=Expanded;$a=Assess2 $f;Check $a.RecoveryProfileAllowed ($a.Reasons -join ',');$p=Profile2 $f
Check ($p.ProfileVersion -eq 2 -and $p.GuestOS -eq 'Windows11' -and $p.TpmPolicy -eq 'NewLocalProtector') 'Win11 new TPM'
Check (-not $p.OriginalTpmSecretsRecreated -and -not $p.BootTested -and -not $p.RestoreTested) 'no proof claims'
$f=Expanded;Encrypt $f;$a=Assess2 $f;Check $a.RecoveryProfileAllowed ($a.Reasons -join ',');$p=Profile2 $f
Check ($p.BitLockerState -eq 'Encrypted' -and $p.RecoveryUnlockPolicy -eq 'UserConsoleOnly') 'manual unlock'
Check (($p|ConvertTo-Json -Depth 12) -notmatch '11111111|RecoveryKeyId') 'no recovery identifier propagation'
$f=Expanded;AddDisk $f;Check (Assess2 $f).RecoveryProfileAllowed 'multi disk';$p=Profile2 $f
Check ($p.SourceDiskCount -eq 2 -and $p.Sources[1].Role -eq 'Data') 'ordered sources'
$f=Expanded;AddDisk $f;Encrypt $f;Check (Assess2 $f).RecoveryProfileAllowed 'encrypted multi'
foreach($mutation in @(
 {$f.E.OriginalTpmSecretsRequired=$true},{$f.E.OriginalTpmSecretsRequired='false'},{$f.E.AcceptNewTpmIdentity=$false},{$f.E.HostWindows11CpuSupported=$false},
 {$f.I.OS.BuildNumber='99999';$f.I.OS.Version='10.0.99999'},{$f.I.OS.Architecture='ARM64'},{$f.I.SnapshotComplete=$false},{$f.I.Errors=@('PRIVATE_SECRET_9341')},
 {$f.I.Firmware.SecureBoot.Enabled=$false},{$f.I.Firmware.Type='Bios'},{$f.I.BootDependencies.Status='Unknown'},{$f.I.BootDependencies.RequiredDiskNumbers=@(0,2)},
 {$f.I.BootDependencies.PotentialBootDiskNumbers=@(1)},{$f.I.Partitions=@()},{$f.I.Disks[0].SerialNumber='OTHER'},{$f.I.Disks[0].PartitionStyle='RAW'},
 {$f.M.State='copied'},{$f.M.Metadata.SourceWriteProtected=$false},{$f.E.Sources[0].SourceImageSha256=('c'*64)},{$f.E.Sources[0].Role='Data'},
 {$f.E.Sources[0].ControllerLocation=1},{$f.E.RecordedUtc='bad'},{$f.E.RecordedUtc='2025-01-01T00:00:00Z'},{$f.E.Operator=''},{$f.E.AllApplicationDataIncluded=$false},
 {$f.E.Password='PRIVATE_SECRET_9341'},{$f.E.Operator=('123456-'*7)+'123456'},{$f.E.Sources[0].RecoveryPassword='PRIVATE_SECRET_9341'},
 {$f.E.BitLockerVolumes=@('PRIVATE_SECRET_9341')},{$f.E.BitLockerVolumes=@(@{Password='PRIVATE_SECRET_9341'})},
 {$f.I.Encryption.Volumes[0].ConversionStatus='EncryptionInProgress'},{$f.I.Encryption.Volumes[0].EncryptionPercentage=$true},{$f.I.Encryption.Volumes[0].Status='Unknown'},{$f.I.Encryption.Volumes[0].MountPoint='Z:'},
 {$f.E.NoWritesDuringAcquisition=$false},{$f.E.QuiescentStartUtc='bad'},{$f.E.QuiescentEndUtc='2026-01-01T00:20:00Z'},{$f.M.CreatedUtc='2026-01-01T00:01:00Z'},{$f.E.SourceSetComplete=$false},{$f.E.SourceSetQuiescedTogether=$false},{$f.E.SourceSetSha256=('0'*64)},{$f.E.BasicStorageTopologyVerified=$false},{$f.I.Disks[0].BusType='RAID'},{$f.I.Disks[0].BusType='Unknown'}
)){
 $f=Expanded;& $mutation;$a=Assess2 $f;Check (-not $a.RecoveryProfileAllowed) ('refuse '+$mutation)
 Check (($a|ConvertTo-Json -Depth 12) -notmatch 'PRIVATE_SECRET_9341|123456-') 'sanitized result'
 $blocked=$false;try{Profile2 $f|Out-Null}catch{$blocked=$true;Check ($_.Exception.Message -notmatch 'PRIVATE_SECRET_9341|123456-') 'sanitized failure'};Check $blocked 'profile blocked'
}
foreach($mutation in @(
 {$f.E.BitLockerVolumes=@()},{$f.E.BitLockerVolumes[0].RecoveryKeyId=('123456-'*7)+'123456'},{$f.E.BitLockerVolumes[0].RecoveryKeyId=@('bad')},
 {$f.E.BitLockerVolumes[0].SourceImageSha256=('c'*64)},{$f.E.BitLockerVolumes[0].SeparateStorageVerified='true'},{$f.E.BitLockerVolumes[0].RecoveryKeyIdMatched=$false},
 {$f.E.RecoveryKeyStoredSeparately=$false},{$f.E.RecoveryKeyMatchesSource=$false},{$f.E.AcceptManualUnlock=$false},
 {$f.I.Encryption.Volumes[0].ConversionStatus='EncryptionPaused'},{$f.I.Encryption.Volumes[0].EncryptionPercentage=99},{$f.I.Encryption.Volumes[0].EncryptionMethod='HardwareEncryption'}
)){$f=Expanded;Encrypt $f;& $mutation;Check (-not(Assess2 $f).RecoveryProfileAllowed) ('encrypted refuse '+$mutation)}
foreach($mutation in @({$f.More=@()},{$f.E.Sources=$f.E.Sources[0]},{$f.More[0].Sha256=('a'*64)},{$f.More[0].Metadata.Source.SerialNumber='SERIAL'},{$f.E.Sources[1].Size=1024},{$f.I.Disks[1].LogicalSectorSize=4096})){$f=Expanded;AddDisk $f;& $mutation;Check (-not(Assess2 $f).RecoveryProfileAllowed) ('multi refuse '+$mutation)}
foreach($settings in @(@{MemoryStartupBytes=2GB},@{ProcessorCount=1})){$f=Expanded;$blocked=$false;try{New-WindowsRecoveryVmProfile $f.I $f.M $f.E @settings|Out-Null}catch{$blocked=$true};Check $blocked 'Win11 resource minimums'}
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'HyperVRecovery.psm1')
foreach($case in @('Clear','Encrypted','Multi')){$f=Expanded;if($case -eq 'Encrypted'){Encrypt $f};if($case -eq 'Multi'){AddDisk $f};$p=Profile2 $f;$v=Test-RecoveryVmProfile $p;Check $v.Allowed ('HyperV schema '+($v.Reasons -join ','))}

$f=Expanded
$f.I.Disks+=@{Number=9;SerialNumber='BACKUP';UniqueId='BACKUP-ID';Size=160GB;LogicalSectorSize=512;PartitionStyle='GPT';BusType='USB'}
$f.I.Partitions+=@{DiskNumber=9;DriveLetter='E'}
$f.I.Encryption.Volumes+=@{MountPoint='E:';Status='Known';EncryptionMethod='XtsAes256';EncryptionPercentage=100;ConversionStatus='FullyEncrypted';ProtectionStatus='On';LockStatus='Unlocked'}
Check (Assess2 $f).RecoveryProfileAllowed 'encrypted backup destination proven outside source set does not require its own recovery image'
$f.I.Partitions[-1].DiskNumber=0
Check (-not(Assess2 $f).RecoveryProfileAllowed) 'encrypted volume on source set still requires recovery evidence'
$f=Expanded;$f.I.Partitions+=@{DiskNumber=0;DriveLetter='D'}
$a=Assess2 $f
Check (-not $a.RecoveryProfileAllowed -and $a.Reasons -contains 'DEPENDENT_VOLUME_ENCRYPTION_COVERAGE_UNPROVEN') 'missing source-volume state still rejected in v2'

# CLI reads synthetic JSON files only; never Inventory action or device APIs.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ExpandedPlanFixtures_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
 $f=Expanded;AddDisk $f;Encrypt $f
 foreach($pair in @(@('inventory',$f.I),@('boot',$f.M),@('data',$f.More[0]),@('evidence',$f.E))){$pair[1]|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $temp ($pair[0]+'.json')) -Encoding UTF8}
 $cli=Join-Path (Split-Path $PSScriptRoot -Parent) 'windows-recovery.ps1'
 $args=@{InventoryPath=(Join-Path $temp 'inventory.json');RawManifestPath=(Join-Path $temp 'boot.json');AdditionalRawManifestPaths=@((Join-Path $temp 'data.json'));EvidencePath=(Join-Path $temp 'evidence.json')}
 $out=Join-Path $temp 'profile.json'; & $cli -Action Profile @args -OutputPath $out|Out-Null
 $profile=Get-Content -LiteralPath $out -Raw|ConvertFrom-Json
 Check ($profile.ProfileVersion -eq 2 -and $profile.SourceDiskCount -eq 2 -and $profile.BitLockerState -eq 'Encrypted') 'CLI expanded profile'
 Check (Test-RecoveryVmProfile $profile).Allowed 'CLI output HyperV compatible'
 $before=[IO.File]::ReadAllText($out);$blocked=$false;try{& $cli -Action Profile @args -OutputPath $out|Out-Null}catch{$blocked=$true};Check ($blocked -and [IO.File]::ReadAllText($out) -ceq $before) 'CLI output no overwrite'
 $f.E.Password='PRIVATE_SECRET_9341';$f.E|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $args.EvidencePath -Encoding UTF8
 $bad=Join-Path $temp 'blocked.json';$blocked=$false;$capture=''
 try{$capture= & $cli -Action Profile @args -OutputPath $bad 2>&1|Out-String}catch{$blocked=$true;$capture+=$_.Exception.Message}
 Check ($blocked -and $capture -notmatch 'PRIVATE_SECRET_9341') 'CLI secret input refused without leak'
 Check ((Get-Item -LiteralPath $bad).Length -eq 0) 'CLI blocked output remains empty reservation'
}finally{
 $resolved=[IO.Path]::GetFullPath($temp);$root=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ExpandedPlanFixtures_[0-9a-f]{32}$'){throw 'UNSAFE_TEST_CLEANUP'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('PASS expanded Windows plan assertions='+$count+'; pure fixtures only')
