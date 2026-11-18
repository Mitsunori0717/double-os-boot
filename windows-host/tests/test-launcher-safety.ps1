#requires -Version 5.1
# Helper functions are extracted without running the launcher entry point.
# Disk/VM calls are mocks; real child processes run only temporary harmless scripts.
$ErrorActionPreference='Stop'
$launcher=Join-Path $PSScriptRoot '..\00-field-launcher.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($launcher,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$script:count=0
function Check($value,[string]$message){if(-not $value){throw ('LAUNCHER TEST FAILED: '+$message)};$script:count++}
function Refuses([scriptblock]$action,[string]$message){$failed=$false;try{&$action|Out-Null}catch{$failed=$true};Check $failed $message}
$helpers=@('Get-PassthroughDisks','Get-LauncherSavedDisk','Get-LauncherVerifiedDisk','Get-LauncherVmDisk','Invoke-LauncherChild','Invoke-LauncherCreateVm','Set-LauncherDiskOffline')
foreach($name in $helpers){
    $definition=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -eq $name)
    Check ($definition.Count -eq 1) ('helper present: '+$name)
    Invoke-Expression $definition[0].Extent.Text
}
$nativeChild=(Get-Command Invoke-LauncherChild).ScriptBlock
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()})
foreach($forbidden in @('Remove-VMHardDiskDrive','New-VM','Add-VMHardDiskDrive','New-VMSwitch','New-FieldVmHere','Stop-VM','Remove-VM')){
    Check ($commands -notcontains $forbidden) ('launcher has no bypass/detach command: '+$forbidden)
}
Check (@($commands|Where-Object{$_ -eq 'Set-Disk'}).Count -eq 1) 'only guarded offline function may change disk state'
Check ($commands -notcontains 'Get-Partition') 'system disk validation delegated to shared guard, no C drive assumption'

function Reset-Fixture {
    $script:F=@{
        Disk=[pscustomobject]@{Number=4;UniqueId='disk-id';Size=[uint64]8192;SerialNumber='SERIAL';IsOffline=$false;FriendlyName='fixture'}
        VM=[pscustomobject]@{Id='vm-id';Name='EdgeBox';State='Off'}
        Drives=@([pscustomobject]@{DiskNumber=4});GuardError=$false;OtherOwner=$false;SetCalls=0;ChildCalls=0;ChildExit=0;GuardCalls=@();ExtraDisks=@()
    }
}
function Get-Disk {param($Number,$ErrorAction) @($script:F.Disk)+@($script:F.ExtraDisks)}
function Get-VM {param($Id,$ErrorAction) $script:F.VM}
function Get-VMHardDiskDrive {param($VMName,$ErrorAction) $script:F.Drives}
function Get-EdgeBoxCreateDisk {
    param($DiskNumber,$ExpectedUniqueId='',$ExpectedSize=0,$ExpectedSerialNumber='',$AllowedVmId='')
    $script:F.GuardCalls+=@{Number=$DiskNumber;UniqueId=$ExpectedUniqueId;Size=$ExpectedSize;Serial=$ExpectedSerialNumber;Allowed=$AllowedVmId}
    if($script:F.GuardError -or $script:F.OtherOwner){throw 'fixture shared-guard refusal'}
    if($DiskNumber -ne $script:F.Disk.Number){throw 'fixture changed number'}
    if($ExpectedUniqueId -and $ExpectedUniqueId -cne $script:F.Disk.UniqueId){throw 'fixture changed identity'}
    if($ExpectedSize -and $ExpectedSize -ne $script:F.Disk.Size){throw 'fixture changed size'}
    if($ExpectedSerialNumber -and $ExpectedSerialNumber -cne $script:F.Disk.SerialNumber){throw 'fixture changed serial'}
    if($AllowedVmId -and $AllowedVmId -ne $script:F.VM.Id){throw 'fixture wrong allowed VM'}
    $script:F.Disk
}
function Set-Disk {
    param($Number,$IsOffline,$ErrorAction)
    if($Number -ne $script:F.Disk.Number -or $IsOffline -ne $true){throw 'unexpected disk mutation'}
    $script:F.SetCalls++;$script:F.Disk.IsOffline=$true
}
function Invoke-LauncherChild {
    param($ScriptPath,$Parameters)
    $script:F.ChildCalls++;$script:F.ChildParameters=$Parameters
    return $script:F.ChildExit
}
# Any accidental native bypass fails without reaching the host.
foreach($name in @('New-VM','Remove-VM','Stop-VM','Add-VMHardDiskDrive','Remove-VMHardDiskDrive','New-VMSwitch')){
    Set-Item -Path ('Function:script:'+$name) -Value {throw 'REAL_VM_MUTATION_FORBIDDEN'}
}

