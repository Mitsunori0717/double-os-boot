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

    端末ごとの設定ファイル (display-config.json / fsbp-disk.conf /
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
    # 取得するコミット (省略時はブランチの最新)。
    # GitHub の配信キャッシュで古い内容が返るときは、コミット ID を指定すると確実
    [string]$Ref = "",
    [ValidateSet("auto", "zip", "files")]
    [string]$Method = "auto",
    [switch]$Check,      # 変更せず、更新される内容だけ表示
    [switch]$Diagnose,   # 到達性の確認のみ
    # 内部用: 旧ファイル名 (*-field-*) を参照している登録済みタスクを登録し直す (管理者権限で自動的に呼ばれる)
    [switch]$MigrateTasks
)

$ErrorActionPreference = "Stop"

# 古い既定のままだと GitHub に接続できない環境があるため明示する
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$UA = @{ "User-Agent" = "double-os-boot-updater" }   # GitHub API は User-Agent 必須

if (-not $Ref) { $Ref = $Branch }
$BranchEnc = [uri]::EscapeDataString($Ref)
# ZIP も -Ref に従う。コミット ID (40 桁の 16 進) は archive/<sha>.zip、
# ブランチ名 (/ を含むことがある) は archive/refs/heads/<branch>.zip で取得する
if ($Ref -match '^[0-9a-fA-F]{40}$') {
    $ZipUrl = "https://github.com/$Repo/archive/$Ref.zip"
} else {
    $ZipUrl = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
}
$tmpRoot   = Join-Path $env:TEMP ("dob-update-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$script:skippedDocs = @()   # 個別取得で取れなかった説明書 (.md) の一覧

# ============================================================
#  到達性の確認
# ============================================================
if ($Diagnose) {
    Write-Host ""
    Write-Host "=== 取得先への到達性 ===" -ForegroundColor Cyan
    $targets = [ordered]@{
        "GitHub 本体          " = "https://github.com/$Repo"
        "ZIP 配信 (codeload)  " = $ZipUrl
        "個別取得 (raw)       " = "https://raw.githubusercontent.com/$Repo/$Ref/README.md"
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
#  名称を FsBP に統一した際の移行 (旧ファイル名 *-field-* からの引き継ぎ)
# ============================================================
# 旧名 → 新名。登録済みタスク・デスクトップのアイコンは旧名を絶対パスで参照している
# ため、ファイルを置き換えるだけでは動かなくなる。更新のたびに以下を自動で行う:
#   1. 端末ごとの設定ファイル (*.conf) を新名へ引き継ぐ
#   2. 旧名のスクリプトを削除する (新名のものが揃っているときだけ)
#   3. デスクトップのアイコンの参照先を新名に書き換える
#   4. 旧名を参照している登録済みタスクを新しいスクリプトで登録し直す (要管理者 → 昇格して実行)
$FsBPRenames = [ordered]@{
    "00-field-launcher.ps1"         = "00-fsbp-launcher.ps1"
    "01-create-field-vm.ps1"        = "01-create-fsbp-vm.ps1"
    "02-start-field-vm.ps1"         = "02-start-fsbp-vm.ps1"
    "03-field-display-kiosk.ps1"    = "03-fsbp-display-kiosk.ps1"
    "04-reboot-to-field-native.ps1" = "04-reboot-to-fsbp-native.ps1"
    "field-start.cmd"               = "fsbp-start.cmd"
    "field-disk.conf"               = "fsbp-disk.conf"
    "field-boot-entry.conf"         = "fsbp-boot-entry.conf"
}
$FsBPStalePattern = 'field-launcher|create-field-vm|start-field-vm|field-display-kiosk|reboot-to-field-native'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 旧ファイル名を参照している登録済みタスク
function Get-StaleFsBPTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $a = @($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " "
        $a -match $FsBPStalePattern
    })
}

# 1〜3: 管理者権限なしでできる分
function Invoke-FsBPFileMigration {
    $wh = Join-Path $PSScriptRoot "windows-host"
    if (-not (Test-Path $wh)) { return }
    foreach ($k in $FsBPRenames.Keys) {
        $old = Join-Path $wh $k
        $new = Join-Path $wh $FsBPRenames[$k]
        if (-not (Test-Path $old)) { continue }
        try {
            if ($k -like "*.conf") {
                # 端末ごとの設定は引き継ぐ (新名が既にあるなら旧名は不要)
                if (-not (Test-Path $new)) {
                    Move-Item $old $new -Force
                    Write-Host "  設定を引き継ぎました: $k → $($FsBPRenames[$k])"
                } else {
                    Remove-Item $old -Force -ErrorAction SilentlyContinue
                }
            } elseif (Test-Path $new) {
                Remove-Item $old -Force -ErrorAction SilentlyContinue
                Write-Host "  旧ファイルを削除しました: windows-host\$k"
            }
        } catch {
            Write-Host "  $k の引き継ぎに失敗しました (手動で対処してください): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # デスクトップのアイコンが旧名を直接参照していれば書き換える
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $sh = New-Object -ComObject WScript.Shell
        foreach ($lnk in @(Get-ChildItem $desktop -Filter *.lnk -ErrorAction SilentlyContinue)) {
            try {
                $s = $sh.CreateShortcut($lnk.FullName)
                $lnkArgs = [string]$s.Arguments
                if ($lnkArgs -notmatch $FsBPStalePattern) { continue }
                foreach ($k in $FsBPRenames.Keys) { $lnkArgs = $lnkArgs.Replace($k, $FsBPRenames[$k]) }
                $s.Arguments = $lnkArgs
                $s.Save()
                Write-Host "  アイコンの参照先を直しました: $($lnk.Name)"
            } catch { }
        }
    } catch { }
}

# 4: 旧名を参照しているタスクを、新しいスクリプトで登録し直す (管理者権限が必要)
function Repair-StaleFsBPTasks {
    $wh = Join-Path $PSScriptRoot "windows-host"
    # タスク名 → 登録し直すスクリプトとスイッチ
    $map = @{
        "EdgeBox-Launcher"             = @("00-fsbp-launcher.ps1",       "Setup")
        "EdgeBox-Display-Kiosk"        = @("03-fsbp-display-kiosk.ps1",  "Install")
        "EdgeBox-Display-Kiosk-Splash" = @("03-fsbp-display-kiosk.ps1",  "Install")
        "EdgeBox-Native-Boot"          = @("04-reboot-to-fsbp-native.ps1", "Setup")
    }
    $done = @{}
    $ok = $true
    foreach ($t in @(Get-StaleFsBPTasks)) {
        $entry = $map[$t.TaskName]
        if (-not $entry) {
            Write-Host "  タスク '$($t.TaskName)' は旧ファイル名を参照しています。登録し直し方が分からないため、手動で登録し直してください。" -ForegroundColor Yellow
            $ok = $false
            continue
        }
        $key = $entry -join " "
        if ($done.ContainsKey($key)) { continue }   # 03 は 2 つのタスクを 1 回の -Install で登録し直す
        $done[$key] = $true
        $script = Join-Path $wh $entry[0]
        if (-not (Test-Path $script)) {
            Write-Host "  $($entry[0]) が見つからないため、タスク '$($t.TaskName)' は登録し直せませんでした。" -ForegroundColor Yellow
            $ok = $false
            continue
        }
        # タスクに焼き込まれていた VM 名はそのまま引き継ぐ
        $p = @{ $entry[1] = $true }
        $a = @($t.Actions | ForEach-Object { "$($_.Arguments)" }) -join " "
        if ($a -match '-VMName\s+"([^"]+)"') { $p["VMName"] = $Matches[1] }
        Write-Host "  タスクを登録し直します: $($t.TaskName)  (.\$($entry[0]) -$($entry[1]))" -ForegroundColor Cyan
        try {
            & $script @p | Out-Null
        } catch {
            Write-Host "    失敗しました: $($_.Exception.Message)" -ForegroundColor Yellow
            $ok = $false
        }
    }
    return $ok
}

if ($MigrateTasks) {
    Write-Host ""
    Write-Host "=== 登録済みタスクを新しいファイル名で登録し直します ===" -ForegroundColor Cyan
    if (-not (Test-IsAdmin)) { Write-Host "管理者権限が必要です。" -ForegroundColor Red; exit 1 }
    $ok = Repair-StaleFsBPTasks
    if (@(Get-StaleFsBPTasks).Count -eq 0) {
        Write-Host "登録し直しました。" -ForegroundColor Green
        exit 0
    }
    Write-Host "一部のタスクが旧ファイル名のままです。" -ForegroundColor Yellow
    exit 1
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
# 同梱のファイル一覧 (filelist.txt) から取得する。api.github.com が
# 遮断されている環境でも、raw.githubusercontent.com だけで完結する
function Get-EntriesFromFileList {
    $url = "https://raw.githubusercontent.com/$Repo/$Ref/filelist.txt"
    $txt = (Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $UA).Content
    $out = @()
    foreach ($line in ($txt -split "`r?`n")) {
        $rel = $line.Trim()
        if (-not $rel -or $rel.StartsWith("#")) { continue }
        $out += [pscustomobject]@{
            Rel = $rel
            Url = "https://raw.githubusercontent.com/$Repo/$Ref/$rel"
        }
    }
    return $out
}

function Get-RepoEntries([string]$Path) {
    # 末尾に / を付けると GitHub API が 400 を返すため、パス無しのときは付けない
    $api = "https://api.github.com/repos/$Repo/contents"
    if ($Path) { $api += "/$Path" }
    $api += "?ref=$BranchEnc"
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
    # まず同梱の一覧 (raw のみで完結)。取れなければ GitHub API にフォールバック
    $entries = @()
    try {
        $entries = @(Get-EntriesFromFileList)
    } catch {
        Write-Host "    同梱の一覧を取得できなかったため、GitHub API を使います" -ForegroundColor Yellow
    }
    if ($entries.Count -eq 0) { $entries = @(Get-RepoEntries "") }
    if ($entries.Count -eq 0) { throw "ファイル一覧を取得できませんでした。" }
    Write-Host "  $($entries.Count) 件をダウンロードしています..."
    $n = 0; $failed = @()
    foreach ($e in $entries) {
        $dst = Join-Path $root ($e.Rel -replace '/', '\')
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # 一時的な失敗 (混雑・throttle) に備えて数回試す
        $got = $false
        for ($try = 1; $try -le 3 -and -not $got; $try++) {
            try {
                Invoke-WebRequest -Uri $e.Url -OutFile $dst -UseBasicParsing -Headers $UA
                $got = $true
            } catch {
                if ($try -lt 3) { Start-Sleep -Milliseconds (400 * $try) }
            }
        }
        if ($got) {
            $n++
        } else {
            # それでも駄目なら飛ばす (プロキシが特定のパスだけ弾く環境があるため)
            $failed += $e.Rel
            Remove-Item $dst -Force -ErrorAction SilentlyContinue
        }
        if ((($n + $failed.Count) % 10) -eq 0) { Write-Host "    $($n + $failed.Count) / $($entries.Count)" }
    }
    if ($n -eq 0) { throw "1 件もダウンロードできませんでした。" }
    if ($failed.Count -gt 0) {
        # スクリプト類は互いに呼び合うため、一部だけ新しくなると動かなくなる。
        # 1 件でも取れなければ更新を中止する (既存環境には何も書き込まない)。
        # 説明書 (.md) だけが取れなかった場合は、スクリプトの更新を優先して続行する。
        $failedScripts = @($failed | Where-Object { $_ -notmatch '\.md$' })
        if ($failedScripts.Count -gt 0) {
            Write-Host "  取得できなかったファイル ($($failed.Count) 件):" -ForegroundColor Red
            foreach ($f in $failed) { Write-Host "    - $f" -ForegroundColor Red }
            throw "スクリプトの一部が取得できなかったため、更新を中止しました (一部だけ新しくなると動かなくなるため)。時間をおいて再実行してください。"
        }
        Write-Host "  取得できなかった説明書 ($($failed.Count) 件・そのまま残します):" -ForegroundColor Yellow
        foreach ($f in $failed) { Write-Host "    - $f" -ForegroundColor Yellow }
        $script:skippedDocs = $failed
    }
    return $root
}

# ============================================================
#  更新
# ============================================================
Write-Host ""
Write-Host "===== ツール一式の更新 =====" -ForegroundColor White
Write-Host "  取得元 : $Repo ($Ref)"
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

    # --- 名称を FsBP に統一した際の移行 (旧ファイル名からの引き継ぎ) ---
    Invoke-FsBPFileMigration
    if (@(Get-StaleFsBPTasks).Count -gt 0) {
        Write-Host ""
        Write-Host "登録済みタスクが旧ファイル名 (*-field-*) を参照しているため、新しいファイル名で登録し直します。" -ForegroundColor Cyan
        if (Test-IsAdmin) {
            Repair-StaleFsBPTasks | Out-Null
        } else {
            Write-Host "  管理者権限が必要なため、確認画面 (UAC) が出ます。「はい」を選んでください。"
            try {
                $pr = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MigrateTasks"
                if ($pr.ExitCode -ne 0) { throw "登録し直しが完了しませんでした (終了コード $($pr.ExitCode))。" }
            } catch {
                Write-Host "  登録し直せませんでした: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        if (@(Get-StaleFsBPTasks).Count -gt 0) {
            Write-Host "  旧ファイル名のままのタスクが残っています。管理者 PowerShell で次を実行してください:" -ForegroundColor Yellow
            Write-Host "    cd `"$PSScriptRoot\windows-host`""
            Write-Host "    .\03-fsbp-display-kiosk.ps1 -Install ; .\00-fsbp-launcher.ps1 -Setup ; .\04-reboot-to-fsbp-native.ps1 -Setup"
        } else {
            Write-Host "  登録済みタスクを新しいファイル名で登録し直しました。" -ForegroundColor Green
        }
    }

    Write-Host ""
    if ($script:skippedDocs -and $script:skippedDocs.Count -gt 0) {
        Write-Host "更新しました ($($added.Count + $changed.Count) 件)。ただし説明書 $($script:skippedDocs.Count) 件は取得できず、古いままです。" -ForegroundColor Yellow
        Write-Host "  時間をおいて再実行すると、残りも更新されます。"
    } else {
        Write-Host "更新しました ($($added.Count + $changed.Count) 件)。" -ForegroundColor Green
    }
    Write-Host "  端末ごとの設定ファイルはそのまま残しています。"
} finally {
    Remove-Item -Path $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
