#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'StorageRecovery.psm1') -Force
$script:Count = 0
function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw "TEST FAILED: $Message" }
    $script:Count++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}
function New-Fixture {
    [pscustomobject]@{
        Host = 'FIXTURE-HOST'; VmInventoryComplete = $true
        Disks = @(
            [pscustomobject]@{Number=0;UniqueId='SOURCE-ID';SerialNumber='SOURCE-SERIAL';Size=[uint64]8192;LogicalSectorSize=512;IsOffline=$true;IsBoot=$false;IsSystem=$false;IsReadOnly=$false},
            [pscustomobject]@{Number=1;UniqueId='DEST-ID';SerialNumber='DEST-SERIAL';Size=[uint64]17179869184;LogicalSectorSize=512;IsOffline=$false;IsBoot=$false;IsSystem=$false;IsReadOnly=$false}
        )
        VirtualMachines = @([pscustomobject]@{Name='EdgeBox';State='Off';Disks=@([pscustomobject]@{DiskNumber=0;Path=$null})})
    }
}
$source = [pscustomobject]@{UniqueId='SOURCE-ID';SerialNumber='SOURCE-SERIAL';Size=[uint64]8192;LogicalSectorSize=512}
function Get-Plan($Inventory, $Fingerprint=$source, [int]$Destination=1, [uint64]$Free=10737418240) {
    Test-RecoveryPlan -Inventory $Inventory -Source $Fingerprint -DestinationDiskNumber $Destination -FreeBytes $Free
}
function Assert-Denied($Plan, [string]$Message) {
    Assert-True (-not $Plan.Allowed) $Message
    Assert-True (@($Plan.Reasons).Count -gt 0) "$Message must explain why"
}
$baseline = Get-Plan (New-Fixture)
Assert-True $baseline.Allowed 'offline identified source with stopped VM is a valid PLAN, not permission to copy'
Assert-True ($baseline.RequiredBytes -ge $source.Size) 'required capacity must cover source bytes'
Assert-True (-not $baseline.PhysicalAcquisitionEnabled) 'successful plan cannot enable physical acquisition'
foreach ($state in @('Running','Paused','Saved','Starting','Stopping','Unknown','')) {
    $f=New-Fixture; $f.VirtualMachines[0].State=$state
    Assert-Denied (Get-Plan $f) "VM state $state must fail closed"
}
$f=New-Fixture; $f.VmInventoryComplete=$false
Assert-Denied (Get-Plan $f) 'incomplete VM inventory'
$f=New-Fixture; $f.Disks[0].IsOffline=$false
Assert-Denied (Get-Plan $f) 'online source'
foreach ($property in @('IsBoot','IsSystem')) {
    $f=New-Fixture; $f.Disks[0].$property=$true
    Assert-Denied (Get-Plan $f) "protected source $property"
}
Assert-Denied (Get-Plan (New-Fixture) $source 0) 'same source and destination disk'
Assert-Denied (Get-Plan (New-Fixture) $source 1 8191) 'insufficient destination capacity'
Assert-Denied (Get-Plan (New-Fixture) $source 99) 'missing destination disk'
$f=New-Fixture; $f.Disks[0].UniqueId='CHANGED'
Assert-Denied (Get-Plan $f) 'changed unique ID'
$f=New-Fixture; $f.Disks[0].SerialNumber='CHANGED'
Assert-Denied (Get-Plan $f) 'changed serial number'
$f=New-Fixture; $f.Disks[0].Size=16384
Assert-Denied (Get-Plan $f) 'changed actual size'
$f=New-Fixture; $f.Disks[0].LogicalSectorSize=4096
Assert-Denied (Get-Plan $f) 'changed logical sector size'
$f=New-Fixture; $f.Disks += $f.Disks[0].PSObject.Copy()
Assert-Denied (Get-Plan $f) 'ambiguous source identity'
foreach ($property in @('UniqueId','SerialNumber')) {
    $s=$source.PSObject.Copy(); $s.$property=''
    Assert-Denied (Get-Plan (New-Fixture) $s) "empty identity $property"
}

