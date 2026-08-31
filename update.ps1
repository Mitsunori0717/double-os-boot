<#
.SYNOPSIS
    このツール一式を GitHub の最新版に更新します。

.DESCRIPTION
    ZIP の取得・展開・上書きを自動化します。ネットワークによっては ZIP の配信元
    (codeload.github.com) が遮断されていることがあるため、その場合は
    ファイルを 1 つずつ取得する方式へ自動で切り替えます。

      方式 zip   : ZIP をまとめて取得 (速い。既定でまずこちらを試す)
      方式 files : GitHub API で一覧を取り、raw.githubusercontent.com から個別取得
                   (ZIP が遮断されている環境でも通ることが多い)

    端末ごとの設定ファイル (display-config.json / field-disk.conf /
    cpu-partition.json / cpu-apps.json / tools\ など) は GitHub 側に無いため、
    上書きされず、そのまま残ります。

.EXAMPLE
    update.cmd をダブルクリック     # いちばん簡単
    .\update.ps1                    # 最新版に更新 (zip → files の順で試す)
    .\update.ps1 -Check             # 更新される内容だけ確認 (変更しない)
    .\update.ps1 -Method files      # 個別取得を明示 (ZIP が遮断されている環境)
    .\update.ps1 -Diagnose          # どの取得先に到達できるか調べる

.NOTES
    管理者権限は不要です。
#>
[CmdletBinding()]
param(
    [string]$Repo   = "Mitsunori0717/double-os-boot",
    [string]$Branch = "claude/windows-linux-dual-boot-lwgj28",
    [ValidateSet("auto", "zip", "files")]
    [string]$Method = "auto",
    [switch]$Check,      # 変更せず、更新される内容だけ表示
    [switch]$Diagnose    # 到達性の確認のみ
)

$ErrorActionPreference = "Stop"

# 古い既定のままだと GitHub に接続できない環境があるため明示する
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$UA = @{ "User-Agent" = "double-os-boot-updater" }   # GitHub API は User-Agent 必須

