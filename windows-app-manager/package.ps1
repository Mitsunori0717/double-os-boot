#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(-not [IO.Path]::IsPathRooted($OutputPath) -or [IO.Path]::GetExtension($OutputPath) -ine '.zip'){throw 'NEW_ABSOLUTE_ZIP_PATH_REQUIRED'}
$full=[IO.Path]::GetFullPath($OutputPath)
if($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')){throw 'LOCAL_ZIP_PATH_REQUIRED'}
$parent=[IO.Path]::GetDirectoryName($full)
while($parent){if(([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'REPARSE_OUTPUT_REFUSED'};$parent=[IO.Path]::GetDirectoryName($parent)}
$files=@('PurposeCatalog.psm1','NetworkSnapshot.psm1','NetworkView.psm1','AppInventory.psm1','SafeUninstall.psm1','AppManager.psm1','start.ps1','start.cmd','start-demo.cmd','README.md','VALIDATION.md')
foreach($name in $files){if(-not [IO.File]::Exists((Join-Path $PSScriptRoot $name))){throw 'PACKAGE_SOURCE_MISSING'}}
$stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{foreach($name in $files){[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $PSScriptRoot $name),('windows-app-manager/'+$name))|Out-Null}}finally{$zip.Dispose()}
    $stream.Flush($true)
}finally{$stream.Dispose()}
Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath
