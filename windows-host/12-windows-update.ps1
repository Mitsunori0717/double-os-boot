#requires -Version 5.1
<#
.SYNOPSIS
    Edge Box の Windows Update を手動運用にし、再起動の競合を検査します。
.EXAMPLE
    .\12-windows-update.ps1 -Status
    .\12-windows-update.ps1 -UpdateNow
    .\12-windows-update.ps1 -UpdateNow -PackagePath C:\Updates\update.msu
    .\12-windows-update.ps1 -Restore  # バージョン固定・先送りのみ解除
#>
[CmdletBinding(DefaultParameterSetName='Apply')]
param(
    [Parameter(ParameterSetName='Restore')][switch]$Restore,
    [Parameter(ParameterSetName='Status')][switch]$Status,
    [Parameter(ParameterSetName='Inspect')][switch]$Inspect,
    [Parameter(ParameterSetName='Manual',Mandatory=$true)][switch]$UpdateNow,
    [Parameter(ParameterSetName='Manual')][string]$PackagePath,
    [Parameter(ParameterSetName='Apply')][switch]$Quiet,
    [Parameter(ParameterSetName='Apply')][ValidateRange(0,30)][int]$DeferQualityDays=30
)
$ErrorActionPreference='Stop'
$WU='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AU=Join-Path $WU 'AU'
$MDM='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'
$WatchTask='EdgeBox-WindowsUpdate-Lock'
$WatchExe=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\WindowsPowerShell\v1.0\powershell.exe'
$osRegistry=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
try {
    $platform=$osRegistry.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion')
    try { $ProgramRoot=[string]$platform.GetValue('ProgramFilesDir') } finally { $platform.Dispose() }
} finally { $osRegistry.Dispose() }
$WatchRoot=Join-Path $ProgramRoot 'EdgeBox-WindowsUpdate-Lock'
$WatchFiles=@('12-windows-update.ps1','host-restart-policy.psm1','service-restart-policy.psm1','service-restart-policy.cs')
$RequiredAU=[ordered]@{NoAutoUpdate=1;AUOptions=2;NoAutoRebootWithLoggedOnUsers=1;AlwaysAutoRebootAtScheduledTime=0}
$LogFile=Join-Path $PSScriptRoot 'windows-update-lock.log'

