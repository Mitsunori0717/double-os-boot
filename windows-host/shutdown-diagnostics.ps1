#requires -Version 5.1
param([ValidateRange(1,365)][int]$Days=90, [ValidateRange(1,30)][int]$Count=5)
$ErrorActionPreference='Stop'

function Read-ShutdownEvents([string]$Log, [int[]]$Ids, [datetime]$Since) {
    try {
        $info=Get-WinEvent -ListLog $Log -ErrorAction Stop
        if (-not $info.IsEnabled) { Write-Warning "$Log は無効です。"; return }
        $filter=@{LogName=$Log;Id=$Ids;StartTime=$Since}
        if ($Log -eq 'System') { $filter.ProviderName=@('User32','EventLog','Microsoft-Windows-Kernel-General','Microsoft-Windows-Kernel-Power') }
        Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return }
        $errorType=$_.Exception
        while ($errorType -and $errorType -isnot [UnauthorizedAccessException]) { $errorType=$errorType.InnerException }
        if ($errorType -or $_.CategoryInfo.Category -in @('PermissionDenied','SecurityError')) {
            Write-Warning "$Log の読み取り権限がありません。管理者の PowerShell で確認できます。"
        } else { Write-Warning "$Log を読み取れません。イベント ビューアーでログの状態を確認してください。" }
    }
}

function Get-HostShutdownIntervals($Events) {
    $sessions=@()
    $session=$null
    foreach ($e in ($Events | Sort-Object RecordId)) {
        if ($e.ProviderName -eq 'Microsoft-Windows-Kernel-General' -and $e.Id -eq 12) {
            $session=[pscustomobject]@{ Boot=$e.TimeCreated; Requests=@(); Ends=@(); Dirty=$false }
            $sessions+=$session
        } elseif ($session) {
            if ($e.ProviderName -eq 'User32' -and $e.Id -eq 1074) { $session.Requests+=$e.TimeCreated }
            if ($e.ProviderName -eq 'User32' -and $e.Id -in @(1073,1075)) { $session.Requests=@() }
            if ($e.ProviderName -eq 'Microsoft-Windows-Kernel-General' -and $e.Id -eq 13) { $session.Ends+=$e.TimeCreated }
            if (($e.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) -or
                ($e.ProviderName -eq 'EventLog' -and $e.Id -eq 6008)) { $session.Dirty=$true }
        }
    }
    for ($i=1;$i -lt $sessions.Count;$i++) {
        $previous=$sessions[$i-1];$next=$sessions[$i]
        if ($next.Dirty) {
            '{0:yyyy-MM-dd HH:mm:ss} 起動時に異常終了の記録（41/6008）があり、前回の終了時間は算出不可。' -f $next.Boot
            continue
        }
        if ($previous.Ends.Count -ne 1) {
            '{0:yyyy-MM-dd HH:mm:ss} 次回起動。前回のカーネル終了記録（13）を一意に確認できません。' -f $next.Boot
            continue
        }
        $end=$previous.Ends[0]
        if ($end.ToUniversalTime() -lt $previous.Boot.ToUniversalTime() -or $end.ToUniversalTime() -gt $next.Boot.ToUniversalTime()) {
            '{0:yyyy-MM-dd HH:mm:ss} 起動・終了時刻の順序が一致せず、時間を算出できません。' -f $next.Boot
            continue
        }
        $requestText='終了要求（1074）がないか複数あり、要求から終了までの時間は算出不可'
        if ($previous.Requests.Count -eq 1 -and $previous.Requests[0].ToUniversalTime() -ge $previous.Boot.ToUniversalTime() -and
            $previous.Requests[0].ToUniversalTime() -le $end.ToUniversalTime()) {
            $request=$previous.Requests[0]
            $requestText='終了要求 {0:yyyy-MM-dd HH:mm:ss} → カーネル終了まで {1:N1} 秒' -f $request,($end.ToUniversalTime()-$request.ToUniversalTime()).TotalSeconds
        }
        '{0}。カーネル終了 {1:yyyy-MM-dd HH:mm:ss} → 次回起動 {2:yyyy-MM-dd HH:mm:ss}（{3:N1} 秒）' -f $requestText,$end,$next.Boot,($next.Boot.ToUniversalTime()-$end.ToUniversalTime()).TotalSeconds
    }
}

