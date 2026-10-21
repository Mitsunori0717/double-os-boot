#requires -Version 5.1
# 文字列として UI のソースを扱う。デザインファイルを実行しない。
function Get-PreviewHash([string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n")
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Resolve-PreviewPath([string]$Root, [string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) { throw '対応表には相対パスが必要です。' }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "フォルダ外のパスは使えません: $RelativePath" }
    return $path
}

function Get-PreviewRegion([string]$Text, $Entry) {
    if (-not $Entry.startMarker -and -not $Entry.endMarker) { return [pscustomobject]@{ Start = 0; Length = $Text.Length; Text = $Text } }
    if (-not $Entry.startMarker -or -not $Entry.endMarker) { throw '開始・終了マーカーは両方必要です。' }
    $startMarker = ([string]$Entry.startMarker).Replace("`r`n", "`n")
    $endMarker = ([string]$Entry.endMarker).Replace("`r`n", "`n")
    $first = $Text.IndexOf($startMarker, [StringComparison]::Ordinal)
    if ($first -lt 0 -or $Text.IndexOf($startMarker, $first + $startMarker.Length, [StringComparison]::Ordinal) -ge 0) { throw "開始マーカーが一意に見つかりません: $($Entry.designFile)" }
    $start = $first + $startMarker.Length
    $end = $Text.IndexOf($endMarker, [StringComparison]::Ordinal)
    if ($end -lt $start -or $Text.IndexOf($endMarker, $end + $endMarker.Length, [StringComparison]::Ordinal) -ge 0) { throw "終了マーカーが一意に見つかりません: $($Entry.designFile)" }
    return [pscustomobject]@{ Start = $start; Length = $end - $start; Text = $Text.Substring($start, $end - $start) }
}

function Get-PreviewIntegrationPlan([string]$PreviewRoot, [string]$TargetRoot) {
    $allowed = @(
        'windows-cpu-partition/cpu-ui-theme.ps1',
        'windows-cpu-partition/cpu-console.ps1',
        'windows-cpu-partition/cpu-monitor.ps1',
        'windows-host/03-field-display-kiosk.ps1',
        'windows-host/06-auto-logon.ps1',
        'windows-host/08-settings-console.ps1'
    )
    $entries = @()
    foreach ($group in @('cpu', 'host')) {
        $manifest = Get-Content -LiteralPath (Join-Path $PreviewRoot "$group/manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries += @($manifest.entries)
    }
    if ($entries.Count -eq 0) { throw 'デザインの対応表が空です。' }
    $files = [ordered]@{}
    $seenDesign = @{}
    foreach ($entry in $entries) {
        $relative = ([string]$entry.targetFile).Replace('\', '/')
        if ($relative -notin $allowed) { throw "取り込み対象外のファイルです: $relative" }
        if ($seenDesign.ContainsKey([string]$entry.designFile)) { throw "デザインの対応が重複しています: $($entry.designFile)" }
        $seenDesign[[string]$entry.designFile] = $true
        if ([string]$entry.baselineHash -notmatch '^[0-9a-fA-F]{64}$') { throw "基準ハッシュが不正です: $($entry.designFile)" }
        $designPath = Resolve-PreviewPath $PreviewRoot ([string]$entry.designFile)
        $targetPath = Resolve-PreviewPath $TargetRoot $relative
        if (-not $files.Contains($relative)) {
            $rawSource = [IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8)
            $source = $rawSource.Replace("`r`n", "`n")
            $files[$relative] = [pscustomobject]@{ Path = $targetPath; Original = $source; CrLf = $rawSource.Contains("`r`n"); Replacements = @() }
        }
        $file = $files[$relative]
        $region = Get-PreviewRegion $file.Original $entry
        $design = [IO.File]::ReadAllText($designPath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
        $currentHash = Get-PreviewHash $region.Text
        $designHash = Get-PreviewHash $design
        if ($currentHash -ne $entry.baselineHash -and $currentHash -ne $designHash) {
            throw "本体の UI が基準から変更されています。最新版と比較してから手動で調整してください: $relative ($($entry.designFile))"
        }
        foreach ($other in $file.Replacements) {
            if ($region.Start -lt ($other.Start + $other.Length) -and $other.Start -lt ($region.Start + $region.Length)) { throw "取り込み範囲が重複しています: $relative" }
        }
        $file.Replacements += [pscustomobject]@{ Start = $region.Start; Length = $region.Length; Text = $design }
    }
    $result = @()
    foreach ($relative in $files.Keys) {
        $file = $files[$relative]
        $content = $file.Original
        foreach ($r in @($file.Replacements | Sort-Object Start -Descending)) {
            $content = $content.Remove($r.Start, $r.Length).Insert($r.Start, $r.Text)
        }
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "取り込み後の PowerShell 構文にエラーがあります: $relative : $($errors[0].Message)" }
        $result += [pscustomobject]@{
            Path = $file.Path; RelativePath = $relative
            Content = $(if ($file.CrLf) { $content.Replace("`n", "`r`n") } else { $content })
            OriginalHash = (Get-PreviewHash $file.Original)
            Changed = ($content -cne $file.Original)
        }
    }
    return $result
}
