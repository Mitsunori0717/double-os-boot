#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$SourceRoot)
$ErrorActionPreference = 'Stop'
$previewRoot = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxUiTests_' + [guid]::NewGuid().ToString('N'))
$fixturePreview = Join-Path $fixture 'preview-copy'
$fixtureSource = Join-Path $fixture 'source-copy'
$utf8 = New-Object Text.UTF8Encoding($true)
function Assert-Preview($Condition, [string]$Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
try {
    [void][IO.Directory]::CreateDirectory($fixtureSource)
    Copy-Item -LiteralPath $previewRoot -Destination $fixturePreview -Recurse
    . (Join-Path $fixturePreview 'integration-lib.ps1')
    $entries = @()
    foreach ($name in @('cpu', 'host')) { $entries += @((Get-Content (Join-Path $fixturePreview "$name/manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json).entries) }
    foreach ($relative in @($entries.targetFile | Sort-Object -Unique)) {
        $destination = Join-Path $fixtureSource $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $destination
    }
    & git -C $fixtureSource init --quiet
    if ($LASTEXITCODE -ne 0) { throw '検証用 Git フォルダを作成できません。' }
    $initial = @(Get-PreviewIntegrationPlan $fixturePreview $fixtureSource)
    Assert-Preview (@($initial | Where-Object Changed).Count -eq 0) 'unchanged native designs must be a no-op'
    # 本体と同じデザインなら、基準ハッシュも今の本体の範囲と一致する (取り込み後に基準の更新を忘れると、次の取り込みが止まる)
    foreach ($e in $entries) {
        $text = [IO.File]::ReadAllText((Join-Path $fixtureSource $e.targetFile), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
        Assert-Preview ((Get-PreviewHash (Get-PreviewRegion $text $e).Text) -eq $e.baselineHash) "baselineHash must match the current source region: $($e.designFile)"
    }

    # 本体の機能部分だけが更新されていても、UI 部分が同じなら保持して取り込める。
    $entry = $entries | Where-Object designFile -eq 'host/views/display.view.ps1'
    $displayPath = Join-Path $fixtureSource $entry.targetFile
    $displayOriginal = [IO.File]::ReadAllText($displayPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($displayPath, ($displayOriginal + "`r`n# newer operational code must be preserved`r`n"), $utf8)
    $designPath = Join-Path $fixturePreview $entry.designFile
    $designOriginal = [IO.File]::ReadAllText($designPath, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($designPath, ($designOriginal + "`n    # design-only edit`n"), $utf8)
    $changed = @(Get-PreviewIntegrationPlan $fixturePreview $fixtureSource | Where-Object Changed)
    Assert-Preview ($changed.Count -eq 1 -and $changed[0].RelativePath -eq $entry.targetFile) 'only the mapped UI file should change'
    Assert-Preview ($changed[0].Content.Contains('newer operational code must be preserved')) 'unrelated operational changes must remain intact'
    & (Join-Path $fixturePreview 'integrate.ps1') -TargetRoot $fixtureSource -Apply -WhatIf
    Assert-Preview (-not ([IO.File]::ReadAllText($displayPath)).Contains('design-only edit')) 'WhatIf must not write source'
    & (Join-Path $fixturePreview 'integrate.ps1') -TargetRoot $fixtureSource -Apply
    Assert-Preview ([IO.File]::ReadAllText($displayPath).Contains('design-only edit')) 'Apply must copy design into native source'
    Assert-Preview (@(Get-PreviewIntegrationPlan $fixturePreview $fixtureSource | Where-Object Changed).Count -eq 0) 'integration must be repeatable without changes'

    # 同じ UI が別途変更されたら、複数ファイルのいずれにも書き込まない。
    [IO.File]::WriteAllText($displayPath, ($displayOriginal + "`n# live UI changed`n"), $utf8)
    $liveText = [IO.File]::ReadAllText($displayPath, [Text.Encoding]::UTF8).Replace('    $form = New-Object System.Windows.Forms.Form', '    $form = New-Object System.Windows.Forms.Form # independently edited')
    Assert-Preview ($liveText.Contains('# independently edited')) 'fixture must change the actual UI region'
    [IO.File]::WriteAllText($displayPath, $liveText, $utf8)
    $themePath = Join-Path $fixtureSource 'windows-cpu-partition/cpu-ui-theme.ps1'
    $themeBefore = [IO.File]::ReadAllText($themePath, [Text.Encoding]::UTF8)
    $themeDesign = Join-Path $fixturePreview 'cpu/cpu-ui-theme.ps1'
    [IO.File]::AppendAllText($themeDesign, "`n# another design-only edit`n", $utf8)
    $blocked = $false
    try { & (Join-Path $fixturePreview 'integrate.ps1') -TargetRoot $fixtureSource -Apply } catch { $blocked = $_.Exception.Message.Contains('基準から変更') }
    Assert-Preview $blocked 'stale UI must stop integration'
    Assert-Preview ([IO.File]::ReadAllText($themePath, [Text.Encoding]::UTF8) -ceq $themeBefore) 'a later conflict must not cause a partial apply'

    [IO.File]::WriteAllText($displayPath, $displayOriginal, $utf8)
    [IO.File]::WriteAllText($designPath, 'if (', $utf8)
    $blocked = $false
    try { [void](Get-PreviewIntegrationPlan $fixturePreview $fixtureSource) } catch { $blocked = $_.Exception.Message.Contains('構文') }
    Assert-Preview $blocked 'invalid design must fail before any source write'
    $blocked = $false
    try { [void](Resolve-PreviewPath $fixturePreview '..\outside.ps1') } catch { $blocked = $true }
    Assert-Preview $blocked 'manifest paths must stay inside their root'
    Write-Host 'PASS: no-op, mapped integration, behavior preservation, WhatIf, repeatability, stale UI, preflight, syntax and path checks'
} finally {
    $fullFixture = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($fullFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($fullFixture).StartsWith('EdgeBoxUiTests_')) {
        Remove-Item -LiteralPath $fullFixture -Recurse -Force
    }
}