function Get-ShutdownEventFields($Event) {
    $fields=@{}
    $xml=[xml]$Event.ToXml()
    foreach ($node in $xml.Event.EventData.Data) { $fields[$node.GetAttribute('Name')]=$node.InnerText }
    $fields
}

function Format-ShutdownPhase($Event) {
    $fields=Get-ShutdownEventFields $Event
    $timeKey=if ($Event.Id -eq 200) { 'ShutdownStartTime' } else { 'StartTime' }
    $at=[DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($fields[$timeKey],[Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$at)) { return }
    $stamp=$at.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
    if ($Event.Id -eq 200) {
        $labels=[ordered]@{ShutdownTime='全体';ShutdownUserSessionTime='ユーザーセッション';ShutdownSystemSessionsTime='システムセッション';
            ShutdownPreShutdownNotificationsTime='サービスへの終了事前通知';ShutdownServicesTime='サービス終了';ShutdownKernelTime='カーネル'}
        $parts=@(foreach ($key in $labels.Keys) {
            if ($fields[$key] -match '^\d+$') { '{0} {1:N1}秒' -f $labels[$key],([double]$fields[$key]/1000) }
        })
        if ($parts.Count) { "$stamp  終了開始（200）  " + ($parts -join '、') }
    } elseif ($Event.Id -eq 203 -and $fields.TotalTime -match '^\d+$') {
        $service=[string]$fields.Name
        if ($service -notmatch '^[a-zA-Z0-9_.-]{1,128}$') { $service='（名前の表示を省略）' }
        $extra=if ($fields.DegradationTime -match '^\d+$') { '、基準超過 {0:N1}秒' -f ([double]$fields.DegradationTime/1000) } else { '' }
        '{0}  サービス遅延（203） {1}  所要 {2:N1}秒{3}' -f $stamp,$service,([double]$fields.TotalTime/1000),$extra
    }
}

function Get-GuestShutdownTimes($Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (Edge Box の停止を確認|開始から Windows 終了要求直前まで|Edge Box の終了完了: 開始から):? ([\d.,]+) 秒\s*$') {
            '{0}  {1} {2} 秒' -f $Matches[1],$Matches[2],$Matches[3]
        }
    }
}

$since=(Get-Date).AddDays(-$Days)
Write-Output "Windows の終了要求・カーネル終了・次回起動（過去 $Days 日、現地時刻）"
$system=@(Read-ShutdownEvents 'System' @(12,13,41,1073,1074,1075,6008) $since)
$intervals=@(Get-HostShutdownIntervals $system | Select-Object -Last $Count)
if ($intervals.Count) { $intervals } else { '対象期間に対応する起動・終了記録がありません。' }
'終了から次回起動までの区間には、電源が切れていた時間も含みます。'

'Windows の終了フェーズと遅延サービス（イベント内の開始時刻。各フェーズは重複する場合があります）'
$details=@(Read-ShutdownEvents 'Microsoft-Windows-Diagnostics-Performance/Operational' @(200,203) $since)
foreach ($id in @(200,203)) {
    $rows=@($details | Where-Object Id -eq $id | Sort-Object TimeCreated -Descending | Select-Object -First $Count | ForEach-Object { Format-ShutdownPhase $_ })
    if ($rows.Count) { $rows } else { "表示できるイベント $id はありません。" }
}

'Edge Box の停止操作（手元の shutdown-log.txt に記録された直近の実測）'
$path=Join-Path $PSScriptRoot 'shutdown-log.txt'
try {
    if (Test-Path -LiteralPath $path) {
        $guest=@(Get-GuestShutdownTimes (Get-Content -LiteralPath $path -Encoding UTF8 -Tail 1000) | Select-Object -Last $Count)
        if ($guest.Count) { $guest } else { '直近のログに計測値がありません。' }
    } else { '停止操作のログがありません。' }
} catch { Write-Warning '停止操作のログを読み取れません。ファイルの読み取り権限を確認してください。' }
