#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxCpuBoot_' + [guid]::NewGuid().ToString('N'))
$cpu = Join-Path $fixture 'windows-cpu-partition'
$hostDir = Join-Path $fixture 'windows-host'
$config = Join-Path $cpu 'cpu-partition.json'
function Check($Condition,$Message) { if (-not $Condition) { throw $Message } }
try {
    [void][IO.Directory]::CreateDirectory($cpu)
    [void][IO.Directory]::CreateDirectory($hostDir)
    Copy-Item (Join-Path $root 'windows-host/cpu-boot.psm1') $hostDir
    Import-Module (Join-Path $hostDir 'cpu-boot.psm1') -Force
    $name = "Edge Box O'Brien"
    Check (-not (Invoke-EdgeBoxCpuPreparation $name)) 'absent CPU plan should skip'
    $scriptPath = Join-Path $cpu 'cpu-partition.ps1'
    @'
param($VMName,[switch]$BootApply,[switch]$PrepareOnly,[switch]$Quiet)
if (-not ($PrepareOnly -and $BootApply -and $Quiet -and $VMName -ceq "Edge Box O'Brien")) { exit 22 }
exit 0
'@ | Set-Content $scriptPath -Encoding UTF8
    @{VMName=$name;Mode='full'} | ConvertTo-Json | Set-Content $config -Encoding UTF8
    Check (-not (Invoke-EdgeBoxCpuPreparation 'different VM')) 'plan for another VM should skip'
    Check (Invoke-EdgeBoxCpuPreparation $name) 'same VM should run successfully in prepare-only mode'
    'exit 17' | Set-Content $scriptPath -Encoding UTF8
    $errorSeen = $false
    try { Invoke-EdgeBoxCpuPreparation $name } catch { $errorSeen = $_.Exception.Message -like '*exit 17*' }
    Check $errorSeen 'start must stop after a failed child process'

    # Use real table parsing and binding functions with synthetic Hyper-V responses.
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'windows-cpu-partition/cpu-partition.ps1'),[ref]$null,[ref]$null)
    foreach ($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -in @('Get-VmGroupId','Get-GuidsInText','Get-FullGroupState','Get-FullPlanVM','Invoke-FullBind','Invoke-FullStage2')},$false)) {
        # Extracted functions have no source path; keep optional I/O work inside the empty fixture.
        $definition=$f.Extent.Text.Replace('$PSScriptRoot','$cpu')
        . ([scriptblock]::Create($definition))
    }
    $GroupId = 'b0edb0ed-c01e-4a11-8000-0000000000e1'
    $NullGroupId = [guid]::Empty.ToString()
    $id = [guid]::NewGuid()
    $other = [guid]::NewGuid()
    $VMName = $name
    $vm = [pscustomobject]@{Name=$VMName;Id=$id;State='Running'}
    function Get-VM { $script:vm }
    function ConvertTo-LpRangeText { '1' }
    function Invoke-CpuGroups { [pscustomobject]@{ Ok=$true;Output=$script:table } }
    $table = "$name $id $GroupId" + [Environment]::NewLine + "Other $other $NullGroupId"
    Check ((Get-VmGroupId 'fixture' $name) -eq $GroupId) 'match table row to VM ID'
    $table = "Other $other $GroupId"
    Check (-not (Invoke-FullBind 'fixture' @(1) $vm).Bound) 'existing group alone cannot confirm VM binding'

    # Stateful executable mock uses Microsoft's documented comma-separated table.
    function Reset-GroupFixture {
        $script:vm = [pscustomobject]@{Name=$name;Id=$id;State='Off'}
        $script:cg = @{ Exists=$true;Lps=@(1,2);Current=$GroupId;OtherMember=$false;Malformed=$false;
            QueryFails=$false;FilteredFails=$false;WrongCreated=$false;FailCommand='';Mutations=@();ReplaceAfterBind=$false }
    }
    function Invoke-CpuGroups([string]$Exe,[string[]]$CgArgs) {
        $cmd = $CgArgs[0]
        $result = [pscustomobject]@{Ok=$true;Output=''}
        switch ($cmd) {
            'GetVmGroup' { $result.Output = "VmName VmId CpuGroupId`n$name $id $($cg.Current)" }
            'GetGroups' {
                if ($cg.QueryFails -or ($cg.FilteredFails -and $CgArgs.Count -gt 1)) { $result.Ok=$false;break }
                $result.Output = "CpuGroupId CpuCap LpIndexes`n------------------------------------ ------ ---------"
                if ($cg.Exists) { $result.Output += "`n$GroupId 65536 " + ($cg.Lps -join ',') }
                if ($cg.Malformed) { $result.Output = "CpuGroupId CpuCap LpIndexes`n$GroupId 65536 unknown" }
            }
            'GetGroupVms' {
                $result.Output = "CpuGroupId VmName VmId`n------------------------------------ ------ ------------------------------------"
                if ($cg.Current -eq $GroupId) { $result.Output += "`n$GroupId $name $id" }
                if ($cg.OtherMember) { $result.Output += "`n$GroupId Other $other" }
            }
            default {
                $cg.Mutations += $cmd
                if ($cmd -eq $cg.FailCommand) { $result.Ok=$false;$result.Output='fixture failure';break }
                switch ($cmd) {
                    'SetVmGroup' {
                        $cg.Current = ($CgArgs | Where-Object { $_ -like '/GroupId:*' }) -replace '^/GroupId:',''
                        if ($cg.ReplaceAfterBind) { $script:vm = [pscustomobject]@{Name=$name;Id=$other;State='Off'} }
                    }
                    'DeleteGroup' { $cg.Exists=$false }
                    'CreateGroup' {
                        $cg.Exists=$true
                        $cg.Lps=@((($CgArgs | Where-Object { $_ -like '/GroupAffinity:*' }) -replace '^/GroupAffinity:','') -split ',' | ForEach-Object { [int]$_ })
                        if ($cg.WrongCreated) { $cg.Lps=@(9) }
                    }
                    default { throw "Unexpected CpuGroups command $cmd" }
                }
            }
        }
        return $result
    }
    Reset-GroupFixture
    $vm.State='Running'
    Check (Invoke-FullBind 'fixture' @(2,1) $vm).Bound 'official table accepts the same LP set in any order'
    Check ($cg.Mutations.Count -eq 0) 'matching running group must stay untouched'
    Check (-not (Invoke-FullBind 'fixture' @(1,3) $vm).Bound) 'same ID with different running affinity must fail'
    Check ($cg.Mutations.Count -eq 0) 'running affinity mismatch must not mutate any group'
    Reset-GroupFixture
    Check (Invoke-FullBind 'fixture' @(1,2) $vm).Bound 'matching stopped group remains valid'
    Check ($cg.Mutations.Count -eq 0) 'matching stopped group must not be recreated'
    Reset-GroupFixture
    Check (Invoke-FullBind 'fixture' @(1,3) $vm).Bound 'stopped exclusively owned group can be repaired'
    Check (($cg.Mutations -join ',') -eq 'SetVmGroup,DeleteGroup,CreateGroup,SetVmGroup') 'repair must detach, recreate, then bind'
    Check (($cg.Lps -join ',') -eq '1,3') 'repair must use planned LP indexes'
    Reset-GroupFixture
    $cg.OtherMember=$true
    Check (-not (Invoke-FullBind 'fixture' @(1,3) $vm).Bound) 'shared group affinity must not be changed'
    Check ($cg.Mutations.Count -eq 0) 'shared group rejection must precede any mutation'
    foreach ($flag in @('Malformed','QueryFails')) {
        Reset-GroupFixture
        $cg[$flag]=$true
        Check (-not (Invoke-FullBind 'fixture' @(1,2) $vm).Bound) "unverified LP query must fail: $flag"
        Check ($cg.Mutations.Count -eq 0) "unverified query must not mutate: $flag"
    }
    Reset-GroupFixture
    $cg.Exists=$false;$cg.Current=$NullGroupId;$cg.FilteredFails=$true
    Check (Invoke-FullBind 'fixture' @(1,3) $vm).Bound 'confirmed absence via all-groups table permits boot creation'
    foreach ($command in @('SetVmGroup','DeleteGroup','CreateGroup')) {
        Reset-GroupFixture
        $cg.FailCommand=$command
        Check (-not (Invoke-FullBind 'fixture' @(1,3) $vm).Bound) "failed repair command must not report bound: $command"
        Check ($cg.Mutations[-1] -eq $command) "failed repair must not continue: $command"
    }
    Reset-GroupFixture
    $cg.WrongCreated=$true
    Check (-not (Invoke-FullBind 'fixture' @(1,3) $vm).Bound) 'creation readback must match planned affinity'
    Check ($cg.Current -eq $NullGroupId) 'unverified created group must not be attached'
    Reset-GroupFixture
    $cg.Current=$NullGroupId;$cg.ReplaceAfterBind=$true
    Check (-not (Invoke-FullBind 'fixture' @(1,2) $vm).Bound) 'same-name replacement cannot prove original VM binding'

    # Execute the actual stage-two orchestration; all host mutation boundaries are mocked.
    function Get-CpuTopology { [pscustomobject]@{SmtPerCore=1} }
    function Get-HvSchedulerType { 'core' }
    function Write-PinLog { }
    function Say { }
    function Write-FullStatus($H) { $script:fullStatus=$H }
    function Get-SavedConfig { $script:savedConfig }
    function Save-Config($Obj) { $script:savedConfig=$Obj }
    function Unregister-ScheduledTask { }
    function Stop-WatchTask { }
    function Find-CpuGroupsExe { 'fixture' }
    function Get-VMProcessor { [pscustomobject]@{Count=2} }
    function Set-VMProcessor { throw 'Unexpected processor mutation' }
    function Start-VM($VM) { $script:started += [string]$VM.Id }
    function Invoke-FullBind {
        $script:bindCalls++
        [pscustomobject]@{Bound=($script:bindOk -and ($script:bindCalls -lt $script:failAt));Message='fixture binding result'}
    }
    $Scheduler='core';$NoReserve=$true;$PrepareOnly=$false;$AllowMissingVM=$false
    $hostLps=@(0..([Environment]::ProcessorCount-1))
    function Reset-StageFixture {
        Reset-GroupFixture
        $script:savedConfig=[pscustomobject]@{Mode='full';VMName=$name;VMId=[string]$id;ManageVmStart=$true}
        $script:started=@();$script:bindCalls=0;$script:bindOk=$true;$script:failAt=[int]::MaxValue
    }
    Reset-StageFixture
    $bindOk=$false
    Check (-not (Invoke-FullStage2 $hostLps @(1,2) $false)) 'unverified binding must fail preparation'
    Check ($started.Count -eq 0) 'managed VM must not start after unverified binding'
    Check (-not $fullStatus.Bound) 'failure must be visible in full status'
    Reset-StageFixture
    $failAt=2
    Check (-not (Invoke-FullStage2 $hostLps @(1,2) $false)) 'binding lost just before start must fail'
    Check ($started.Count -eq 0 -and -not $savedConfig.GroupBound) 'lost binding must block start and clear success status'
    Reset-StageFixture
    Check (Invoke-FullStage2 $hostLps @(1,2) $false) 'verified binding permits managed start'
    Check ($started.Count -eq 1 -and $started[0] -eq [string]$id) 'managed start must use verified original VM exactly once'
    Reset-StageFixture
    $PrepareOnly=$true
    Check (Invoke-FullStage2 $hostLps @(1,2) $false) 'prepare-only verifies the plan'
    Check ($started.Count -eq 0) 'prepare-only must leave starting to the caller'
    $PrepareOnly=$false
    Reset-StageFixture
    $vm=$null;$AllowMissingVM=$true;$savedConfig=$null
    Check (-not (Invoke-FullStage2 $hostLps @(1,2) $true)) 'allow-missing preconfiguration must return pending, not throw'
    Check ($fullStatus.PendingVM -and $started.Count -eq 0 -and $bindCalls -eq 0) 'missing VM must not bind or start'
    # The production full-mode save block must still persist a plan when stage two is pending.
    $saveBranch=$ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
        $n.Clauses[0].Item1.Extent.Text -eq '-not $cfgF -or $cfgF.Mode -ne "full"'},$false)[0]
    Check ($null -ne $saveBranch) 'locate production preconfiguration save branch'
    $cfgF=$null;$plan=[pscustomobject]@{HostLps=$hostLps;GuestLps=@(1,2)};$bound=$false
    . ([scriptblock]::Create($saveBranch.Extent.Text))
    Check ($savedConfig.PendingVM -and -not $savedConfig.VMId -and $savedConfig.Mode -eq 'full') 'preconfiguration must persist a pending plan without inventing a VM ID'
    $AllowMissingVM=$false
    $missingRejected=$false
    try { Invoke-FullStage2 $hostLps @(1,2) $false | Out-Null } catch { $missingRejected=$true }
    Check $missingRejected 'missing VM without explicit allowance must still fail'
    Reset-StageFixture
    $savedConfig.VMId=[string]$other
    $identityRejected=$false
    try { Invoke-FullStage2 $hostLps @(1,2) $false | Out-Null } catch { $identityRejected=$true }
    Check ($identityRejected -and $started.Count -eq 0 -and $bindCalls -eq 0) 'saved VM ID mismatch must fail before binding or starting'

    Import-Module (Join-Path $root 'windows-cpu-partition/cpu-tool.psm1') -Force
    $invalid = $false
    try { Assert-EdgeBoxCpuTool $scriptPath } catch { $invalid=$true }
    Check $invalid 'unsigned fixture must not pass tool validation'
    Write-Host 'PASS: CPU preparation, child status, verified LP affinity, safe group repair, managed start gating, missing VM preconfiguration, signature rejection'
} finally {
    Remove-Module cpu-boot -ErrorAction SilentlyContinue
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($fixture).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $fixture -Leaf) -match '^EdgeBoxCpuBoot_[a-f0-9]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
