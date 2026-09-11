<#
.SYNOPSIS
    EdgeBox の画面表示を管理します (左右モニターへの自動表示)。
    すべての設定は『EdgeBox表示設定』の設定コンソール (-Settings) で変更できます。

.EXAMPLE
    .\03-field-display-kiosk.ps1              # 設定内容で今すぐ表示
    .\03-field-display-kiosk.ps1 -Settings    # 設定コンソールを開く
    .\03-field-display-kiosk.ps1 -Setup       # デスクトップに『EdgeBox表示設定』アイコンを作成
    .\03-field-display-kiosk.ps1 -Install     # ログオン時の自動表示を登録
    .\03-field-display-kiosk.ps1 -Uninstall   # 自動表示を解除
    .\03-field-display-kiosk.ps1 -ConsoleResolution auto   # コンソールの解像度をモニターに合わせる (EdgeBox 停止中)

.NOTES
    動作の記録は display-log.txt に残ります (うまく表示されないときはこれを確認)。
#>
[CmdletBinding()]
param(
    [string]$VMName   = "EdgeBox",
    [string]$RightUrl,
    [string]$LeftUrl,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Settings,
    [switch]$Setup,
    [switch]$EscWatcher,
    [switch]$Splash,
    [switch]$NoSplash,
    [switch]$Backdrop,
    [string]$BackdropBounds,
    [switch]$Notice,          # 内部用: 右画面の右上に数秒だけ出す小さな案内 (別プロセスで自分で閉じる)
    [string]$NoticeText = "",
    [int]$NoticeSec = 5,
    [string]$NoticeBounds = "",   # 右画面の範囲 "X,Y,W,H"
    [switch]$ConsoleCloser,
    [switch]$KeepConsole,     # コンソールを自動で閉じない (『EdgeBox 画面』アイコン用)
    [switch]$LeftGuard,       # 内部用: 左画面の見張り役 (コンソールの全画面を固定し、他の窓を右へ)
    [switch]$UrlRetry,        # 内部用: 管理画面が応答してから右画面のブラウザを開き直す (起動時に応答が無かった場合)
    [int]$CloserDelaySec = 30,
    [string]$CloserWaitUrl = "",
    [string]$ConsoleResolution,
    [int]$TimeoutSec  = 420,
    [int]$UrlTimeoutSec = 900   # 管理画面 (右画面の URL) の応答を待つ上限。左のコンソールは待たずに先に出す
)

$ErrorActionPreference = "Stop"

# -VMName を明示していない場合、既定名の EdgeBox が無ければ、EdgeBox のディスク
# (物理ディスクのパススルー) を持つ EdgeBox を探して使う。00-field-launcher.ps1 と
# 同じ考え方で、登録名が「EdgeBox」でなくても (旧名称のままでも) そのまま動くようにする
if (-not $PSBoundParameters.ContainsKey("VMName") -and -not ($Splash -or $Backdrop -or $Notice -or $EscWatcher -or $ConsoleCloser -or $LeftGuard -or $UrlRetry) -and
    -not (Get-VM -Name $VMName -ErrorAction SilentlyContinue)) {
    $foundVms = @()
    foreach ($v in @(Get-VM -ErrorAction SilentlyContinue)) {
        $pt = @(Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_.DiskNumber })
        if ($pt.Count -gt 0) { $foundVms += $v }
    }
    if ($foundVms.Count -eq 1) { $VMName = $foundVms[0].Name }
}
$TaskName = "EdgeBox-Display-Kiosk"
$ConfigFile = Join-Path $PSScriptRoot "display-config.json"
$LogFile    = Join-Path $PSScriptRoot "display-log.txt"
$StatusFile = Join-Path $PSScriptRoot "display-status.txt"

# どこで停止しても原因が追えるように、未処理エラーは必ずファイルに残す
trap {
    try {
        $errFile = Join-Path $PSScriptRoot "display-error.txt"
        $mode = if ($Splash) { "Splash" } elseif ($EscWatcher) { "EscWatcher" } elseif ($Backdrop) { "Backdrop" } elseif ($Notice) { "Notice" } elseif ($ConsoleCloser) { "ConsoleCloser" } elseif ($LeftGuard) { "LeftGuard" } else { "Main" }
        Add-Content -Path $errFile -Encoding UTF8 -Value (
            "{0}  [{1}] {2}`r`n  場所: {3}`r`n" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $mode,
            $_.Exception.Message, $_.InvocationInfo.PositionMessage)
    } catch { }
    break
}

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        # 起動中画面 (スプラッシュ) がこのファイルを読んで進捗を表示する
        Set-Content -Path $StatusFile -Value $m -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}
# 起動中画面に出す進捗だけを更新する (記録には残さない。待ち時間の経過表示用)
function Set-Status([string]$m) {
    try { Set-Content -Path $StatusFile -Value $m -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}

# CPU コア分割ツール (別フォルダ windows-cpu-partition) が full モードなら、EdgeBox を起動する前に
# 起動タスクと同じ処理を呼び、CPU グループに固定してから起動する (固定は EdgeBox 停止中に確実に効く)。
# ツールが無ければ何もしない (互いに独立。あるときだけ順番を譲る)。戻り値: 呼んだか
function Invoke-CpuPartitionBoot {
    try {
        $cpuDir = Join-Path (Split-Path $PSScriptRoot -Parent) "windows-cpu-partition"
        $cfgF = Join-Path $cpuDir "cpu-partition.json"; $ps1 = Join-Path $cpuDir "cpu-partition.ps1"
        if (-not (Test-Path $cfgF) -or -not (Test-Path $ps1)) { return $false }
        $c = Get-Content $cfgF -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($c.Mode -ne "full") { return $false }
        $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -BootApply -Quiet"
        if (-not $p.WaitForExit(240000)) { try { $p.Kill() } catch { } }
        return $true
    } catch { return $false }
}
# URL の先に 1 回だけ接続を試す (TCP が開くか)
function Test-UrlOnce([string]$u) {
    try {
        $uri = [Uri]$u
        $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "https") { 443 } else { 80 }
        $tcp = New-Object Net.Sockets.TcpClient
        $ok = $tcp.ConnectAsync($uri.Host, $port).Wait(3000)
        $tcp.Dispose()
        return [bool]$ok
    } catch { return $false }
}
$SplashLeftOffFile = Join-Path $PSScriptRoot "display-splash-leftoff.flag"   # 起動中画面 (左画面) を閉じる合図

# ============================================================
#  接続バー探し (共通): vmconnect の窓 (トップレベルと、その子孫) を列挙する
#  全画面のときに上部へ出る接続バーは、名前 (クラス名) が環境で違うため、
#  「vmconnect が持つ、左画面の上端に張り付いた横長で背の低い窓」という形で見つける
# ============================================================
$BarFinderSource = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class BarFinder {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public class Info {
        public IntPtr Hwnd; public IntPtr Parent; public int Pid; public bool Visible; public int Style;
        public string Class; public string Title; public int Left, Top, Right, Bottom;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
        // タイトルバー付きの普通の窓か (WS_CAPTION = 0x00C00000)。全画面モードの窓は枠なし
        public bool HasCaption { get { return (Style & 0x00C00000) == 0x00C00000; } }
    }
    static Info Describe(IntPtr h, IntPtr parent) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        Info i = new Info(); i.Hwnd = h; i.Parent = parent; i.Pid = (int)pid; i.Visible = IsWindowVisible(h);
        i.Style = GetWindowLong(h, -16);   // GWL_STYLE
        RECT r; if (GetWindowRect(h, out r)) { i.Left = r.Left; i.Top = r.Top; i.Right = r.Right; i.Bottom = r.Bottom; }
        StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, 256); i.Class = sb.ToString();
        StringBuilder st = new StringBuilder(256); GetWindowText(h, st, 256); i.Title = st.ToString();
        return i;
    }
    // 指定プロセスの窓をすべて返す (トップレベルと、includeChildren ならその子孫も)
    public static List<Info> Find(int[] pids, bool includeChildren) {
        List<Info> list = new List<Info>();
        List<IntPtr> tops = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) { tops.Add(h); return true; }, IntPtr.Zero);
        foreach (IntPtr h in tops) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (Array.IndexOf(pids, (int)pid) < 0) continue;
            list.Add(Describe(h, IntPtr.Zero));
            if (!includeChildren) continue;
            IntPtr top = h;
            EnumChildWindows(h, delegate(IntPtr c, IntPtr l) { list.Add(Describe(c, top)); return true; }, IntPtr.Zero);
        }
        return list;
    }
}
'@
function Get-ConsoleWindows {
    if (-not ("BarFinder" -as [type])) { Add-Type -TypeDefinition $BarFinderSource -ErrorAction Stop }
    $pids = @(Get-Process vmconnect -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($pids.Count -eq 0) { return @() }
    return @([BarFinder]::Find([int[]]$pids, $true))
}
# 接続バーらしい窓を探す ($b = 左画面の範囲、$main = コンソール本体の窓)
function Find-ConsoleBarWindows($b, [IntPtr]$main) {
    $found = @()
    foreach ($w in Get-ConsoleWindows) {
        if ($w.Hwnd -eq [IntPtr]::Zero -or $w.Hwnd -eq $main -or -not $w.Visible) { continue }
        if ($w.Parent -ne [IntPtr]::Zero -and $w.Class -like 'WindowsForms10*') { continue }   # vmconnect 自身の部品 (ツールバーなど) は対象外
        if ($w.Height -le 0 -or $w.Height -gt 160) { continue }
        if ($w.Width -lt 100 -or $w.Width -gt $b.Width) { continue }
        if ($w.Top -lt ($b.Y - 200) -or $w.Top -gt ($b.Y + 24)) { continue }
        if ($w.Left -lt ($b.X - 8) -or $w.Right -gt ($b.X + $b.Width + 8)) { continue }
        $found += $w
    }
    # 注意: 見つからなかったときに ,$found (空配列を包む) を返すと、呼び出し側の foreach が
    # 「空の要素 1 個」で 1 回まわり、$w.Hwnd が null になって ShowWindow が例外を出す。
    # foreach で受けるので、包まずにそのまま返す (0 件 = 0 回、1 件 = 1 回)
    return $found
}
function Format-ConsoleWindow($w) {
    $kind = if ($w.Parent -eq [IntPtr]::Zero) { "" } else { " 子" }
    return ("{0}[{1}] {2}x{3}@({4},{5}){6}" -f $w.Class, $w.Title, $w.Width, $w.Height, $w.Left, $w.Top, $kind)
}
# 見つからなかったときの手掛かり: 見えている窓を、画面上端に近い順に最大 12 個
function Get-ConsoleWindowDiag($b) {
    $list = @(Get-ConsoleWindows | Where-Object { $_.Visible } | Sort-Object { [Math]::Abs($_.Top - $b.Y) } | Select-Object -First 12)
    if ($list.Count -eq 0) { return "(見えている窓なし)" }
    return (($list | ForEach-Object { Format-ConsoleWindow $_ }) -join "; ")
}

# コンソールが「本当の全画面モード」でモニターの範囲 $b を覆っているか。
# 最大化しただけの窓もモニターを覆うので、大きさだけでは区別できない (実機では最大化のまま
# 「全画面になった」と誤判定していた)。全画面モードでは枠なし (タイトルバーなし) の窓が
# モニターを覆う点で見分ける。vmconnect 本体が枠なしになる場合も、RDP 部品が別窓を作る場合も
# トップレベルの窓として見つかる。タイトルバーを画面の上に押し出す方式にも備える
function Test-ConsoleFullScreenOn($b) {
    foreach ($w in Get-ConsoleWindows) {
        if ($w.Hwnd -eq [IntPtr]::Zero -or $w.Parent -ne [IntPtr]::Zero -or -not $w.Visible) { continue }
        if ($w.Left -gt ($b.X + 4) -or $w.Right -lt ($b.X + $b.Width - 4) -or $w.Bottom -lt ($b.Y + $b.Height - 4)) { continue }
        if (-not $w.HasCaption -and $w.Top -le ($b.Y + 4)) { return $true }
        if ($w.HasCaption -and $w.Top -le ($b.Y - 20)) { return $true }   # タイトルバーが画面外に隠れている
    }
    return $false
}
# 枠なしのコンソール窓がモニター $b の中にあるか (代替表示 = 黒背景の上に枠を外して中央表示 の状態)。
# 見張り役がこれを「全画面が外れた」と誤って戻さないために使う
function Test-ConsoleFramelessOn($b) {
    foreach ($w in Get-ConsoleWindows) {
        if ($w.Hwnd -eq [IntPtr]::Zero -or $w.Parent -ne [IntPtr]::Zero -or -not $w.Visible -or $w.HasCaption) { continue }
        $cx = [int](($w.Left + $w.Right) / 2); $cy = [int](($w.Top + $w.Bottom) / 2)
        if ($cx -ge $b.X -and $cx -lt ($b.X + $b.Width) -and $cy -ge $b.Y -and $cy -lt ($b.Y + $b.Height)) { return $true }
    }
    return $false
}
# コンソールの映像を受け持つ RDP 部品の入力窓 (IHWindowClass = Input Capture Window)。
# Ctrl+Alt+Break はこの窓にキーボードフォーカスがあるときに効くため、キー送信の前にここへフォーカスを移す
function Get-ConsoleInputWindow {
    foreach ($w in Get-ConsoleWindows) {
        if ($w.Parent -ne [IntPtr]::Zero -and $w.Class -eq 'IHWindowClass' -and $w.Visible) { return [IntPtr]$w.Hwnd }
    }
    return [IntPtr]::Zero
}
# 全画面かどうかの判定の手掛かり (記録用): vmconnect のトップレベルの窓を「枠あり/なし」付きで列挙
function Get-ConsoleTopWindowDiag {
    $list = @(Get-ConsoleWindows | Where-Object { $_.Parent -eq [IntPtr]::Zero -and $_.Visible })
    if ($list.Count -eq 0) { return "(見えている窓なし)" }
    return (($list | ForEach-Object { (Format-ConsoleWindow $_) + $(if ($_.HasCaption) { " 枠あり" } else { " 枠なし" }) }) -join "; ")
}

# ============================================================
#  起動中画面: 表示準備が終わるまで、全モニターを黒い画面で覆う
# ============================================================
if ($Splash) {
    # サインイン直後はデスクトップの準備中で失敗することがあるため、読み込みを再試行する
    $loaded = $false
    for ($i = 0; $i -lt 10 -and -not $loaded; $i++) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $loaded = $true
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $loaded) { exit 1 }
    $script:SplashDeadline = (Get-Date).AddSeconds($TimeoutSec + 30)    # 万一のときは自動で閉じる
    $script:SplashStart = Get-Date
    $script:SplashForms = @()
    $script:SplashDots = 0
    $script:SplashCheck = 0
    # 表示処理の本体 (このスクリプトを補助モードなしで実行しているプロセス) が動いているか。
    # 本体が起動しなかった / 途中で止まった場合に、黒い画面だけが残らないようにするための確認
    function Test-MainRunning {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match '03-field-display-kiosk' -and
                           $_.CommandLine -notmatch '-(Splash|Backdrop|Notice|EscWatcher|ConsoleCloser|LeftGuard)' })
        return ($procs.Count -gt 0)
    }

    function New-SplashForm($bounds) {
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = "None"
        $f.StartPosition = "Manual"
        $f.Bounds = $bounds
        $f.BackColor = [System.Drawing.Color]::Black
        $f.TopMost = $true
        $f.ShowInTaskbar = $false
        $f.KeyPreview = $true
        $f.Add_KeyDown({ param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { [System.Windows.Forms.Application]::Exit() }
        })
        $main = New-Object System.Windows.Forms.Label
        $main.Name = "main"
        $main.Dock = "Fill"
        $main.TextAlign = "MiddleCenter"
        $main.BackColor = [System.Drawing.Color]::Black
        $main.ForeColor = [System.Drawing.Color]::White
        $main.Font = New-Object System.Drawing.Font("Meiryo UI", 26)
        $main.Text = "EdgeBox 起動中"
        # 下の説明文 (進み具合) は出さない。「EdgeBox 起動中」だけ
        $f.Controls.Add($main)
        return $f
    }

    # 左端のモニター (EdgeBox のコンソールが出る画面) だけを「EdgeBox 起動中」で覆う
    # (あとから 2 枚目が認識されて左端が変わったらそちらへ移す)。右画面 (Windows のデスクトップ) は覆わない
    $script:LeftOff = $false
    function Sync-SplashScreens {
        $all = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds })
        if ($all.Count -gt 1) {
            $minX = ($all | ForEach-Object { $_.X } | Measure-Object -Minimum).Minimum
            $all = @($all | Where-Object { $_.X -eq $minX })
            foreach ($f in $script:SplashForms) {
                if (-not $f.IsDisposed -and $f.Bounds.X -ne $minX) { $f.Close() }
            }
        }
        foreach ($b in $all) {
            $covered = @($script:SplashForms | Where-Object { -not $_.IsDisposed -and $_.Bounds -eq $b })
            if ($covered.Count -eq 0) {
                $f = New-SplashForm $b
                $f.Show()
                $script:SplashForms += $f
            }
        }
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        if ((Get-Date) -gt $script:SplashDeadline) { [System.Windows.Forms.Application]::Exit(); return }
        # 開始から 60 秒たっても本体が動いていない (起動しなかった / 途中で止まった) なら、
        # 黒い画面を残さず普通の Windows の画面に戻す。10 秒ごとに確認
        $script:SplashCheck++
        if (($script:SplashCheck % 20) -eq 0 -and ((Get-Date) - $script:SplashStart).TotalSeconds -gt 60) {
            if (-not (Test-MainRunning)) {
                try { Add-Content -Path $LogFile -Encoding UTF8 -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  起動中画面: 表示処理の本体が動いていないため、画面を閉じて Windows に戻します。") } catch { }
                [System.Windows.Forms.Application]::Exit(); return
            }
        }
        $script:SplashDots = ($script:SplashDots + 1) % 4
        # 本体から「左のコンソールを全画面にする」の合図が来たら、覆いを外して終わる
        # (覆ったままだと全画面の切り替えが効かないことがあるため、切り替えの直前に外す)
        if (-not $script:LeftOff -and (Test-Path $SplashLeftOffFile)) {
            $script:LeftOff = $true
            [System.Windows.Forms.Application]::Exit(); return
        }
        foreach ($f in $script:SplashForms) {
            if ($f.IsDisposed) { continue }
            foreach ($c in $f.Controls) {
                if ($c.Name -eq "main") { $c.Text = "EdgeBox 起動中" + ("." * $script:SplashDots) }
            }
        }
        Sync-SplashScreens
    })

    Sync-SplashScreens
    $timer.Start()
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
    exit 0
}

