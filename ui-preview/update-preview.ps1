#requires -Version 5.1
<#
.SYNOPSIS
    この ui-preview フォルダを GitHub の最新版に更新します (update.cmd から起動)。
.DESCRIPTION
    GitHub から ui-preview フォルダだけを取得し、このフォルダへ上書きします。
    内容が変わるファイルは、上書きする前に backups\<日時>\ へ保存します。
    手元で編集したデザインは、そこから取り戻せます。GitHub に無いファイルは消しません。

      方式 zip   : リポジトリの ZIP をまとめて取得し、ui-preview だけを取り出す
      方式 files : GitHub API で ui-preview の一覧を取り、1 つずつ取得する
                   (ZIP の配信元が遮断されている環境向け)
.EXAMPLE
    .\update-preview.ps1            # 最新版に更新 (zip → files の順で試す)
    .\update-preview.ps1 -Check     # 更新される内容だけ確認 (変更しない)
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Mitsunori0717/double-os-boot',
    [string]$Branch = 'claude/windows-linux-dual-boot-lwgj28',
    [ValidateSet('auto', 'zip', 'files')]
    [string]$Method = 'auto',
    [switch]$Check,
    # 非公開リポジトリ用 (省略時: このフォルダーか 1 つ上の update-token.txt を使う)
    [string]$Token = ''
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$headers = @{ 'User-Agent' = 'edgebox-ui-preview-updater' }
if (-not $Token) {
    foreach ($dir in @($PSScriptRoot, (Split-Path $PSScriptRoot -Parent))) {
        $tokenFile = Join-Path $dir 'update-token.txt'
        if (Test-Path -LiteralPath $tokenFile) {
            try { $Token = ((Get-Content -LiteralPath $tokenFile -Raw) -replace '\s', '') } catch { }
            if ($Token) { break }
        }
    }
}
if ($Token) { $headers['Authorization'] = "token $Token" }
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('edgebox-ui-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Get-PreviewViaZip {
    $zip = Join-Path $tmpRoot 'source.zip'
    $extract = Join-Path $tmpRoot 'zip'
    Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing -Headers $headers
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $top = @(Get-ChildItem -LiteralPath $extract -Directory)[0]
    $preview = if ($top) { Join-Path $top.FullName 'ui-preview' } else { '' }
    if (-not $preview -or -not (Test-Path -LiteralPath $preview)) { throw 'ZIP の中に ui-preview フォルダがありません。' }
    return $preview
}

function Get-PreviewEntries([string]$Path) {
    $api = "https://api.github.com/repos/$Repo/contents/$Path" + '?ref=' + [uri]::EscapeDataString($Branch)
    $out = @()
    foreach ($item in @(Invoke-RestMethod -Uri $api -UseBasicParsing -Headers $headers)) {
        if ($item.type -eq 'dir') { $out += Get-PreviewEntries $item.path }
        elseif ($item.type -eq 'file' -and $item.download_url) { $out += [pscustomobject]@{ Rel = $item.path.Substring('ui-preview/'.Length); Url = $item.download_url } }
    }
    return $out
}

