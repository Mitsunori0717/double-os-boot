#requires -Version 5.1
# Extract production functions; no entry point, physical device or live VM runs.
$ErrorActionPreference='Stop'
$hostDirectory=Split-Path $PSScriptRoot -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDirectory '02-start-field-vm.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -in @('Get-PassthroughDisks','Test-DiskReady'))
$module=Import-Module (Join-Path $hostDirectory 'vm-create-safety.psm1') -Force -PassThru
try{
    & $module {
        param($Definitions)
        foreach($definition in $Definitions){Invoke-Expression $definition.Extent.Text}
        $script:Assertions=0
        function Check($condition,$message){if(-not $condition){throw ('START TEST FAILED: '+$message)};$script:Assertions++}
        function Refuses([scriptblock]$action,$message){$failed=$false;try{&$action|Out-Null}catch{$failed=$true};Check $failed $message}
        function Reset-Fixture {
            $script:vm=[pscustomobject]@{Name='EdgeBox';Id='selected';State='Off'}
            $script:other=[pscustomobject]@{Name='Other';Id='other';State='Off'}
            $script:Vms=@($script:vm)
            $script:Disk=[pscustomobject]@{Number=7;UniqueId='original';Size=[uint64]8192;SerialNumber='serial';IsBoot=$false;IsSystem=$false;IsOffline=$false}
            $script:Drives=@{selected=@([pscustomobject]@{Id='main';VMId='selected';DiskNumber=7});other=@()}
            $script:Partitions=@();$script:SystemNumber=0;$script:QueryFailure=''
            $script:DetachOthers=$false;$script:OfflineCalls=0;$script:Removed=@();$script:DiskQueries=0
            $script:ChangeDisk=$false;$script:NoOfflineEffect=$false;$script:OwnerStarts=$false
        }
        function Get-Disk {
            if($script:QueryFailure -eq 'disk'){throw 'disk query denied'}
            $script:DiskQueries++
            if($script:ChangeDisk -and $script:DiskQueries -gt 1){$script:Disk.UniqueId='replacement'}
            $script:Disk
        }
        function Get-Partition {
            param($DriveLetter,$DiskNumber)
            if($script:QueryFailure -eq 'partition'){throw 'partition query denied'}
            if($DriveLetter){[pscustomobject]@{DiskNumber=$script:SystemNumber}}else{$script:Partitions}
        }
        function Get-VM {
            param($Id)
            if($script:QueryFailure -eq 'vm'){throw 'VM query denied'}
            if($Id){
                if($Id -eq 'other' -and $script:OwnerStarts){$script:other.State='Running'}
                @($script:Vms|Where-Object Id -eq $Id)
            }else{$script:Vms}
        }
        function Get-VMHardDiskDrive {
            param($VM,$VMName)
            if($script:QueryFailure -eq 'attachment'){throw 'attachment query denied'}
            $owner=if($VM){$VM}else{@($script:Vms|Where-Object Name -eq $VMName)[0]}
            $script:Drives[[string]$owner.Id]
        }
        function Remove-VMHardDiskDrive {
            [CmdletBinding()]param($VMHardDiskDrive)
            $script:Removed+=([string]$VMHardDiskDrive.Id)
            $script:Drives[[string]$VMHardDiskDrive.VMId]=@($script:Drives[[string]$VMHardDiskDrive.VMId]|Where-Object Id -ne $VMHardDiskDrive.Id)
        }
        function Set-Disk {
            param($Number,$IsOffline)
            Check ($Number -eq 7 -and $IsOffline -eq $true) 'only selected disk may be offlined'
            $script:OfflineCalls++
            if(-not $script:NoOfflineEffect){$script:Disk.IsOffline=$true}
        }
        function Start-VM {throw 'LIVE_START_FORBIDDEN'}
        function Stop-VM {throw 'LIVE_STOP_FORBIDDEN'}
        function Remove-VM {throw 'LIVE_VM_REMOVE_FORBIDDEN'}

        foreach($failure in @('disk','partition','vm','attachment')){
            Reset-Fixture;$script:QueryFailure=$failure
            Refuses {Test-DiskReady -Fix} ('query failure closes repair: '+$failure)
            Check ($script:OfflineCalls -eq 0 -and $script:Removed.Count -eq 0) 'unreadable state causes no repair mutation'
        }
        foreach($system in @('boot','system','current')){
            Reset-Fixture
            if($system -eq 'boot'){$script:Disk.IsBoot=$true}
            if($system -eq 'system'){$script:Disk.IsSystem=$true}
            if($system -eq 'current'){$script:SystemNumber=7}
            Refuses {Test-DiskReady -Fix} ('host disk rejected: '+$system)
            Check ($script:OfflineCalls -eq 0 -and $script:Removed.Count -eq 0) 'host disk never changed'
        }
        foreach($partition in @(@{DriveLetter='D';AccessPaths=@()},@{DriveLetter='';AccessPaths=@('D:\Mounted\')})){
            Reset-Fixture;$script:Partitions=@([pscustomobject]$partition)
            Refuses {Test-DiskReady -Fix} 'mounted data disk rejected'
            Check ($script:OfflineCalls -eq 0) 'mounted data disk never offlined'
        }
        Reset-Fixture;$script:vm.State='Running'
        Refuses {Test-DiskReady -Fix} 'running selected VM cannot be repaired'
        Reset-Fixture;$script:Vms+=$script:other;$script:Drives.other=@([pscustomobject]@{Id='foreign';VMId='other';DiskNumber=7})
        Check (@(Test-DiskReady -Fix).Count -gt 0) 'other owner without DetachOthers remains blocked'
        Check ($script:OfflineCalls -eq 0 -and $script:Removed.Count -eq 0) 'blocked ownership prevents even offline mutation'
        $script:DetachOthers=$true;$script:other.State='Running'
        Check (@(Test-DiskReady -Fix).Count -gt 0) 'running other owner remains blocked even with DetachOthers'
        Check ($script:OfflineCalls -eq 0 -and $script:Removed.Count -eq 0) 'running other VM remains untouched'
        $script:other.State='Off';$script:OwnerStarts=$true
        Refuses {Test-DiskReady -Fix} 'owner starting after plan blocks detach'
        Check ($script:Removed.Count -eq 0 -and $script:OfflineCalls -eq 0) 'owner state rechecked before mutation'
        Reset-Fixture;$script:ChangeDisk=$true
        Refuses {Test-DiskReady -Fix} 'replaced disk at same number blocked'
        Check ($script:OfflineCalls -eq 0) 'disk identity rechecked before offline'
        Reset-Fixture;$script:NoOfflineEffect=$true
        Refuses {Test-DiskReady -Fix} 'offline operation must be confirmed by readback'
        Reset-Fixture
        $null=Test-DiskReady -Fix
        Check ($script:OfflineCalls -eq 1 -and @(Test-DiskReady).Count -eq 0) 'valid idle disk still repaired'
        Reset-Fixture;$script:DetachOthers=$true;$script:Vms+=$script:other
        $script:Drives.selected+=([pscustomobject]@{Id='duplicate';VMId='selected';DiskNumber=7})
        $script:Drives.other=@([pscustomobject]@{Id='foreign';VMId='other';DiskNumber=7})
        Check (@(Test-DiskReady).Count -ge 3) 'read-only diagnosis reports duplicate/other owner/online state'
        Check ($script:OfflineCalls -eq 0 -and $script:Removed.Count -eq 0) 'diagnosis never repairs'
        $null=Test-DiskReady -Fix
        Check (($script:Removed -join ',') -eq 'duplicate,foreign' -and $script:OfflineCalls -eq 1) 'explicit repair retains one selected attachment and detaches only planned stopped owners'
        Check (@(Test-DiskReady).Count -eq 0) 'successful repair passes independent diagnostic readback'
        Write-Output ('PASS start/repair safety assertions='+$script:Assertions+'; mocked devices and VMs only')
    } $definitions
}finally{Remove-Module $module -Force}

$shutdown=Import-Module (Join-Path $hostDirectory 'vm-shutdown.psm1') -Force -PassThru
try{
    & $shutdown {
        $script:Scenario='renamed';$script:StopCalls=0;$script:Queries=@()
        function Get-VM {
            param($Id)
            $script:Queries+=([string]$Id)
            if(-not $Id){return [pscustomobject]@{Name='EdgeBox';Id='original';State='Running'}}
            if($script:Scenario -eq 'replacement'){return [pscustomobject]@{Name='EdgeBox';Id='replacement';State='Off'}}
            return [pscustomobject]@{Name='Renamed';Id='original';State='Off'}
        }
        function Stop-VM {
            [CmdletBinding()]param($VM,[switch]$AsJob,[switch]$Confirm)
            if($VM.Id -ne 'original' -or -not $AsJob){throw 'shutdown must bind the selected VM object and remain asynchronous'}
            $script:StopCalls++;[pscustomobject]@{State='Completed'}
        }
        function Remove-Job {}
        function Stop-Job {}
        Wait-EdgeBoxShutdown -VMName EdgeBox -ExpectedVmId original -Log {}
        if($script:StopCalls -ne 1 -or $script:Queries[-1] -ne 'original'){throw 'rename must not change shutdown target'}
        $script:Scenario='replacement';$failed=$false
        try{Wait-EdgeBoxShutdown -VMName EdgeBox -Log {}}catch{$failed=$true}
        if(-not $failed){throw 'replacement VM Off must not confirm original shutdown'}
        $script:StopCalls=0;$failed=$false
        try{Wait-EdgeBoxShutdown -VMName EdgeBox -ExpectedVmId another -Log {}}catch{$failed=$true}
        if(-not $failed -or $script:StopCalls -ne 0){throw 'changed initial VM identity must stop before shutdown request'}
        Write-Output 'PASS shutdown identity retention across rename/replacement; mocked VMs only'
    }
}finally{Remove-Module $shutdown -Force}

# Run the production start branch with CPU preparation substituted. Its failure
# must stop before Start-VM; successful preparation must start the selected ID once.
$startBranch=@($ast.EndBlock.Statements|Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and
    $_.Clauses[0].Item1.Extent.Text.Contains('$vm.State -ne "Running"')
})
if($startBranch.Count -ne 1){throw 'start workflow could not be identified'}
$body=$startBranch[0].Clauses[0].Item2.Extent.Text
$body=$body.Substring(1,$body.Length-2).Replace('$PSScriptRoot',"'C:\fixture'")
& {
    param($StartBody)
    $vm=[pscustomobject]@{Name='EdgeBox';Id='selected';State='Off'};$VMName='EdgeBox'
    $script:StartCalls=0;$script:CpuFails=$true
    function Test-DiskReady {return @()}
    function Test-Path {return $false}
    function Invoke-CpuPartitionBoot {if($script:CpuFails){throw 'fixture CPU preparation failed'};return $true}
    function Start-VM {param($VM) if($VM.Id -ne 'selected'){throw 'wrong start target'};$script:StartCalls++}
    $run=[scriptblock]::Create($StartBody)
    $failed=$false;try{. $run}catch{$failed=$true}
    if(-not $failed -or $script:StartCalls -ne 0){throw 'CPU preparation failure must block Start-VM'}
    $script:CpuFails=$false
    . $run
    if($script:StartCalls -ne 1){throw 'successful CPU preparation must lead to exactly one start'}
    Write-Output 'PASS production start waits for CPU preparation and starts selected VM exactly once; mocks only'
} $body
