function Assert-EdgeBoxCpuTool([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne 'Microsoft Corporation') {
        throw "A valid Microsoft Corporation signature is required for CpuGroups.exe: $Path"
    }
}

function Resolve-EdgeBoxVmGroupId([string]$Output, [guid]$VMId) {
    $guidPattern = '[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    $groups = @(foreach ($line in ($Output -split '\r?\n')) {
        if ($line -match ('(?:^|\s)(' + $guidPattern + ')\s+(' + $guidPattern + ')\s*$') -and
            $Matches[1] -eq $VMId.ToString('D')) { $Matches[2].ToLowerInvariant() }
    })
    if ($groups.Count -eq 1) { return $groups[0] }
    return ''
}

function Resolve-EdgeBoxCpuGroup([string]$Output, [guid]$GroupId) {
    if ($Output -notmatch '(?m)^\s*CpuGroupId\s+CpuCap\s+LpIndexes\s*$') {
        throw 'CPU グループの LP 一覧を確認できません。CpuGroups.exe GetGroups の結果を確認してください。'
    }
    $id = [regex]::Escape($GroupId.ToString('D'))
    $rows = @(foreach ($line in ($Output -split '\r?\n')) {
        if ($line -notmatch $id) { continue }
        if ($line -notmatch ('^\s*' + $id + '\s+\d+\s+(\d+(?:\s*,\s*\d+)*)\s*$')) {
            throw 'CPU グループの LpIndexes を解析できません。CpuGroups.exe GetGroups の結果を確認してください。'
        }
        $lps = @($Matches[1] -split ',' | ForEach-Object { [int]$_.Trim() })
        if (@($lps | Sort-Object -Unique).Count -ne $lps.Count) { throw 'CPU グループの LpIndexes が重複しています。' }
        [pscustomobject]@{ Exists = $true; Lps = @($lps | Sort-Object) }
    })
    if ($rows.Count -gt 1) { throw '同一 ID の CPU グループが複数報告されています。' }
    if ($rows.Count -eq 1) { return $rows[0] }
    return [pscustomobject]@{ Exists = $false; Lps = @() }
}

function Get-EdgeBoxHypervisorLpCount([int]$Visible) {
    $counters = @(Get-CimInstance -ClassName Win32_PerfRawData_HvStats_HyperVHypervisorLogicalProcessor -Property Name -ErrorAction Stop)
    $ids = @(foreach ($counter in $counters) {
        if ($counter.Name -eq '_Total') { continue }
        if ($counter.Name -notmatch '^Hv LP (\d+)$') { throw 'Hyper-V の論理 CPU 番号を読み取れません。' }
        [int]$Matches[1]
    })
    if ($ids.Count -lt $Visible -or -not $ids.Count -or
        (Compare-Object ($ids | Sort-Object) @(0..($ids.Count-1)))) {
        throw 'Hyper-V の論理 CPU 一覧を確認できません。ハイパーバイザーのパフォーマンスカウンターを確認してください。'
    }
    return $ids.Count
}

function Save-EdgeBoxCpuSnapshot([string]$Path, [string]$CpuName, [object[]]$Cores) {
    if ([string]::IsNullOrWhiteSpace($CpuName) -or -not $Cores.Count) { throw 'CPU 名とコア構成を確認できません。' }
    $snapshot = [ordered]@{
        Cpu = $CpuName.Trim()
        Cores = @($Cores | ForEach-Object { [ordered]@{ Eff=[int]$_.Eff; Lps=@([int[]]$_.Lps) } })
    }
    Write-EdgeBoxCpuJson $Path $snapshot
}

function Write-EdgeBoxCpuJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 4), [Text.Encoding]::UTF8)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Enter-EdgeBoxCpuPlanLock {
    $mutex = [Threading.Mutex]::new($false, 'Global\EdgeBoxCpuPartitionFull')
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(45)) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'CPU 計画を別の処理が適用中です。少し待ってから再実行してください。' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Get-EdgeBoxCpuHostBootId {
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime -ErrorAction Stop).LastBootUpTime
    if (-not ($boot -is [datetime])) { throw '今回の Windows 起動時刻を確認できないため Edge Box の自動起動を保留しました。' }
    return $boot.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Set-EdgeBoxManualCpuStop($VM) {
    $path = Join-Path $PSScriptRoot 'cpu-partition.json'
    $mutex = Enter-EdgeBoxCpuPlanLock
    try {
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return }
        $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($config.Mode -notin @('runtime','full') -or -not $config.VMName) { throw 'CPU 計画の対象 VM と方式を確認できません。' }
        if ($config.Mode -ne 'full' -or $config.VMName -ne $VM.Name) { return }
        if (-not $VM.Id -or ($config.VMId -and [string]$VM.Id -ne [string]$config.VMId)) { throw '停止対象の VM ID が CPU 計画と一致しません。' }
        $current = @(Get-VM -Id $VM.Id -ErrorAction Stop)
        if ($current.Count -ne 1 -or $current[0].Name -ne $VM.Name -or $current[0].Id -ne $VM.Id) { throw '停止対象の VM を確認できません。' }
        $config | Add-Member NoteProperty VMId ([string]$VM.Id) -Force
        $config | Add-Member NoteProperty ManualStopBootId (Get-EdgeBoxCpuHostBootId) -Force
        Write-EdgeBoxCpuJson $path $config
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

Export-ModuleMember -Function Assert-EdgeBoxCpuTool,Resolve-EdgeBoxVmGroupId,Resolve-EdgeBoxCpuGroup,Get-EdgeBoxHypervisorLpCount,Save-EdgeBoxCpuSnapshot,Write-EdgeBoxCpuJson,Enter-EdgeBoxCpuPlanLock,Get-EdgeBoxCpuHostBootId,Set-EdgeBoxManualCpuStop