# ============================================================
#  黒背景: 指定モニターを黒いウィンドウで覆う (コンソールの余白を黒にする土台)
# ============================================================
if ($Backdrop) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ("BdApi" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class BdApi {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@
    }
    $p = $BackdropBounds -split ','
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = "None"
    $f.StartPosition = "Manual"
    $f.Bounds = New-Object System.Drawing.Rectangle([int]$p[0], [int]$p[1], [int]$p[2], [int]$p[3])
    $f.BackColor = [System.Drawing.Color]::Black
    $f.ShowInTaskbar = $false
    # (ESC では閉じない。誤操作で黒背景が消えるのを防ぐ)
    # 黒背景は「クリックが素通りし、絶対に前面に出ない」窓にする。
    # これでクリックしてもコンソールを隠さない
    # 0x08000020 = WS_EX_NOACTIVATE | WS_EX_TRANSPARENT / (-20) = GWL_EXSTYLE
    # 0x0013 = SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE / (-2) = HWND_BOTTOM
    $f.Add_Shown({ param($s, $e)
        $ex = [BdApi]::GetWindowLong($s.Handle, -20)
        [BdApi]::SetWindowLong($s.Handle, -20, ($ex -bor 0x08000020)) | Out-Null
        [BdApi]::SetWindowPos($s.Handle, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
    })
    $script:BdMiss = 0
    $bt = New-Object System.Windows.Forms.Timer
    $bt.Interval = 2000
    $bt.Add_Tick({
        if ($f.IsDisposed) { return }
        [BdApi]::SetWindowPos($f.Handle, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
        # コンソール (vmconnect) が終了したら、黒い画面だけを残さず自分も閉じる
        if (Get-Process vmconnect -ErrorAction SilentlyContinue) {
            $script:BdMiss = 0
        } else {
            $script:BdMiss++
            if ($script:BdMiss -ge 2) { [System.Windows.Forms.Application]::Exit() }
        }
    })
    $bt.Start()
    $f.Show()
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
    exit 0
}

# ============================================================
#  案内 (内部用): 右画面の右上に小さな文を数秒だけ出して、自分で閉じる
#  (見張り役の中で出すと、見張り役の都合で閉じないことがあるため別プロセスにする)
# ============================================================
if ($Notice) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $b = @(0, 0, 1920, 1080)
    try { $q = $NoticeBounds -split ','; if ($q.Count -ge 4) { $b = @([int]$q[0], [int]$q[1], [int]$q[2], [int]$q[3]) } } catch { }
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = "None"; $f.StartPosition = "Manual"; $f.TopMost = $true; $f.ShowInTaskbar = $false
    $f.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $NoticeText; $l.AutoSize = $true
    $l.ForeColor = [System.Drawing.Color]::White
    $l.Font = New-Object System.Drawing.Font("Meiryo UI", 11)
    $l.Location = New-Object System.Drawing.Point(16, 12)
    $f.Controls.Add($l)
    $f.ClientSize = New-Object System.Drawing.Size(($l.PreferredWidth + 32), ($l.PreferredHeight + 24))
    $f.Location = New-Object System.Drawing.Point(($b[0] + $b[2] - $f.Width - 20), ($b[1] + 20))
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = [Math]::Max(1000, $NoticeSec * 1000)
    $t.Add_Tick({ $t.Stop(); [System.Windows.Forms.Application]::Exit() })
    $t.Start()
    $f.Add_Click({ [System.Windows.Forms.Application]::Exit() })   # クリックでも閉じる
    $f.Show()
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
    exit 0
}

# ============================================================
#  ESC 見張り役: EdgeBox 表示用ブラウザ窓が前面・最大化のときだけ ESC で解除
# ============================================================
if ($EscWatcher) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class EscApi {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
}
"@
    $edgePids = @()
    $lastScan = [datetime]::MinValue
    while ($true) {
        if (((Get-Date) - $lastScan).TotalSeconds -gt 10) {
            $edgePids = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'FieldKiosk' } | Select-Object -ExpandProperty ProcessId)
            $lastScan = Get-Date
        }
        if (([EscApi]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
            $h = [EscApi]::GetForegroundWindow()
            $procId = [uint32]0
            [EscApi]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
            if ($edgePids -contains $procId) {
                if ([EscApi]::IsZoomed($h)) {
                    [EscApi]::ShowWindow($h, 9) | Out-Null   # 最大化 → 元のサイズに戻す
                } else {
                    # 全画面 (F11) 状態なら解除する。ウィンドウがモニター全体を覆っているかで判定
                    $r = New-Object 'EscApi+RECT'
                    [EscApi]::GetWindowRect($h, [ref]$r) | Out-Null
                    $b = [System.Windows.Forms.Screen]::FromHandle($h).Bounds
                    if ($r.Left -le $b.Left -and $r.Top -le $b.Top -and $r.Right -ge $b.Right -and $r.Bottom -ge $b.Bottom) {
                        [System.Windows.Forms.SendKeys]::SendWait("{F11}")
                    }
                }
            }
            while (([EscApi]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) { Start-Sleep -Milliseconds 50 }
        }
        Start-Sleep -Milliseconds 100
    }
    exit 0
}