function Get-PreviewViaFiles {
    $root = Join-Path $tmpRoot 'files'
    Write-Host '  ファイル一覧を取得しています...'
    $entries = @(Get-PreviewEntries 'ui-preview')
    if (-not $entries.Count) { throw 'ui-preview のファイル一覧を取得できませんでした。' }
    Write-Host "  $($entries.Count) 件をダウンロードしています..."
    $failed = @()
    foreach ($entry in $entries) {
        if ($entry.Rel -match '(^|/)\.\.(/|$)') { throw "不正なパスです: $($entry.Rel)" }
        $destination = Join-Path $root ($entry.Rel -replace '/', '\')
        [void][IO.Directory]::CreateDirectory((Split-Path $destination -Parent))
        $done = $false
        for ($try = 1; $try -le 3 -and -not $done; $try++) {
            try { Invoke-WebRequest -Uri $entry.Url -OutFile $destination -UseBasicParsing -Headers $headers; $done = $true }
            catch { if ($try -lt 3) { Start-Sleep -Milliseconds (400 * $try) } }
        }
        if (-not $done) { $failed += $entry.Rel }
    }
    # 一部のスクリプトだけ新しくなると動かなくなるため、説明書 (.md) 以外が欠けたら中止する
    $missing = @($failed | Where-Object { $_ -notmatch '\.md$' })
    if ($missing.Count) { throw ('取得できなかったファイルがあるため中止しました: ' + ($missing -join ', ')) }
    foreach ($rel in $failed) {
        Remove-Item -LiteralPath (Join-Path $root ($rel -replace '/', '\')) -Force -ErrorAction SilentlyContinue
        Write-Host "  取得できなかった説明書 (古いまま残します): $rel" -ForegroundColor Yellow
    }
    return $root
}

Write-Host ''
Write-Host '===== UI プレビューの更新 =====' -ForegroundColor White
Write-Host "  取得元 : $Repo ($Branch) の ui-preview"
Write-Host "  更新先 : $PSScriptRoot"
[void][IO.Directory]::CreateDirectory($tmpRoot)
try {
    $source = $null
    if ($Method -ne 'files') {
        Write-Host ''
        Write-Host 'ZIP でまとめて取得しています...' -ForegroundColor Cyan
        try { $source = Get-PreviewViaZip }
        catch {
            Write-Host "  ZIP では取得できませんでした: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($Method -eq 'zip') { exit 1 }
        }
    }
    if (-not $source) {
        Write-Host ''
        Write-Host 'ファイル単位で取得しています...' -ForegroundColor Cyan
        try { $source = Get-PreviewViaFiles }
        catch {
            Write-Host "取得できませんでした: $($_.Exception.Message)" -ForegroundColor Red
            if (-not $Token) { Write-Host '  すべて 404 の場合は、update-token.txt (GitHub のトークン 1 行) を置いてから再実行してください。' -ForegroundColor Yellow }
            exit 1
        }
    }

    $sourceRoot = (Get-Item -LiteralPath $source).FullName.TrimEnd('\') + '\'
    $added = @(); $changed = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File)) {
        $rel = $file.FullName.Substring($sourceRoot.Length)
        $target = Join-Path $PSScriptRoot $rel
        if (-not (Test-Path -LiteralPath $target)) { $added += $rel }
        elseif ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { $changed += $rel }
    }
    Write-Host ''
    if (-not ($added.Count + $changed.Count)) {
        Write-Host 'すでに最新です (更新するファイルはありません)。' -ForegroundColor Green
        exit 0
    }
    foreach ($rel in $added) { Write-Host "  + $rel" }
    foreach ($rel in $changed) { Write-Host "  * $rel" }
    if ($Check) {
        Write-Host ''
        Write-Host "追加 $($added.Count) 件 / 更新 $($changed.Count) 件。確認のみのため変更していません (-Check)。" -ForegroundColor Yellow
        exit 0
    }

    $backup = $null
    if ($changed.Count) {
        $backup = Join-Path $PSScriptRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($rel in $changed) {
            $copy = Join-Path $backup $rel
            [void][IO.Directory]::CreateDirectory((Split-Path $copy -Parent))
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $rel) -Destination $copy -Force
        }
    }
    foreach ($rel in @($added + $changed)) {
        $target = Join-Path $PSScriptRoot $rel
        [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        Copy-Item -LiteralPath (Join-Path $source $rel) -Destination $target -Force
        # ダウンロード由来のブロックを外す (実行ポリシーに弾かれないように)
        Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host "更新しました (追加 $($added.Count) 件 / 更新 $($changed.Count) 件)。" -ForegroundColor Green
    if ($backup) { Write-Host "  上書き前のファイルは $backup に保存しました。" }
    Write-Host '  プレビューを開いている場合は、自動で開き直します。'
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
