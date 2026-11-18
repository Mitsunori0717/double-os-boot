#requires -Version 5.1
# Independent evidence/assessment integration. Synthetic provider fixtures only.
# No real registry/file scan, native signature validation, network access, or uninstall.
$ErrorActionPreference='Stop'
$dir=Split-Path $PSScriptRoot -Parent
$im=Import-Module (Join-Path $dir 'AppInventory.psm1') -Force -PassThru
$em=Import-Module (Join-Path $dir 'AppEvidence.psm1') -Force -PassThru
$am=Import-Module (Join-Path $dir 'AppAssessment.psm1') -Force -PassThru
$um=Import-Module (Join-Path $dir 'SafeUninstall.psm1') -Force -PassThru
$script:Count=0
function Assert-True($v,[string]$m){if(-not $v){throw "TEST FAILED: $m"};$script:Count++}
function Assert-Throws([scriptblock]$a,[string]$m){$threw=$false;try{& $a|Out-Null}catch{$threw=$true};Assert-True $threw $m}
try {
    & $im {
        function script:Get-AiCurrentSid {'S-1-5-21-1-2-3-1001'}
        function script:Get-AiRegistryEntries([string]$Hive,[string]$View){
            if($Hive -ne 'LocalMachine' -or $View -ne 'Registry64'){return}
            $prefix='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'
            [pscustomobject]@{Key=($prefix+'{11111111-2222-3333-4444-555555555555}');DisplayName='Mozilla Firefox 128';DisplayVersion='128';Publisher='Mozilla';InstallLocation='C:\Fixture';UninstallString='NEVER_EXECUTE';WindowsInstaller=1;SystemComponent=0;NoRemove=0}
            [pscustomobject]@{Key=($prefix+'{22222222-3333-4444-5555-666666666666}');DisplayName='Mystery Application';DisplayVersion='1';Publisher='Unknown';WindowsInstaller=1;SystemComponent=0;NoRemove=0}
            [pscustomobject]@{Key=($prefix+'{33333333-4444-5555-6666-777777777777}');DisplayName='Mozilla Firefox 128';DisplayVersion='128';Publisher='Forged Corporation';WindowsInstaller=1;SystemComponent=0;NoRemove=0}
        }
        function script:Get-AiAppxEntries {throw 'Actual Appx scanning forbidden'}
    }
    & $em {
        function script:Get-AeFileState([string]$Path){
            $script:EF.ReadCount++
            if($script:EF.FailState){throw ('provider error '+$script:EF.Secret)}
            $ticks=100L;if($script:EF.ChangeDuringRead -and $script:EF.ReadCount -gt 1){$ticks=200L}
            [pscustomobject]@{Length=$script:EF.Bytes.Length;LastWriteUtcTicks=$ticks;CreationUtcTicks=50L}
        }
        function script:Open-AeFile([string]$Path){return [IO.MemoryStream]::new([byte[]]$script:EF.Bytes,$false)}
        function script:Get-AeVersion([string]$Path){
            if($script:EF.FailVersion){throw ('native version metadata failed '+$script:EF.Secret)}
            $script:EF.Version
        }
        foreach($cmd in @('Get-AuthenticodeSignature','Invoke-WebRequest','Invoke-RestMethod','Start-Process','Get-ChildItem','Get-Item','Get-ItemProperty','Get-AppxPackage')) {
            Set-Item -Path ('Function:script:'+$cmd) -Value {throw 'Real scan, signature provider, network or process forbidden'}
        }
    }
    & $um {
        function script:Get-SUInventory {throw 'Uninstall query forbidden in evidence tests'}
        function script:Get-SUMsiProductInstances {throw 'Native MSI query forbidden in evidence tests'}
        function script:Initialize-SUMsiNative {throw 'Native binding forbidden in evidence tests'}
        function script:Invoke-SUMsi {throw 'Uninstall forbidden in evidence tests'}
        function script:Show-SUConfirmation {throw 'Native confirmation forbidden in evidence tests'}
    }
    function Reset-EvidenceFixture {
        $bytes=New-Object byte[] 1024
        [BitConverter]::GetBytes([uint16]0x5a4d).CopyTo($bytes,0)
        [BitConverter]::GetBytes([uint32]128).CopyTo($bytes,60)
        [BitConverter]::GetBytes([uint32]0x4550).CopyTo($bytes,128)
        [BitConverter]::GetBytes([uint16]224).CopyTo($bytes,148)
        [BitConverter]::GetBytes([uint16]0x10b).CopyTo($bytes,152)
        [BitConverter]::GetBytes([uint32]16).CopyTo($bytes,244)
        [BitConverter]::GetBytes([uint32]768).CopyTo($bytes,280)
        [BitConverter]::GetBytes([uint32]16).CopyTo($bytes,284)
        [BitConverter]::GetBytes([uint32]16).CopyTo($bytes,768)
        [BitConverter]::GetBytes([uint16]0x200).CopyTo($bytes,772)
        [BitConverter]::GetBytes([uint16]2).CopyTo($bytes,774)
        & $em {param($bytes)
            $script:EF=[pscustomobject]@{Bytes=$bytes;ReadCount=0;FailState=$false;FailVersion=$false;ChangeDuringRead=$false;Secret='PRIVATE_TOKEN_97423';Version=[pscustomobject]@{CompanyName='Mozilla';ProductName='Mozilla Firefox 128';FileDescription='Mozilla Firefox';FileVersion='128';ProductVersion='128';OriginalFilename='firefox.exe';UnselectedSecret='PRIVATE_TOKEN_97423'}}
        } $bytes
    }
    $inventory=& $im {Get-AppInventory}
    $record=$inventory.Records[0];$unknown=$inventory.Records[1];$forged=$inventory.Records[2]
    $originalJson=$inventory|ConvertTo-Json -Depth 20 -Compress
    $planBefore=New-SafeUninstallPlan -Inventory $inventory -SelectedIds @($record.Id)
    Reset-EvidenceFixture
    $evidence=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
    Assert-True ($evidence.File.Status -eq 'Read') 'synthetic PE metadata read via mocked file providers'
    Assert-True ($evidence.Signature.CertificateTable -eq 'Present') 'PE certificate directory recognized structurally'
    Assert-True ($evidence.Signature.Status -eq 'NotVerified' -and $evidence.Signature.PublisherTrust -eq 'Unknown') 'certificate table is neither valid signature nor publisher trust'
    Assert-True ($evidence.File.MetadataTrust -eq 'SelfDeclaredNotAuthenticated') 'version metadata marked untrusted self-declaration'
    Assert-True (-not (($evidence|ConvertTo-Json -Depth 20).Contains('PRIVATE_TOKEN_97423'))) 'unselected metadata property not exported'
    $assessment=Get-AppAssessment -Record $record -AppEvidence $evidence
    Assert-True $assessment.DisplayOnly 'assessment is display-only'
    Assert-True ($assessment.IdentityConfidence -eq 'MetadataConsistentNotAuthenticated') 'matching file metadata does not authenticate app identity'
    Assert-True ('SafetyNotDetermined' -in $assessment.Unknowns -and 'NecessityUnknown' -in $assessment.Unknowns) 'metadata agreement does not determine safety or necessity'
    Assert-True (-not $assessment.Protection.OverrideApplied -and -not $assessment.Protection.EligibilityEvaluated) 'assessment cannot grant uninstall eligibility'
    Assert-True (-not $assessment.Research.AutomaticLookup -and $assessment.Research.NoDataTransmitted) 'research links do not perform network lookup'
    Assert-True (@($assessment.EvidenceLayers|Where-Object {$_.Layer -eq 'OfflineSignature' -and $_.Status -eq 'CertificateTablePresent'}).Count -eq 1) 'structural certificate-table evidence stays separate layer'
    Reset-EvidenceFixture
    $noFile=Get-AppEvidence -Record $record
    Assert-True ($noFile.File.Status -eq 'NotRequested' -and (& $em {$script:EF.ReadCount}) -eq 0) 'no explicitly selected file means no scan'
    $without=Get-AppAssessment -Record $record -AppEvidence $noFile
    Assert-True ($without.IdentityConfidence -eq 'Unverified') 'registration alone cannot authenticate identity'
    Reset-EvidenceFixture
    & $em {$script:EF.Version.CompanyName='Forged Corporation'}
    $conflict=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
    $a=Get-AppAssessment -Record $record -AppEvidence $conflict
    Assert-True ('FILE_COMPANY_REGISTRY_PUBLISHER_DIFFER' -in $a.ConflictCodes) 'file company conflict surfaced'
    Assert-True ('SafetyNotDetermined' -in $a.Unknowns -and -not $a.Protection.OverrideApplied) 'publisher conflict cannot change protection'
    Reset-EvidenceFixture
    $eu=Get-AppEvidence -Record $unknown -ExecutablePath 'C:\Fixture\firefox.exe'
    $a=Get-AppAssessment -Record $unknown -AppEvidence $eu
    Assert-True ($a.Protection.OriginalProtected -eq $true -and -not $a.Protection.OverrideApplied) 'Firefox-looking metadata cannot unprotect unknown program'
    Assert-True (@($a.CandidateCategories|Where-Object Category -eq 'Browser').Count -gt 0) 'metadata can suggest purpose without changing safety'
    Assert-Throws {New-SafeUninstallPlan -Inventory $inventory -SelectedIds @($unknown.Id)} 'unknown app still refused by uninstall plan after assessment'
    $a=Get-AppAssessment -Record $forged
    Assert-True ($a.Protection.OriginalProtected -eq $true) 'forged registry publisher retains protection'
    Assert-True (@($a.CandidateCategories|Where-Object Confidence -eq 'Medium').Count -eq 0) 'forged publisher is not bounded catalog identity match'
    $a=Get-AppAssessment -Record $unknown
    Assert-True (@($a.CandidateCategories).Count -eq 0 -and $a.IdentityConfidence -eq 'Unverified') 'no evidence leaves unknown program unknown'
    Reset-EvidenceFixture
    $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Private\PRIVATE_TOKEN_97423\random-name.exe'
    $a=Get-AppAssessment -Record $record -AppEvidence $ef
    Assert-True ('ExecutableOwnershipUnproven' -in $a.Unknowns) 'filename and selected path do not prove app ownership'
    Assert-True (-not (($a|ConvertTo-Json -Depth 20).Contains('PRIVATE_TOKEN_97423'))) 'assessment never echoes private selected path'
    Reset-EvidenceFixture
    & $em {$script:EF.Version.ProductName='SQL PRIVATE_TOKEN_97423';$script:EF.Version.FileDescription='CAD PRIVATE_TOKEN_97423'}
    $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\file.exe'
    $a=Get-AppAssessment -Record $record -AppEvidence $ef
    Assert-True ('MULTIPLE_WEAK_CATEGORY_CANDIDATES' -in $a.ConflictCodes) 'conflicting weak purpose hints remain explicit candidates'
    Assert-True (-not (($a|ConvertTo-Json -Depth 20).Contains('PRIVATE_TOKEN_97423'))) 'assessment output contains fixed rule findings, not private metadata text'
    Reset-EvidenceFixture
    & $em {[Array]::Clear($script:EF.Bytes,280,8)}
    $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
    $a=Get-AppAssessment -Record $record -AppEvidence $ef
    Assert-True ($ef.Signature.CertificateTable -eq 'Absent' -and $ef.Signature.Status -eq 'NotVerified') 'absent embedded certificate table is not signature validation'
    Assert-True ('SafetyNotDetermined' -in $a.Unknowns) 'absence of certificate table is not malware or safety conclusion'
    foreach($case in @('FailState','FailVersion','ChangeDuringRead')) {
        Reset-EvidenceFixture;& $em {param($field)$script:EF.$field=$true} $case
        $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
        $a=Get-AppAssessment -Record $record -AppEvidence $ef
        Assert-True ($ef.File.Status -eq 'Unknown' -and -not $ef.Complete) "$case fails closed in evidence collection"
        Assert-True ($a.IdentityConfidence -eq 'Unverified') "$case cannot authenticate identity"
        Assert-True (-not (($ef|ConvertTo-Json -Depth 20).Contains('PRIVATE_TOKEN_97423'))) "$case exception text secret not exported"
    }
    foreach($path in @('\\server\share\program.exe','C:\Fixture\file.exe:stream','C:\Fixture\..\file.exe','C:\Fixture\NUL.exe')) {
        Reset-EvidenceFixture
        $ef=Get-AppEvidence -Record $record -ExecutablePath $path
        Assert-True ($ef.File.Status -eq 'Unknown' -and (& $em {$script:EF.ReadCount}) -eq 0) 'unsafe file path rejected before filesystem provider'
    }
    Reset-EvidenceFixture
    $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
    foreach($case in @('RecordId','RecordHash','ObservedUtcPast','ObservedUtcFuture','SignatureTrust')) {
        $copy=$ef|ConvertTo-Json -Depth 20|ConvertFrom-Json
        switch($case){
            'RecordId' {$copy.RecordId=$unknown.Id}
            'RecordHash' {$copy.RecordHash=('b'*64)}
            'ObservedUtcPast' {$copy.ObservedUtc=[DateTime]::UtcNow.AddHours(-25).ToString('o')}
            'ObservedUtcFuture' {$copy.ObservedUtc=[DateTime]::UtcNow.AddHours(1).ToString('o')}
            'SignatureTrust' {$copy.Signature.Status='Valid';$copy.Signature.PublisherTrust='Trusted'}
        }
        $a=Get-AppAssessment -Record $record -AppEvidence $copy
        Assert-True (@($a.ConflictCodes).Count -gt 0) "$case evidence forgery/staleness rejected or flagged"
        Assert-True (-not $a.Protection.OverrideApplied -and 'SafetyNotDetermined' -in $a.Unknowns) "$case cannot grant safety or remove protection"
        if($case -eq 'SignatureTrust'){Assert-True ('UNSUPPORTED_SIGNATURE_TRUST_CLAIM' -in $a.ConflictCodes) 'forged Valid signature claim explicitly flagged'}
    }
    $bad=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json;$bad.Publisher='Changed'
    $a=Get-AppAssessment -Record $bad -AppEvidence $ef
    Assert-True ('RECORD_INTEGRITY_INVALID' -in $a.ConflictCodes -and @($a.CandidateCategories).Count -eq 0) 'modified inventory record is not analyzed as authenticated source'
    Assert-Throws {Get-AppEvidence -Record $bad -ExecutablePath 'C:\Fixture\firefox.exe'} 'modified inventory record rejected before evidence reads'
    Reset-EvidenceFixture
    & $em {$script:EF.Version.ProductVersion='129';$script:EF.Version.OriginalFilename='other.exe'}
    $ef=Get-AppEvidence -Record $record -ExecutablePath 'C:\Fixture\firefox.exe'
    $a=Get-AppAssessment -Record $record -AppEvidence $ef
    Assert-True ('FILE_VERSION_REGISTRY_VERSION_DIFFER' -in $a.ConflictCodes) 'version mismatch is reported, not ignored'
    Assert-True ('FILE_ORIGINAL_NAME_DIFFERS_FROM_SELECTED_NAME' -in $a.ConflictCodes) 'original filename mismatch is reported, not identity proof'
    Assert-True (-not $a.Protection.OverrideApplied -and 'SafetyNotDetermined' -in $a.Unknowns) 'version and filename mismatch do not claim malware or override protection'
    $planAfter=New-SafeUninstallPlan -Inventory $inventory -SelectedIds @($record.Id)
    Assert-True ($planBefore.PlanHash -ceq $planAfter.PlanHash) 'assessment leaves existing uninstall selection eligibility/hash unchanged'
    Assert-True (($inventory|ConvertTo-Json -Depth 20 -Compress) -ceq $originalJson) 'all assessment flows leave source records and protection byte-for-byte unchanged'
    Assert-True (& $im {param($r) Test-AppRecordIntegrity $r} $record) 'original record integrity retained'
    Write-Host ("PASS: {0} app evidence/assessment integration assertions; memory/provider fixtures only" -f $script:Count)
} finally {Remove-Module $im,$em,$am,$um -Force}




