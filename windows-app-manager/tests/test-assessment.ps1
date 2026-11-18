$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $PSScriptRoot '..\AppAssessment.psm1') -Force -PassThru
$ai=& $m {$script:AAInventory}
$n=0
function Assert($v,$msg){if(-not $v){throw $msg};$script:n++}
function Record($name='Research SQL CAD Tool',$publisher='Example Vendor'){
 & $ai {param($name,$publisher)
  New-AiRecord @{DisplayName=$name;DisplayVersion='1.0';Publisher=$publisher;SystemComponent=0;NoRemove=0;WindowsInstaller=1;InstallLocation='C:\Program Files\SecretFolder';UninstallString='SECRET_COMMAND'} ([pscustomobject][ordered]@{Kind='Registry';Hive='CurrentUser';View='Registry64';Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}';PackageFullName='';UserSid='S-1-5-21-1'})
 } $name $publisher
}
$now=[DateTimeOffset]'2026-11-18T12:00:00Z'
function Evidence($r){
 @{SchemaVersion=1;Kind='AppLocalEvidence';RecordId=$r.Id;RecordHash=$r.RecordHash;ObservedUtc='2026-11-18T11:00:00Z';Complete=$true
 File=@{Status='Read';Path='C:\PRIVATE_SECRET\secret.exe';Association='UserSelectedNotProvenOwnership';Metadata=@{CompanyName=$r.Publisher;ProductName=$r.DisplayName;FileDescription='database engineering';OriginalFilename='secret.exe'}}
 Signature=@{Status='NotVerified';PublisherTrust='Unknown';CertificateTable='Present'};Errors=@('SECRET_ERROR')}
}
$r=Record;$before=$r|ConvertTo-Json -Depth 20
$a=Get-AppAssessment $r -AsOfUtc $now
Assert $a.DisplayOnly 'display only'
Assert ($a.Protection.OriginalProtected -and -not $a.Protection.OverrideApplied -and -not $a.Protection.EligibilityEvaluated) 'unknown protection retained'
Assert (@($a.CandidateCategories|Where-Object Category -eq 'Database').Count -gt 0) 'database candidate'
Assert (@($a.CandidateCategories|Where-Object Category -eq 'CadCamEngineering').Count -gt 0) 'CAD candidate'
Assert ($a.ConflictCodes -contains 'MULTIPLE_WEAK_CATEGORY_CANDIDATES') 'ambiguity surfaced'
Assert (($r|ConvertTo-Json -Depth 20) -ceq $before) 'input immutable'
Assert ($a.DeclaredLocationClass -eq 'ProgramFilesDeclared') 'location declared only'
Assert (-not $a.Research.AutomaticLookup -and $a.Research.RequiresExplicitUserClick -and $a.Research.NoDataTransmitted) 'no implicit external lookup'
Assert (($a|ConvertTo-Json -Depth 20) -notmatch 'SECRET|SecretFolder') 'no input paths commands or errors leaked'
$e=Evidence $r;$a=Get-AppAssessment $r $e -AsOfUtc $now
Assert ($a.IdentityConfidence -eq 'MetadataConsistentNotAuthenticated') 'consistency not auth'
Assert (@($a.EvidenceLayers|Where-Object Layer -eq 'OfflineSignature')[0].Status -eq 'CertificateTablePresent') 'PE marker not verified'
Assert (($a|ConvertTo-Json -Depth 20) -notmatch 'PRIVATE_SECRET|SECRET_COMMAND|SECRET_ERROR|SECRET.exe') 'evidence paths and errors not echoed'
foreach($change in @(
 {$e.RecordHash=('b'*64)},{$e.RecordId=('b'*64)},{$e.Kind='wrong'},{$e.SchemaVersion=2},
 {$e.ObservedUtc='2020-01-01T00:00:00Z'},{$e.ObservedUtc='invalid'},{$e.ObservedUtc='2027-01-01T00:00:00Z'}
)){
 $e=Evidence $r;&$change;$a=Get-AppAssessment $r $e -AsOfUtc $now
 Assert ($a.ConflictCodes.Count -gt 0 -and @($a.EvidenceLayers|Where-Object Layer -eq 'FileVersionInfo').Count -eq 0) 'invalid bound evidence ignored'
}
foreach($field in @('CompanyName','ProductName')){
 $e=Evidence $r;$e.File.Metadata[$field]='Other';$a=Get-AppAssessment $r $e -AsOfUtc $now
 Assert (@($a.ConflictCodes|Where-Object{$_ -like 'FILE_*_DIFFER'}).Count -gt 0) 'metadata mismatch'
}
$e=Evidence $r;$e.Signature.Status='Valid';$e.Signature.PublisherTrust='Trusted'
$a=Get-AppAssessment $r $e -AsOfUtc $now
Assert ($a.ConflictCodes -contains 'UNSUPPORTED_SIGNATURE_TRUST_CLAIM') 'forged signature claim not accepted'
$r=Record '7-Zip' 'Igor Pavlov';$a=Get-AppAssessment $r -AsOfUtc $now
Assert (@($a.CandidateCategories|Where-Object Confidence -eq 'Medium').Count -eq 1) 'known bounded dictionary'
Assert ($a.Research.OfficialUrls -contains 'https://www.7-zip.org/') 'fixed official source'
$r=Record '7-Zip' 'Wrong Publisher';$a=Get-AppAssessment $r -AsOfUtc $now
Assert (@($a.CandidateCategories|Where-Object Confidence -eq 'Medium').Count -eq 0 -and $a.Protection.OriginalProtected) 'fake publisher no dictionary or eligibility uplift'
foreach($case in @(@('MATLAB','Scientific'),@('Invoice Office','BusinessOffice'),@('Audio Player','Media'),@('Image Design','GraphicsDesign'),@('Development IDE','Development'),@('Game Launcher','Game'),@('Chat Meeting','Communication'),@('Web Browser','Browser'),@('Backup Utility','Utility'),@('Runtime Framework','SystemRuntime'),@('VPN Driver','SecurityNetwork'))){
 $r=Record $case[0];$a=Get-AppAssessment $r -AsOfUtc $now
 Assert (@($a.CandidateCategories|Where-Object Category -eq $case[1]).Count -gt 0) ('wide domain '+$case[1])
 Assert (@($a.CandidateCategories|Where-Object Confidence -ne 'Low').Count -eq 0) 'weak only'
}
$r=Record;$r.DisplayName='tampered';$a=Get-AppAssessment $r -AsOfUtc $now
Assert ($a.ConflictCodes -contains 'RECORD_INTEGRITY_INVALID' -and $a.CandidateCategories.Count -eq 0) 'tamper suppresses classification'
Assert ($null -eq $a.RecordId -and $null -eq $a.RecordHash) 'bad identity not echoed'
$r=Record;$e=Evidence $r;$e.File.Metadata.OriginalFilename='other.exe';$a=Get-AppAssessment $r $e -AsOfUtc $now
Assert ($a.ConflictCodes -contains 'FILE_ORIGINAL_NAME_DIFFERS_FROM_SELECTED_NAME') 'filename mismatch noted without claiming malware'
$e=Evidence $r;$e.File.Metadata.ProductVersion='9.0';$a=Get-AppAssessment $r $e -AsOfUtc $now
Assert ($a.ConflictCodes -contains 'FILE_VERSION_REGISTRY_VERSION_DIFFER') 'file version differs'
$r=Record 'Mystery Application' 'Unknown';$a=Get-AppAssessment $r -AsOfUtc $now
Assert ($a.CandidateCategories.Count -eq 0 -and $a.DisplayOnly) 'unknown empty result safe'
# Registry fields are untrusted and never echoed as text or quantities.
$r=Record 'Mystery Application' 'Unknown'
$r.Metadata.Comments='database engineering editor'
$r.Metadata.EstimatedSizeKiB=123456
$r.Evidence.InstallDateDeclared='20261117'
$r.RecordHash=& $ai {param($x) Get-AiRecordHash $x} $r
$a=Get-AppAssessment $r -AsOfUtc $now
Assert (@($a.CandidateCategories|Where-Object{$_.BasisCodes -contains 'SELF_DECLARED_REGISTRY_DESCRIPTION_KEYWORD'}).Count -gt 0) 'comments separate weak basis'
Assert (@($a.CandidateCategories|Where-Object Confidence -ne 'Low').Count -eq 0) 'comments never medium confidence'
Assert (@($a.EvidenceLayers|Where-Object Layer -eq 'RegisteredSize')[0].Status -eq 'NonnegativeSizeDeclaredNotMeasured') 'registered size declaration not measurement'
Assert (@($a.EvidenceLayers|Where-Object Layer -eq 'RegisteredDate')[0].Status -eq 'DateDeclaredNotProvenInstallationTime') 'date declaration only'
Assert (($a|ConvertTo-Json -Depth 20) -notmatch '123456|20261117|database engineering editor') 'raw registry values withheld'
foreach($text in @('https://private.example/SQL?token=SECRET','C:\PRIVATE\CAD\SECRET','\\private\share\database',('x'*513))){
 $r.Metadata.Comments=$text;$r.RecordHash=& $ai {param($x) Get-AiRecordHash $x} $r
 $a=Get-AppAssessment $r -AsOfUtc $now
 Assert (@($a.CandidateCategories|Where-Object{$_.BasisCodes -contains 'SELF_DECLARED_REGISTRY_DESCRIPTION_KEYWORD'}).Count -eq 0) 'paths URLs long text excluded'
 Assert (($a|ConvertTo-Json -Depth 20) -notmatch 'SECRET|private.example') 'no query path secret output'
}
$r.Metadata.Comments='';$r.Metadata.EstimatedSizeKiB=-1;$r.Evidence.InstallDateDeclared='20260230'
$r.RecordHash=& $ai {param($x) Get-AiRecordHash $x} $r
$a=Get-AppAssessment $r -AsOfUtc $now
Assert (@($a.EvidenceLayers|Where-Object Layer -eq 'RegisteredDate')[0].Status -eq 'InvalidDeclaration') 'invalid date not accepted'
Assert (@($a.EvidenceLayers|Where-Object Layer -eq 'RegisteredSize')[0].Status -eq 'InvalidDeclaration') 'negative size not accepted'
# Import assessment must not reload dependencies or erase callers' exported commands.
Import-Module (Join-Path $PSScriptRoot '..\AppInventory.psm1') -Global
$beforeInventory=Get-Command Get-AppInventory
$beforeIntegrity=Get-Command Test-AppRecordIntegrity
$beforeModule=$beforeInventory.Module
Import-Module (Join-Path $PSScriptRoot '..\AppAssessment.psm1') -Force
Assert ([object]::ReferenceEquals($beforeModule,(Get-Command Get-AppInventory).Module)) 'existing inventory module reused'
Assert ((Get-Command Test-AppRecordIntegrity).Definition -ceq $beforeIntegrity.Definition) 'integrity export retained'
Assert ((Get-Command Get-AppInventory).Definition -ceq $beforeInventory.Definition) 'inventory export retained'
Write-Output "PASS assessment assertions=$n (pure synthetic inputs)"
