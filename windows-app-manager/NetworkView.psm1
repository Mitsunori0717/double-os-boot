#requires -Version 5.1
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
function Get-NvText($v){$s=[string]$v;$s=$s -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' ';if($s.Length -gt 600){$s=$s.Substring(0,600)};return $s}
function Get-DemoNetworkSnapshot {
    [pscustomobject]@{SchemaVersion=1;ObservedUtc=[DateTime]::UtcNow.ToString('o');Complete=$true;Truncated=$false;EndpointLimit=500;Errors=@();Endpoints=@(
        [pscustomobject]@{LocalAddress='192.0.2.20';LocalPort=50123;RemoteAddress='198.51.100.10';RemotePort=443;State='Established';OwningProcess=4242;ProcessName='demo-browser';ProcessPath='X:\DEMO\Browser\browser.exe';AttributionStatus='Candidate';CandidateApps=@([pscustomobject]@{Id='demo';DisplayName='Demo Browser';Basis='Synthetic demonstration only'})},
        [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=54321;RemoteAddress='0.0.0.0';RemotePort=0;State='Listen';OwningProcess=4300;ProcessName='demo-helper';ProcessPath='';AttributionStatus='Unknown';CandidateApps=@()}
    );Limitations=@('Synthetic data, not this computer. No real connections measured.')}
}
function New-AppNetworkWindow {
    [CmdletBinding()]param([Parameter(Mandatory)]$Snapshot,[switch]$Demo)
    $f=New-Object Windows.Forms.Form;$f.Text='現在のTCP接続 | 読み取り専用'+$(if($Demo){' [合成デモ]'}else{''});$f.Size=New-Object Drawing.Size(1180,740);$f.MinimumSize=New-Object Drawing.Size(950,620);$f.StartPosition='CenterParent';$f.Font=New-Object Drawing.Font('Yu Gothic UI',10);$f.AutoScaleMode='Dpi'
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(14);$layout.ColumnCount=1;$layout.RowCount=4
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,110)));$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)));$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,160)));$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,45)));$f.Controls.Add($layout)
    $notice=New-Object Windows.Forms.TextBox;$notice.Name='NetworkNotice';$notice.Multiline=$true;$notice.ReadOnly=$true;$notice.ScrollBars='Vertical';$notice.Dock='Fill'
    $notice.Text="観測時刻 (UTC): "+$Snapshot.ObservedUtc+' / '+@($Snapshot.Endpoints).Count+" 行`r`n現在のTCPだけを1回読み取った結果です。継続監視・通信内容の解析・外部送信・自動保存はしません。`r`nUDP/QUIC・過去の通信は対象外。未表示＝通信なしではありません。通信先IPだけで流出・不正・安全を判断できません。`r`nアプリ名は実行パスと登録場所からの候補。共有プロセス・PIDの変化・アクセス拒否などで特定できない場合があります。"
    if(-not $Snapshot.Complete -or $Snapshot.Truncated){$notice.Text+="`r`n注意: 結果は不完全または件数上限で省略されています。"}
    if(@($Snapshot.Errors).Count -gt 0){$notice.Text+="`r`n確認コード: "+(@($Snapshot.Errors|ForEach-Object{Get-NvText $_.Code})-join ', ')}
    $layout.Controls.Add($notice,0,0)
    $g=New-Object Windows.Forms.DataGridView;$g.Name='NetworkRows';$g.Dock='Fill';$g.ReadOnly=$true;$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.RowHeadersVisible=$false;$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g.AutoSizeColumnsMode='Fill';$g.BackgroundColor=[Drawing.Color]::White
    foreach($col in @(@('Process','プロセス / PID',100),@('Remote','相手IP : port',130),@('Local','ローカルIP : port',130),@('State','TCP状態',70),@('App','関連アプリ候補',130),@('Certainty','関連の確かさ',100))){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$col[0];$c.HeaderText=$col[1];$c.FillWeight=$col[2];$null=$g.Columns.Add($c)}
    $details=New-Object Windows.Forms.TextBox;$details.Name='NetworkDetails';$details.Dock='Fill';$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.Text='行を選ぶと、ローカルでのみプロセスパスと候補の根拠を表示します。'
    foreach($e in @($Snapshot.Endpoints)){
        $apps=@($e.CandidateApps|ForEach-Object{Get-NvText $_.DisplayName})-join ', '
        $certainty=if($e.AttributionStatus -eq 'Candidate'){'候補のみ・未確定'}else{'不明・特定できず'}
        $i=$g.Rows.Add((Get-NvText ($e.ProcessName+' / '+$e.OwningProcess)),(Get-NvText ($e.RemoteAddress+' : '+$e.RemotePort)),(Get-NvText ($e.LocalAddress+' : '+$e.LocalPort)),(Get-NvText $e.State),$apps,$certainty);$g.Rows[$i].Tag=$e
    }
    $g.add_SelectionChanged({param($sender,$eventArgs)
        if($sender.SelectedRows.Count -eq 0){return};$e=$sender.SelectedRows[0].Tag;if($null -eq $e){return}
        $d=$sender.FindForm().Controls.Find('NetworkDetails',$true)[0]
        $d.Text="ローカル表示のみ。パスやIPを共有する際は内容を確認してください。`r`nプロセス: "+(Get-NvText $e.ProcessName)+' / PID '+$e.OwningProcess+"`r`n実行パス: "+(Get-NvText $e.ProcessPath)+"`r`n接続: "+(Get-NvText ($e.LocalAddress+':'+$e.LocalPort+' -> '+$e.RemoteAddress+':'+$e.RemotePort))+"`r`n関連状態: "+(Get-NvText $e.AttributionStatus)+"`r`n候補の根拠: "+(@($e.CandidateApps|ForEach-Object{(Get-NvText $_.DisplayName)+' / '+(Get-NvText $_.Basis)})-join '; ')+"`r`n通信内容・送信データ・無断導入の有無は、この結果では分かりません。"
    })
    $layout.Controls.Add($g,0,1);$layout.Controls.Add($details,0,2)
    $close=New-Object Windows.Forms.Button;$close.Name='CloseNetwork';$close.Text='閉じる';$close.Dock='Right';$close.Width=130;$close.DialogResult='Cancel';$layout.Controls.Add($close,0,3);$f.CancelButton=$close;$f.AcceptButton=$close;$f.ActiveControl=$close
    return $f
}
Export-ModuleMember -Function New-AppNetworkWindow,Get-DemoNetworkSnapshot
