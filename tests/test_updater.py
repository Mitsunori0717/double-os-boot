"""Repository-only coverage for the legacy ZIP installation updater."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LegacyUpdateTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / '.git').exists(), 'Git index required to check release inventory')
    def test_raw_inventory_matches_git_sources(self):
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')[:-1]
        manifest = (ROOT / 'filelist.txt').read_text(encoding='utf-8-sig').splitlines()
        entries = [s for s in manifest if s and not s.startswith('#')]
        self.assertCountEqual(entries, tracked)

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell 5.1 updater')
    def test_api_fallback_and_destination_validation(self):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        with tempfile.TemporaryDirectory(prefix='edgebox-update-test-') as directory:
            folder = Path(directory)
            shutil.copyfile(ROOT / 'update.ps1', folder / 'update.ps1')
            # The mock returns an array as one pipeline object, like Invoke-RestMethod in 5.1.
            script = r'''
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'update.ps1'),[ref]$null,[ref]$null)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-UpdateFile'},$true)
. ([scriptblock]::Create($node.Extent.Text))
foreach ($relative in @('/absolute','../other','a/../other','a//b','AUX.txt','D:other','a/file:stream','.git/config','a/b.','a\b')) {
    $rejected=$false
    try { Resolve-UpdateFile $PSScriptRoot $relative | Out-Null } catch { $rejected=$true }
    if (-not $rejected) { throw "accepted invalid relative path: $relative" }
}
function Invoke-RestMethod {
    param($Uri,[switch]$UseBasicParsing,$Headers)
    $base='https://raw.githubusercontent.com/example/repo/fixture/'
    if ($Uri -eq 'https://api.github.com/repos/example/repo/contents?ref=fixture') {
        $items=@([pscustomobject]@{name='nested';type='dir';path='nested'},
            [pscustomobject]@{name='.gitignore';type='file';path='.gitignore';download_url=$base+'.gitignore'})
    } elseif ($Uri -eq 'https://api.github.com/repos/example/repo/contents/nested?ref=fixture') {
        $items=@([pscustomobject]@{name='child.ps1';type='file';path='nested/child.ps1';download_url=$base+'nested/child.ps1'})
    } else { throw "unexpected contents URL: $Uri" }
    return ,$items
}
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing,$Headers)
    if ($Uri -like '*/filelist.txt') { throw 'fixture has no raw manifest' }
    if ($Uri -notlike 'https://raw.githubusercontent.com/example/repo/fixture/*' -or -not $OutFile) { throw 'unknown file' }
    [IO.File]::WriteAllText($OutFile,'from api')
    if ($Uri -like '*/.gitignore') { [IO.File]::SetAttributes($OutFile,[IO.FileAttributes]::Hidden) }
}
& (Join-Path $PSScriptRoot 'update.ps1') -Repo example/repo -Ref fixture -Method files
if ($LASTEXITCODE) { exit $LASTEXITCODE }
'''
            driver = folder / 'fixture.ps1'
            driver.write_text(script, encoding='utf-8-sig')
            config = folder / 'setup' / 'settings.json'
            config.parent.mkdir()
            config.write_text('local')
            result = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                                     'Bypass', '-File', str(driver)], capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode(errors='replace'))
            for name in ('nested/child.ps1', '.gitignore'):
                self.assertEqual((folder / name).read_text(), 'from api')
            self.assertEqual(config.read_text(), 'local')