# ============================================================
#  コンソール自動クローズ: EdgeBox の起動を確認したら、コンソール画面と黒背景を閉じる
#  (EdgeBox の操作は Web 管理画面で行うため、起動後のコンソールは黒い画面が残るだけになる)
# ============================================================
if ($ConsoleCloser) {
    # 起動完了の目印になる URL (管理画面) が指定されていれば、応答するまで待つ
    if ($CloserWaitUrl) {
        $responded = $false
        try {
            $uri = [Uri]$CloserWaitUrl
            $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "https") { 443 } else { 80 }
            $wsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($wsw.Elapsed.TotalSeconds -lt $TimeoutSec) {
                try {
                    $tcp = New-Object Net.Sockets.TcpClient
                    $ok = $tcp.ConnectAsync($uri.Host, $port).Wait(3000)
                    $tcp.Dispose()
                    if ($ok) { $responded = $true; break }
                } catch { }
                Start-Sleep -Seconds 5
            }
        } catch { }
        if (-not $responded) {
            Log "コンソール自動クローズ: 管理画面 ($CloserWaitUrl) の応答を確認できないため閉じません (起動の様子を確認できるよう残します)。"
            exit 0
        }
    }
    Start-Sleep -Seconds $CloserDelaySec
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not ($vm -and $vm.State -eq "Running")) {
        Log "コンソール自動クローズ: EdgeBox が実行中でないため閉じません (起動の様子を確認できるよう残します)。"
        exit 0
    }
    $procs = @(Get-Process vmconnect -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) { [void]$p.CloseMainWindow() }   # 正しく閉じて表示状態を保存させる
        $csw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($csw.Elapsed.TotalSeconds -lt 8) {
            if (-not (Get-Process vmconnect -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 500
        }
        Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # 黒背景も一緒に片付ける (自動終了の保険。通常はコンソール終了を検知して自分で閉じる)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Backdrop' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Log "コンソール自動クローズ: EdgeBox は起動済みのため、コンソール画面を閉じました (EdgeBox は動いています。見たいときはデスクトップの『EdgeBox 画面』)。"
    exit 0
}

function Stop-EscWatcher {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-EscWatcher' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Stop-LeftGuard {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-LeftGuard' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Stop-UrlRetry {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-UrlRetry' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ============================================================
#  設定ファイル
# ============================================================
$DefaultConfig = [ordered]@{
    "_説明"             = "EdgeBox 表示の設定。『EdgeBox表示設定』アイコンから編集できます。"
    "RightUrl"          = ""       # 右画面は通常の Windows デスクトップ (URL を入れるとブラウザで表示)
    "RightFullScreen"   = $false
    "LeftUrl"           = "console"
    "LeftFullScreen"    = $true
    "RightBrowserV2"    = $true    # 「右画面はデスクトップ」既定に切り替え済みの印 (旧設定ファイルの移行用)
    "EscEnabled"        = $true
    "ConsoleStripFrame" = $true
    "ConsoleAutoClose"  = $false   # コンソール窓は閉じない (閉じてほしい場合だけオン)
    "ConsoleAutoCloseV2" = $true   # 「閉じない」既定に切り替え済みの印 (旧設定ファイルの移行用)
    "ConsoleHideBar"    = $true    # 全画面時に上部の接続バー (「localhost 上の EdgeBox」の帯) を出さない
    "LeftGuard"         = $true    # 左画面をコンソールの全画面で固定 (他の窓は右へ移し、全画面が外れたら戻す)
    "LeftGuardHotkey"   = "Alt+F11" # 固定の解除/再固定に使うキー
    "StowHotkey"        = "Ctrl+Alt+K" # 長押しでコンソールを収納 (最小化) ⇔ 全画面に戻す
    "ConsoleResolution" = "自動 (モニターに合わせる)"
}
if (-not (Test-Path $ConfigFile)) {
    $DefaultConfig | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "設定ファイルを作成しました: $ConfigFile" -ForegroundColor Cyan
}
$cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
# 旧版の仮の URL (.200) が設定ファイルに残っている場合は、実機の管理画面 (.205) に置き換える。
# .200 はどの環境にも合っていない初期値だったため、残しておく理由がない
if ([string]$cfg.RightUrl -eq "https://192.168.0.200/") {
    $cfg.RightUrl = [string]$DefaultConfig["RightUrl"]
    try { $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 } catch { }
}
# 旧版は「起動後にコンソールを自動で閉じる」が既定だった。閉じないでほしいという要望により
# 既定を「閉じない」に変更。旧既定のまま残っている設定ファイルは一度だけ切り替える
if (-not $cfg.PSObject.Properties["ConsoleAutoCloseV2"]) {
    if ($cfg.PSObject.Properties["ConsoleAutoClose"]) { $cfg.ConsoleAutoClose = $false }
    else { $cfg | Add-Member -NotePropertyName ConsoleAutoClose -NotePropertyValue $false -Force }
    $cfg | Add-Member -NotePropertyName ConsoleAutoCloseV2 -NotePropertyValue $true -Force
    if (-not $cfg.PSObject.Properties["ConsoleHideBar"]) { $cfg | Add-Member -NotePropertyName ConsoleHideBar -NotePropertyValue $true -Force }
    try { $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 } catch { }
}
# 右画面のブラウザ全画面はやめ、通常の Windows デスクトップのままにする方針に変更。
# 旧既定の管理画面 URL (.205) がそのまま残っている設定ファイルは一度だけ空にする
# (『設定』で URL を入れ直せば、以前どおり右画面にブラウザを出せる)
if (-not $cfg.PSObject.Properties["RightBrowserV2"]) {
    if ([string]$cfg.RightUrl -eq "https://192.168.0.205/") {
        if ($cfg.PSObject.Properties["RightUrl"]) { $cfg.RightUrl = "" }
        else { $cfg | Add-Member -NotePropertyName RightUrl -NotePropertyValue "" -Force }
    }
    $cfg | Add-Member -NotePropertyName RightBrowserV2 -NotePropertyValue $true -Force
    try { $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8 } catch { }
}
if (-not $PSBoundParameters.ContainsKey("RightUrl")) { $RightUrl = [string]$cfg.RightUrl }
if (-not $PSBoundParameters.ContainsKey("LeftUrl"))  { $LeftUrl  = [string]$cfg.LeftUrl }
# 左右それぞれの全画面指定。設定が無い場合は旧バージョンの設定から引き継ぐ
function Get-SideFullScreen([string]$side, [string]$url) {
    $name = $side + "FullScreen"
    $v = $cfg.$name
    if ($null -ne $v) { return ($v -eq $true) }
    if ($url -match '^(console|コンソール)$') { return ($cfg.ConsoleFullScreen -ne $false) }
    return ($cfg.Kiosk -eq $true)
}
$LeftFull  = Get-SideFullScreen "Left"  $LeftUrl
$RightFull = Get-SideFullScreen "Right" $RightUrl

# ============================================================
#  左画面の見張り役 (内部用): EdgeBox のコンソール全画面を左画面に固定し、
#  左画面に出てきた他の窓は右画面へ移す。解除/再固定はホットキーだけ
# ============================================================
# ============================================================
#  管理画面の後追い (内部用): 起動時に管理画面が応答しなかった場合、
#  応答してから右画面のブラウザを開き直す (エラー画面のまま放置しない)
# ============================================================
if ($UrlRetry) {
    if (-not $RightUrl) { exit 0 }
    Log "管理画面の後追いを開始しました (応答したら右画面のブラウザを開き直します): $RightUrl"
    $deadline = (Get-Date).AddMinutes(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        if (Test-UrlOnce $RightUrl) {
            Log "管理画面が応答したため、右画面のブラウザを開き直します。"
            & $PSCommandPath -VMName $VMName -RightUrl $RightUrl -LeftUrl "" -NoSplash -KeepConsole
            exit 0
        }
    }
    Log "管理画面の後追い: 90 分待っても応答しないため終了します (『EdgeBox 再起動』で表示し直せます)。"
    exit 0
}

if ($LeftGuard) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class GuardApi {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool repaint);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr hMenu, uint uIDItem, StringBuilder s, int cch, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
    # "Alt+F11" のような指定をキーコードの一覧にする
    function ConvertTo-VKeys([string]$spec) {
        $keys = @()
        foreach ($part in ($spec -split '\+')) {
            $k = $part.Trim().ToUpperInvariant()
            if ($k -match '^(CTRL|CONTROL)$') { $keys += 0x11 }
            elseif ($k -eq 'ALT')             { $keys += 0x12 }
            elseif ($k -eq 'SHIFT')           { $keys += 0x10 }
            elseif ($k -eq 'WIN')             { $keys += 0x5B }
            elseif ($k -match '^F(\d{1,2})$') { $keys += (0x6F + [int]$Matches[1]) }
            elseif ($k -match '^[A-Z0-9]$')   { $keys += [int][char]$k }
        }
        return $keys
    }
    $hotkey = if ($cfg.LeftGuardHotkey) { [string]$cfg.LeftGuardHotkey } else { "Alt+F11" }
    $vkeys = @(ConvertTo-VKeys $hotkey)
    if ($vkeys.Count -eq 0) { $vkeys = @(0x12, 0x7A); $hotkey = "Alt+F11" }
    # 収納/再表示のキー (長押し)。コンソール窓を最小化して左画面を Windows に明け渡し、もう一度で全画面に戻す
    $stowHotkey = if ($cfg.StowHotkey) { [string]$cfg.StowHotkey } else { "Ctrl+Alt+K" }
    $stowKeys = @(ConvertTo-VKeys $stowHotkey)
    if ($stowKeys.Count -eq 0) { $stowKeys = @(0x11, 0x12, 0x4B); $stowHotkey = "Ctrl+Alt+K" }
    $HoldMs = 1000   # 長押しとみなす時間 (ESC / 収納キー 共通)

    $screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
    if ($screens.Count -lt 2) { Log "左画面の見張り役: モニターが 1 枚のため何もしません。"; exit 0 }
    $left = $screens[0].Bounds; $right = $screens[-1].Bounds
    Log "左画面の見張り役を開始しました (解除/再固定: $hotkey / 収納⇔全画面: $stowHotkey 長押し)。"

    function Get-ConsoleMain {
        $p = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return [IntPtr]$p.MainWindowHandle } else { return [IntPtr]::Zero }
    }
    function Find-MenuId([IntPtr]$menu, [string]$pattern, [int]$depth) {
        if ($depth -gt 3) { return -1 }
        $n = [GuardApi]::GetMenuItemCount($menu)
        for ($i = 0; $i -lt $n; $i++) {
            $sb = New-Object System.Text.StringBuilder 256
            $id = [GuardApi]::GetMenuItemID($menu, $i)
            [GuardApi]::GetMenuString($menu, [uint32]$i, $sb, 256, 0x400) | Out-Null    # 0x400 = MF_BYPOSITION
            if ($id -ne [uint32]::MaxValue -and $sb.ToString() -match $pattern) { return [int]$id }
            $sub = [GuardApi]::GetSubMenu($menu, $i)
            if ($sub -ne [IntPtr]::Zero) { $r = Find-MenuId $sub $pattern ($depth + 1); if ($r -ge 0) { return $r } }
        }
        return -1
    }
    # vmconnect の見えているトップレベルの窓 (本体と、全画面のときに RDP 部品が作る枠なしの窓)
    function Get-ConsoleTopWindows {
        return @(Get-ConsoleWindows | Where-Object { $_.Hwnd -ne [IntPtr]::Zero -and $_.Parent -eq [IntPtr]::Zero -and $_.Visible } |
                 ForEach-Object { [IntPtr]$_.Hwnd })
    }
    # モニター $b を全画面で覆っている vmconnect の窓 (Test-ConsoleFullScreenOn と同じ見分け方)。無ければ Zero
    function Get-ConsoleFullScreenWindow($b) {
        foreach ($w in Get-ConsoleWindows) {
            if ($w.Hwnd -eq [IntPtr]::Zero -or $w.Parent -ne [IntPtr]::Zero -or -not $w.Visible) { continue }
            if ($w.Left -gt ($b.X + 4) -or $w.Right -lt ($b.X + $b.Width - 4) -or $w.Bottom -lt ($b.Y + $b.Height - 4)) { continue }
            if (-not $w.HasCaption -and $w.Top -le ($b.Y + 4)) { return [IntPtr]$w.Hwnd }
            if ($w.HasCaption -and $w.Top -le ($b.Y - 20)) { return [IntPtr]$w.Hwnd }
        }
        return [IntPtr]::Zero
    }
    # 前面化 (本体側の Force-Foreground と同じ手順)。見張り役は自分の窓を持たないので、
    # ALT の疑似押下で前面化のブロックを避け、駄目なら前面の窓のスレッドに入力を相乗りさせて前面化する
    function Set-GuardForeground([IntPtr]$h) {
        for ($i = 0; $i -lt 3; $i++) {
            [GuardApi]::keybd_event(0x12, 0, 0, 0)
            [GuardApi]::SetForegroundWindow($h) | Out-Null
            [GuardApi]::keybd_event(0x12, 0, 2, 0)
            Start-Sleep -Milliseconds 300
            if ([GuardApi]::GetForegroundWindow() -eq $h) { return $true }
            try {
                $fg = [GuardApi]::GetForegroundWindow()
                $procId = [uint32]0
                $fgThread = [GuardApi]::GetWindowThreadProcessId($fg, [ref]$procId); $my = [GuardApi]::GetCurrentThreadId()
                [GuardApi]::AttachThreadInput($my, $fgThread, $true) | Out-Null
                [GuardApi]::BringWindowToTop($h) | Out-Null
                [GuardApi]::SetForegroundWindow($h) | Out-Null
                [GuardApi]::AttachThreadInput($my, $fgThread, $false) | Out-Null
            } catch { }
            Start-Sleep -Milliseconds 300
            if ([GuardApi]::GetForegroundWindow() -eq $h) { return $true }
        }
        return ([GuardApi]::GetForegroundWindow() -eq $h)
    }
    # キーボードフォーカスを映像の入力窓へ移し、Ctrl+Alt+Break を 1 回送る (Ctrl+Alt+Break はその窓で受け付けられる)。
    # 偶数回目は SendKeys で送る (本体側と同じく、環境によって効く方が違うため交互に試す)
    function Send-GuardCtrlAltBreak([IntPtr]$h, [int]$try) {
        try {
            $ih = Get-ConsoleInputWindow; if ($ih -eq [IntPtr]::Zero) { $ih = $h }
            $procId = [uint32]0
            $t = [GuardApi]::GetWindowThreadProcessId($ih, [ref]$procId); $my = [GuardApi]::GetCurrentThreadId()
            [GuardApi]::AttachThreadInput($my, $t, $true) | Out-Null
            [GuardApi]::SetFocus($ih) | Out-Null
            [GuardApi]::AttachThreadInput($my, $t, $false) | Out-Null
            Start-Sleep -Milliseconds 100
        } catch { }
        if (($try % 2) -eq 0) {
            try { [System.Windows.Forms.SendKeys]::SendWait("^%{BREAK}"); return } catch { }
        }
        # Ctrl+Alt+Break。Break は実際のキーと同じ「VK_CANCEL (0x03) + 拡張スキャンコード 0x46」で送る
        [GuardApi]::keybd_event(0x11, 0, 0, 0); [GuardApi]::keybd_event(0x12, 0, 0, 0)
        [GuardApi]::keybd_event(0x03, 0x46, 1, 0)
        Start-Sleep -Milliseconds 60
        [GuardApi]::keybd_event(0x03, 0x46, 3, 0)
        [GuardApi]::keybd_event(0x12, 0, 2, 0); [GuardApi]::keybd_event(0x11, 0, 2, 0)
    }
    function Invoke-FullScreenToggle([IntPtr]$h) {
        # メニュー『全画面』を WM_COMMAND で直接実行 (フォーカス不要)。無ければ Ctrl+Alt+Break を送る
        $menu = [GuardApi]::GetMenu($h)
        if ($menu -ne [IntPtr]::Zero) {
            $id = Find-MenuId $menu '全画面|Full' 0
            if ($id -ge 0) { [GuardApi]::PostMessage($h, 0x0111, [IntPtr]$id, [IntPtr]::Zero) | Out-Null; return }
        }
        Set-GuardForeground $h | Out-Null
        Send-GuardCtrlAltBreak $h 1
    }
    # 全画面を解除する (ESC 長押し・ホットキー用)。1 回送って終わりにせず、解除できたかを確かめて繰り返す。
    # 全画面のときは本体の窓ではなく「モニターを覆っている窓」を前面にしてからキーを送る
    # (RDP 部品が別の窓で全画面にしている環境では、本体の窓を前面にしてもキーが届かなかった)。
    # それでも解除できなければ、最後の手段としてコンソール窓を最小化 (収納) して左画面を明け渡す。
    # 戻り値: "解除" / "収納" / "" (どちらもできなかった)
    function Exit-GuardFullScreen([IntPtr]$h) {
        for ($try = 1; $try -le 4; $try++) {
            if (-not (Test-ConsoleFullScreenOn $left)) { return "解除" }
            $target = Get-ConsoleFullScreenWindow $left
            if ($target -eq [IntPtr]::Zero) { $target = $h }
            if ($try -eq 1) {
                # 本体側と同じく、まず Win32 メニューの『全画面』を WM_COMMAND で試す (フォーカス不要)
                $menu = [GuardApi]::GetMenu($h)
                if ($menu -ne [IntPtr]::Zero) {
                    $id = Find-MenuId $menu '全画面|Full' 0
                    if ($id -ge 0) {
                        [GuardApi]::PostMessage($h, 0x0111, [IntPtr]$id, [IntPtr]::Zero) | Out-Null
                        Start-Sleep -Milliseconds 1000
                        if (-not (Test-ConsoleFullScreenOn $left)) { return "解除" }
                    }
                }
            }
            $fgOk = Set-GuardForeground $target
            Send-GuardCtrlAltBreak $target $try
            Start-Sleep -Milliseconds 1200
            if (-not (Test-ConsoleFullScreenOn $left)) { return "解除" }
            if ($try -eq 1 -or $try -eq 3) {
                Log ("左画面の見張り役: 全画面の解除がまだ効きません (試行 $try / 前面化=" + $(if ($fgOk) { "成功" } else { "失敗" }) + ")。窓: " + (Get-ConsoleTopWindowDiag))
            }
        }
        # 最後の手段: 収納 (最小化)。全画面のまま最小化されるので、戻すときは復元するだけで全画面に戻る
        Log "左画面の見張り役: 全画面の切り替えが効かないため、コンソール窓を収納 (最小化) して左画面を明け渡します。"
        if (Set-GuardStowed $true) { return "収納" }
        return ""
    }
    # 収納 (最小化) ⇔ 復元。全画面のときに RDP 部品が別の窓を作る環境にも備えて、見えているトップレベルの窓すべてに掛ける
    function Set-GuardStowed([bool]$stow) {
        $wins = @(Get-ConsoleTopWindows)
        $main = Get-ConsoleMain
        if ($main -ne [IntPtr]::Zero -and ($wins -notcontains $main)) { $wins += $main }
        if ($wins.Count -eq 0) { return $false }
        if ($stow) {
            foreach ($w in $wins) { [GuardApi]::ShowWindow($w, 6) | Out-Null }   # SW_MINIMIZE
            Start-Sleep -Milliseconds 400
            $m = Get-ConsoleMain
            return ($m -eq [IntPtr]::Zero -or [GuardApi]::IsIconic($m))
        }
        foreach ($w in $wins) { if ([GuardApi]::IsIconic($w)) { [GuardApi]::ShowWindow($w, 9) | Out-Null } }   # SW_RESTORE
        Start-Sleep -Milliseconds 400
        $m = Get-ConsoleMain
        if ($m -ne [IntPtr]::Zero) {
            $fs = Get-ConsoleFullScreenWindow $left
            Set-GuardForeground $(if ($fs -ne [IntPtr]::Zero) { $fs } else { $m }) | Out-Null
        }
        return $true
    }
    # キーが離されるまで待つ (最長 $maxMs)。押しっぱなしで何度も切り替わらないようにするための待ち。
    # コンソールの中にフォーカスが移ると離した合図が見張り役に届かないことがあるため、待ちに上限を設ける
    function Wait-KeysUp([int[]]$keys, [int]$maxMs) {
        $t0 = Get-Date
        while (((Get-Date) - $t0).TotalMilliseconds -lt $maxMs) {
            $any = $false
            foreach ($vk in $keys) { if (([GuardApi]::GetAsyncKeyState($vk) -band 0x8000) -ne 0) { $any = $true; break } }
            if (-not $any) { return }
            Start-Sleep -Milliseconds 50
        }
    }
    function Show-Notice([string]$text) {
        # 右画面の右上に約 5 秒だけ出す小さな案内 (別プロセスが自分で閉じる)
        try {
            $bounds = "{0},{1},{2},{3}" -f $right.X, $right.Y, $right.Width, $right.Height
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
                "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Notice -NoticeSec 5 " +
                "-NoticeText `"$text`" -NoticeBounds `"$bounds`"")
        } catch { }
    }

    $script:HiddenBars = @{}
    $script:GuardStart = Get-Date; $script:BarDiagDone = $false
    function Hide-GuardBar {
        # 全画面のときに上部へ出る接続バーが見えていれば隠す (形で判断: 共通の Find-ConsoleBarWindows)
        try {
            $main = Get-ConsoleMain
            if ($main -eq [IntPtr]::Zero) { return }
            foreach ($w in Find-ConsoleBarWindows $left $main) {
                if ($w.Hwnd -eq [IntPtr]::Zero) { continue }
                [BarFinder]::ShowWindow($w.Hwnd, 0) | Out-Null
                $key = [string]$w.Hwnd
                if (-not $script:HiddenBars.ContainsKey($key)) {
                    $script:HiddenBars[$key] = $true
                    Log ("左画面の見張り役: 上部の接続バーを隠しました (" + (Format-ConsoleWindow $w) + ")。")
                }
            }
            # 開始から 30 秒たっても一度も見つからなければ、手掛かりを 1 回だけ記録する
            if ($script:HiddenBars.Count -eq 0 -and -not $script:BarDiagDone -and ((Get-Date) - $script:GuardStart).TotalSeconds -gt 30) {
                $script:BarDiagDone = $true
                if (Test-ConsoleFullScreenOn $left) {
                    Log ("左画面の見張り役: [診断] 接続バーが見つかりません。vmconnect の見えている窓: " + (Get-ConsoleWindowDiag $left))
                }
            }
        } catch { }
    }
    $hideBar = ($cfg.ConsoleHideBar -ne $false)
    if ($hideBar) { try { Get-ConsoleWindows | Out-Null } catch { Log ("左画面の見張り役: 接続バー探しの準備に失敗しました: " + $_.Exception.Message); $hideBar = $false } }

    $released = $false
    $helperPids = @(); $lastScan = [datetime]::MinValue
    $lastFs = [datetime]::MinValue; $notCover = 0
    $fsFail = 0   # 全画面に戻せなかった回数 (3 回続いたら 30 秒に 1 回に広げる。あきらめはしない)
    $missingSince = $null; $lastRelaunch = [datetime]::MinValue   # コンソール窓が閉じられたときの立て直し用
    $lastCtrlAlt = [datetime]::MinValue   # Ctrl+Alt を押していた時刻 (自分で Ctrl+Alt+Break を押した解除を見分ける)
    $escSince = $null                     # ESC を押し始めた時刻 (長押しの判定)
    $stowSince = $null                    # 収納キーを押し始めた時刻 (長押しの判定)
    $stowed = $false                      # 収納中 (コンソール窓を最小化して左画面を明け渡している)
    $lastErrLog = [datetime]::MinValue
    $tick = 0
    function Test-ConsoleForeground {
        # 前面の窓が vmconnect のものか
        try {
            $fg = [GuardApi]::GetForegroundWindow()
            if ($fg -eq [IntPtr]::Zero) { return $false }
            $fgPid = [uint32]0
            [GuardApi]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
            return (@(Get-Process vmconnect -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id }) -contains $fgPid)
        } catch { return $false }
    }
    while ($true) {
        try {
            # ホットキーは 0.1 秒ごとに見る (短い押下も取りこぼさない)。窓の見回りは 0.5 秒ごと
            $tick++
            # --- 自分で解除する操作を見分ける ---
            # (a) Ctrl+Alt を押している間 (Ctrl+Alt+Break を自分で押した) の解除は自動で戻さない
            if ((([GuardApi]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0) -and (([GuardApi]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0)) { $lastCtrlAlt = Get-Date }
            # (b) 全画面中に ESC を 1 秒長押し → 解除して、自動では戻さない。再固定は $hotkey
            #     Windows 側 (右画面のアプリなど) を操作しているときに効く。コンソールの中にキー入力が
            #     入っている間は vmconnect がキーを EdgeBox へ渡して横取りするため、見張り役からは見えない。
            #     普通の ESC (短押し) は Windows のアプリでよく使うので、長押しだけを合図にする
            #     固定を解除したあとに窓の最大化ボタンで最大化した場合も、ESC 長押しで最大化を解除する
            #     切り替えのキーは ESC を離してから送る (ESC を押したまま送ると、押しっぱなしの ESC が
            #     前面にしたコンソールへ流れ込み、Ctrl+Alt+Break が組み合わせとして成立しないことがあった)。
            #     1 回送って終わりにせず、解除できたかを確かめて繰り返し、駄目なら収納 (最小化) で明け渡す
            if (([GuardApi]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0) {
                if (-not $escSince) { $escSince = Get-Date }
                elseif (((Get-Date) - $escSince).TotalMilliseconds -ge $HoldMs) {
                    Wait-KeysUp @(0x1B) 3000
                    $escSince = $null
                    $h = Get-ConsoleMain
                    if ($h -ne [IntPtr]::Zero -and (Test-ConsoleFullScreenOn $left)) {
                        $released = $true
                        $how = Exit-GuardFullScreen $h
                        if ($how -eq "解除") {
                            Show-Notice "ESC 長押しで左画面の固定を解除しました ($hotkey でもう一度固定)"
                            Log "左画面の見張り役: ESC 長押しにより固定を解除しました (自動では戻しません。再固定は $hotkey)。"
                        } elseif ($how -eq "収納") {
                            $stowed = $true
                            Show-Notice "ESC 長押し: 全画面の解除が効かないため、コンソールを収納しました ($stowHotkey 長押しで戻す)"
                            Log "左画面の見張り役: ESC 長押し: 全画面を解除できなかったため、コンソールを収納 (最小化) しました (戻すには $stowHotkey 長押し / $hotkey)。"
                        } else {
                            Show-Notice "ESC 長押し: 全画面を解除できませんでした ($hotkey で固定の解除/再固定)"
                            Log ("左画面の見張り役: ESC 長押し: 全画面を解除できませんでした (固定は解除扱い。再固定は $hotkey)。窓: " + (Get-ConsoleTopWindowDiag))
                        }
                    } elseif ($h -ne [IntPtr]::Zero -and [GuardApi]::IsZoomed($h)) {
                        $released = $true
                        [GuardApi]::ShowWindow($h, 9) | Out-Null   # 最大化 → 元の大きさ
                        Show-Notice "ESC 長押しでコンソールの最大化を解除しました ($hotkey で全画面に固定)"
                        Log "左画面の見張り役: ESC 長押しにより最大化を解除しました (再固定は $hotkey)。"
                    }
                }
            } else { $escSince = $null }
            # (c) 収納キー ($stowHotkey) を 1 秒長押し → コンソール窓を収納 (最小化) して左画面を Windows に明け渡す。
            #     もう一度長押し → 窓を戻し、左画面の全画面に固定し直す (全画面のまま最小化されていれば復元だけで戻る。
            #     外れていれば見張り役が全画面に戻す)。ESC と同じく Windows 側を操作しているときに効く
            $stowDown = $true
            foreach ($vk in $stowKeys) { if (([GuardApi]::GetAsyncKeyState($vk) -band 0x8000) -eq 0) { $stowDown = $false; break } }
            if ($stowDown) {
                if (-not $stowSince) { $stowSince = Get-Date }
                elseif (((Get-Date) - $stowSince).TotalMilliseconds -ge $HoldMs) {
                    Wait-KeysUp $stowKeys 3000
                    $stowSince = $null
                    $h = Get-ConsoleMain
                    if ($h -eq [IntPtr]::Zero) {
                        Show-Notice "コンソール窓が見つかりません (『EdgeBox 画面』で表示し直せます)"
                        Log "左画面の見張り役: $stowHotkey 長押し: コンソール窓が見つからないため何もしません。"
                    } elseif (-not $stowed -and -not [GuardApi]::IsIconic($h)) {
                        if (Set-GuardStowed $true) {
                            $stowed = $true; $released = $true
                            Show-Notice "コンソールを収納しました ($stowHotkey 長押しで全画面に戻す)"
                            Log "左画面の見張り役: $stowHotkey 長押しによりコンソールを収納 (最小化) しました (戻すには $stowHotkey 長押し)。"
                        } else {
                            Show-Notice "コンソールを収納できませんでした"
                            Log ("左画面の見張り役: $stowHotkey 長押し: コンソールを収納 (最小化) できませんでした。窓: " + (Get-ConsoleTopWindowDiag))
                        }
                    } else {
                        Set-GuardStowed $false | Out-Null
                        $stowed = $false; $released = $false
                        $notCover = 3; $lastFs = [datetime]::MinValue   # 全画面が外れていれば次の見回りで戻す
                        Show-Notice "コンソールを左画面の全画面に戻します ($stowHotkey 長押しで収納)"
                        Log "左画面の見張り役: $stowHotkey 長押しによりコンソールを戻し、左画面の全画面に固定します。"
                    }
                }
            } else { $stowSince = $null }
            # --- ホットキー: 固定の解除 ⇔ 再固定 ---
            $allDown = $true
            foreach ($vk in $vkeys) { if (([GuardApi]::GetAsyncKeyState($vk) -band 0x8000) -eq 0) { $allDown = $false; break } }
            if ($allDown) {
                $released = -not $released
                $h = Get-ConsoleMain
                if ($released) {
                    if ($h -ne [IntPtr]::Zero -and (Test-ConsoleFullScreenOn $left)) {
                        $how = Exit-GuardFullScreen $h
                        if ($how -eq "収納") { $stowed = $true }
                    }
                    Show-Notice "左画面の固定を解除しました ($hotkey でもう一度固定)"
                    Log "左画面の見張り役: $hotkey により固定を解除しました。"
                } else {
                    if ($stowed -or ($h -ne [IntPtr]::Zero -and [GuardApi]::IsIconic($h))) { Set-GuardStowed $false | Out-Null }
                    $stowed = $false
                    Show-Notice "左画面を EdgeBox の全画面で固定しました ($hotkey で解除)"
                    Log "左画面の見張り役: $hotkey により固定に戻しました。"
                    $notCover = 3; $lastFs = [datetime]::MinValue
                }
                # キーが離されるまで待つ (押しっぱなしで何度も切り替わらないように)
                Wait-KeysUp $vkeys 5000
            }
            if (-not $released -and ($tick % 5) -eq 0) {
                # 自分たちの補助ウィンドウ (起動中画面・黒背景) は動かさない。PID を 10 秒ごとに更新
                if (((Get-Date) - $lastScan).TotalSeconds -gt 10) {
                    $helperPids = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match '03-field-display-kiosk' } | Select-Object -ExpandProperty ProcessId)
                    $lastScan = Get-Date
                }
                # 1) コンソールの全画面が外れていたら左画面の全画面に戻す
                #    (最大化しただけの窓は「全画面」とみなさない: 共通の Test-ConsoleFullScreenOn で判定)
                $h = Get-ConsoleMain
                if ($h -eq [IntPtr]::Zero) {
                    # 0) コンソール窓そのものが閉じられた → EdgeBox が動いていれば表示を立ち上げ直す
                    #    (自動で閉じる設定のときは閉じたままにする。2 分に 1 回まで)
                    if (-not $missingSince) { $missingSince = Get-Date }
                    elseif (((Get-Date) - $missingSince).TotalSeconds -gt 15 -and ((Get-Date) - $lastRelaunch).TotalSeconds -gt 120 -and
                            ($cfg.ConsoleAutoClose -ne $true)) {
                        $vmState = ""
                        try { $vmState = [string](Get-VM -Name $VMName -ErrorAction Stop).State } catch { }
                        if ($vmState -eq "Running") {
                            $lastRelaunch = Get-Date; $missingSince = $null
                            Log "左画面の見張り役: コンソール窓が閉じられていたため、左画面の表示を立ち上げ直します。"
                            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
                                "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`" -LeftUrl console -RightUrl `"`" -NoSplash -KeepConsole")
                            Start-Sleep -Seconds 20   # 立ち上げ直し (この見張り役も入れ替わる) の間は何もしない
                        }
                    }
                } else { $missingSince = $null }
                if ($h -ne [IntPtr]::Zero -and [GuardApi]::IsIconic($h)) {
                    # 最小化されていたら戻す (最小化も「全画面が外れた」扱い)
                    [GuardApi]::ShowWindow($h, 9) | Out-Null
                    Start-Sleep -Milliseconds 300
                    Log "左画面の見張り役: 最小化されていたコンソールを戻します。"
                }
                if ($h -ne [IntPtr]::Zero -and -not [GuardApi]::IsIconic($h)) {
                    if ((Test-ConsoleFullScreenOn $left) -or (Test-ConsoleFramelessOn $left)) { $notCover = 0; $fsFail = 0 }   # 全画面か、代替表示 (枠なし中央表示) ならそのまま
                    else {
                        # ブラウザや他アプリがフォーカスを奪うと vmconnect の全画面が外れることがある。
                        # 連続 2 回確認・6 秒に 1 回まで、素早く左画面の全画面に戻す。
                        # 3 回続けて戻せなければ (切り替えが効かない状態)、30 秒に 1 回に広げて試し続ける
                        $notCover++
                        if ($notCover -eq 2 -and ((Get-Date) - $lastCtrlAlt).TotalSeconds -lt 3) {
                            # 自分で Ctrl+Alt+Break を押して解除した → 固定を解除扱いにして戻さない
                            $released = $true; $notCover = 0
                            Show-Notice "全画面を自分で解除したため、自動では戻しません ($hotkey で再固定)"
                            Log "左画面の見張り役: Ctrl+Alt+Break による解除を検出したため、自動では戻しません (再固定は $hotkey)。"
                            continue
                        }
                        $interval = if ($fsFail -ge 3) { 30 } else { 6 }
                        if ($notCover -ge 2 -and ((Get-Date) - $lastFs).TotalSeconds -gt $interval) {
                            if (Test-ConsoleFullScreenOn $right) { Invoke-FullScreenToggle $h; Start-Sleep -Milliseconds 800 }   # 右で全画面 → いったん解除
                            $h2 = Get-ConsoleMain; if ($h2 -ne [IntPtr]::Zero) { $h = $h2 }
                            [GuardApi]::ShowWindow($h, 9) | Out-Null
                            [GuardApi]::MoveWindow($h, $left.X, $left.Y, 900, 700, $true) | Out-Null
                            Start-Sleep -Milliseconds 300
                            Invoke-FullScreenToggle $h
                            Start-Sleep -Milliseconds 1500
                            $lastFs = Get-Date; $notCover = 0
                            if (Test-ConsoleFullScreenOn $left) {
                                $fsFail = 0
                                Log "左画面の見張り役: コンソールを左画面の全画面に戻しました。"
                            } else {
                                $fsFail++
                                if ($fsFail -le 3) {
                                    Log ("左画面の見張り役: コンソールを全画面に戻せませんでした ($fsFail 回目)。窓: " + (Get-ConsoleTopWindowDiag))
                                }
                                if ($fsFail -eq 3) { Log "左画面の見張り役: 3 回続けて戻せなかったため、以後は 30 秒に 1 回試します。" }
                            }
                        }
                    }
                }
                if ($hideBar) { Hide-GuardBar }
                # 2) 左画面に出てきた他の窓を右画面へ (大きさは保ち、最大化は右画面で最大化し直す)
                foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
                    $hw = [IntPtr]$p.MainWindowHandle
                    if ($hw -eq $h -or $p.ProcessName -eq 'vmconnect' -or ($helperPids -contains $p.Id)) { continue }
                    if (-not [GuardApi]::IsWindowVisible($hw) -or [GuardApi]::IsIconic($hw)) { continue }
                    $r = New-Object 'GuardApi+RECT'
                    if (-not [GuardApi]::GetWindowRect($hw, [ref]$r)) { continue }
                    $cx = [int](($r.Left + $r.Right) / 2); $cy = [int](($r.Top + $r.Bottom) / 2)
                    if ($cx -lt $left.X -or $cx -ge ($left.X + $left.Width) -or $cy -lt $left.Y -or $cy -ge ($left.Y + $left.Height)) { continue }
                    $zoomed = [GuardApi]::IsZoomed($hw)
                    if ($zoomed) {
                        [GuardApi]::ShowWindow($hw, 9) | Out-Null
                        Start-Sleep -Milliseconds 150
                        [GuardApi]::GetWindowRect($hw, [ref]$r) | Out-Null
                    }
                    $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
                    if ($w -gt $right.Width) { $w = $right.Width }
                    if ($hgt -gt $right.Height) { $hgt = $right.Height }
                    $nx = $right.X + [Math]::Max(0, [Math]::Min($r.Left - $left.X, $right.Width - $w))
                    $ny = $right.Y + [Math]::Max(0, [Math]::Min($r.Top - $left.Y, $right.Height - $hgt))
                    [GuardApi]::MoveWindow($hw, $nx, $ny, $w, $hgt, $true) | Out-Null
                    if ($zoomed) { Start-Sleep -Milliseconds 150; [GuardApi]::ShowWindow($hw, 3) | Out-Null }
                    Log ("左画面の見張り役: 『{0}』({1}) を右画面へ移しました。" -f $p.MainWindowTitle, $p.ProcessName)
                }
            }
        } catch {
            # 見回りの中で例外が起きても止まらない。原因が分かるように 1 分に 1 回だけ記録する
            if (((Get-Date) - $lastErrLog).TotalSeconds -gt 60) { $lastErrLog = Get-Date; Log ("左画面の見張り役: [診断] 見回り中のエラー: " + $_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 100
    }
}

# ============================================================
#  コンソール (EdgeBox) の画面解像度
# ============================================================
$ResolutionChoices = @(
    "自動 (モニターに合わせる)",
    "1920x1080", "1920x1200", "1680x1050", "1600x900",
    "1440x900", "1366x768", "1280x1024", "1280x720", "1024x768"
)

# 「1920x1080」「自動」などの文字列を幅・高さに解決する。解釈できなければ $null
function Resolve-ResolutionText([string]$text) {
    $t = ([string]$text).Trim()
    if (-not $t) { return $null }
    if ($t -match '^(auto|自動)') {
        Add-Type -AssemblyName System.Windows.Forms
        $b = (@([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })[0]).Bounds
        return [pscustomobject]@{ W = $b.Width; H = $b.Height }
    }
    if ($t -match '^(\d{3,5})\s*[xX×*]\s*(\d{3,5})$') {
        return [pscustomobject]@{ W = [int]$Matches[1]; H = [int]$Matches[2] }
    }
    return $null
}

# 解像度を EdgeBox に適用する。実行中なら再起動が要るので、その扱いを $OnRunning で決める
#   "ask" = 確認ダイアログ / "skip" = 何もしない
function Set-ConsoleResolution([int]$w, [int]$h, [string]$OnRunning = "skip") {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return "登録 '$VMName' が見つからないため、解像度は反映していません。" }
    if ($vm.State -eq "Off") {
        Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
        return "コンソールの解像度を ${w}x${h} にしました。"
    }
    if ($OnRunning -ne "ask") {
        return "EdgeBox が動作中のため、解像度 ${w}x${h} は保存だけしました (次回停止時に反映)。"
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "コンソールの解像度を ${w}x${h} にするには、EdgeBox をいったん終了して起動し直す必要があります。`n`n" +
        "今すぐ再起動しますか?`n" +
        "[はい]    EdgeBox を正常終了 → 解像度を変更 → 起動し直す`n" +
        "[いいえ]  設定だけ保存する (次に EdgeBox を起動したときに反映)",
        "EdgeBox 表示設定",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
        return "設定だけ保存しました。次に EdgeBox を起動したときに ${w}x${h} で表示されます。"
    }
    Stop-VM -Name $VMName            # ACPI シャットダウン要求 (強制電源断ではない)
    $wsw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($wsw.Elapsed.TotalSeconds -lt 180) {
        if ((Get-VM -Name $VMName).State -eq "Off") { break }
        Start-Sleep -Seconds 3
    }
    if ((Get-VM -Name $VMName).State -ne "Off") {
        return "EdgeBox が3分以内に停止しませんでした。解像度は変更していません (強制終了はしていません)。"
    }
    Set-VMVideo -VMName $VMName -ResolutionType Single -HorizontalResolution $w -VerticalResolution $h
    Start-VM -Name $VMName
    return "解像度を ${w}x${h} にして EdgeBox を起動し直しました。"
}

# ============================================================
#  設定コンソール (GUI)
# ============================================================
if ($Settings) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "EdgeBox 表示設定"
    $form.Size = New-Object System.Drawing.Size(600, 505)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    function New-Label($text, $x, $y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
        return $l
    }

    # --- モニター表示 ---
    $grpMon = New-Object System.Windows.Forms.GroupBox
    $grpMon.Text = "モニター表示 (URL を入力 / console = EdgeBox のコンソール画面 / 空欄 = 表示しない)"
    $grpMon.Location = New-Object System.Drawing.Point(15, 15)
    $grpMon.Size = New-Object System.Drawing.Size(555, 130)

    $grpMon.Controls.Add((New-Label "左モニター:" 15 30))
    $tbL = New-Object System.Windows.Forms.TextBox
    $tbL.Location = New-Object System.Drawing.Point(110, 27)
    $tbL.Size = New-Object System.Drawing.Size(330, 24)
    $tbL.Text = [string]$cfg.LeftUrl
    $grpMon.Controls.Add($tbL)

    $cbLF = New-Object System.Windows.Forms.CheckBox
    $cbLF.Text = "全画面"
    $cbLF.Location = New-Object System.Drawing.Point(455, 29)
    $cbLF.Size = New-Object System.Drawing.Size(85, 24)
    $cbLF.Checked = $LeftFull
    $grpMon.Controls.Add($cbLF)

    $grpMon.Controls.Add((New-Label "右モニター:" 15 65))
    $tbR = New-Object System.Windows.Forms.TextBox
    $tbR.Location = New-Object System.Drawing.Point(110, 62)
    $tbR.Size = New-Object System.Drawing.Size(330, 24)
    $tbR.Text = [string]$cfg.RightUrl
    $grpMon.Controls.Add($tbR)

    $cbRF = New-Object System.Windows.Forms.CheckBox
    $cbRF.Text = "全画面"
    $cbRF.Location = New-Object System.Drawing.Point(455, 64)
    $cbRF.Size = New-Object System.Drawing.Size(85, 24)
    $cbRF.Checked = $RightFull
    $grpMon.Controls.Add($cbRF)

    $lblMon = New-Label "全画面 = 枠なしで画面全体 (タスクバーも隠れる) / チェックなし = 最大化ウィンドウ" 15 98
    $lblMon.ForeColor = [System.Drawing.Color]::DimGray
    $grpMon.Controls.Add($lblMon)
    $form.Controls.Add($grpMon)

    # --- 操作 ---
    $grpOp = New-Object System.Windows.Forms.GroupBox
    $grpOp.Text = "操作"
    $grpOp.Location = New-Object System.Drawing.Point(15, 155)
    $grpOp.Size = New-Object System.Drawing.Size(555, 120)
    $cbEsc = New-Object System.Windows.Forms.CheckBox
    $cbEsc.Text = "ESC キーでブラウザの最大化を解除する (ブラウザ画面が前面のときのみ)"
    $cbEsc.Location = New-Object System.Drawing.Point(15, 25)
    $cbEsc.Size = New-Object System.Drawing.Size(530, 24)
    $cbEsc.Checked = ($cfg.EscEnabled -ne $false)
    $grpOp.Controls.Add($cbEsc)

    $cbSF = New-Object System.Windows.Forms.CheckBox
    $cbSF.Text = "コンソールの全画面が効かないときは、黒背景の上に中央表示する (代替の全画面)"
    $cbSF.Location = New-Object System.Drawing.Point(15, 55)
    $cbSF.Size = New-Object System.Drawing.Size(530, 24)
    $cbSF.Checked = ($cfg.ConsoleStripFrame -ne $false)
    $grpOp.Controls.Add($cbSF)

    $cbAC = New-Object System.Windows.Forms.CheckBox
    $cbAC.Text = "EdgeBox の起動を確認したら、コンソール画面を自動で閉じる (通常はオフ。閉じても EdgeBox は動き続ける)"
    $cbAC.Location = New-Object System.Drawing.Point(15, 85)
    $cbAC.Size = New-Object System.Drawing.Size(530, 24)
    $cbAC.Checked = ($cfg.ConsoleAutoClose -eq $true)
    $grpOp.Controls.Add($cbAC)
    $form.Controls.Add($grpOp)

    # --- コンソールの表示サイズ ---
    $grpRes = New-Object System.Windows.Forms.GroupBox
    $grpRes.Text = "コンソールの表示サイズ (EdgeBox 側の画面解像度)"
    $grpRes.Location = New-Object System.Drawing.Point(15, 285)
    $grpRes.Size = New-Object System.Drawing.Size(555, 115)

    # このチェック 1 つで「解像度をモニターに合わせる」+「コンソール側を全画面」がまとまる
    $cbFit = New-Object System.Windows.Forms.CheckBox
    $cbFit.Text = "モニターいっぱいに全画面表示する (解像度をモニターに合わせ、全画面にする)"
    $cbFit.Location = New-Object System.Drawing.Point(15, 25)
    $cbFit.Size = New-Object System.Drawing.Size(530, 24)
    $resCur = [string]$cfg.ConsoleResolution
    $consoleFull = if ($LeftUrl -match '^(console|コンソール)$') { $LeftFull }
                   elseif ($RightUrl -match '^(console|コンソール)$') { $RightFull }
                   else { $false }
    $cbFit.Checked = (((-not $resCur) -or ($resCur -match '^(auto|自動)')) -and $consoleFull)
    $grpRes.Controls.Add($cbFit)

    $grpRes.Controls.Add((New-Label "解像度:" 15 58))
    $cmbRes = New-Object System.Windows.Forms.ComboBox
    $cmbRes.Location = New-Object System.Drawing.Point(85, 55)
    $cmbRes.Size = New-Object System.Drawing.Size(220, 24)
    $cmbRes.DropDownStyle = "DropDown"        # 一覧から選ぶほか、直接入力もできる
    $cmbRes.Items.AddRange($ResolutionChoices)
    $cmbRes.Text = if ($cfg.ConsoleResolution) { [string]$cfg.ConsoleResolution } else { $ResolutionChoices[0] }
    $grpRes.Controls.Add($cmbRes)

    $lblRes = New-Label "一覧にないサイズは直接入力できます (例: 2560x1440)" 315 58
    $lblRes.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes)

    $lblRes2 = New-Label "※ 変更は EdgeBox を起動し直したときに反映されます" 15 85
    $lblRes2.ForeColor = [System.Drawing.Color]::DimGray
    $grpRes.Controls.Add($lblRes2)
    $form.Controls.Add($grpRes)

    # チェックを入れたら、解像度は自動、コンソール側のモニターは全画面にそろえる
    $syncFit = {
        if ($cbFit.Checked) {
            $cmbRes.Text = $ResolutionChoices[0]
            $cmbRes.Enabled = $false
            if ($tbL.Text.Trim() -match '^(console|コンソール)$') { $cbLF.Checked = $true }
            if ($tbR.Text.Trim() -match '^(console|コンソール)$') { $cbRF.Checked = $true }
        } else {
            $cmbRes.Enabled = $true
        }
    }
    $cbFit.Add_CheckedChanged($syncFit)
    & $syncFit

    # --- ボタン ---
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "保存"
    $btnOK.Location = New-Object System.Drawing.Point(370, 415)
    $btnOK.Size = New-Object System.Drawing.Size(90, 32)
    $btnOK.DialogResult = "OK"
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "キャンセル"
    $btnCancel.Location = New-Object System.Drawing.Point(475, 415)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)
    $btnCancel.DialogResult = "Cancel"
    $form.Controls.AddRange(@($btnOK, $btnCancel))
    $form.AcceptButton = $btnOK
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -eq "OK") {
        # --- 解像度の指定を解釈する ---
        $resText = $cmbRes.Text.Trim()
        $res = Resolve-ResolutionText $resText
        $resChanged = ($resText -ne [string]$cfg.ConsoleResolution)
        if (-not $res) {
            [System.Windows.Forms.MessageBox]::Show(
                "解像度の指定『$resText』を解釈できませんでした。`n" +
                "「1920x1080」のような形式か、一覧からの選択にしてください。`n`n" +
                "解像度以外の設定は保存します。",
                "EdgeBox 表示設定",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $resText = [string]$cfg.ConsoleResolution
            $resChanged = $false
        }

        $out = [ordered]@{
            "_説明"             = "EdgeBox 表示の設定。『EdgeBox表示設定』アイコンから編集できます。"
            "RightUrl"          = $tbR.Text.Trim()
            "RightFullScreen"   = $cbRF.Checked
            "LeftUrl"           = $tbL.Text.Trim()
            "LeftFullScreen"    = $cbLF.Checked
            "EscEnabled"        = $cbEsc.Checked
            "ConsoleStripFrame" = $cbSF.Checked
            "ConsoleAutoClose"  = $cbAC.Checked
            "ConsoleResolution" = $resText
        }
        # 手動で追加できる詳細設定 (自動クローズまでの秒数) は保存で消さない
        if ($cfg.PSObject.Properties["ConsoleAutoCloseDelaySec"]) {
            $out["ConsoleAutoCloseDelaySec"] = [int]$cfg.ConsoleAutoCloseDelaySec
        }
        if ($cfg.PSObject.Properties["ConsoleHideBar"]) { $out["ConsoleHideBar"] = ($cfg.ConsoleHideBar -ne $false) }
        if ($cfg.PSObject.Properties["LeftGuard"]) { $out["LeftGuard"] = ($cfg.LeftGuard -ne $false) }
        if ($cfg.PSObject.Properties["LeftGuardHotkey"]) { $out["LeftGuardHotkey"] = [string]$cfg.LeftGuardHotkey }
        if ($cfg.PSObject.Properties["StowHotkey"]) { $out["StowHotkey"] = [string]$cfg.StowHotkey }
        $out["ConsoleAutoCloseV2"] = $true
        $out | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8

        $msg = "保存しました。次回の表示から反映されます。"
        if ($res -and $resChanged) {
            try { $msg += "`n`n" + (Set-ConsoleResolution $res.W $res.H "ask") }
            catch { $msg += "`n`n解像度の変更に失敗しました: $($_.Exception.Message)" }
        }
        [System.Windows.Forms.MessageBox]::Show($msg, "EdgeBox 表示設定") | Out-Null
    }
    exit 0
}

