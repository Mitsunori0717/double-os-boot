$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\PurposeCatalog.psm1') -Force
$n=0
function Assert($v,$msg){if(-not $v){throw $msg};$script:n++}
$cases=ConvertFrom-Json '[["Google Chrome","Google LLC","chrome"],["Mozilla Firefox","Mozilla","firefox"],["Brave","Brave Software Inc","brave"],["7-Zip","Igor Pavlov","7zip"],["Notepad++","Notepad++ Team","notepadpp"],["VLC media player","VideoLAN","vlc"],["Audacity","Audacity Team","audacity"],["OBS Studio","OBS Project","obs"],["GIMP","The GIMP Team","gimp"],["Inkscape","Inkscape","inkscape"],["Blender","Blender Foundation","blender"],["Zoom","Zoom Video Communications, Inc.","zoom"],["Slack","Slack Technologies Inc.","slack"],["Discord","Discord Inc.","discord"],["Steam","Valve Corporation","steam"],["Epic Games Launcher","Epic Games, Inc.","epic"],["Git","The Git Development Community","git"],["PyCharm","JetBrains s.r.o.","pycharm"],["Microsoft Visual Studio Code","Microsoft Corporation","vscode"]]'
foreach($case in $cases){
 $p=Get-AppPurposeAnalysis $case[0] $case[1]
 Assert ($p.Matched -and $p.RuleId -eq $case[2]) ('known product '+$case[0])
 Assert ($p.SourceUrls.Count -eq 1 -and $p.SourceUrls[0] -match '^https://') 'primary source present'
 Assert ($p.Dependencies -eq 'Unknown' -and $p.Necessity -eq 'Unknown' -and $p.Authenticity -eq 'NotVerified' -and $p.NetworkActivity -eq 'NotMeasured') 'no safety necessity or telemetry claim'
 Assert (-not(Get-AppPurposeAnalysis ($case[0]+' Evil Helper') $case[1]).Matched) 'arbitrary suffix no match'
 Assert (-not(Get-AppPurposeAnalysis $case[0] 'Unverified Other Publisher').Matched) 'publisher mismatch unknown'
}
foreach($name in @('7-Zip 24.09 (x64)','7-Zip 24','7-Zip')){
 Assert (Get-AppPurposeAnalysis $name 'Igor Pavlov').Matched 'bounded version names'
}
foreach($bad in @('7-Zip Evil','7-Zip Security','7-Zip Repair Agent','A7-Zip','7-Zip+',"7-Zip`n",('7-Zip'+[char]0x202e),'7-Zip 1.2.3.4.5.6')){
 Assert (-not(Get-AppPurposeAnalysis $bad 'Igor Pavlov').Matched) 'noncatalog does not become unprotected'
}
Assert (-not(Get-AppPurposeAnalysis '7-Zip' '').Matched) 'missing publisher unknown'
Assert (Get-AppPurposeAnalysis 'Git' 'The Git Development Community').DependencyReviewRequired 'developer dependency review'
# Internal record builder only, no registry, package, network, or process query.
Import-Module (Join-Path $PSScriptRoot '..\AppInventory.psm1') -Force
$m=Get-Module AppInventory
foreach($case in @(@('Microsoft Visual Studio Code','Microsoft Corporation'),@('7-Zip Driver','Igor Pavlov'),@('7-Zip','Microsoft Corporation'),@('Git','The Git Development Community'))){
 $record=& $m {param($name,$publisher)
  New-AiRecord @{DisplayName=$name;Publisher=$publisher;SystemComponent=0;NoRemove=0;WindowsInstaller=1} ([pscustomobject][ordered]@{Kind='Registry';Hive='LocalMachine';View='Registry64';Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}';PackageFullName='';UserSid='fixture'})
 } $case[0] $case[1]
 Assert $record.Protection.Protected 'protection priority maintained'
 Assert (Test-AppRecordIntegrity $record) 'new purpose metadata hash bound'
}
$r=& $m {New-AiRecord @{DisplayName='7-Zip';Publisher='Igor Pavlov';SystemComponent=0;NoRemove=0;WindowsInstaller=1} ([pscustomobject][ordered]@{Kind='Registry';Hive='LocalMachine';View='Registry64';Key='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}';PackageFullName='';UserSid='fixture'})}
$r.Evidence.PurposeSourceUrls=@('https://invalid.example/')
Assert (-not(Test-AppRecordIntegrity $r)) 'provenance mutation detected'
Write-Output "PASS purpose assertions=$n (local rules and synthetic records only)"
