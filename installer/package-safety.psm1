#requires -Version 5.1
Set-StrictMode -Version Latest

function Assert-EdgeBoxSafePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path -match '^[\\/]{2}|[\x00-\x1f]' -or $Path -match '[<>"|?*]') { throw 'UNSAFE_LOCAL_PATH' }
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'LOCAL_DRIVE_PATH_REQUIRED' }
    foreach($part in $full.Substring(3).Split('\')) {
        if ($part -and ($part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)')) { throw 'UNSAFE_WINDOWS_NAME' }
    }
    $cursor=$full
    while($cursor) {
        $item=$null
        try {$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}
        catch [System.Management.Automation.ItemNotFoundException] {}
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'REPARSE_POINT_FORBIDDEN' }
        $parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
    return $full
}

function ConvertTo-EdgeBoxRelativePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $relative=$Path.Replace('\','/')
    if ($relative.Length -gt 240 -or $relative -match '[\x00-\x1f<>:"|?*]' -or $relative.StartsWith('/')) { throw 'UNSAFE_ARCHIVE_PATH' }
    foreach($part in $relative.Split('/')) {
        if (-not $part -or $part -in @('.','..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)') { throw 'UNSAFE_ARCHIVE_PATH' }
    }
    return $relative
}

function Test-EdgeBoxPackagePath {
    param([string]$RelativePath)
    if ($RelativePath -cin @('start.cmd','setup-all.cmd','README.md','CHANGELOG.md','VALIDATION.md','release.json','package-files.txt','.gitignore','.gitattributes')) { return $true }
    if ($RelativePath -cin @('windows-host/.gitignore','windows-cpu-partition/.gitignore','storage-recovery/.gitignore')) { return $true }
    if ($RelativePath -cmatch '^(windows-host|windows-cpu-partition|setup)/[A-Za-z0-9][A-Za-z0-9_.-]*\.(ps1|psm1|cmd|md|cs)$') { return $true }
    if ($RelativePath -cmatch '^storage-recovery/[A-Za-z0-9][A-Za-z0-9_.-]*\.(ps1|psm1|py|md)$') { return $true }
    if ($RelativePath -cmatch '^(setup|storage-recovery|windows-host|windows-cpu-partition|installer)/tests/[A-Za-z0-9][A-Za-z0-9_.-]*\.(ps1|py)$') { return $true }
    if ($RelativePath -cmatch '^installer/[A-Za-z0-9][A-Za-z0-9_.-]*\.(ps1|psm1|cmd|md|cs|manifest)$') { return $true }
    if ($RelativePath -cmatch '^tests/[A-Za-z0-9][A-Za-z0-9_.-]*\.(ps1|py)$' -or $RelativePath -cmatch '^docs/[A-Za-z0-9][A-Za-z0-9_.-]*\.md$') { return $true }
    if ($RelativePath -ceq 'tools/package.py') { return $true }
    return $RelativePath -cin @('windows-cpu-partition/fonts/Michroma-Regular.ttf','windows-cpu-partition/fonts/OFL.txt','windows-cpu-partition/images/app-icon.png','windows-cpu-partition/images/app-icon.ico')
}

function Get-EdgeBoxRequiredFiles {
    @('start.cmd','setup-all.cmd','setup/setup-all.ps1','setup/setup-engine.psm1','setup/run-child.ps1','setup/cpu-topology.cs',
      'windows-host/01-create-field-vm.ps1','windows-host/06-auto-logon.ps1','windows-host/vm-shutdown.psm1',
      'windows-host/12-windows-update.ps1','windows-host/13-quiet-windows.ps1','windows-host/startup-cover.cs',
      'windows-host/host-restart-policy.psm1','windows-host/service-restart-policy.psm1','windows-host/service-restart-policy.cs','windows-host/tests/test-service-restart-policy.ps1','windows-host/shutdown-diagnostics.ps1',
      'windows-cpu-partition/cpu-partition.ps1','windows-cpu-partition/cpu-console.ps1','windows-cpu-partition/cpu-ui-theme.ps1',
      'windows-cpu-partition/fonts/Michroma-Regular.ttf','windows-cpu-partition/fonts/OFL.txt','windows-cpu-partition/images/app-icon.png','windows-cpu-partition/images/app-icon.ico',
      'storage-recovery/offline_image.py','storage-recovery/convert_image.py','storage-recovery/restore_image.py','storage-recovery/backup_set.py','storage-recovery/larger_disk_layout.py',
      'storage-recovery/StorageRecovery.psm1','storage-recovery/HyperVRecovery.psm1','storage-recovery/WindowsRecoveryInventory.psm1','storage-recovery/WindowsRecoveryPlan.psm1',
      'storage-recovery/storage-recovery.ps1','storage-recovery/restore-vm.ps1','storage-recovery/windows-recovery.ps1')
    @('setup/setup-all.cmd','setup/check-status.cmd','setup/02-enable-hyperv.cmd','setup/05-create-edgebox.cmd','setup/06-auto-logon.cmd',
      'setup/09-install-autostart.cmd','setup/10-partition-cpu.cmd','setup/11-install-shortcuts.cmd','setup/12-windows-update.cmd','setup/13-quiet-windows.cmd',
      'windows-host/vm-create-safety.psm1','windows-host/00-field-launcher.ps1','windows-host/02-start-field-vm.ps1','windows-host/03-field-display-kiosk.ps1',
      'windows-host/04-reboot-to-field-native.ps1','windows-host/05-shutdown-all.ps1','windows-host/07-boot-appearance.ps1','windows-host/08-settings-console.ps1',
      'windows-host/09-rename-to-edgebox.ps1','windows-host/10-restart-edgebox.ps1','windows-host/11-io-passthrough.ps1','windows-host/99-fix-black-screen.ps1',
      'windows-host/build-startup-cover.ps1','windows-host/field-start.cmd','windows-host/fix-black-screen.cmd',
      'windows-cpu-partition/cpu-apps.ps1','windows-cpu-partition/cpu-monitor.ps1','windows-cpu-partition/console.cmd','windows-cpu-partition/setup.cmd',
      'windows-host/cpu-boot.psm1','windows-cpu-partition/cpu-tool.psm1')
    @('README.md','CHANGELOG.md','VALIDATION.md','release.json','package-files.txt',
      'docs/FRESH-INSTALL.md','docs/HARDWARE-ACCEPTANCE.md','tools/package.py','tests/run-all.ps1','tests/test_package.py','tests/test_qemu_integration.py',
      'installer/bootstrap.cs','installer/bootstrap.manifest','installer/build-installer.cmd','installer/build-installer.ps1',
      'installer/install.cmd','installer/install.ps1','installer/package-safety.psm1','installer/README.md','installer/tests/run-tests.ps1',
      'setup/tests/run-tests.ps1','setup/tests/test-safety.ps1','setup/tests/test-vm-create-safety.ps1','windows-host/tests/test-launcher-safety.ps1',
      'windows-host/tests/test-start-safety.ps1','windows-host/tests/test-cpu-preparation.ps1',
      'storage-recovery/tests/run-all.ps1','storage-recovery/tests/run-tests.ps1','storage-recovery/tests/test-hyperv-recovery.ps1',
      'storage-recovery/tests/test-hyperv-v2.ps1','storage-recovery/tests/test-hyperv-wiring.ps1','storage-recovery/tests/test-windows-expanded-plan.ps1',
      'storage-recovery/tests/test-windows-integration.ps1','storage-recovery/tests/test-windows-inventory.ps1','storage-recovery/tests/test-windows-plan.ps1',
      'storage-recovery/tests/test_backup_set.py','storage-recovery/tests/test_convert_image.py','storage-recovery/tests/test_larger_disk_layout.py',
      'storage-recovery/tests/test_offline_image.py','storage-recovery/tests/test_restore_image.py')
}

function Get-EdgeBoxPackageFileList {
    param([Parameter(Mandatory=$true)][string]$Root)
    $base=(Assert-EdgeBoxSafePath $Root).TrimEnd('\')+'\'
    $files=[Collections.Generic.List[object]]::new();$seen=@{}
    $spec=Assert-EdgeBoxSafePath (Join-Path $base 'package-files.txt')
    if (-not [IO.File]::Exists($spec)) {throw 'PACKAGE_FILE_LIST_MISSING'}
    foreach($line in [IO.File]::ReadAllLines($spec,[Text.Encoding]::UTF8)) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) {continue}
        $name=ConvertTo-EdgeBoxRelativePath $line.Trim()
        if ($name -cne $line.Trim() -or -not (Test-EdgeBoxPackagePath $name)) {throw ('PACKAGE_FILE_NOT_ALLOWED: '+$name)}
        if ($seen.ContainsKey($name)) {throw 'PACKAGE_DUPLICATE_PATH'}
        $seen[$name]=$true
        $safe=Assert-EdgeBoxSafePath (Join-Path $base $name)
        if (-not [IO.File]::Exists($safe)) {throw ('PACKAGE_DEPENDENCY_MISSING: '+$name)}
        $files.Add([pscustomobject]@{RelativePath=$name;FullName=$safe})
    }
    if ($files.Count -gt 4095) {throw 'PACKAGE_TOO_MANY_FILES'}
    $names=@($files|ForEach-Object {$_.RelativePath})
    foreach($required in Get-EdgeBoxRequiredFiles) { if ($required -cnotin $names) { throw ('PACKAGE_DEPENDENCY_MISSING: '+$required) } }
    return $files.ToArray() | Sort-Object RelativePath
}

function Write-EdgeBoxPayloadManifest {
    param([Parameter(Mandatory=$true)][string]$Directory)
    $files=@(Get-EdgeBoxPackageFileList $Directory)
    $members=@(foreach($file in $files) {
        [ordered]@{Path=$file.RelativePath;Length=(Get-Item -LiteralPath $file.FullName).Length;Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $path=Join-Path $Directory 'payload-manifest.json'
    $json=[ordered]@{SchemaVersion=1;Files=$members}|ConvertTo-Json -Depth 5
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)} finally {$stream.Dispose()}
}

function Publish-EdgeBoxArtifact {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)
    $destination=Assert-EdgeBoxSafePath $Destination
    if (Test-Path -LiteralPath $destination) { throw 'OUTPUT_ALREADY_EXISTS' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($destination))) { throw 'OUTPUT_PARENT_REQUIRED' }
    $partial=$destination+'.partial-'+[guid]::NewGuid().ToString('N')
    [IO.File]::Copy($Source,$partial,$false)
    $stream=[IO.File]::Open($partial,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {$stream.Flush($true)} finally {$stream.Dispose()}
    Assert-EdgeBoxSafePath $destination|Out-Null
    [IO.File]::Move($partial,$destination)
}

function Get-EdgeBoxValidatedPayload {
    param([Parameter(Mandatory=$true)]$Archive,[Parameter(Mandatory=$true)][string]$InstallDir)
    $base=(Assert-EdgeBoxSafePath $InstallDir).TrimEnd('\')+'\'
    if ($base -eq [IO.Path]::GetPathRoot($base)) { throw 'INSTALL_DRIVE_ROOT_FORBIDDEN' }
    if ([IO.File]::Exists($base.TrimEnd('\'))) { throw 'INSTALL_DIRECTORY_IS_FILE' }
    $entries=@{}; $total=[long]0
    if ($Archive.Entries.Count -gt 4096) { throw 'PAYLOAD_TOO_MANY_ENTRIES' }
    foreach($entry in $Archive.Entries) {
        # Generated payloads contain ordinary files only; links and directory entries are not needed.
        $name=ConvertTo-EdgeBoxRelativePath $entry.FullName
        $attributes=[long]$entry.ExternalAttributes -band 0xffffffffL
        $kind=($attributes -shr 16) -band 0xf000
        if ($kind -notin @(0,0x8000) -or ($attributes -band 0x410)) { throw 'PAYLOAD_LINK_OR_DIRECTORY_FORBIDDEN' }
        if ($name -cne 'payload-manifest.json' -and -not (Test-EdgeBoxPackagePath $name)) { throw ('PAYLOAD_FILE_NOT_ALLOWED: '+$name) }
        if ($entries.ContainsKey($name)) { throw 'PAYLOAD_DUPLICATE_PATH' }
        if ($entry.Length -gt 64MB -or $entry.Length -lt 0) { throw 'PAYLOAD_ENTRY_TOO_LARGE' }
        $total+=$entry.Length
        if ($total -gt 512MB) { throw 'PAYLOAD_TOO_LARGE' }
        $dest=Assert-EdgeBoxSafePath (Join-Path $base $name)
        if (-not $dest.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw 'PAYLOAD_PATH_ESCAPES_TARGET' }
        if ([IO.Directory]::Exists($dest)) { throw 'PAYLOAD_FILE_COLLIDES_WITH_DIRECTORY' }
        if ([IO.File]::Exists($dest) -and ((Get-Item -LiteralPath $dest -Force).Attributes -band [IO.FileAttributes]::ReadOnly)) { throw 'PAYLOAD_TARGET_READ_ONLY' }
        $parent=[IO.Path]::GetDirectoryName($dest)
        while($parent -and $parent.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) {
            if ([IO.File]::Exists($parent)) { throw 'PAYLOAD_DIRECTORY_COLLIDES_WITH_FILE' }
            $parent=[IO.Path]::GetDirectoryName($parent)
        }
        $entries[$name]=[pscustomobject]@{Entry=$entry;RelativePath=$name;Destination=$dest}
    }
    if (-not $entries.ContainsKey('payload-manifest.json')) { throw 'PAYLOAD_MANIFEST_MISSING' }
    $manifestEntry=$entries['payload-manifest.json'].Entry
    if ($manifestEntry.Length -gt 1MB) { throw 'PAYLOAD_MANIFEST_TOO_LARGE' }
    $reader=[IO.StreamReader]::new($manifestEntry.Open(),[Text.Encoding]::UTF8,$true)
    try {$manifest=$reader.ReadToEnd()|ConvertFrom-Json} finally {$reader.Dispose()}
    if (($manifest.SchemaVersion -isnot [int] -and $manifest.SchemaVersion -isnot [long]) -or $manifest.SchemaVersion -ne 1 -or @($manifest.PSObject.Properties.Name).Count -ne 2 -or $null -eq $manifest.Files) { throw 'PAYLOAD_MANIFEST_INVALID' }
    $seen=@{}
    foreach($member in @($manifest.Files)) {
        if (@($member.PSObject.Properties.Name).Count -ne 3 -or $member.Path -isnot [string] -or ($member.Length -isnot [long] -and $member.Length -isnot [int]) -or $member.Sha256 -isnot [string] -or $member.Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'PAYLOAD_MANIFEST_MEMBER_INVALID' }
        $name=ConvertTo-EdgeBoxRelativePath $member.Path
        if (-not (Test-EdgeBoxPackagePath $name) -or $seen.ContainsKey($name) -or -not $entries.ContainsKey($name)) { throw 'PAYLOAD_MANIFEST_MEMBERS_MISMATCH' }
        $seen[$name]=$true; $entry=$entries[$name].Entry
        if ($entry.Length -ne $member.Length) { throw 'PAYLOAD_LENGTH_MISMATCH' }
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose();$stream.Dispose()}
        if ($hash -cne $member.Sha256) { throw 'PAYLOAD_HASH_MISMATCH' }
    }
    if ($seen.Count -ne $entries.Count-1) { throw 'PAYLOAD_MANIFEST_MEMBERS_MISMATCH' }
    foreach($required in Get-EdgeBoxRequiredFiles) { if (-not $seen.ContainsKey($required)) { throw ('PACKAGE_DEPENDENCY_MISSING: '+$required) } }
    $specEntry=$entries['package-files.txt'].Entry
    if ($specEntry.Length -gt 1MB) {throw 'PACKAGE_FILE_LIST_TOO_LARGE'}
    $reader=[IO.StreamReader]::new($specEntry.Open(),[Text.Encoding]::UTF8,$true)
    try {$specText=$reader.ReadToEnd()} finally {$reader.Dispose()}
    $specNames=@{}
    foreach($line in ($specText -split '\r?\n')) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) {continue}
        $name=ConvertTo-EdgeBoxRelativePath $line.Trim()
        if ($name -cne $line.Trim() -or $specNames.ContainsKey($name) -or -not $seen.ContainsKey($name)) {throw 'PAYLOAD_PACKAGE_FILE_LIST_MISMATCH'}
        $specNames[$name]=$true
    }
    if ($specNames.Count -ne $seen.Count) {throw 'PAYLOAD_PACKAGE_FILE_LIST_MISMATCH'}
    return @($entries.Values|Sort-Object RelativePath)
}

function Install-EdgeBoxPayload {
    param([Parameter(Mandatory=$true)][string]$PayloadPath,[Parameter(Mandatory=$true)][string]$InstallDir)
    $zip=Assert-EdgeBoxSafePath $PayloadPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
        # Validate EVERY entry, digest and destination before the first target write.
        $files=@(Get-EdgeBoxValidatedPayload -Archive $archive -InstallDir $InstallDir)
        foreach($file in $files) {
            $dest=Assert-EdgeBoxSafePath $file.Destination
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
            Assert-EdgeBoxSafePath $dest|Out-Null
            $partial=Join-Path ([IO.Path]::GetDirectoryName($dest)) ('.edgebox-install-'+[guid]::NewGuid().ToString('N'))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($file.Entry,$partial,$false)
            $stream=[IO.File]::Open($partial,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try {$stream.Flush($true)} finally {$stream.Dispose()}
            Assert-EdgeBoxSafePath $dest|Out-Null
            # Replace the directory entry instead of truncating a possible existing hard link.
            if ([IO.File]::Exists($dest)) {[IO.File]::Replace($partial,$dest,[System.Management.Automation.Language.NullString]::Value)}
            else {[IO.File]::Move($partial,$dest)}
            Unblock-File -LiteralPath $dest -ErrorAction Stop
        }
    } finally {$archive.Dispose()}
}

function ConvertTo-EdgeBoxProcessArgument {
    param([string]$Value)
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"'+$escaped+'"'
}

function Test-EdgeBoxInstallAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-EdgeBoxInstallProcess {
    param([string]$Script,[string[]]$ScriptArguments,[switch]$Elevate)
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script)+$ScriptArguments
    $line=(@($arguments|ForEach-Object {ConvertTo-EdgeBoxProcessArgument $_}) -join ' ')
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($Elevate) {$child=Start-Process -FilePath $exe -Verb RunAs -Wait -PassThru -ArgumentList $line}
    else {$child=Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru -ArgumentList $line}
    if ($null -eq $child -or $null -eq $child.ExitCode) { throw 'INSTALL_CHILD_EXIT_CODE_UNAVAILABLE' }
    return [int]$child.ExitCode
}

function Invoke-EdgeBoxInstall {
    param([string]$InstallerPath,[string]$PayloadPath,[string]$InstallDir,[switch]$NoPause)
    try {
        $InstallDir=Assert-EdgeBoxSafePath $InstallDir
        if (-not (Test-EdgeBoxInstallAdmin)) {
            $arguments=@('-InstallDir',$InstallDir,'-PayloadPath',$PayloadPath)
            if ($NoPause) {$arguments+='-NoPause'}
            return Start-EdgeBoxInstallProcess -Script $InstallerPath -ScriptArguments $arguments -Elevate
        }
        Write-Host ('Edge Box 一式を配置します: '+$InstallDir)
        Install-EdgeBoxPayload -PayloadPath $PayloadPath -InstallDir $InstallDir
        $setup=Join-Path $InstallDir 'setup\setup-all.ps1'
        $code=Start-EdgeBoxInstallProcess -Script $setup -ScriptArguments @('-NoPause')
        if ($code -notin @(0,3010)) {Write-Warning ('未完了の設定があります。'+$InstallDir+'\setup\logs を確認してください。')}
        if (-not $NoPause) {Read-Host 'Enter キーで閉じます'|Out-Null}
        return $code
    } catch {
        Write-Warning ('Edge Box の配置または起動に失敗しました: '+$_.Exception.Message)
        return 1
    }
}

Export-ModuleMember -Function Assert-EdgeBoxSafePath,Test-EdgeBoxPackagePath,Get-EdgeBoxRequiredFiles,Get-EdgeBoxPackageFileList,Write-EdgeBoxPayloadManifest,Publish-EdgeBoxArtifact,Get-EdgeBoxValidatedPayload,Install-EdgeBoxPayload,Invoke-EdgeBoxInstall