# ============================================================
#  デスクトップに『EdgeBox表示設定』アイコンを作成
# ============================================================
if ($Setup) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "EdgeBox表示設定.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "powershell.exe"
    $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Settings"
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = "shell32.dll,21"
    $lnk.Description  = "EdgeBox 表示の設定コンソール"
    $lnk.Save()
    Write-Host "デスクトップに『EdgeBox表示設定』アイコンを作成しました。" -ForegroundColor Green
    exit 0
}

# ============================================================
#  コンソール解像度をモニターに合わせる (EdgeBox 停止中のみ)
# ============================================================
if ($ConsoleResolution) {
    $res = Resolve-ResolutionText $ConsoleResolution
    if (-not $res) {
        Write-Error "解像度の指定が不正です。例: -ConsoleResolution 1920x1080  または  -ConsoleResolution auto"
        exit 1
    }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Error "登録 '$VMName' がありません。"; exit 1 }
    if ($vm.State -ne "Off") {
        Write-Error "EdgeBox を停止してから実行してください (.\05-shutdown-all.ps1 で EdgeBox だけ終了 → もう一度実行)。"
        exit 1
    }
    Set-VMVideo -VMName $VMName -ResolutionType Single `
        -HorizontalResolution $res.W -VerticalResolution $res.H
    # 設定画面にも反映させておく
    $cfg | Add-Member -NotePropertyName ConsoleResolution -NotePropertyValue $ConsoleResolution -Force
    $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "コンソールの解像度を $($res.W)x$($res.H) に設定しました。" -ForegroundColor Green
    Write-Host "次に EdgeBox を起動すると、この解像度で表示されます (.\02-start-field-vm.ps1)。"
    exit 0
}

# ============================================================
#  ログオン時自動実行の登録 / 解除
# ============================================================
if ($Install) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "管理者権限で実行してください (スタートボタンを右クリック →『ターミナル (管理者)』または『Windows PowerShell (管理者)』)。"
        exit 1
    }
    # 時間制限なし + 多重起動可。表示処理は見張り役などの常駐プロセスを残すため、タスクは「実行中」のままになる。
    # 時間制限があると、その時間が来たときにタスクごと (常駐プロセスも) 止められてしまう
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

    # 起動中画面 (スプラッシュ) は独立のタスクとして先に走らせる。
    # サインイン直後の数秒はデスクトップの準備中で不安定なため、少しだけ遅らせる
    $sAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Splash"
    $sTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    try { $sTrigger.Delay = "PT5S" } catch { }
    Register-ScheduledTask -TaskName "$TaskName-Splash" -Action $sAction -Trigger $sTrigger `
        -Settings $taskSettings -RunLevel Highest -Force | Out-Null

    $arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -VMName `"$VMName`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    try { $trigger.Delay = "PT15S" } catch { }
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $taskSettings -RunLevel Highest -Force | Out-Null
    # 「電源 ON → EdgeBox が自動起動 → サインイン → 画面表示」を成立させるには
    # EdgeBox 側の自動起動も必要。未設定なら、ここで一緒に入れておく (実行中の EdgeBox にも設定できる)
    $vmAuto = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vmAuto) {
        if ($vmAuto.AutomaticStartAction -ne "Start") {
            try {
                Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30
                Write-Host "登録 '$VMName' を PC 起動時に自動で起動するよう設定しました (30 秒後)。" -ForegroundColor Green
            } catch {
                Write-Host "EdgeBox の自動起動を設定できませんでした: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  手動で: Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStartDelay 30" -ForegroundColor Yellow
            }
        } else {
            Write-Host "登録 '$VMName' の自動起動は設定済みです。" -ForegroundColor Gray
        }
    } else {
        Write-Host "登録 '$VMName' が見つからないため、EdgeBox の自動起動は設定していません。" -ForegroundColor Yellow
    }
    Write-Host "登録しました。次回ログオンから自動で表示されます (起動中は黒い画面で覆います)。" -ForegroundColor Green
    Write-Host "  表示内容の変更: 『EdgeBox表示設定』アイコン (再登録不要)"
    exit 0
}
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "$TaskName-Splash" -Confirm:$false -ErrorAction SilentlyContinue
    Stop-EscWatcher
    Stop-LeftGuard
    Stop-UrlRetry
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-(Splash|Backdrop)' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "自動表示を解除しました。"
    exit 0
}
if (-not $RightUrl -and -not $LeftUrl) {
    Write-Error "表示する内容がありません。『EdgeBox表示設定』(-Settings) で設定してください。"
    exit 1
}

