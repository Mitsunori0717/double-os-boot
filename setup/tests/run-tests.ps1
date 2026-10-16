#requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxSetupTests_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temp 'setup') -Force | Out-Null
$modulePath=Join-Path $temp 'setup\setup-engine.psm1'
Copy-Item (Join-Path $project 'setup\setup-engine.psm1') $modulePath
Copy-Item (Join-Path $project 'setup\run-child.ps1') (Join-Path $temp 'setup\run-child.ps1')
$module=Import-Module $modulePath -PassThru -Force
& $module { param($Dir) $script:FixtureSetupDir=$Dir } (Split-Path $modulePath -Parent)
try {
    & $module {
        function Assert($Condition,[string]$Message) { if (-not $Condition) { throw "TEST FAILED: $Message" } }
        $script:MockStates=@{}; $script:Applied=@(); $script:Fail=''; $script:NoEffect=''
        function Test-SetupAdmin { $true }
        function Get-SetupStepState([string]$Id) { New-SetupState $script:MockStates[$Id] ('fixture '+$Id) }
        function Invoke-SetupStep([string]$Id) {
            $script:Applied+=$Id
            if ($Id -eq $script:Fail) { throw 'simulated failure' }
            if ($Id -ne $script:NoEffect) { $script:MockStates[$Id]='Done' }
        }
        function Register-SetupResume { $script:Registered=$true }
        function Unregister-ScheduledTask { $script:Removed=$true }
        function Restart-Computer { throw 'Tests must never restart the PC' }
        function Get-SetupBootId { 'boot-current' }
        function Write-SetupLog([string]$Message) { if ($script:RunDir) {Add-Content (Join-Path $script:RunDir 'summary.txt') $Message -Encoding UTF8} }
        function Reset-Fixture {
            foreach($d in Get-SetupSteps){$script:MockStates[$d.Id]='Done'}
            $script:Applied=@();$script:Fail='';$script:NoEffect='';$script:Removed=$false;$script:Registered=$false
        }
        Reset-Fixture
        $rc=Invoke-EdgeBoxSetup -Status
        Assert ($rc -eq 0 -and $script:Applied.Count -eq 0) 'status must never apply settings'
        Assert (-not (Test-Path (Join-Path $script:FixtureSetupDir 'logs'))) 'status must not write logs or settings'
        $rc=Invoke-EdgeBoxSetup -NoConfirm
        Assert ($rc -eq 0 -and $script:Applied.Count -eq 0) 'completed setup must be a no-op'
        $rc=Invoke-EdgeBoxSetup -NoConfirm
        Assert ($rc -eq 0 -and $script:Applied.Count -eq 0) 'repeated completed setup must be a no-op'

        Reset-Fixture
        foreach($id in @('05','06','09','10','13')){$script:MockStates[$id]='NeedsWork'}
        $script:Fail='05'
        $rc=Invoke-EdgeBoxSetup -NoConfirm
        Assert ($rc -eq 1) 'a failed step must produce a nonzero exit'
        Assert ('06' -in $script:Applied -and '13' -in $script:Applied) 'independent steps must continue after failure'
        Assert ('09' -notin $script:Applied -and '10' -notin $script:Applied) 'dependent steps must be skipped'
        $latest=Get-ChildItem (Join-Path $script:FixtureSetupDir 'logs') -Directory | Sort-Object LastWriteTime | Select-Object -Last 1
        $summary=Get-Content (Join-Path $latest.FullName 'summary.txt') -Raw -Encoding UTF8
        Assert ($summary.Contains('simulated failure') -and $summary.Contains('05-create-edgebox.cmd') -and $summary.Contains('対処法')) 'failure log must include cause, remedy and retry batch'
        $results=Get-Content (Join-Path $latest.FullName 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert (($results | Where-Object Number -eq '09').State -eq 'Blocked') 'structured log must describe dependency blocking'

        Reset-Fixture
        $script:MockStates['05']='NeedsWork';$script:NoEffect='05'
        $s=Invoke-SetupOne ((Get-SetupSteps)[1])
        Assert ($s.State -eq 'Failed') 'exit zero without real setting changes must not count as success'
        Reset-Fixture
        $script:MockStates['05']='Unknown'
        $s=Invoke-SetupOne ((Get-SetupSteps)[1])
        Assert ($s.State -eq 'Unknown' -and $script:Applied.Count -eq 0) 'unreadable state must not be treated as missing'

        Reset-Fixture
        $script:MockStates['02']='RebootRequired'
        $rc=Invoke-EdgeBoxSetup -NoConfirm
        Assert ($rc -eq 3010 -and $script:Registered) 'pending reboot must register resumption and return 3010'
        $state=Join-Path $script:FixtureSetupDir 'resume-state.json'
        @{BootId='boot-previous';Pending=@('02');AutoReboots=1}|ConvertTo-Json|Set-Content $state -Encoding UTF8
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm
        Assert ($rc -eq 1 -and $script:Removed) 'unchanged settings after reboot must stop the restart loop'
        Reset-Fixture
        $script:MockStates['10']='RebootRequired'
        @{BootId='boot-previous';Pending=@('02');AutoReboots=2}|ConvertTo-Json|Set-Content $state -Encoding UTF8
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm
        Assert ($rc -eq 1 -and -not $script:Registered) 'automatic reboots must be bounded'
        Reset-Fixture
        $script:MockStates['05']='NeedsWork'
        $rc=Invoke-EdgeBoxSetup -Step '05' -NoConfirm
        Assert ($rc -eq 0 -and ($script:Applied -join ',') -eq '05') 'numbered batch must run only its own step'
        Reset-Fixture
        $settings=Join-Path $script:FixtureSetupDir 'settings.json'
        Set-Content -LiteralPath $settings -Value '{broken' -Encoding UTF8
        $script:MockStates['13']='NeedsWork'
        $rc=Invoke-EdgeBoxSetup -Step '13' -NoConfirm
        Assert ($rc -eq 0 -and '13' -in $script:Applied) 'corrupt device choices must not block independent settings'
        Remove-Item -LiteralPath $settings -Force
        Set-Content -LiteralPath $state -Value '{broken' -Encoding UTF8
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm
        Assert ($rc -eq 1 -and $script:Removed) 'corrupt resume state must stop automatic resumption safely'
        Write-Host 'PASS: setup resumption, idempotence, failure isolation, postchecks, logs and numbered retry'
    }
    # 実際に別プロセスを起動し、引用符・空白・末尾バックスラッシュと終了コードを確認する。
    $fixture=Join-Path $temp "child space's.ps1"
    [IO.File]::WriteAllText($fixture,'param([string]$Value) if($Value -ne ''a b"c\''){exit 7}; Write-Output ''子プロセス成功''; exit 0',(New-Object Text.UTF8Encoding($true)))
    & $module {
        param($Fixture,$TempRoot)
        function Assert($Condition,[string]$Message){if(-not $Condition){throw "TEST FAILED: $Message"}}
        $script:Root=$TempRoot;$script:RunDir=$TempRoot;$script:ActiveStep='test'
        Invoke-SetupChild ([IO.Path]::GetFileName($Fixture)) @('-Value','a b"c\')
        $childLog=Join-Path $TempRoot ("test-"+[IO.Path]::GetFileNameWithoutExtension($Fixture)+'.txt')
        Assert ([IO.File]::ReadAllText($childLog,[Text.Encoding]::UTF8).Contains('子プロセス成功')) 'child logs must be readable UTF-8'
        [IO.File]::WriteAllText($Fixture,'exit 23')
        $failed=$false
        try{Invoke-SetupChild ([IO.Path]::GetFileName($Fixture))}catch{$failed=$_.Exception.Message.Contains('23')}
        Assert $failed 'child exit code must be retained'
        Write-Host 'PASS: real child process quoting and failure exit code'
    } $fixture $temp

    $shutdown=Import-Module (Join-Path $project 'windows-host\vm-shutdown.psm1') -PassThru -Force
    & $shutdown {
        function Assert($Condition,[string]$Message){if(-not $Condition){throw "TEST FAILED: $Message"}}
        $script:Calls=0;$script:StopCalls=0;$script:Scenario='stops'
        function Get-VM {
            $script:Calls++
            if($script:Scenario -eq 'missing'){throw 'missing VM'}
            $state='Running'
            if($script:Scenario -eq 'off' -or ($script:Scenario -eq 'stops' -and $script:Calls -gt 1)){$state='Off'}
            if($script:Scenario -eq 'saved'){$state='Saved'}
            [pscustomobject]@{State=$state}
        }
        function Stop-VM {param($Name,[switch]$AsJob,[switch]$Confirm,$ErrorAction) if(-not $AsJob){throw 'synchronous stop'};$script:StopCalls++;[pscustomobject]@{State='Running'} }
        function Stop-Job {}
        function Remove-Job {}
        Wait-EdgeBoxShutdown -VMName fixture -Log {}
        Assert ($script:StopCalls -eq 1) 'running VM receives normal async shutdown'
        $script:Scenario='off';$script:StopCalls=0
        Wait-EdgeBoxShutdown -VMName fixture -Log {}
        Assert ($script:StopCalls -eq 0) 'already off VM requires no stop'
        foreach($scenario in @('missing','saved','timeout')){
            $script:Scenario=$scenario;$script:Calls=0;$script:StopCalls=0;$failed=$false
            try{Wait-EdgeBoxShutdown -VMName fixture -TimeoutSec 1 -Log {}}catch{$failed=$true}
            Assert $failed ('unsafe state must block host shutdown: '+$scenario)
        }
        Write-Host 'PASS: shutdown, already off, missing/saved VM, real timeout, no forced power-off'
    }
    Remove-Module $shutdown
    Write-Host 'All tests passed.' -ForegroundColor Green
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'EdgeBoxSetupTests_*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
