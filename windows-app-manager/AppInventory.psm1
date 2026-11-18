Import-Module (Join-Path $PSScriptRoot 'PurposeCatalog.psm1') -ErrorAction Stop
Set-StrictMode -Version Latest
function Get-AiValue($Object,[string]$Name,$Default=$null) {
 if ($null -eq $Object) { return $Default }
 if ($Object -is [System.Collections.IDictionary]) { if($Object.Contains($Name)){return $Object[$Name]} } elseif($Object.PSObject.Properties[$Name]) { return $Object.$Name }
 return $Default
}
function Get-AiRegistryEntries([string]$Hive,[string]$View) {
 $base=$null; $root=$null
 try {
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive,[Microsoft.Win32.RegistryView]::$View)
  $path='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
  $root=$base.OpenSubKey($path,$false)
  if($null -eq $root){return}
  foreach($name in $root.GetSubKeyNames()) {
   $key=$null
   try {
    $key=$root.OpenSubKey($name,$false)
    if($null -eq $key){throw 'REGISTRY_ENTRY_CHANGED'}
    $item=[ordered]@{Key="$path\$name"}
    foreach($field in @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','QuietUninstallString','WindowsInstaller','SystemComponent','ReleaseType','ParentKeyName','NoRemove','InstallDate','DisplayIcon','Comments','URLInfoAbout','HelpLink','EstimatedSize')) {
     $item[$field]=$key.GetValue($field,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    [pscustomobject]$item
   } finally {if($null -ne $key){$key.Dispose()}}
  }
 } finally {if($null -ne $root){$root.Dispose()};if($null -ne $base){$base.Dispose()}}
}
function Get-AiCurrentSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Get-AiAppxEntries {
 Get-AppxPackage -ErrorAction Stop | Select-Object Name,PackageFullName,Publisher,Version,InstallLocation,IsFramework,NonRemovable
}
function Get-AiHash([string]$Text) {
 $sha=[System.Security.Cryptography.SHA256]::Create()
 try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() } finally {$sha.Dispose()}
}
function Get-AiRecordHash($Record) {
 $data=[ordered]@{}
 foreach($field in @('Id','Source','DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','QuietUninstallString','WindowsInstaller','ProductCode','SystemComponent','NoRemove','Category','PurposeSummary','ClassificationBasis','Protection','Evidence','Metadata')) {$data[$field]=Get-AiValue $Record $field}
 Get-AiHash (ConvertTo-Json -InputObject $data -Depth 12 -Compress)
}
function Test-AppRecordIntegrity {
 [CmdletBinding()]param([Parameter(Mandatory)]$Record)
 try {
  $source=Get-AiValue $Record 'Source'
  $identity=ConvertTo-Json -InputObject $source -Depth 4 -Compress
  return ((Get-AiValue $Record 'Id') -ceq (Get-AiHash $identity) -and (Get-AiValue $Record 'RecordHash') -ceq (Get-AiRecordHash $Record))
 } catch {return $false}
}
function Get-AiRegistrationFlag($Entry,[string]$Name) {
 # Read directly: pipeline enumeration must not turn a one-element array into a DWORD.
 $value=$null
 if($Entry -is [System.Collections.IDictionary]) {if($Entry.Contains($Name)){$value=$Entry[$Name]}}
 elseif($Entry.PSObject.Properties[$Name]) {$value=$Entry.$Name}
 if($null -eq $value){return [pscustomobject]@{Valid=$true;Enabled=$false}}
 $valid=($value -is [int] -and ($value -eq 0 -or $value -eq 1))
 [pscustomobject]@{Valid=$valid;Enabled=($valid -and $value -eq 1)}
}
function Get-AiMetadata($Entry) {
 $result=[ordered]@{}
 foreach($field in @('DisplayIcon','Comments','URLInfoAbout','HelpLink','ParentKeyName','ReleaseType')) {
  $value=$null
  if($Entry -is [Collections.IDictionary]){if($Entry.Contains($field)){$value=$Entry[$field]}}elseif($Entry.PSObject.Properties[$field]){$value=$Entry.$field}
  if($value -isnot [string]){$value=''}
  $value=$value -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' '
  if($value.Length -gt 2048){$value=$value.Substring(0,2048)}
  $result[$field]=$value
 }
 $size=$null
 if($Entry -is [Collections.IDictionary]){if($Entry.Contains('EstimatedSize')){$size=$Entry['EstimatedSize']}}elseif($Entry.PSObject.Properties['EstimatedSize']){$size=$Entry.EstimatedSize}
 $result.EstimatedSizeKiB=$null
 if(($size -is [int] -or $size -is [long]) -and $size -ge 0){$result.EstimatedSizeKiB=$size}
 $result.Trust='UnverifiedRegistrationClaims; URLsAndCommandsNotOpened'
 [pscustomobject]$result
}
function New-AiRecord($Entry,$Source) {
 $name=[string](Get-AiValue $Entry 'DisplayName' '')
 if([string]::IsNullOrWhiteSpace($name)){return}
 $reasons=[Collections.Generic.List[string]]::new()
 $category='Unknown';$purpose='用途不明（要確認）'
 $systemFlag=Get-AiRegistrationFlag $Entry 'SystemComponent'
 $noRemoveFlag=Get-AiRegistrationFlag $Entry 'NoRemove'
 $system=($systemFlag.Enabled -or -not $systemFlag.Valid)
 $noRemove=($noRemoveFlag.Enabled -or -not $noRemoveFlag.Valid)
 if(-not $systemFlag.Valid){$reasons.Add('InvalidSystemComponentRegistration')}
 if(-not $noRemoveFlag.Valid){$reasons.Add('InvalidNoRemoveRegistration')}
 $publisher=[string](Get-AiValue $Entry 'Publisher' '')
 if($system){$reasons.Add('SystemComponent')}
 if($noRemove){$reasons.Add('RemovalDisabledByRegistration')}
 if((Get-AiValue $Entry 'ParentKeyName') -or (Get-AiValue $Entry 'ReleaseType')){$reasons.Add('UpdateOrChildComponent')}
 # Publisher text is unverified metadata, never proof of authenticity or safe removal.
 if(($name+' '+$publisher) -match '(?i)Microsoft|Windows|framework|runtime|redistributable|\.NET|DirectX|WebView|Visual C\+\+'){$category='SystemRuntime';$reasons.Add('PossibleSystemOrRuntime')}
 if(($name+' '+$publisher) -match '(?i)driver|firmware|chipset|motherboard|Intel|AMD|NVIDIA|Realtek|Qualcomm|Broadcom|ASUS|Gigabyte|MSI\b|CPU|GPU'){$category='Hardware';$reasons.Add('PossibleHardwareDependency')}
 if(($name+' '+$publisher) -match '(?i)network|ethernet|wireless|Wi-?Fi|VPN|firewall|antivirus|security|Defender|CrowdStrike|Sentinel|Sophos|Kaspersky|McAfee|ESET|Bitdefender|remote|AnyDesk|TeamViewer|RustDesk|Tailscale|ZeroTier'){$category='SecurityNetwork';$reasons.Add('PossibleSecurityNetworkOrRemoteAccess')}
 $analysis=Get-AppPurposeAnalysis -DisplayName $name -Publisher $publisher
 if($category -eq 'Unknown') {
  if($analysis.Matched){
   $category=$analysis.Category;$purpose=$analysis.PurposeSummary
   if($analysis.DependencyReviewRequired){$reasons.Add('DeveloperDependencyReviewRequired')}
  }else{$purpose=$analysis.PurposeSummary;$reasons.Add('UnknownPurposeOrDependency')}
 }
 if($category -eq 'SystemRuntime'){$purpose='OS・共有ランタイム関連（推定・保護）'}
 if($category -eq 'Hardware'){$purpose='機器制御・ドライバ関連（推定・保護）'}
 if($category -eq 'SecurityNetwork'){$purpose='通信・安全対策・遠隔接続（推定・保護）'}
 if($Source.Kind -eq 'Appx'){$reasons.Add('AppxRemovalNotSupported')}
 $msiFlag=Get-AiRegistrationFlag $Entry 'WindowsInstaller'
 $isMsi=$msiFlag.Enabled
 if(-not $msiFlag.Valid){$reasons.Add('InvalidWindowsInstallerRegistration')}
 $productCode=''
 if($isMsi -and $Source.Kind -eq 'Registry') {
  $leaf=($Source.Key -split '\\')[-1]
  if($leaf -cmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'){$productCode=$leaf.ToUpperInvariant()}
 }
 $record=[pscustomobject][ordered]@{
  Id=(Get-AiHash (ConvertTo-Json -InputObject $Source -Depth 4 -Compress));Source=$Source
  DisplayName=$name;DisplayVersion=[string](Get-AiValue $Entry 'DisplayVersion' '');Publisher=$publisher
  InstallLocation=[string](Get-AiValue $Entry 'InstallLocation' '')
  UninstallString=[string](Get-AiValue $Entry 'UninstallString' '');QuietUninstallString=[string](Get-AiValue $Entry 'QuietUninstallString' '')
  WindowsInstaller=$isMsi;ProductCode=$productCode;SystemComponent=$system;NoRemove=$noRemove
  Category=$category;PurposeSummary=$purpose;ClassificationBasis=$analysis.ClassificationBasis;Protection=[pscustomobject][ordered]@{Protected=($reasons.Count -gt 0);Reasons=@($reasons)}
  Evidence=[pscustomobject][ordered]@{Classification='HeuristicNotVerified';Installation=$(if($Source.Kind -eq 'Appx'){'PackageRegistration'}else{'RegistryRegistration'});NetworkActivity='NotMeasured';InstallDateDeclared=[string](Get-AiValue $Entry 'InstallDate' '');InstallerActor='Unknown';ActualInstalledFiles='NotVerified';Dependencies='Unknown';PublisherAuthenticity='NotVerified';Necessity='Unknown';PurposeRuleId=$analysis.RuleId;PurposeGroup=$analysis.PurposeGroup;PurposeSourceUrls=@($analysis.SourceUrls);PurposeCatalogReviewedUtc=$analysis.CatalogReviewedUtc}
  Metadata=(Get-AiMetadata $Entry)
  RecordHash=''
 }
 $record.RecordHash=Get-AiRecordHash $record
 return $record
}
function Get-AppInventory {
 [CmdletBinding()]param([switch]$IncludeAppx)
 $records=[Collections.Generic.List[object]]::new();$errors=[Collections.Generic.List[object]]::new()
 try {$sid=[string](Get-AiCurrentSid);if($sid -notmatch '^S-1-\d+(?:-\d+)+$'){throw 'INVALID_USER_SID'}} catch {throw 'CURRENT_USER_IDENTITY_UNAVAILABLE'}
 foreach($hive in @('LocalMachine','CurrentUser')) {
  foreach($view in @('Registry64','Registry32')) {
   try {
    $entries=@(Get-AiRegistryEntries -Hive $hive -View $view)
    foreach($entry in $entries) {
     $key=[string](Get-AiValue $entry 'Key' '')
     if(-not $key.StartsWith('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\',[StringComparison]::OrdinalIgnoreCase)){throw 'INVALID_REGISTRY_IDENTITY'}
     $source=[pscustomobject][ordered]@{Kind='Registry';UserSid=$sid;Hive=$hive;View=$view;Key=$key;PackageFullName=''}
     $record=New-AiRecord $entry $source
     if($null -ne $record){$records.Add($record)}
    }
   } catch {$errors.Add([pscustomobject]@{Code='REGISTRY_INVENTORY_FAILED';Hive=$hive;View=$view;HResult=$_.Exception.HResult})}
  }
 }
 if($IncludeAppx) {
  try {
   foreach($entry in @(Get-AiAppxEntries)) {
    $package=[string](Get-AiValue $entry 'PackageFullName' '')
    if([string]::IsNullOrWhiteSpace($package)){throw 'INVALID_PACKAGE_IDENTITY'}
    $source=[pscustomobject][ordered]@{Kind='Appx';UserSid=$sid;Hive='CurrentUser';View='';Key='';PackageFullName=$package}
    $mapped=@{DisplayName=(Get-AiValue $entry 'Name');DisplayVersion=[string](Get-AiValue $entry 'Version');Publisher=(Get-AiValue $entry 'Publisher');InstallLocation=(Get-AiValue $entry 'InstallLocation');SystemComponent=1;NoRemove=1}
    $record=New-AiRecord $mapped $source
    if($null -ne $record){$records.Add($record)}
   }
  } catch {$errors.Add([pscustomobject]@{Code='APPX_INVENTORY_FAILED';HResult=$_.Exception.HResult})}
 }
 $duplicates=@($records | Group-Object Id | Where-Object Count -gt 1)
 if($duplicates.Count -gt 0){$errors.Add([pscustomobject]@{Code='DUPLICATE_SOURCE_IDENTITY'})}
 [pscustomobject][ordered]@{SchemaVersion=1;Kind='WindowsAppInventory';CollectedUtc=[DateTime]::UtcNow.ToString('o');Complete=($errors.Count -eq 0);ReadOnly=$true;AppxIncluded=[bool]$IncludeAppx;Records=@($records);Errors=@($errors);Limitations=@('Registration is not proof files exist or application is unused.','No network activity is measured.','Portable programs, other users and dependency graphs are not enumerated.','Hashes detect accidental change, not authenticated or tamper-proof authorization.','Registry commands can contain private arguments: never include them in logs or remote reports.')}
}
Export-ModuleMember -Function Get-AppInventory,Test-AppRecordIntegrity