# ============================================================
#  表示処理
# ============================================================
# ログが育ちすぎないように、大きくなったら作り直す
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 200KB)) { Remove-Item $LogFile -Force }
Log "===== 表示処理を開始 (左=$LeftUrl / 右=$RightUrl) ====="

# アイコン用のタスク (『EdgeBox 再起動』『EdgeBox 画面』『設定』『EdgeBox 起動』とログオン時の表示) の設定を直す。
# 表示処理は見張り役などの常駐プロセスを残すため、タスクは「実行中」のままになる。旧設定 (時間制限 1 時間・
# 多重起動不可) のままだと、1 時間後にタスクごと常駐プロセスが止められ、「実行中」の間はアイコンを押しても
# 何も起きない。アイコンを作り直さなくても済むよう、表示処理 (管理者で動く) のたびに設定だけ直す
function Repair-LauncherTasks {
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { return }
        $fixed = @()
        foreach ($tn in @($TaskName, "$TaskName-Splash", "EdgeBox-Restart", "EdgeBox-Console", "EdgeBox-Settings-Console", "EdgeBox-Launcher")) {
            $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
            if (-not $t) { continue }
            $limit = [string]$t.Settings.ExecutionTimeLimit
            $multi = [string]$t.Settings.MultipleInstances
            if (($limit -eq "PT0S" -or $limit -eq "") -and $multi -eq "Parallel") { continue }
            $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
            Set-ScheduledTask -TaskName $tn -Settings $ts -ErrorAction Stop | Out-Null
            $fixed += $tn
        }
        if ($fixed.Count -gt 0) { Log ("アイコン用タスクの設定を直しました (時間制限なし・多重起動可): " + ($fixed -join ", ")) }
    } catch { Log ("アイコン用タスクの設定を直せませんでした: " + $_.Exception.Message) }
}
Repair-LauncherTasks

