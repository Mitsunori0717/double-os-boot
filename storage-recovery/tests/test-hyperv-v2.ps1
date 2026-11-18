#requires -Version 5.1
# Synthetic archives and MOCK Hyper-V wrappers only. Never run actual Hyper-V commands.
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $PSScriptRoot '..\HyperVRecovery.psm1') -Force -PassThru
$nativeSetTpm=& $m {(Get-Command Set-RecoveryNewTpm).ScriptBlock}
$n=0
function Assert($v,$message){if(-not $v){throw $message};$script:n++}
function Throws([scriptblock]$b){$failed=$false;try{&$b|Out-Null}catch{$failed=$true};Assert $failed 'expected refusal'}
function Profile {
 $p=[pscustomobject]@{InventoryCollectedUtc='2026-01-01T00:00:00Z';EvidenceRecordedUtc='2026-01-01T03:00:00Z';NoWritesDuringAcquisition=$true;QuiescentStartUtc='2026-01-01T01:00:00Z';QuiescentEndUtc='2026-01-01T02:00:00Z';SourceSetComplete=$true;SourceSetQuiescedTogether=$true;SourceSetSha256='';ProfileVersion=2;SourceDiskCount=2;NetworkAdapterCount=1;Generation=2;MemoryStartupBytes=4GB;ProcessorCount=2;SecureBoot='On';SecureBootTemplate='MicrosoftWindows';MacPolicy='New';IdentityPolicy='NewVmId';TpmPolicy='NewLocalProtector';OriginalTpmSecretsRequired=$false;AcceptNewTpmIdentity=$true;BitLockerState='Clear';GuestOS='Windows11';HostWindows11CpuSupported=$true
 Sources=@([pscustomobject]@{Role='Boot';ControllerLocation=0;SourceImageSha256=('a'*64);SerialNumber='fixture0';Size=64GB;LogicalSectorSize=512},[pscustomobject]@{Role='Data';ControllerLocation=1;SourceImageSha256=('b'*64);SerialNumber='fixture1';Size=1GB;LogicalSectorSize=512})}
 $p.SourceSetSha256=Get-RecoverySourceSetHash -Sources $p.Sources;return $p
}
function Reset-Mocks {
 & $m {
  $script:trace=[Collections.Generic.List[string]]::new();$script:paths=@();$script:tpm=$false;$script:state='Off';$script:failTpm=$false
  function script:Get-RecoveryHostState {[pscustomobject]@{VMs=@();MacAddresses=@();ProcessorCount=8;AvailableMemoryBytes=16GB}}
  function script:Get-RecoveryVhdInfo($Path){
   $size=if([IO.Path]::GetFileName($Path) -match '^(data|disk-1)'){1GB}else{64GB}
   [pscustomobject]@{VhdFormat='VHDX';VhdType='Dynamic';ParentPath='';Attached=$false;Size=$size;LogicalSectorSize=512}
  }
  function script:New-RecoveryVM($Name,$Generation,$Memory,$Path){$script:trace.Add('new');[pscustomobject]@{Name=$Name;Id='fixture-new-vm'}}
  function script:Get-RecoveryVmIsolation($VM){[pscustomobject]@{Id=$VM.Id;State=$script:state;Isolated=$true;Generation=2;PhysicalDiskCount=0;DiskPaths=$script:paths;MacAddresses=@()}}
  function script:Set-RecoveryVmHardware($VM,$Profile,$VhdxPath){$script:paths=@($VhdxPath);$script:trace.Add('boot')}
  function script:Add-RecoveryDataDisk($VM,$Path,$Location){$script:paths+=$Path;$script:trace.Add('data'+$Location)}
  function script:Set-RecoveryNewTpm($VM){$script:trace.Add('tpm');if($script:failTpm){throw 'fixture TPM failure'};$script:tpm=$true}
  function script:Get-RecoveryTpmState($VM){[pscustomobject]@{TpmEnabled=$script:tpm}}
  function script:Get-RecoveryV2HardwareState($VM){[pscustomobject]@{SecureBoot='On';SecureBootTemplate='MicrosoftWindows';MemoryStartupBytes=4GB;ProcessorCount=2;DynamicMemoryEnabled=$false;ProcessorCompatibilityEnabled=$false;Disks=@(for($i=0;$i -lt $script:paths.Count;$i++){[pscustomobject]@{Path=$script:paths[$i];ControllerType='SCSI';ControllerNumber=0;ControllerLocation=$i}})}}
  function script:Start-RecoveryVM($VM){$script:trace.Add('start');$script:state='Running'}
 }
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('RecoveryV2Tests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
 $p=Profile
 for($i=0;$i -lt 2;$i++){
  $path=Join-Path $temp $(if($i -eq 0){'boot.vhdx'}else{'data.vhdx'})
  $bytes=New-Object byte[] 4096;$bytes[0]=[byte]($i+1);[IO.File]::WriteAllBytes($path,$bytes)
  $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
  $s=$p.Sources[$i]
  $manifest=[pscustomobject]@{SchemaVersion=1;State='verified';Format='vhdx';Size=4096;VirtualSize=$s.Size;Sha256=$hash;SourceSha256=$s.SourceImageSha256;LogicalSectorSize=512;FullSectorImage=$true;SourceAcquisitionMode='offline-block';Metadata=@{SourceWriteProtected=$true;Source=@{SerialNumber=$s.SerialNumber;Size=$s.Size;LogicalSectorSize=512}};Verification=@{VirtualSize=$true;QemuCheck=$true;LogicalCompare=$true;ReadbackSha256=$true;LogicalSectorSize=$true}}
  $manifest|ConvertTo-Json -Depth 8|Set-Content -LiteralPath ($path+'.manifest.json') -Encoding UTF8
 }
 $boot=Join-Path $temp 'boot.vhdx';$data=Join-Path $temp 'data.vhdx'
 Reset-Mocks
 Assert (Test-RecoveryVmProfile $p).Allowed 'valid v2'
 $plan=Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'plan')
 Assert ($plan.State -eq 'PlanOnly' -and $plan.WorkingCopies.Count -eq 2) 'multidisk plan'
 Assert ((& $m {$script:trace.Count}) -eq 0) 'plan performs no VM changes'
 $result=Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'created') -Create -Confirm:$false
 Assert ($result.State -eq 'VMCreatedOff' -and -not $result.OriginalTpmSecretsRestored -and -not $result.BootTested) 'new tpm no restoration claim'
 Assert (((& $m {$script:trace.ToArray()}) -join ',') -eq 'new,boot,data1,tpm') 'correct wiring no start'
 Assert ($result.WorkingCopies.Count -eq 2 -and (Test-Path $result.WorkingCopies[1])) 'all working copies'
 Reset-Mocks
 $result=Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'started') -Create -StartIsolated -Confirm:$false
 Assert ($result.State -eq 'StartRequestedUnverified' -and ((& $m {$script:trace.ToArray()}) -join ',') -eq 'new,boot,data1,tpm,start') 'start only after full config'
 foreach($change in @(
 {$p.MemoryStartupBytes=2GB},{$p.ProcessorCount=1},{$p.Generation=1},{$p.SecureBoot='Off'},{$p.SecureBootTemplate='Other'},
 {$p.TpmPolicy='None'},{$p.AcceptNewTpmIdentity=$false},{$p.OriginalTpmSecretsRequired=$true},{$p.HostWindows11CpuSupported=$false},
 {$p.Sources[0].Size=32GB},{$p.Sources[1].Role='Boot'},{$p.Sources[1].ControllerLocation=0},
 {$p.Sources[1].SourceImageSha256=$p.Sources[0].SourceImageSha256},{$p.Sources[1].SerialNumber='fixture0'},{$p.Sources[1].LogicalSectorSize=4096},
 {$p.InventoryCollectedUtc='2026-01-02T00:00:00Z'},{$p.EvidenceRecordedUtc='2026-01-01T01:00:00Z'},{$p.NoWritesDuringAcquisition=$false},{$p.QuiescentStartUtc='invalid'},{$p.QuiescentEndUtc='2025-01-01T00:00:00Z'},{$p.SourceSetComplete=$false},{$p.SourceSetQuiescedTogether=$false},{$p.SourceSetSha256=('0'*64)},{$p.SourceDiskCount=3},{$p.BitLockerState='Unknown'},{$p.BitLockerState='Encrypted'},{$p.MacPolicy='Preserve'}
 )){
  $p=Profile;&$change;Assert (-not(Test-RecoveryVmProfile $p).Allowed) 'invalid profile rejected'
 }
 $p=Profile;$p.BitLockerState='Encrypted'
 $p|Add-Member RecoveryKeyStoredSeparately $true;$p|Add-Member RecoveryKeyMatchesSource $true;$p|Add-Member AcceptManualUnlock $true;$p|Add-Member RecoveryUnlockPolicy 'UserConsoleOnly'
 Assert (Test-RecoveryVmProfile $p).Allowed 'encrypted requires manual evidence'
 $p.RecoveryKeyMatchesSource=$false;Assert (-not(Test-RecoveryVmProfile $p).Allowed) 'unmatched key refused'
 $p=Profile
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'missing')}
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($boot) -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'duplicate')}
 Reset-Mocks;& $m {$script:failTpm=$true}
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile $p -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'tpm-failure') -Create -StartIsolated -Confirm:$false}
 Assert (-not ((& $m {$script:trace.ToArray()}) -contains 'start')) 'TPM failure no boot'
 Assert (Test-Path (Join-Path $temp 'tpm-failure\disk-0.vhdx')) 'failure preserved artifacts'
 # Native vTPM wiring: low-level cmdlets are test functions, not Hyper-V.
 Reset-Mocks
 & $m {
  function script:Set-VMKeyProtector {param($VM,[switch]$NewLocalKeyProtector,$ErrorAction)
   if(-not $NewLocalKeyProtector -or $VM.Id -ne 'fixture-new-vm'){throw 'BAD_PROTECTOR_TARGET'}
   $script:trace.Add('native-key-protector')
  }
  function script:Enable-VMTPM {param($VM,$ErrorAction)
   if($VM.Id -ne 'fixture-new-vm'){throw 'BAD_TPM_TARGET'}
   $script:trace.Add('native-enable-tpm')
  }
 }
 & $m {param($native) & $native ([pscustomobject]@{Id='fixture-new-vm'})} $nativeSetTpm
 Assert (((& $m {$script:trace.ToArray()}) -join ',') -eq 'native-key-protector,native-enable-tpm') 'real wrapper uses only newlocal then enable'
 & $m {function script:Get-RecoveryVmIsolation($VM){[pscustomobject]@{Id=$VM.Id;State='Running';Isolated=$true}}}
 Throws {& $m {param($native) & $native ([pscustomobject]@{Id='fixture-new-vm'})} $nativeSetTpm}
 Assert ((& $m {$script:trace.Count}) -eq 2) 'running VM no protector modification'
 Reset-Mocks
 & $m {function script:Get-RecoveryV2HardwareState($VM){[pscustomobject]@{SecureBoot='Off';SecureBootTemplate='';MemoryStartupBytes=4GB;ProcessorCount=2}}}
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile (Profile) -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'hardware-mismatch') -Create -StartIsolated -Confirm:$false}
 Assert (-not ((& $m {$script:trace.ToArray()}) -contains 'start')) 'hardware readback mismatch no boot'
 Reset-Mocks
 $mp=$data+'.manifest.json';$originalManifest=Get-Content $mp -Raw
 $bad=$originalManifest|ConvertFrom-Json;$bad.Metadata.Source.SerialNumber='another-source';$bad|ConvertTo-Json -Depth 8|Set-Content $mp -Encoding UTF8
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile (Profile) -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'wrong-serial') -Create -Confirm:$false}
 Assert ((& $m {$script:trace.Count}) -eq 0) 'all source bindings before any VM change'
 $originalManifest|Set-Content $mp -Encoding UTF8
 $bytes=[IO.File]::ReadAllBytes($data);$bytes[1]=99;[IO.File]::WriteAllBytes($data,$bytes)
 Throws {Invoke-IsolatedVmRecovery -VhdxPath $boot -DataVhdxPaths @($data) -Profile (Profile) -VMName 'Recovery-V2' -VMRoot (Join-Path $temp 'bad-hash') -Create -Confirm:$false}
 Assert ((& $m {$script:trace.Count}) -eq 0) 'all hashes before any VM change'
 Write-Output "PASS RecoveryV2 assertions=$n (synthetic archives, mock Hyper-V only)"
}finally{
 $resolved=[IO.Path]::GetFullPath($temp)
 if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and [IO.Path]::GetFileName($resolved).StartsWith('RecoveryV2Tests_')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
