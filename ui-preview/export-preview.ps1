#requires -Version 5.1
[CmdletBinding()]
param([string]$OutFile = (Join-Path ([IO.Path]::GetTempPath()) 'EdgeBox-UI-Preview.zip'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$destination = [IO.Path]::GetFullPath($OutFile)
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
if ($destination.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP の出力先には ui-preview の外を指定してください。' }
if (Test-Path -LiteralPath $destination) { throw "出力先が既にあります。別のファイル名を指定してください: $destination" }
$archive = [IO.Compression.ZipFile]::Open($destination, [IO.Compression.ZipArchiveMode]::Create)
try {
    # プレビューのソースと同梱フォントだけを収録する。画像・ログ・作業用の ZIP・トークンは含めない。
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File) {
        $relative = $file.FullName.Substring($root.Length).Replace('\', '/')
        if (-not ($file.Extension -in @('.ps1', '.cmd', '.md', '.json') -or $relative -match '(^|/)fonts/[^/]+\.(ttf|txt)$' -or $relative -match '(^|/)images/[^/]+\.png$')) { continue }
        if ($relative -match '(^|/)(output|screenshots|logs|backups|\.git)(/|$)') { continue }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, ('ui-preview/' + $relative))
    }
} finally { $archive.Dispose() }
Write-Host "プレビューだけの ZIP を作成しました: $destination"
