#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'AppInventory.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SafeUninstall.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NetworkView.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:Ui=$null
function Get-UiValue($o,[string]$n,$fallback=''){if($null -eq $o){return $fallback};$p=$o.PSObject.Properties[$n];if($null -ne $p){return $p.Value};return $fallback}
function Get-UiText([string]$s){$s=$s -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' ';if($s.Length -gt 300){$s=$s.Substring(0,300)+'…'};return $s}
function Get-DemoAppInventory {
    $m=Get-Module AppInventory
    $rows=@();$i=0
    foreach($sample in @(@('7-Zip 24.09','Igor Pavlov','24.09'),@('Google Chrome','Google LLC','131.0'),@('Microsoft Visual C++ Runtime','Microsoft Corporation','14.42'),@('NVIDIA Graphics Driver','NVIDIA Corporation','566.14'),@('Unknown Vendor Helper','Unverified vendor','1.0'))){
        $i++;$guid='{'+('00000000-0000-0000-0000-'+$i.ToString('000000000000'))+'}'
        $entry=@{DisplayName=$sample[0];Publisher=$sample[1];DisplayVersion=$sample[2];WindowsInstaller=1;UninstallString=('MsiExec.exe /I'+$guid);InstallDate='20260101'}
        $source=[pscustomobject][ordered]@{Kind='Registry';UserSid='S-1-5-21-100-100-100-1001';Hive='LocalMachine';View='Registry64';Key=('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$guid);PackageFullName=''}
        $rows+= & $m {param($e,$s) New-AiRecord $e $s} $entry $source
    }
    [pscustomobject]@{SchemaVersion=1;Kind='WindowsAppInventory';Complete=$true;ReadOnly=$true;AppxIncluded=$false;Records=$rows;Errors=@();CollectedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Set-UiStatus([string]$s){$script:Ui.Status.Text=$s}
function Reset-UiPlan {$script:Ui.Plan=$null;$script:Ui.Run.Enabled=$false}
function Update-UiSelection {
    if($null -eq $script:Ui){return};Reset-UiPlan
    $count=@($script:Ui.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}).Count
    $script:Ui.Review.Enabled=($count -gt 0 -and -not $script:Ui.Busy)
    $script:Ui.Selection.Text=('選択 '+$count+' 件 / 最大50件')
}
function Show-UiInventory($Inventory) {
    $script:Ui.Inventory=$Inventory;$script:Ui.Grid.Enabled=(-not $script:Ui.Busy);$script:Ui.Grid.Rows.Clear();$script:Ui.Eligibility=@{}
    foreach($r in @($Inventory.Records)){
        $id=[string]$r.Id;$reason='';$allowed=$false
        try {$null=New-SafeUninstallPlan -Inventory $Inventory -SelectedIds @($id);$allowed=$true}catch{$reason=$_.Exception.Message}
        $script:Ui.Eligibility[$id]=$allowed
        $protected=[bool]$r.Protection.Protected
        $status=if($protected){'保護・要確認'}elseif($allowed){'MSI候補・実体は再確認'}else{'Windows設定で個別確認'}
        $purpose=Get-UiValue $r 'PurposeSummary' ([string]$r.Category)
        $index=$script:Ui.Grid.Rows.Add($false,(Get-UiText $r.DisplayName),(Get-UiText $r.DisplayVersion),(Get-UiText $r.Publisher),$purpose,$status)
        $row=$script:Ui.Grid.Rows[$index];$row.Tag=$r;$row.Cells['Select'].ReadOnly=(-not $allowed)
        if(-not $allowed){$row.DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(110,117,126);$row.Cells['Select'].Style.BackColor=[Drawing.Color]::FromArgb(234,237,241)}
        $row.Cells['Status'].ToolTipText=$reason
    }
    $script:Ui.Selection.Text='選択 0 件 / 最大50件';$script:Ui.Details.Text='行を選択すると、用途の推定根拠・保護理由・確認できないことを表示します。'
    $script:Ui.SelectEligible.Enabled=($Inventory.Complete -and -not $script:Ui.Busy)
    Set-UiStatus ('登録 '+@($Inventory.Records).Count+' 件。用途は推定です。通信・無断インストール・不要性は判定していません。'+$(if(-not $Inventory.Complete){' 一覧取得が不完全のため一括処理は無効です。'}else{''}))
    Reset-UiPlan
}
function Set-UiBusy([bool]$Busy){
    $script:Ui.Busy=$Busy
    foreach($c in @($script:Ui.Refresh,$script:Ui.Appx,$script:Ui.Search,$script:Ui.SelectEligible,$script:Ui.Clear,$script:Ui.Settings,$script:Ui.Network,$script:Ui.Grid)){$c.Enabled=(-not $Busy)}
    $script:Ui.Review.Enabled=$false;$script:Ui.Run.Enabled=$false;$script:Ui.Cancel.Enabled=$Busy
}
function Start-UiBatch {
    if($script:Ui.Demo -or $null -eq $script:Ui.Plan -or $script:Ui.Busy){return}
    $dialog=New-Object Windows.Forms.SaveFileDialog
    $dialog.Title='新しい実行ログの保存先を選択';$dialog.Filter='JSON Lines (*.jsonl)|*.jsonl';$dialog.FileName=('app-removal-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'.jsonl');$dialog.OverwritePrompt=$true
    if($dialog.ShowDialog($script:Ui.Form) -ne [Windows.Forms.DialogResult]::OK){$dialog.Dispose();return}
    $log=$dialog.FileName;$dialog.Dispose()
    if(Test-Path -LiteralPath $log){[Windows.Forms.MessageBox]::Show('既存ログは上書きしません。新しいファイル名を選んでください。','保存先',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null;return}
    $script:Ui.Shared=[hashtable]::Synchronized(@{CancelRequested=$false})
    $ps=[PowerShell]::Create();$rs=[RunspaceFactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open();$ps.Runspace=$rs
    $worker={param($ModulePath,$Plan,$LogPath,$Shared)
        $ErrorActionPreference='Stop'
        try {
            Import-Module $ModulePath -Force
            $token=Request-SafeUninstallConfirmation -Plan $Plan
            if([string]::IsNullOrEmpty($token)){return [pscustomobject]@{State='NotConfirmed';Results=@()}}
            Invoke-SafeUninstallPlan -Plan $Plan -ConfirmationToken $token -LogPath $LogPath -CancellationRequested {return [bool]$Shared.CancelRequested}
        }catch{
            $code='UNEXPECTED_ERROR';if($_.Exception.Message -cmatch '^[A-Z][A-Z0-9_]{1,100}$'){$code=$_.Exception.Message}
            [pscustomobject]@{State='PreflightOrExecutionBlocked';ReasonCode=$code;ExceptionType=$_.Exception.GetType().FullName;HResult=$_.Exception.HResult;Results=@();RemovalVerified=$false;LogMayNotExist=$true}
        }
    }
    $null=$ps.AddScript($worker.ToString()).AddArgument((Join-Path $PSScriptRoot 'SafeUninstall.psm1')).AddArgument($script:Ui.Plan).AddArgument($log).AddArgument($script:Ui.Shared)
    $script:Ui.Worker=$ps;$script:Ui.Runspace=$rs;$script:Ui.LogPath=$log
    Set-UiBusy $true;Set-UiStatus '確認ダイアログで対象を再確認してください。実行中のアンインストーラーは強制終了しません。'
    try{$script:Ui.Async=$ps.BeginInvoke();$script:Ui.Timer.Start()}catch{Set-UiBusy $false;$ps.Dispose();$rs.Dispose();Set-UiStatus '処理を開始できませんでした。対象は再確認してください。'}
}
function Complete-UiBatch {
    if($null -eq $script:Ui.Async -or -not $script:Ui.Async.IsCompleted){return}
    $script:Ui.Timer.Stop()
    try{
        $result=@($script:Ui.Worker.EndInvoke($script:Ui.Async))
        if($script:Ui.Worker.HadErrors -or $result.Count -eq 0){Set-UiStatus '処理は完了していません。ログを確認し、一覧を再取得してください。'}
        else{
            $last=$result[-1];Set-UiStatus ('処理状態: '+$last.State+' / ログ: '+$script:Ui.LogPath)
            $script:Ui.Details.Text="結果（削除の完全性は未検証）`r`n"+($last|ConvertTo-Json -Depth 6)+"`r`n`r`n一覧を再取得して確認してください。再起動は自動実行しません。"
        }
    }catch{Set-UiStatus '処理を停止しました。ログとWindows側の表示を確認してください。'}
    finally{$script:Ui.Worker.Dispose();$script:Ui.Runspace.Dispose();$script:Ui.Async=$null;Set-UiBusy $false;$script:Ui.Grid.Enabled=$false;$script:Ui.SelectEligible.Enabled=$false;$script:Ui.Plan=$null}
}
function New-AppManagerWindow {
    [CmdletBinding()]param([switch]$Demo)
    [Windows.Forms.Application]::EnableVisualStyles()
    $f=New-Object Windows.Forms.Form;$f.Text='BEラボ | アプリ整理';$f.Size=New-Object Drawing.Size(1260,850);$f.MinimumSize=New-Object Drawing.Size(1000,700);$f.StartPosition='CenterScreen';$f.Font=New-Object Drawing.Font('Yu Gothic UI',10);$f.BackColor=[Drawing.Color]::FromArgb(245,247,250);$f.AutoScaleMode='Dpi'
    $layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(20);$layout.ColumnCount=1;$layout.RowCount=7
    foreach($h in @(65,90,48,-1,180,100,52)){if($h -lt 0){$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))}else{$null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$h)))}}
    $f.Controls.Add($layout)
    $title=New-Object Windows.Forms.Label;$title.Dock='Fill';$title.Font=New-Object Drawing.Font('Yu Gothic UI',19,[Drawing.FontStyle]::Bold);$title.ForeColor=[Drawing.Color]::FromArgb(26,43,65);$title.Text="アプリを見える化して、安全に整理`r`n";$title.AutoSize=$false;$layout.Controls.Add($title,0,0)
    $tools=New-Object Windows.Forms.FlowLayoutPanel;$tools.Dock='Fill';$tools.WrapContents=$true;$layout.Controls.Add($tools,0,1)
    function MakeButton([string]$text,[int]$width){$b=New-Object Windows.Forms.Button;$b.Text=$text;$b.Size=New-Object Drawing.Size($width,36);$b.FlatStyle='Flat';$b.BackColor=[Drawing.Color]::White;$tools.Controls.Add($b);return $b}
    $refresh=MakeButton '一覧を読み取る' 140;$appx=New-Object Windows.Forms.CheckBox;$appx.Text='Storeアプリも表示';$appx.Width=185;$appx.Height=36;$tools.Controls.Add($appx)
    $search=New-Object Windows.Forms.TextBox;$search.Width=230;$search.Margin=New-Object Windows.Forms.Padding(12,7,8,3);$tools.Controls.Add($search)
    $settings=MakeButton 'Windowsの設定で確認' 190;$network=MakeButton '現在のTCPを観測' 170
    $notice=New-Object Windows.Forms.Label;$notice.Dock='Fill';$notice.Text='検索: 名前・発行元   |   OS / ドライバ / 共有部品 / セキュリティ / 不明は保護。通信や不正の監視・判定ツールではありません。';$notice.ForeColor=[Drawing.Color]::FromArgb(80,90,105);$layout.Controls.Add($notice,0,2)
    $g=New-Object Windows.Forms.DataGridView;$g.Dock='Fill';$g.AllowUserToAddRows=$false;$g.AllowUserToDeleteRows=$false;$g.AllowUserToResizeRows=$false;$g.RowHeadersVisible=$false;$g.SelectionMode='FullRowSelect';$g.MultiSelect=$false;$g.BackgroundColor=[Drawing.Color]::White;$g.BorderStyle='None';$g.AutoSizeColumnsMode='Fill';$g.RowTemplate.Height=36;$g.ClipboardCopyMode='Disable';$g.EnableHeadersVisualStyles=$false;$g.ColumnHeadersDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(229,235,243);$g.ColumnHeadersHeight=38
    $check=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$check.Name='Select';$check.HeaderText='選択';$check.FillWeight=28;$null=$g.Columns.Add($check)
    foreach($col in @(@('Name','アプリ',150),@('Version','バージョン',65),@('Publisher','発行元（申告）',110),@('Purpose','用途（推定）',110),@('Status','処理の扱い',130))){$c=New-Object Windows.Forms.DataGridViewTextBoxColumn;$c.Name=$col[0];$c.HeaderText=$col[1];$c.FillWeight=$col[2];$c.ReadOnly=$true;$null=$g.Columns.Add($c)}
    $layout.Controls.Add($g,0,3)
    $details=New-Object Windows.Forms.TextBox;$details.Dock='Fill';$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.BackColor=[Drawing.Color]::White;$details.BorderStyle='FixedSingle';$details.Text='「一覧を読み取る」で登録情報だけを読み取ります。削除・設定変更・外部送信は行いません。';$details.Margin=New-Object Windows.Forms.Padding(0,12,0,8);$layout.Controls.Add($details,0,4)
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill';$layout.Controls.Add($actions,0,5)
    $tools=$actions;$select=MakeButton '表示中の対象を選択' 180;$clear=MakeButton '選択を解除' 120;$review=MakeButton '選択内容を確認' 150;$run=MakeButton '確認して実行…' 150;$cancel=MakeButton '次の処理から中止' 170
    $run.BackColor=[Drawing.Color]::FromArgb(35,91,171);$run.ForeColor=[Drawing.Color]::White
    $selection=New-Object Windows.Forms.Label;$selection.Text='選択 0 件';$selection.Width=170;$selection.Height=36;$selection.TextAlign='MiddleLeft';$actions.Controls.Add($selection)
    $status=New-Object Windows.Forms.Label;$status.Dock='Fill';$status.ForeColor=[Drawing.Color]::FromArgb(55,75,100);$status.Text='未取得。選択は初期状態ではすべてOFFです。';$layout.Controls.Add($status,0,6)
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=400
    $script:Ui=@{Form=$f;Grid=$g;Details=$details;Status=$status;Refresh=$refresh;Appx=$appx;Search=$search;Settings=$settings;Network=$network;SelectEligible=$select;Clear=$clear;Review=$review;Run=$run;Cancel=$cancel;Selection=$selection;Timer=$timer;Demo=[bool]$Demo;Busy=$false;Inventory=$null;Plan=$null;Eligibility=@{};Async=$null;Worker=$null;Runspace=$null;Shared=$null;LogPath=''}
    $select.Enabled=$false;$review.Enabled=$false;$run.Enabled=$false;$cancel.Enabled=$false
    $refresh.add_Click({Reset-UiPlan;try{if($script:Ui.Demo){Show-UiInventory (Get-DemoAppInventory)}else{Show-UiInventory (Get-AppInventory -IncludeAppx:$script:Ui.Appx.Checked)}}catch{$script:Ui.Inventory=$null;$script:Ui.Grid.Rows.Clear();$script:Ui.SelectEligible.Enabled=$false;$script:Ui.Review.Enabled=$false;Set-UiStatus '一覧を取得できません。権限と環境を確認してください。'}})
    $appx.add_CheckedChanged({Reset-UiPlan;Set-UiStatus '表示範囲を変更しました。「一覧を読み取る」で反映してください。'})
    $g.add_CurrentCellDirtyStateChanged({if($script:Ui.Grid.IsCurrentCellDirty){$null=$script:Ui.Grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)}})
    $g.add_CellValueChanged({Update-UiSelection})
    $g.add_SelectionChanged({if($script:Ui.Grid.SelectedRows.Count -gt 0){$r=$script:Ui.Grid.SelectedRows[0].Tag;if($null -ne $r){$script:Ui.Details.Text=(Get-UiText $r.DisplayName)+"`r`n用途はローカル規則による推定。発行元文字列も未検証です。`r`n用途: "+(Get-UiText (Get-UiValue $r PurposeSummary))+"`r`n推定根拠: "+(Get-UiText (Get-UiValue $r ClassificationBasis))+"`r`n用途の公式出典: "+(@(Get-UiValue $r.Evidence PurposeSourceUrls @())-join "; ")+"`r`n登録上のインストール日: "+(Get-UiText (Get-UiValue $r.Evidence InstallDateDeclared))+"（インストール日時や実行者の証明ではありません）`r`n保護理由: "+(@($r.Protection.Reasons)-join ', ')+"`r`n登録があることは、実ファイルの存在・使用頻度・不要性の証明ではありません。`r`n通信: 未計測。無断インストールの実行者・経緯は判定できません。`r`nMSI以外、保護対象、不明な用途は一括処理できません。"}}})
    $search.add_TextChanged({Reset-UiPlan;$q=$script:Ui.Search.Text;$script:Ui.Grid.CurrentCell=$null;foreach($row in $script:Ui.Grid.Rows){$row.Visible=([string]::IsNullOrEmpty($q) -or (($row.Tag.DisplayName+' '+$row.Tag.Publisher).IndexOf($q,[StringComparison]::OrdinalIgnoreCase) -ge 0));if(-not $row.Visible){$row.Cells['Select'].Value=$false}};Update-UiSelection})
    $select.add_Click({$n=0;foreach($row in $script:Ui.Grid.Rows){$yes=$row.Visible -and $script:Ui.Eligibility[[string]$row.Tag.Id] -and $n -lt 50;$row.Cells['Select'].Value=$yes;if($yes){$n++}};Update-UiSelection})
    $clear.add_Click({foreach($row in $script:Ui.Grid.Rows){$row.Cells['Select'].Value=$false};Update-UiSelection})
    $review.add_Click({try{$ids=@($script:Ui.Grid.Rows|Where-Object{[bool]$_.Cells['Select'].Value}|ForEach-Object{[string]$_.Tag.Id});$script:Ui.Plan=New-SafeUninstallPlan -Inventory $script:Ui.Inventory -SelectedIds $ids;$script:Ui.Details.Text="実行前の確認（削除はまだ行いません）`r`n"+(@($script:Ui.Plan.Items|ForEach-Object{(Get-UiText $_.DisplayName)+'  '+(Get-UiText $_.DisplayVersion)})-join "`r`n")+"`r`n`r`nアプリの設定・データを失う場合があります。必要なバックアップを先に確保してください。`r`n実行ボタンの後、最新登録情報を再照合して別の確認ダイアログを表示します。";$script:Ui.Run.Enabled=(-not $script:Ui.Demo);if($script:Ui.Demo){Set-UiStatus 'デモは合成データです。実アンインストールは無効です。'}}catch{$script:Ui.Plan=$null;$script:Ui.Run.Enabled=$false;Set-UiStatus '選択対象に保護・非対応・変更・重複があります。一覧を再取得して個別に確認してください。'}})
    $run.add_Click({Start-UiBatch});$cancel.add_Click({if($null -ne $script:Ui.Shared){$script:Ui.Shared.CancelRequested=$true;Set-UiStatus '未開始の処理を中止します。実行中のアンインストーラーは画面側で安全に完了・取消してください。'}})
    $settings.add_Click({if(-not $script:Ui.Demo){Start-Process 'ms-settings:appsfeatures'}})
    $network.add_Click({
        if($script:Ui.Demo){$snapshot=Get-DemoNetworkSnapshot}else{
            $answer=[Windows.Forms.MessageBox]::Show('現在のTCP接続、プロセスの開始時刻・実行パスを1回読み取ります。IPやパスはこの画面だけで扱い、外部送信・自動保存・継続監視はしません。通信内容や情報流出は判定できません。読み取りますか？','TCPの読み取り',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information,[Windows.Forms.MessageBoxDefaultButton]::Button2)
            if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
            try{Import-Module (Join-Path $PSScriptRoot 'NetworkSnapshot.psm1') -Force;$script:Ui.Form.UseWaitCursor=$true;$snapshot=Get-AppNetworkSnapshot -Inventory $script:Ui.Inventory}catch{Set-UiStatus 'TCPを読み取れませんでした。通信がないという意味ではありません。';return}finally{$script:Ui.Form.UseWaitCursor=$false}
        }
        $window=New-AppNetworkWindow -Snapshot $snapshot -Demo:$script:Ui.Demo
        try{[void]$window.ShowDialog($script:Ui.Form)}finally{$window.Dispose()}
    })
    $timer.add_Tick({Complete-UiBatch})
    $f.add_FormClosing({param($sender,$e) if($script:Ui.Busy){$e.Cancel=$true;Set-UiStatus '処理中は閉じられません。「次の処理から中止」で安全に終了してください。'}})
    $f.add_FormClosed({$script:Ui.Timer.Dispose()})
    if($Demo){$f.Text+=' [デモ: 実PCは読み取りません]';Show-UiInventory (Get-DemoAppInventory);$settings.Enabled=$false;$appx.Enabled=$false}
    return $f
}
Export-ModuleMember -Function New-AppManagerWindow,Get-DemoAppInventory
