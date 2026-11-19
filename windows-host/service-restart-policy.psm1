#requires -Version 5.1
function Initialize-ServiceRecoveryApi {
    if (-not ('EdgeBox.ServiceRecovery' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'service-restart-policy.cs') -ErrorAction Stop
    }
}

function Get-RecoveryServiceNames {
    Get-CimInstance -ClassName Win32_Service -Property Name -ErrorAction Stop | Select-Object -ExpandProperty Name
}
function Read-RecoveryService([string]$Name) {
    [EdgeBox.ServiceRecovery]::Read($Name)
}
function Set-RecoveryService([string]$Name, $State) {
    [EdgeBox.ServiceRecovery]::ReplaceReboots($Name, $State)
}

function Test-DedicatedLocalRestartTask($Task) {
    if (@($Task.Actions).Count -ne 1) { return $false }
    $action=$Task.Actions[0]
    $program=[Environment]::ExpandEnvironmentVariables(([string]$action.Execute).Trim('"'))
    if ($program -ne (Join-Path $env:SystemRoot 'System32\shutdown.exe')) { return $false }
    # Only the local restart verb and optional numeric timeout/force flags. Wrappers and remote targets require review.
    $arguments=([string]$action.Arguments).Trim()
    return $arguments -match '^(?:[/-](?:r|g|sg))(?=\s|$)(?:\s+[/-]f|\s+[/-]t\s+\d+)*$'
}

function Get-StableTaskDefinition([string]$Xml) {
    [xml]$definition=$Xml
    if ($definition.DocumentElement.LocalName -ne 'Task') { throw 'タスク定義 XML を確認できません。' }
    # Registration may refresh its timestamp. All actions, principals, settings and trigger schedules must remain identical.
    $ignore="/*[local-name()='Task']/*[local-name()='Triggers']/*/*[local-name()='Enabled'] | /*[local-name()='Task']/*[local-name()='RegistrationInfo']/*[local-name()='Date']"
    foreach ($node in @($definition.SelectNodes($ignore))) { [void]$node.ParentNode.RemoveChild($node) }
    $definition.DocumentElement.OuterXml
}

function Disable-ServicePolicyTaskTriggers($Task, [switch]$PreviouslyVerifiedOnly) {
    $arguments=@{ TaskPath=$Task.TaskPath; TaskName=$Task.TaskName; ErrorAction='Stop' }
    $original=[string](Export-ScheduledTask @arguments)
    $name=$Task.TaskPath+$Task.TaskName
    if ($PreviouslyVerifiedOnly -and -not (Test-PolicyApproval 'Task' $name $original)) {
        throw 'このタスクの登録内容は手順12で確認されていません。明示適用が必要です。'
    }
    $fresh=@(Get-ScheduledTask @arguments | Where-Object { $_.TaskPath -eq $Task.TaskPath -and $_.TaskName -eq $Task.TaskName })
    if ($fresh.Count -ne 1 -or -not (Test-DedicatedLocalRestartTask $fresh[0])) { throw 'タスクの再起動アクションが変更されました。' }
    if (-not $fresh[0].Settings.Enabled) { return }
    $enabled=@($fresh[0].Triggers | Where-Object { $_ -and $_.Enabled -ne $false })
    if (-not $enabled.Count) { return }
    if ([string](Export-ScheduledTask @arguments) -cne $original) { throw 'タスク登録が変更されました。' }
    if (-not $PreviouslyVerifiedOnly) { Save-PolicyBackup 'TaskTriggerBackup' $name $original }
    foreach ($trigger in $enabled) { $trigger.Enabled=$false }
    Set-ScheduledTask @arguments -Trigger $fresh[0].Triggers | Out-Null
    $result=@(Get-ScheduledTask @arguments | Where-Object { $_.TaskPath -eq $Task.TaskPath -and $_.TaskName -eq $Task.TaskName })
    if ((Get-StableTaskDefinition ([string](Export-ScheduledTask @arguments))) -cne (Get-StableTaskDefinition $original) -or
        $result.Count -ne 1 -or -not $result[0].Settings.Enabled -or
        -not (Test-DedicatedLocalRestartTask $result[0]) -or
        $result[0].Settings.AllowDemandStart -ne $Task.Settings.AllowDemandStart -or
        @($result[0].Triggers).Count -ne @($fresh[0].Triggers).Count -or
        @($result[0].Triggers | Where-Object { $_ -and $_.Enabled -ne $false }).Count) {
        throw 'トリガー停止後の登録内容を照合できません。'
    }
    if (-not $PreviouslyVerifiedOnly) { Save-PolicyBackup 'ApprovedTask' $name $original }
}

