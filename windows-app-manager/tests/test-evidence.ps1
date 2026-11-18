$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\AppEvidence.psm1') -Force
$m=Get-Module AppEvidence
& $m {
 $script:originalState=${function:Get-AeFileState};$script:reads=0;$script:mode='normal';$script:bytes=[byte[]]::new(512)
 function script:Test-AeRecord($Record){$Record.Id -eq 'valid'}
 function script:Get-AeFileState($Path){$script:reads++;if($script:mode -eq 'denied'){throw 'SECRET'};$size=512;if($script:mode -eq 'change' -and $script:reads%2 -eq 0){$size=513};[pscustomobject]@{Length=$size;LastWriteUtcTicks=1;CreationUtcTicks=1}}
 function script:Open-AeFile($Path){[IO.MemoryStream]::new($script:bytes,$false)}
 function script:Get-AeVersion($Path){[pscustomobject]@{CompanyName=('Unverified'+[char]0x202e+' company');ProductName='claimed product';FileDescription='desc';FileVersion='1';ProductVersion='1';OriginalFilename='tool.exe'}}
}
$n=0
function Assert($v,$message){if(-not $v){throw $message};$script:n++}
$record=@{Id='valid';RecordHash='abc';Source=@{Kind='Registry';Key='test';Secret='SECRET'}}
$r=Get-AppEvidence -Record $record
Assert (($r|ConvertTo-Json -Depth 10) -notmatch 'SECRET') 'source allowlist'
Assert ($r.File.Status -eq 'NotRequested') 'opt in only'
Assert ((& $m {$script:reads}) -eq 0) 'no file query on record only'
$r=Get-AppEvidence -Record $record -ExecutablePath 'C:\Apps\tool.exe'
Assert ($r.File.Status -eq 'Read') 'read mock'
Assert ($r.File.Sha256 -match '^[0-9a-f]{64}$') 'hash'
Assert ($r.Signature.Status -eq 'NotVerified') 'signature not trusted'
Assert ($r.File.Metadata.CompanyName -eq 'Unverified  company') 'self declared metadata'
Assert ($r.RecordId -eq 'valid' -and $r.RecordHash -eq 'abc') 'binding'
foreach($path in @('\\host\share\tool.exe','\\?\C:\tool.exe','C:\tool.exe:secret','C:\NUL.exe','C:\folder\..\tool.exe','C:\folder\tool.dll','relative.exe','C:\folder\tool.exe.')) {
 $before=& $m {$script:reads};$r=Get-AppEvidence -Record $record -ExecutablePath $path
 Assert ($r.File.Status -eq 'Unknown') 'unsafe path rejected';Assert ($r.Errors[0].ReasonCode -eq 'LOCAL_REGULAR_EXE_REQUIRED') 'fixed reason';Assert ((& $m {$script:reads}) -eq $before) 'reject before file access'
}
foreach($mode in @('denied','change')) {& $m {param($mode)$script:mode=$mode;$script:reads=0} $mode;$r=Get-AppEvidence -Record $record -ExecutablePath 'C:\Apps\tool.exe';Assert (-not $r.Complete -and $r.File.Status -eq 'Unknown') 'errors unknown';Assert (($r|ConvertTo-Json -Depth 10) -notmatch 'SECRET') 'sanitized'}
# Synthetic PE table cases, no executable or native API involved.
$result=& $m {
 $b=[byte[]]::new(512)
 [BitConverter]::GetBytes([uint16]0x5a4d).CopyTo($b,0);[BitConverter]::GetBytes([uint32]64).CopyTo($b,60)
 [BitConverter]::GetBytes([uint32]0x4550).CopyTo($b,64);[BitConverter]::GetBytes([uint16]224).CopyTo($b,84)
 [BitConverter]::GetBytes([uint16]0x10b).CopyTo($b,88);[BitConverter]::GetBytes([uint32]16).CopyTo($b,180)
 $s=[IO.MemoryStream]::new($b,$false);try{Get-AeCertificateTable $s}finally{$s.Dispose()}
 [BitConverter]::GetBytes([uint32]400).CopyTo($b,216);[BitConverter]::GetBytes([uint32]16).CopyTo($b,220)
 [BitConverter]::GetBytes([uint32]16).CopyTo($b,400);[BitConverter]::GetBytes([uint16]0x200).CopyTo($b,404);[BitConverter]::GetBytes([uint16]2).CopyTo($b,406)
 $s=[IO.MemoryStream]::new($b,$false);try{Get-AeCertificateTable $s}finally{$s.Dispose()}
 [BitConverter]::GetBytes([uint32]500).CopyTo($b,216)
 $s=[IO.MemoryStream]::new($b,$false);try{Get-AeCertificateTable $s}finally{$s.Dispose()}
}
Assert ($result[0] -eq 'Absent') 'absent table'
Assert ($result[1] -eq 'Present') 'present structure only'
Assert ($result[2] -eq 'Unknown') 'malformed table'
$record.Id='invalid';$threw=$false;try{Get-AppEvidence -Record $record|Out-Null}catch{$threw=$true};Assert $threw 'invalid record rejected'
$states=& $m {
 $script:guard='normal'
 function script:Get-AeDriveType($Root){if($script:guard -eq 'network'){[IO.DriveType]::Network}else{[IO.DriveType]::Fixed}}
 function script:Get-AeAttributes($Path){if($script:guard -eq 'reparse' -and $Path -eq 'C:\Apps'){[IO.FileAttributes]::ReparsePoint}elseif($script:guard -eq 'directory'){[IO.FileAttributes]::Directory}else{[IO.FileAttributes]::Normal}}
 function script:Get-AeFileInfo($Path){$size=512;if($script:guard -eq 'large'){$size=134217729};[pscustomobject]@{Length=$size;LastWriteTimeUtc=[DateTime]::UtcNow;CreationTimeUtc=[DateTime]::UtcNow}}
 foreach($mode in @('normal','network','reparse','directory','large')) {
  $script:guard=$mode
  try{& $script:originalState 'C:\Apps\tool.exe'|Out-Null;'accepted'}catch{'rejected'}
 }
}
Assert ($states[0] -eq 'accepted') 'regular local accepted'
foreach($index in 1..4){Assert ($states[$index] -eq 'rejected') 'unsafe file metadata rejected'}
Write-Output "PASS: $n evidence assertions (mocked reads and synthetic memory only)"
