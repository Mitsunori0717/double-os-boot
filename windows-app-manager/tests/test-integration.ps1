#requires -Version 5.1
# Synthetic registry records and fully mocked confirmation/MSI only; NEVER uninstall a real app.
$ErrorActionPreference='Stop'
$dir=Split-Path $PSScriptRoot -Parent
$im=Import-Module (Join-Path $dir 'AppInventory.psm1') -Force -PassThru
$um=Import-Module (Join-Path $dir 'SafeUninstall.psm1') -Force -PassThru
$script:Count=0
function Assert-True($v,[string]$m){if(-not $v){throw "TEST FAILED: $m"};$script:Count++}
function Assert-Throws([scriptblock]$a,[string]$m){$threw=$false;try{& $a|Out-Null}catch{$threw=$true};Assert-True $threw $m}
$secret='FIXTURE_SECRET_AND_INJECTION_92741'
$g1='{11111111-2222-3333-4444-555555555555}'
$g2='{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxAppIntegration_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
try {
    & $im {
        function script:Get-AiCurrentSid {'S-1-5-21-1-2-3-1001'}
        function script:Get-AiRegistryEntries([string]$Hive,[string]$View) {
            if($script:AF.FailRegistry){throw ('fixture registry failed '+$script:AF.Secret)}
            if(-not $script:AF.UserOnly -and $Hive -eq 'LocalMachine' -and $View -eq 'Registry64'){$script:AF.Entries}
            if($script:AF.UserOnly -and $Hive -eq 'CurrentUser' -and $View -eq 'Registry32'){$script:AF.Entries}
            if($script:AF.DuplicateProduct -and $Hive -eq 'CurrentUser' -and $View -eq 'Registry32'){$script:AF.Entries[0]}
        }
        function script:Get-AiAppxEntries {throw 'Appx query forbidden in this integration fixture'}
        function script:Get-AppxPackage {throw 'Real query forbidden'}
    }
    & $um {param($inventoryModule)
        $script:FixtureInventoryModule=$inventoryModule
        function script:Get-SUCurrentSid {$script:UF.CurrentSid}
        function script:Get-SUMsiProductInstances([string]$ProductCode) {
            if($script:UF.NativeQueryFailure){throw 'fixture native MSI metadata unavailable'}
            @($script:UF.Instances[$ProductCode])
        }
        function script:Initialize-SUMsiNative {throw 'Real MSI native binding forbidden in integration tests'}
        function script:Get-SUMsiProperty {throw 'Real MSI native API query forbidden in integration tests'}
        function script:Get-SUInventory {& $script:FixtureInventoryModule {Get-AppInventory}}
        function script:Show-SUConfirmation($Items) {$script:UF.ConfirmCalls++;$script:UF.ConfirmedItems=@($Items);return $script:UF.Approve}
        function script:Test-SUCancelRequested {return ($script:UF.CancelAfter -ge 0 -and $script:UF.Calls.Count -ge $script:UF.CancelAfter)}
        function script:Invoke-SUMsi([string]$ProductCode) {
            if($ProductCode -cnotmatch '^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$'){throw 'Test caught noncanonical MSI argument'}
            $script:UF.Calls.Add($ProductCode)
            if($script:UF.ThrowMsi){throw ('fixture process exception '+$script:UF.Secret)}
            if($script:UF.ChangeAfterFirst -and $script:UF.Calls.Count -eq 1){& $script:FixtureInventoryModule {$script:AF.Entries[1].DisplayVersion='changed-after-confirmation'}}
            if($script:UF.ExitCode -eq 0 -and -not $script:UF.KeepRegistration){& $script:FixtureInventoryModule {param($code)$script:AF.Entries=@($script:AF.Entries|Where-Object{($_.Key -split '\\')[-1] -ine $code})} $ProductCode}
            return $script:UF.ExitCode
        }
        foreach($cmd in @('Start-Process','Invoke-Expression','Remove-AppxPackage','Restart-Computer','Stop-Computer','Get-AppxPackage','Get-ItemProperty','Remove-ItemProperty')) {
            Set-Item -Path ('Function:script:'+$cmd) -Value {throw 'Real query/process/settings forbidden in integration test'}
        }
    } $im
    function Reset-Fixture {
        & $im {param($secret,$g1,$g2)
            $prefix='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'
            $script:AF=[pscustomobject]@{FailRegistry=$false;DuplicateProduct=$false;UserOnly=$false;Secret=$secret;Entries=@(
                [pscustomobject]@{Key=($prefix+$g1);DisplayName='7-Zip 24.09';DisplayVersion='24.09';Publisher='Igor Pavlov';InstallLocation='C:\Fixture\Seven';UninstallString=('cmd /c echo '+$secret+' & delete-everything');QuietUninstallString=('powershell -Command '+$secret);WindowsInstaller=1;SystemComponent=0;NoRemove=0},
                [pscustomobject]@{Key=($prefix+$g2);DisplayName='Mozilla Firefox 128';DisplayVersion='128';Publisher='Mozilla';InstallLocation='C:\Fixture\Firefox';UninstallString=('untrusted.exe '+$secret);QuietUninstallString='';WindowsInstaller=1;SystemComponent=0;NoRemove=0},
                [pscustomobject]@{Key=($prefix+'{33333333-4444-5555-6666-777777777777}');DisplayName='Intel Ethernet Driver';DisplayVersion='1';Publisher='Intel';WindowsInstaller=1;SystemComponent=0;NoRemove=0},
                [pscustomobject]@{Key=($prefix+'{44444444-5555-6666-7777-888888888888}');DisplayName='Unknown Business Tool';DisplayVersion='1';Publisher='Unknown';WindowsInstaller=1;SystemComponent=0;NoRemove=0})}
        } $secret $g1 $g2
        & $um {param($secret)
            $script:SUConfirmations=@{}
            $script:UF=[pscustomobject]@{Secret=$secret;Calls=[Collections.Generic.List[string]]::new();Approve=$true;ConfirmCalls=0;ConfirmedItems=@();ExitCode=0;CancelAfter=-1;ThrowMsi=$false;ChangeAfterFirst=$false;KeepRegistration=$false;CurrentSid='S-1-5-21-1-2-3-1001';NativeQueryFailure=$false;Instances=@{}}
            $script:UF.Instances['{11111111-2222-3333-4444-555555555555}']=@([pscustomobject]@{Context=4;UserSid='';ProductName='7-Zip 24.09';VersionString='24.09';Publisher='Igor Pavlov';State='5'})
            $script:UF.Instances['{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}']=@([pscustomobject]@{Context=4;UserSid='';ProductName='Mozilla Firefox 128';VersionString='128';Publisher='Mozilla';State='5'})
        } $secret
    }
    function Read-FixtureInventory {& $im {Get-AppInventory}}
    function Read-Calls {@(& $um {$script:UF.Calls.ToArray()})}
    function Make-Plan {
        $i=Read-FixtureInventory
        New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[0].Id,$i.Records[1].Id)
    }
    function New-LogPath {Join-Path $temp ([guid]::NewGuid().ToString('N')+'.jsonl')}
    Reset-Fixture
    $i=Read-FixtureInventory
    Assert-True ($i.Complete -and $i.Records.Count -eq 4) 'mock registry produces complete inventory'
    Assert-True (Test-AppRecordIntegrity $i.Records[0]) 'collector record has valid integrity hash'
    $plan=Make-Plan
    Assert-True ($plan.Items.Count -eq 2 -and (Read-Calls).Count -eq 0) 'multiple selection planning causes no execution'
    Assert-True (-not (($plan|ConvertTo-Json -Depth 12).Contains($secret))) 'plan never includes raw command/private arguments'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[0].Id,$i.Records[0].Id)} 'duplicate selection rejected'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[2].Id)} 'hardware protected selection rejected'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[3].Id)} 'unknown purpose selection rejected'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[0].Id,$i.Records[2].Id)} 'mixed safe/protected selection rejected as a whole'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @('nonexistent')} 'missing selected identity rejected'
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken 'fake' -LogPath (New-LogPath)} 'no native confirmation token means no execution'
    Assert-True ((Read-Calls).Count -eq 0) 'refused operations have no MSI effects'
    & $um {$script:UF.Approve=$false}
    $token=Request-SafeUninstallConfirmation -Plan $plan
    Assert-True ([string]::IsNullOrEmpty($token) -and (Read-Calls).Count -eq 0) 'declining native confirmation gives no token and no execution'
    Reset-Fixture;$plan=Make-Plan
    $token=Request-SafeUninstallConfirmation -Plan $plan
    Assert-True (-not [string]::IsNullOrEmpty($token)) 'positive mocked native confirmation issues token'
    $log=New-LogPath;$result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath $log
    Assert-True ($result.Results.Count -eq 2 -and $result.State -eq 'CompletedInstallerBatch') 'selected safe MSI applications processed serially'
    $calls=Read-Calls
    Assert-True ($calls.Count -eq 2 -and $calls[0] -ceq $g1 -and $calls[1] -ceq $g2) 'only canonical selected GUIDs reach process wrapper'
    Assert-True (-not $result.RemovalVerified -and -not $result.RestartPerformedByTool) 'installer success is not removal verification or restart'
    Assert-True (-not ((Get-Content -LiteralPath $log -Raw).Contains($secret))) 'uninstall logs never include untrusted command/private arguments'
    Assert-True (-not (($result|ConvertTo-Json -Depth 12).Contains($secret))) 'result does not leak command arguments'
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)} 'confirmation token single use'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    $plan.Items[0].ProductCode=$g2
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)} 'tampered plan rejected'
    Assert-True ((Read-Calls).Count -eq 0) 'tampered plan executes nothing'
    Reset-Fixture;$plan=Make-Plan
    & $im {$script:AF.Entries[0].UninstallString='changed registry command'}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'registry change before dialog invalidates plan'
    Assert-True ((& $um {$script:UF.ConfirmCalls}) -eq 0) 'stale plan not shown as current confirmation'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $im {$script:AF.Entries[0].DisplayVersion='changed-version'}
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)} 'registry change after confirmation blocks execution'
    Assert-True ((Read-Calls).Count -eq 0) 'stale token executes nothing'
    Reset-Fixture;& $im {$script:AF.DuplicateProduct=$true}
    Assert-Throws {Make-Plan} 'same MSI across source registrations is ambiguous'
    Reset-Fixture;& $im {$script:AF.Entries[0].Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\not-a-guid'}
    Assert-Throws {Make-Plan} 'non-GUID MSI registration refused'
    Reset-Fixture;& $im {$script:AF.Entries[0].WindowsInstaller=0}
    Assert-Throws {Make-Plan} 'non-MSI raw uninstall command unsupported'
    Reset-Fixture;& $im {$script:AF.FailRegistry=$true}
    $i=Read-FixtureInventory
    Assert-True (-not $i.Complete) 'registry access failure incomplete'
    Assert-True (-not (($i|ConvertTo-Json -Depth 12).Contains($secret))) 'registry exception sanitized'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @('no-id')} 'incomplete inventory refused'
    foreach($case in @(@{Code=3010;State='RestartRequired'},@{Code=1641;State='RestartInitiated'},@{Code=1602;State='Cancelled'},@{Code=1603;State='InstallerFailed'})) {
        Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
        & $um {param($c)$script:UF.ExitCode=$c} $case.Code
        $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
        Assert-True ($result.State -eq $case.State) ('MSI exit '+$case.Code+' maps to '+$case.State)
        Assert-True ((Read-Calls).Count -eq 1) ('MSI exit '+$case.Code+' stops before next selected app')
        Assert-True (-not $result.RestartPerformedByTool) 'tool never initiates restart'
    }
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.CancelAfter=0}
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'CancelledBeforeNext' -and (Read-Calls).Count -eq 0) 'pre-start cancel prevents all installers'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.CancelAfter=1}
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'CancelledBeforeNext' -and (Read-Calls).Count -eq 1) 'between-item cancel prevents second installer'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.ChangeAfterFirst=$true}
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'StoppedOnError' -and (Read-Calls).Count -eq 1) 'changed next registration stops batch after first'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.ThrowMsi=$true}
    $log=New-LogPath;$result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath $log
    Assert-True ($result.State -eq 'StoppedOnError' -and (Read-Calls).Count -eq 1) 'process exception stops batch'
    Assert-True (-not ((Get-Content -LiteralPath $log -Raw).Contains($secret))) 'process exception text not exposed in log'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {param($t)$script:SUConfirmations[$t].Expires=[DateTime]::UtcNow.AddSeconds(-1)} $token
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)} 'expired confirmation rejected'
    Assert-True ((Read-Calls).Count -eq 0) 'expired token executes nothing'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    $log=New-LogPath;[IO.File]::WriteAllText($log,'existing log')
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath $log} 'existing log never overwritten'
    Assert-True ([IO.File]::ReadAllText($log) -eq 'existing log' -and (Read-Calls).Count -eq 0) 'log overwrite refusal leaves state unchanged'
    Reset-Fixture;$i=Read-FixtureInventory
    $i.Records[0].UninstallString='forged record command'
    Assert-Throws {New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[0].Id)} 'tampered inventory record hash rejected'
    Reset-Fixture;& $im {$script:AF.Entries[0].NoRemove=1}
    Assert-Throws {Make-Plan} 'registration NoRemove flag protects app'
    Reset-Fixture;& $im {$script:AF.Entries[0].SystemComponent=1}
    Assert-Throws {Make-Plan} 'registration SystemComponent flag protects app'
    Reset-Fixture;$i=Read-FixtureInventory;$plan=Make-Plan
    $other=New-SafeUninstallPlan -Inventory $i -SelectedIds @($i.Records[0].Id)
    $token=Request-SafeUninstallConfirmation -Plan $plan
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $other -ConfirmationToken $token -LogPath (New-LogPath)} 'token for two-item batch cannot authorize different batch'
    Assert-True ((Read-Calls).Count -eq 0) 'scope-mismatched token executes nothing'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.KeepRegistration=$true}
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'StoppedOnRegistrationUncertainty' -and (Read-Calls).Count -eq 1) 'MSI zero with registration still present stops next app'
    Assert-True ($result.Results[0].RegistrationState -eq 'StillPresent' -and -not $result.RemovalVerified) 'registration presence is reported without false removal claim'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.ExitCode=1618}
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'InstallerBusy' -and (Read-Calls).Count -eq 1) 'MSI busy stops without retries or next app'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath) -CancellationRequested {$true}
    Assert-True ($result.State -eq 'CancelledBeforeNext' -and (Read-Calls).Count -eq 0) 'UI cancellation callback prevents installer invocation'
    # Authoritative MSI context fixtures are independent of registry display strings.
    Reset-Fixture;$plan=Make-Plan
    & $im {$script:AF.UserOnly=$true}
    $plan=Make-Plan
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'HKCU spoof pointing at machine MSI context is refused'
    Assert-True ((& $um {$script:UF.ConfirmCalls}) -eq 0 -and (Read-Calls).Count -eq 0) 'context spoof reaches neither confirmation nor installer'
    Reset-Fixture;$plan=Make-Plan
    & $um {$v=$script:UF.Instances['{11111111-2222-3333-4444-555555555555}'][0];$v.Context=2;$v.UserSid=$script:UF.CurrentSid}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'HKLM registration cannot authorize current-user MSI context'
    foreach($field in @('ProductName','VersionString','Publisher','State')) {
        Reset-Fixture;$plan=Make-Plan
        & $um {param($field)$script:UF.Instances['{11111111-2222-3333-4444-555555555555}'][0].$field='mismatch'} $field
        Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} "authoritative MSI $field mismatch is refused"
        Assert-True ((& $um {$script:UF.ConfirmCalls}) -eq 0) "MSI $field mismatch not shown as approved identity"
    }
    Reset-Fixture;$plan=Make-Plan
    & $um {$script:UF.Instances['{11111111-2222-3333-4444-555555555555}']=@()}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'unregistered MSI product refused'
    Reset-Fixture;$plan=Make-Plan
    & $um {$script:UF.Instances['{11111111-2222-3333-4444-555555555555}']+= $script:UF.Instances['{11111111-2222-3333-4444-555555555555}'][0].PSObject.Copy()}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'multiple native MSI instances refused'
    Reset-Fixture;$plan=Make-Plan
    & $um {$script:UF.NativeQueryFailure=$true}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'native metadata unavailable fails closed'
    Assert-True ((Read-Calls).Count -eq 0) 'native metadata failure cannot invoke installer'
    Reset-Fixture;$plan=Make-Plan
    & $um {$script:UF.CurrentSid='S-1-5-21-9-8-7-1002'}
    Assert-Throws {Request-SafeUninstallConfirmation -Plan $plan} 'changed user SID invalidates source context'
    Reset-Fixture;$plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    & $um {$script:UF.Instances['{11111111-2222-3333-4444-555555555555}'][0].VersionString='new version'}
    Assert-Throws {Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)} 'authoritative metadata changed after confirmation blocks execution'
    Assert-True ((Read-Calls).Count -eq 0) 'native state revalidated before any installer'
    Reset-Fixture;& $im {$script:AF.UserOnly=$true}
    & $um {foreach($list in $script:UF.Instances.Values){$list[0].Context=2;$list[0].UserSid=$script:UF.CurrentSid}}
    $plan=Make-Plan;$token=Request-SafeUninstallConfirmation -Plan $plan
    $result=Invoke-SafeUninstallPlan -Plan $plan -ConfirmationToken $token -LogPath (New-LogPath)
    Assert-True ($result.State -eq 'CompletedInstallerBatch' -and (Read-Calls).Count -eq 2) 'known current-user registry and native MSI context agree'
    Write-Host ("PASS: {0} app inventory/safe-uninstall integration assertions; mocked registry, native dialogs and MSI only" -f $script:Count)
} finally {
    $resolved=[IO.Path]::GetFullPath($temp);$root=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxAppIntegration_[0-9a-f]{32}$'){throw 'Unsafe test cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Remove-Module $im,$um -Force
}
