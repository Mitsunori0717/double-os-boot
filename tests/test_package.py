import hashlib
import json
import os
from pathlib import Path
import sys
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import package


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='edgebox-package-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.root.mkdir()
        for name in package.REQUIRED:
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('fixture\n', encoding='utf-8')
        self.names = sorted(package.REQUIRED)
        self.spec()
        self.output = Path(self.temp.name) / 'source.zip'

    def spec(self):
        (self.root / 'package-files.txt').write_text('\n'.join(self.names)+'\n', encoding='utf-8')

    def rewrite(self, mutate):
        with zipfile.ZipFile(self.output) as source:
            files = {name: source.read(name) for name in source.namelist()}
        mutate(files)
        with zipfile.ZipFile(self.output, 'w') as target:
            for name, data in files.items():
                target.writestr(name, data)

    def test_round_trip_contains_both_products_and_no_runtime_data(self):
        (self.root / 'setup/settings.json').write_text('{"private":true}')
        (self.root / 'update-token.txt').write_text('fixture-secret')
        (self.root / 'storage-recovery/disk.raw').write_bytes(b'fixture-disk')
        result = package.build(self.root, self.output)
        self.assertEqual(package.verify(self.output), result)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()), set(self.names) | {package.MANIFEST})

    def test_missing_dependency_prevents_output_creation(self):
        (self.root / 'windows-host/vm-shutdown.psm1').unlink()
        with self.assertRaises(package.PackageError):
            package.build(self.root, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(Path(str(self.output)+'.partial').exists())

    def test_required_dependency_cannot_be_omitted_from_list(self):
        self.names.remove('windows-host/vm-shutdown.psm1')
        self.spec()
        with self.assertRaisesRegex(package.PackageError, 'REQUIRED_COMPONENT_NOT_LISTED'):
            package.build(self.root, self.output)

    def test_transitive_setup_and_validation_dependencies_are_required(self):
        for name in ('setup/run-child.ps1', 'windows-host/build-startup-cover.ps1',
                     'windows-cpu-partition/cpu-apps.ps1', 'tests/test_qemu_integration.py',
                     'installer/package-safety.psm1'):
            with self.subTest(path=name):
                self.names = sorted(package.REQUIRED - {name})
                self.spec()
                with self.assertRaisesRegex(package.PackageError, 'REQUIRED_COMPONENT_NOT_LISTED'):
                    package.build(self.root, self.output)

    def test_existing_output_and_partial_are_preserved(self):
        for destination in (self.output, Path(str(self.output)+'.partial')):
            with self.subTest(path=destination):
                destination.write_bytes(b'previous-artifact')
                with self.assertRaisesRegex(package.PackageError, 'OUTPUT_ALREADY_EXISTS'):
                    package.build(self.root, self.output)
                self.assertEqual(destination.read_bytes(), b'previous-artifact')
                destination.unlink()

    def test_traversal_and_private_entries_are_rejected(self):
        for name in ('../README.md', '/README.md', 'C:/README.md', 'setup/settings.json',
                     'tools/CpuGroups.exe', 'setup/logs/output.md', '.git/config'):
            with self.subTest(path=name):
                self.names = sorted(package.REQUIRED) + [name]
                self.spec()
                with self.assertRaises(package.PackageError):
                    package.build(self.root, self.output)

    def test_case_insensitive_duplicate_rejected(self):
        self.names.append('readme.md')
        self.spec()
        with self.assertRaisesRegex(package.PackageError, 'DUPLICATE_PACKAGE_PATH'):
            package.build(self.root, self.output)

    def test_windows_unextractable_names_are_rejected(self):
        for name in ('setup/NUL.ps1', 'setup/con.txt', 'aux/ok.py', 'setup/COM1.py',
                     'setup/LPT\u00b9.py', 'setup/bad?.ps1', 'setup/bad*.py',
                     'setup/a|b.py', 'setup/a<b.py'):
            with self.subTest(path=name):
                with self.assertRaisesRegex(package.PackageError, 'INVALID_PACKAGE_PATH'):
                    package.valid_name(name)

    def test_validation_output_is_never_source(self):
        with self.assertRaisesRegex(package.PackageError, 'RUNTIME_DIRECTORY_FORBIDDEN'):
            package.source_name('validation-results/private.md')

    def test_nested_gitignore_is_distributed(self):
        name = 'storage-recovery/.gitignore'
        (self.root / name).write_text('*.raw\n*.vhdx\n')
        self.names.append(name)
        self.spec()
        package.build(self.root, self.output)
        self.assertIn(name, {item['Path'] for item in package.verify(self.output)['Files']})

    def test_reparse_source_or_parent_is_rejected(self):
        original = Path.lstat
        for reparse in (self.root / 'README.md', self.root):
            with self.subTest(path=str(reparse)):
                def lstat(path, *args, **kwargs):
                    info = original(path, *args, **kwargs)
                    if path == reparse:
                        return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400)
                    return info
                with mock.patch.object(Path, 'lstat', lstat):
                    with self.assertRaisesRegex(package.PackageError, 'REPARSE_POINT_FORBIDDEN'):
                        package.build(self.root, self.output)
                self.assertFalse(self.output.exists())

    def test_reparse_output_parent_is_rejected(self):
        original = Path.lstat
        def lstat(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            if path == self.output.parent:
                return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400)
            return info
        with mock.patch.object(Path, 'lstat', lstat):
            with self.assertRaisesRegex(package.PackageError, 'REPARSE_POINT_FORBIDDEN'):
                package.build(self.root, self.output)
        self.assertFalse(self.output.exists())

    def test_corrupt_source_bytes_in_archive_rejected(self):
        package.build(self.root, self.output)
        self.rewrite(lambda files: files.update({'README.md': b'altered'}))
        with self.assertRaisesRegex(package.PackageError, 'PACKAGE_FILE_HASH_MISMATCH'):
            package.verify(self.output)

    def test_unlisted_archive_entry_rejected(self):
        package.build(self.root, self.output)
        self.rewrite(lambda files: files.update({'extra.ps1': b'fixture'}))
        with self.assertRaisesRegex(package.PackageError, 'PACKAGE_FILE_SET_MISMATCH'):
            package.verify(self.output)

    def test_zip_traversal_is_rejected_before_any_extraction(self):
        package.build(self.root, self.output)
        self.rewrite(lambda files: files.update({'../outside.ps1': b'fixture'}))
        with self.assertRaisesRegex(package.PackageError, 'INVALID_PACKAGE_PATH'):
            package.verify(self.output)

    def test_manifest_cannot_hide_omitted_component(self):
        package.build(self.root, self.output)
        def remove(files):
            name = 'windows-host/vm-shutdown.psm1'
            files.pop(name)
            manifest = json.loads(files[package.MANIFEST])
            manifest['Files'] = [f for f in manifest['Files'] if f['Path'] != name]
            files[package.MANIFEST] = json.dumps(manifest).encode()
        self.rewrite(remove)
        with self.assertRaisesRegex(package.PackageError, 'REQUIRED_COMPONENT_MISSING'):
            package.verify(self.output)

    def test_manifest_schema_rejects_unknown_fields_and_boolean_version(self):
        package.build(self.root, self.output)
        for update in ({'SchemaVersion': True}, {'Unexpected': 'ignored before'}):
            with self.subTest(update=update):
                def change(files):
                    manifest = json.loads(files[package.MANIFEST])
                    manifest.pop('Unexpected', None)
                    manifest['SchemaVersion'] = 1
                    manifest.update(update)
                    files[package.MANIFEST] = json.dumps(manifest).encode()
                self.rewrite(change)
                with self.assertRaisesRegex(package.PackageError, 'PACKAGE_MANIFEST_INVALID'):
                    package.verify(self.output)

    def test_duplicate_manifest_keys_are_rejected(self):
        package.build(self.root, self.output)
        self.rewrite(lambda files: files.update({package.MANIFEST: b'{"SchemaVersion":1,"SchemaVersion":1}'}))
        with self.assertRaisesRegex(package.PackageError, 'DUPLICATE_MANIFEST_KEY'):
            package.verify(self.output)

    def test_archive_entry_and_total_size_limits_are_enforced(self):
        package.build(self.root, self.output)
        with mock.patch.object(package, 'MAX_FILES', len(self.names)):
            with self.assertRaisesRegex(package.PackageError, 'TOO_MANY_PACKAGE_FILES'):
                package.verify(self.output)
        with mock.patch.object(package, 'MAX_TOTAL_SIZE', 1):
            with self.assertRaisesRegex(package.PackageError, 'PACKAGE_TOTAL_SIZE_EXCEEDED'):
                package.verify(self.output)

    def test_nonregular_zip_member_is_rejected(self):
        package.build(self.root, self.output)
        with zipfile.ZipFile(self.output) as archive:
            files = {name: archive.read(name) for name in archive.namelist()}
        with zipfile.ZipFile(self.output, 'w') as archive:
            for name, data in files.items():
                info = zipfile.ZipInfo(name)
                if name == 'README.md':
                    info.create_system = 3
                    info.external_attr = (stat.S_IFIFO | 0o600) << 16
                archive.writestr(info, data)
        with self.assertRaisesRegex(package.PackageError, 'ARCHIVE_NONREGULAR_FILE_FORBIDDEN'):
            package.verify(self.output)