# --- 起動中画面: 表示がそろうまでデスクトップを黒い画面で覆う ---
function Stop-Splash {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Splash' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item $SplashLeftOffFile -Force -ErrorAction SilentlyContinue
}
if (-not $NoSplash) {
    # ログオンタスク (EdgeBox-Display-Kiosk-Splash) が先に出していればそれを使い、無ければここで出す
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Splash' -and $_.ProcessId -ne $PID })
    if ($existing.Count -eq 0) {
        Start-Process powershell.exe -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Splash -TimeoutSec $TimeoutSec"
    }
}
$leftIsConsole = ($LeftUrl -match '^(console|コンソール)$')
if ($leftIsConsole) {
    # 前回の黒背景が残っていれば片付ける (コンソールを置き直すときだけ)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '-Backdrop' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    # 見張り役は表示の組み立て中に窓を動かしてしまうため、いったん止めて最後に起動し直す
    Stop-LeftGuard
}
Stop-UrlRetry
Remove-Item $SplashLeftOffFile -Force -ErrorAction SilentlyContinue
$script:RightUrlPending = $false
try {

# --- EdgeBox の起動を待つ (止まっていれば起動する: 自動起動が働かなかった場合の保険) ---
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($vm -and $vm.State -eq "Off") {
    # CPU コア分割ツール (full モード) があれば、EdgeBox を CPU グループに固定してから起動する
    if (Invoke-CpuPartitionBoot) { Log "CPU コア分割 (full): EdgeBox を CPU グループに固定する処理を先に行いました。" }
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") {
        Log "EdgeBox は起動済みです (コア分割の処理で起動)。"
    } else {
        Log "EdgeBox が起動していないため、ここで起動します。"
        try { Start-VM -Name $VMName -ErrorAction Stop } catch { Log "警告: EdgeBox を起動できませんでした: $($_.Exception.Message)" }
    }
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm -and $vm.State -eq "Running") { break }
    Start-Sleep -Seconds 5
}
Log ("EdgeBox の状態: " + $(if ($vm) { $vm.State } else { "見つかりません" }))

# --- モニターの位置 (X座標で左右を判定) ---
# サインイン直後はまだ 2 枚目が認識されていないことがあるため、そろうまで待つ
Add-Type -AssemblyName System.Windows.Forms
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
} catch { Log "警告: UI Automation を読み込めませんでした (メニュー操作の代替は使えません)。" }
$msw = [System.Diagnostics.Stopwatch]::StartNew()
while ($msw.Elapsed.TotalSeconds -lt 90) {
    if (@([System.Windows.Forms.Screen]::AllScreens).Count -ge 2) { break }
    Start-Sleep -Seconds 3
}
$screens = @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X })
$leftScreen  = $screens[0]
$rightScreen = $screens[-1]
Log ("認識したモニター: {0} 枚 — {1}" -f $screens.Count,
     (($screens | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)@$($_.Bounds.X)" }) -join " / "))
if ($screens.Count -lt 2) {
    Log "警告: モニターが 1 枚しか認識できません。左右の表示が同じ画面に重なります。"
}

# --- Web 画面の応答を待つ (console 指定はスキップ) ---
function Wait-Url([string]$u) {
    if (-not $u) { return $true }
    $uri = [Uri]$u
    $port = if ($uri.Port -gt 0) { $uri.Port } elseif ($uri.Scheme -eq "https") { 443 } else { 80 }
    $usw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($usw.Elapsed.TotalSeconds -lt $UrlTimeoutSec) {
        if (Test-UrlOnce $u) { return $true }
        $el = [int]$usw.Elapsed.TotalSeconds
        Set-Status ("管理画面 (" + $uri.Host + ") の応答を待っています  経過 " + [int]($el / 60) + " 分 " + ($el % 60) + " 秒")
        Start-Sleep -Seconds 5
    }
    return $false
}
function Wait-OneUrl([string]$u, [string]$label) {
    if (-not $u -or $u -match '^(console|コンソール)$') { return }
    if (Wait-Url $u) { Log "$label URL が応答しました: $u"; return }
    Log "警告: $label URL が応答しません (それでも開きます): $u"
    if ($label -eq "右画面用") { $script:RightUrlPending = $true }
    # 次の切り分けのために、EdgeBox 側のネットワークの様子を残す
    try {
        $nics = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue)
        $ips = @($nics | ForEach-Object { $_.IPAddresses }) -join ", "
        $sws = @($nics | ForEach-Object { $_.SwitchName }) -join ", "
        Log ("  [診断] EdgeBox のネットワーク: スイッチ=" + $sws + " / IP=" + $(if ($ips) { $ips } else { "(報告なし)" }))
    } catch { }
}
function Wait-ForUrls {
    Wait-OneUrl $RightUrl "右画面用"
    Wait-OneUrl $LeftUrl  "左画面用"
}

$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$needsBrowser = (($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$') -or
                 ($LeftUrl  -and $LeftUrl  -notmatch '^(console|コンソール)$'))
if (-not $edge -and $needsBrowser) { Log "エラー: Microsoft Edge が見つかりません。"; exit 1 }

# --- ウィンドウ操作用 API ---
if (-not ([System.Management.Automation.PSTypeName]'FieldWin').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class FieldWin {
    [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetMenuString(IntPtr hMenu, uint uIDItem, StringBuilder lpString, int cchMax, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, uint dwExtraInfo);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetMenu(IntPtr hWnd, IntPtr hMenu);
    [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetFocus();
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
}
"@
}

# 前面化のブロック (フォアグラウンドロック) を回避して前面化する。
# ALT キー疑似押下 → 駄目なら AttachThreadInput 方式。成功したかを返す
function Force-Foreground([IntPtr]$hwnd) {
    for ($i = 0; $i -lt 3; $i++) {
        [FieldWin]::keybd_event(0x12, 0, 0, 0)      # ALT down
        [FieldWin]::SetForegroundWindow($hwnd) | Out-Null
        [FieldWin]::keybd_event(0x12, 0, 2, 0)      # ALT up
        Start-Sleep -Milliseconds 300
        if ([FieldWin]::GetForegroundWindow() -eq $hwnd) { return $true }

        # 前面ウィンドウのスレッドに入力を相乗りさせてから前面化する (確実性の高い方式)
        $fg = [FieldWin]::GetForegroundWindow()
        $procId = [uint32]0
        $fgThread = [FieldWin]::GetWindowThreadProcessId($fg, [ref]$procId)
        $myThread = [FieldWin]::GetCurrentThreadId()
        [FieldWin]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
        [FieldWin]::BringWindowToTop($hwnd) | Out-Null
        [FieldWin]::SetForegroundWindow($hwnd) | Out-Null
        [FieldWin]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([FieldWin]::GetForegroundWindow() -eq $hwnd) { return $true }
    }
    return ([FieldWin]::GetForegroundWindow() -eq $hwnd)
}

# 指定プロファイルの Edge ウィンドウを探す
function Get-EdgeWindow([string]$profile) {
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 800
        $procIds = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match [regex]::Escape($profile) } |
            Select-Object -ExpandProperty ProcessId)
        if ($procIds.Count -gt 0) {
            $p = Get-Process -Id $procIds -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($p) { return $p.MainWindowHandle }
        }
    }
    return [IntPtr]::Zero
}

function Open-Kiosk([string]$u, $screen, [string]$profile, [bool]$fullScreen) {
    if (-not $u) { return }
    Log ("ブラウザを開きます: {0}  (モニター {1},{2} / {3})" -f $u, $screen.Bounds.X, $screen.Bounds.Y,
         $(if ($fullScreen) { "全画面" } else { "最大化ウィンドウ" }))
    # --test-type: 「サポートされていないフラグ」警告バーを非表示にする
    # 全画面指定は --start-fullscreen で最初から全画面にする (F11 と同じ状態 = ESC 見張りで解除可)
    # 同じ用途の古い窓 (前回の表示や、応答待ちで開いたエラー画面) が残っていれば閉じてから開く
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($profile) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    $eargs = @(
        "--user-data-dir=$env:LOCALAPPDATA\$profile", "--no-first-run",
        "--ignore-certificate-errors", "--test-type",
        "--window-position=$($screen.Bounds.X),$($screen.Bounds.Y)",
        "--app=$u"
    )
    if ($fullScreen) { $eargs += "--start-fullscreen" }
    & $edge @eargs
    $h = Get-EdgeWindow $profile
    if ($h -eq [IntPtr]::Zero) { Log "警告: ブラウザのウィンドウを見つけられませんでした。"; return }

    if ($fullScreen -and (Test-CoversScreen $h $screen)) {
        Log "ブラウザ: 全画面表示で開きました。"
        Start-Sleep -Seconds 2
        return
    }

    # 対象モニターへ移動 + 最大化 (--start-maximized は app 窓では無視されるため直接操作する)
    [FieldWin]::MoveWindow($h, $screen.Bounds.X, $screen.Bounds.Y, 1000, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 300
    [FieldWin]::ShowWindow($h, 3) | Out-Null   # 最大化
    Log "ブラウザのウィンドウを配置しました。"

    # 全画面指定なのに全画面になっていない場合 (別モニターで開いた等) は F11 で仕上げる
    if ($fullScreen) {
        for ($try = 1; $try -le 2; $try++) {
            Force-Foreground $h | Out-Null
            [System.Windows.Forms.SendKeys]::SendWait("{F11}")
            Start-Sleep -Milliseconds 900
            if (Test-CoversScreen $h $screen) { Log "ブラウザ: 全画面表示にしました。"; break }
            if ($try -eq 2) { Log "ブラウザ: 全画面化できなかったため最大化ウィンドウのままにします。" }
        }
    }
    Start-Sleep -Seconds 2
}

# ウィンドウがモニター全体を覆っているか
function Test-CoversScreen([IntPtr]$hwnd, $screen) {
    $r = New-Object 'FieldWin+RECT'
    if (-not [FieldWin]::GetWindowRect($hwnd, [ref]$r)) { return $false }
    return (($r.Right - $r.Left) -ge ($screen.Bounds.Width - 4) -and
            ($r.Bottom - $r.Top) -ge ($screen.Bounds.Height - 4))
}

# Win32 メニューを再帰的にたどり、項目名が一致するコマンド (ID と表示名) を探す
function Find-MenuCommand([IntPtr]$menu, [string]$pattern, [int]$depth) {
    if ($depth -gt 3 -or $menu -eq [IntPtr]::Zero) { return $null }
    $sb = New-Object System.Text.StringBuilder 256
    for ($i = 0; $i -lt [FieldWin]::GetMenuItemCount($menu); $i++) {
        [void]$sb.Clear()
        [FieldWin]::GetMenuString($menu, [uint32]$i, $sb, 256, 0x400) | Out-Null   # 0x400 = MF_BYPOSITION
        $text = $sb.ToString()
        $sub = [FieldWin]::GetSubMenu($menu, $i)
        if ($sub -ne [IntPtr]::Zero) {
            $r = Find-MenuCommand $sub $pattern ($depth + 1)
            if ($r) { return $r }
        } elseif ($text -match $pattern) {
            $cmdId = [FieldWin]::GetMenuItemID($menu, $i)
            if ($cmdId -ne [uint32]::MaxValue) {
                return [pscustomobject]@{ Id = $cmdId; Text = $text }
            }
        }
    }
    return $null
}

# Win32 メニューから項目名が一致するコマンドを探し、WM_COMMAND を直接送って実行する。
# 実行した項目の表示名を返す (見つからなければ $null)。フォーカス不要
function Invoke-ConsoleMenuCommand([IntPtr]$hwnd, [string]$pattern) {
    $menu = [FieldWin]::GetMenu($hwnd)
    if ($menu -eq [IntPtr]::Zero) { return $null }
    $hit = Find-MenuCommand $menu $pattern 0
    if (-not $hit) { return $null }
    [FieldWin]::PostMessage($hwnd, 0x0111, [IntPtr][int64]$hit.Id, [IntPtr]::Zero) | Out-Null   # WM_COMMAND
    return $hit.Text
}

# UI Automation の要素を「押す」: Invoke → Expand → 中心をマウスでクリック の順に試し、使えた方法名を返す
# (vmconnect のメニューは WinForms 製で、環境によって対応するパターンが違うため)
function Invoke-UiaElement($el) {
    try {
        $pat = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) { $pat.Invoke(); return "Invoke" }
    } catch { }
    try {
        $pat = $null
        if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pat)) { $pat.Expand(); return "Expand" }
    } catch { }
    try {
        $r = $el.Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
            $x = [int]($r.Left + $r.Width / 2); $y = [int]($r.Top + $r.Height / 2)
            [FieldWin]::SetCursorPos($x, $y) | Out-Null
            Start-Sleep -Milliseconds 80
            [FieldWin]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # 左ボタン押す
            Start-Sleep -Milliseconds 60
            [FieldWin]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # 左ボタン離す
            return "Click"
        }
    } catch { }
    return $null
}

# vmconnect の窓 (本体と、開いたメニューのポップアップ) から名前が一致するメニュー項目を探す
function Find-ConsoleMenuItem([IntPtr]$hwnd, $root, [string]$pattern, [ref]$seen) {
    $condMi = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::MenuItem)
    $scopes = @()
    if ($root) { $scopes += $root }
    $procId = [uint32]0
    [FieldWin]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
    $pidCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$procId)
    $scopes += @([System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond))
    foreach ($sc in $scopes) {
        foreach ($i in $sc.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condMi)) {
            $n = [string]$i.Current.Name
            if ($n -and $seen.Value -notcontains $n) { $seen.Value += $n }
            if ($n -match $pattern) { return $i }
        }
    }
    return $null
}

# vmconnect のメニュー『表示 → 全画面モード』を UI 操作で実行する
# (キー送信と違い、タイミングやフォーカスの影響を受けにくい)。
# 成否の理由は $script:MenuDiag に残す (実機で何が見えていたかを記録に出すため)
function Invoke-ConsoleFullScreenMenu([IntPtr]$hwnd) {
    $script:MenuDiag = ""
    try {
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $seen = @()
        $view = Find-ConsoleMenuItem $hwnd $ae '^表示|^View' ([ref]$seen)

        # 「表示」メニューを開く: UI 操作 → 駄目なら Alt+V (メニューの見出し「表示(V)」のキー)
        $full = $null; $how = ""
        foreach ($attempt in 1, 2) {
            if ($attempt -eq 1 -and $view) { $how = Invoke-UiaElement $view; if (-not $how) { continue } }
            else { [System.Windows.Forms.SendKeys]::SendWait("%v"); $how = "Alt+V" }
            for ($k = 0; $k -lt 4 -and -not $full; $k++) {
                Start-Sleep -Milliseconds 400
                $full = Find-ConsoleMenuItem $hwnd $view '全画面|Full' ([ref]$seen)
            }
            if ($full) { break }
            [System.Windows.Forms.SendKeys]::SendWait("{ESC}")   # 開いたメニューがあれば閉じる
            Start-Sleep -Milliseconds 300
        }
        if (-not $full) {
            $script:MenuDiag = "『全画面』の項目が見つかりません (『表示』" + $(if ($view) { "あり" } else { "なし" }) + " / 開き方=$how / 見えた項目: " + ($seen -join ", ") + ")"
            return $false
        }
        $name = [string]$full.Current.Name
        $how2 = Invoke-UiaElement $full
        if (-not $how2) { $script:MenuDiag = "『$name』を押せませんでした"; return $false }
        Start-Sleep -Milliseconds 900
        $script:MenuDiag = "『表示』($how) → 『$name』($how2)"
        return $true
    } catch { $script:MenuDiag = "エラー: " + $_.Exception.Message; return $false }
}

# 全画面モードの切り替え操作を 1 回だけ送る (成否は確かめない。別モニターの全画面を解除するときなどに使う)
function Send-ConsoleFullScreenToggle([IntPtr]$hwnd) {
    if (Invoke-ConsoleMenuCommand $hwnd '全画面|Full') { return }
    Force-Foreground $hwnd | Out-Null
    if (Invoke-ConsoleFullScreenMenu $hwnd) { return }
    Send-CtrlAltBreak
}

# 窓のクラス名 (記録用)
function Get-WindowClassName([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return "(なし)" }
    $sb = New-Object System.Text.StringBuilder 256
    [FieldWin]::GetClassName($h, $sb, 256) | Out-Null
    return $sb.ToString()
}

