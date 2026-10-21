#requires -Version 5.1
<#
  Edge Box UI preview. Loads only the design copies in this directory.
  All system, VM, process, installed application and performance data are fixtures.
  No production script, engine, task, registry or device configuration is loaded.
#>
[CmdletBinding()]
param(
    [ValidateSet('Console','Monitor','Apps','CoreChooser','Processes','InstalledApps')]
    [string]$Screen = 'Console',
    [switch]$SmokeTest,
    [string]$ScreenshotDirectory,
    # viewer.ps1 dot-sources this file for its fixtures and Show-* functions only.
    [switch]$LoadOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'cpu-ui-theme.ps1')
# The preview keeps the user-facing product name; file and type identifiers stay intact.
$UiAppName = 'Edge Box'
$VMName = 'EdgeBox'
$IntervalMs = 1000
$TopMost = $false
$script:PreviewRoot = $PSScriptRoot
$script:PreviewErrors = New-Object System.Collections.ArrayList
$script:Rendered = New-Object System.Collections.ArrayList
$script:DrawingResources = @()
$threadError = [System.Threading.ThreadExceptionEventHandler]{ param($s,$e) [void]$script:PreviewErrors.Add($e.Exception) }
[System.Windows.Forms.Application]::add_ThreadException($threadError)

function ConvertTo-LpRangeText([int[]]$Lps) {
    $values = @($Lps | Sort-Object -Unique)
    if (-not $values.Count) { return '' }
    $parts = @(); $first = $values[0]; $last = $first
    foreach ($n in @($values | Select-Object -Skip 1)) {
        if ($n -eq $last + 1) { $last = $n; continue }
        $parts += $(if ($first -eq $last) { "$first" } else { "$first-$last" })
        $first = $n; $last = $n
    }
    $parts += $(if ($first -eq $last) { "$first" } else { "$first-$last" })
    return $parts -join ','
}
function Get-LpCount($Cores) { return [int](($Cores | ForEach-Object { $_.Lps.Count } | Measure-Object -Sum).Sum) }
function New-Lbl([string]$Text,[int]$X,[int]$Y,[int]$W=0) { New-UiLabel $Text $X $Y $W 'body' }

