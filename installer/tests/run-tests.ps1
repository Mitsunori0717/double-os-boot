#requires -Version 5.1
# Only temporary ordinary files, test-created links, and mocked process/UAC calls.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\package-safety.psm1') -Force -PassThru
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:Count=0
function Check($Value,[string]$Message) {if(-not $Value){throw ('TEST FAILED: '+$Message)};$script:Count++}
function Refuses([scriptblock]$Action,[string]$Code) {
    $failed=$false
    try {& $Action|Out-Null} catch {$failed=$true;if($Code){Check ($_.Exception.Message.Contains($Code)) ('expected '+$Code+', received '+$_.Exception.Message)}}
    Check $failed 'unsafe input must fail'
}
function Write-Text([string]$Path,[string]$Value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))|Out-Null
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
}
function Add-ZipText($Archive,[string]$Name,[string]$Value) {
    $entry=$Archive.CreateEntry($Name);$stream=$entry.Open()
    try {$bytes=[Text.Encoding]::UTF8.GetBytes($Value);$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    return $entry
}
function Get-ZipEntry($Archive,[string]$Name) {
    return @($Archive.Entries|Where-Object {$_.FullName.Replace('\','/') -ceq $Name})[0]
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('EdgeBoxInstallerTests_'+[guid]::NewGuid().ToString('N'))
$junction=$null
[IO.Directory]::CreateDirectory($temp)|Out-Null
try {
    $source=Join-Path $temp 'source'
    foreach($relative in Get-EdgeBoxRequiredFiles) {Write-Text (Join-Path $source $relative) ('fixture '+$relative)}
    Write-Text (Join-Path $source 'package-files.txt') ((Get-EdgeBoxRequiredFiles) -join "`n")
    foreach($relative in @('setup/settings.json','setup/resume-state.json','setup/logs/private.ps1','windows-host/display-config.json','windows-host/field-disk.identity.json','windows-host/field-disk.conf','windows-cpu-partition/fonts/private.json','update.cmd','update.ps1')) {
        Write-Text (Join-Path $source $relative) 'PRIVATE_FIXTURE'
    }
    $files=@(Get-EdgeBoxPackageFileList $source)
    Check ($files.Count -eq @(Get-EdgeBoxRequiredFiles).Count) 'only source allowlist and exact assets are selected'
    Check ('storage-recovery/restore_image.py' -cin @($files.RelativePath)) 'physical recovery implementation is included'
    Check ('windows-cpu-partition/fonts/OFL.txt' -cin @($files.RelativePath)) 'font license is included'
    Check ('update.ps1' -cnotin @($files.RelativePath)) 'updater is neither required nor bundled'
    $fileList=Join-Path $source 'package-files.txt';$validList=[IO.File]::ReadAllText($fileList)
    Write-Text $fileList ($validList+"`nsetup/settings.json")
    Refuses {Get-EdgeBoxPackageFileList $source} 'PACKAGE_FILE_NOT_ALLOWED'
    Write-Text $fileList $validList
    $helper=Join-Path $source 'windows-host/vm-create-safety.psm1'
    $helperBytes=[IO.File]::ReadAllBytes($helper);[IO.File]::Delete($helper)
    Refuses {Get-EdgeBoxPackageFileList $source} 'PACKAGE_DEPENDENCY_MISSING: windows-host/vm-create-safety.psm1'
    [IO.File]::WriteAllBytes($helper,$helperBytes)
    # Read only the setup engine's declared dependency list; do not invoke setup.
    $setupModule=Import-Module (Join-Path $PSScriptRoot '..\..\setup\setup-engine.psm1') -Force -PassThru
    try {
        $required=@(Get-EdgeBoxRequiredFiles)
        foreach($dependency in @(& $setupModule {Get-SetupRequiredFiles})) {
            Check ($dependency.Replace('\','/') -cin $required) ('installer requires setup dependency: '+$dependency)
        }
    } finally {Remove-Module $setupModule -Force}
    $payload=Join-Path $temp 'payload'
    foreach($file in $files) {Write-Text (Join-Path $payload $file.RelativePath) ([IO.File]::ReadAllText($file.FullName))}
    Write-EdgeBoxPayloadManifest $payload
    $zip=Join-Path $temp 'payload.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($payload,$zip)
    $target=Join-Path $temp 'installed'
    Write-Text (Join-Path $target 'setup/settings.json') 'existing settings'
    Write-Text (Join-Path $target 'windows-host/display-config.json') 'existing display'
    Write-Text (Join-Path $target 'setup/logs/existing.log') 'existing log'
    Write-Text (Join-Path $target 'windows-host/field-disk.identity.json') 'existing identity'
    Write-Text (Join-Path $target 'windows-host/field-disk.conf') 'existing legacy choice'
    Install-EdgeBoxPayload $zip $target
    foreach($file in $files) {Check ([IO.File]::ReadAllText((Join-Path $target $file.RelativePath)) -ceq [IO.File]::ReadAllText($file.FullName)) ('correct extracted bytes: '+$file.RelativePath)}
    Check ([IO.File]::ReadAllText((Join-Path $target 'setup/settings.json')) -ceq 'existing settings') 'setup device settings preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'windows-host/display-config.json')) -ceq 'existing display') 'display settings preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'setup/logs/existing.log')) -ceq 'existing log') 'existing logs preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'windows-host/field-disk.identity.json')) -ceq 'existing identity') 'device identity state preserved'
    Check ([IO.File]::ReadAllText((Join-Path $target 'windows-host/field-disk.conf')) -ceq 'existing legacy choice') 'legacy device selection preserved'
    Install-EdgeBoxPayload $zip $target
    Check ([IO.File]::ReadAllText((Join-Path $target 'setup/settings.json')) -ceq 'existing settings') 'repeat source update preserves state'

    $cases=@(
        @{Name='../outside.ps1';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup/../outside.ps1';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='C:/outside.ps1';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup/setup-all.ps1:secret';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup/NUL.ps1';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup/bad.ps1.';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup//bad.ps1';Code='UNSAFE_ARCHIVE_PATH'},
        @{Name='setup/settings.json';Code='PAYLOAD_FILE_NOT_ALLOWED'},
        @{Name='setup/setup-all.ps1';Code='PAYLOAD_DUPLICATE_PATH'},
        @{Name='setup/SETUP-ALL.ps1';Code='PAYLOAD_DUPLICATE_PATH'}
    )
    $number=0
    foreach($case in $cases) {
        $number++;$bad=Join-Path $temp ('bad-'+$number+'.zip');[IO.File]::Copy($zip,$bad,$false)
        $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
        try {Add-ZipText $archive $case.Name 'bad entry'|Out-Null} finally {$archive.Dispose()}
        $absent=Join-Path $temp ('never-created-'+$number)
        Refuses {Install-EdgeBoxPayload $bad $absent} $case.Code
        Check (-not (Test-Path -LiteralPath $absent)) 'all path checks happen before creating destination'
    }
    $bad=Join-Path $temp 'corrupt.zip';[IO.File]::Copy($zip,$bad,$false)
    $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
    try {$stream=(Get-ZipEntry $archive 'setup/setup-all.ps1').Open();try {$stream.WriteByte(88)}finally{$stream.Dispose()}}finally{$archive.Dispose()}
    $absent=Join-Path $temp 'corrupt-never-created'
    Refuses {Install-EdgeBoxPayload $bad $absent} 'PAYLOAD_HASH_MISMATCH'
    Check (-not (Test-Path -LiteralPath $absent)) 'all hashes checked before first target write'

    $bad=Join-Path $temp 'link.zip';[IO.File]::Copy($zip,$bad,$false)
    $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
    try {(Get-ZipEntry $archive 'setup/setup-all.ps1').ExternalAttributes=-1577123840}finally{$archive.Dispose()}
    Refuses {Install-EdgeBoxPayload $bad (Join-Path $temp 'link-never-created')} 'PAYLOAD_LINK_OR_DIRECTORY_FORBIDDEN'

    $bad=Join-Path $temp 'missing.zip';[IO.File]::Copy($zip,$bad,$false)
    $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
    try {
        (Get-ZipEntry $archive 'setup/setup-all.ps1').Delete()
        $manifest=Get-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Raw|ConvertFrom-Json
        $manifest.Files=@($manifest.Files|Where-Object Path -cne 'setup/setup-all.ps1')
        $archive.GetEntry('payload-manifest.json').Delete()
        Add-ZipText $archive 'payload-manifest.json' ($manifest|ConvertTo-Json -Depth 5)|Out-Null
    }finally{$archive.Dispose()}
    Refuses {Install-EdgeBoxPayload $bad (Join-Path $temp 'missing-never-created')} 'PACKAGE_DEPENDENCY_MISSING'

    $bad=Join-Path $temp 'mismatched-file-list.zip';[IO.File]::Copy($zip,$bad,$false)
    $archive=[IO.Compression.ZipFile]::Open($bad,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $list=((Get-EdgeBoxRequiredFiles)|Where-Object {$_ -cne 'tools/package.py'}) -join "`n"
        $listBytes=[Text.Encoding]::UTF8.GetBytes($list)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$listHash=[BitConverter]::ToString($sha.ComputeHash($listBytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $manifest=Get-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Raw|ConvertFrom-Json
        $record=@($manifest.Files|Where-Object Path -ceq 'package-files.txt')[0]
        $record.Length=$listBytes.Length;$record.Sha256=$listHash
        $archive.GetEntry('payload-manifest.json').Delete();$archive.GetEntry('package-files.txt').Delete()
        Add-ZipText $archive 'payload-manifest.json' ($manifest|ConvertTo-Json -Depth 5)|Out-Null
        Add-ZipText $archive 'package-files.txt' $list|Out-Null
    } finally {$archive.Dispose()}
    Refuses {Install-EdgeBoxPayload $bad (Join-Path $temp 'file-list-never-created')} 'PAYLOAD_PACKAGE_FILE_LIST_MISMATCH'

    $outside=Join-Path $temp 'outside';[IO.Directory]::CreateDirectory($outside)|Out-Null
    $linkTarget=Join-Path $temp 'link-target';[IO.Directory]::CreateDirectory($linkTarget)|Out-Null
    $junction=Join-Path $linkTarget 'setup'
    New-Item -ItemType Junction -Path $junction -Target $outside|Out-Null
    Refuses {Install-EdgeBoxPayload $zip $linkTarget} 'REPARSE_POINT_FORBIDDEN'
    Check (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) 'junction target untouched'
    [IO.Directory]::Delete($junction);$junction=$null

    $hardTarget=Join-Path $temp 'hard-target';[IO.Directory]::CreateDirectory($hardTarget)|Out-Null
    $original=Join-Path $outside 'keep.cmd';Write-Text $original 'outside original'
    New-Item -ItemType HardLink -Path (Join-Path $hardTarget 'start.cmd') -Target $original|Out-Null
    Install-EdgeBoxPayload $zip $hardTarget
    Check ([IO.File]::ReadAllText($original) -ceq 'outside original') 'existing hard-link alias is not truncated'
    Check ([IO.File]::ReadAllText((Join-Path $hardTarget 'start.cmd')) -ceq 'fixture start.cmd') 'hard-link destination gets independent new content'

    $collision=Join-Path $temp 'file-collision';Write-Text (Join-Path $collision 'setup') 'keep file'
    Refuses {Install-EdgeBoxPayload $zip $collision} 'PAYLOAD_DIRECTORY_COLLIDES_WITH_FILE'
    Check ([IO.File]::ReadAllText((Join-Path $collision 'setup')) -ceq 'keep file') 'file-directory collision leaves original file intact'
    $artifact=Join-Path $temp 'artifact.zip';Write-Text $artifact 'existing artifact'
    Refuses {Publish-EdgeBoxArtifact $zip $artifact} 'OUTPUT_ALREADY_EXISTS'
    Check ([IO.File]::ReadAllText($artifact) -ceq 'existing artifact') 'existing build output preserved'
    $published=Join-Path $temp 'new-artifact.zip';Publish-EdgeBoxArtifact $zip $published
    Check ((Get-FileHash $zip).Hash -eq (Get-FileHash $published).Hash) 'artifact published byte-for-byte'

    # Mock every process/elevation/setup path. Never executes an installer or system setup.
    & $module {
        $script:Admin=$false;$script:ProcessCode=23;$script:ProcessFailure=$false;$script:InstallCalls=0;$script:ProcessCalls=0
        function script:Test-EdgeBoxInstallAdmin {$script:Admin}
        function script:Install-EdgeBoxPayload {param($PayloadPath,$InstallDir)$script:InstallCalls++}
        function script:Start-Process {
            param($FilePath,$Verb,[switch]$Wait,[switch]$PassThru,$ArgumentList,[switch]$NoNewWindow)
            $script:ProcessCalls++;$script:Verb=$Verb;$script:Arguments=$ArgumentList
            if($script:ProcessFailure){throw 'fixture UAC/process failure'}
            if(-not $Wait -or -not $PassThru){throw 'exit status must be captured'}
            [pscustomobject]@{ExitCode=$script:ProcessCode}
        }
        function script:Restart-Computer {throw 'REAL_RESTART_FORBIDDEN'}
        function script:Read-Host {throw 'UNEXPECTED_PROMPT'}
    }
    $params=@{InstallerPath=(Join-Path $temp 'space name\install.ps1');PayloadPath=$zip;InstallDir=(Join-Path $temp 'space target\');NoPause=$true}
    Check ((Invoke-EdgeBoxInstall @params) -eq 23) 'elevated child failure exit preserved'
    Check ((& $module {$script:Verb}) -eq 'RunAs') 'elevation requested only through mocked process'
    Check ((& $module {$script:InstallCalls}) -eq 0) 'unelevated parent never installs'
    & $module {$script:ProcessCode=3010}
    Check ((Invoke-EdgeBoxInstall @params) -eq 3010) 'elevated reboot-needed exit preserved'
    & $module {$script:ProcessFailure=$true}
    Check ((Invoke-EdgeBoxInstall @params) -eq 1) 'cancelled UAC or process launch fails'
    & $module {$script:Admin=$true;$script:ProcessFailure=$false;$script:ProcessCode=23}
    Check ((Invoke-EdgeBoxInstall @params) -eq 23) 'setup child exit preserved'
    Check ((& $module {$script:InstallCalls}) -eq 1) 'admin path installs once before mocked setup'
    Check ((& $module {$script:Arguments}) -notmatch '-RestartIfNeeded') 'installer must leave restarts to the operator'
    & $module {$script:ProcessCode=0}
    Check ((Invoke-EdgeBoxInstall @params) -eq 0) 'successful mocked setup returns zero'
    Check ((& $module {ConvertTo-EdgeBoxProcessArgument 'D:\Edge Box\'}) -ceq '"D:\Edge Box\\"') 'trailing backslash quoted correctly'
    Write-Output ('PASS installer assertions='+$script:Count+'; temporary files and mocked processes only')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    if($junction -and [IO.Directory]::Exists($junction)){[IO.Directory]::Delete($junction)}
    $resolved=[IO.Path]::GetFullPath($temp);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^EdgeBoxInstallerTests_[0-9a-f]{32}$'){throw 'UNSAFE_TEST_CLEANUP'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
