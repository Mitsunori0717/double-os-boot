Set-StrictMode -Version Latest
function Get-NsTcpConnections { Get-NetTCPConnection -ErrorAction Stop | Select-Object -First 501 LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess }
function Get-NsProcessIdentity([int]$ProcessId) {
 $p=Get-Process -Id $ProcessId -ErrorAction Stop
 try {[pscustomobject]@{Id=$p.Id;StartTimeUtc=$p.StartTime.ToUniversalTime().ToString('o');Path=$p.Path;Name=$p.ProcessName}}finally{$p.Dispose()}
}
function Get-NsValue($Object,[string]$Name,$Default=$null) {
 if($null -eq $Object){return $Default}
 if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]}}
 elseif($Object.PSObject.Properties[$Name]){return $Object.$Name}
 return $Default
}
function Get-NsLocalPath($Path) {
 if($Path -isnot [string] -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f]' -or $Path.Substring(2).Contains(':')){return $null}
 try { return [IO.Path]::GetFullPath($Path).TrimEnd('\','/') } catch {return $null}
}
function Test-NsRecord($Record) {
 if(-not (Get-Command Test-AppRecordIntegrity -ErrorAction SilentlyContinue)) {Import-Module (Join-Path $PSScriptRoot 'AppInventory.psm1') -ErrorAction Stop}
 Test-AppRecordIntegrity $Record
}
function Get-NsEndpointKey($Endpoint) {
 $fields=@('LocalAddress','LocalPort','RemoteAddress','RemotePort','State','OwningProcess')
 $values=@();foreach($field in $fields){$v=Get-NsValue $Endpoint $field;if($null -eq $v){return $null};$values+=([string]$v)}
 ConvertTo-Json -InputObject $values -Compress
}
function Test-NsIdentity($First,$Second,[int]$ProcessId) {
 if($null -eq $First -or $null -eq $Second){return $false}
 foreach($p in @($First,$Second)) {
  $id=Get-NsValue $p 'Id';$start=Get-NsValue $p 'StartTimeUtc';$path=Get-NsLocalPath (Get-NsValue $p 'Path');$name=Get-NsValue $p 'Name'
  if($id -isnot [int] -or $id -ne $ProcessId -or -not $path -or $start -isnot [string] -or [string]::IsNullOrWhiteSpace($name)){return $false}
  $date=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($start,[ref]$date)){return $false}
 }
 ((Get-NsValue $First 'StartTimeUtc') -ceq (Get-NsValue $Second 'StartTimeUtc')) -and ((Get-NsLocalPath (Get-NsValue $First 'Path')) -ieq (Get-NsLocalPath (Get-NsValue $Second 'Path'))) -and ((Get-NsValue $First 'Name') -ceq (Get-NsValue $Second 'Name'))
}
function Get-AppNetworkSnapshot {
 [CmdletBinding()]param([Parameter(Mandatory)][AllowNull()]$Inventory)
 $errors=[Collections.Generic.List[object]]::new();$output=[Collections.Generic.List[object]]::new()
 $observed=[DateTime]::UtcNow.ToString('o');$first=@();$second=@();$ok=$true
 try {$first=@(Get-NsTcpConnections)}catch{$errors.Add([pscustomobject]@{Code='TCP_SNAPSHOT_UNAVAILABLE'});$ok=$false}
 $truncated=$first.Count -gt 500;$selected=@($first|Select-Object -First 500)
 $before=@{};$after=@{}
 foreach($e in $selected) {
  $id=Get-NsValue $e 'OwningProcess'
  if($id -isnot [int] -and $id -isnot [uint32]){continue}
  if($id -le 0 -or $id -gt [int]::MaxValue -or $before.ContainsKey([int]$id)){continue}
  try {$before[[int]$id]=Get-NsProcessIdentity -ProcessId ([int]$id)}catch{$before[[int]$id]=$null;$errors.Add([pscustomobject]@{Code='PROCESS_IDENTITY_UNAVAILABLE'})}
 }
 if($ok){try {$second=@(Get-NsTcpConnections)}catch{$errors.Add([pscustomobject]@{Code='TCP_RECHECK_UNAVAILABLE'});$ok=$false}}
 if($second.Count -gt 500){$truncated=$true}
 foreach($id in @($before.Keys)) {
  try {$after[$id]=Get-NsProcessIdentity -ProcessId $id}catch{$after[$id]=$null;$errors.Add([pscustomobject]@{Code='PROCESS_RECHECK_UNAVAILABLE'})}
 }
 $firstKeys=@{};$secondKeys=@{}
 foreach($pair in @(@{Items=$selected;Keys=$firstKeys},@{Items=@($second|Select-Object -First 500);Keys=$secondKeys})) {
  foreach($e in $pair.Items){$key=Get-NsEndpointKey $e;if($key){if(-not $pair.Keys.ContainsKey($key)){$pair.Keys[$key]=0};$pair.Keys[$key]++}}
 }
 $records=@();foreach($record in @(Get-NsValue $Inventory 'Records' @())) {
  try {if(Test-NsRecord $record){$records+=,$record}}catch{$errors.Add([pscustomobject]@{Code='INVENTORY_RECORD_UNVERIFIED'})}
 }
 foreach($e in $selected) {
  $id=Get-NsValue $e 'OwningProcess';$key=Get-NsEndpointKey $e;$stable=$false
  if($ok -and $key -and $firstKeys[$key] -eq 1 -and $secondKeys.ContainsKey($key) -and $secondKeys[$key] -eq 1 -and ($id -is [int] -or $id -is [uint32]) -and $id -gt 0 -and $id -le [int]::MaxValue -and $before.ContainsKey([int]$id)) {
   $stable=Test-NsIdentity $before[[int]$id] $after[[int]$id] ([int]$id)
  }
  $candidates=[Collections.Generic.List[object]]::new();$processName=$null;$path=$null;$status='Unknown';$reason='EndpointOrProcessNotStableOrNotReadable'
  if($stable) {
   $processName=Get-NsValue $after[[int]$id] 'Name';$path=Get-NsLocalPath (Get-NsValue $after[[int]$id] 'Path');$reason='NoSpecificInstallationDirectoryMatch'
   foreach($record in $records) {
    $location=Get-NsLocalPath (Get-NsValue $record 'InstallLocation')
    # A drive root / broad system directory is not a specific app attribution.
    if(-not $location -or $location -match '^[A-Za-z]:$' -or $location -match '(?i)^[A-Za-z]:\\(Windows(?:\\System32|\\SysWOW64)?|Program Files(?: \(x86\))?|Users|ProgramData)$'){continue}
    if($path.StartsWith($location+'\',[StringComparison]::OrdinalIgnoreCase)) {
     $candidates.Add([pscustomobject]@{Id=(Get-NsValue $record 'Id');DisplayName=(Get-NsValue $record 'DisplayName');Basis='ProcessPathWithinDeclaredInstallLocation; not verified ownership'})
    }
   }
   if($candidates.Count -gt 0){$status='Candidate';$reason='DirectoryMatchOnly; shared processes and injected code cannot be attributed'}
  }
  $row=[ordered]@{};foreach($field in @('LocalAddress','LocalPort','RemoteAddress','RemotePort','State','OwningProcess')){$row[$field]=Get-NsValue $e $field}
  $row.ProcessName=$processName;$row.ProcessPath=$path;$row.AttributionStatus=$status;$row.AttributionBasis=$reason;$row.CandidateApps=@($candidates);$row.ObservedUtc=$observed
  $output.Add([pscustomobject]$row)
 }
 [pscustomobject][ordered]@{SchemaVersion=1;Kind='LocalTcpSnapshot';ObservedUtc=$observed;CompletedUtc=[DateTime]::UtcNow.ToString('o');Complete=($ok -and -not $truncated -and $errors.Count -eq 0);Truncated=$truncated;EndpointLimit=500;Endpoints=@($output);Errors=@($errors|Sort-Object Code -Unique);LocalOnly=$true;Limitations=@('One-time TCP table only; no new network connections are initiated.','At most 500 endpoints; not an atomic or exhaustive observation.','UDP, QUIC, past traffic and communication content are not measured.','Directory matches are candidates only; shared hosts, injected code and dependencies remain unknown.','No conclusion about data leakage, safety, necessity or removal is possible.','IP addresses and process paths are local display only; do not log or transmit this snapshot.')}
}
Export-ModuleMember -Function Get-AppNetworkSnapshot