Reset-Fixture
$identity=@{SchemaVersion=1;UniqueId='disk-id';Size=8192;SerialNumber='SERIAL'}
$script:F.Disk.Number=8
Check ((Get-LauncherSavedDisk $identity).Number -eq 8) 'saved hardware identity follows disk renumbering'
$script:F.Disk.UniqueId='replacement'
Refuses {Get-LauncherSavedDisk $identity} 'old disk number cannot silently select replacement'
Reset-Fixture;$script:F.ExtraDisks=@($script:F.Disk.PSObject.Copy())
Refuses {Get-LauncherSavedDisk $identity} 'ambiguous saved identity refused'
Reset-Fixture
Refuses {Get-LauncherVmDisk $script:F.VM 5} 'explicit disk mismatch with selected VM refused'
$script:F.Drives+=@([pscustomobject]@{DiskNumber=4})
Refuses {Get-LauncherVmDisk $script:F.VM} 'duplicate VM disk attachments refused without repair'
Reset-Fixture;$snapshot=$script:F.Disk.PSObject.Copy();$script:F.OtherOwner=$true
Refuses {Set-LauncherDiskOffline $snapshot $script:F.VM} 'other VM ownership blocks offline change'
Check ($script:F.SetCalls -eq 0) 'other owner never detached or offlined'
Reset-Fixture;$snapshot=$script:F.Disk.PSObject.Copy();$script:F.Disk.UniqueId='replacement'
Refuses {Set-LauncherDiskOffline $snapshot $script:F.VM} 'changed disk identity blocks offline change'
Check ($script:F.SetCalls -eq 0) 'changed identity causes no mutation'
Reset-Fixture;$script:F.VM.State='Running'
Refuses {Set-LauncherDiskOffline $script:F.Disk $script:F.VM} 'running VM cannot trigger disk offline mutation'
Check ($script:F.SetCalls -eq 0) 'running VM causes no mutation'
Reset-Fixture;$snapshot=$script:F.Disk.PSObject.Copy()
$result=Set-LauncherDiskOffline $snapshot $script:F.VM
Check ($result.IsOffline -and $script:F.SetCalls -eq 1) 'validated idle disk offlined once and read back'
Check ($script:F.GuardCalls[-1].Allowed -eq 'vm-id' -and $script:F.GuardCalls[-1].UniqueId -eq 'disk-id') 'readback remains bound to target VM and physical identity'

$createScript=Join-Path $PSScriptRoot '..\01-create-field-vm.ps1'
Reset-Fixture;$script:F.ChildExit=23
Refuses {Invoke-LauncherCreateVm $script:F.Disk 'EdgeBox' $createScript 8 6 'External' ''} '01 refusal propagates without alternate creation'
Check ($script:F.ChildCalls -eq 1 -and $script:F.SetCalls -eq 0) '01 failure has one child call and no launcher offline mutation'
Check ($script:F.ChildParameters.ExpectedUniqueId -eq 'disk-id' -and $script:F.ChildParameters.ExpectedSize -eq 8192 -and $script:F.ChildParameters.ExpectedSerialNumber -eq 'SERIAL') '01 receives full selected physical identity'
Reset-Fixture
Refuses {Invoke-LauncherCreateVm $script:F.Disk 'EdgeBox' ($createScript+'.missing') 8 6 '' ''} 'missing 01 does not fall back'
Check ($script:F.ChildCalls -eq 0 -and $script:F.SetCalls -eq 0) 'missing 01 performs no child or disk mutation'
Reset-Fixture;$script:F.GuardError=$true
Refuses {Invoke-LauncherCreateVm $script:F.Disk 'EdgeBox' $createScript 8 6 '' ''} 'fresh shared guard refusal precedes create child'
Check ($script:F.ChildCalls -eq 0) 'guard refusal cannot be bypassed by child creation'
Reset-Fixture
Check ((Invoke-LauncherCreateVm $script:F.Disk 'EdgeBox' $createScript 8 6 '' '').Id -eq 'vm-id') 'successful child result requires matching VM attachment'