# キーボードフォーカスをコンソールの映像の入力窓 (IHWindowClass) へ移す。
# Ctrl+Alt+Break は RDP 部品がフォーカスを持っているときに効く。EdgeBox を起動した直後は
# フォーカスがツールバーなど別の場所にあることがあり、キーを送っても効かなかった。
# 他プロセスの窓にフォーカスを置くため、そのスレッドの入力に相乗り (AttachThreadInput) する。
# 移す前後のフォーカス先 (クラス名) を返す (記録用)
function Set-ConsoleInputFocus([IntPtr]$main) {
    try {
        $ih = Get-ConsoleInputWindow
        if ($ih -eq [IntPtr]::Zero) { $ih = $main }
        $procId = [uint32]0
        $t = [FieldWin]::GetWindowThreadProcessId($ih, [ref]$procId)
        $my = [FieldWin]::GetCurrentThreadId()
        [FieldWin]::AttachThreadInput($my, $t, $true) | Out-Null
        $before = [FieldWin]::GetFocus()
        [FieldWin]::SetFocus($ih) | Out-Null
        Start-Sleep -Milliseconds 80
        $after = [FieldWin]::GetFocus()
        [FieldWin]::AttachThreadInput($my, $t, $false) | Out-Null
        return ("フォーカス " + (Get-WindowClassName $before) + " → " + (Get-WindowClassName $after))
    } catch { return ("フォーカス移動でエラー: " + $_.Exception.Message) }
}

# コンソールを全画面モードにする (成功したら $true)。
#   方法1: Win32 メニューの『全画面』を WM_COMMAND で実行 (フォーカス不要。vmconnect の版によっては無い)
#   方法2: Ctrl+Alt+Break のキー送信 (映像の入力窓にフォーカスを移してから。約 30 秒かけて繰り返す)
#   方法3: メニュー『表示 → 全画面モード』の UI 操作 (環境によっては項目が見えない)
# 成否は「枠なしの窓がモニターを覆っているか」(Test-ConsoleFullScreenOn) で確かめる。
# 最大化しただけの窓を全画面と誤判定していたため、大きさだけの判定はやめた
function Enter-ConsoleFullScreen($screen) {
    $b = $screen.Bounds
    $hwnd = Get-ConsoleHwnd
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $diagDone = $false

    # 方法1
    $hit = Invoke-ConsoleMenuCommand $hwnd '全画面|Full'
    if ($hit) {
        Start-Sleep -Milliseconds 1000
        if (Test-ConsoleFullScreenOn $b) { Log "コンソール: 全画面モードになりました (メニューコマンド『$hit』)"; return $true }
        Log ("コンソール: メニューコマンド『$hit』を実行しましたが全画面になりませんでした。窓: " + (Get-ConsoleTopWindowDiag)); $diagDone = $true
    }

    # 方法2 (実機ではこの方法で成功した実績あり。起動直後は効かないことがあるため長めに繰り返す)
    for ($try = 1; $try -le 10; $try++) {
        $h2 = Get-ConsoleHwnd; if ($h2 -ne [IntPtr]::Zero) { $hwnd = $h2 }
        if (-not (Force-Foreground $hwnd)) { Log "コンソール: 前面化に失敗 (キー送信 試行 $try)" }
        $focus = Set-ConsoleInputFocus $hwnd
        if ($try -eq 1 -or $try -eq 5) { Log "コンソール: キー送信の準備 (試行 ${try}): $focus" }
        if ($try % 2 -eq 1) { Send-CtrlAltBreak } else { [System.Windows.Forms.SendKeys]::SendWait("^%{BREAK}") }
        Start-Sleep -Milliseconds 1500
        if (Test-ConsoleFullScreenOn $b) { Log "コンソール: 全画面モードになりました (キー送信 試行 $try)"; return $true }
        if ($try -eq 4) {
            if (-not $diagDone) { Log ("コンソール: キー送信 4 回で全画面になりません。窓: " + (Get-ConsoleTopWindowDiag)); $diagDone = $true }
            try { Set-Content -Path $SplashLeftOffFile -Value "1" -Encoding ASCII } catch { }   # 覆いを外して続ける
            Start-Sleep -Milliseconds 1000
        }
        Start-Sleep -Milliseconds 1500
    }

    # 方法3
    $h2 = Get-ConsoleHwnd; if ($h2 -ne [IntPtr]::Zero) { $hwnd = $h2 }
    Force-Foreground $hwnd | Out-Null
    if (Invoke-ConsoleFullScreenMenu $hwnd) {
        Start-Sleep -Milliseconds 700
        if (Test-ConsoleFullScreenOn $b) { Log "コンソール: 全画面モードになりました (メニュー操作: $script:MenuDiag)"; return $true }
        Log "コンソール: メニューを操作しましたが全画面になりませんでした ($script:MenuDiag)"
    } else {
        Log "コンソール: メニュー操作に失敗: $script:MenuDiag"
    }
    Log ("コンソール: 全画面モードにできませんでした。窓: " + (Get-ConsoleTopWindowDiag))
    return $false
}

# ウィンドウ上端からツールバー下端までの高さ (メニュー・ツールバー領域のサイズ)
function Get-ConsoleChromeHeight([IntPtr]$hwnd) {
    try {
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $condTb = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ToolBar)
        $tb = $ae.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condTb)
        $r = New-Object 'FieldWin+RECT'
        [FieldWin]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        if ($tb) {
            $h = [int]([Math]::Ceiling($tb.Current.BoundingRectangle.Bottom) - $r.Top)
            if ($h -gt 0 -and $h -lt 200) { return $h }
        }
    } catch { }
    return 60   # 取得できなければ標準的なメニュー+ツールバーの高さで近似
}

# Ctrl+Alt+Break (vmconnect の全画面モード切り替え)
function Send-CtrlAltBreak {
    [FieldWin]::keybd_event(0x11, 0, 0, 0)          # Ctrl down
    [FieldWin]::keybd_event(0x12, 0, 0, 0)          # Alt down
    [FieldWin]::keybd_event(0x03, 0x46, 1, 0)       # Break down (拡張キー)
    Start-Sleep -Milliseconds 60
    [FieldWin]::keybd_event(0x03, 0x46, 3, 0)       # Break up
    [FieldWin]::keybd_event(0x12, 0, 2, 0)          # Alt up
    [FieldWin]::keybd_event(0x11, 0, 2, 0)          # Ctrl up
}

# 枠を外して指定位置・サイズに固定する
function Set-FramelessWindow([IntPtr]$hwnd, [int]$x, [int]$y, [int]$w, [int]$h) {
    $GWL_STYLE = -16
    $WS_CAPTION = 0x00C00000; $WS_THICKFRAME = 0x00040000; $WS_BORDER = 0x00800000
    [FieldWin]::ShowWindow($hwnd, 1) | Out-Null       # 最大化を解除しないと大きさを変えられない
    Start-Sleep -Milliseconds 300
    $style = [FieldWin]::GetWindowLong($hwnd, $GWL_STYLE)
    $style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_BORDER))
    [FieldWin]::SetWindowLong($hwnd, $GWL_STYLE, $style) | Out-Null
    if ([FieldWin]::GetMenu($hwnd) -ne [IntPtr]::Zero) { [FieldWin]::SetMenu($hwnd, [IntPtr]::Zero) | Out-Null }
    # 0x0020 = SWP_FRAMECHANGED, 0x0040 = SWP_SHOWWINDOW
    [FieldWin]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, $w, $h, 0x0060) | Out-Null
    [FieldWin]::BringWindowToTop($hwnd) | Out-Null
}

