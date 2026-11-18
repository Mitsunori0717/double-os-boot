#requires -Version 5.1
param([string]$PreviewPath)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'STA_REQUIRED'}
$m=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AppManager.psm1') -PassThru -Force
$count=0
function Assert($v,$s){if(-not $v){throw ('FAIL UI: '+$s)};$script:count++}
# Any accidental inventory on the real machine is fatal. Demo remains synthetic.
& $m {function script:Get-AppInventory {throw 'REAL_INVENTORY_FORBIDDEN_IN_UI_TEST'}}
$f=New-AppManagerWindow -Demo
try{
    $f.ShowInTaskbar=$false;$f.StartPosition='Manual';$f.Location=New-Object Drawing.Point(-20000,-20000);$f.Show();[Windows.Forms.Application]::DoEvents()
    $u=& $m {$script:Ui}
    Assert ($u.Grid.Rows.Count -eq 5) 'demo records'
    Assert (@($u.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}).Count -eq 0) 'default unchecked'
    Assert (-not $u.Run.Enabled -and -not $u.Review.Enabled) 'nothing ready'
    Assert ($u.Grid.Rows[2].Cells['Select'].ReadOnly -and $u.Grid.Rows[3].Cells['Select'].ReadOnly -and $u.Grid.Rows[4].Cells['Select'].ReadOnly) 'protected unknown disabled'
    $u.SelectEligible.PerformClick();[Windows.Forms.Application]::DoEvents()
    Assert (@($u.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}).Count -eq 2) 'select eligible only'
    $u.Review.PerformClick()
    Assert ($null -ne $u.Plan -and @($u.Plan.Items).Count -eq 2) 'review plan'
    Assert (-not $u.Run.Enabled) 'demo execution cannot enable'
    $u.Search.Text='Chrome';[Windows.Forms.Application]::DoEvents()
    Assert ($null -eq $u.Plan) 'filter invalidates plan'
    Assert (@($u.Grid.Rows|Where-Object Visible).Count -eq 1) 'literal search filters'
    Assert (@($u.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}).Count -eq 1) 'hidden selections cleared'
    $u.Clear.PerformClick();Assert (@($u.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}).Count -eq 0) 'clear all'
    $u.Search.Text='';$u.SelectEligible.PerformClick();$u.Review.PerformClick();$u.Refresh.PerformClick()
    Assert ($null -eq $u.Plan -and -not $u.Run.Enabled) 'refresh invalidates selection/plan'
    $u.Grid.CurrentCell=$u.Grid.Rows[3].Cells['Name'];[Windows.Forms.Application]::DoEvents()
    Assert ($u.Details.Text -match 'PossibleHardwareDependency') 'protection detail'
    Assert ($u.Details.Text -notmatch 'UninstallString|MsiExec.exe') 'no command string in detail'
    $f.Size=New-Object Drawing.Size(1000,740);[Windows.Forms.Application]::DoEvents()
    Assert ($u.Cancel.Bottom -le $u.Cancel.Parent.ClientSize.Height) 'cancel visible at minimum width'
    Assert ($u.Selection.Bottom -le $u.Selection.Parent.ClientSize.Height) 'selection count visible at minimum width'
    $f.Size=New-Object Drawing.Size(1260,850);[Windows.Forms.Application]::DoEvents()
    if($PreviewPath){$b=New-Object Drawing.Bitmap($f.Width,$f.Height);try{$f.DrawToBitmap($b,(New-Object Drawing.Rectangle(0,0,$f.Width,$f.Height)));$b.Save($PreviewPath)}finally{$b.Dispose()}}
    & $m {Set-UiBusy $true;$script:Ui.Shared=[hashtable]::Synchronized(@{CancelRequested=$false})}
    $u.Cancel.PerformClick();Assert $u.Shared.CancelRequested 'cancel requests next-only'
    $f.Close();Assert (-not $f.IsDisposed) 'busy close blocked'
    & $m {Set-UiBusy $false};$f.Close()
}finally{$f.Dispose()}
$f=New-AppManagerWindow
try{
    $f.ShowInTaskbar=$false;$f.StartPosition='Manual';$f.Location=New-Object Drawing.Point(-20000,-20000);$f.Show();[Windows.Forms.Application]::DoEvents();$u=& $m {$script:Ui}
    Assert ($u.Grid.Rows.Count -eq 0 -and $null -eq $u.Inventory) 'no startup real query'
    & $m {Show-UiInventory (Get-DemoAppInventory)};$u.SelectEligible.PerformClick();$u.Review.PerformClick()
    Assert ($u.Run.Enabled) 'non-demo eligible preview can prepare only'
    $u.Refresh.PerformClick()
    Assert ($null -eq $u.Inventory -and $u.Grid.Rows.Count -eq 0 -and -not $u.Run.Enabled) 'failed query clears stale plan'
    # Synthetic asynchronous completion exercises the UI but never loads/executes an installer.
    & $m {
        $script:Ui.Worker=[PowerShell]::Create();$script:Ui.Runspace=[RunspaceFactory]::CreateRunspace();$script:Ui.Runspace.Open();$script:Ui.Worker.Runspace=$script:Ui.Runspace
        $null=$script:Ui.Worker.AddScript('[pscustomobject]@{State="SyntheticComplete";Results=@();RemovalVerified=$false}')
        $script:Ui.Async=$script:Ui.Worker.BeginInvoke();Set-UiBusy $true
    }
    while(-not $u.Async.IsCompleted){Start-Sleep -Milliseconds 10}
    & $m {Complete-UiBatch}
    Assert (-not $u.Busy -and -not $u.Grid.Enabled -and -not $u.Run.Enabled -and $null -eq $u.Plan) 'completion requires fresh list'
    Assert ($u.Status.Text -match 'SyntheticComplete') 'result status'
    & $m {Show-UiInventory (Get-DemoAppInventory)}
    Assert $u.Grid.Enabled 'successful refresh re-enables grid after batch'
    $f.Close()
}finally{$f.Dispose()}
Write-Output ('PASS UI assertions='+$count+'; synthetic offscreen forms only, no machine inventory/uninstall')