# Deliberately shadow the names used by copied layout code. These are fixtures,
# including on a PC that has Hyper-V or the actual Edge Box configuration installed.
function Get-VM {
    [CmdletBinding()] param([string]$Name)
    return [pscustomobject]@{Name='EdgeBox'; State='Running'}
}
function Get-Process {
    [CmdletBinding()] param()
    foreach ($n in @('SampleBrowser','SampleEditor','SampleCollector')) {
        [pscustomobject]@{ProcessName=$n; Path=('C:\Preview\'+$n+'.exe'); MainWindowHandle=[IntPtr]1}
    }
}
function Get-InstalledApps {
    foreach ($n in @('サンプル ブラウザー','サンプル エディター','サンプル 収集アプリ')) {
        [pscustomobject]@{Name=$n; Exe=('C:\Preview\'+$n+'.exe'); Source='プレビュー用データ'}
    }
}
function Show-Info([string]$Text,[string]$Icon='Information') {
    if ($SmokeTest) { return }
    [void](Show-UiMessage ($Text+"`n`nプレビュー用のサンプルです。実機の設定は変更されません。") 'Edge Box プレビュー' 'OK' $Icon)
}
function Save-PreviewImage($Window,[string]$Name) {
    $Window.PerformLayout()
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap $Window.Width,$Window.Height
    try {
        $Window.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle 0,0,$bitmap.Width,$bitmap.Height))
        if ($ScreenshotDirectory) {
            $destination = [IO.Path]::GetFullPath($ScreenshotDirectory)
            [void][IO.Directory]::CreateDirectory($destination)
            $bitmap.Save((Join-Path $destination ($Name+'.png')), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        [void]$script:Rendered.Add($Name)
    } finally { $bitmap.Dispose() }
    if ($script:PreviewErrors.Count) { throw $script:PreviewErrors[0] }
}
function Show-PreviewWindow($Window,[string]$Name) {
    $Window.Text = 'Edge Box プレビュー | ' + $Window.Text
    # In the all-in-one viewer, the first window of a screen is embedded instead of opened.
    # Windows opened from it (monitor, dialogs) stay ordinary modal windows.
    if ($script:ViewerEmbedNext) { $script:ViewerEmbedNext = $false; return (Invoke-ViewerEmbed $Window) }
    if ($SmokeTest) {
        $Window.StartPosition = 'Manual'
        $Window.Location = New-Object System.Drawing.Point -30000,-30000
        $Window.ShowInTaskbar = $false
        $Window.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Save-PreviewImage $Window $Name
        $Window.Close()
        return [System.Windows.Forms.DialogResult]::Cancel
    }
    if ($ScreenshotDirectory) {
        $previewName = $Name
        $Window.Add_Shown({ Save-PreviewImage $this $previewName }.GetNewClosure())
    }
    return $Window.ShowDialog()
}

$script:Cores = @()
for ($i=0; $i -lt 20; $i++) {
    $isP = $i -lt 8
    $lps = if ($isP) { @((2*$i), (2*$i+1)) } else { @(16+$i-8) }
    $script:Cores += [pscustomobject]@{
        Id=$i; Label=$(if($isP){'P'+$i}else{'E'+($i-8)}); Kind=$(if($isP){'P'}else{'E'});
        Lps=[int[]]$lps; State=$(if($i -lt 12){'Host'}else{'Guest'})
    }
}
$script:Tiles=@{}
$script:Hybrid=$true
$script:HyperVOk=$true
$script:VmNameSel='EdgeBox'
$script:Vm=[pscustomobject]@{Name='EdgeBox';State='Running'}
$script:UsedSnapshot=$false
$script:TotalLps=28
$script:VisibleLps=20
$script:Apps=@(
    [pscustomobject]@{Name='サンプル ブラウザー';Exe='C:\Preview\SampleBrowser.exe';Match='SampleBrowser';Lps=@(0,1,2,3);Priority='通常'},
    [pscustomobject]@{Name='サンプル エディター';Exe='C:\Preview\SampleEditor.exe';Match='SampleEditor';Lps=@(4,5,6,7);Priority='高'},
    [pscustomobject]@{Name='サンプル 収集アプリ';Exe='';Match='SampleCollector';Lps=@(16,17,18,19);Priority='通常'}
)
$ColHost=[CoreUi.Theme]::Win
$ColGuest=[CoreUi.Theme]::Edge

function Get-Selection {
    $hostCores=@($script:Cores | Where-Object {$_.State -eq 'Host'})
    $guestCores=@($script:Cores | Where-Object {$_.State -eq 'Guest'})
    return [pscustomobject]@{
        HostLps=@($hostCores | ForEach-Object {$_.Lps} | Sort-Object);
        GuestLps=@($guestCores | ForEach-Object {$_.Lps} | Sort-Object);
        HostCores=$hostCores.Count;GuestCores=$guestCores.Count;NoneCores=@($script:Cores | Where-Object {$_.State -eq 'None'}).Count
    }
}
function Show-CoreChooser([int[]]$Preselect,[string]$Title,[int[]]$GuestLps) {
    . (Join-Path $script:PreviewRoot 'core-chooser-layout.ps1')
    try {
        if ((Show-PreviewWindow $d 'cpu-core-chooser') -ne 'OK') { return $null }
        return ,@($script:Cores | Where-Object {$boxes[$_.Id] -and $boxes[$_.Id].Checked} | ForEach-Object {$_.Lps} | Sort-Object -Unique)
    } finally { $d.Dispose() }
}
function Show-ProcessPicker {
    . (Join-Path $script:PreviewRoot 'process-picker-layout.ps1')
    try {
        if ($lb.Items.Count) { $lb.SelectedIndex=0 }
        if ((Show-PreviewWindow $d 'cpu-process-picker') -ne 'OK' -or $lb.SelectedIndex -lt 0) { return $null }
        return $entries[$lb.SelectedIndex]
    } finally { $d.Dispose() }
}
function Show-InstalledAppPicker {
    . (Join-Path $script:PreviewRoot 'installed-app-picker-layout.ps1')
    try {
        if ($lv.Items.Count) { $lv.Items[0].Selected=$true }
        if ((Show-PreviewWindow $d 'cpu-installed-app-picker') -ne 'OK' -or $lv.SelectedIndices.Count -eq 0) { return $null }
        return $script:InstShown[$lv.SelectedIndices[0]]
    } finally { $d.Dispose() }
}
function Show-AppsDialog {
    . (Join-Path $script:PreviewRoot 'apps-layout.ps1')
    try {
        # Avoid displaying the real filesystem. Other add buttons open fixture pickers.
        $btnFile.Enabled=$false
        if ($lv.Items.Count) { $lv.Items[0].Selected=$true }
        if ((Show-PreviewWindow $d 'cpu-apps') -eq 'OK') {
            $script:Apps=@($work)
            if ($script:lblApps) { $script:lblApps.Text='登録: '+$script:Apps.Count+' 件 (プレビュー)' }
        }
    } finally { $d.Dispose() }
}

function Update-PreviewConsole {
    $sel=Get-Selection
    $script:rtb.Text="[サンプル] この画面の操作はプレビュー内だけで反映されます。`r`n[注意] 未割当のコア: $($sel.NoneCores) 個`r`n実機の設定・VM・アプリへの適用は行いません。"
    $script:chipVerdict.Text='プレビュー';$script:chipVerdict.Tone='Ok'
    $script:chipChange.Text='サンプル データ';$script:chipChange.Tone='Muted'
    Update-FooterLayout
}
function Update-Validation { Update-PreviewConsole }

function Get-Avg($Lps,[string]$Key) {
    $values=@($Lps | ForEach-Object {if($script:Stat[[int]$_]){[double]$script:Stat[[int]$_][$Key]}})
    if(-not $values.Count){return 0.0}
    return [double](($values|Measure-Object -Average).Average)
}
function Get-ContainState { return @{Text='完全分離: ○ 成立 (プレビュー用のサンプル データ)';Ok=$true} }
function Set-PreviewSample {
    $script:Plan=@{Host=@(0..19);Guest=@(20..27);Mode='full'}
    $script:Stat=@{}
    foreach($i in 0..27){
        $script:Stat[$i]=@{Win=$(if($i -lt 20){14+($i*7)%36}else{0.0});Vm=$(if($i -ge 20){35+($i*11)%43}else{0.0});Hv=0.6}
    }
    $script:RootTotal=Get-Avg @(0..19) 'Win';$script:RootTotal*=20
    $script:VmTotal=Get-Avg @(20..27) 'Vm';$script:VmTotal*=8
    $script:VpOk=$true;$script:lpName='PreviewCounter';$script:LeakVm=0.0;$script:LeakWin=0.0
    $script:LeakWindow=60;$script:LeakVmHist=@(0..59);$script:SelfPct=0.2
    $script:Mem=@{TotalGB=32.0;FreeGB=13.2;VmGB=8.0;VmState='Running';VmAssignedGB=8.0;WinCommitPct=49.0;WinPagesPerSec=0.0;VmReported=$true;VmVisibleGB=8.0;VmAvailGB=3.4;VmDemandGB=4.6;VmPressure=58;VmMemStatus='正常'}
}
function Show-PreviewMonitor {
    $VMName='Edge Box'
    Set-PreviewSample
    . (Join-Path $script:PreviewRoot 'monitor-drawing.ps1')
    . (Join-Path $script:PreviewRoot 'monitor-layout.ps1')
    try {
        $lblStatus.Text='プレビュー用のサンプル データ / 実機の測定は行いません'
        $chkTop.Add_CheckedChanged({$form.TopMost=$chkTop.Checked})
        $cmbIv.Add_SelectedIndexChanged({$timer.Interval=@(1000,2000,5000)[$cmbIv.SelectedIndex]})
        if($SmokeTest){
            $checkBitmap=New-Object System.Drawing.Bitmap 1120,556
            $checkGraphics=[System.Drawing.Graphics]::FromImage($checkBitmap)
            try{Draw-All $checkGraphics 1120 556}finally{$checkGraphics.Dispose();$checkBitmap.Dispose()}
        }
        [void](Show-PreviewWindow $form 'cpu-monitor')
    } finally {
        $timer.Stop();$timer.Dispose();$form.Dispose()
        foreach($resourceName in @('BrWin','BrVm','BrHv','BrWinBar','BrVmBar','BrFree','BrText','BrGray','BrP','BrE','BrBad','BrGood','BrBadMark','BrWinText','BrVmText','PenHost','PenGuest','PenNone','PenRule','FontNum')){
            $value=Get-Variable $resourceName -ValueOnly -ErrorAction SilentlyContinue
            if($value -is [IDisposable]){$value.Dispose()}
        }
    }
}

function Show-PreviewConsole {
    try {
        . (Join-Path $script:PreviewRoot 'console-layout.ps1')
        $form.Text='Edge Box プレビュー | CPU コア割り当て'
        $script:lblVm.Text='状態: Running    プロセッサ: 8    メモリ: 8 GB'
        $script:lblMemPc.Text='この PC のメモリ: 32 GB';$script:lblMemVm.Text='Edge Box に:'
        $script:lblMemHost.Text='→ Windows に残る: 24 GB';$script:lblMemNote.Text='現在の設定: 8 GB (サンプル)';$script:memBar.SetValues(32,8)
        $script:lblApps.Text='登録: 3 件 (プレビュー)'
        $script:btnMon.Add_Click({Show-PreviewMonitor})
        $script:btnApps.Add_Click({Show-AppsDialog})
        $script:btnApply.Add_Click({Show-Info 'この内容をプレビュー内で確認しました。'})
        $script:btnUndo.Add_Click({foreach($c in $script:Cores){$c.State='Host'};Sync-AllTiles;Update-PreviewConsole})
        $script:btnMem.Add_Click({$script:memBar.SetValues(32,[double]$script:numMem.Value);$script:lblMemHost.Text='→ Windows に残る: '+(32-[int]$script:numMem.Value)+' GB (プレビュー)'})
        Sync-AllTiles
        Update-PreviewConsole
        Show-Page 'core'
        if($SmokeTest){
            $form.StartPosition='Manual';$form.Location=New-Object System.Drawing.Point -30000,-30000;$form.ShowInTaskbar=$false
            $form.Show();[System.Windows.Forms.Application]::DoEvents()
            foreach($key in @('core','settings')){Show-Page $key;Update-CoreLayout;Save-PreviewImage $form ('cpu-console-'+$key)}
            Show-Page 'core'
            [System.Windows.Forms.Application]::DoEvents()
            $script:Tiles[12].PerformClick()
            if($script:Cores[12].State -ne 'None'){throw 'Core tile interaction failed'}
            if($script:cmbVm.Items.Count -ne 1){throw 'VM fixture was not used'}
            Show-Page 'core';Save-PreviewImage $form 'cpu-console-core-edited'
            $script:btnMon.PerformClick()
            Show-Page 'settings'
            [System.Windows.Forms.Application]::DoEvents()
            $script:btnApps.PerformClick()
            $form.Close()
        }else{[void](Show-PreviewWindow $form 'cpu-console-core')}
    } finally { if($form){$form.Dispose()} }
}

if ($LoadOnly) { return }
try {
    switch ($Screen) {
        'Console' { Show-PreviewConsole }
        'Monitor' { Show-PreviewMonitor }
        'Apps' { Show-AppsDialog }
        'CoreChooser' { [void](Show-CoreChooser @(0..7) 'コアの選択 - サンプル ブラウザー' @(20..27)) }
        'Processes' { [void](Show-ProcessPicker) }
        'InstalledApps' { [void](Show-InstalledAppPicker) }
    }
    if($script:PreviewErrors.Count){throw $script:PreviewErrors[0]}
    if($SmokeTest){Write-Output ('PASS: CPU '+$Screen+' ('+($script:Rendered -join ', ')+')')}
} finally {
    if($timer){$timer.Stop();$timer.Dispose()}
    if($form){$form.Dispose()}
    [System.Windows.Forms.Application]::remove_ThreadException($threadError)
}