function Write-UpdateLog([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
    try { Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'  '+$Message) } catch {}
}
function Read-UpdateKey([string]$Path) {
    try { Get-ItemProperty -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
}
function Set-UpdateValue([string]$Path,[string]$Name,$Value,[string]$Kind='DWord') {
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { $null=New-Item -Path $Path -Force -ErrorAction Stop }
    $null=New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Kind -Value $Value -Force -ErrorAction Stop
}
function Get-UpdateRestartTasks($Tasks) {
    $Tasks | Where-Object { $_.TaskPath -eq '\Microsoft\Windows\UpdateOrchestrator\' -and $_.TaskName -match 'reboot|restart' }
}
function Get-UpdateWatchVersion([string]$Directory) {
    $hashes=foreach ($name in $WatchFiles) {
        $entry=Get-Item -LiteralPath (Join-Path $Directory $name) -Force -ErrorAction Stop
        if ($entry -isnot [IO.FileInfo] -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "維持タスクのファイルを確認してください: $name" }
        (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::ASCII.GetBytes(($hashes -join ':'))))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Assert-UpdateWatchPath([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "維持タスクの配置先に再解析ポイントがあります: $Path" }
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $raw=[Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(),0)
    if ($null -eq $raw.DiscretionaryAcl) { throw "維持タスクの配置先にアクセス制御がありません: $Path" }
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw "維持タスクの配置先の所有者を確認してください: $Path" }
    # Includes GENERIC_ALL / GENERIC_WRITE and NTFS write, delete and security rights.
    $write=0x50000000 -bor [int][Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in $trusted) { continue }
        if ($rule.IdentityReference.Value -eq 'S-1-3-0' -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ([long]$rule.FileSystemRights -band $write) { throw "維持タスクの配置先に管理者以外の書込み権限があります: $Path" }
    }
}
function New-UpdateWatchDirectory([string]$Path) {
    if (-not [IO.Directory]::Exists($Path)) {
        $security=[Security.AccessControl.DirectorySecurity]::new()
        $admins=[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        $security.SetOwner($admins)
        $security.SetAccessRuleProtection($true,$false)
        foreach ($sid in @('S-1-5-32-544','S-1-5-18','S-1-5-32-545')) {
            $rights=if ($sid -eq 'S-1-5-32-545') {'ReadAndExecute'} else {'FullControl'}
            $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow')
            $security.AddAccessRule($rule)
        }
        $null=[IO.Directory]::CreateDirectory($Path,$security)
    }
    Assert-UpdateWatchPath $Path
}
function Test-UpdateWatchPayload {
    Assert-UpdateWatchPath $ProgramRoot
    foreach ($dir in @($WatchRoot,$WatchDirectory)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container -ErrorAction Stop)) { return $false }
        Assert-UpdateWatchPath $dir
    }
    foreach ($name in $WatchFiles) {
        $file=Join-Path $WatchDirectory $name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf -ErrorAction Stop)) { return $false }
        Assert-UpdateWatchPath $file
    }
    return (Get-UpdateWatchVersion $WatchDirectory) -eq $WatchVersion
}
function Install-UpdateWatchPayload([string]$Source=$PSScriptRoot) {
    if (Test-UpdateWatchPayload) { return }
    if ($Quiet) { throw '維持タスクの保護された実体を確認できません。手順12を管理者として再実行してください。' }
    New-UpdateWatchDirectory $WatchRoot
    # Publish a complete immutable version before switching the SYSTEM task.
    $stage=Join-Path $WatchRoot ('stage-'+[guid]::NewGuid().ToString('N'))
    New-UpdateWatchDirectory $stage
    try {
        Assert-UpdateWatchPath $stage
        foreach ($name in $WatchFiles) {
            $file=Join-Path $stage $name
            # Create a new file under the protected parent, inheriting its ACL.
            [IO.File]::WriteAllBytes($file,[IO.File]::ReadAllBytes((Join-Path $Source $name)))
            $acl=Get-Acl -LiteralPath $file -ErrorAction Stop
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            Set-Acl -LiteralPath $file -AclObject $acl -ErrorAction Stop
            Assert-UpdateWatchPath $file
        }
        if ((Get-UpdateWatchVersion $stage) -ne $WatchVersion) { throw '登録中に更新ポリシーのソースが変更されました。' }
        try { [IO.Directory]::Move($stage,$WatchDirectory) }
        catch [IO.IOException] { if (-not (Test-UpdateWatchPayload)) { throw } }
    } finally {
        if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($stage)) -eq $WatchRoot -and
            [IO.Path]::GetFileName($stage) -match '^stage-[0-9a-f]{32}$' -and [IO.Directory]::Exists($stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
        }
    }
    if (-not (Test-UpdateWatchPayload)) { throw '維持タスク用ファイルの整合性を確認できません。' }
}
function Test-UpdateWatchTask($Task) {
    if (-not $Task -or -not $Task.Settings.Enabled -or $Task.State -eq 'Disabled' -or
        $Task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18') -or
        $Task.Principal.RunLevel -notin @('Highest','1') -or $Task.Principal.LogonType -notin @('ServiceAccount','5') -or @($Task.Actions).Count -ne 1) { return $false }
    $action=@($Task.Actions)[0]
    $triggers=@($Task.Triggers | Where-Object Enabled)
    $boot=@($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
    $daily=@($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger' -and $_.DaysInterval -eq 1 })
    return ($action.Execute -eq $WatchExe -and $action.Arguments -eq $WatchArgs -and
        $boot.Count -gt 0 -and $daily.Count -gt 0)
}
function Get-UpdateLockState {
    $missing=@(); $blocked=@()
    try {
        $auValues=Read-UpdateKey $AU
        foreach ($key in $RequiredAU.Keys) {
            if ($null -eq $auValues.$key -or $auValues.$key -isnot [int] -or $auValues.$key -ne $RequiredAU[$key]) { $missing+="AU/$key" }
        }
        if (-not (Test-EdgeBoxCrashRestartBlocked)) { $missing+='CrashControl/AutoReboot' }
        $recovery=Get-EdgeBoxServiceRestartPolicy
        if (-not $recovery.Compliant) {
            if ($recovery.RebootServices) { $missing+='サービス障害時のホスト再起動: '+($recovery.RebootServices -join '、') }
            $review=@($recovery.UnreadableServices | Where-Object {$_})+@($recovery.Errors | Where-Object {$_})+@($recovery.ReviewTasks | Where-Object {$_})
            if ($review.Count) { $blocked+='サービス・予約タスクの確認が必要: '+($review -join '、') }
            if (-not $recovery.RebootServices -and -not $review.Count) { $blocked+='サービス障害時の設定を確認できません。' }
        }
        $service=Get-Service -Name wuauserv -ErrorAction Stop
        if ($service.StartType -ne 'Disabled') { $missing+='wuauserv の自動起動防止' }
        if ($service.Status -ne 'Stopped') { $missing+='wuauserv の停止' }
        $tasks=@(Get-ScheduledTask -ErrorAction Stop)
        $watch=@($tasks | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $WatchTask })
        if (-not (Test-UpdateWatchPayload)) { $missing+='管理者保護された維持タスク用ファイル' }
        if ($watch.Count -ne 1 -or -not (Test-UpdateWatchTask $watch[0])) { $missing+='維持タスクの実行先・SYSTEM・起動時/毎日トリガー' }
        foreach ($task in @(Get-UpdateRestartTasks $tasks)) {
            if ($task.State -ne 'Disabled') { $missing+='再起動タスク '+$task.TaskName }
        }
        $policy=Read-UpdateKey $WU
        foreach ($key in @('SetComplianceDeadline','SetComplianceDeadlineForQU','SetComplianceDeadlineForFU','SetAutoRestartDeadline','SetEngagedRestartTransitionSchedule')) {
            if ($policy.$key -eq 1) { $blocked+="GPO/$key" }
        }
        $mdmPolicy=Read-UpdateKey $MDM
        if ($null -ne $mdmPolicy.AllowAutoUpdate -and $mdmPolicy.AllowAutoUpdate -ne 5) { $blocked+='MDM/AllowAutoUpdate' }
        foreach ($key in @('ConfigureDeadlineForQualityUpdates','ConfigureDeadlineForFeatureUpdates','EngagedRestartDeadline','EngagedRestartDeadlineForFeatureUpdates','AutoRestartDeadlinePeriodInDays','AutoRestartDeadlinePeriodInDaysForFeatureUpdates')) {
            # A zero-day deadline is immediate, and must be reported.
            if ($null -ne $mdmPolicy.$key) { $blocked+="MDM/$key" }
        }
        foreach ($keyPath in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
            if (Test-Path -LiteralPath $keyPath -ErrorAction Stop) { $blocked+='Windows は再起動待ち'; break }
        }
    } catch { return [pscustomobject]@{State='Unknown';Detail=('再起動抑止の状態を照会できません。'+$_.Exception.Message)} }
    $details=@()
    if ($missing.Count) { $details+='未適用: '+($missing -join '、') }
    if ($blocked.Count) { $details+='保留: '+($blocked -join '、')+'。組織の更新期限・再起動予約を確認し、保守時に手動で対応してください。' }
    if ($missing.Count) { $state='NeedsWork' } elseif ($blocked.Count) { $state='Unknown' } else {
        $state='Done'; $details+='自動更新禁止・更新サービス停止・再起動タスク・維持タスクを確認しました。'
    }
    [pscustomobject]@{State=$state;Detail=($details -join ' ')}
}
function Register-UpdateWatch {
    $action=New-ScheduledTaskAction -Execute $WatchExe -Argument $WatchArgs
    $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Daily -At '12:00'))
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $WatchTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}
function Set-UpdateLock {
    $problems=@()
    foreach ($key in $RequiredAU.Keys) {
        try { Set-UpdateValue $AU $key $RequiredAU[$key] } catch { $problems+="AU/$key を設定できません。"+$_.Exception.Message }
    }
    $tasks=@()
    try {
        $tasks=@(Get-ScheduledTask -ErrorAction Stop)
        $watch=@($tasks | Where-Object { $_.TaskPath -eq '\' -and $_.TaskName -eq $WatchTask })
        if ($Quiet) {
            if ($watch.Count -ne 1 -or -not (Test-UpdateWatchTask $watch[0])) { throw '登録済みの維持タスクを確認してください。' }
        } else {
            Install-UpdateWatchPayload
            if ($watch.Count -ne 1 -or -not (Test-UpdateWatchTask $watch[0])) { Register-UpdateWatch }
        }
    } catch { $problems+='維持タスクの安全な登録に失敗しました。'+$_.Exception.Message }
    foreach ($task in @(Get-UpdateRestartTasks $tasks)) {
        if ($task.State -ne 'Disabled') {
            try { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null }
            catch { $problems+=$task.TaskName+' を無効化できません。'+$_.Exception.Message }
        }
    }
    try {
        $service=Get-Service -Name wuauserv -ErrorAction Stop
        if ($service.StartType -ne 'Disabled') { Set-Service -Name wuauserv -StartupType Disabled -ErrorAction Stop }
        if ($service.Status -ne 'Stopped') { Stop-Service -Name wuauserv -ErrorAction Stop }
    } catch { $problems+='Windows Update サービスを停止・無効化できません。'+$_.Exception.Message }
    if ($problems.Count) { throw ($problems -join ' ') }
}
function Invoke-ManualUpdate([string]$File) {
    if (-not $File) {
        Write-UpdateLog 'Microsoft Update カタログから対象機種・Windows の版に合う .msu を取得し、-UpdateNow -PackagePath <ファイル> を指定してください。'
        Start-Process 'https://www.catalog.update.microsoft.com/' -ErrorAction Stop
        return 0
    }
    $package=Get-Item -LiteralPath $File -ErrorAction Stop
    if ($package -isnot [IO.FileInfo] -or $package.Extension -ne '.msu') { throw 'Windows 11 用の .msu ファイルを 1 件指定してください。' }
    $result=Add-WindowsPackage -Online -PackagePath $package.FullName -NoRestart -PreventPending -ErrorAction Stop
    if ($result.RestartNeeded) { Write-UpdateLog 'パッケージを適用しました。作業を保存し、Edge Box の正常終了後に手動で再起動してください。'; return 3010 }
    Write-UpdateLog 'パッケージの適用が完了しました。'
    return 0
}

function Invoke-UpdateLockMode {
    $failures=@()
    try { Set-EdgeBoxCrashRestartPolicy } catch { $failures+=$_.Exception.Message }
    try { Set-UpdateLock } catch { $failures+=$_.Exception.Message }
    try {
        $servicePolicy=Set-EdgeBoxServiceRestartPolicy -PreviouslyVerifiedOnly:$Quiet
        $failures+=@($servicePolicy.Errors | Where-Object { $_ })
    } catch { $failures+=$_.Exception.Message }
    if ($failures.Count) { throw ($failures -join ' ') }
    if ($Restore) {
        $optional=Read-UpdateKey $WU
        foreach ($key in @('TargetReleaseVersion','TargetReleaseVersionInfo','ProductVersion','DeferQualityUpdates','DeferQualityUpdatesPeriodInDays','DeferFeatureUpdates','DeferFeatureUpdatesPeriodInDays')) {
            if ($null -ne $optional.$key) { Remove-ItemProperty -LiteralPath $WU -Name $key -ErrorAction Stop }
        }
        Write-UpdateLog '更新のバージョン固定と先送りを解除しました。自動再起動禁止は継続します。'
    } elseif (-not $Quiet -and -not $UpdateNow) {
        $version=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).DisplayVersion
        if ($version) {
            Set-UpdateValue $WU 'ProductVersion' 'Windows 11' 'String'
            Set-UpdateValue $WU 'TargetReleaseVersion' 1
            Set-UpdateValue $WU 'TargetReleaseVersionInfo' $version 'String'
        }
        Set-UpdateValue $WU 'DeferQualityUpdates' 1
        Set-UpdateValue $WU 'DeferQualityUpdatesPeriodInDays' $DeferQualityDays
        Set-UpdateValue $WU 'DeferFeatureUpdates' 1
        Set-UpdateValue $WU 'DeferFeatureUpdatesPeriodInDays' 365
    }
    $state=Get-UpdateLockState
    if ($state.State -ne 'Done') { throw $state.Detail }
    if ($UpdateNow) { return (Invoke-ManualUpdate $PackagePath) }
    Write-UpdateLog $state.Detail
    return 0
}

try {
    $WatchVersion=Get-UpdateWatchVersion $PSScriptRoot
    $WatchDirectory=Join-Path $WatchRoot $WatchVersion
    $WatchScript=Join-Path $WatchDirectory $WatchFiles[0]
    $WatchArgs='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$WatchScript+'" -Quiet'
    if ($Quiet) {
        $trustedQuiet=$PSCommandPath -eq $WatchScript -and (Test-UpdateWatchPayload)
        if (-not $trustedQuiet) { throw '維持タスクの配置先を確認できません。管理者として手順12を再実行してください。' }
        if (-not (Test-UpdateWatchTask (Get-ScheduledTask -TaskPath '\' -TaskName $WatchTask -ErrorAction Stop))) { throw '維持タスクの登録先が変わりました。旧版の実行を終了します。' }
    }
    Import-Module (Join-Path $PSScriptRoot 'host-restart-policy.psm1') -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'service-restart-policy.psm1') -ErrorAction Stop
    if ($Inspect -or $Status) {
        $state=Get-UpdateLockState
        if ($Inspect) { return $state }
        Write-Host $state.Detail
        if ($state.State -eq 'Done') { exit 0 }; exit 2
    }
    $principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '管理者として実行してください。' }
    $code=Invoke-UpdateLockMode
    exit $code
} catch {
    if ($Inspect) { return [pscustomobject]@{State='Unknown';Detail=$_.Exception.Message} }
    if ($Quiet -and -not $trustedQuiet) { Write-Warning $_.Exception.Message; exit 1 }
    if ($Status) { Write-Host $_.Exception.Message } else { Write-UpdateLog ('未完了: '+$_.Exception.Message) }
    exit 1
}
