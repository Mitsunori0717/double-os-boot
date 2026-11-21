#requires -Version 5.1
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test-safety.ps1')
& (Join-Path $PSScriptRoot 'test-vm-create-safety.ps1')
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
        # These tests isolate orchestration. test-safety.ps1 exercises the real package preflight.
        function Get-SetupMissingFiles { @() }
        function Get-SetupStepState([string]$Id) { New-SetupState $script:MockStates[$Id] ('fixture '+$Id) }
        function Invoke-SetupStep([string]$Id) {
            $script:Applied+=$Id
            if ($Id -eq $script:Fail) { throw 'simulated failure' }
            if ($Id -ne $script:NoEffect) { $script:MockStates[$Id]='Done' }
        }
        function Register-SetupResume { param($Step,[switch]$RestartIfNeeded) $script:Registered=$true; $script:RegisteredRestart=[bool]$RestartIfNeeded }
        function Unregister-ScheduledTask { $script:Removed=$true }
        function Restart-Computer { $script:RestartCalls++; throw 'Tests must never restart the PC' }
        function Invoke-EdgeBoxHostRestart { $script:RestartCalls++; throw 'unexpected setup restart' }
        function Get-SetupBootId { 'boot-current' }
        function Write-SetupLog([string]$Message) { if ($script:RunDir) {Add-Content (Join-Path $script:RunDir 'summary.txt') $Message -Encoding UTF8} }
        function Reset-Fixture {
            foreach($d in Get-SetupSteps){$script:MockStates[$d.Id]='Done'}
            $script:Applied=@();$script:Fail='';$script:NoEffect='';$script:Removed=$false;$script:Registered=$false;$script:RegisteredRestart=$false
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
        $script:RestartCalls=0
        $script:MockStates['02']='RebootRequired'
        $rc=Invoke-EdgeBoxSetup -NoConfirm
        Assert ($rc -eq 3010 -and $script:Registered) 'pending reboot must register resumption and return 3010'
        Assert (-not $script:RegisteredRestart) 'manual restart preference must survive resumption'
        $state=Join-Path $script:FixtureSetupDir 'resume-state.json'
        $rc=Invoke-EdgeBoxSetup -NoConfirm -RestartIfNeeded
        Assert ($rc -eq 3010 -and $script:RestartCalls -eq 0 -and -not $script:RegisteredRestart) 'legacy restart flags must only register resume after Hyper-V setup'
        $script:MockStates['02']='Done'; $script:MockStates['10']='RebootRequired'
        $rc=Invoke-EdgeBoxSetup -NoConfirm -RestartIfNeeded
        Assert ($rc -eq 3010 -and $script:RestartCalls -eq 0 -and -not $script:RegisteredRestart) 'CPU setup must never stop a guest or reboot the host'
        $script:MockStates['02']='RebootRequired'; $script:MockStates['10']='Done'
        @{BootId='boot-previous';Pending=@('02');AutoReboots=1}|ConvertTo-Json|Set-Content $state -Encoding UTF8
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm
        Assert ($rc -eq 1 -and $script:Removed) 'unchanged settings after reboot must stop the restart loop'
        Reset-Fixture
        $script:MockStates['10']='RebootRequired'
        @{BootId='boot-previous';Pending=@('02');AutoReboots=2}|ConvertTo-Json|Set-Content $state -Encoding UTF8
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm -RestartIfNeeded
        Assert ($rc -eq 3010 -and $script:Registered -and $script:RestartCalls -eq 0 -and -not $script:RegisteredRestart) 'a legacy resume task must wait for the operator even after prior reboots'
        Reset-Fixture
        $script:MockStates['05']='NeedsWork'
        $rc=Invoke-EdgeBoxSetup -Step '05' -NoConfirm
        Assert ($rc -eq 0 -and ($script:Applied -join ',') -eq '05') 'numbered batch must run only its own step'
        Assert (-not $script:Removed) 'numbered runs must preserve an existing all-steps resume task'
        Reset-Fixture
        $script:MockStates['02']='RebootRequired'
        $before=Get-Content -LiteralPath $state -Raw
        $rc=Invoke-EdgeBoxSetup -Step '02' -NoConfirm -RestartIfNeeded
        Assert ($rc -eq 3010 -and -not $script:Registered -and -not $script:Removed) 'numbered pending runs must not register or remove resume tasks'
        Assert ((Get-Content -LiteralPath $state -Raw) -eq $before) 'numbered runs must preserve all-steps resume state'
        Reset-Fixture
        $settings=Join-Path $script:FixtureSetupDir 'settings.json'
        Set-Content -LiteralPath $settings -Value '{broken' -Encoding UTF8
        $script:MockStates['13']='NeedsWork'
        $rc=Invoke-EdgeBoxSetup -Step '13' -NoConfirm
        Assert ($rc -eq 0 -and '13' -in $script:Applied) 'corrupt device choices must not block independent settings'
        Remove-Item -LiteralPath $settings -Force
        Set-Content -LiteralPath $state -Value '{broken' -Encoding UTF8
        $script:MockStates['13']='NeedsWork';$script:Applied=@()
        $rc=Invoke-EdgeBoxSetup -Resume -NoConfirm
        Assert ($rc -eq 1 -and $script:Removed) 'corrupt resume state must stop automatic resumption safely'
        Assert ($script:Applied.Count -eq 0) 'corrupt resume state must be rejected before changing settings'
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
            [pscustomobject]@{Name='fixture';Id='fixture-id';State=$state}
        }
        function Stop-VM {param($VM,[switch]$AsJob,[switch]$Confirm,$ErrorAction) if(-not $AsJob -or $VM.Id -ne 'fixture-id'){throw 'unbound or synchronous stop'};$script:StopCalls++;[pscustomobject]@{State='Running'} }
        function Stop-Job {}
        function Remove-Job {}
        $script:popupEvents=@()
        function Start-EdgeBoxShutdownProgress([string]$NextAction) {
            $script:popupEvents+=@($NextAction)
            $signal=[pscustomobject]@{}
            $signal | Add-Member ScriptMethod Set { $script:popupEvents+='closed'; return $true }
            $signal | Add-Member ScriptMethod Dispose { $script:popupEvents+='disposed' }
            $signal
        }
        $confirmed=Wait-EdgeBoxShutdown -VMName fixture -NextAction 'Windows will shut down' -PassThruId -Log {}
        Assert ($confirmed -eq 'fixture-id') 'caller must retain the confirmed guest ID'
        Assert (($script:popupEvents -join ',') -eq 'Windows will shut down,closed,disposed') 'nonmodal progress must close after positive confirmation'
        Assert ($script:StopCalls -eq 1) 'running VM receives normal async shutdown'
        $script:Scenario='off';$script:StopCalls=0
        Wait-EdgeBoxShutdown -VMName fixture -Log {}
        Assert ($script:StopCalls -eq 0) 'already off VM requires no stop'
        foreach($scenario in @('missing','saved','timeout')){
            $script:Scenario=$scenario;$script:Calls=0;$script:StopCalls=0;$failed=$false
            $script:popupEvents=@()
            try{Wait-EdgeBoxShutdown -VMName fixture -TimeoutSec 1 -NextAction 'fixture next step' -Log {}}catch{$failed=$true}
            Assert $failed ('unsafe state must block host shutdown: '+$scenario)
            Assert (($script:popupEvents -join ',') -eq 'fixture next step,closed,disposed') 'failure and timeout must close the progress window'
        }
        Write-Host 'PASS: shutdown, already off, missing/saved VM, real timeout, no forced power-off'
    }
    & $shutdown {
        param($ProjectRoot,$NativeBootTestDir)
        function Assert($ok,[string]$why) { if (-not $ok) { throw "TEST FAILED: $why" } }
        function Assert-Blocked([scriptblock]$Action,[string]$why) {
            $blocked=$false
            try { & $Action } catch { $blocked=$true }
            Assert ($blocked -and $script:restartCount -eq 0) $why
        }
        $script:restartCount=0; $script:stopCount=0; $script:apiDown=$false
        function Start-EdgeBoxShutdownProgress { return } # headless/hidden-UI startup failure must not affect VM safety
        $script:guest=[pscustomobject]@{Name='Custom Box';Id='original';State='Running'}
        $script:inventory=@($script:guest)
        function Get-VM { if ($script:apiDown) { throw 'unavailable VM API' }; $script:inventory }
        function Stop-VM { param($VM,[switch]$AsJob,[switch]$Confirm) $script:stopCount++; $VM.State='Off' }
        function Restart-Computer { param([switch]$Force) $script:restartCount++; if ($Force) { throw 'forced restart' } }
        Invoke-EdgeBoxHostRestart -VMName 'Custom Box' -ExpectedVmId original
        Assert ($script:restartCount -eq 1 -and $script:stopCount -eq 1) 'selected running guest must stop normally before restarting'
        $script:restartCount=0
        Assert-Blocked { Invoke-EdgeBoxHostRestart -VMName 'Custom Box' -ExpectedVmId replacement } 'a changed VM identity blocks restart'
        Assert-Blocked { Invoke-EdgeBoxHostRestart -VMName 'Custom Box' -BeforeRestart { $script:guest.State='Running' } } 'guest restarting before host restart blocks the host'
        Assert-Blocked { Invoke-EdgeBoxHostRestart } 'an unrelated running VM cannot be implicitly stopped'
        Assert ($script:stopCount -eq 1) 'an unrelated VM must receive no stop request'
        $script:apiDown=$true
        Assert-Blocked { Invoke-EdgeBoxHostRestart } 'an unavailable management API blocks manual restart'

        $nativePath=Join-Path $ProjectRoot 'windows-host\04-reboot-to-field-native.ps1'
        $nativeAst=[Management.Automation.Language.Parser]::ParseFile($nativePath,[ref]$null,[ref]$null)
        foreach ($name in @('Get-NativeBootSequence','Invoke-EdgeBoxNativeRestart','ConvertFrom-FirmwareEntries','Get-NativeBootConsoleEntry')) {
            $node=$nativeAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
            . ([scriptblock]::Create($node.Extent.Text))
        }
        $script:apiDown=$false; $script:guest.State='Off'; $script:restartCount=0
        $entry='{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}'
        $vmGuid=[guid]'12345678-1234-1234-1234-123456789abc'
        $otherEntry='{dddddddd-dddd-dddd-dddd-dddddddddddd}'
        $rawFirmware=@"
Firmware Boot Manager
identifier              {fwbootmgr}
displayorder            $otherEntry

Windows Boot Manager
identifier              {9dea862c-5cdd-4e70-acc1-f32b344d4795}
description             fixture translated Windows Boot Manager name

Firmware Application
identifier              $entry
description             Edge Box

ファームウェア アプリケーション
識別子                  $otherEntry
説明                    UEFI OS
"@
        $script:firmwareFixture=@(ConvertFrom-FirmwareEntries $rawFirmware)
        Assert ($script:firmwareFixture.Count -eq 2 -and $script:firmwareFixture[0].Guid -eq $entry -and $script:firmwareFixture[1].Guid -eq $otherEntry) 'firmware parser reads English/Japanese identifiers and does not accept a display-order ID or the Windows boot manager'
        function Get-FirmwareEntries { $script:firmwareFixture }
        $bootConfig=Join-Path $NativeBootTestDir 'native-boot-fixture.conf'
        $entry | Set-Content -LiteralPath $bootConfig -Encoding ASCII
        Assert-Blocked { Get-NativeBootConsoleEntry $vmGuid $bootConfig } 'legacy GUID cannot silently become a verified binding'
        $binding='VM={0};UEFI={1}' -f $vmGuid,$entry
        @($entry,$binding) | Set-Content -LiteralPath $bootConfig -Encoding ASCII
        Assert ((Get-NativeBootConsoleEntry $vmGuid $bootConfig) -eq $entry) 'explicit setup binds the same VM and firmware entry'
        Assert-Blocked { Get-NativeBootConsoleEntry '87654321-1234-1234-1234-123456789abc' $bootConfig } 'a different VM cannot borrow an entry'
        Assert-Blocked { Get-NativeBootConsoleEntry $vmGuid ($bootConfig+'.missing') } 'missing boot config cannot start native boot'
        @($otherEntry,$binding) | Set-Content -LiteralPath $bootConfig -Encoding ASCII
        Assert-Blocked { Get-NativeBootConsoleEntry $vmGuid $bootConfig } 'another valid firmware GUID cannot replace the confirmed entry'
        @($entry,$binding) | Set-Content -LiteralPath $bootConfig -Encoding ASCII
        $script:firmwareFixture=@()
        Assert-Blocked { Get-NativeBootConsoleEntry $vmGuid $bootConfig } 'missing firmware entry is rejected before any VM shutdown'
        Assert ($script:restartCount -eq 0 -and $script:stopCount -eq 1) 'console target validation never changes VM or host state'
        $prior=@('{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}','{cccccccc-cccc-cccc-cccc-cccccccccccc}')
        $script:queue=$prior; $script:bcdFail=$true; $script:guestStartsDuringBcd=$true
        function bcdedit.exe {
            $global:LASTEXITCODE=0
            switch ($args[0]) {
                '/enum' { if ($script:queue.Count) { 'bootsequence   '+($script:queue -join "`r`n               ") } }
                '/deletevalue' { $script:queue=@() }
                '/set' {
                    if ($script:bcdFail) { $global:LASTEXITCODE=5; return }
                    $script:queue=@($args | Select-Object -Skip 3)
                    if ($script:guestStartsDuringBcd -and $script:queue[0] -eq $entry) { $script:guest.State='Running' }
                }
                default { throw 'unexpected BCD operation' }
            }
        }
        Assert-Blocked { Invoke-EdgeBoxNativeRestart $entry 'Custom Box' original } 'failed firmware update blocks Windows restart'
        $script:bcdFail=$false
        Assert-Blocked { Invoke-EdgeBoxNativeRestart $entry 'Custom Box' original } 'a guest restarting during BCD setup blocks Windows restart'
        Assert (($script:queue -join ',') -eq ($prior -join ',')) 'an aborted native boot must restore the full previous firmware sequence'
        $script:guestStartsDuringBcd=$false
        Invoke-EdgeBoxNativeRestart $entry 'Custom Box' original
        Assert ($script:restartCount -eq 1 -and $script:queue.Count -eq 1 -and $script:queue[0] -eq $entry) 'native boot with a confirmed stopped VM must request exactly one restart'
        Write-Host 'PASS: manual host restart, custom VM identity and native boot rollback with mocked OS calls'
    } $project $temp
    Remove-Module $shutdown
    Write-Host 'All tests passed.' -ForegroundColor Green
} finally {
    Remove-Module $module -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($temp)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'EdgeBoxSetupTests_*') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
