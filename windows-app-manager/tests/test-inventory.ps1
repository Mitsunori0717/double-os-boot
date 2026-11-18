$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\AppInventory.psm1') -Force
$m=Get-Module AppInventory
& $m {
 $script:calls=0;$script:appxCalls=0;$script:fail=$false
 $script:entry=@{Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}';DisplayName='7-Zip 24';DisplayVersion='24';Publisher='Igor Pavlov';WindowsInstaller=1;SystemComponent=0;NoRemove=0;UninstallString='SECRET-COMMAND';QuietUninstallString='SECRET-QUIET'}
 function script:Get-AiCurrentSid {'S-1-5-21-1-2-3-1001'}
 function script:Get-AiRegistryEntries($Hive,$View) {$script:calls++;if($script:fail){throw 'SECRET-CREDENTIAL'};if($Hive -eq 'LocalMachine' -and $View -eq 'Registry64'){[pscustomobject]$script:entry}}
 function script:Get-AiAppxEntries {$script:appxCalls++;[pscustomobject]@{Name='test.app';PackageFullName='test.app_1';Publisher='private';Version='1';InstallLocation='C:\private'}}
}
$script:n=0
function Assert($value,$message){if(-not $value){throw $message};$script:n++}
$i=Get-AppInventory
Assert $i.Complete 'complete'
Assert ($i.Records.Count -eq 1) 'one record'
$r=$i.Records[0]
Assert ($r.Category -eq 'Tool' -and -not $r.Protection.Protected) 'tool heuristic'
Assert ($r.ProductCode -eq '{12345678-1234-1234-1234-123456789ABC}') 'guid'
Assert (Test-AppRecordIntegrity $r) 'integrity'
Assert (Test-AppRecordIntegrity ($r|ConvertTo-Json -Depth 12|ConvertFrom-Json)) 'json roundtrip'
Assert ((& $m {$script:calls}) -eq 4) 'all registry views'
Assert ((& $m {$script:appxCalls}) -eq 0) 'appx opt in only'
Assert ($r.Evidence.NetworkActivity -eq 'NotMeasured') 'no telemetry inference'
$r.DisplayName='tampered';Assert (-not (Test-AppRecordIntegrity $r)) 'tampering rejected'
foreach($name in @('Mystery app','Microsoft Edge','Intel helper','NVIDIA panel','WiFi utility','Security agent','ASUS utility','Visual C++ runtime','TeamViewer','Windows update')) {
 & $m {param($name) $script:entry.DisplayName=$name} $name
 $item=(Get-AppInventory).Records[0]
 Assert $item.Protection.Protected "protected $name"
}
& $m {$script:entry.DisplayName='7-Zip';$script:entry.SystemComponent=1}
Assert ((Get-AppInventory).Records[0].Protection.Protected) 'system flag'
& $m {$script:entry.SystemComponent=0;$script:entry.NoRemove=1}
Assert ((Get-AppInventory).Records[0].Protection.Protected) 'no remove'
& $m {$script:entry.NoRemove=0;$script:entry.WindowsInstaller='1'}
Assert (-not (Get-AppInventory).Records[0].WindowsInstaller) 'strict msi flag'
& $m {$script:entry.WindowsInstaller=1;$script:entry.Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\bad'}
Assert ((Get-AppInventory).Records[0].ProductCode -eq '') 'non guid no productcode'
& $m {$script:entry.Key='evil'}
Assert (-not (Get-AppInventory).Complete) 'invalid identity'
& $m {$script:fail=$true}
$i=Get-AppInventory
Assert (-not $i.Complete) 'failure incomplete'
Assert (($i|ConvertTo-Json -Depth 12) -notmatch 'SECRET-CREDENTIAL') 'sanitized failure'
$i=Get-AppInventory -IncludeAppx
Assert ($i.Records.Count -eq 1 -and $i.Records[0].Protection.Protected) 'appx always protected'
Assert ((& $m {$script:appxCalls}) -eq 1) 'explicit appx'
Assert ($i.Records[0].Source.UserSid -eq 'S-1-5-21-1-2-3-1001') 'sid binding'
& $m {$script:fail=$false;$script:entry.Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}';$script:entry.DisplayName='7-Zip'}
foreach($field in @('SystemComponent','NoRemove','WindowsInstaller')) {
 foreach($value in @(2,'unknown','1',[long]1,$true,@(1),@(0),@(0,1),@())) {
  & $m {param($f,$v) $script:entry.SystemComponent=0;$script:entry.NoRemove=0;$script:entry.WindowsInstaller=1;$script:entry[$f]=$v} $field $value
  $r=(Get-AppInventory).Records[0]
  Assert $r.Protection.Protected "invalid flag protected $field"
  Assert ($r.Protection.Reasons -contains "Invalid${field}Registration") "invalid reason $field"
  if($field -eq 'WindowsInstaller'){Assert (-not $r.WindowsInstaller) 'invalid MSI false'}else{Assert $r.$field 'invalid protection flag true'}
 }
 foreach($value in @($null,0,1)) {
  & $m {param($f,$v) $script:entry.SystemComponent=0;$script:entry.NoRemove=0;$script:entry.WindowsInstaller=1;$script:entry[$f]=$v} $field $value
  $r=(Get-AppInventory).Records[0]
  Assert (-not ($r.Protection.Reasons -contains "Invalid${field}Registration")) 'valid or absent flag'
 }
 & $m {param($f) $script:entry.Remove($f)} $field
 $r=(Get-AppInventory).Records[0]
 Assert (-not ($r.Protection.Reasons -contains "Invalid${field}Registration")) 'missing flag permitted'
}
Write-Output "PASS: $script:n inventory assertions (all registry and Appx queries mocked)"
