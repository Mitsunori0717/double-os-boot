#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Help','Inventory','Assess','Profile')][string]$Action='Help',
    [string]$InventoryPath,[string]$RawManifestPath,[string]$EvidencePath,[string]$OutputPath,
    [ValidateRange(2147483648,1099511627776)][long]$MemoryStartupBytes=4GB,
    [ValidateRange(1,256)][int]$ProcessorCount=2
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($Action -eq 'Help'){
    Write-Output 'Windows recovery: Inventory reads current Windows metadata only; Assess/Profile read JSON only. No disk copying, shutdown, key collection, VM creation or restoration. All actions require a NEW OutputPath. See GENERAL-OS-RECOVERY.md and WINDOWS-INVENTORY.md.'
    return
}
Import-Module (Join-Path $PSScriptRoot 'StorageRecovery.psm1') -Force
$storage=Get-Module StorageRecovery
function Resolve-LocalFile([string]$Path){
    if([string]::IsNullOrWhiteSpace($Path)){throw 'LOCAL_JSON_PATH_REQUIRED'}
    & $storage {param($p) Resolve-RegularImagePath $p} $Path
}
function Read-LocalJson([string]$Path){
    $p=Resolve-LocalFile $Path
    if([IO.Path]::GetExtension($p) -ine '.json'){throw 'JSON_EXTENSION_REQUIRED'}
    $s=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($s.Length -gt 16MB){throw 'JSON_INPUT_TOO_LARGE'}
        $reader=[IO.StreamReader]::new($s,[Text.Encoding]::UTF8,$true)
        try { $reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop }finally{$reader.Dispose()}
    }finally{$s.Dispose()}
}
$out=Resolve-LocalFile $OutputPath
if([IO.Path]::GetExtension($out) -ine '.json'){throw 'JSON_OUTPUT_REQUIRED'}
if(Test-Path -LiteralPath $out){throw 'OUTPUT_ALREADY_EXISTS'}
# Reserve destination BEFORE collecting current-machine metadata. Never replace any file.
$dest=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    if($Action -eq 'Inventory'){
        Import-Module (Join-Path $PSScriptRoot 'WindowsRecoveryInventory.psm1') -Force
        $result=Get-WindowsRecoveryInventory
    }else{
        $inventory=Read-LocalJson $InventoryPath
        $manifest=Read-LocalJson $RawManifestPath
        $evidence=Read-LocalJson $EvidencePath
        Import-Module (Join-Path $PSScriptRoot 'WindowsRecoveryPlan.psm1') -Force
        if($Action -eq 'Assess'){$result=Test-WindowsRecoverySuitability $inventory $manifest $evidence}
        else{$result=New-WindowsRecoveryVmProfile $inventory $manifest $evidence -MemoryStartupBytes $MemoryStartupBytes -ProcessorCount $ProcessorCount}
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 20))
    $dest.Write($bytes,0,$bytes.Length);$dest.Flush($true)
    Write-Output ('Written '+$Action+' JSON. This is not backup, restoration or OS/application boot verification.')
}catch{
    # The reserved empty/partial file is intentionally retained. Do not dump input objects or secrets.
    Write-Error ('WINDOWS_RECOVERY_ACTION_FAILED: '+$Action+'; exception type='+$_.Exception.GetType().Name+'; HResult='+$_.Exception.HResult+'; output retained (may be empty or partial).') -ErrorAction Continue
    throw 'WINDOWS_RECOVERY_ACTION_FAILED; output retained; inspect non-secret status codes.'
}finally{$dest.Dispose()}