$f=New-Fixture; $f.PSObject.Properties.Remove('VirtualMachines')
Assert-Denied (Get-Plan $f) 'missing VM collection cannot mean no VMs'
$f=New-Fixture; $f.VirtualMachines=$null
Assert-Denied (Get-Plan $f) 'null VM collection cannot mean no VMs'
$f=New-Fixture; $f.VirtualMachines[0].Disks=@([pscustomobject]@{DiskNumber=$null;Path=$null})
Assert-Denied (Get-Plan $f) 'unknown drive mapping cannot be ignored'
$f=New-Fixture; $f.Disks[1].IsOffline=$true
Assert-Denied (Get-Plan $f) 'offline destination cannot store an image'
$f=New-Fixture; $f.Disks[1].IsReadOnly=$true
Assert-Denied (Get-Plan $f) 'read-only destination'
$f=New-Fixture; $f.Disks[1].SerialNumber=''
Assert-Denied (Get-Plan $f) 'unidentified destination'
$f=New-Fixture; $f.Disks[0].PSObject.Properties.Remove('IsBoot')
Assert-Denied (Get-Plan $f) 'missing source state'
# All I/O below is synthetic, ordinary files under a unique temporary directory.
# No physical disk, VM, network, scheduled task, service or reboot commands are called.
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxStorageTests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $bytes=New-Object byte[] 8192
    for($i=0;$i -lt $bytes.Length;$i++) { $bytes[$i]=[byte]($i % 251) }
    $path=Join-Path $temp 'fixture.img'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Write-ImageFromStream -Stream $stream -Size $bytes.Length -ImagePath $path -ManifestMetadata @{Source=$source;Inventory=(New-Fixture)} | Out-Null } finally { $stream.Dispose() }
    Assert-True ([IO.File]::Exists($path)) 'image finalized'
    Assert-True (([IO.FileInfo]$path).Length -eq 8192) 'exact image size'
    $v=Test-RecoveryImage -ImagePath $path
    Assert-True $v.Verified 'full image verification succeeds'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size $bytes.Length -ImagePath $path -ManifestMetadata @{Source=$source} } 'existing image cannot be overwritten' } finally { $stream.Dispose() }
    $long=Join-Path $temp 'long.img'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 1 -ImagePath $long -ManifestMetadata @{Source=$source} } 'longer stream than declared rejected' } finally { $stream.Dispose() }
    Assert-True (-not [IO.File]::Exists($long)) 'overlong input not finalized'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 0 -ImagePath (Join-Path $temp 'zero.img') -ManifestMetadata @{Source=$source} } 'zero-size source rejected' } finally { $stream.Dispose() }
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath '\\.\PhysicalDrive0' -ManifestMetadata @{Source=$source} } 'physical device output path rejected before any write' } finally { $stream.Dispose() }
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath (Join-Path $temp 'file.img:stream') -ManifestMetadata @{Source=$source} } 'alternate data stream output rejected' } finally { $stream.Dispose() }
    foreach($name in @('NUL','NUL.img','CON','PRN.txt','AUX','COM1.img','LPT1.img','trailing.','trailing ')) {
        $stream=[IO.MemoryStream]::new($bytes,$false)
        try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath (Join-Path $temp $name) -ManifestMetadata @{Source=$source} } "reserved/ambiguous filename $name rejected" } finally { $stream.Dispose() }
    }
    $mismatch=Join-Path $temp 'mismatch.img'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath $mismatch -ManifestMetadata @{Source=$source} -ExpectedSha256 ('0'*64) } 'expected source digest mismatch rejected' } finally { $stream.Dispose() }
    Assert-True (-not [IO.File]::Exists($mismatch)) 'digest mismatch cannot publish image'
    Assert-True (-not [IO.File]::Exists($mismatch+'.manifest.json')) 'digest mismatch cannot publish verified manifest'
    $stream=[IO.MemoryStream]::new($bytes,$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath (Join-Path $temp 'invalidhash.img') -ManifestMetadata @{Source=$source} -ExpectedSha256 'invalid' } 'invalid expected hash rejected' } finally { $stream.Dispose() }
    $short=Join-Path $temp 'short.img'
    $stream=[IO.MemoryStream]::new([byte[]](1,2,3),$false)
    try { Assert-Throws { Write-ImageFromStream -Stream $stream -Size 8192 -ImagePath $short -ManifestMetadata @{Source=$source} } 'short read cannot succeed' } finally { $stream.Dispose() }
    Assert-True (-not [IO.File]::Exists($short)) 'short image is not finalized'
    $target=[pscustomobject]@{Number=3;UniqueId='RESTORE-ID';SerialNumber='RESTORE-SERIAL';Size=[uint64]16384;LogicalSectorSize=512;IsOffline=$true;IsBoot=$false;IsSystem=$false;IsReadOnly=$false}
    $restoreInventory=[pscustomobject]@{VmInventoryComplete=$true;VirtualMachines=@();Disks=@($target,[pscustomobject]@{Number=1;UniqueId="STORE";SerialNumber="STORE-SERIAL";Size=[uint64]1GB;LogicalSectorSize=512;IsOffline=$false;IsReadOnly=$false;IsBoot=$false;IsSystem=$false})}
    $rp=New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $target -SourceFingerprint $source
    Assert-True $rp.Allowed 'valid restore plan only'
    $unknownTarget=$target.PSObject.Copy();$unknownTarget.Number=99
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $unknownTarget -SourceFingerprint $source) 'nonexistent target denied'
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 99 -ImagePath $path -TargetDisk $target -SourceFingerprint $source) 'nonexistent image disk denied'
    Assert-Denied (New-RestorePlan -ImagePath $path -TargetDisk $target -SourceFingerprint $source) 'restore plan without image disk or VM inventory rejected'
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 3 -ImagePath $path -TargetDisk $target -SourceFingerprint $source) 'image hosting disk cannot be restore target'
    $attached=[pscustomobject]@{VmInventoryComplete=$true;VirtualMachines=@([pscustomobject]@{Name='OtherVM';State='Off';Disks=@([pscustomobject]@{DiskNumber=3;Path=$null})})}
    Assert-Denied (New-RestorePlan -Inventory $attached -ImageDiskNumber 1 -ImagePath $path -TargetDisk $target -SourceFingerprint $source) 'restore target attached even to stopped VM is protected'
    Assert-True (-not $rp.PhysicalWriteEnabled) 'successful restore plan cannot enable device writes'
    Assert-True (-not $rp.RestoreTested) 'plan must not claim restore tested'
    foreach($property in @('IsBoot','IsSystem','IsReadOnly')) {
        $t=$target.PSObject.Copy();$t.$property=$true
        Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) "protected restore target $property"
    }
    $t=$target.PSObject.Copy();$t.IsOffline=$false
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'online restore target'
    $t=$target.PSObject.Copy();$t.Size=4096
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'small restore target'
    $t=$target.PSObject.Copy();$t.LogicalSectorSize=4096
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'sector mismatch'
    $t=$target.PSObject.Copy();$t.UniqueId=$source.UniqueId;$t.SerialNumber=$source.SerialNumber
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'original source cannot be restore target'
    $t=$target.PSObject.Copy();$t.UniqueId=''
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'unidentified restore target'
    $t=$target.PSObject.Copy();$t.SerialNumber=$source.SerialNumber
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'serial collision must protect original source'
    $s=$source.PSObject.Copy();$s.UniqueId='FORGED'
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $target -SourceFingerprint $s) 'source fingerprint must match manifest metadata'
    $t=$target.PSObject.Copy();$t.PSObject.Properties.Remove('IsOffline')
    Assert-Denied (New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $t -SourceFingerprint $source) 'missing target state must fail closed'
    $manifestPath=$path+'.manifest.json'
    $manifestOriginal=[IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath,'{invalid')
    Assert-Throws { Test-RecoveryImage -ImagePath $path } 'invalid manifest JSON rejected'
    [IO.File]::WriteAllText($manifestPath,$manifestOriginal)
    Assert-True (Test-RecoveryImage -ImagePath $path).Verified 'original manifest still validates unchanged image'
    # Tampering must invalidate a previously valid image.
    $bytes[0]=42;[IO.File]::WriteAllBytes($path,$bytes)
    Assert-Throws { Test-RecoveryImage -ImagePath $path } 'tampered image rejected'
    Assert-Throws { New-RestorePlan -Inventory $restoreInventory -ImageDiskNumber 1 -ImagePath $path -TargetDisk $target -SourceFingerprint $source } 'tampered image cannot yield restore plan'
    Assert-Throws { Test-RecoveryImage -ImagePath (Join-Path $temp 'missing.img') } 'missing image rejected'
    $iso=Join-Path $temp 'fixture.iso'
    [IO.File]::WriteAllBytes($iso,[byte[]](1,2,3,4))
    $isoHash=(Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    $media=Test-RecoveryMediaHash -IsoPath $iso -ExpectedSha256 $isoHash
    Assert-True $media.HashMatches 'ISO hash matches fixture'
    Assert-True (-not $media.AuthenticityVerified -and -not $media.BootTested) 'hash does not imply authentic media or boot test'
    Assert-Throws { Test-RecoveryMediaHash -IsoPath $iso -ExpectedSha256 ('0'*64) } 'wrong ISO digest rejected'
    Assert-Throws { Test-RecoveryMediaHash -IsoPath $iso -ExpectedSha256 'invalid' } 'invalid expected ISO digest rejected'
    Assert-Throws { Test-RecoveryMediaHash -IsoPath $path -ExpectedSha256 $isoHash } 'non-ISO media rejected'
    Write-Host ("PASS: {0} storage-recovery assertions (synthetic files only)" -f $script:Count)
} finally {
    # Fixed, unique directory created above. Never derives cleanup from image metadata.
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxStorageTests_[0-9a-f]{32}$') { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