function Get-AutomaticRestartTaskReview([switch]$Apply, [switch]$PreviouslyVerifiedOnly, $TaskErrors) {
    foreach ($task in Get-ScheduledTask -ErrorAction Stop) {
        if (-not $task.Settings.Enabled -or -not @($task.Triggers | Where-Object { $_ -and $_.Enabled -ne $false }).Count) { continue }
        foreach ($action in $task.Actions) {
            $command=([string]$action.Execute).Trim('"')
            $program=[IO.Path]::GetFileName($command)
            $arguments=[string]$action.Arguments
            $name=$task.TaskPath+$task.TaskName
            # PnP's documented task displays a user notification. Its COM handler does not request a restart.
            if ($name -eq '\Microsoft\Windows\Plug and Play\Device Install Reboot Required' -and
                [string]$action.ClassId -eq '{48794782-6A1F-47B9-BD52-1D5F95D49C1B}') { continue }
            if ($program -match '^shutdown(?:\.exe)?$' -and $arguments -match '(?:^|\s)[/-](?:r|g|sg)(?=\s|$)' -and
                $arguments -notmatch '(?:^|\s)[/-]m(?=\s|$)') {
                if ($Apply -and (Test-DedicatedLocalRestartTask $task)) {
                    try { Disable-ServicePolicyTaskTriggers $task -PreviouslyVerifiedOnly:$PreviouslyVerifiedOnly; break }
                    catch { $TaskErrors.Add($name+' — '+$_.Exception.GetBaseException().Message) }
                }
                $name; break
            }
            if ($task.TaskName -match '(?i)reboot|restart|再起動' -or
                "$program $arguments" -match '(?i)Restart-Computer|Win32Shutdown|RestartDevice|Restart-WUComputer|reboot') { $name; break }
        }
    }
}

function ConvertTo-RecoveryRecord($State, [switch]$WithoutReboot) {
    $types=@(foreach ($type in $State.Types) { if ($WithoutReboot -and $type -eq 2) { 1 } else { [int]$type } })
    [ordered]@{ResetPeriod=[uint32]$State.ResetPeriod;ServiceIdentityDigest=[string]$State.ServiceIdentityDigest;Types=$types;Delays=@([uint32[]]$State.Delays);MessageAndCommandDigest=[string]$State.MessageAndCommandDigest} | ConvertTo-Json -Depth 4 -Compress
}

function Assert-PolicyApprovalAccess($Key) {
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $acl=$Key.GetAccessControl()
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw '承認状態のレジストリ所有者を確認できません。' }
    $write=[Security.AccessControl.RegistryRights]'SetValue, CreateSubKey, Delete, ChangePermissions, TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted -and
            -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
            ($rule.RegistryRights -band $write)) { throw '管理者以外が承認状態を書き換えられるため保留します。' }
    }
}

function Test-PolicyApproval([string]$Kind, [string]$Name, [string]$Original) {
    $root=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\EdgeBox')
    if (-not $root) { return $false }
    try {
        Assert-PolicyApprovalAccess $root
        $key=$root.OpenSubKey('Approved'+$Kind)
        if (-not $key) { return $false }
        try {
            Assert-PolicyApprovalAccess $key
            return ($key.GetValue($Name,$null) -ceq $Original)
        } finally { $key.Dispose() }
    } finally { $root.Dispose() }
}

