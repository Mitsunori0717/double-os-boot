#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('All','02','05','06','09','10','11','12','13')][string]$Step = 'All',
    [switch]$Status,
    [switch]$NoConfirm,
    [switch]$RestartIfNeeded,
    [switch]$Resume,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'
if (-not $Status -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Step '+$Step
        foreach ($flag in @('NoConfirm','RestartIfNeeded','Resume','NoPause')) { if ($PSBoundParameters[$flag]) { $arguments+=' -'+$flag } }
        $p=Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $p.ExitCode
    } catch {
        Write-Host ('管理者として起動できません: '+$_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
try {
    Import-Module (Join-Path $PSScriptRoot 'setup-engine.psm1') -Force
    $code = Invoke-EdgeBoxSetup @PSBoundParameters
} catch {
    Write-Host ('セットアップを開始できません: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'setup フォルダを含む一式を同じ場所へ展開し、setup-all.cmd を再実行してください。'
    $code = 1
}
if (-not $Status -and -not $Resume -and -not $NoPause) { [void](Read-Host 'Enter キーで閉じます') }
exit $code
