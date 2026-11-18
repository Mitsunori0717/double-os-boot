#requires -Version 5.1
# Display-only, no registry/file/process/network queries. Never changes uninstall policy.
Set-StrictMode -Version Latest
$inventoryPath=Join-Path $PSScriptRoot 'AppInventory.psm1'
$purposePath=Join-Path $PSScriptRoot 'PurposeCatalog.psm1'
$script:AAInventory=Get-Module -All | Where-Object Path -eq $inventoryPath | Select-Object -First 1
if($null -eq $script:AAInventory){$script:AAInventory=Import-Module $inventoryPath -PassThru}
$script:AAPurpose=Get-Module -All | Where-Object Path -eq $purposePath | Select-Object -First 1
if($null -eq $script:AAPurpose){$script:AAPurpose=Import-Module $purposePath -PassThru}
function Get-AAValue($o,[string]$n){if($null -eq $o){return $null};if($o -is [Collections.IDictionary]){return $o[$n]};$p=$o.PSObject.Properties[$n];if($null -ne $p){return $p.Value};return $null}
function Test-AARecordIntegrity($r){& $script:AAInventory {param($r) Test-AppRecordIntegrity $r} $r}
function Get-AASafeText($v){
 if($v -isnot [string] -or $v.Length -gt 512 -or $v -match '[\x00-\x1f\x7f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]'){return ''}
 return $v.Trim()
}
function Get-AALocationClass($value){
 $p=Get-AASafeText $value
 if(-not $p){return 'Unknown'}
 if($p.StartsWith('\\')){return 'NetworkDeclared'}
 if($p -match '^[A-Za-z]:\\Windows(?:\\|$)'){return 'WindowsDirectoryDeclared'}
 if($p -match '^[A-Za-z]:\\Program Files(?: \(x86\))?(?:\\|$)'){return 'ProgramFilesDeclared'}
 if($p -match '^[A-Za-z]:\\Users\\[^\\]+(?:\\|$)'){return 'UserProfileDeclared'}
 if($p -match '^[A-Za-z]:\\'){return 'OtherLocalDeclared'}
 return 'UnrecognizedDeclared'
}
$script:AARules=@(
 @{Category='Database';Pattern='(?i)\b(SQL|PostgreSQL|MySQL|MariaDB|MongoDB|database|SQLite|Redis)\b|データベース';Label='データベース'},
 @{Category='CadCamEngineering';Pattern='(?i)\b(CAD|CAM|CAE|AutoCAD|Fusion|SolidWorks|CATIA|ANSYS|Mastercam|NX|engineering)\b|設計|製図|加工';Label='CAD・CAM・工学'},
 @{Category='Scientific';Pattern='(?i)\b(MATLAB|Simulink|Mathematica|LabVIEW|SPSS|scientific|simulation|statistics)\b|科学|統計|解析';Label='科学・解析'},
 @{Category='BusinessOffice';Pattern='(?i)\b(Office|Word|Excel|PowerPoint|LibreOffice|Acrobat|accounting|ERP|CRM|invoice)\b|会計|請求|業務|文書';Label='業務・文書'},
 @{Category='Media';Pattern='(?i)\b(video|audio|media|player|VLC|Audacity|OBS|Premiere|DaVinci)\b|動画|音声|録音|配信';Label='メディア'},
 @{Category='GraphicsDesign';Pattern='(?i)\b(GIMP|Inkscape|Blender|Photoshop|Illustrator|graphics|design|image|paint)\b|画像|描画|デザイン';Label='画像・デザイン'},
 @{Category='Development';Pattern='(?i)\b(Git|PyCharm|IDE|SDK|compiler|debugger|developer|development|Visual Studio|IntelliJ|Eclipse|code editor)\b|開発';Label='開発'},
 @{Category='Game';Pattern='(?i)\b(Steam|Epic Games|GOG|game|gaming|launcher)\b|ゲーム';Label='ゲーム'},
 @{Category='Communication';Pattern='(?i)\b(Zoom|Slack|Discord|chat|meeting|messenger|Webex)\b|会議|チャット|通話';Label='会議・チャット'},
 @{Category='Browser';Pattern='(?i)\b(browser|Chrome|Firefox|Brave|Opera)\b|ブラウザ';Label='ブラウザ'},
 @{Category='Utility';Pattern='(?i)\b(7-Zip|WinRAR|archive|compression|Notepad\+\+|file manager|backup|utility)\b|圧縮|展開|バックアップ';Label='ユーティリティ'},
 @{Category='SystemRuntime';Pattern='(?i)\b(runtime|framework|redistributable|\.NET|Java|Python)\b|ランタイム';Label='ランタイム・共通機能'},
 @{Category='SecurityNetwork';Pattern='(?i)\b(VPN|firewall|security|antivirus|driver|firmware|network)\b|セキュリティ|ドライバ';Label='保護・通信・機器'}
)
function Get-AppAssessment {
 [CmdletBinding()]param([Parameter(Mandatory)]$Record,$AppEvidence,[DateTimeOffset]$AsOfUtc=[DateTimeOffset]::UtcNow)
 $layers=[Collections.Generic.List[object]]::new();$conflicts=[Collections.Generic.List[string]]::new()
 $candidates=[Collections.Generic.List[object]]::new();$urls=[Collections.Generic.List[string]]::new()
 $urls.Add('https://support.microsoft.com/windows')
 $protected=Get-AAValue (Get-AAValue $Record Protection) Protected
 if($protected -isnot [bool]){$protected=$null}
 $id=Get-AAValue $Record Id;$hash=Get-AAValue $Record RecordHash
 $valid=($id -is [string] -and $id -cmatch '^[0-9a-f]{64}$' -and $hash -is [string] -and $hash -cmatch '^[0-9a-f]{64}$')
 if($valid){try{$valid=(Test-AARecordIntegrity $Record) -eq $true}catch{$valid=$false}}
 $name='';$publisher='';$location='Unknown';$kind='Unknown';$metadataText='';$registryDescription='';$identity='Unverified';$known=$null
 if(-not $valid){$conflicts.Add('RECORD_INTEGRITY_INVALID');$id=$null;$hash=$null}
 else{
  $name=Get-AASafeText (Get-AAValue $Record DisplayName);$publisher=Get-AASafeText (Get-AAValue $Record Publisher)
  if(-not $name){$conflicts.Add('DISPLAY_NAME_INVALID_OR_MISSING')}
  if(-not $publisher){$conflicts.Add('PUBLISHER_INVALID_OR_MISSING')}
  $registryDescription=Get-AASafeText (Get-AAValue (Get-AAValue $Record Metadata) Comments)
  if($registryDescription -match '(?i)https?://|[A-Za-z]:\\|\\\\'){$registryDescription='';$conflicts.Add('REGISTRY_DESCRIPTION_CONTAINS_URL_OR_PATH_IGNORED')}
  $metadata=Get-AAValue $Record Metadata
  $estimatedSize=Get-AAValue $metadata EstimatedSizeKiB
  $sizeState=if(($estimatedSize -is [int] -or $estimatedSize -is [long]) -and $estimatedSize -ge 0){'NonnegativeSizeDeclaredNotMeasured'}elseif($null -eq $estimatedSize){'NotDeclared'}else{'InvalidDeclaration'}
  $layers.Add([pscustomobject]@{Layer='RegisteredSize';Status=$sizeState;Codes=@('REGISTRY_SIZE_NOT_DISK_USAGE_MEASUREMENT')})
  $date=Get-AAValue (Get-AAValue $Record Evidence) InstallDateDeclared
  $parsedDate=[DateTime]::MinValue
  $dateState=if($date -is [string] -and $date -cmatch '^[0-9]{8}$' -and [DateTime]::TryParseExact($date,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsedDate)){'DateDeclaredNotProvenInstallationTime'}elseif([string]::IsNullOrEmpty([string]$date)){'NotDeclared'}else{'InvalidDeclaration'}
  $layers.Add([pscustomobject]@{Layer='RegisteredDate';Status=$dateState;Codes=@('DECLARED_DATE_NOT_INSTALLER_OR_INSTALL_TIME_PROOF')})
  $flagStates=@()
  foreach($flag in @('SystemComponent','NoRemove','WindowsInstaller')){
   $v=Get-AAValue $Record $flag
   $flagStates+=($flag+$(if($v -isnot [bool]){'Unknown'}elseif($v){'DeclaredOn'}else{'DeclaredOff'}))
  }
  $layers.Add([pscustomobject]@{Layer='RegistrationFlags';Status='DeclarationsOnly';Codes=$flagStates})
  $layers.Add([pscustomobject]@{Layer='RegistryDescription';Status=$(if($registryDescription){'UntrustedTextAvailable'}else{'UnavailableOrExcluded'});Codes=@('COMMENTS_SELF_DECLARED_NOT_EXECUTABLE_EVIDENCE')})
  $source=Get-AAValue $Record Source;$sourceKind=Get-AAValue $source Kind
  if($sourceKind -ceq 'Appx'){$kind='AppxRegistration';$layers.Add([pscustomobject]@{Layer='AppxIdentity';Status='DeclaredNotAuthenticated';Codes=@('PACKAGE_REGISTRATION_NOT_SIGNATURE_PROOF')})}
  elseif($sourceKind -ceq 'Registry'){
   if((Get-AAValue $Record WindowsInstaller) -is [bool] -and (Get-AAValue $Record WindowsInstaller) -eq $true){$kind='MsiDeclaredNotAuthoritativelyChecked'}else{$kind='RegistryUninstallerUnknown'}
  }
  $location=Get-AALocationClass (Get-AAValue $Record InstallLocation)
  $layers.Add([pscustomobject]@{Layer='RegisteredLocation';Status=$location;Codes=@('LOCATION_SELF_DECLARED_NOT_OWNERSHIP_PROOF')})
  $layers.Add([pscustomobject]@{Layer='Registration';Status=$kind;Codes=@('REGISTRATION_SELF_DECLARED','HASH_IS_NOT_AUTHENTICATION')})
  $layers.Add([pscustomobject]@{Layer='ComponentProtection';Status=$(if($protected -eq $true){'Protected'}elseif($protected -eq $false){'ExistingPolicyRetained'}else{'Unknown'});Codes=@('ASSESSMENT_CANNOT_OVERRIDE_PROTECTION')})
  if((Get-AAValue $Record SystemComponent) -eq $true -or (Get-AAValue $Record NoRemove) -eq $true){$layers.Add([pscustomobject]@{Layer='ComponentFlags';Status='ProtectionFlagPresent';Codes=@('REGISTERED_COMPONENT_OR_NO_REMOVE')})}
  $layers.Add([pscustomobject]@{Layer='NamePublisher';Status='SelfDeclared';Codes=@('NOT_SIGNATURE_OR_LEGITIMACY_PROOF')})
  $known=& $script:AAPurpose {param($n,$p) Get-AppPurposeAnalysis -DisplayName $n -Publisher $p} $name $publisher
  if($known.Matched){
   foreach($url in $known.SourceUrls){$urls.Add($url)}
   $candidates.Add([pscustomobject]@{Category=$known.Category;Label=$known.PurposeGroup;Confidence='Medium';BasisCodes=@('BOUNDED_LOCAL_CATALOG_MATCH');Summary=$known.PurposeSummary})
  }
 }
 $evidenceStatus='NotProvided'
 if($null -ne $AppEvidence){
  $bound=($valid -and (Get-AAValue $AppEvidence SchemaVersion) -eq 1 -and (Get-AAValue $AppEvidence Kind) -ceq 'AppLocalEvidence' -and (Get-AAValue $AppEvidence RecordId) -ceq $id -and (Get-AAValue $AppEvidence RecordHash) -ceq $hash)
  $observed=[DateTimeOffset]::MinValue
  if(-not $bound){$evidenceStatus='Rejected';$conflicts.Add('LOCAL_EVIDENCE_BINDING_INVALID')}
  elseif(-not [DateTimeOffset]::TryParse([string](Get-AAValue $AppEvidence ObservedUtc),[ref]$observed) -or $observed -gt $AsOfUtc.AddMinutes(5) -or $observed -lt $AsOfUtc.AddHours(-24)){$evidenceStatus='StaleOrInvalidTime';$conflicts.Add('LOCAL_EVIDENCE_TIME_INVALID_OR_STALE')}
  else{
   $evidenceStatus=$(if((Get-AAValue $AppEvidence Complete) -is [bool] -and (Get-AAValue $AppEvidence Complete) -eq $true){'BoundSnapshot'}else{'BoundPartialSnapshot'})
   $file=Get-AAValue $AppEvidence File;$signature=Get-AAValue $AppEvidence Signature
   if((Get-AAValue $file Status) -ceq 'Read'){
    $meta=Get-AAValue $file Metadata
    $company=Get-AASafeText (Get-AAValue $meta CompanyName);$product=Get-AASafeText (Get-AAValue $meta ProductName)
    $description=Get-AASafeText (Get-AAValue $meta FileDescription)
    $metadataText=$product+' '+$description
    $original=Get-AASafeText (Get-AAValue $meta OriginalFilename)
    $selected=Get-AASafeText (Get-AAValue $file Path)
    if($original -and $selected){
     try{if([IO.Path]::GetFileName($selected) -ine $original){$conflicts.Add('FILE_ORIGINAL_NAME_DIFFERS_FROM_SELECTED_NAME')}}catch{$conflicts.Add('SELECTED_FILENAME_FORMAT_UNKNOWN')}
    }
    $fileVersion=Get-AASafeText (Get-AAValue $meta ProductVersion)
    $registeredVersion=Get-AASafeText (Get-AAValue $Record DisplayVersion)
    if($fileVersion -and $registeredVersion -and $fileVersion -ine $registeredVersion){$conflicts.Add('FILE_VERSION_REGISTRY_VERSION_DIFFER')}
    $layers.Add([pscustomobject]@{Layer='FileVersionInfo';Status='SelfDeclaredNotAuthenticated';Codes=@('USER_SELECTED_FILE_OWNERSHIP_UNPROVEN','METADATA_NOT_SIGNATURE_PROOF')})
    if($company -and $publisher -and $company -ine $publisher){$conflicts.Add('FILE_COMPANY_REGISTRY_PUBLISHER_DIFFER')}
    if($product -and $name -and $product -ine $name){$conflicts.Add('FILE_PRODUCT_REGISTRY_NAME_DIFFER')}
    if($company -and $publisher -and $company -ieq $publisher -and $product -and $product -ieq $name){$identity='MetadataConsistentNotAuthenticated'}
    if((Get-AAValue $file Association) -cne 'UserSelectedNotProvenOwnership'){$conflicts.Add('FILE_ASSOCIATION_NOT_PROVEN')}
   }else{$layers.Add([pscustomobject]@{Layer='FileVersionInfo';Status='UnavailableOrNotRequested';Codes=@('NO_FILE_IDENTITY_CONCLUSION')})}
   $cert=Get-AAValue $signature CertificateTable
   if($cert -cnotin @('Present','Absent','Unknown')){$cert='Unknown'}
   $layers.Add([pscustomobject]@{Layer='OfflineSignature';Status=('CertificateTable'+$cert);Codes=@('STRUCTURAL_MARKER_ONLY','NO_CERTIFICATE_TRUST_OR_SIGNATURE_VALIDATION')})
   if((Get-AAValue $signature Status) -cne 'NotVerified' -or (Get-AAValue $signature PublisherTrust) -cne 'Unknown'){$conflicts.Add('UNSUPPORTED_SIGNATURE_TRUST_CLAIM')}
  }
 }
 $layers.Add([pscustomobject]@{Layer='LocalEvidence';Status=$evidenceStatus;Codes=@('NO_FILE_OR_NETWORK_ACCESS_BY_ASSESSMENT')})
 if($valid){
  foreach($rule in $script:AARules){
   $basis=@()
   if($name -match $rule.Pattern){$basis+='DISPLAY_NAME_KEYWORD'}
   if($registryDescription -match $rule.Pattern){$basis+='SELF_DECLARED_REGISTRY_DESCRIPTION_KEYWORD'}
   if($metadataText -match $rule.Pattern){$basis+='UNAUTHENTICATED_FILE_METADATA_KEYWORD'}
   if($basis.Count -gt 0){$candidates.Add([pscustomobject]@{Category=$rule.Category;Label=$rule.Label;Confidence='Low';BasisCodes=$basis;Summary='語句からの用途候補。製品の実体・安全性・不要性・依存関係は未確認。'})}
  }
 }
 if($valid){
  $vendorHints=@{
   'Autodesk, Inc.'='CadCamEngineering';'Autodesk'='CadCamEngineering';'Dassault Systemes'='CadCamEngineering';
   'The MathWorks, Inc.'='Scientific';'Wolfram Research, Inc.'='Scientific';'PostgreSQL Global Development Group'='Database'
  }
  if($vendorHints.ContainsKey($publisher)){
   $category=$vendorHints[$publisher];$rule=@($script:AARules|Where-Object Category -eq $category)[0]
   $candidates.Add([pscustomobject]@{Category=$category;Label=$rule.Label;Confidence='Low';BasisCodes=@('SELF_DECLARED_PUBLISHER_FAMILY_HINT');Summary='登録発行元からの分野候補。発行元の認証や製品の特定ではありません。'})
  }
 }
 $weak=@($candidates|Where-Object Confidence -eq 'Low')
 if(@($weak|ForEach-Object{$_.Category}|Sort-Object -Unique).Count -gt 1){$conflicts.Add('MULTIPLE_WEAK_CATEGORY_CANDIDATES')}
 if(@($conflicts|Where-Object{$_ -like 'FILE_*' -or $_ -eq 'UNSUPPORTED_SIGNATURE_TRUST_CLAIM'}).Count -gt 0 -and $identity -ne 'Unverified'){$identity='ConflictingOrIncompleteEvidence'}
 foreach($candidate in $candidates){$candidate|Add-Member -NotePropertyName LabelJa -NotePropertyValue $candidate.Label;$candidate|Add-Member -NotePropertyName ConfidenceLabelJa -NotePropertyValue $(if($candidate.Confidence -eq 'Medium'){'中（名称・発行元候補の一致）'}else{'低（語句・自己申告からの候補）'})}
 $layerLabels=@{RegisteredSize='登録サイズの有無';RegisteredDate='登録日付の有無';RegistrationFlags='登録フラグの申告';RegistryDescription='登録された説明文';RegisteredLocation='登録先の種類';Registration='インストール登録';AppxIdentity='Appxの登録識別';ComponentProtection='既存の保護判定';ComponentFlags='Windows部品・削除禁止フラグ';NamePublisher='名称・発行元の申告';FileVersionInfo='選択ファイルの製品情報';OfflineSignature='署名領域の構造';LocalEvidence='追加のローカル証拠'}
 foreach($layer in $layers){$layer|Add-Member -NotePropertyName LabelJa -NotePropertyValue $layerLabels[$layer.Layer]}
 $summary=if($null -ne $known -and $known.Matched){$known.PurposeSummary}elseif($candidates.Count -gt 0){'用途候補: '+(@($candidates|ForEach-Object{$_.Label}|Select-Object -Unique) -join ' / ')+'。低信頼の推定であり、不要性・削除可否は判断しません。'}else{'用途不明。登録情報だけでは判断できません。'}
 [pscustomobject]@{
  Summary=$summary;PurposeSummary=$summary;IdentitySummary=$(if($identity -eq 'MetadataConsistentNotAuthenticated'){'申告情報は一致。ただし製品実体・署名・所有関係は未認証。'}elseif($identity -eq 'ConflictingOrIncompleteEvidence'){'根拠に不一致または不足があります。製品の同一性は未確認。'}else{'製品の同一性は未認証。名称や登録情報は偽装される可能性があります。'})
  AssessmentVersion=1;DisplayOnly=$true;RecordId=$id;RecordHash=$hash;RegistrationType=$kind
  IdentityConfidence=$identity;DeclaredLocationClass=$location;CandidateCategories=$candidates.ToArray()
  EvidenceLayers=$layers.ToArray();ConflictCodes=$conflicts.ToArray()
  Unknowns=@('SafetyNotDetermined','NecessityUnknown','DependenciesUnknown','ExecutableOwnershipUnproven','InstallerActorUnknown','NetworkBehaviorNotEvaluated')
  Protection=[pscustomobject]@{OriginalProtected=$protected;EligibilityEvaluated=$false;OverrideApplied=$false}
  Research=[pscustomobject]@{OfficialUrls=@($urls.ToArray()|Select-Object -Unique);AutomaticLookup=$false;NoDataTransmitted=$true;RequiresExplicitUserClick=$true;Steps=@('名称と発行元を公式製品情報と照合する。','インストール元、用途、組織の管理対象かを本人に確認する。','依存アプリと復元方法が分からなければ削除しない。')}
  Limitations=@('名称・発行元・ファイル情報は自己申告で偽装可能。','署名欄の存在は署名の検証成功でも発行元の認証でもない。','候補の信頼度は用途推定のみ。安全性や削除可否の判定ではない。','登録フォルダーは申告値。実ファイルの所有関係を証明しない。')
 }
}
Export-ModuleMember -Function Get-AppAssessment