function Save-PolicyBackup([string]$Category, [string]$Name, [string]$Record) {
    # HKLM is local to this installation. Never overwrite an earlier baseline.
    $root=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\EdgeBox')
    try {
        Assert-PolicyApprovalAccess $root
        $parent=$root.CreateSubKey($Category)
    } finally { $root.Dispose() }
    try {
        Assert-PolicyApprovalAccess $parent
        $existing=$parent.GetValue($Name,$null)
        if ($null -ne $existing -and $existing -cne $Record) { throw '保存済みの回復設定と現在の設定が異なります。' }
        if ($null -eq $existing) { $parent.SetValue($Name,$Record,[Microsoft.Win32.RegistryValueKind]::String); $parent.Flush() }
        if ($parent.GetValue($Name,$null) -cne $Record) { throw '回復設定のバックアップを確認できません。' }
    } finally { $parent.Dispose() }
}

function Invoke-ServiceRestartPolicy([switch]$Apply, [switch]$PreviouslyVerifiedOnly) {
    $reboot=New-Object 'System.Collections.Generic.List[string]'
    $unreadable=New-Object 'System.Collections.Generic.List[string]'
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $review=@()
    try { Initialize-ServiceRecoveryApi; $services=@(Get-RecoveryServiceNames) }
    catch { $services=@(); $errors.Add('サービス一覧: '+$_.Exception.Message) }
    if (-not $services.Count -and -not $errors.Count) { $errors.Add('サービス一覧が空です。') }
    foreach ($name in $services) {
        try { $state=Read-RecoveryService $name }
        catch { $unreadable.Add($name); continue }
        if (3 -in $state.Types) { $errors.Add($name+' — 障害時の外部コマンドがホストを再起動するか確認してください。') }
        if (2 -notin $state.Types) { continue }
        if ($Apply) {
            try {
                $original=ConvertTo-RecoveryRecord $state
                if ($PreviouslyVerifiedOnly) {
                    if (-not (Test-PolicyApproval 'Service' $name $original)) { throw 'このサービス構成は手順12で確認されていません。明示適用が必要です。' }
                } else { Save-PolicyBackup 'ServiceRecoveryBackup' $name $original }
                Set-RecoveryService $name $state
                $result=Read-RecoveryService $name
                if ((ConvertTo-RecoveryRecord $result) -cne (ConvertTo-RecoveryRecord $state -WithoutReboot)) {
                    throw '変更後の回復アクション・遅延・リセット期間を照合できません。'
                }
                if (-not $PreviouslyVerifiedOnly) { Save-PolicyBackup 'ApprovedService' $name $original }
                continue
            } catch { $errors.Add($name+' — '+$_.Exception.GetBaseException().Message) }
        }
        $reboot.Add($name)
    }
    try { $review=@(Get-AutomaticRestartTaskReview -Apply:$Apply -PreviouslyVerifiedOnly:$PreviouslyVerifiedOnly -TaskErrors $errors | Sort-Object -Unique) }
    catch { $errors.Add('自動タスク一覧: '+$_.Exception.Message) }
    [pscustomobject]@{
        Compliant=($reboot.Count -eq 0 -and $unreadable.Count -eq 0 -and $errors.Count -eq 0 -and $review.Count -eq 0)
        RebootServices=$reboot.ToArray(); UnreadableServices=$unreadable.ToArray()
        Errors=$errors.ToArray(); ReviewTasks=$review
    }
}

function Get-EdgeBoxServiceRestartPolicy { Invoke-ServiceRestartPolicy }

function Set-EdgeBoxServiceRestartPolicy([switch]$PreviouslyVerifiedOnly) {
    # Separate invocations must not write different original values to the same backup.
    $mutex=[Threading.Mutex]::new($false, 'Global\EdgeBox-ServiceRecoveryPolicy')
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'ほかのサービス回復ポリシー適用が進行中です。' }
        Invoke-ServiceRestartPolicy -Apply -PreviouslyVerifiedOnly:$PreviouslyVerifiedOnly
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

Export-ModuleMember -Function Get-EdgeBoxServiceRestartPolicy,Set-EdgeBoxServiceRestartPolicy
