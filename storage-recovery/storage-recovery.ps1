#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Inventory','Verify','CopyImage','PhysicalBackup','PhysicalRestore')][string]$Action='Inventory',
    [string]$ImagePath,
    [string]$DestinationPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'StorageRecovery.psm1') -Force
try {
    switch ($Action) {
        'Inventory' { Get-RecoveryInventory | ConvertTo-Json -Depth 12 }
        'Verify' { Test-RecoveryImage -ImagePath $ImagePath | ConvertTo-Json -Depth 12 }
        'CopyImage' {
            # Only previously verified ordinary image files, never a raw device or VM disk.
            $verified=Test-RecoveryImage -ImagePath $ImagePath
            $stream=[IO.File]::Open([IO.Path]::GetFullPath($ImagePath),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try {
                $result=Write-ImageFromStream -Stream $stream -Size $verified.Size -ImagePath $DestinationPath -ManifestMetadata $verified.Metadata -ExpectedSha256 $verified.Sha256
                if($result.Sha256 -cne $verified.Sha256) { throw 'SOURCE_CHANGED_SINCE_VERIFICATION' }
                $result | ConvertTo-Json -Depth 12
            } finally { $stream.Dispose() }
        }
        default { throw 'PHYSICAL_IO_DISABLED: Physical backup/restore is not enabled. This release provides read-only inventory, preflight, verified image copying and restore planning only.' }
    }
} catch {
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}
