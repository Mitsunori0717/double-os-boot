#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('AppManagerPackageTest_'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
$path=Join-Path $temp 'bundle.zip';$count=0
function Assert($v,$s){if(-not $v){throw ('PACKAGE_TEST_FAILED: '+$s)};$script:count++}
try{
    & (Join-Path $root 'package.ps1') -OutputPath $path|Out-Null
    $before=(Get-FileHash $path).Hash
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try{
        Assert ($zip.Entries.Count -eq 11) 'eleven whitelisted release files'
        foreach($e in $zip.Entries){
            Assert ($e.FullName -notmatch '\.\.\.|tests|jsonl' -and $e.FullName.StartsWith('windows-app-manager/')) 'safe archive entry'
            $reader=New-Object IO.BinaryReader($e.Open());try{$bytes=$reader.ReadBytes([int]$e.Length)}finally{$reader.Dispose()}
            $original=[IO.File]::ReadAllBytes((Join-Path $root $e.Name))
            Assert ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($original)) 'entry matches source'
        }
    }finally{$zip.Dispose()}
    $failed=$false;try{& (Join-Path $root 'package.ps1') -OutputPath $path|Out-Null}catch{$failed=$true}
    Assert ($failed -and (Get-FileHash $path).Hash -ceq $before) 'never overwrite existing package'
    foreach($bad in @('relative.zip','\\invalid\share\x.zip',($path+':stream.zip'))){$failed=$false;try{& (Join-Path $root 'package.ps1') -OutputPath $bad|Out-Null}catch{$failed=$true};Assert $failed 'unsafe path refused'}
}finally{
    $resolved=[IO.Path]::GetFullPath($temp);$base=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('AppManagerPackageTest_')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
Write-Output ('PASS packaging assertions='+$count)
