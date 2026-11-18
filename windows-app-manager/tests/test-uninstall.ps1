#requires -Version 5.1
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SafeUninstall.psm1') -Force -PassThru
$count=0
function Assert($v,$message){if(-not $v){throw "FAILED: $message"};$script:count++}
function Throws([scriptblock]$b){$yes=$false;try{& $b|Out-Null}catch{$yes=$true};Assert $yes 'expected rejection'}
function Record($n){
 $g=('{00000000-0000-0000-0000-00000000000'+$n+'}')
 [pscustomobject]@{Id=("$n"*64);RecordHash=('a'*64);ProductCode=$g;DisplayName="Fixture app $n";DisplayVersion='1.0';Publisher='Fixture';WindowsInstaller=$true;SystemComponent=$false;NoRemove=$false;Category='Tool';Protection=@{Protected=$false};Source=@{UserSid='S-1-5-21-100';Kind='Registry';Hive='CurrentUser';View='Registry64';Key=('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$g)};UninstallString='NEVER_EXECUTE_SECRET';QuietUninstallString='NEVER_EXECUTE_SECRET'}
}
function Setup {
 $global:SUFixture=[pscustomobject]@{SchemaVersion=1;Complete=$true;Records=@((Record 1),(Record 2))}
 & $m {
  $script:SUConfirmations=@{};$script:Calls=0;$script:Exit=0;$script:Agree=$true;$script:Remove=$true;$script:Cancel=$false;$script:Integrity=$true
  function script:Get-SUCurrentSid {'S-1-5-21-100'}
  function script:Get-SUMsiProductInstances($ProductCode){
   $r=@($global:SUFixture.Records|Where-Object ProductCode -eq $ProductCode)[0]
   [pscustomobject]@{Context=2;UserSid='S-1-5-21-100';State='5';ProductName=$r.DisplayName;VersionString=$r.DisplayVersion;Publisher=$r.Publisher}
  }
  function script:Get-SUInventory {$global:SUFixture}
  function script:Show-SUConfirmation($Items){$script:Agree}
  function script:Test-SURecordIntegrity($r){$script:Integrity}
  function script:Test-SUCancelRequested {$script:Cancel}
  function script:Invoke-SUMsi($ProductCode){
   if($ProductCode -notmatch '^\{[0-9A-F-]{36}\}$'){throw 'BAD_GUID_TO_EXECUTOR'}
   $script:Calls++
   if($script:Remove -and $script:Exit -eq 0){$global:SUFixture.Records=@($global:SUFixture.Records|Where-Object ProductCode -ne $ProductCode)}
   return $script:Exit
  }
 }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('SafeUninstallTests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
 Setup
 $p=New-SafeUninstallPlan $global:SUFixture @(('1'*64),('2'*64))
 Assert ($p.State -eq 'PlanOnly') 'plan only'
 $t=Request-SafeUninstallConfirmation $p
 $r=Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'success.jsonl')
 Assert ($r.State -eq 'CompletedInstallerBatch' -and $r.Results.Count -eq 2) 'sequential success'
 Assert (-not $r.RemovalVerified -and $r.Results[0].RegistrationState -eq 'RegistrationAbsent') 'bounded success claim'
 Assert ((Get-Content (Join-Path $temp 'success.jsonl') -Raw) -notmatch 'NEVER_EXECUTE_SECRET') 'no secret log'
 Throws {Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'replay.jsonl')}
 foreach($exit in @(1602,1618,1641,3010,1603)){
  Setup;$p=New-SafeUninstallPlan $global:SUFixture @(('1'*64),('2'*64));$t=Request-SafeUninstallConfirmation $p
  & $m {param($x)$script:Exit=$x} $exit
  $r=Invoke-SafeUninstallPlan $p $t (Join-Path $temp ("exit"+$exit+'.jsonl'))
  Assert ((& $m {$script:Calls}) -eq 1 -and $r.Results[0].ExitCode -eq $exit) 'nonzero stops batch'
 }
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$t=Request-SafeUninstallConfirmation $p
 & $m {$script:Remove=$false}
 $r=Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'still.jsonl')
 Assert ($r.State -eq 'StoppedOnRegistrationUncertainty' -and $r.Results[0].RegistrationState -eq 'StillPresent') 'still registered stops'
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$t=Request-SafeUninstallConfirmation $p
 $r=Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'cancel.jsonl') -CancellationRequested {$true}
 Assert ($r.State -eq 'CancelledBeforeNext' -and (& $m {$script:Calls}) -eq 0) 'cancel no execution'
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);& $m {$script:Agree=$false}
 Assert ($null -eq (Request-SafeUninstallConfirmation $p)) 'native decline'
 foreach($change in @(
  {$global:SUFixture.Records[0].WindowsInstaller=$false},
  {$global:SUFixture.Records[0].NoRemove=$true},
  {$global:SUFixture.Records[0].Protection.Protected=$true},
  {$global:SUFixture.Records[0].Category='Unknown'},
  {$global:SUFixture.Records[0].ProductCode='cmd.exe'},
  {$global:SUFixture.Records[0].Source.Kind='Appx'},
  {$global:SUFixture.Records[0].Source.Key='wrong'},
  {$global:SUFixture.Records[0].SystemComponent='false'},
  {$global:SUFixture.Complete=$false},
  {& $m {$script:Integrity=$false}}
 )){
  Setup;& $change;Throws {New-SafeUninstallPlan $global:SUFixture @('1'*64)}
 }
 Setup;Throws {New-SafeUninstallPlan $global:SUFixture @(('1'*64),('1'*64))}
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$p.Items[0].ProductCode='tamper'
 Throws {Request-SafeUninstallConfirmation $p}
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$t=Request-SafeUninstallConfirmation $p;$global:SUFixture.Records[0].RecordHash=('b'*64)
 Throws {Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'changed.jsonl')}
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @(('1'*64),('2'*64));$t=Request-SafeUninstallConfirmation $p
 $r=Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'cancel-after-one.jsonl') -CancellationRequested {($global:SUFixture.Records.Count -eq 1)}
 Assert ($r.State -eq 'CancelledBeforeNext' -and (& $m {$script:Calls}) -eq 1) 'cancel leaves active installer alone and skips remaining'
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$t=Request-SafeUninstallConfirmation $p
 & $m {param($t)$script:SUConfirmations[$t].Expires=[DateTime]::UtcNow.AddMinutes(-1)} $t
 Throws {Invoke-SafeUninstallPlan $p $t (Join-Path $temp 'expired.jsonl')}
 foreach($path in @('\unsafe.jsonl','C:\NUL','C:\log.jsonl:ads','C:\bad.\log','C:\..\log','\\server\share\log')){
  Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64);$t=Request-SafeUninstallConfirmation $p
  Throws {Invoke-SafeUninstallPlan $p $t $path}
  Assert ((& $m {$script:Calls}) -eq 0) 'unsafe log path no execution'
 }
 foreach($field in @('DisplayName','DisplayVersion','Publisher')){
  foreach($bad in @("line`nspoof",([string][char]0x202e+'spoof'),([string][char]0x200f+'spoof'),('x'*201))){
   Setup;$global:SUFixture.Records[0].$field=$bad
   Throws {New-SafeUninstallPlan $global:SUFixture @('1'*64)}
  }
 }
 Setup;$global:SUFixture.Records[0].DisplayVersion='';$global:SUFixture.Records[0].Publisher=''
 Assert ((New-SafeUninstallPlan $global:SUFixture @('1'*64)).Items.Count -eq 1) 'optional version publisher empty allowed'
 # Native dialog construction only: never ShowDialog, never click execute.
 $rows=@(1..50|ForEach-Object{[pscustomobject]@{DisplayName=('Fixture '+$_);DisplayVersion='1';Publisher='Fixture';ProductCode='{00000000-0000-0000-0000-000000000001}'}})
 $dialog=& $m {param($rows) New-SUConfirmationDialog $rows} $rows
 try{
  $grid=$dialog.Controls.Find('SelectedItems',$true)[0]
  $check=$dialog.Controls.Find('Acknowledgement',$true)[0]
  $run=$dialog.Controls.Find('ExecuteAction',$true)[0]
  Assert ($grid.Items.Count -eq 50 -and $grid.Columns.Count -eq 4 -and $grid.Scrollable) '50-row native scrollable review'
  Assert (-not $check.Checked -and -not $run.Enabled) 'default unchecked disabled'
  Assert ($dialog.CancelButton.Name -eq 'CancelAction' -and $dialog.AcceptButton.Name -eq 'CancelAction') 'escape and enter default cancel'
  Assert (-not $dialog.Visible) 'dialog never displayed in test'
 }finally{$dialog.Dispose()}
 foreach($mode in @('name','version','publisher','context','multiple','absent','state','query-error')){
  Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64)
  & $m {
   param($mode)
   $script:BadMode=$mode
   function script:Get-SUMsiProductInstances($ProductCode){
    if($script:BadMode -eq 'query-error'){throw 'MSI_METADATA_UNAVAILABLE'}
    if($script:BadMode -eq 'absent'){return}
    $i=[pscustomobject]@{Context=2;UserSid='S-1-5-21-100';State='5';ProductName='Fixture app 1';VersionString='1.0';Publisher='Fixture'}
    switch($script:BadMode){'name'{$i.ProductName='Critical service'}'version'{$i.VersionString='9'}'publisher'{$i.Publisher='Other'}'context'{$i.Context=4;$i.UserSid=''}'state'{$i.State='1'}}
    $i;if($script:BadMode -eq 'multiple'){$i}
   }
  } $mode
  Throws {Request-SafeUninstallConfirmation $p}
  Assert ((& $m {$script:Calls}) -eq 0) 'MSI identity refusal before execution'
 }
 Setup;$p=New-SafeUninstallPlan $global:SUFixture @('1'*64)
 & $m {function script:Get-SUCurrentSid {'S-1-5-21-999'}}
 Throws {Request-SafeUninstallConfirmation $p}
 Setup
 & $m {function script:Get-SUMsiProductInstances($code){throw 'NATIVE_QUERY_MUST_NOT_RUN_IN_PURE_PLAN'}}
 Assert ((New-SafeUninstallPlan $global:SUFixture @('1'*64)).State -eq 'PlanOnly') 'pure plan no MSI calls'
 # Compile only the P/Invoke declaration. No native entry point is called.
 & $m {Initialize-SUMsiNative}
 Assert ($null -ne ('SafeUninstallNative.MsiInfo' -as [type])) 'native declaration compiles without query'
 Write-Output ("PASS SafeUninstall assertions="+$count)
}finally{
 Remove-Variable SUFixture -Scope Global -ErrorAction SilentlyContinue
 # Test-owned directory only; do not remove user logs.
 if($temp.StartsWith([IO.Path]::GetTempPath())){Remove-Item -LiteralPath $temp -Recurse -Force}
}