@unittest.skipUnless(os.name == 'nt', 'Windows PowerShell report runner')
class ValidationRunnerTests(unittest.TestCase):
    def test_missing_python_still_writes_failed_report(self):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        runner = Path(__file__).resolve().parent / 'run-all.ps1'
        with tempfile.TemporaryDirectory(prefix='edgebox-runner-report-test-') as directory:
            report = Path(directory) / 'report'
            environment = dict(os.environ, PATH='')
            result = subprocess.run([str(powershell), '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', str(runner), '-ReportDirectory', str(report)], env=environment,
                capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertNotEqual(result.returncode, 0)
            data = json.loads((report / 'results.json').read_text(encoding='utf-8-sig'))
            self.assertFalse(data['Passed'])
            self.assertTrue(any(check['Name'] == 'Runner' and check['ExitCode'] != 0 for check in data['Checks']))
            self.assertEqual(data['PythonTestsRun'], 0)
            self.assertEqual(data['QemuTestsPassed'], 0)

    def test_runner_counts_skips_and_rejects_missing_required_tests(self):
        powershell = Path(os.environ['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        runner = Path(__file__).resolve().parent / 'run-all.ps1'
        with tempfile.TemporaryDirectory(prefix='edgebox-runner-count-test-') as directory:
            # Load only the actual runner function, then use harmless stdout-only children.
            script = r'''
$ErrorActionPreference='Stop'
$ReportDirectory='__REPORT__'
$exe='__POWERSHELL__'
$ast=[Management.Automation.Language.Parser]::ParseFile('__RUNNER__',[ref]$null,[ref]$null)
$function=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-FileCheck'},$false))[0]
. ([scriptblock]::Create($function.Extent.Text))
$script:results=New-Object 'System.Collections.Generic.List[object]'
$RequireQemu=$false
Invoke-FileCheck 'Python-fixture' $exe @('-NoProfile','-Command',"Write-Output 'Ran 4 tests'; Write-Output 'OK (skipped=1)'; exit 0")
Invoke-FileCheck 'Python-empty' $exe @('-NoProfile','-Command',"Write-Output 'Ran 0 tests'; Write-Output 'OK'; exit 0")
$global:LASTEXITCODE=0
Invoke-FileCheck 'missing-executable' (Join-Path $ReportDirectory 'absent.exe') @()
$RequireQemu=$true
Invoke-FileCheck 'Python-recovery' $exe @('-NoProfile','-Command',"Write-Output 'Ran 4 tests'; Write-Output 'OK'; exit 0")
Invoke-FileCheck 'Python-release' $exe @('-NoProfile','-Command',"Write-Output 'test_multiple_copy_chunks (test_qemu_integration.QemuPipelineTests.test_multiple_copy_chunks) ... ok'; Write-Output 'test_unaligned_megabyte_size (test_qemu_integration.QemuPipelineTests.test_unaligned_megabyte_size) ... ok'; Write-Output 'Ran 4 tests'; Write-Output 'OK (skipped=1)'; exit 0")
Invoke-FileCheck 'native-stderr-success' $exe @('-NoProfile','-Command',"[Console]::Error.WriteLine('successful process stderr'); exit 0")
Invoke-FileCheck 'native-stderr-failure' $exe @('-NoProfile','-Command',"[Console]::Error.WriteLine('failed process stderr'); exit 23")
ConvertTo-Json -InputObject @($script:results.ToArray()) -Depth 5 -Compress
'''
            for marker, value in (('__REPORT__', directory), ('__POWERSHELL__', str(powershell)), ('__RUNNER__', str(runner))):
                script = script.replace(marker, value.replace("'", "''"))
            result = subprocess.run([str(powershell), '-NoProfile', '-NonInteractive', '-Command', script],
                capture_output=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            rows = json.loads(result.stdout.decode(errors='replace').splitlines()[-1])
            self.assertEqual(rows[0]['TestsRun'], 4)
            self.assertEqual(rows[0]['Skipped'], 1)
            self.assertEqual(rows[0]['ExitCode'], 0)
            self.assertNotEqual(rows[1]['ExitCode'], 0)
            self.assertNotEqual(rows[2]['ExitCode'], 0)
            self.assertNotEqual(rows[3]['ExitCode'], 0)
            self.assertEqual(rows[4]['QemuTestsPassed'], 2)
            self.assertEqual(rows[4]['Skipped'], 1)
            self.assertEqual(rows[4]['ExitCode'], 0)
            self.assertEqual(rows[5]['ExitCode'], 0)
            self.assertEqual(rows[6]['ExitCode'], 23)


if __name__ == '__main__':
    unittest.main()
