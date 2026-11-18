#requires -Version 5.1
param([string]$PreviewPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NetworkView.psm1') -Force
$count=0
function Assert($v,$s){if(-not $v){throw ('NETWORK_VIEW_TEST_FAILED: '+$s)};$script:count++}
$s=Get-DemoNetworkSnapshot;$s.Complete=$false;$s.Truncated=$true
$f=New-AppNetworkWindow -Snapshot $s -Demo
try{
    $f.ShowInTaskbar=$false;$f.StartPosition='Manual';$f.Location=New-Object Drawing.Point(-20000,-20000);$f.Show();[Windows.Forms.Application]::DoEvents()
    $g=$f.Controls.Find('NetworkRows',$true)[0];$n=$f.Controls.Find('NetworkNotice',$true)[0];$d=$f.Controls.Find('NetworkDetails',$true)[0]
    Assert ($g.Rows.Count -eq 2 -and $g.ReadOnly) 'synthetic read-only rows'
    Assert ($n.Text -match '不完全' -and $n.Text -match 'UDP/QUIC') 'limits visible'
    Assert ($f.Text -match '合成デモ') 'demo labeled'
    $g.CurrentCell=$g.Rows[1].Cells[0];$g.CurrentCell=$g.Rows[0].Cells[0];[Windows.Forms.Application]::DoEvents()
    Assert ($d.Text -match 'X:\\DEMO' -and $d.Text -match 'Synthetic demonstration only') 'local identity and evidence detail'
    Assert ($g.Rows[0].Cells['Certainty'].Value -match '候補' -and $g.Rows[1].Cells['Certainty'].Value -match '不明') 'never asserts ownership'
    Assert ($f.CancelButton.Name -eq 'CloseNetwork' -and $f.AcceptButton.Name -eq 'CloseNetwork') 'only close action'
    $f.Size=New-Object Drawing.Size(950,620);[Windows.Forms.Application]::DoEvents()
    Assert ($g.Width -gt 600 -and $g.Height -gt 100) 'minimum layout remains readable'
    if($PreviewPath){$f.Size=New-Object Drawing.Size(1180,740);[Windows.Forms.Application]::DoEvents();$b=New-Object Drawing.Bitmap($f.Width,$f.Height);try{$f.DrawToBitmap($b,(New-Object Drawing.Rectangle(0,0,$f.Width,$f.Height)));$b.Save($PreviewPath)}finally{$b.Dispose()}}
    $f.Close()
}finally{$f.Dispose()}
Write-Output ('PASS network-view assertions='+$count+'; synthetic offscreen UI only')
