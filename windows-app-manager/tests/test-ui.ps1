#requires -Version 5.1
param([string]$PreviewPath)
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'STA_REQUIRED'}
$m=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AppManager.psm1') -PassThru -Force
$count=0
function Assert($v,$s){if(-not $v){throw ('FAIL UI: '+$s)};$script:count++}
# Any accidental inventory on the real machine is fatal. Demo remains synthetic.
& $m {
    function script:Get-AppInventory {throw 'REAL_INVENTORY_FORBIDDEN_IN_UI_TEST'}
    function script:Get-AppEvidence {throw 'REAL_FILE_EVIDENCE_FORBIDDEN_IN_UI_TEST'}
    function script:Start-Process {throw 'REAL_PROCESS_FORBIDDEN_IN_UI_TEST'}
    $script:AssessmentCalls=@()
    function script:Show-UiAssessment($Record,$Evidence=$null){
        $script:AssessmentCalls+= [pscustomobject]@{Record=$Record;Evidence=$Evidence}
    }
}
$f=New-AppManagerWindow -Demo
try{
    $f.ShowInTaskbar=$false;$f.StartPosition='Manual';$f.Location=New-Object Drawing.Point(-20000,-20000);$f.Show();[Windows.Forms.Application]::DoEvents()
    $u=& $m {$script:Ui}
    Assert ($u.Grid.Rows.Count -eq 5) 'demo records'
    Assert ($u.Assessments.Count -eq 5) 'assessment cached for every row'
    Assert ($u.Grid.Columns['Confidence'].ReadOnly) 'confidence column read only'
    foreach($row in $u.Grid.Rows){
        $a=$u.Assessments[[string]$row.Tag.Id]
        Assert ($null -ne $a -and $a.DisplayOnly) 'row assessment present display only'
        $expected=& $m {param($a) Get-UiAssessmentConfidence $a} $a
        Assert ($row.Cells['Confidence'].Value -eq $expected) 'row confidence matches cached assessment'
        Assert ($row.Cells['Purpose'].Value -eq $a.Summary) 'row purpose matches assessment'
    }
    $u.Assessments['StaleSynthetic']='old';$u.Evidences['StaleSynthetic']='old'
    $u.Refresh.PerformClick()
    Assert ($u.Assessments.Count -eq 5 -and -not $u.Assessments.ContainsKey('StaleSynthetic') -and $u.Evidences.Count -eq 0) 'successful refresh clears cached evidence and reassesses'

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
    $u.Evidences['StaleSynthetic']='old'
    $u.Refresh.PerformClick()
    Assert ($u.Assessments.Count -eq 0 -and $u.Evidences.Count -eq 0) 'failed refresh clears caches'
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
    # Only synthetic PowerShell results cross this runspace boundary. No module
    # imports, inventory, file reads, signature provider, process or network calls.
    $eligibilityBefore=$u.Eligibility|ConvertTo-Json -Compress
    $inventoryBefore=$u.Inventory|ConvertTo-Json -Depth 20 -Compress
    foreach($scenario in @('Success','Cancelled','Empty','Multiple','Error','Throw')){
        & $m {param($case)
            $script:Ui.SelectEligible.PerformClick();$script:Ui.Review.PerformClick()
            $script:Ui.WorkerKind='Evidence';$script:Ui.EvidenceRecord=$script:Ui.Inventory.Records[0]
            $script:Ui.Shared=[hashtable]::Synchronized(@{CancelRequested=$false})
            $script:Ui.Worker=[PowerShell]::Create();$script:Ui.Runspace=[RunspaceFactory]::CreateRunspace();$script:Ui.Runspace.Open();$script:Ui.Worker.Runspace=$script:Ui.Runspace
            $code=switch($case){
                'Empty' {''}
                'Multiple' {'[pscustomobject]@{Marker="One"};[pscustomobject]@{Marker="Two"}'}
                'Error' {'Write-Error "PRIVATE_UI_ERROR_9371";[pscustomobject]@{Marker="DoNotDisplay"}'}
                'Throw' {'throw "PRIVATE_UI_ERROR_9371"'}
                default {'[pscustomobject]@{Kind="AppLocalEvidence";Marker="SyntheticEvidence"}'}
            }
            $null=$script:Ui.Worker.AddScript($code);$script:Ui.Async=$script:Ui.Worker.BeginInvoke();Set-UiBusy $true
        } $scenario
        Assert ($u.Busy -and -not $u.Inspect.Enabled -and -not $u.FileEvidence.Enabled) 'evidence busy disables entry points'
        if($scenario -eq 'Cancelled'){$u.Cancel.PerformClick();Assert $u.Shared.CancelRequested 'evidence cancel records discard request'}
        while(-not $u.Async.IsCompleted){Start-Sleep -Milliseconds 10}
        & $m {Complete-UiBatch}
        Assert (-not $u.Busy -and $null -eq $u.Async -and $u.Grid.Enabled -and $u.Inspect.Enabled -and $u.FileEvidence.Enabled) 'evidence completion restores UI'
        Assert ($null -eq $u.Plan -and -not $u.Run.Enabled) 'evidence completion invalidates previous removal plan'
        $calls=@(& $m {$script:AssessmentCalls})
        Assert ($calls.Count -eq 1) 'only one successful evidence result invokes mocked assessment'
        Assert ($calls[0].Evidence.Marker -eq 'SyntheticEvidence' -and $calls[0].Record.Id -eq $u.Inventory.Records[0].Id) 'evidence bound to selected record'
        Assert ($u.Status.Text -notmatch 'PRIVATE_UI_ERROR_9371' -and $u.Details.Text -notmatch 'PRIVATE_UI_ERROR_9371') 'worker exception raw data not displayed'
        Assert (($u.Eligibility|ConvertTo-Json -Compress) -eq $eligibilityBefore) 'evidence does not change removal eligibility'
        Assert (($u.Inventory|ConvertTo-Json -Depth 20 -Compress) -eq $inventoryBefore) 'evidence does not mutate inventory protection'
    }

    $f.Close()
}finally{$f.Dispose()}
Write-Output ('PASS UI assertions='+$count+'; synthetic offscreen forms only, no machine inventory/uninstall')
