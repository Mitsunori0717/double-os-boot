<#
.SYNOPSIS
    Edge Box をワンクリックで起動します。
    Edge Box があればそのまま起動し、無ければ作成してから起動します。

.DESCRIPTION
    これ 1 本で、毎回つまずきがちな段取りを全部自動でやります。

      1. 既存 Edge Box を探す
         - 指定名の Edge Box があればそれを使う
         - 名前が違っても、Edge Box のディスクを使っている Edge Box があればそれを使う
           (旧構成の Edge Box がそのまま活きるので、作り直す必要がありません)
      2. 対象ディスクを決める
         - 既存 Edge Box の接続 / 明示指定 / 前回の媒体ID / 確認付き自動検出 の順
         - ディスク番号だけの古い記録は自動選択に使わない
      3. ディスクの使用状況を確認する
         - 二重接続・他の VM の接続・Windows の使用中領域は拒否する
         - 対象 VM が停止中で、未使用媒体と再確認できた場合だけオフライン化する
      4. Edge Box が無ければ作成する (01-create-field-vm.ps1 を呼ぶ)
      5. 起動してコンソールを表示する (02-start-field-vm.ps1 を呼ぶ)

    作成スクリプトが拒否した場合は停止し、別経路で作成しません。
    ディスクの中身には一切触れません。Edge Box を消したり作り直したりもしません
    (作成は「Edge Box がまったく無い場合」だけです)。

.EXAMPLE
    .\00-field-launcher.ps1              # おまかせ起動
    .\00-field-launcher.ps1 -Status      # 何が使われるかだけ確認 (変更しない)
    .\00-field-launcher.ps1 -Setup       # デスクトップに『Edge Box 起動』アイコンを作成
    .\00-field-launcher.ps1 -DiskNumber 0 -SwitchName "EdgeBox-External"
    .\00-field-launcher.ps1 -NetAdapterName "イーサネット 2"   # 新規 PC (外部スイッチがまだ無い) の初回

.NOTES
    管理者権限が必要です (アイコンから起動すれば UAC 確認なしで管理者になります)。
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[^"\r\n]+$')][string]$VMName    = "EdgeBox",
    [int]$DiskNumber   = -1,      # 省略時: 既存 Edge Box / 記録 / 自動検出 から決める
    [string]$SwitchName = "",     # 省略時: 既存の外部スイッチを自動選択
    [string]$NetAdapterName = "", # 外部スイッチがまだ無い PC で、ライン側 LAN ポートの Name (Get-NetAdapter)。IP でも可
    [ValidateRange(1,1024)][int]$MemoryGB     = 8,
    [ValidateRange(1,256)][int]$CpuCount     = 6,
    [switch]$Status,              # 判定結果だけ表示 (何も変更しない)
    [switch]$Setup,               # デスクトップアイコンの作成
    [switch]$NoConfirm            # 確認プロンプトを出さない
)

$ErrorActionPreference = "Stop"

$DiskConf  = Join-Path $PSScriptRoot "field-disk.conf"
$Script01  = Join-Path $PSScriptRoot "01-create-field-vm.ps1"
$Script02  = Join-Path $PSScriptRoot "02-start-field-vm.ps1"
$TaskName  = "EdgeBox-Launcher"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Step([string]$Text) { Write-Host "" ; Write-Host "== $Text" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }
function Info([string]$Text) { Write-Host "   $Text" }

# アイコンからの起動では画面が残らないため、失敗はダイアログでも知らせる
function Fail([string]$Text) {
    Write-Host ""
    Write-Host $Text -ForegroundColor Red
    if ($NoConfirm) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Text, "Edge Box 起動",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        } catch { }
    }
    exit 1
}

function Confirm-Step([string]$Question) {
    if ($NoConfirm) { return $true }
    $a = Read-Host "   $Question (y/N)"
    return ($a -eq "y")
}