# vmconnect を正しく閉じる (強制終了ではなく通常の閉じ方にして、全画面などの状態を保存させる)
function Close-ConsoleGracefully {
    $procs = @(Get-Process vmconnect -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return }
    foreach ($p in $procs) { [void]$p.CloseMainWindow() }
    # 設定ファイルの書き出しが終わるまで、最大8秒はプロセスの終了を待つ
    $csw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($csw.Elapsed.TotalSeconds -lt 8) {
        if (-not (Get-Process vmconnect -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# vmconnect が保存している表示設定ファイルを探す
# (EdgeBox ごとの vmconnect.rdp.<VMID>.config、無ければ共通の vmconnect.config)
function Get-ConsoleConfigFile {
    try {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if (-not $vm) { return $null }
        $vmid = $vm.Id.ToString()
        foreach ($root in $env:APPDATA, $env:LOCALAPPDATA) {
            $dir = Join-Path $root "Microsoft\Windows\Hyper-V\Client\1.0"
            $f = Get-ChildItem -Path $dir -Filter "vmconnect.rdp.*.config" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match [regex]::Escape($vmid) } | Select-Object -First 1
            if ($f) { return $f }
            $g = Join-Path $dir "vmconnect.config"
            if (Test-Path $g) { return (Get-Item $g) }
        }
        return $null
    } catch { return $null }
}

# 表示設定ファイルの FullScreen 系の設定を書き換える。
# True にしてから起動すると、切り替え操作なしで最初から全画面で開く
function Set-ConsoleSavedFullScreen([bool]$on) {
    try {
        $file = Get-ConsoleConfigFile
        if (-not $file) { return $false }
        [xml]$x = Get-Content $file.FullName -Raw -Encoding UTF8
        $nodes = @($x.SelectNodes("//setting") | Where-Object { $_.GetAttribute("name") -match 'FullScreen' })
        if ($nodes.Count -eq 0) {
            # 何という名前で保存されているかを一度だけ記録する (次の改善のための診断)
            $names = @($x.SelectNodes("//setting") | ForEach-Object { $_.GetAttribute("name") } | Select-Object -First 40)
            Log ("コンソール: [診断] $($file.Name) の設定名一覧: " + ($names -join ", "))
            return $false
        }
        $val = if ($on) { "True" } else { "False" }
        foreach ($n in $nodes) {
            $valNode = $n.SelectSingleNode("value")
            if ($valNode) { $valNode.InnerText = $val } else { $n.InnerText = $val }
        }
        $x.Save($file.FullName)
        return $true
    } catch { return $false }
}

# 窓が最初に出る位置 (StartingPosition) を左画面の座標に書き換える。
# 書き換えないと窓はメイン ディスプレイ (右画面) に出てから左へ動くため、右画面が一瞬ちらつく
function Set-ConsoleSavedPosition([int]$x0, [int]$y0) {
    try {
        $file = Get-ConsoleConfigFile
        if (-not $file) { return $false }
        [xml]$x = Get-Content $file.FullName -Raw -Encoding UTF8
        $nodes = @($x.SelectNodes("//setting") | Where-Object { $_.GetAttribute("name") -eq 'StartingPosition' })
        if ($nodes.Count -eq 0) { return $false }
        $val = "{0}, {1}" -f $x0, $y0   # System.Drawing.Point の保存形式 ("X, Y")
        foreach ($n in $nodes) {
            $valNode = $n.SelectSingleNode("value")
            $old = if ($valNode) { $valNode.InnerText } else { $n.InnerText }
            if (-not $script:PosDiagDone) { $script:PosDiagDone = $true; Log "コンソール: [診断] 保存されていた窓の位置: '$old' → '$val' に書き換えます。" }
            if ($valNode) { $valNode.InnerText = $val } else { $n.InnerText = $val }
        }
        $x.Save($file.FullName)
        return $true
    } catch { return $false }
}

# 全画面のときに上部へ出る接続バー (「localhost 上の EdgeBox」の帯) の表示/非表示を書き換える。
# RDP クライアントの DisplayConnectionBar / PinConnectionBar に相当する設定名を探して書く
function Set-ConsoleSavedBar([bool]$hide) {
    try {
        $file = Get-ConsoleConfigFile
        if (-not $file) { return $false }
        [xml]$x = Get-Content $file.FullName -Raw -Encoding UTF8
        $nodes = @($x.SelectNodes("//setting") | Where-Object { $_.GetAttribute("name") -match 'ConnectionBar' })
        if ($nodes.Count -eq 0) {
            $names = @($x.SelectNodes("//setting") | ForEach-Object { $_.GetAttribute("name") } | Select-Object -First 40)
            Log ("コンソール: [診断] 接続バーの設定が見つかりません。設定名一覧: " + ($names -join ", "))
            return $false
        }
        $val = if ($hide) { "False" } else { "True" }
        foreach ($n in $nodes) {
            $valNode = $n.SelectSingleNode("value")
            if ($valNode) { $valNode.InnerText = $val } else { $n.InnerText = $val }
        }
        $x.Save($file.FullName)
        $mode = if ($hide) { "非表示" } else { "表示" }
        Log ("コンソール: 接続バーの設定を " + $mode + " に書き換えました (" + (($nodes | ForEach-Object { $_.GetAttribute("name") }) -join ", ") + ")。")
        return $true
    } catch { return $false }
}

# vmconnect の「今の」メインウィンドウを取り直す
# (接続の途中でウィンドウが作り直されることがあり、古いハンドルへの操作は空振りするため)
function Get-ConsoleHwnd {
    $p = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { return $p.MainWindowHandle }
    return [IntPtr]::Zero
}

# vmconnect を起動してウィンドウハンドルを返す
function Start-ConsoleWindow {
    Start-Process "vmconnect.exe" -ArgumentList "localhost", $VMName
    $csw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($csw.Elapsed.TotalSeconds -lt 30) {
        Start-Sleep -Seconds 1
        $p = Get-Process vmconnect -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

# --- EdgeBox のコンソール画面 (vmconnect) を指定モニターに表示 ---
# 全画面のときに上部へ出る接続バーは、RDP クライアントが出す別ウィンドウ。vmconnect の設定ファイルには
# この項目が無い (実機の診断: ZoomLevel, ConnectionDialogServers, StartingPosition, ShowToolbar のみ) ため、
# ウィンドウそのものを非表示にする。名前 (クラス名) は環境で違い (実機では BBarWindowClass では見つからなかった)、
# 出るまで少し時間もかかるため、形で探して数秒間は探し直す。見つからなければ手掛かりを記録に残す
function Hide-ConsoleBar($screen) {
    if ($cfg.ConsoleHideBar -eq $false) { return $false }
    $b = $screen.Bounds
    $hidden = @{}
    try {
        $main = Get-ConsoleHwnd
        for ($try = 1; $try -le 8; $try++) {
            foreach ($w in Find-ConsoleBarWindows $b $main) {
                if ($w.Hwnd -eq [IntPtr]::Zero) { continue }
                [BarFinder]::ShowWindow($w.Hwnd, 0) | Out-Null
                $key = [string]$w.Hwnd
                if (-not $hidden.ContainsKey($key)) {
                    $hidden[$key] = $true
                    Log ("コンソール: 上部の接続バーを隠しました (" + (Format-ConsoleWindow $w) + ")。")
                }
            }
            if ($hidden.Count -gt 0 -and $try -ge 3) { break }   # 隠せたあとも 2 回は探し直す (出直してくる場合)
            Start-Sleep -Milliseconds 750
        }
        if ($hidden.Count -eq 0) {
            Log ("コンソール: [診断] 接続バーが見つかりません。vmconnect の見えている窓: " + (Get-ConsoleWindowDiag $b))
        }
    } catch { Log ("コンソール: 接続バーの非表示でエラー: " + $_.Exception.Message) }
    return ($hidden.Count -gt 0)
}

$script:ConsoleFallback = $false   # 全画面にできず代替表示 (黒背景 + 枠なし中央表示) にしたか
function Open-Console($screen, [bool]$fullScreen) {
    Log ("コンソールを開きます (モニター {0},{1} / {2})" -f $screen.Bounds.X, $screen.Bounds.Y,
         $(if ($fullScreen) { "全画面" } else { "最大化ウィンドウ" }))
    # コンソールは同時に1接続のみ。古い窓は「正しく閉じて」状態を保存させる
    Close-ConsoleGracefully

    # 保存設定を「全画面」に書き換えてから起動する (起動した瞬間から全画面になる)
    $NoCfgFlag = Join-Path $PSScriptRoot "vmconnect-config-unsupported-v2.flag"
    if ($fullScreen) {
        if (-not (Get-ConsoleConfigFile) -and -not (Test-Path $NoCfgFlag)) {
            # 初回のみ: 一度開いて正しく閉じ、vmconnect 自身に設定ファイルを作らせる。
            # 接続が確立する前に閉じると保存されないため、しばらく待ってから閉じる
            Log "コンソール: 設定ファイルが無いため、一度開いて作成させます..."
            $tmp = Start-ConsoleWindow
            if ($tmp -ne [IntPtr]::Zero) { Start-Sleep -Seconds 6 }
            Close-ConsoleGracefully
            $cf = Get-ConsoleConfigFile
            if ($cf) { Log "コンソール: 設定ファイルを作成しました ($($cf.Name))。" }
            else {
                # この環境では作られないと判断し、以後この手順は省略する (毎回10秒の無駄を防ぐ)
                New-Item -Path $NoCfgFlag -ItemType File -Force | Out-Null
                Log "コンソール: 設定ファイルは作成されませんでした。以後この手順は省略します。"
                # 実際の保存場所を探すための診断情報
                try {
                    $found = @()
                    foreach ($root in "$env:APPDATA\Microsoft", "$env:LOCALAPPDATA\Microsoft") {
                        $found += Get-ChildItem -Path $root -Recurse -Depth 6 -Filter "vmconnect*" -File -ErrorAction SilentlyContinue |
                            Select-Object -First 5
                    }
                    if ($found.Count -gt 0) {
                        Log ("コンソール: [診断] vmconnect 関連ファイル: " + (($found | ForEach-Object { $_.FullName }) -join " ; "))
                    } else {
                        Log "コンソール: [診断] vmconnect 関連ファイルはプロファイル内に見つかりませんでした。"
                    }
                } catch { }
            }
        }
        if (Set-ConsoleSavedFullScreen $true) { Log "コンソール: 保存設定を全画面に書き換えました。" }
        elseif (-not (Test-Path $NoCfgFlag)) { Log "コンソール: 保存設定を書き換えられなかったため、起動後に切り替えます。" }
    } else {
        Set-ConsoleSavedFullScreen $false | Out-Null
    }
    # 窓は最初から左画面に出す (右画面でちらつかせない)
    Set-ConsoleSavedPosition $screen.Bounds.X $screen.Bounds.Y | Out-Null

    $hwnd = Start-ConsoleWindow
    if ($hwnd -eq [IntPtr]::Zero) { Log "警告: コンソール画面のウィンドウが見つかりませんでした。"; return }

    # 接続の途中でウィンドウが作り直されることがあるため、落ち着くのを待って取り直す
    Start-Sleep -Seconds 2
    $h2 = Get-ConsoleHwnd
    if ($h2 -ne [IntPtr]::Zero -and $h2 -ne $hwnd) {
        Log "コンソール: 接続後にウィンドウが作り直されたため、取得し直しました。"
        $hwnd = $h2
    }

    # 保存設定が効いて、最初から目的のモニターで全画面になっているか確認
    if ($fullScreen) {
        Start-Sleep -Milliseconds 1200
        $h2 = Get-ConsoleHwnd; if ($h2 -ne [IntPtr]::Zero) { $hwnd = $h2 }
        if (Test-ConsoleFullScreenOn $screen.Bounds) {
            Log "コンソール: 保存設定により最初から全画面で起動しました。"
            Start-Sleep -Milliseconds 800
            Hide-ConsoleBar $screen | Out-Null
            return
        }
        $own = [System.Windows.Forms.Screen]::FromHandle($hwnd)
        if ($own -and ($own.Bounds -ne $screen.Bounds) -and (Test-ConsoleFullScreenOn $own.Bounds)) {
            # 別のモニターで全画面になってしまった → いったん解除してから配置し直す
            Log "コンソール: 別のモニターで全画面になっていたため、いったん解除して配置し直します。"
            Send-ConsoleFullScreenToggle $hwnd
            Start-Sleep -Milliseconds 800
        }
    }

    [FieldWin]::MoveWindow($hwnd, $screen.Bounds.X, $screen.Bounds.Y, 900, 700, $true) | Out-Null
    Start-Sleep -Milliseconds 400
    [FieldWin]::ShowWindow($hwnd, 3) | Out-Null   # 最大化
    Start-Sleep -Milliseconds 600

    if (-not $fullScreen) { Log "コンソール: 最大化ウィンドウで表示します (全画面の指定なし)。"; return }

    # 全画面モード (メニューバーなし・余白は黒)。解除/再開は Ctrl+Alt+Break
    # 起動中画面 (左画面の黒い覆い) は、全画面になるまで掛けたままにする (最大化 → 全画面 の途中経過を見せない)。
    # キー送信が 4 回効かなければ、覆いが邪魔をしている可能性に備えて途中で外す (Enter-ConsoleFullScreen 内)
    $done = Enter-ConsoleFullScreen $screen
    try { Set-Content -Path $SplashLeftOffFile -Value "1" -Encoding ASCII } catch { }

    if ($done) { Start-Sleep -Milliseconds 800; Hide-ConsoleBar $screen | Out-Null }

    # 方法4: 黒背景を敷き、枠を外したコンソールを「実際の映像サイズ」で中央に重ねる
    if (-not $done) {
        Log "コンソール: 全画面モードの切り替えが効きませんでした。代替表示に切り替えます。"
        $script:ConsoleFallback = $true   # 仕上げの処理で全画面に戻そうとしない
        if ($cfg.ConsoleStripFrame -ne $false) {
            # EdgeBox がいま実際に出している映像の解像度を調べる (設定値ではなく実測)
            $vw = 0; $vh = 0
            try {
                $vm2 = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                if ($vm2) {
                    $head = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_VideoHead -ErrorAction SilentlyContinue |
                        Where-Object { $_.SystemName -eq $vm2.Id.ToString() } | Select-Object -First 1
                    if ($head -and [int]$head.CurrentHorizontalResolution -gt 0) {
                        $vw = [int]$head.CurrentHorizontalResolution
                        $vh = [int]$head.CurrentVerticalResolution
                        Log "コンソール: 現在の実映像サイズは ${vw}x${vh} です。"
                    }
                }
            } catch { }
            if ($vw -le 0) {
                try {
                    $vid = Get-VMVideo -VMName $VMName -ErrorAction SilentlyContinue
                    $vw = [int]$vid.HorizontalResolution; $vh = [int]$vid.VerticalResolution
                } catch { }
            }
            if ($vw -le 0 -or $vw -gt $screen.Bounds.Width)  { $vw = [Math]::Min(1024, $screen.Bounds.Width) }
            if ($vh -le 0 -or $vh -gt $screen.Bounds.Height) { $vh = [Math]::Min(768,  $screen.Bounds.Height) }
            if ($vw -lt $screen.Bounds.Width) {
                Log "コンソール: 映像がモニターより小さいため余白は黒になります (EdgeBox の再起動後はモニターと同じ大きさになります)。"
            }
            $cx = $screen.Bounds.X + [int](($screen.Bounds.Width  - $vw) / 2)
            $cy = $screen.Bounds.Y + [int](($screen.Bounds.Height - $vh) / 2)

            # 黒背景を敷く (黒背景は自分で最背面に下がるので、コンソールを隠さない)
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
                "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Backdrop " +
                "-BackdropBounds `"$($screen.Bounds.X),$($screen.Bounds.Y),$($screen.Bounds.Width),$($screen.Bounds.Height)`"")
            Start-Sleep -Milliseconds 900

            # 枠とメニューを外して実映像サイズで中央に配置し、ステータスバー等も隠す。
            # ウィンドウが作り直されて空振りすることがあるため、除去できたか確認して再試行する
            $stripped = $false
            for ($k = 1; $k -le 3; $k++) {
                $h2 = Get-ConsoleHwnd; if ($h2 -ne [IntPtr]::Zero) { $hwnd = $h2 }
                Set-FramelessWindow $hwnd $cx $cy $vw $vh
                Start-Sleep -Milliseconds 500
                $h2 = Get-ConsoleHwnd; if ($h2 -ne [IntPtr]::Zero) { $hwnd = $h2 }
                $style = [FieldWin]::GetWindowLong($hwnd, -16)
                if (($style -band 0x00C00000) -eq 0) { $stripped = $true; break }   # WS_CAPTION が消えたか
                Log "コンソール: 枠の除去が効かなかったため再試行します ($k/3)"
            }
            foreach ($cls in "msctls_statusbar32", "ToolbarWindow32", "msctls_toolbarwindow32", "ReBarWindow32") {
                $child = [FieldWin]::FindWindowEx($hwnd, [IntPtr]::Zero, $cls, $null)
                if ($child -ne [IntPtr]::Zero) { [FieldWin]::ShowWindow($child, 0) | Out-Null }
            }
            if ([FieldWin]::GetMenu($hwnd) -ne [IntPtr]::Zero) { [FieldWin]::SetMenu($hwnd, [IntPtr]::Zero) | Out-Null }
            # vmconnect のメニューバー・ツールバー・ステータスバーは WinForms の子窓 (Win32 メニューではない) なので、
            # 「横長で背の低い子窓」を隠す。そのうえで映像の窓 (IHWindowClass) の位置から余白を測り、
            # 映像がちょうどモニター中央に収まるように窓を置き直す (以前はメニューが残り、映像の下が切れていた)
            $offX = 0; $offY = 0; $hiddenStrips = 0
            for ($k = 1; $k -le 2; $k++) {
                foreach ($w in Get-ConsoleWindows) {
                    if ($w.Parent -ne $hwnd -or -not $w.Visible -or $w.Class -notlike 'WindowsForms10*') { continue }
                    if ($w.Height -gt 0 -and $w.Height -le 40 -and $w.Width -ge 100) { [FieldWin]::ShowWindow($w.Hwnd, 0) | Out-Null; $hiddenStrips++ }
                }
                Start-Sleep -Milliseconds 300
                $mainInfo = $null; $ihInfo = $null
                foreach ($w in Get-ConsoleWindows) {
                    if ($w.Hwnd -eq $hwnd) { $mainInfo = $w }
                    elseif ($w.Parent -eq $hwnd -and $w.Class -eq 'IHWindowClass' -and $w.Visible) { $ihInfo = $w }
                }
                if ($mainInfo -and $ihInfo) {
                    $offX = [Math]::Max(0, $ihInfo.Left - $mainInfo.Left)
                    $offY = [Math]::Max(0, $ihInfo.Top - $mainInfo.Top)
                }
                [FieldWin]::SetWindowPos($hwnd, [IntPtr]::Zero, ($cx - $offX), ($cy - $offY), ($vw + $offX), ($vh + $offY), 0x0060) | Out-Null
                Start-Sleep -Milliseconds 300
            }
            [FieldWin]::BringWindowToTop($hwnd) | Out-Null
            Log "コンソール: 黒背景の上に実映像サイズ ${vw}x${vh} で表示しました (枠除去=$stripped / 隠したバー=$hiddenStrips / 余白=$offX,$offY)。"
        }
    }
}

function Open-Display([string]$val, $screen, [string]$profile, [bool]$fullScreen) {
    if (-not $val) { return }
    if ($val -match '^(console|コンソール)$') { Open-Console $screen $fullScreen }
    else { Open-Kiosk $val $screen $profile $fullScreen }
}

# 左 = コンソールなら先に出して起動中画面を閉じる (EdgeBox は起動済みなのですぐ出せる)。
# 管理画面の応答待ちはそのあとに行う (長くかかっても左は見えている)
if ($leftIsConsole) {
    Open-Display $LeftUrl $leftScreen "FieldKioskL" $LeftFull
    # 左は出たので、起動中画面 (左画面の黒い覆い) を閉じる合図を出す (既に閉じていれば何もしない)
    try { Set-Content -Path $SplashLeftOffFile -Value "1" -Encoding ASCII } catch { }
    if ($RightUrl) { Set-Status "管理画面の応答を待っています" } else { Set-Status "左画面の表示を仕上げています" }
}
Wait-ForUrls
Open-Display $RightUrl $rightScreen "FieldKioskR" $RightFull
if (-not $leftIsConsole) { Open-Display $LeftUrl $leftScreen "FieldKioskL" $LeftFull }
if ($script:RightUrlPending -and $RightUrl) {
    # 応答が無いまま開いたので、応答したら開き直す後追いを残す
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -UrlRetry -RightUrl `"$RightUrl`" -VMName `"$VMName`"")
    Log "管理画面が応答したら右画面を開き直す後追いを起動しました。"
}

# --- 表示の仕上げ (左 = コンソール & 右 = ブラウザ のとき) ---
# 起動時、右画面のブラウザを開くとフォーカスが右へ移り、左のコンソール (vmconnect) の全画面が
# 外れることがある (vmconnect はフォーカスを失うと全画面を抜ける)。また、他のアプリが右画面に
# 自動起動していると管理画面が隠れる。そこで最後に、
#   1) 右のブラウザを最前面へ (自動起動した他アプリの上に出す。Chrome の全画面はフォーカスを失っても外れない)
#   2) 左のコンソールを「最後に」前面化し、全画面が外れていれば戻す (最後に前面化するので全画面のまま残る)
$rightIsBrowser = ($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$')
if ($leftIsConsole -and $rightIsBrowser) {
    Start-Sleep -Seconds 2
    $bh = Get-EdgeWindow "FieldKioskR"
    if ($bh -ne [IntPtr]::Zero) {
        Force-Foreground $bh | Out-Null
        [FieldWin]::BringWindowToTop($bh) | Out-Null
        Log "右画面のブラウザを最前面にしました (他アプリの上に管理画面を出します)。"
    }
    $ch = Get-ConsoleHwnd
    if ($ch -ne [IntPtr]::Zero) {
        if ($LeftFull -and -not $script:ConsoleFallback -and -not (Test-ConsoleFullScreenOn $leftScreen.Bounds)) {
            Log "コンソール: ブラウザ表示後に全画面が外れていたため、戻します。"
            [FieldWin]::ShowWindow($ch, 9) | Out-Null
            [FieldWin]::MoveWindow($ch, $leftScreen.Bounds.X, $leftScreen.Bounds.Y, 900, 700, $true) | Out-Null
            Start-Sleep -Milliseconds 300
            Enter-ConsoleFullScreen $leftScreen | Out-Null
            $ch2 = Get-ConsoleHwnd; if ($ch2 -ne [IntPtr]::Zero) { $ch = $ch2 }
        }
        Force-Foreground $ch | Out-Null
        if ($LeftFull -and -not $script:ConsoleFallback) { Hide-ConsoleBar $leftScreen | Out-Null }
    }
}

# --- ESC 見張り役 (ブラウザ表示があれば起動。全画面→最大化→元のサイズ の順に ESC で戻せる) ---
$hasBrowser = (($RightUrl -and $RightUrl -notmatch '^(console|コンソール)$') -or
               ($LeftUrl  -and $LeftUrl  -notmatch '^(console|コンソール)$'))
if ($hasBrowser -and ($cfg.EscEnabled -ne $false)) {
    Stop-EscWatcher
    Start-Process powershell.exe -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -EscWatcher"
    Log "ESC キーでブラウザの全画面/最大化を解除できます (ブラウザ画面が前面のときのみ)。"
}

# --- EdgeBox 起動後のコンソール自動クローズ (起動確認だけ済ませて黒い画面を残さない) ---
$hasConsole = (($LeftUrl -match '^(console|コンソール)$') -or ($RightUrl -match '^(console|コンソール)$'))
if ($hasConsole -and ($cfg.ConsoleAutoClose -ne $false) -and -not $KeepConsole) {
    $closeDelay = 30
    if ([int]$cfg.ConsoleAutoCloseDelaySec -gt 0) { $closeDelay = [int]$cfg.ConsoleAutoCloseDelaySec }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConsoleCloser " +
        "-CloserDelaySec $closeDelay -VMName `"$VMName`"")
    Log "コンソール: 起動確認のため約 $closeDelay 秒表示したあと、自動で閉じます (『設定』の[画面表示]で変更可)。"
}

# --- 左画面の見張り役 (左 = コンソールのとき) ---
if (($LeftUrl -match '^(console|コンソール)$') -and ($cfg.LeftGuard -ne $false)) {
    Stop-LeftGuard
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -LeftGuard -VMName `"$VMName`"")
    $hk = if ($cfg.LeftGuardHotkey) { [string]$cfg.LeftGuardHotkey } else { "Alt+F11" }
    $sk = if ($cfg.StowHotkey) { [string]$cfg.StowHotkey } else { "Ctrl+Alt+K" }
    Log "左画面を EdgeBox の全画面で固定します (他の窓は右画面へ。解除/再固定: $hk / 収納⇔全画面: $sk 長押し。『設定』の[画面表示]で変更可)。"
}

Log "===== 表示処理を完了 ====="

} finally {
    # 表示がそろったので起動中画面を閉じる (エラーで中断した場合も必ず閉じる)
    Start-Sleep -Milliseconds 500
    Stop-Splash
}
