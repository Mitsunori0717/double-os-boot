#requires -Version 5.1
<#
.SYNOPSIS
    プレビューのデザインを Git クローン側のソースへ取り込みます。
.DESCRIPTION
    既定では変更予定だけ表示します。-Apply でソースを書き換えます。
    スクリプトは実行せず、対応表で指定した UI 部分だけを置き換えます。
    対象の UI がプレビュー作成時から変わっていれば、上書きせず停止します。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$TargetRoot,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'integration-lib.ps1')

$target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath (Join-Path $target '.git'))) {
    throw '取り込み先には Git クローンのルートを指定してください。ZIP 配置の実稼働フォルダには直接取り込みません。'
}
$gitRoot = & git -C $target rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath([string]$gitRoot).TrimEnd('\', '/') -ne $target) {
    throw '取り込み先には有効な Git 作業フォルダのルートを指定してください。'
}
$plan = @(Get-PreviewIntegrationPlan -PreviewRoot $PSScriptRoot -TargetRoot $target)
foreach ($item in $plan) {
    Write-Host ('{0}: {1}' -f $(if ($item.Changed) { '変更予定' } else { '一致' }), $item.RelativePath)
}
$changes = @($plan | Where-Object Changed)
if (-not $Apply) {
    Write-Host ('変更対象: {0} ファイル。取り込むには同じコマンドに -Apply を付けてください。' -f $changes.Count)
    return
}
# 全対象の構文・競合確認を終えてから書き込む。実機の設定処理は呼び出さない。
foreach ($item in $changes) {
    if ((Get-PreviewHash ([IO.File]::ReadAllText($item.Path, [Text.Encoding]::UTF8))) -ne $item.OriginalHash) {
        throw "取り込み確認中にソースが変更されました。再確認してください: $($item.RelativePath)"
    }
}
foreach ($item in $changes) {
    if ($PSCmdlet.ShouldProcess($item.Path, 'デザインのソースを取り込み')) {
        if ((Get-PreviewHash ([IO.File]::ReadAllText($item.Path, [Text.Encoding]::UTF8))) -ne $item.OriginalHash) {
            throw "書き込み前にソースが変更されました。再確認してください: $($item.RelativePath)"
        }
        [IO.File]::WriteAllText($item.Path, $item.Content, (New-Object Text.UTF8Encoding($true)))
    }
}
Write-Host '取り込み後は git diff と setup\tests\run-tests.ps1 を確認してから、通常の commit / push / PR マージを行ってください。'
