#requires -Version 5.1
param([string]$PreviewPath,[string]$FilePreviewPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$am=Import-Module (Join-Path $root 'AppManager.psm1') -PassThru -Force
$av=Import-Module (Join-Path $root 'AssessmentView.psm1') -PassThru
$ac=Import-Module (Join-Path $root 'AppAssessment.psm1') -PassThru
$count=0
function Assert($v,$s){if(-not $v){throw ('ASSESSMENT_VIEW_FAIL: '+$s)};$script:count++}
# No live inventory or evidence read is allowed in this UI test.
& $am {function script:Get-AppInventory {throw 'LIVE_QUERY_FORBIDDEN'};function script:Get-AppEvidence {throw 'FILE_SCAN_FORBIDDEN'}}
$records=@((Get-DemoAppInventory).Records);$record=$records[0]
$e=& $am {param($r) Get-DemoLocalEvidence $r} $record
$a=& $ac {param($r,$e) Get-AppAssessment -Record $r -AppEvidence $e} $record $e
$before=$record|ConvertTo-Json -Depth 20 -Compress
$f=New-AppAssessmentWindow -Record $record -Assessment $a -AppEvidence $e -Demo
try{
    $f.ShowInTaskbar=$false;$f.StartPosition='Manual';$f.Location=New-Object Drawing.Point(-20000,-20000);$f.Show();[Windows.Forms.Application]::DoEvents()
    $tabs=$f.Controls.Find('AssessmentTabs',$true)[0]
    Assert ($tabs.TabPages.Count -eq 4) 'four evidence views'
    Assert ($f.Text -match '合成デモ') 'demo label'
    Assert (@($tabs.TabPages|Where-Object{-not $_.Controls[0].ReadOnly}).Count -eq 0) 'all views read-only'
    $overview=$tabs.TabPages[0].Controls[0].Text
    Assert ($overview -match '削除の保護条件を変更しません' -and $overview -match '未認証|認証では') 'not safety or eligibility claim'
    Assert ($overview -match '7-Zip') 'selected record shown'
    Assert ($tabs.TabPages[1].Controls[0].Text -match 'インストール登録') 'separate evidence labels'
    Assert ($tabs.TabPages[2].Controls[0].Text -match '署名用の構造あり' -and $tabs.TabPages[2].Controls[0].Text -match '未検証') 'signature structure not trust'
    Assert ($tabs.TabPages[2].Controls[0].Text -match 'X:\\DEMO' -and $tabs.TabPages[2].Controls[0].Text -match 'SHA-256') 'explicit file identity locally visible'
    Assert ($tabs.TabPages[3].Controls[0].Text -match '自動では開きません' -and $tabs.TabPages[3].Controls[0].Text -match '全ソフト一覧を送らない') 'manual research privacy'
    Assert ($f.AcceptButton.Name -eq 'CloseAssessment' -and $f.CancelButton.Name -eq 'CloseAssessment') 'no execution action'
    foreach($target in @(@($PreviewPath,0),@($FilePreviewPath,2))){if($target[0]){$tabs.SelectedIndex=$target[1];[Windows.Forms.Application]::DoEvents();$b=New-Object Drawing.Bitmap($f.Width,$f.Height);try{$f.DrawToBitmap($b,(New-Object Drawing.Rectangle(0,0,$f.Width,$f.Height)));$b.Save([string]$target[0])}finally{$b.Dispose()}}}
    $f.Size=New-Object Drawing.Size(850,620);[Windows.Forms.Application]::DoEvents();Assert ($tabs.Width -gt 700 -and $tabs.Height -gt 350) 'minimum window remains useful'
    $f.Close()
}finally{$f.Dispose()}
Assert (($record|ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'view never mutates record or protection'
$unknown=$records[4];$ua=& $ac {param($r) Get-AppAssessment -Record $r} $unknown
$text=Format-AppAssessmentText $unknown $ua
Assert ($text -match '用途不明') 'unknown is explicitly unknown'
$noFile=Format-AppEvidenceText $null;Assert ($noFile -match '未実施') 'no file claim without reading'
Write-Output ('PASS assessment-view assertions='+$count+'; synthetic offscreen forms only')