# ============================================================
#  デスクトップアイコンの作成
# ============================================================
if ($Setup) {
    if (-not (Test-Admin)) { Write-Error "管理者権限で実行してください。"; exit 1 }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NoConfirm -VMName `"$VMName`""
    # 時間制限なし + 多重起動可 (表示処理が常駐プロセスを残すため。理由は 10-restart-edgebox.ps1 の -Setup を参照)
    $ts = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $ts -RunLevel Highest -Force | Out-Null

    # 旧名のアイコンは消して、新しい名前で作り直す
    Remove-Item (Join-Path ([Environment]::GetFolderPath("Desktop")) "EdgeBox 起動.lnk") -Force -ErrorAction SilentlyContinue
    $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Edge Box 起動.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = "schtasks.exe"
    $lnk.Arguments  = "/run /tn `"$TaskName`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.WindowStyle  = 7
    $lnk.IconLocation = "shell32.dll,15"
    $lnk.Description  = "Edge Box を起動する (Edge Box が無ければ作成してから起動)"
    $lnk.Save()
    Write-Host "デスクトップに『Edge Box 起動』アイコンを作成しました (UAC 確認なしで起動できます)。" -ForegroundColor Green
    exit 0
}

if (-not (Test-Admin)) {
    Write-Error "管理者権限の PowerShell で実行してください (またはデスクトップの『Edge Box 起動』アイコンから)。"
    exit 1
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Write-Error "Hyper-V が有効になっていません。先に有効化して再起動してください: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All"
    exit 1
}

Write-Host ""
Write-Host "===== Edge Box 起動 =====" -ForegroundColor White

# ============================================================
#  1. 既存 Edge Box とディスクを探す
# ============================================================
function Get-PassthroughDisks([string]$Name) {
    @(Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop | Where-Object { $null -ne $_.DiskNumber })
}

function Get-LauncherSavedDisk($Identity) {
    if($null -eq $Identity -or $Identity.SchemaVersion -ne 1 -or
       [string]::IsNullOrWhiteSpace([string]$Identity.UniqueId) -or $Identity.Size -le 0){throw 'SAVED_DISK_IDENTITY_INVALID'}
    $matches=@(Get-Disk -ErrorAction Stop|Where-Object {
        ([string]$_.UniqueId).Trim() -ceq ([string]$Identity.UniqueId).Trim() -and
        $_.Size -eq $Identity.Size -and
        ([string]$_.SerialNumber).Trim() -ceq ([string]$Identity.SerialNumber).Trim()
    })
    if($matches.Count -ne 1){throw 'SAVED_DISK_MISSING_CHANGED_OR_AMBIGUOUS'}
    return $matches[0]
}

function Get-LauncherVerifiedDisk($Snapshot,[string]$AllowedVmId='') {
    Get-EdgeBoxCreateDisk -DiskNumber $Snapshot.Number -ExpectedUniqueId $Snapshot.UniqueId -ExpectedSize $Snapshot.Size -ExpectedSerialNumber $Snapshot.SerialNumber -AllowedVmId $AllowedVmId
}

function Get-LauncherVmDisk($VM,[int]$RequestedDiskNumber=-1) {
    $drives=@(Get-PassthroughDisks $VM.Name)
    if($drives.Count -ne 1){throw 'EXISTING_VM_REQUIRES_ONE_UNAMBIGUOUS_PHYSICAL_DISK'}
    $number=[int]$drives[0].DiskNumber
    if($RequestedDiskNumber -ge 0 -and $number -ne $RequestedDiskNumber){throw 'EXPLICIT_DISK_DOES_NOT_MATCH_SELECTED_VM'}
    Get-EdgeBoxCreateDisk -DiskNumber $number -AllowedVmId ([string]$VM.Id)
}

function Invoke-LauncherChild([string]$ScriptPath,[hashtable]$Parameters) {
    if(-not(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw ('REQUIRED_SCRIPT_MISSING: '+$ScriptPath)}
    # Transport names/IDs as data, never interpolated into PowerShell syntax.
    $json=@{Script=$ScriptPath;Parameters=$Parameters}|ConvertTo-Json -Depth 6 -Compress
    $request=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $childCode=@'
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
try {
    $data=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__REQUEST__'))|ConvertFrom-Json
    $parameters=@{}
    foreach($property in $data.Parameters.PSObject.Properties){$parameters[$property.Name]=$property.Value}
    $global:LASTEXITCODE=0
    & ([string]$data.Script) @parameters
    $ok=$?
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
    if(-not $ok){exit 1}
    exit 0
}catch{Write-Error ($_|Out-String) -ErrorAction Continue;exit 1}
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode.Replace('__REQUEST__',$request)))
    $process=Start-Process powershell.exe -NoNewWindow -Wait -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-OutputFormat','Text','-EncodedCommand',$encoded)
    return [int]$process.ExitCode
}

function Invoke-LauncherCreateVm($Snapshot,[string]$Name,[string]$CreateScript,
    [int]$Memory,[int]$Cpu,[string]$ExternalSwitch,[string]$Adapter) {
    if(-not(Test-Path -LiteralPath $CreateScript -PathType Leaf)){throw 'CREATE_SCRIPT_MISSING_NO_FALLBACK'}
    $fresh=Get-LauncherVerifiedDisk $Snapshot
    $parameters=@{DiskNumber=$fresh.Number;ExpectedUniqueId=$fresh.UniqueId;ExpectedSize=$fresh.Size;
        ExpectedSerialNumber=$fresh.SerialNumber;VMName=$Name;MemoryGB=$Memory;CpuCount=$Cpu;NoConfirm=$true}
    if($ExternalSwitch){$parameters.SwitchName=$ExternalSwitch}
    if($Adapter){$parameters.NetAdapterName=$Adapter}
    $exitCode=Invoke-LauncherChild $CreateScript $parameters
    if($exitCode -ne 0){throw ('CREATE_SCRIPT_FAILED_NO_FALLBACK: '+$exitCode)}
    $created=@(Get-VM -ErrorAction Stop|Where-Object {$_.Name -ceq $Name})
    if($created.Count -ne 1){throw 'CREATED_VM_NOT_UNIQUE'}
    $null=Get-LauncherVmDisk $created[0] $Snapshot.Number
    $null=Get-LauncherVerifiedDisk $Snapshot ([string]$created[0].Id)
    return $created[0]
}

function Set-LauncherDiskOffline($Snapshot,$VM) {
    $current=Get-VM -Id $VM.Id -ErrorAction Stop
    if([string]$current.Id -ne [string]$VM.Id){throw 'SELECTED_VM_IDENTITY_CHANGED'}
    $null=Get-LauncherVmDisk $current $Snapshot.Number
    $fresh=Get-LauncherVerifiedDisk $Snapshot ([string]$VM.Id)
    if($fresh.IsOffline){return $fresh}
    if($current.State -ne 'Off'){throw 'DISK_OFFLINE_REQUIRES_SELECTED_VM_OFF'}
    # The guard rejects mounted/system/changed/other-VM disks before mutation.
    Set-Disk -Number $fresh.Number -IsOffline $true -ErrorAction Stop
    $verified=Get-LauncherVerifiedDisk $Snapshot ([string]$VM.Id)
    if(-not $verified.IsOffline){throw 'DISK_OFFLINE_READBACK_FAILED'}
    return $verified
}

$identityPath=Join-Path $PSScriptRoot 'field-disk.identity.json'
try {
    Import-Module (Join-Path $PSScriptRoot 'vm-create-safety.psm1') -Force -ErrorAction Stop
    Step '既存の Edge Box と対象ディスクを確認'
    $allVms=@(Get-VM -ErrorAction Stop)
    $named=@($allVms|Where-Object {$_.Name -ceq $VMName})
    if($named.Count -gt 1){throw 'VM_NAME_AMBIGUOUS'}
    $targetVm=$null;$diskInfo=$null
    if($named.Count -eq 1){
        $targetVm=$named[0]
        $diskInfo=Get-LauncherVmDisk $targetVm $DiskNumber
    }else{
        if($DiskNumber -ge 0){
            $selected=@(Get-Disk -Number $DiskNumber -ErrorAction Stop)
            if($selected.Count -ne 1){throw 'SELECTED_DISK_NOT_UNIQUE'}
            $diskInfo=$selected[0]
        }elseif(Test-Path -LiteralPath $identityPath -PathType Leaf){
            $identity=Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
            $diskInfo=Get-LauncherSavedDisk $identity
        }
        # Use an older VM name only when its disk matches an explicit selection
        # or saved hardware identity, never just because it is the only VM.
        if($null -ne $diskInfo -and -not $PSBoundParameters.ContainsKey('VMName')){
            $owners=@(foreach($vm in $allVms){
                if(@(Get-PassthroughDisks $vm.Name|Where-Object {$_.DiskNumber -eq $diskInfo.Number}).Count -gt 0){$vm}
            })
            if($owners.Count -gt 1){throw 'SELECTED_DISK_ATTACHED_TO_MULTIPLE_VMS'}
            if($owners.Count -eq 1){$targetVm=$owners[0];$VMName=$targetVm.Name;$diskInfo=Get-LauncherVmDisk $targetVm $diskInfo.Number}
        }
        if($null -eq $diskInfo){
            if($allVms.Count -gt 0){
                $physicalOwners=@($allVms|Where-Object {@(Get-PassthroughDisks $_.Name).Count -gt 0})
                if($physicalOwners.Count -gt 0){throw ('VM_SELECTION_REQUIRED: -VMName で対象を指定してください: '+(($physicalOwners.Name)-join ', '))}
            }
            if(Test-Path -LiteralPath $DiskConf){
                Warn '以前のディスク番号だけの記録は自動選択に使いません。実ディスクを確認します。'
            }
            $candidates=@(foreach($disk in @(Get-Disk -ErrorAction Stop)){
                try{Get-EdgeBoxCreateDisk -DiskNumber $disk.Number}catch{Info ('除外: ディスク '+$disk.Number+' / '+$_.Exception.Message)}
            })
            if($candidates.Count -ne 1){throw 'DISK_SELECTION_REQUIRED: Get-Disk で確認して -DiskNumber を指定してください。'}
            $diskInfo=$candidates[0]
            Info ('候補: ディスク '+$diskInfo.Number+' / '+$diskInfo.FriendlyName+' / ID='+$diskInfo.UniqueId)
            if(-not $Status){
                if($NoConfirm){throw 'EXPLICIT_DISK_REQUIRED_FOR_UNATTENDED_CREATION'}
                if(-not(Confirm-Step 'このディスクを Edge Box として使用しますか?')){exit 0}
            }
        }
        if($null -eq $targetVm){$diskInfo=Get-LauncherVerifiedDisk $diskInfo}
    }
    $diskNo=[int]$diskInfo.Number
    Ok ('ディスク '+$diskNo+' / '+$diskInfo.FriendlyName+' / ID='+$diskInfo.UniqueId)
    if($Status){
        Step '確認だけの実行のため、変更せず終了します'
        if($targetVm){Info ('対象の登録: '+$targetVm.Name+' / 状態: '+$targetVm.State)}
        else{Info ('新規作成する登録: '+$VMName)}
        if(-not $diskInfo.IsOffline){Info '実行時は使用状況を再確認してからディスクをオフラインにします。'}
        exit 0
    }
    if(-not $targetVm){
        if(-not(Confirm-Step ('登録『'+$VMName+'』を作成します。よろしいですか?'))){exit 0}
        $targetVm=Invoke-LauncherCreateVm $diskInfo $VMName $Script01 $MemoryGB $CpuCount $SwitchName $NetAdapterName
        Ok ('登録『'+$targetVm.Name+'』を作成しました')
    }else{
        $diskInfo=Set-LauncherDiskOffline $diskInfo $targetVm
    }
    # Preserve the legacy number file for existing readers. Future launcher
    # selection uses the identity file and follows disk renumbering.
    $diskNo|Set-Content -LiteralPath $DiskConf -Encoding ASCII -ErrorAction Stop
    [ordered]@{SchemaVersion=1;UniqueId=$diskInfo.UniqueId;Size=$diskInfo.Size;SerialNumber=$diskInfo.SerialNumber}|
        ConvertTo-Json|Set-Content -LiteralPath $identityPath -Encoding UTF8 -ErrorAction Stop
    Step '起動'
    $targetVm=Get-VM -Id $targetVm.Id -ErrorAction Stop
    $null=Get-LauncherVmDisk $targetVm $diskNo
    $null=Get-LauncherVerifiedDisk $diskInfo ([string]$targetVm.Id)
    if($targetVm.State -eq 'Running'){
        Ok 'すでに起動しています。コンソールを開きます。'
        Start-Process 'vmconnect.exe' -ArgumentList @('localhost',('"'+$targetVm.Name+'"'))
        exit 0
    }
    if($targetVm.State -ne 'Off'){throw ('VM_NOT_OFF_OR_RUNNING: '+$targetVm.State)}
    $exitCode=Invoke-LauncherChild $Script02 @{VMName=$targetVm.Name}
    if($exitCode -ne 0){throw ('START_SCRIPT_FAILED: '+$exitCode)}
    Ok 'Edge Box を起動しました。'
    Warn '起動画面で Ctrl キーを押しっぱなしにしないでください (工場出荷リセットが選ばれる機種があります)。'
}catch{
    Fail ('安全確認または起動処理で停止しました。接続の自動切離しや別経路での再作成は行いません。'+[Environment]::NewLine+$_.Exception.Message)
}
