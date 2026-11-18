#requires -Version 5.1
<#
.SYNOPSIS
    Edge Box の配布ファイルを全検証して配置し、一括セットアップへ引き継ぎます。
.DESCRIPTION
    payload.zip と package-safety.psm1 が必要です。端末設定・ログは同梱も上書きもしません。
    UAC の拒否、検証・配置・起動失敗は非ゼロ終了します。セットアップの終了コードを保持します。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\EdgeBox',
    [string]$PayloadPath = '',
    [switch]$NoPause
)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'package-safety.psm1') -Force
    if (-not $PayloadPath) {$PayloadPath=Join-Path $PSScriptRoot 'payload.zip'}
    $code=Invoke-EdgeBoxInstall -InstallerPath $PSCommandPath -PayloadPath $PayloadPath -InstallDir $InstallDir -NoPause:$NoPause
    exit $code
} catch {
    Write-Warning ('Edge Box の配置に失敗しました: '+$_.Exception.Message)
    exit 1
}
