#requires -Version 5.1
# Read-only disk identity/use checks shared by setup, creation and the launcher.
function Get-EdgeBoxHostDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateRange(0,2147483647)][int]$DiskNumber,
        [string]$ExpectedUniqueId='', [UInt64]$ExpectedSize=0,
        [string]$ExpectedSerialNumber=''
    )
    $disks=@(Get-Disk -ErrorAction Stop)
    $matching=@($disks | Where-Object Number -eq $DiskNumber)
    if ($matching.Count -ne 1) { throw "ディスク $DiskNumber を一意に確認できません。" }
    $disk=$matching[0]
    if ([string]::IsNullOrWhiteSpace([string]$disk.UniqueId) -or [UInt64]$disk.Size -eq 0) { throw 'ディスクの一意 ID または容量を確認できません。' }
    if (@($disks | Where-Object UniqueId -eq $disk.UniqueId).Count -ne 1) { throw 'ディスクの一意 ID が重複しています。' }
    if ($ExpectedUniqueId -and [string]$disk.UniqueId -ne $ExpectedUniqueId) { throw '選択時からディスクの一意 ID が変わりました。' }
    if ($ExpectedSize -and [UInt64]$disk.Size -ne $ExpectedSize) { throw '選択時からディスク容量が変わりました。' }
    if ($ExpectedSerialNumber -and ([string]$disk.SerialNumber).Trim() -ne $ExpectedSerialNumber.Trim()) { throw '選択時からディスクのシリアル番号が変わりました。' }
    if ($null -eq $disk.IsBoot -or $null -eq $disk.IsSystem -or $null -eq $disk.IsOffline) { throw 'ディスクのシステム用途・オンライン状態を確認できません。' }
    if ($disk.IsBoot -or $disk.IsSystem) { throw 'Windows の起動用・システム用ディスクは使用できません。' }
    if ($env:SystemDrive -notmatch '^[A-Za-z]:$') { throw 'Windows のシステムドライブを確認できません。' }
    $system=@(Get-Partition -DriveLetter $env:SystemDrive.Substring(0,1) -ErrorAction Stop)
    if (-not $system.Count) { throw 'Windows のシステムディスクを確認できません。' }
    if ($DiskNumber -in @($system | ForEach-Object DiskNumber)) { throw '稼働中の Windows のディスクは使用できません。' }
    foreach ($partition in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop)) {
        if ($partition.DriveLetter) { throw '対象ディスクにドライブ文字があります。使用中ディスクを自動でオフラインにしません。' }
        foreach ($path in @($partition.AccessPaths)) {
            if ($path -and [string]$path -notmatch '^\\\\\?\\Volume\{[^}]+\}\\$') { throw '対象ディスクにフォルダーのマウントがあります。' }
        }
    }
    $disk
}

function Get-EdgeBoxCreateDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][ValidateRange(0,2147483647)][int]$DiskNumber,
        [string]$ExpectedUniqueId='', [UInt64]$ExpectedSize=0,
        [string]$ExpectedSerialNumber='', [string]$AllowedVmId=''
    )
    $disk=Get-EdgeBoxHostDisk -DiskNumber $DiskNumber -ExpectedUniqueId $ExpectedUniqueId -ExpectedSize $ExpectedSize -ExpectedSerialNumber $ExpectedSerialNumber
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        $attached=@(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber -and $_.DiskNumber -eq $DiskNumber })
        if ($attached.Count -and (-not $AllowedVmId -or [string]$vm.Id -ne $AllowedVmId)) { throw "ディスク $DiskNumber は別 VM '$($vm.Name)' が使用しています。接続を自動で外しません。" }
        if ($attached.Count -gt 1) { throw '対象 VM に物理ディスクが重複接続されています。自動修復せず停止します。' }
    }
    $disk
}

function Undo-EdgeBoxVmCreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$DiskSnapshot,
        [string]$CreatedVmId='', [string]$CreatedSwitchId='',
        [switch]$RestoreDiskOnline
    )
    $vmRemoved=-not [bool]$CreatedVmId
    $diskOnline=$false; $switchRemoved=-not [bool]$CreatedSwitchId
    if ($CreatedVmId) {
        try {
            $created=@(Get-VM -ErrorAction Stop | Where-Object { [string]$_.Id -eq $CreatedVmId })
            if ($created.Count -gt 1) { throw '作成した VM の ID が重複しています。' }
            if ($created.Count) {
                if ([string]$created[0].State -ne 'Off') { throw '作成した VM の停止を確認できません。削除・強制停止しません。' }
                Remove-VM -VM $created[0] -Force -ErrorAction Stop
            }
            if (@(Get-VM -ErrorAction Stop | Where-Object { [string]$_.Id -eq $CreatedVmId }).Count) { throw 'VM の削除を確認できません。' }
            $vmRemoved=$true
            Write-Host '  - 作成途中の VM の削除を確認しました'
        } catch { Write-Warning ('VM の後処理を保留しました: '+$_.Exception.Message) }
    }
    if ($RestoreDiskOnline -and $vmRemoved) {
        try {
            $disk=Get-EdgeBoxCreateDisk -DiskNumber $DiskSnapshot.Number -ExpectedUniqueId ([string]$DiskSnapshot.UniqueId) -ExpectedSize ([UInt64]$DiskSnapshot.Size) -ExpectedSerialNumber ([string]$DiskSnapshot.SerialNumber)
            if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop }
            $check=@(Get-Disk -ErrorAction Stop | Where-Object Number -eq $DiskSnapshot.Number)
            if ($check.Count -ne 1 -or [string]$check[0].UniqueId -ne [string]$DiskSnapshot.UniqueId -or $check[0].IsOffline) { throw '元ディスクのオンライン状態を確認できません。' }
            $diskOnline=$true
            Write-Host '  - 他 VM の未使用を確認し、元ディスクをオンラインに戻しました'
        } catch { Write-Warning ('ディスクをオンラインに戻せませんでした。オフラインのまま確認してください: '+$_.Exception.Message) }
    } elseif ($RestoreDiskOnline) {
        Write-Warning 'VM の削除を確認できないため、ディスクはオフラインのまま保持します。'
    }
    if ($CreatedSwitchId -and $vmRemoved) {
        try {
            $switch=@(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]$_.Id -eq $CreatedSwitchId })
            if ($switch.Count -gt 1) { throw '作成したスイッチを一意に確認できません。' }
            if ($switch.Count) {
                foreach ($vm in @(Get-VM -ErrorAction Stop)) {
                    $using=@(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction Stop | Where-Object { [string]$_.SwitchId -eq $CreatedSwitchId -or $_.SwitchName -eq $switch[0].Name })
                    if ($using.Count) { throw '作成したスイッチを使用中の VM があります。' }
                }
                Remove-VMSwitch -VMSwitch $switch[0] -Force -ErrorAction Stop
            }
            if (@(Get-VMSwitch -ErrorAction Stop | Where-Object { [string]$_.Id -eq $CreatedSwitchId }).Count) { throw 'スイッチの削除を確認できません。' }
            $switchRemoved=$true
            Write-Host '  - 作成した外部スイッチの削除を確認しました'
        } catch { Write-Warning ('外部スイッチの後処理を保留しました: '+$_.Exception.Message) }
    }
    [pscustomobject]@{VmRemoved=$vmRemoved;DiskOnline=$diskOnline;SwitchRemoved=$switchRemoved}
}
Export-ModuleMember -Function Get-EdgeBoxHostDisk,Get-EdgeBoxCreateDisk,Undo-EdgeBoxVmCreation
