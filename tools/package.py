"""Build and verify a source-only Edge Box distribution using an explicit file list."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile

MANIFEST = 'package-manifest.json'
REQUIRED = {
    'README.md', 'release.json', 'package-files.txt', 'setup-all.cmd',
    'setup/setup-all.ps1', 'setup/setup-engine.psm1',
    'windows-host/01-create-field-vm.ps1', 'windows-host/vm-shutdown.psm1',
    'windows-host/vm-create-safety.psm1', 'windows-cpu-partition/cpu-partition.ps1',
    'storage-recovery/offline_image.py', 'storage-recovery/restore_image.py',
    'storage-recovery/convert_image.py', 'storage-recovery/HyperVRecovery.psm1',
    'tests/run-all.ps1', 'tools/package.py',
}
REQUIRED_GROUPS = {
    'setup': ('run-child.ps1', 'cpu-topology.cs', 'setup-all.cmd', 'check-status.cmd',
              '02-enable-hyperv.cmd', '05-create-edgebox.cmd', '06-auto-logon.cmd',
              '09-install-autostart.cmd', '10-partition-cpu.cmd', '11-install-shortcuts.cmd',
              '12-windows-update.cmd', '13-quiet-windows.cmd', 'tests/run-tests.ps1',
              'tests/test-safety.ps1', 'tests/test-vm-create-safety.ps1'),
    'windows-host': ('00-field-launcher.ps1', '02-start-field-vm.ps1',
                     '03-field-display-kiosk.ps1', '05-shutdown-all.ps1', '06-auto-logon.ps1',
                     '08-settings-console.ps1', '10-restart-edgebox.ps1', '11-io-passthrough.ps1',
                     '12-windows-update.ps1', '13-quiet-windows.ps1', 'build-startup-cover.ps1',
                     'host-restart-policy.psm1', 'service-restart-policy.psm1', 'service-restart-policy.cs',
                     'tests/test-service-restart-policy.ps1', 'shutdown-diagnostics.ps1',
                     'startup-cover.cs', 'tests/test-launcher-safety.ps1'),
    'windows-cpu-partition': ('cpu-console.ps1', 'cpu-monitor.ps1', 'cpu-apps.ps1',
                             'cpu-ui-theme.ps1', 'setup.cmd', 'console.cmd'),
    'storage-recovery': ('backup_set.py', 'larger_disk_layout.py', 'StorageRecovery.psm1',
                         'WindowsRecoveryInventory.psm1', 'WindowsRecoveryPlan.psm1',
                         'storage-recovery.ps1', 'restore-vm.ps1', 'windows-recovery.ps1',
                         'tests/run-tests.ps1', 'tests/test-hyperv-recovery.ps1',
                         'tests/test-hyperv-v2.ps1', 'tests/test-hyperv-wiring.ps1',
                         'tests/test-windows-expanded-plan.ps1', 'tests/test-windows-integration.ps1',
                         'tests/test-windows-inventory.ps1', 'tests/test-windows-plan.ps1',
                         'tests/test_backup_set.py', 'tests/test_convert_image.py',
                         'tests/test_larger_disk_layout.py', 'tests/test_offline_image.py',
                         'tests/test_restore_image.py'),
    'installer': ('bootstrap.cs', 'bootstrap.manifest', 'build-installer.cmd',
                  'build-installer.ps1', 'install.cmd', 'install.ps1',
                  'package-safety.psm1', 'tests/run-tests.ps1'),
    'tests': ('test_package.py', 'test_qemu_integration.py'),
}
REQUIRED.update(f'{folder}/{name}' for folder, names in REQUIRED_GROUPS.items() for name in names)
REQUIRED.update(('start.cmd',
                 'windows-cpu-partition/cpu-tool.psm1',
                 'windows-host/cpu-boot.psm1',
                 'windows-host/tests/test-cpu-preparation.ps1',
                 'windows-host/tests/test-start-safety.ps1',
                 'windows-host/field-start.cmd', 'windows-host/fix-black-screen.cmd',
                 'windows-host/04-reboot-to-field-native.ps1','windows-host/07-boot-appearance.ps1',
                 'windows-host/09-rename-to-edgebox.ps1','windows-host/99-fix-black-screen.ps1',
                 'docs/FRESH-INSTALL.md','docs/HARDWARE-ACCEPTANCE.md','VALIDATION.md','CHANGELOG.md'))
SOURCE_SUFFIXES = {'.md', '.ps1', '.psm1', '.cmd', '.py', '.cs', '.manifest', '.yml'}
ASSETS = {
    'windows-cpu-partition/fonts/Michroma-Regular.ttf',
    'windows-cpu-partition/fonts/OFL.txt',
    'windows-cpu-partition/images/app-icon.ico',
    'windows-cpu-partition/images/app-icon.png',
}
ROOT_METADATA = {'package-files.txt', 'release.json', '.gitignore', '.gitattributes'}
REQUIRED.update(ASSETS)
MAX_FILES = 4096
MAX_FILE_SIZE = 16 * 1024 * 1024
MAX_TOTAL_SIZE = 128 * 1024 * 1024
RESERVED_WINDOWS_NAME = re.compile(r'^(?:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\.|$)', re.I)


class PackageError(ValueError):
    pass


def require(value, code):
    if not value:
        raise PackageError(code)


def valid_name(name):
    require(isinstance(name, str) and name and len(name) <= 240
            and not any(c in name for c in '\\:<>"|?*')
            and not any(ord(c) < 32 for c in name), 'INVALID_PACKAGE_PATH')
    parts = name.split('/')
    require(all(p and p not in ('.', '..') and not p.endswith((' ', '.')) for p in parts),
            'INVALID_PACKAGE_PATH')
    require(not any(RESERVED_WINDOWS_NAME.match(p) for p in parts), 'INVALID_PACKAGE_PATH')
    require(not any(p.lower() in ('.git', '__pycache__', 'logs', 'tools-cache', 'startup-cover',
                                 'validation-results')
                    for p in parts), 'RUNTIME_DIRECTORY_FORBIDDEN')
    return name


def source_name(name):
    valid_name(name)
    require(name in ROOT_METADATA or name in ASSETS or PurePosixPath(name).name == '.gitignore' or
            PurePosixPath(name).suffix.lower() in SOURCE_SUFFIXES, 'NON_SOURCE_FILE_FORBIDDEN')
    require(PurePosixPath(name).name.lower() not in ('update-token.txt', 'settings.json'),
            'PRIVATE_FILE_FORBIDDEN')


def local_regular(path):
    for item in (path, *path.parents):
        if item.exists() or item.is_symlink():
            info = item.lstat()
            require(not stat.S_ISLNK(info.st_mode) and not getattr(info, 'st_file_attributes', 0) & 0x400,
                    'REPARSE_POINT_FORBIDDEN')
    require(path.is_file(), 'PACKAGE_SOURCE_MISSING:' + path.name)
    require(stat.S_ISREG(path.stat().st_mode), 'REGULAR_FILE_REQUIRED')


def load_spec(root):
    spec = root / 'package-files.txt'
    local_regular(spec)
    names = [line.strip() for line in spec.read_text(encoding='utf-8-sig').splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    require(len(names) == len(set(n.casefold() for n in names)), 'DUPLICATE_PACKAGE_PATH')
    require(len(names) < MAX_FILES, 'TOO_MANY_PACKAGE_FILES')
    require(REQUIRED <= set(names), 'REQUIRED_COMPONENT_NOT_LISTED')
    for name in names:
        source_name(name)
        local_regular(root / name)
    return sorted(names)


def build(root, destination):
    root, destination = Path(root).absolute(), Path(destination).absolute()
    require(destination.suffix.lower() == '.zip', 'ZIP_EXTENSION_REQUIRED')
    require(destination.parent.is_dir(), 'OUTPUT_DIRECTORY_REQUIRED')
    partial = Path(str(destination) + '.partial')
    require(not destination.exists() and not partial.exists(), 'OUTPUT_ALREADY_EXISTS')
    for item in (destination, partial, *destination.parents):
        require(not item.is_symlink() and not (item.exists() and
                getattr(item.lstat(), 'st_file_attributes', 0) & 0x400), 'REPARSE_POINT_FORBIDDEN')
    names = load_spec(root)
    content = {}
    total_size = 0
    for name in names:
        path = root / name
        local_regular(path)
        before = path.stat()
        require(before.st_size <= MAX_FILE_SIZE, 'UNEXPECTED_LARGE_SOURCE_FILE')
        total_size += before.st_size
        require(total_size <= MAX_TOTAL_SIZE, 'PACKAGE_TOTAL_SIZE_EXCEEDED')
        data = path.read_bytes()
        local_regular(path)
        after = path.stat()
        require((before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns) and len(data) == before.st_size,
                'SOURCE_CHANGED_DURING_BUILD')
        content[name] = data
    manifest = {'SchemaVersion': 1, 'Kind': 'EdgeBoxSourcePackage', 'Files': [
        {'Path': n, 'Size': len(content[n]), 'Sha256': hashlib.sha256(content[n]).hexdigest()}
        for n in names]}
    # Exclusive creation and no-replace publication protect an existing release.
    with open(partial, 'xb') as raw:
        with zipfile.ZipFile(raw, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, data in content.items():
                archive.writestr(name, data)
            archive.writestr(MANIFEST, json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        raw.flush()
        os.fsync(raw.fileno())
    verify(partial)
    os.link(partial, destination)
    partial.unlink()
    return manifest


def verify(path):
    path = Path(path).absolute()
    local_regular(path)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) <= MAX_FILES, 'TOO_MANY_PACKAGE_FILES')
        require(len(names) == len(set(n.casefold() for n in names)), 'DUPLICATE_ARCHIVE_ENTRY')
        require(MANIFEST in names, 'PACKAGE_MANIFEST_REQUIRED')
        total_size = 0
        for entry in archive.infolist():
            valid_name(entry.filename)
            mode = entry.external_attr >> 16
            require(not stat.S_ISLNK(mode), 'ARCHIVE_SYMLINK_FORBIDDEN')
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG) and not entry.is_dir(),
                    'ARCHIVE_NONREGULAR_FILE_FORBIDDEN')
            require(entry.file_size <= MAX_FILE_SIZE, 'UNEXPECTED_LARGE_SOURCE_FILE')
            total_size += entry.file_size
            require(total_size <= MAX_TOTAL_SIZE, 'PACKAGE_TOTAL_SIZE_EXCEEDED')
        def unique(pairs):
            value = {}
            for key, item in pairs:
                require(key not in value, 'DUPLICATE_MANIFEST_KEY')
                value[key] = item
            return value
        manifest = json.loads(archive.read(MANIFEST).decode('utf-8'), object_pairs_hook=unique)
        require(isinstance(manifest, dict) and set(manifest) == {'SchemaVersion', 'Kind', 'Files'}
                and type(manifest.get('SchemaVersion')) is int and
                manifest['SchemaVersion'] == 1 and manifest.get('Kind') == 'EdgeBoxSourcePackage'
                and isinstance(manifest.get('Files'), list), 'PACKAGE_MANIFEST_INVALID')
        listed = []
        for item in manifest['Files']:
            require(isinstance(item, dict) and set(item) == {'Path', 'Size', 'Sha256'}, 'FILE_RECORD_INVALID')
            name = item['Path']
            source_name(name)
            require(name in names and type(item['Size']) is int and item['Size'] >= 0,
                    'FILE_RECORD_INVALID')
            require(isinstance(item['Sha256'], str) and re.fullmatch('[0-9a-f]{64}', item['Sha256']),
                    'FILE_RECORD_INVALID')
            data = archive.read(name)
            require(len(data) == item['Size'] and hashlib.sha256(data).hexdigest() == item['Sha256'],
                    'PACKAGE_FILE_HASH_MISMATCH:' + name)
            listed.append(name)
        require(len(listed) == len(set(n.casefold() for n in listed)) and set(names) == set(listed) | {MANIFEST},
                'PACKAGE_FILE_SET_MISMATCH')
        require(REQUIRED <= set(listed), 'REQUIRED_COMPONENT_MISSING')
        spec_names = [line.strip() for line in archive.read('package-files.txt').decode('utf-8-sig').splitlines()
                      if line.strip() and not line.lstrip().startswith('#')]
        require(len(spec_names) == len(set(n.casefold() for n in spec_names)) and set(spec_names) == set(listed),
                'PACKAGE_SPEC_MISMATCH')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('build')
    p.add_argument('--root', default=str(Path(__file__).resolve().parent.parent))
    p.add_argument('--output', required=True)
    p = sub.add_parser('verify')
    p.add_argument('archive')
    args = parser.parse_args()
    try:
        result = build(args.root, args.output) if args.action == 'build' else verify(args.archive)
        print(json.dumps({'State': 'verified', 'Files': len(result['Files'])}))
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
