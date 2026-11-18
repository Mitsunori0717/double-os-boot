# Offline only. No Authenticode trust provider is invoked.
# https://learn.microsoft.com/en-us/windows/win32/api/wintrust/ns-wintrust-wintrust_data
# https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.fileversioninfo.getversioninfo
# https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
Set-StrictMode -Version Latest
function Get-AeValue($Object,[string]$Name,$Default=$null) {
 if($null -eq $Object){return $Default}
 if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
 elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
 return $Default
}
function Test-AeRecord($Record) {
 Import-Module (Join-Path $PSScriptRoot 'AppInventory.psm1') -ErrorAction Stop
 Test-AppRecordIntegrity $Record
}
function Get-AePath([string]$Path) {
 if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[\x00-\x1f/*?]' -or $Path.Substring(2).Contains(':') -or [IO.Path]::GetExtension($Path) -ine '.exe'){throw 'LOCAL_REGULAR_EXE_REQUIRED'}
 foreach($part in $Path.Substring(3).Split('\')){if($part -in @('','.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'LOCAL_REGULAR_EXE_REQUIRED'}}
 [IO.Path]::GetFullPath($Path)
}
function Get-AeDriveType([string]$Root) {([IO.DriveInfo]::new($Root)).DriveType}
function Get-AeAttributes([string]$Path) {[IO.File]::GetAttributes($Path)}
function Get-AeFileInfo([string]$Path) {[IO.FileInfo]::new($Path)}
function Get-AeFileState([string]$Path) {
 $driveType=Get-AeDriveType ([IO.Path]::GetPathRoot($Path))
 if($driveType -notin @([IO.DriveType]::Fixed,[IO.DriveType]::Removable)){throw 'LOCAL_DISK_REQUIRED'}
 $current=$Path
 while($current){
  $attrs=Get-AeAttributes $current
  if(($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'REPARSE_PATH_REJECTED'}
  if($current -eq $Path -and ($attrs -band [IO.FileAttributes]::Directory) -ne 0){throw 'REGULAR_FILE_REQUIRED'}
  $parent=[IO.Directory]::GetParent($current);if($null -eq $parent){break};$current=$parent.FullName
 }
 $info=Get-AeFileInfo $Path
 if($info.Length -le 0 -or $info.Length -gt 134217728){throw 'FILE_SIZE_REJECTED'}
 [pscustomobject]@{Length=$info.Length;LastWriteUtcTicks=$info.LastWriteTimeUtc.Ticks;CreationUtcTicks=$info.CreationTimeUtc.Ticks}
}
function Open-AeFile([string]$Path) {[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
function Get-AeVersion([string]$Path) {[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)}
function Get-AeHash($Stream) {
 $Stream.Position=0;$sha=[Security.Cryptography.SHA256]::Create()
 try {([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-AeCertificateTable($Stream) {
 # PE/COFF security directory is a file offset, not an RVA. Presence is NOT signature validation.
 $reader=[IO.BinaryReader]::new($Stream,[Text.Encoding]::ASCII,$true)
 try {
  if($Stream.Length -lt 64){return 'Unknown'}
  $Stream.Position=0;if($reader.ReadUInt16() -ne 0x5a4d){return 'Unknown'}
  $Stream.Position=60;$pe=[long]$reader.ReadUInt32()
  if($pe -lt 64 -or $pe+24 -gt $Stream.Length){return 'Unknown'}
  $Stream.Position=$pe;if($reader.ReadUInt32() -ne 0x4550){return 'Unknown'}
  $Stream.Position=$pe+20;$optionalLength=$reader.ReadUInt16();$optional=$pe+24
  if($optional+$optionalLength -gt $Stream.Length){return 'Unknown'}
  $Stream.Position=$optional;$magic=$reader.ReadUInt16()
  if($magic -eq 0x10b){$directory=96;$number=92}elseif($magic -eq 0x20b){$directory=112;$number=108}else{return 'Unknown'}
  if($optionalLength -lt $number+4){return 'Unknown'}
  $Stream.Position=$optional+$number;if($reader.ReadUInt32() -le 4){return 'Absent'}
  if($optionalLength -lt $directory+40){return 'Unknown'}
  $Stream.Position=$optional+$directory+32;$offset=[long]$reader.ReadUInt32();$size=[long]$reader.ReadUInt32()
  if($offset -eq 0 -and $size -eq 0){return 'Absent'}
  if($offset -lt $optional+$optionalLength -or $offset%8 -ne 0 -or $size -lt 8 -or $offset+$size -gt $Stream.Length){return 'Unknown'}
  $Stream.Position=$offset;$length=[long]$reader.ReadUInt32();$revision=$reader.ReadUInt16();$type=$reader.ReadUInt16()
  if($length -lt 8 -or $length -gt $size -or $revision -ne 0x200 -or $type -ne 2){return 'Unknown'}
  return 'Present'
 }finally{$reader.Dispose()}
}
function Get-AppEvidence {
 [CmdletBinding()]param([Parameter(Mandatory)]$Record,[string]$ExecutablePath)
 if(-not (Test-AeRecord $Record)){throw 'INVENTORY_RECORD_INVALID'}
 $errors=[Collections.Generic.List[object]]::new()
 $file=[ordered]@{Status='NotRequested';Path=$null;Size=$null;Sha256=$null;Metadata=$null;MetadataTrust='SelfDeclaredNotAuthenticated';Association='UserSelectedNotProvenOwnership'}
 $signature=[ordered]@{Status='NotVerified';CertificateTable='Unknown';PublisherTrust='Unknown';CertificateSubject='NotInspected';Reason='NoTrustProviderOrNetworkInvoked'}
 if($PSBoundParameters.ContainsKey('ExecutablePath')) {
  $stream=$null
  try {
   $path=Get-AePath $ExecutablePath;$before=Get-AeFileState $path;$stream=Open-AeFile $path
   if($stream.Length -ne $before.Length){throw 'FILE_CHANGED'}
   $hash=Get-AeHash $stream;$table=Get-AeCertificateTable $stream;$version=Get-AeVersion $path
   $metadata=[ordered]@{}
   foreach($field in @('CompanyName','ProductName','FileDescription','FileVersion','ProductVersion','OriginalFilename')) {
    $value=Get-AeValue $version $field ''
    if($value -isnot [string]){$value=''}
    $value=$value -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' '
    if($value.Length -gt 1024){$value=$value.Substring(0,1024)}
    $metadata[$field]=$value
   }
   $after=Get-AeFileState $path;$hashAfter=Get-AeHash $stream
   if($before.Length -ne $after.Length -or $before.LastWriteUtcTicks -ne $after.LastWriteUtcTicks -or $before.CreationUtcTicks -ne $after.CreationUtcTicks -or $hash -cne $hashAfter){throw 'FILE_CHANGED'}
   $file.Status='Read';$file.Path=$path;$file.Size=$before.Length;$file.Sha256=$hash;$file.Metadata=[pscustomobject]$metadata;$signature.CertificateTable=$table
  }catch{
   $file.Status='Unknown';$reason='READ_OR_METADATA_UNAVAILABLE'
   $allowed=@('LOCAL_REGULAR_EXE_REQUIRED','LOCAL_DISK_REQUIRED','REPARSE_PATH_REJECTED','REGULAR_FILE_REQUIRED','FILE_SIZE_REJECTED','FILE_CHANGED')
   if($_.Exception.Message -cin $allowed){$reason=$_.Exception.Message}
   $errors.Add([pscustomobject]@{Code='EXECUTABLE_EVIDENCE_UNAVAILABLE';ReasonCode=$reason;HResult=$_.Exception.HResult})
  }finally{if($null -ne $stream){$stream.Dispose()}}
 }
 $source=[ordered]@{};$registeredSource=Get-AeValue $Record 'Source'
 foreach($field in @('Kind','UserSid','Hive','View','Key','PackageFullName')) {
  $value=Get-AeValue $registeredSource $field ''
  if($value -isnot [string]){$value=''}
  $value=$value -replace '[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' '
  if($value.Length -gt 2048){$value=$value.Substring(0,2048)}
  $source[$field]=$value
 }
 [pscustomobject][ordered]@{SchemaVersion=1;Kind='AppLocalEvidence';RecordId=(Get-AeValue $Record 'Id');RecordHash=(Get-AeValue $Record 'RecordHash');ObservedUtc=[DateTime]::UtcNow.ToString('o');Complete=($errors.Count -eq 0);Registration=[pscustomobject]@{Source=[pscustomobject]$source;Trust='SelfDeclaredRegistryOrPackageRegistration';MsiContextStatus='NotQueried';PackageAuthenticity='NotVerified'};File=[pscustomobject]$file;Signature=[pscustomobject]$signature;Errors=@($errors);LocalOnly=$true;Limitations=@('No file execution, DLL loading, trust-provider invocation, network or directory search.','Signature and certificate subject are not verified; table presence is not proof of a valid signature.','Absence of an embedded certificate table does not exclude catalog signing.','Metadata and company names are self-declared and cannot establish safety or ownership.','Explicit file selection is not proof that a file belongs to the selected app.','Path checks and repeat hashing reduce accidental races, not a defense against a privileged concurrent attacker.','Evidence cannot remove protection or authorize uninstall; local paths must not be remotely sent or logged.')}
}
Export-ModuleMember -Function Get-AppEvidence
