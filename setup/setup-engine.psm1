#requires -Version 5.1
# 判定と実行を分離する。進捗の記録を「設定済み」の根拠にしない。
$script:Root = Split-Path $PSScriptRoot -Parent
$script:TaskName = 'EdgeBox-Setup-Resume'
$script:RunDir = $null
$script:Settings = @{}
$script:ResumeMode = $false
$script:SettingsLoadError = ''

function Get-SetupSteps {
    @(
        @{ Id='02'; Name='Hyper-V'; Batch='02-enable-hyperv.cmd'; Depends=@(); Help='Windows 11 Pro/Enterprise/Education、BIOS の仮想化を確認。再起動後に再実行してください。' },
        @{ Id='05'; Name='Edge Box の作成・接続'; Batch='05-create-edgebox.cmd'; Depends=@('02'); Help='Edge Box の物理ディスクとライン側 LAN を確認。候補が複数なら表示された番号を選択。使用中の別 VM の接続は自動で外しません。' },
        @{ Id='06'; Name='自動サインイン'; Batch='06-auto-logon.cmd'; Depends=@(); Help='Windows のアカウントとパスワード（PIN ではありません）を確認し、このバッチを再実行。パスワードはログや JSON に保存しません。' },
        @{ Id='09'; Name='自動起動・左画面表示'; Batch='09-install-autostart.cmd'; Depends=@('02','05'); Help='05 の VM 作成を完了してください。タスクの実行先・ユーザー・CPU 起動タスクとの整合をこのバッチで修復します。' },
        @{ Id='10'; Name='CPU の完全分離'; Batch='10-partition-cpu.cmd'; Depends=@('02','05'); Help='再起動待ちなら PC を再起動。tools\\CpuGroups.exe と cpu-partition-log.txt を確認。コア不足・構成不明なら「CPU割り当て」で計画を選んで適用後、再実行してください。' },
        @{ Id='11'; Name='操作アイコン'; Batch='11-install-shortcuts.cmd'; Depends=@('02'); Help='一式の配置先とログオン中のユーザーを確認。この番号を再実行すると不足・古いリンクを修復します。' },
        @{ Id='12'; Name='Windows Update の自動再起動抑止'; Batch='12-windows-update.cmd'; Depends=@(); Help='管理者権限と組織の更新ポリシーを確認。詳細は windows-update-lock.log。手動更新は 12-windows-update.ps1 -UpdateNow。' },
        @{ Id='13'; Name='通知・スリープの抑止'; Batch='13-quiet-windows.cmd'; Depends=@(); Help='組織のポリシーと電源設定を確認。13-quiet-windows.ps1 -Status でも確認できます。' }
    )
}
function New-SetupState([string]$State, [string]$Detail) {
    [pscustomobject]@{ State=$State; Detail=$Detail }
}
function Test-SetupAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Read-SetupJson([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
}
function Get-SetupBootId { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') }
function Get-SetupTask([string]$Name) {
    # 一覧取得の権限エラーを「タスクなし」と誤判定しない。
    @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $Name -and $_.TaskPath -eq '\' }) | Select-Object -First 1
}
function Test-SetupTask([string]$Name, [string]$Script, [string]$Argument = '', [switch]$Logon) {
    $t = Get-SetupTask $Name
    if (-not $t -or -not $t.Settings.Enabled -or [string]$t.Principal.RunLevel -notin @('Highest','1')) { return $false }
    $a = @($t.Actions | Where-Object {
        ([string]$_.Arguments).IndexOf((Join-Path $script:Root $Script), [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        (-not $Argument -or ([string]$_.Arguments).Contains($Argument))
    })
    if (-not $a.Count) { return $false }
    if ($Logon) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $tr = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.Enabled })
        $matching = @($tr | Where-Object {
            $u = [string]$_.UserId
            $u -eq $sid -or $u -eq $env:USERNAME -or $u -eq "$env:USERDOMAIN\$env:USERNAME"
        })
        if (-not $matching.Count) { return $false }
    }
    return $true
}
function Get-SetupVM {
    $all = @(Get-VM -ErrorAction Stop)
    if ($script:Settings.VMName) { return ($all | Where-Object Name -eq $script:Settings.VMName | Select-Object -First 1) }
    $named = @($all | Where-Object Name -eq 'EdgeBox')
    if ($named.Count) { return $named[0] }
    $found = @($all | Where-Object { @(Get-VMHardDiskDrive -VMName $_.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber }).Count -gt 0 })
    if ($found.Count -gt 1) { throw '物理ディスクを使う VM が複数あります。settings.json の VMName に対象を指定してください。' }
    if ($found.Count -eq 1) { return $found[0] }
}
function Get-SetupCpuConfig { Read-SetupJson (Join-Path $script:Root 'windows-cpu-partition\cpu-partition.json') }
function Get-SetupBcd {
    $out = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'BCD を読めません。管理者として再実行してください。' }
    $n=0; $s=''
    if ($out -match '(?m)^\s*hypervisorrootproc\s+(\S+)') { $n=[Convert]::ToInt32($Matches[1], $(if ($Matches[1] -match '^0x') {16} else {10})) }
    if ($out -match '(?m)^\s*hypervisorschedulertype\s+(\S+)') { $s=$Matches[1].ToLowerInvariant() }
    [pscustomobject]@{ RootProc=$n; Scheduler=$s }
}
function Get-SetupScheduler {
    $ev = Get-WinEvent -FilterHashtable @{ProviderName='Microsoft-Windows-Hyper-V-Hypervisor';Id=2} -MaxEvents 1 -ErrorAction Stop
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    if ($ev.TimeCreated -lt $boot.AddSeconds(-5)) { throw '今回の起動の Hyper-V イベントを確認できません。' }
    switch ([int]$ev.Properties[0].Value) { 1 {'classic'} 2 {'classic'} 3 {'core'} 4 {'root'} default {'unknown'} }
}
function Get-SetupCpuState {
    $cfg = Get-SetupCpuConfig
    if (-not $cfg -or $cfg.Mode -ne 'full') { return (New-SetupState NeedsWork '完全分離が未設定です。既存の割り当てがあれば引き継ぎます。') }
    $vm = Get-SetupVM
    if (-not $vm -or $cfg.VMName -ne $vm.Name) { return (New-SetupState NeedsWork 'CPU 計画の VM と実際の対象が一致していません。') }
    $bootTask = Test-SetupTask 'CpuPartition-Boot' 'windows-cpu-partition\cpu-partition.ps1' '-BootApply'
    $bcd = Get-SetupBcd
    $expected = if ($cfg.Scheduler) { [string]$cfg.Scheduler } else { 'core' }
    if ($bcd.RootProc -ne @($cfg.HostLps).Count -or $bcd.Scheduler -ne $expected -or -not $bootTask) {
        return (New-SetupState NeedsWork 'BCD または CPU 起動タスクが計画と一致していません。')
    }
    $sched = Get-SetupScheduler
    $p = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    $cores = ($p | Measure-Object NumberOfCores -Sum).Sum
    $lps = ($p | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    # cpu-partition.ps1 の Get-CpuTopology と同じ判定（混成コアの端数も含む）。
    $smt=1
    if ($cores -gt 0 -and ($lps % $cores) -eq 0) { $smt=[int]($lps/$cores) }
    $schedOk = $sched -eq $expected -or ($expected -eq 'core' -and $sched -eq 'classic' -and $smt -eq 1)
    if ([Environment]::ProcessorCount -ne $bcd.RootProc -or -not $schedOk) {
        return (New-SetupState RebootRequired 'BCD は設定済みですが、現在の CPU 数・スケジューラに反映されていません。')
    }
    $st = Read-SetupJson (Join-Path $script:Root 'windows-cpu-partition\cpu-full-status.json')
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    # 古い Bound=true を信用しない。現在の起動の状態と CPU グループを読み取りで照合する。
    $fresh = $st -and $st.At -and ([datetime]$st.At -ge $boot.AddSeconds(-5)) -and $st.MinrootOk -and $st.Bound
    $exe = Join-Path $script:Root 'windows-cpu-partition\tools\CpuGroups.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return (New-SetupState NeedsWork 'CpuGroups.exe がありません。') }
    $group = & $exe GetVmGroup ("/VmName:" + $vm.Name) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $group -notmatch '(?i)b0edb0ed-c01e-4a11-8000-0000000000e1' -or -not $fresh) {
        return (New-SetupState NeedsWork 'CPU 固定の現在の成立を確認できません。cpu-full-status.json と CPU グループを再確認します。')
    }
    if ($cfg.ManageVmStart -and [string]$vm.AutomaticStartAction -ne 'Nothing') { return (New-SetupState NeedsWork 'CPU 固定前に VM が起動する設定です。起動順を修復します。') }
    New-SetupState Done '今回の起動で Windows の CPU 制限と Edge Box の CPU グループ所属を確認しました。'
}
function Get-SetupStepState([string]$Id) {
    try {
        if (-not (Test-SetupAdmin)) { return (New-SetupState Unknown '管理者権限がないため確認できません。未設定とは判定しません。') }
        if ($script:SettingsLoadError -and $Id -in @('05','09','10')) { return (New-SetupState Unknown $script:SettingsLoadError) }
        switch ($Id) {
            '02' {
                $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
                if ([string]$f.State -match 'Pending') { return (New-SetupState RebootRequired ('Windows 機能の状態: ' + $f.State)) }
                if ([string]$f.State -ne 'Enabled') { return (New-SetupState NeedsWork ('Windows 機能の状態: ' + $f.State)) }
                if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return (New-SetupState NeedsWork 'Hyper-V の PowerShell 管理機能がありません。') }
                if (-not (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent) { return (New-SetupState RebootRequired 'Hyper-V が起動していません。BIOS の仮想化と BCD を確認してください。') }
                if ((Get-Service vmms -ErrorAction Stop).Status -ne 'Running') { return (New-SetupState NeedsWork 'Hyper-V 管理サービスが停止しています。') }
                $null = @(Get-VM -ErrorAction Stop)
                return (New-SetupState Done 'Hyper-V の機能・サービス・管理 API が利用できます。')
            }
            '05' {
                $vm = Get-SetupVM
                if (-not $vm) { return (New-SetupState NeedsWork 'Edge Box の VM がありません。') }
                $d = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber })
                if ($d.Count -ne 1) { return (New-SetupState NeedsWork '物理ディスクが未接続、または複数接続されています。') }
                $disk = Get-Disk -Number $d[0].DiskNumber -ErrorAction Stop
                if ($disk.IsBoot -or $disk.IsSystem -or -not $disk.IsOffline) { return (New-SetupState NeedsWork '対象ディスクが Windows と共有されているか、オフラインではありません。') }
                $net = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction Stop | Where-Object { $_.SwitchName })
                $ext = @($net | ForEach-Object { Get-VMSwitch -Name $_.SwitchName -ErrorAction Stop } | Where-Object SwitchType -eq External)
                if (-not $ext.Count) { return (New-SetupState NeedsWork 'ライン側の外部スイッチへ未接続です。') }
                if ([string](Get-VMFirmware -VMName $vm.Name -ErrorAction Stop).SecureBoot -ne 'Off' -or [string]$vm.AutomaticStopAction -ne 'ShutDown' -or [string]$vm.CheckpointType -ne 'Disabled') {
                    return (New-SetupState NeedsWork 'セキュアブート・チェックポイント・正常終了の設定に不足があります。')
                }
                return (New-SetupState Done ("登録 '$($vm.Name)' の物理ディスクと外部 LAN、正常終了設定を確認しました。"))
            }
            '06' {
                $w = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
                if ($w.AutoAdminLogon -eq '1' -and $w.DefaultUserName) { return (New-SetupState Done '自動サインインの登録あり。実際のサインイン成功は次回起動時に確認してください。') }
                return (New-SetupState NeedsWork '自動サインインは未登録です。初回だけパスワード入力が必要です。')
            }
            '09' {
                $vm=Get-SetupVM; $cfg=Get-SetupCpuConfig
                $main=Test-SetupTask 'EdgeBox-Display-Kiosk' 'windows-host\03-field-display-kiosk.ps1' ("-VMName `""+$vm.Name+'"') -Logon
                $t=Get-SetupTask 'EdgeBox-Display-Kiosk-Splash'
                $cover=& (Join-Path $script:Root 'windows-host\build-startup-cover.ps1') -PathOnly
                $fast=$t -and $t.Settings.Enabled -and @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $_.Enabled -and (-not $_.Delay -or $_.Delay -eq 'PT0S') }).Count -gt 0 -and @($t.Actions | Where-Object { $_.Execute -eq $cover }).Count -gt 0 -and (Test-Path -LiteralPath $cover)
                $start = $vm -and ([string]$vm.AutomaticStartAction -eq 'Start' -or ($cfg -and $cfg.Mode -eq 'full' -and $cfg.ManageVmStart -and [string]$vm.AutomaticStartAction -eq 'Nothing' -and (Test-SetupTask 'CpuPartition-Boot' 'windows-cpu-partition\cpu-partition.ps1' '-BootApply')))
                if ($main -and $fast -and $start) { return (New-SetupState Done '遅延なしの専用起動中画面、自動表示、VM の起動経路を確認しました。') }
                return (New-SetupState NeedsWork '自動表示タスク・専用起動中画面・VM 起動経路を修復します。')
            }
            '10' { return (Get-SetupCpuState) }
            '11' {
                $defs=@(
                    @('EdgeBox-Launcher','windows-host\00-field-launcher.ps1','Edge Box 起動.lnk'),
                    @('EdgeBox-Settings-Console','windows-host\08-settings-console.ps1','設定.lnk'),
                    @('EdgeBox-Shutdown-All','windows-host\05-shutdown-all.ps1','全部シャットダウン.lnk'),
                    @('EdgeBox-Restart','windows-host\10-restart-edgebox.ps1','Edge Box 再起動.lnk'),
                    @('EdgeBox-Console','windows-host\10-restart-edgebox.ps1','Edge Box 画面.lnk'),
                    @('CpuPartition-Console','windows-cpu-partition\cpu-console.ps1','CPU割り当て.lnk'),
                    @('CpuPartition-Monitor','windows-cpu-partition\cpu-monitor.ps1','Edge Box 監視.lnk')
                )
                $shell=New-Object -ComObject WScript.Shell
                foreach ($d in $defs) {
                    if (-not (Test-SetupTask $d[0] $d[1])) { return (New-SetupState NeedsWork ("タスク不足・配置先相違: " + $d[0])) }
                    $path=Join-Path ([Environment]::GetFolderPath('Desktop')) $d[2]
                    if (-not (Test-Path -LiteralPath $path)) { return (New-SetupState NeedsWork ('アイコン不足: '+$d[2])) }
                    $lnk=$shell.CreateShortcut($path)
                    if ($lnk.WorkingDirectory -ne (Split-Path (Join-Path $script:Root $d[1]) -Parent)) { return (New-SetupState NeedsWork ('古い配置先のアイコン: '+$d[2])) }
                }
                return (New-SetupState Done '操作アイコンと実行タスクが現在の配置先を参照しています。')
            }
            '12' {
                $au=Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
                $svc=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv' -ErrorAction Stop
                if ($au.NoAutoUpdate -eq 1 -and $au.NoAutoRebootWithLoggedOnUsers -eq 1 -and $svc.Start -eq 4 -and (Test-SetupTask 'EdgeBox-WindowsUpdate-Lock' 'windows-host\12-windows-update.ps1')) { return (New-SetupState Done '自動更新抑止ポリシー・サービス・維持タスクを確認しました。') }
                return (New-SetupState NeedsWork '自動更新・再起動抑止の設定が不足しています。')
            }
            '13' {
                $a=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -ErrorAction SilentlyContinue
                $b=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -ErrorAction SilentlyContinue
                $power=& powercfg.exe /getactivescheme 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) { throw '電源プランを照会できません。' }
                if ($a.ScoobeSystemSettingEnabled -eq 0 -and $b.ToastEnabled -eq 0 -and $power.Contains('Edge Box 常時稼働')) { return (New-SetupState Done '通知抑止と常時稼働用の電源プランを確認しました。') }
                return (New-SetupState NeedsWork '通知・スリープ抑止の設定が不足しています。')
            }
        }
    } catch { return (New-SetupState Unknown $_.Exception.Message) }
}
function Write-SetupLog([string]$Message) {
    Write-Host $Message
    if ($script:RunDir) { Add-Content -LiteralPath (Join-Path $script:RunDir 'summary.txt') -Value $Message -Encoding UTF8 }
}
function Save-SetupSettings {
    $script:Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Encoding UTF8
}
function Select-SetupItem([array]$Items, [string]$Label) {
    if ($Items.Count -eq 1) { return $Items[0] }
    if ($script:ResumeMode -or -not [Environment]::UserInteractive) { throw "$Label の選択が必要です。05-create-edgebox.cmd を手動で実行してください。" }
    for ($i=0;$i -lt $Items.Count;$i++) { Write-Host ("[$i] " + $Items[$i].Label) }
    $answer=Read-Host "$Label の番号（空欄は保留）"
    $n=0
    if (-not [int]::TryParse($answer,[ref]$n) -or $n -lt 0 -or $n -ge $Items.Count) { throw "$Label を選択できませんでした。" }
    $Items[$n]
}
function Resolve-SetupDisk($VM) {
    $disks=@(Get-Disk -ErrorAction Stop)
    $sys=@(Get-Partition -DriveLetter $env:SystemDrive.Substring(0,1) -ErrorAction Stop | Select-Object -ExpandProperty DiskNumber)
    $attached=@(); if ($VM) { $attached=@(Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber }) }
    if ($attached.Count -gt 1) { throw '物理ディスクが複数接続されています。Hyper-V マネージャーで対象を確認してください。' }
    $disk=$null
    if ($attached.Count -eq 1) { $disk=$disks | Where-Object Number -eq $attached[0].DiskNumber }
    elseif ($script:Settings.DiskUniqueId) {
        $disk=$disks | Where-Object UniqueId -eq $script:Settings.DiskUniqueId
        if (-not $disk) { throw '選択済みディスクが見つかりません。接続を確認してください（別ディスクへ自動変更しません）。' }
    } else {
        $choices=@($disks | Where-Object { $_.Number -notin $sys -and -not $_.IsBoot -and -not $_.IsSystem -and [string]$_.BusType -notin @('USB','File Backed Virtual') } | ForEach-Object {
            $mounted=@(Get-Partition -DiskNumber $_.Number -ErrorAction Stop | Where-Object { $_.DriveLetter })
            if (-not $mounted.Count) { [pscustomobject]@{Disk=$_;Label=("ディスク {0}: {1} ({2:N0} GB)" -f $_.Number,$_.FriendlyName,($_.Size/1GB))} }
        })
        if (-not $choices.Count) { throw 'Windows 用・USB・ドライブ文字のあるディスクを除くと候補がありません。Edge Box のディスクを確認してください。' }
        $disk=(Select-SetupItem $choices 'Edge Box の物理ディスク').Disk
    }
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.Number -in $sys) { throw 'Windows の起動用ディスクは利用できません。' }
    foreach ($other in @(Get-VM -ErrorAction Stop | Where-Object { -not $VM -or $_.Id -ne $VM.Id })) {
        if (@(Get-VMHardDiskDrive -VMName $other.Name -ErrorAction Stop | Where-Object DiskNumber -eq $disk.Number).Count) { throw "ディスクは別 VM '$($other.Name)' に接続済みです。接続を自動で外さず保留します。" }
    }
    $script:Settings.DiskUniqueId=[string]$disk.UniqueId; Save-SetupSettings
    $disk
}
function Resolve-SetupSwitch {
    $sw=@(Get-VMSwitch -SwitchType External -ErrorAction Stop)
    if ($script:Settings.SwitchId) {
        $chosen=$sw | Where-Object { [string]$_.Id -eq $script:Settings.SwitchId }
        if (-not $chosen) { throw '選択済み外部スイッチがありません。settings.json の SwitchId を確認してください。' }
        return @{SwitchName=$chosen.Name}
    }
    if ($sw.Count) {
        $chosen=(Select-SetupItem @($sw | ForEach-Object { [pscustomobject]@{Switch=$_;Label=$_.Name} }) '外部スイッチ').Switch
        $script:Settings.SwitchId=[string]$chosen.Id; Save-SetupSettings
        return @{SwitchName=$chosen.Name}
    }
    $nics=@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq Up)
    if ($script:Settings.NetAdapterGuid) {
        $nic=$nics | Where-Object { [string]$_.InterfaceGuid -eq $script:Settings.NetAdapterGuid }
        if (-not $nic) { throw '選択済み LAN ポートが未接続です。接続を確認してください。' }
    } else {
        if (-not $nics.Count) { throw '接続中の物理 LAN がありません。ライン側ケーブルを接続してください。' }
        $nic=(Select-SetupItem @($nics | ForEach-Object { [pscustomobject]@{Nic=$_;Label=("{0}: {1} / MAC {2}" -f $_.Name,$_.InterfaceDescription,$_.MacAddress)} }) 'ライン側 LAN').Nic
        $script:Settings.NetAdapterGuid=[string]$nic.InterfaceGuid; Save-SetupSettings
    }
    @{NetAdapterName=$nic.Name}
}
function Invoke-SetupChild([string]$RelativePath, [string[]]$Arguments=@(), [switch]$Interactive) {
    $file=Join-Path $script:Root $RelativePath
    if (-not (Test-Path -LiteralPath $file)) { throw "必要なファイルがありません: $RelativePath" }
    $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # スイッチ/名前付き引数は -File 形式で渡す。空白や引用符は Windows の引数規則に従う。
    $argsLine='-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-SetupArgument $file)
    foreach ($a in $Arguments) { $argsLine+=' '+(ConvertTo-SetupArgument $a) }
    $log=Join-Path $script:RunDir ($script:ActiveStep+'-'+[IO.Path]::GetFileNameWithoutExtension($file)+'.txt')
    if ($Interactive) {
        Add-Content -LiteralPath $log -Encoding UTF8 -Value 'パスワード入力を含む対話画面。入力内容は記録しません。'
        $p=Start-Process $ps -ArgumentList $argsLine -NoNewWindow -PassThru -Wait
    } else {
        $errLog=$log+'.stderr.txt'
        $parameters=@{}
        $switches=@('Setup','Install','NoConfirm','Apply','AutoGetTools')
        for($i=0;$i -lt $Arguments.Count;$i++) {
            $name=$Arguments[$i].TrimStart('-')
            if ($name -in $switches) { $parameters[$name]=$true }
            else {
                $i++
                if($i -ge $Arguments.Count){throw ('引数の値がありません: '+$name)}
                $parameters[$name]=$Arguments[$i]
            }
        }
        $request=@{Script=$file;Parameters=$parameters} | ConvertTo-Json -Compress -Depth 5
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($request))
        $runner=Join-Path $PSScriptRoot 'run-child.ps1'
        $line='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(ConvertTo-SetupArgument $runner)+' -Request '+$encoded
        $p=Start-Process $ps -ArgumentList $line -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $errLog
        $null=$p.Handle   # Windows PowerShell 5.1: 終了前にハンドルを確保し ExitCode を保持する
        if (-not $p.WaitForExit(900000)) { $p.Kill(); throw "15 分以内に終了しませんでした。詳細: $log" }
    }
    if ($p.ExitCode -ne 0) {
        $detail=''
        if(-not $Interactive){$detail=(@(Get-Content -LiteralPath $log,$errLog -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 12) -join ' ')}
        throw "子スクリプト終了コード $($p.ExitCode)。$detail 詳細: $log"
    }
}
function ConvertTo-SetupArgument([string]$Value) {
    # CommandLineToArgvW: 引用符の直前と末尾のバックスラッシュだけを倍にする。
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-SetupStep([string]$Id) {
    switch ($Id) {
        '02' {
            $f=Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
            if ([string]$f.State -ne 'Enabled') {
                $enabled=Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart -ErrorAction Stop
                if ($enabled.RestartNeeded) { return }
            }
            if (Get-Service vmms -ErrorAction SilentlyContinue) { Start-Service vmms -ErrorAction Stop }
        }
        '05' {
            $vm=Get-SetupVM; $disk=Resolve-SetupDisk $vm
            $script:Settings.VMName=if ($vm) {$vm.Name} elseif ($script:Settings.VMName) {$script:Settings.VMName} else {'EdgeBox'}
            Save-SetupSettings
            if (-not $vm) {
                $sw=Resolve-SetupSwitch
                $total=(Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1GB
                if ($total -lt 16) { throw 'Edge Box 8 GB と Windows 8 GB のため、16 GB 以上のメモリが必要です。' }
                $args=@('-DiskNumber',[string]$disk.Number,'-VMName',$script:Settings.VMName,'-NoConfirm')
                foreach ($k in $sw.Keys) { $args+=@('-'+$k,[string]$sw[$k]) }
                Invoke-SetupChild 'windows-host\01-create-field-vm.ps1' $args
            } else {
                if ([string]$vm.State -ne 'Off') { throw 'VM が稼働中で構成が未完了です。正常終了後、この番号を再実行してください。' }
                $d=@(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber })
                if (-not $disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop }
                if (-not $d.Count) { Add-VMHardDiskDrive -VMName $vm.Name -DiskNumber $disk.Number -ErrorAction Stop }
                $boot=@(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber })[0]
                Set-VMFirmware -VMName $vm.Name -EnableSecureBoot Off -FirstBootDevice $boot -ErrorAction Stop
                Set-VM -Name $vm.Name -CheckpointType Disabled -AutomaticStopAction ShutDown -ErrorAction Stop
                $nets=@(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction Stop)
                $external=@($nets | Where-Object SwitchName | ForEach-Object {Get-VMSwitch -Name $_.SwitchName -ErrorAction Stop} | Where-Object SwitchType -eq External)
                if (-not $external.Count) {
                    $sw=Resolve-SetupSwitch
                    if ($sw.NetAdapterName) { $new=New-VMSwitch -Name 'EdgeBox-External' -NetAdapterName $sw.NetAdapterName -AllowManagementOS $true -ErrorAction Stop; $sw=@{SwitchName=$new.Name} }
                    if (-not $nets.Count) { Add-VMNetworkAdapter -VMName $vm.Name -SwitchName $sw.SwitchName -ErrorAction Stop }
                    else { $nets[0] | Connect-VMNetworkAdapter -SwitchName $sw.SwitchName -ErrorAction Stop }
                }
            }
        }
        '06' {
            if ($script:ResumeMode) { throw 'パスワード入力が必要です。06-auto-logon.cmd を手動で実行してください。' }
            Invoke-SetupChild 'windows-host\06-auto-logon.ps1' @('-NoConfirm') -Interactive
        }
        '09' {
            $vm=Get-SetupVM
            Invoke-SetupChild 'windows-host\03-field-display-kiosk.ps1' @('-VMName',$vm.Name,'-Install')
            $cfg=Get-SetupCpuConfig
            if ($cfg -and $cfg.Mode -eq 'full' -and $cfg.ManageVmStart) { Set-VM -Name $vm.Name -AutomaticStartAction Nothing -ErrorAction Stop }
        }
        '10' {
            $vm=Get-SetupVM; $cfg=Get-SetupCpuConfig
            $plan=Get-SetupCpuPlan $cfg
            $args=@('-Apply','-Mode','full','-VMName',$vm.Name,'-NoConfirm','-AutoGetTools','-HostLps',($plan.HostLps -join ','),'-GuestLps',($plan.GuestLps -join ','))
            Invoke-SetupChild 'windows-cpu-partition\cpu-partition.ps1' $args
            $cfg=Get-SetupCpuConfig
            # 設定済み BCD を引き継いだ場合も CPU 起動タスクに起動を委譲する。
            if ($cfg -and $cfg.Mode -eq 'full' -and -not $cfg.ManageVmStart) {
                $cfg | Add-Member NoteProperty ManageVmStart $true -Force
                $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:Root 'windows-cpu-partition\cpu-partition.json') -Encoding UTF8
            }
            Set-VM -Name $vm.Name -AutomaticStartAction Nothing -ErrorAction Stop
        }
        '11' {
            $vm=Get-SetupVM; $name=if($vm){$vm.Name}else{'EdgeBox'}
            $errors=@()
            foreach ($s in @('windows-host\00-field-launcher.ps1','windows-host\08-settings-console.ps1','windows-host\05-shutdown-all.ps1','windows-host\10-restart-edgebox.ps1','windows-cpu-partition\cpu-console.ps1')) {
                try { Invoke-SetupChild $s @('-Setup','-VMName',$name) } catch { $errors+=$_.Exception.Message }
            }
            if ($errors.Count) { throw ($errors -join '; ') }
        }
        '12' { Invoke-SetupChild 'windows-host\12-windows-update.ps1' }
        '13' { Invoke-SetupChild 'windows-host\13-quiet-windows.ps1' }
    }
}
function Get-SetupCpuPlan($Config) {
    if ($Config -and @($Config.HostLps).Count -and @($Config.GuestLps).Count) { return $Config }
    if ($script:Settings.HostLps -and $script:Settings.GuestLps) { return [pscustomobject]@{HostLps=$script:Settings.HostLps;GuestLps=$script:Settings.GuestLps} }
    if ((Get-SetupBcd).RootProc -gt 0) { throw 'CPU 制限中で保存済み計画がないため、全コアを確実に把握できません。「CPU割り当て」で計画を指定してください。' }
    # API から物理コアと SMT の境界を取得。推測で SMT を分断しない。
    if (-not ('EdgeBoxSetupTopology' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'cpu-topology.cs') }
    $cores=@([EdgeBoxSetupTopology]::GetCores())
    $all=@($cores | ForEach-Object { $_.Lps } | Sort-Object)
    if (-not $all.Count -or $all.Count -gt 64 -or [Environment]::ProcessorCount -ne $all.Count) { throw 'CPU 構成を確実に取得できません。「CPU割り当て」で計画を保存してください。' }
    $eff=@($cores | Select-Object -ExpandProperty Efficiency -Unique)
    if ($eff.Count -gt 1) {
        $low=($eff | Measure-Object -Minimum).Minimum
        $guest=@($cores | Where-Object Efficiency -eq $low | Sort-Object { $_.Lps[0] } -Descending | Select-Object -First 8)
    } else { $guest=@($cores | Sort-Object { $_.Lps[0] } -Descending | Select-Object -First ([int][Math]::Floor($cores.Count/2))) }
    $g=@($guest | ForEach-Object { $_.Lps } | Sort-Object)
    $h=@($all | Where-Object { $_ -notin $g })
    if ($g.Count -lt 8 -or $h.Count -lt 4 -or (Compare-Object $h @(0..($h.Count-1)))) { throw '既定の完全分離には Edge Box 8 論理 CPU 以上、Windows 4 論理 CPU 以上が必要です。「CPU割り当て」で機種に適した計画を指定してください。' }
    [pscustomobject]@{HostLps=$h;GuestLps=$g}
}
function Invoke-SetupOne($Definition, [switch]$Status) {
    $script:ActiveStep=$Definition.Id
    $s=Get-SetupStepState $Definition.Id
    if (-not $Status -and $s.State -ne 'Done') {
        foreach ($dep in $Definition.Depends) {
            $d=Get-SetupStepState $dep
            if ($d.State -ne 'Done') { return (New-SetupState Blocked ("前提 $dep が未完了: " + $d.Detail)) }
        }
    }
    if (-not $Status -and $s.State -eq 'NeedsWork') {
        try {
            Invoke-SetupStep $Definition.Id
            $s=Get-SetupStepState $Definition.Id
            if ($s.State -notin @('Done','RebootRequired')) { $s=New-SetupState Failed ('実行後の確認に失敗: '+$s.Detail) }
        } catch { $s=New-SetupState Failed $_.Exception.Message }
    }
    $s
}
function Register-SetupResume([string]$Step) {
    $file=Join-Path $PSScriptRoot 'setup-all.ps1'
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -File '+(ConvertTo-SetupArgument $file)+' -Step '+$Step+' -Resume -NoConfirm -RestartIfNeeded')
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay='PT20S'
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}
function Invoke-EdgeBoxSetup {
    [CmdletBinding()]
    param([string]$Step='All',[switch]$Status,[switch]$NoConfirm,[switch]$RestartIfNeeded,[switch]$Resume,[switch]$NoPause)
    $script:RunDir=$null; $script:ResumeMode=[bool]$Resume; $script:Settings=@{}; $script:SettingsLoadError=''
    $saved=$null
    try { $saved=Read-SetupJson (Join-Path $PSScriptRoot 'settings.json') }
    catch { $script:SettingsLoadError='settings.json を読めません: '+$_.Exception.Message+'。内容を修正するか退避して、05-create-edgebox.cmd を再実行してください。' }
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { $script:Settings[$p.Name]=$p.Value } }
    $steps=@(Get-SetupSteps | Where-Object { $Step -eq 'All' -or $_.Id -eq $Step })
    if (-not $steps.Count) { throw "不明な手順番号です: $Step" }
    if (-not $Status -and -not (Test-SetupAdmin)) { throw '管理者として setup-all.cmd または番号別バッチを実行してください。' }
    $lock=$null
    try {
        if (-not $Status) {
            # 同じ一式を一括/番号別から同時に変更しない。クラッシュ時は OS がハンドルを解放する。
            try { $lock=[IO.File]::Open((Join-Path $PSScriptRoot 'setup.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch { throw '別のセットアップが実行中です。終了してから再実行してください。' }
            $script:RunDir=Join-Path $PSScriptRoot ('logs\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
            New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
            if (-not $NoConfirm -and -not $Resume) {
                Write-Host '未完了の設定を適用します。ディスクと LAN は候補を確認し、パスワードは必要な場合に入力します。'
                Write-Host '対象: Hyper-V、VM、自動サインイン、CPU 分離、アイコン、自動更新・通知・スリープの抑止。'
                if ($RestartIfNeeded) { Write-Host '必要なときは正常終了で PC を再起動します。作業を保存してください。自動再起動は最大 2 回です。' }
                [void](Read-Host 'Enter キーで開始（中止は Ctrl+C）')
            }
        }
        $labels=@{Done='設定済み';NeedsWork='未設定・修復必要';Unknown='確認不能';Blocked='前提未達';Failed='失敗';RebootRequired='再起動待ち'}
        $rows=@()
        foreach ($def in $steps) {
            $s=Invoke-SetupOne $def -Status:$Status
            Write-SetupLog ("[$($def.Id)] $($def.Name): $($labels[$s.State])`r`n  原因・状態: $($s.Detail)")
            if ($s.State -ne 'Done') { Write-SetupLog ("  対処法: $($def.Help)`r`n  再実行: " + (Join-Path $PSScriptRoot $def.Batch)) }
            $rows+=[pscustomobject]@{Number=$def.Id;Name=$def.Name;State=$s.State;Cause=$s.Detail;Remedy=$def.Help;RetryBatch=(Join-Path $PSScriptRoot $def.Batch)}
        }
        if ($Status) { if (@($rows | Where-Object State -ne Done).Count) { return 2 }; return 0 }
        $rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:RunDir 'results.json') -Encoding UTF8
        Write-SetupLog ('ログ: '+$script:RunDir)
        $statePath=Join-Path $PSScriptRoot 'resume-state.json'
        $previous=$null
        try { $previous=Read-SetupJson $statePath }
        catch {
            Write-SetupLog ('resume-state.json を読めないため自動再起動を保留します: '+$_.Exception.Message+'。このファイルを退避して setup-all.cmd を再実行してください。')
            Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
            return 1
        }
        $pending=@($rows | Where-Object State -eq RebootRequired)
        if ($pending.Count) {
            $boot=Get-SetupBootId
            $samePending=@($pending | Where-Object { $previous -and $_.Number -in $previous.Pending -and $previous.BootId -ne $boot })
            if ($samePending.Count -or ($Resume -and $previous.AutoReboots -ge 2)) {
                Write-SetupLog '再起動後も反映されない設定が残りました。自動再起動を止めます。該当番号のログを確認してください。'
                foreach ($row in $pending) { $row.State='Failed'; $row.Cause='再起動後も設定が反映されない、または自動再起動回数の上限に達しました。'+$row.Cause }
                $rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:RunDir 'results.json') -Encoding UTF8
                Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
                return 1
            }
            $count=if($Resume -and $previous){[int]$previous.AutoReboots}else{0}
            try { Register-SetupResume $Step }
            catch {
                Write-SetupLog ('再開タスクを登録できません: '+$_.Exception.Message+'。再起動後に setup-all.cmd を再実行してください。')
                return 1
            }
            @{BootId=$boot;Pending=@($pending | ForEach-Object Number);AutoReboots=($count+1)} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
            Write-SetupLog '再起動後、このユーザーのサインイン時に管理者タスクで再判定します。パスワードが未設定なら最初のサインインは手動です。'
            if ($RestartIfNeeded) {
                Write-SetupLog 'Windows に通常の再起動を要求します（アプリ・VM の強制終了はしません）。'
                try { Restart-Computer -ErrorAction Stop }
                catch { Write-SetupLog ('自動再起動できませんでした: '+$_.Exception.Message+'。作業を保存して通常の再起動を行ってください。再開タスクは登録済みです。') }
            }
            return 3010
        }
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
        if (@($rows | Where-Object State -ne Done).Count) { return 1 }
        Write-SetupLog 'すべての対象設定を確認できました。'
        return 0
    } finally { if ($lock) { $lock.Dispose() }; $script:RunDir=$null }
}
Export-ModuleMember -Function Invoke-EdgeBoxSetup
