$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\NetworkSnapshot.psm1') -Force
$m=Get-Module NetworkSnapshot
& $m {
 $script:count=0;$script:pc=0;$script:mode='stable'
 function script:Get-NsTcpConnections {
  $script:count++
  if($script:mode -eq 'denied'){throw 'SECRET'}
  if($script:mode -eq 'gone' -and $script:count -eq 2){return}
  $e=[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=123;RemoteAddress='192.0.2.1';RemotePort=443;State='Established';OwningProcess=99}
  if($script:mode -eq 'changed' -and $script:count -eq 2){$e.State='CloseWait'}
  if($script:mode -eq 'cap'){1..501|ForEach-Object {$e}}else{$e}
 }
 function script:Get-NsProcessIdentity($ProcessId) {
  $script:pc++
  if($script:mode -eq 'access'){throw 'SECRET-PATH'}
  $p=[pscustomobject]@{Id=[int]$ProcessId;Name='browser';Path='C:\Apps\Browser\browser.exe';StartTimeUtc='2026-01-01T00:00:00Z'}
  if($script:mode -eq 'reuse' -and $script:pc -eq 2){$p.StartTimeUtc='2026-01-01T00:01:00Z'}
  if($script:mode -eq 'pathchange' -and $script:pc -eq 2){$p.Path='C:\Other\browser.exe'}
  if($script:mode -eq 'nopath'){$p.Path=$null}
  if($script:mode -eq 'boundary'){$p.Path='C:\Apps\BrowserOther\evil.exe'}
  $p
 }
 function script:Test-NsRecord($Record) {return $Record.Id -ne 'invalid'}
}
$n=0
function Assert($v,$message){if(-not $v){throw $message};$script:n++}
function Run($mode){& $m {param($mode) $script:mode=$mode;$script:count=0;$script:pc=0} $mode;Get-AppNetworkSnapshot -Inventory $inventory}
$inventory=@{Records=@(@{Id='valid';DisplayName='Browser';InstallLocation='C:\Apps\Browser'})}
$r=Run 'stable'
Assert $r.Complete 'stable complete'
Assert ($r.Endpoints.Count -eq 1) 'endpoint'
Assert ($r.Endpoints[0].AttributionStatus -eq 'Candidate') 'candidate only'
Assert ($r.Endpoints[0].CandidateApps.Count -eq 1) 'one candidate'
Assert ((& $m {$script:count}) -eq 2) 'two snapshots'
Assert ((& $m {$script:pc}) -eq 2) 'two identities'
foreach($mode in @('reuse','pathchange','gone','changed','access','nopath','boundary')) {
 $r=Run $mode
 Assert ($r.Endpoints[0].AttributionStatus -eq 'Unknown') "$mode unknown"
 Assert ($r.Endpoints[0].CandidateApps.Count -eq 0) "$mode no candidate"
}
$r=Run 'denied';Assert (-not $r.Complete) 'denied incomplete';Assert (($r|ConvertTo-Json -Depth 10) -notmatch 'SECRET') 'error secret omitted'
$r=Run 'cap';Assert $r.Truncated 'cap flag';Assert ($r.Endpoints.Count -eq 500) '500 cap';Assert (-not $r.Complete) 'cap incomplete';Assert ($r.Endpoints[0].AttributionStatus -eq 'Unknown') 'duplicate unknown'
foreach($location in @('C:\','C:\Windows','C:\Program Files','\\server\share','relative','C:\Apps\Browser:secret')) {
 $inventory.Records[0].InstallLocation=$location;$r=Run 'stable';Assert ($r.Endpoints[0].AttributionStatus -eq 'Unknown') 'invalid broad path'
}
$inventory.Records[0].InstallLocation='C:\Apps\Browser';$inventory.Records[0].Id='invalid';$r=Run 'stable';Assert ($r.Endpoints[0].AttributionStatus -eq 'Unknown') 'unverified record excluded'
Assert ($r.LocalOnly -and $r.Limitations.Count -ge 5) 'local only limits'
$inventory=$null;$r=Run 'stable';Assert ($r.Endpoints.Count -eq 1 -and $r.Endpoints[0].CandidateApps.Count -eq 0) 'null inventory returns unassociated snapshot'
Write-Output "PASS: $n network assertions (all TCP/process queries mocked)"
