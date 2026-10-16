#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Request)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$OutputEncoding=[Console]::OutputEncoding
try {
    $data=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Request)) | ConvertFrom-Json
    $parameters=@{}
    foreach($p in $data.Parameters.PSObject.Properties){$parameters[$p.Name]=$p.Value}
    $global:LASTEXITCODE=0
    & ([string]$data.Script) @parameters
    $ok=$?
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $ok) { exit 1 }
    exit $LASTEXITCODE
} catch {
    Write-Output ($_ | Out-String)
    exit 1
}