$BranchEnc = [uri]::EscapeDataString($Branch)
$ZipUrl    = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$tmpRoot   = Join-Path $env:TEMP ("dob-update-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))

# ============================================================
#  到達性の確認
# ============================================================
if ($Diagnose) {
    Write-Host ""
    Write-Host "=== 取得先への到達性 ===" -ForegroundColor Cyan
    $targets = [ordered]@{
        "GitHub 本体          " = "https://github.com/$Repo"
        "ZIP 配信 (codeload)  " = $ZipUrl
        "個別取得 (raw)       " = "https://raw.githubusercontent.com/$Repo/$Branch/README.md"
        "一覧取得 (api)       " = "https://api.github.com/repos/$Repo"
    }
    foreach ($k in $targets.Keys) {
        try {
            $r = Invoke-WebRequest -Uri $targets[$k] -UseBasicParsing -TimeoutSec 20 -Headers $UA
            Write-Host ("  OK  {0} : HTTP {1}" -f $k, $r.StatusCode) -ForegroundColor Green
        } catch {
            Write-Host ("  NG  {0} : {1}" -f $k, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "『ZIP 配信』だけ NG の場合は -Method files で更新できます。" -ForegroundColor Cyan
    exit 0
}

# ============================================================
#  取得方式 1: ZIP をまとめて取得
# ============================================================
function Get-SourceViaZip {
    $zipPath = Join-Path $tmpRoot "source.zip"
    $extract = Join-Path $tmpRoot "x"
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing -Headers $UA
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force
    # 展開直後のフォルダ名はブランチ名から作られるため、決め打ちせず探す
    $root = @(Get-ChildItem -Path $extract -Directory)[0]
    if (-not $root) { throw "展開したファイルが見つかりません。" }
    return $root.FullName
}

# ============================================================
#  取得方式 2: ファイルを 1 つずつ取得 (ZIP が遮断されている環境向け)
# ============================================================
function Get-RepoEntries([string]$Path) {
    $api = "https://api.github.com/repos/$Repo/contents/$Path" + "?ref=$BranchEnc"
    $items = @(Invoke-RestMethod -Uri $api -UseBasicParsing -Headers $UA)
    $out = @()
    foreach ($i in $items) {
        if ($i.type -eq "dir") { $out += Get-RepoEntries $i.path }
        elseif ($i.type -eq "file" -and $i.download_url) {
            $out += [pscustomobject]@{ Rel = $i.path; Url = $i.download_url }
        }
    }
    return $out
}

function Get-SourceViaFiles {
    $root = Join-Path $tmpRoot "f"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Write-Host "  ファイル一覧を取得しています..."
    $entries = @(Get-RepoEntries "")
    if ($entries.Count -eq 0) { throw "ファイル一覧を取得できませんでした。" }
    Write-Host "  $($entries.Count) 件をダウンロードしています..."
    $n = 0
    foreach ($e in $entries) {
        $dst = Join-Path $root ($e.Rel -replace '/', '\')
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Invoke-WebRequest -Uri $e.Url -OutFile $dst -UseBasicParsing -Headers $UA
        $n++
        if (($n % 10) -eq 0) { Write-Host "    $n / $($entries.Count)" }
    }
    return $root
}

# ============================================================
#  更新
# ============================================================
Write-Host ""
Write-Host "===== ツール一式の更新 =====" -ForegroundColor White
Write-Host "  取得元 : $Repo ($Branch)"
Write-Host "  更新先 : $PSScriptRoot"

New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
try {
    $srcRoot = $null
    if ($Method -ne "files") {
        Write-Host ""
        Write-Host "ZIP でまとめて取得しています..." -ForegroundColor Cyan
        try {
            $srcRoot = Get-SourceViaZip
        } catch {
            Write-Host "  ZIP では取得できませんでした: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($Method -eq "zip") {
                Write-Host "  -Method files をお試しください (個別取得に切り替わります)。" -ForegroundColor Cyan
                exit 1
            }
            Write-Host "  ファイル単位の取得に切り替えます (ZIP の配信元が遮断されている環境向け)。" -ForegroundColor Cyan
        }
    }
    if (-not $srcRoot) {
        Write-Host ""
        Write-Host "ファイル単位で取得しています..." -ForegroundColor Cyan
        try {
            $srcRoot = Get-SourceViaFiles
        } catch {
            Write-Host ""
            Write-Host "取得できませんでした: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  到達性を調べるには: .\update.ps1 -Diagnose" -ForegroundColor Cyan
            exit 1
        }
    }

    # --- 変更されるファイルを調べる ---
    $changed = @(); $added = @()
    foreach ($f in @(Get-ChildItem -Path $srcRoot -Recurse -File)) {
        $rel = $f.FullName.Substring($srcRoot.Length).TrimStart("\")
        $dst = Join-Path $PSScriptRoot $rel
        if (-not (Test-Path $dst)) {
            $added += $rel
        } elseif ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash $dst).Hash) {
            $changed += $rel
        }
    }

    Write-Host ""
    if ($added.Count -eq 0 -and $changed.Count -eq 0) {
        Write-Host "すでに最新です (更新するファイルはありません)。" -ForegroundColor Green
        exit 0
    }
    if ($added.Count -gt 0) {
        Write-Host "追加されるファイル ($($added.Count) 件):" -ForegroundColor Cyan
        foreach ($n in ($added | Select-Object -First 20)) { Write-Host "  + $n" }
        if ($added.Count -gt 20) { Write-Host "  ... ほか $($added.Count - 20) 件" }
    }
    if ($changed.Count -gt 0) {
        Write-Host "更新されるファイル ($($changed.Count) 件):" -ForegroundColor Cyan
        foreach ($n in ($changed | Select-Object -First 20)) { Write-Host "  * $n" }
        if ($changed.Count -gt 20) { Write-Host "  ... ほか $($changed.Count - 20) 件" }
    }

    if ($Check) {
        Write-Host ""
        Write-Host "確認のみのため、ファイルは変更していません (-Check)。" -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "更新しています..." -ForegroundColor Cyan
    foreach ($item in @(Get-ChildItem -Path $srcRoot)) {
        Copy-Item -Path $item.FullName -Destination $PSScriptRoot -Recurse -Force
    }

    # ダウンロード由来のブロックを外す (これをしないと実行ポリシーに弾かれる)
    Get-ChildItem -Path $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "更新しました ($($added.Count + $changed.Count) 件)。" -ForegroundColor Green
    Write-Host "  端末ごとの設定ファイルはそのまま残しています。"
} finally {
    Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
