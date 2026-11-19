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
    Copy-Item (Join-Path $root 'windows-cpu-partition/cpu-tool.psm1') $cpu
    $cpuModule = Import-Module (Join-Path $cpu 'cpu-tool.psm1') -PassThru -Force
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
                $n.Name -in @('Get-VmGroupId','Get-GuidsInText','Get-FullGroupState','Get-FullPlanVM','Invoke-FullBind','Invoke-FullStage2',
                    'ConvertTo-LpArray','Resolve-Plan','Assert-FullPlanTarget','Save-FullPlan','Start-AfterMemoryChange')},$false)) {
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
    function Get-EdgeBoxCpuHostBootId { $script:bootId }
    function Write-PinLog { }
    function Say { }
    function Write-FullStatus($H) { $script:fullStatus=$H }
    function Get-SavedConfig { $script:savedConfig }
    function Save-Config($Obj) { $script:savedConfig=$Obj }
    function Unregister-ScheduledTask { }
    function Stop-WatchTask { }
    function Find-CpuGroupsExe { 'fixture' }
    function Get-VMProcessor { [pscustomobject]@{Count=$script:processorCount} }
    function Set-VMProcessor { throw 'Unexpected processor mutation' }
    function Start-VM($VM) {
        if ($script:startFails) { throw 'simulated start failure' }
        $script:started += [string]$VM.Id
        $script:vm.State='Running'
    }
    function Invoke-FullBind {
        $script:bindCalls++
        [pscustomobject]@{Bound=($script:bindOk -and ($script:bindCalls -lt $script:failAt));Message='fixture binding result'}
    }
    $Scheduler='core';$NoReserve=$true;$PrepareOnly=$false;$AllowMissingVM=$false
    $hostLps=@(0..([Environment]::ProcessorCount-1))
    $guestLps=@($hostLps.Count,($hostLps.Count+1))
    function Reset-StageFixture {
        Reset-GroupFixture
        $script:vm | Add-Member NoteProperty AutomaticStartAction 'Nothing'
        $script:processorCount=2
        $script:bootId='fixture-boot';$script:startFails=$false
        $script:savedConfig=[pscustomobject]@{Mode='full';VMName=$name;VMId=[string]$id;ManageVmStart=$true}
        $script:started=@();$script:bindCalls=0;$script:bindOk=$true;$script:failAt=[int]::MaxValue
    }
    Reset-StageFixture
    $overlapRejected=$false
    try { Invoke-FullStage2 $hostLps @(0,1) $false | Out-Null } catch { $overlapRejected=$true }
    Check ($overlapRejected -and -not $bindCalls -and -not $started.Count) 'overlapping saved plan must never be applied'
    $bindOk=$false
    Check (-not (Invoke-FullStage2 $hostLps $guestLps $false)) 'unverified binding must fail preparation'
    Check ($started.Count -eq 0) 'managed VM must not start after unverified binding'
    Check (-not $fullStatus.Bound) 'failure must be visible in full status'
    Reset-StageFixture
    $processorCount=3
    Check (-not (Invoke-FullStage2 $hostLps $guestLps $false)) 'an unsuccessful vCPU repair must fail'
    Check (-not $started.Count -and -not $bindCalls -and -not $fullStatus.Bound) 'a mismatched vCPU count must not start or bind'
    Reset-StageFixture
    $failAt=2
    Check (-not (Invoke-FullStage2 $hostLps $guestLps $false)) 'binding lost just before start must fail'
    Check ($started.Count -eq 0 -and -not $savedConfig.GroupBound) 'lost binding must block start and clear success status'
    Reset-StageFixture
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'verified binding permits managed start'
    Check ($started.Count -eq 1 -and $started[0] -eq [string]$id) 'managed start must use verified original VM exactly once'
    $vm.State='Off'
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'periodic validation must still work after manual shutdown'
    Check ($started.Count -eq 1 -and $vm.State -eq 'Off') 'periodic validation must respect an intentional shutdown during the same boot'
    $bootId='next-boot'
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'next host boot may start the VM again'
    Check ($started.Count -eq 2 -and $vm.State -eq 'Running') 'next host boot must start the verified VM'
    Reset-StageFixture
    $startFails=$true
    $failed=$false
    try { Invoke-FullStage2 $hostLps $guestLps $false | Out-Null } catch { $failed=$true }
    Check ($failed -and -not $savedConfig.LastVmStartBootId) 'failed startup must remain eligible for retry'
    $startFails=$false
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'successful retry may start the VM'
    Check ($started.Count -eq 1 -and $savedConfig.LastVmStartBootId -eq $bootId) 'success must record only the current boot'
    Reset-StageFixture
    $vm.State='Running'
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'an already-running VM must be recognized'
    $vm.State='Off'
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'an externally started VM may remain off after manual shutdown'
    Check ($started.Count -eq 0) 'observed Running state must also suppress repeated starts'
    Reset-StageFixture
    $savedConfig | Add-Member NoteProperty ManualStopBootId $bootId
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'an explicit stop before the first timer must still allow validation'
    Check ($started.Count -eq 0) 'explicit stop before the first timer must suppress the first start'
    $bootId='next-boot'
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'explicit stop must expire on next host boot'
    Check ($started.Count -eq 1) 'the first start of the next boot must still run'
    Reset-StageFixture
    $PrepareOnly=$true
    Check (Invoke-FullStage2 $hostLps $guestLps $false) 'prepare-only verifies the plan'
    Check ($started.Count -eq 0 -and -not $savedConfig.LastVmStartBootId) 'prepare-only must leave starting to the caller and keep first start eligible'
    $PrepareOnly=$false
    Reset-StageFixture
    $savedConfig | Add-Member NoteProperty HostLps $hostLps
    $savedConfig | Add-Member NoteProperty GuestLps $guestLps
    $bindOk=$false
    $rejected=$false
    try { Start-AfterMemoryChange $vm } catch { $rejected=$true }
    Check ($rejected -and -not $started.Count) 'memory restart must also stop on failed CPU preparation'
    $bindOk=$true
    Start-AfterMemoryChange $vm
    Check ($started.Count -eq 1 -and $started[0] -eq [string]$id) 'successful memory restart must start the verified VM exactly once'
    Reset-StageFixture
    $vm=$null;$AllowMissingVM=$true;$savedConfig=$null
    Check (-not (Invoke-FullStage2 $hostLps $guestLps $true)) 'allow-missing preconfiguration must return pending, not throw'
    Check ($fullStatus.PendingVM -and $started.Count -eq 0 -and $bindCalls -eq 0) 'missing VM must not bind or start'
    $plan=[pscustomobject]@{HostLps=$hostLps;GuestLps=@(1,2)}
    Save-FullPlan $plan $null $null $false
    Check ($savedConfig.PendingVM -and -not $savedConfig.VMId -and $savedConfig.Mode -eq 'full') 'preconfiguration must persist a pending plan without inventing a VM ID'
    $AllowMissingVM=$false
    $missingRejected=$false
    try { Invoke-FullStage2 $hostLps $guestLps $false | Out-Null } catch { $missingRejected=$true }
    Check $missingRejected 'missing VM without explicit allowance must still fail'
    Reset-StageFixture
    $savedConfig.VMId=[string]$other
    $identityRejected=$false
    try { Invoke-FullStage2 $hostLps $guestLps $false | Out-Null } catch { $identityRejected=$true }
    Check ($identityRejected -and $started.Count -eq 0 -and $bindCalls -eq 0) 'saved VM ID mismatch must fail before binding or starting'

    # Windows sees only LPs 0-19 under minroot; Hyper-V still owns all 28 LPs.
    & $cpuModule {
        $script:lpNames=@('_Total') + @(0..27 | ForEach-Object { "Hv LP $_" })
        function script:Get-CimInstance($ClassName) {
            if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{LastBootUpTime=[datetime]'2026-01-02T03:04:05Z'} }
            $script:lpNames | ForEach-Object { [pscustomobject]@{Name=$_} }
        }
    }
    $HostLps='0-19';$GuestLps='20-27';$HostCores=0;$GuestCores=0
    $bcd=[pscustomobject]@{RootProc=20}
    $topo=[pscustomobject]@{Lps=20;Cores=12;HybridSuspected=$true;SmtPerCore=1}
    $plan=Resolve-Plan $topo 'full'
    Check (($plan.GuestLps -join ',') -eq ((20..27) -join ',')) 'full reapply must allow guest LPs hidden from the root partition'
    & $cpuModule { $script:lpNames=$script:lpNames -ne 'Hv LP 24' }
    $rejected=$false
    try { Resolve-Plan $topo 'full' | Out-Null } catch { $rejected=$true }
    Check $rejected 'gapped live hypervisor evidence must fail closed'
    Reset-StageFixture
    $vm.AutomaticStartAction='Start'
    $vm | Add-Member NoteProperty AutomaticStartDelay 10
    function Set-VM($VM,$AutomaticStartAction) { $VM.AutomaticStartAction=$AutomaticStartAction }
    Save-FullPlan $plan $vm $savedConfig $false
    $savedConfig.LastVmStartBootId='prior-boot'
    $plan.GuestLps=@(22..27)
    Save-FullPlan $plan $vm $savedConfig $false
    Check ($savedConfig.GuestLps[0] -eq 22 -and $savedConfig.ManageVmStart) 'updated plan must persist for the next boot task'
    Check ($vm.AutomaticStartAction -eq 'Nothing' -and $savedConfig.VmAutoStart.Action -eq 'Start' -and $savedConfig.VmAutoStart.Delay -eq 10) 'reapply must preserve original automatic start action and delay for undo'
    Check ($savedConfig.LastVmStartBootId -eq 'prior-boot') 'reapply for the same VM must preserve startup history'
    & $cpuModule {
        param($VM)
        $script:observed = $VM
        function script:Get-VM { $script:observed }
        function script:Enter-EdgeBoxCpuPlanLock { return [Threading.Mutex]::new($true) }
    } $vm
    # CPU file and module both live in the temporary fixture. Never touch the installed plan.
    Write-EdgeBoxCpuJson $config ([pscustomobject]@{Mode='full';VMName=$vm.Name;GuestLps=@(22..27)})
    Set-EdgeBoxManualCpuStop -VM $vm
    $marked=Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($marked.VMId -eq [string]$id -and $marked.ManualStopBootId -and $marked.GuestLps[0] -eq 22) 'an explicit stop must bind the legacy plan to the confirmed identity and preserve its LPs'
    Write-EdgeBoxCpuJson $config ([pscustomobject]@{Mode='full';VMName=$vm.Name;VMId=[string]$other})
    $rejected=$false
    try { Set-EdgeBoxManualCpuStop -VM $vm } catch { $rejected=$true }
    Check $rejected 'same-name replacement must not inherit a deliberate stop mark'
    $invalid = $false
    try { Assert-EdgeBoxCpuTool $scriptPath } catch { $invalid=$true }
    Check $invalid 'unsigned fixture must not pass tool validation'
    Write-Host 'PASS: CPU preparation, LP and vCPU verification, minroot reapply, plan persistence, startup retry, deliberate stop across timer runs, missing VM preconfiguration, signature rejection'
} finally {
    Remove-Module cpu-boot -ErrorAction SilentlyContinue
    Remove-Module cpu-tool -ErrorAction SilentlyContinue
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($fixture).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $fixture -Leaf) -match '^EdgeBoxCpuBoot_[a-f0-9]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