$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxLauncherTests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try{
    # Exercise the real entry workflow with a fixture script directory and
    # return instead of exit-with-success, allowing counter inspection.
    $workflowAst=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
    $workflow=[scriptblock]::Create($workflowAst.Extent.Text.Replace('exit 0','return').Replace('$PSScriptRoot','$script:fixtureDirectory'))
    $script:fixtureDirectory=$temp
    function Run-WorkflowFixture([bool]$ReadOnly,[int]$SelectedDisk=-1){
        function Import-Module {param($Name,[switch]$Force,$ErrorAction)}
        function Step($Text){}
        function Ok($Text){}
        function Info($Text){}
        function Warn($Text){}
        function Fail($Text){throw $Text}
        function Confirm-Step($Text){return $true}
        $VMName='EdgeBox';$DiskNumber=$SelectedDisk;$Status=$ReadOnly;$NoConfirm=$true
        $MemoryGB=8;$CpuCount=6;$SwitchName='';$NetAdapterName=''
        $DiskConf=Join-Path $script:fixtureDirectory 'field-disk.conf'
        $identityPath=Join-Path $script:fixtureDirectory 'field-disk.identity.json'
        $Script01=$createScript;$Script02='must-not-run.ps1'
        & $workflow
    }
    Reset-Fixture
    Run-WorkflowFixture $true
    Check ($script:F.SetCalls -eq 0 -and $script:F.ChildCalls -eq 0) 'Status workflow performs no disk or child action'
    Check (-not(Test-Path -LiteralPath (Join-Path $temp 'field-disk.conf')) -and -not(Test-Path -LiteralPath (Join-Path $temp 'field-disk.identity.json'))) 'Status workflow writes no number or identity file'
    Reset-Fixture;$script:F.VM=$null;$script:F.ChildExit=23
    Refuses {Run-WorkflowFixture $false 4} 'full workflow stops after child refusal'
    Check ($script:F.ChildCalls -eq 1 -and $script:F.SetCalls -eq 0 -and -not(Test-Path -LiteralPath (Join-Path $temp 'field-disk.conf'))) 'failed create workflow never changes disk or persists selected number'

    $fixture=Join-Path $temp 'child fixture.ps1';$output=Join-Path $temp 'arguments.json'
    $fixtureText=@'
param([string]$VMName,[uint64]$ExpectedSize,[switch]$NoConfirm,[string]$OutputPath)
@{VMName=$VMName;ExpectedSize=$ExpectedSize;NoConfirm=[bool]$NoConfirm}|ConvertTo-Json|Set-Content -LiteralPath $OutputPath -Encoding UTF8
exit 0
'@
    [IO.File]::WriteAllText($fixture,$fixtureText,[Text.UTF8Encoding]::new($true))
    $name='Edge Box "quoted" ''single''; $(throw ''not code'') 日本語'
    $result=&$nativeChild $fixture @{VMName=$name;ExpectedSize=[uint64]500000000000;NoConfirm=$true;OutputPath=$output}
    $received=Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json
    Check ($result -eq 0 -and $received.VMName -ceq $name -and $received.ExpectedSize -eq 500000000000 -and $received.NoConfirm) 'real harmless child preserves quotes/unicode/UInt64/switch values as data'
    [IO.File]::WriteAllText($fixture,'exit 23',[Text.UTF8Encoding]::new($true))
    Check ((&$nativeChild $fixture @{}) -eq 23) 'real harmless child exit code preserved'
}finally{
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxLauncherTests_[0-9a-f]{32}$'){throw 'UNSAFE_TEST_CLEANUP'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output ('PASS launcher safety assertions='+$script:count+'; mock disk/VM operations and harmless child processes only')
