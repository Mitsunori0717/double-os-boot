#requires -Version 5.1
[CmdletBinding()]
param([switch]$PathOnly)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'startup-cover.cs'
$hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0,16).ToLowerInvariant()
$dir=Join-Path $PSScriptRoot 'startup-cover'
$exe=Join-Path $dir ("EdgeBox-StartupCover-$hash.exe")
if (-not $PathOnly -and -not (Test-Path -LiteralPath $exe)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $temp=Join-Path $dir ([guid]::NewGuid().ToString('N')+'.exe')
    try {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText($source,[Text.Encoding]::UTF8)) -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $temp -OutputType WindowsApplication
        Move-Item -LiteralPath $temp -Destination $exe -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
$exe
