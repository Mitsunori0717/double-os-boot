<#
.SYNOPSIS
    このツール一式を GitHub の最新版に更新します (ZIP のダウンロードと展開を自動化)。

.DESCRIPTION
    ブラウザで ZIP を落として展開して置き換える、という手順を 1 コマンドにします。

      1. GitHub から最新の ZIP を取得
      2. 一時フォルダに展開
      3. このフォルダのスクリプト類を上書き更新
      4. ダウンロード由来のブロック (Mark of the Web) を解除

    端末ごとの設定ファイル (display-config.json / field-disk.conf /
    cpu-partition.json / cpu-apps.json / tools\ など) は GitHub 側に無いため、
    上書きされず、そのまま残ります。

.EXAMPLE
    update.cmd をダブルクリック          # いちばん簡単
    .\update.ps1                         # 最新版に更新
    .\update.ps1 -Check                  # 更新される内容だけ確認 (変更しない)

.NOTES
    管理者権限は不要です。
#>
[CmdletBinding()]
param(
    [string]$Repo   = "Mitsunori0717/double-os-boot",
    [string]$Branch = "claude/windows-linux-dual-boot-lwgj28",
    [switch]$Check   # 変更せず、更新される内容だけ表示
)

$ErrorActionPreference = "Stop"

# 古い既定のままだと GitHub に接続できない環境があるため明示する
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$zipUrl  = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$tmpRoot = Join-Path $env:TEMP ("dob-update-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$zipPath = Join-Path $tmpRoot "source.zip"

Write-Host ""
Write-Host "===== ツール一式の更新 =====" -ForegroundColor White
Write-Host "  取得元 : $zipUrl"
Write-Host "  更新先 : $PSScriptRoot"

New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
try {
    Write-Host ""
    Write-Host "ダウンロードしています..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Host "ダウンロードに失敗しました: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "確認してください:" -ForegroundColor Yellow
        Write-Host "  - インターネットに接続されているか"
        Write-Host "  - ブランチ名が正しいか (-Branch で指定できます)"
        Write-Host "  - 手動で開く場合: $zipUrl"
        exit 1
    }

    Write-Host "展開しています..." -ForegroundColor Cyan
    $extract = Join-Path $tmpRoot "x"
    # 展開直後のフォルダ名はブランチ名から作られるため、決め打ちせず探す
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force
    $srcRoot = @(Get-ChildItem -Path $extract -Directory)[0]
    if (-not $srcRoot) { Write-Error "展開したファイルが見つかりません。"; exit 1 }

    # --- 変更されるファイルを調べる ---
    $changed = @(); $added = @()
    foreach ($f in @(Get-ChildItem -Path $srcRoot.FullName -Recurse -File)) {
        $rel = $f.FullName.Substring($srcRoot.FullName.Length).TrimStart("\")
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
    foreach ($item in @(Get-ChildItem -Path $srcRoot.FullName)) {
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
