#requires -Version 5.1
Set-StrictMode -Version Latest
$script:SUConfirmations=@{}
function Get-SUValue($o,[string]$n){if($null -eq $o){return $null};if($o -is [Collections.IDictionary]){return $o[$n]};$p=$o.PSObject.Properties[$n];if($null -ne $p){return $p.Value};return $null}
function Get-SUHash([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}}
function Get-SUInventory {Import-Module (Join-Path $PSScriptRoot 'AppInventory.psm1') -ErrorAction Stop;Get-AppInventory}
function Test-SURecordIntegrity($Record) {Import-Module (Join-Path $PSScriptRoot 'AppInventory.psm1') -ErrorAction Stop;Test-AppRecordIntegrity -Record $Record}
function Test-SUCancelRequested {return $false}
function New-SUConfirmationDialog($Items) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form=New-Object Windows.Forms.Form
    $form.Font=New-Object Drawing.Font('Yu Gothic UI',10)
    $form.Text='選択したソフトの削除を確認'
    $form.StartPosition='CenterScreen'
    $form.AutoScaleMode='Dpi'
    $area=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize=New-Object Drawing.Size([Math]::Min(960,[int]($area.Width*0.9)),[Math]::Min(640,[int]($area.Height*0.85)))
    $form.MinimizeBox=$false;$form.MaximizeBox=$false;$form.ShowInTaskbar=$true
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(12)
    $layout.ColumnCount=1;$layout.RowCount=4
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,130)))
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,54)))
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,48)))
    $notice=New-Object Windows.Forms.TextBox
    $notice.Name='Warning';$notice.Multiline=$true;$notice.ReadOnly=$true;$notice.ScrollBars='Vertical';$notice.Dock='Fill'
    $notice.Text="以下の "+@($Items).Count+" 件だけを、公式の対話型アンインストーラーで順番に削除します。"+[Environment]::NewLine+"設定・保存データも削除され、元に戻せない場合があります。必要なバックアップを先に用意してください。"+[Environment]::NewLine+"キャンセル・失敗・再起動要求があれば未開始の処理を止めます。本ツールは自動再起動しませんが、インストーラー側で再起動が起きる可能性があります。"+[Environment]::NewLine+"完了表示だけでソフトや関連データの完全削除を保証するものではありません。"
    $list=New-Object Windows.Forms.ListView
    $list.Name='SelectedItems';$list.Dock='Fill';$list.View='Details';$list.FullRowSelect=$true;$list.GridLines=$true;$list.Scrollable=$true;$list.HideSelection=$false
    foreach($column in @(@('ソフト名',280),@('バージョン',130),@('発行元',200),@('MSI 製品コード',310))){$null=$list.Columns.Add([string]$column[0],[int]$column[1])}
    foreach($item in $Items){
        $row=New-Object Windows.Forms.ListViewItem([string]$item.DisplayName)
        $null=$row.SubItems.Add([string]$item.DisplayVersion);$null=$row.SubItems.Add([string]$item.Publisher);$null=$row.SubItems.Add([string]$item.ProductCode)
        $null=$list.Items.Add($row)
    }
    $check=New-Object Windows.Forms.CheckBox
    $check.Name='Acknowledgement';$check.Text='対象一覧と、設定・データが失われる可能性を確認しました'
    $check.Dock='Fill';$check.Checked=$false
    $buttons=New-Object Windows.Forms.FlowLayoutPanel
    $buttons.Dock='Fill';$buttons.FlowDirection='RightToLeft'
    $cancel=New-Object Windows.Forms.Button
    $cancel.Name='CancelAction';$cancel.Text='キャンセル';$cancel.Width=120;$cancel.Height=34;$cancel.DialogResult='Cancel'
    $execute=New-Object Windows.Forms.Button
    $execute.Name='ExecuteAction';$execute.Text='選択したソフトを削除';$execute.Width=190;$execute.Height=34;$execute.Enabled=$false;$execute.DialogResult='Yes'
    $buttons.Controls.Add($cancel);$buttons.Controls.Add($execute)
    $check.add_CheckedChanged({param($sender,$eventArgs) $sender.FindForm().Controls.Find('ExecuteAction',$true)[0].Enabled=$sender.Checked})
    $layout.Controls.Add($notice,0,0);$layout.Controls.Add($list,0,1);$layout.Controls.Add($check,0,2);$layout.Controls.Add($buttons,0,3)
    $form.Controls.Add($layout);$form.CancelButton=$cancel;$form.AcceptButton=$cancel;$form.ActiveControl=$cancel
    return $form
}
function Show-SUConfirmation($Items) {
    $dialog=New-SUConfirmationDialog $Items
    try{return ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::Yes)}finally{$dialog.Dispose()}
}
function Get-SUCurrentSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Initialize-SUMsiNative {
    if(-not ('SafeUninstallNative.MsiInfo' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace SafeUninstallNative {
 public static class MsiInfo {
  [DllImport("msi.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
  [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
  public static extern uint MsiGetProductInfoExW(string product, string sid, uint context, string property, StringBuilder value, ref uint count);
 }
}
'@
    }
}
function Get-SUMsiProperty([string]$ProductCode,[uint32]$Context,[string]$Property) {
    Initialize-SUMsiNative
    $buffer=New-Object Text.StringBuilder(4096)
    [uint32]$count=4096
    $code=[SafeUninstallNative.MsiInfo]::MsiGetProductInfoExW($ProductCode,$null,$Context,$Property,$buffer,[ref]$count)
    [pscustomobject]@{Code=$code;Value=$buffer.ToString()}
}
function Get-SUMsiProductInstances([string]$ProductCode) {
    # Query current-user managed/unmanaged and machine registrations. Never Win32_Product or repair APIs.
    $sid=Get-SUCurrentSid
    foreach($context in @(1,2,4)){
        $state=Get-SUMsiProperty $ProductCode $context 'State'
        if($state.Code -eq 1605){continue}
        if($state.Code -ne 0 -or $state.Value -cne '5'){throw 'MSI_INSTALL_STATE_UNKNOWN'}
        $values=@{}
        foreach($key in @('InstalledProductName','VersionString','Publisher')){
            $value=Get-SUMsiProperty $ProductCode $context $key
            if($value.Code -ne 0 -or [string]::IsNullOrWhiteSpace($value.Value)){throw 'MSI_METADATA_UNAVAILABLE'}
            $values[$key]=Get-SUDisplay $value.Value
        }
        [pscustomobject]@{Context=$context;UserSid=$(if($context -eq 4){''}else{$sid});State='5';ProductName=$values.InstalledProductName;VersionString=$values.VersionString;Publisher=$values.Publisher}
    }
}
function Assert-SUMsiIdentity($Item) {
    $sid=Get-SUCurrentSid
    if([string]::IsNullOrWhiteSpace($sid) -or $Item.SourceUserSid -cne $sid){throw 'MSI_USER_CONTEXT_CHANGED'}
    $instances=@(Get-SUMsiProductInstances $Item.ProductCode)
    if($instances.Count -ne 1){throw 'MSI_CONTEXT_ABSENT_OR_AMBIGUOUS'}
    $instance=$instances[0]
    if($instance.State -cne '5' -or ($Item.SourceHive -ceq 'LocalMachine' -and ($instance.Context -ne 4 -or $instance.UserSid -cne '')) -or ($Item.SourceHive -ceq 'CurrentUser' -and ($instance.Context -notin @(1,2) -or $instance.UserSid -cne $sid))){throw 'MSI_CONTEXT_MISMATCH'}
    if($instance.ProductName -cne $Item.DisplayName -or $instance.VersionString -cne $Item.DisplayVersion -or $instance.Publisher -cne $Item.Publisher){throw 'MSI_METADATA_MISMATCH'}
}
function Invoke-SUMsi([string]$ProductCode) {
    if($ProductCode -cnotmatch '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$'){throw 'MSI_GUID_INVALID'}
    $windows=[Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    if([string]::IsNullOrWhiteSpace($windows)){throw 'WINDOWS_DIRECTORY_UNKNOWN'}
    $exe=Join-Path $windows 'System32\msiexec.exe'
    if(-not [IO.File]::Exists($exe)){throw 'SYSTEM_MSIEXEC_UNAVAILABLE'}
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=$exe;$si.Arguments='/x '+$ProductCode+' /norestart';$si.UseShellExecute=$false
    $p=[Diagnostics.Process]::Start($si)
    try{$p.WaitForExit();return $p.ExitCode}finally{$p.Dispose()}
}
function Get-SUDisplay([string]$s) {
    if([string]::IsNullOrWhiteSpace($s) -or $s.Length -gt 200 -or $s -match '[\x00-\x1f\x7f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]'){throw 'DISPLAY_IDENTITY_INVALID'}
    return $s
}
function ConvertTo-SUItem($record) {
    if(-not(Test-SURecordIntegrity $record)){throw 'RECORD_INTEGRITY_INVALID'}
    if((Get-SUValue $record NoRemove) -isnot [bool] -or (Get-SUValue $record NoRemove) -ne $false){throw 'NO_REMOVE_OR_UNKNOWN'}
    $id=[string](Get-SUValue $record Id);$rh=[string](Get-SUValue $record RecordHash)
    if($id -cnotmatch '^[0-9a-f]{64}$' -or $rh -cnotmatch '^[0-9a-f]{64}$'){throw 'RECORD_HASH_REQUIRED'}
    $source=Get-SUValue $record Source;$protect=Get-SUValue $record Protection
    if((Get-SUValue $source Kind) -cne 'Registry'){throw 'ONLY_MSI_SUPPORTED_USE_WINDOWS_SETTINGS'}
    if((Get-SUValue $record WindowsInstaller) -isnot [bool] -or (Get-SUValue $record WindowsInstaller) -ne $true){throw 'ONLY_MSI_SUPPORTED_USE_WINDOWS_SETTINGS'}
    if((Get-SUValue $record SystemComponent) -isnot [bool] -or (Get-SUValue $record SystemComponent) -ne $false -or (Get-SUValue $protect Protected) -isnot [bool] -or (Get-SUValue $protect Protected) -ne $false){throw 'PROTECTED_OR_UNKNOWN_RECORD'}
    if((Get-SUValue $record Category) -cnotin @('Application','Browser','Tool')){throw 'UNSUPPORTED_OR_PROTECTED_CATEGORY'}
    $guid=([string](Get-SUValue $record ProductCode)).ToUpperInvariant()
    if($guid -cnotmatch '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$'){throw 'MSI_GUID_INVALID'}
    $key=[string](Get-SUValue $source Key)
    if((Get-SUValue $source Hive) -cnotin @('LocalMachine','CurrentUser') -or (Get-SUValue $source View) -cnotin @('Registry64','Registry32') -or $key -inotmatch '^SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\\{[0-9a-f-]{36}\}$'){throw 'REGISTRATION_SOURCE_INVALID'}
    if(($key -split '\\')[-1].ToUpperInvariant() -cne $guid){throw 'MSI_REGISTRATION_KEY_MISMATCH'}
    [pscustomobject][ordered]@{Id=$id;RecordHash=$rh;ProductCode=$guid;SourceHive=([string](Get-SUValue $source Hive));SourceUserSid=([string](Get-SUValue $source UserSid));DisplayName=(Get-SUDisplay ([string](Get-SUValue $record DisplayName)));DisplayVersion=$(if([string]::IsNullOrEmpty([string](Get-SUValue $record DisplayVersion))){''}else{Get-SUDisplay ([string](Get-SUValue $record DisplayVersion))});Publisher=$(if([string]::IsNullOrEmpty([string](Get-SUValue $record Publisher))){''}else{Get-SUDisplay ([string](Get-SUValue $record Publisher))})}
}
function Get-SUPlanHash($Items){Get-SUHash (ConvertTo-Json -InputObject @($Items) -Depth 4 -Compress)}
function New-SafeUninstallPlan {
    [CmdletBinding()]param([Parameter(Mandatory)]$Inventory,[Parameter(Mandatory)][string[]]$SelectedIds)
    if((Get-SUValue $Inventory SchemaVersion) -ne 1 -or (Get-SUValue $Inventory Complete) -isnot [bool] -or (Get-SUValue $Inventory Complete) -ne $true){throw 'INVENTORY_INCOMPLETE'}
    if($SelectedIds.Count -lt 1 -or $SelectedIds.Count -gt 50 -or @($SelectedIds|Sort-Object -Unique).Count -ne $SelectedIds.Count){throw 'SELECTION_EMPTY_DUPLICATED_OR_TOO_LARGE'}
    $items=@()
    foreach($id in $SelectedIds){
        $found=@((Get-SUValue $Inventory Records)|Where-Object{(Get-SUValue $_ Id) -ceq $id})
        if($found.Count -ne 1){throw 'SELECTED_RECORD_NOT_UNIQUE'}
        $item=ConvertTo-SUItem $found[0]
        $sameProduct=@((Get-SUValue $Inventory Records)|Where-Object{([string](Get-SUValue $_ ProductCode)).ToUpperInvariant() -ceq $item.ProductCode})
        if($sameProduct.Count -ne 1){throw 'PRODUCT_REGISTRATION_AMBIGUOUS'}
        $items+=$item
    }
    if(@($items.ProductCode|Sort-Object -Unique).Count -ne $items.Count){throw 'DUPLICATE_PRODUCT_SELECTION'}
    [pscustomobject]@{PlanVersion=1;State='PlanOnly';Items=$items;PlanHash=(Get-SUPlanHash $items);AutomaticRestart=$false;RemovalGuaranteed=$false}
}
function Assert-SUPlan($Plan){
    $items=@(Get-SUValue $Plan Items)
    if((Get-SUValue $Plan PlanVersion) -ne 1 -or $items.Count -lt 1 -or $items.Count -gt 50 -or (Get-SUValue $Plan PlanHash) -cne (Get-SUPlanHash $items)){throw 'PLAN_CHANGED_OR_INVALID'}
    return $items
}
function Assert-SUFresh($Plan) {
    $items=@(Assert-SUPlan $Plan)
    $fresh=New-SafeUninstallPlan -Inventory (Get-SUInventory) -SelectedIds @($items|ForEach-Object{$_.Id})
    if($fresh.PlanHash -cne $Plan.PlanHash){throw 'FRESH_INVENTORY_CHANGED'}
    foreach($item in $fresh.Items){Assert-SUMsiIdentity $item}
}
function Request-SafeUninstallConfirmation {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan)
    Assert-SUFresh $Plan
    $reviewedHash=[string]$Plan.PlanHash
    $reviewedItems=@($Plan.Items|ConvertTo-Json -Depth 4|ConvertFrom-Json)
    if(-not(Show-SUConfirmation $reviewedItems)){return $null}
    $null=Assert-SUPlan $Plan
    if($Plan.PlanHash -cne $reviewedHash){throw 'PLAN_CHANGED_DURING_CONFIRMATION'}
    $token=[guid]::NewGuid().ToString('N')
    $script:SUConfirmations[$token]=@{Hash=[string]$Plan.PlanHash;Expires=[DateTime]::UtcNow.AddMinutes(5)}
    return $token
}
function Write-SUEvent([IO.StreamWriter]$Writer,[string]$Stage,$Item,$ExitCode,$ErrorRecord=$null) {
    $row=[ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Stage=$Stage;Id=$(if($null -eq $Item){$null}else{$Item.Id});ProductCode=$(if($null -eq $Item){$null}else{$Item.ProductCode});ExitCode=$ExitCode}
    if($null -ne $ErrorRecord){
        $known=@('MSI_INSTALL_STATE_UNKNOWN','MSI_METADATA_UNAVAILABLE','MSI_USER_CONTEXT_CHANGED','MSI_CONTEXT_ABSENT_OR_AMBIGUOUS','MSI_CONTEXT_MISMATCH','MSI_METADATA_MISMATCH','FRESH_INVENTORY_CHANGED','INVENTORY_INCOMPLETE','SELECTED_RECORD_NOT_UNIQUE','PRODUCT_REGISTRATION_AMBIGUOUS','RECORD_INTEGRITY_INVALID','NO_REMOVE_OR_UNKNOWN','PROTECTED_OR_UNKNOWN_RECORD','UNSUPPORTED_OR_PROTECTED_CATEGORY','MSI_GUID_INVALID','MSI_REGISTRATION_KEY_MISMATCH','REGISTRATION_SOURCE_INVALID','SYSTEM_MSIEXEC_UNAVAILABLE','WINDOWS_DIRECTORY_UNKNOWN')
        $msg=[string]$ErrorRecord.Exception.Message
        $row.ReasonCode=$(if($msg -cin $known){$msg}else{'VALIDATION_OR_EXECUTION_ERROR'})
        $row.ExceptionType=$ErrorRecord.Exception.GetType().FullName
        $row.HResult=$ErrorRecord.Exception.HResult
    }
    $Writer.WriteLine(($row|ConvertTo-Json -Compress));$Writer.Flush()
}
function Invoke-SafeUninstallPlan {
    [CmdletBinding()]param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$ConfirmationToken,[Parameter(Mandatory)][string]$LogPath,[scriptblock]$CancellationRequested)
    $items=@(Assert-SUPlan $Plan)
    if(-not $script:SUConfirmations.ContainsKey($ConfirmationToken)){throw 'NATIVE_CONFIRMATION_REQUIRED'}
    $approval=$script:SUConfirmations[$ConfirmationToken];$script:SUConfirmations.Remove($ConfirmationToken)
    if($approval.Hash -cne $Plan.PlanHash -or $approval.Expires -lt [DateTime]::UtcNow){throw 'CONFIRMATION_EXPIRED_OR_CHANGED'}
    Assert-SUFresh $Plan
    if($LogPath -notmatch '^[A-Za-z]:\\' -or $LogPath.Substring(2).Contains(':') -or $LogPath.Contains('/') -or $LogPath -match '[\x00-\x1f]'){throw 'LOCAL_NEW_LOG_REQUIRED'}
    foreach($segment in $LogPath.Substring(3).Split('\')){
        if([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.','..') -or $segment -match '[. ]$' -or $segment -imatch '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)' -or $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'LOG_COMPONENT_UNSAFE'}
    }
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($LogPath))
    while($parent){$attr=[IO.File]::GetAttributes($parent);if(($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'LOG_REPARSE_PATH_REFUSED'};$parent=[IO.Path]::GetDirectoryName($parent)}
    $stream=[IO.File]::Open($LogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $writer=New-Object IO.StreamWriter($stream,[Text.UTF8Encoding]::new($false))
    $results=[Collections.Generic.List[object]]::new();$state='CompletedInstallerBatch'
    try {
        Write-SUEvent $writer 'batch-started' $null $null
        foreach($item in $items){
            if((Test-SUCancelRequested) -or ($null -ne $CancellationRequested -and (& $CancellationRequested))){$state='CancelledBeforeNext';Write-SUEvent $writer 'cancelled-before-next' $item $null;break}
            try {
                # Recheck only remaining selected registration: prior successful items may disappear.
                $fresh=New-SafeUninstallPlan -Inventory (Get-SUInventory) -SelectedIds @($item.Id)
                if($fresh.Items[0].RecordHash -cne $item.RecordHash -or (Get-SUPlanHash @($fresh.Items[0])) -cne (Get-SUPlanHash @($item))){throw 'FRESH_INVENTORY_CHANGED'}
                Assert-SUMsiIdentity $fresh.Items[0]
                Write-SUEvent $writer 'installer-starting' $item $null
                $exit=Invoke-SUMsi $item.ProductCode
                Write-SUEvent $writer 'installer-exited' $item $exit
                $outcome=switch($exit){0{'InstallerReportedSuccess'}1602{'Cancelled'}1618{'InstallerBusy'}1641{'RestartInitiated'}3010{'RestartRequired'}default{'InstallerFailed'}}
                $registration='NotChecked'
                if($exit -eq 0){
                    try{
                        $after=Get-SUInventory
                        if((Get-SUValue $after Complete) -isnot [bool] -or (Get-SUValue $after Complete) -ne $true){throw 'INVENTORY_INCOMPLETE'}
                        $registration=$(if(@((Get-SUValue $after Records)|Where-Object{(Get-SUValue $_ Id) -ceq $item.Id -or ([string](Get-SUValue $_ ProductCode)).ToUpperInvariant() -ceq $item.ProductCode}).Count -eq 0){'RegistrationAbsent'}else{'StillPresent'})
                    }catch{$registration='Unknown';Write-SUEvent $writer 'post-inventory-failed' $item $exit $_}
                    Write-SUEvent $writer ('post-'+$registration) $item $exit
                }
                $results.Add([pscustomobject]@{Id=$item.Id;ProductCode=$item.ProductCode;ExitCode=$exit;Outcome=$outcome;RegistrationState=$registration;RemovalVerified=$false})
                if($exit -eq 0 -and $registration -ne 'RegistrationAbsent'){$state='StoppedOnRegistrationUncertainty';break}
                if($exit -ne 0){$state=$outcome;break}
            }catch{$state='StoppedOnError';Write-SUEvent $writer 'stopped-on-validation-or-execution-error' $item $null $_;break}
        }
        Write-SUEvent $writer 'batch-ended' $null $null
    }finally{$writer.Dispose()}
    [pscustomobject]@{State=$state;Results=$results.ToArray();RemovalVerified=$false;RestartPerformedByTool=$false}
}
Export-ModuleMember -Function New-SafeUninstallPlan,Request-SafeUninstallConfirmation,Invoke-SafeUninstallPlan
