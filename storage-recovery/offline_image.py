#!/usr/bin/env python3
"""Edge Box offline all-sector reader. Never opens a physical device for write."""
import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys

CHUNK = 4 * 1024 * 1024
RESERVE = 1024 * 1024 * 1024

class SafetyError(RuntimeError):
    pass

def require(condition, code):
    if not condition:
        raise SafetyError(code)

def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def regular_path(value):
    raw = str(value)
    require(not raw.startswith(('\\\\', '//', '/dev/', '/proc/', '/sys/')), 'SPECIAL_PATH_FORBIDDEN')
    p = Path(value).absolute()
    for part in [p] + list(p.parents):
        require(not part.is_symlink(), 'SYMLINK_FORBIDDEN')
        if part.exists():
            require(not (getattr(part.stat(), 'st_file_attributes', 0) & 0x400), 'REPARSE_POINT_FORBIDDEN')
    return p

def lsblk_rows():
    data = json.loads(subprocess.run(['lsblk', '--json', '--bytes', '--paths', '--output',
        'NAME,KNAME,PKNAME,TYPE,SIZE,LOG-SEC,MODEL,SERIAL,WWN,MAJ:MIN,MOUNTPOINTS'],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout)
    rows = []
    def visit(node):
        rows.append(node)
        for child in node.get('children', []):
            visit(child)
    for node in data['blockdevices']:
        visit(node)
    require(rows, 'DISK_INVENTORY_EMPTY')
    return rows

def row_device(row):
    value = row.get('maj:min')
    require(isinstance(value, str) and re.fullmatch(r'\d+:\d+', value), 'DEVICE_ID_UNKNOWN')
    return tuple(map(int, value.split(':')))

def disk_identity(row):
    require(row.get('type') == 'disk', 'WHOLE_PHYSICAL_DISK_REQUIRED')
    serial = str(row.get('serial') or '').strip()
    model = str(row.get('model') or '').strip()
    size = int(row.get('size') or 0)
    sector = int(row.get('log-sec') or 0)
    require(serial and model and size > 0 and sector in (512, 4096) and size % sector == 0,
            'SOURCE_IDENTITY_INCOMPLETE')
    unique = str(row.get('wwn') or '').strip() or ('serial:' + model + ':' + serial)
    return dict(UniqueId=unique, SerialNumber=serial, Model=model, Size=size, LogicalSectorSize=sector)

def require_unique_identity(rows, identity):
    matches = [r for r in rows if r.get('type') == 'disk' and
               str(r.get('serial') or '').strip() == identity['SerialNumber'] and
               str(r.get('model') or '').strip() == identity['Model'] and
               int(r.get('size') or 0) == identity['Size'] and
               int(r.get('log-sec') or 0) == identity['LogicalSectorSize']]
    require(len(matches) == 1, 'SOURCE_IDENTITY_AMBIGUOUS')

def expected_matches(identity, expected):
    for key in ('SerialNumber', 'Model', 'Size', 'LogicalSectorSize'):
        require(identity.get(key) == expected.get(key), 'SOURCE_IDENTITY_MISMATCH:' + key)

def decode_mount(s):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), s)

def mount_rows(text):
    result = []
    for line in text.splitlines():
        left, right = line.split(' - ', 1)
        a, b = left.split(), right.split()
        require(len(a) >= 6 and len(b) >= 3, 'MOUNT_INVENTORY_INVALID')
        result.append(dict(device=tuple(map(int, a[2].split(':'))), path=decode_mount(a[4]),
                           options=a[5].split(','), fs=b[0], source=decode_mount(b[1])))
    require(result, 'MOUNT_INVENTORY_EMPTY')
    return result

def live_environment():
    require(sys.platform == 'linux' and os.geteuid() == 0, 'LINUX_ROOT_REQUIRED')
    cmdline = Path('/proc/cmdline').read_text().split()
    require('boot=live' in cmdline and not any(x.startswith('persistence') for x in cmdline), 'NONPERSISTENT_LIVE_BOOT_REQUIRED')
    require(Path('/run/live/medium').is_dir(), 'LIVE_MEDIUM_NOT_FOUND')
    mounts = mount_rows(Path('/proc/self/mountinfo').read_text())
    require(any(m['path'] == '/' and m['fs'] in ('overlay', 'squashfs') for m in mounts), 'LIVE_ROOT_NOT_CONFIRMED')
    # Fail on any detected VM process; never stop a process on the operator's behalf.
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            name = (proc / 'comm').read_text().strip().lower()
        except FileNotFoundError:
            continue  # process exited during inventory
        require(not any(x in name for x in ('qemu', 'kvm', 'vmware', 'virtualbox', 'vboxheadless')), 'VIRTUAL_MACHINE_PROCESS_PRESENT')
    return mounts

def find_source(rows, dev):
    matches = [r for r in rows if row_device(r) == dev]
    require(len(matches) == 1, 'SOURCE_MISSING_OR_AMBIGUOUS')
    return matches[0]

def descendants(rows, source):
    names = {source['name']}
    selected = [source]
    changed = True
    while changed:
        changed = False
        for row in rows:
            if row in selected:
                continue
            if row.get('pkname') in names:
                require(row.get('type') == 'part', 'MAPPED_SOURCE_STORAGE_UNSUPPORTED')
                selected.append(row)
                names.add(row['name'])
                changed = True
    return selected

def physical_parent(rows, dev):
    row = find_source(rows, dev)
    seen = set()
    while row.get('type') == 'part':
        require(row['name'] not in seen, 'STORAGE_TOPOLOGY_CYCLE')
        seen.add(row['name'])
        matches = [r for r in rows if r.get('name') == row.get('pkname')]
        require(len(matches) == 1, 'STORAGE_PARENT_UNKNOWN')
        row = matches[0]
    require(row.get('type') == 'disk', 'MAPPED_DESTINATION_STORAGE_UNSUPPORTED')
    return row_device(row)

def require_unmounted(related, mounts):
    devices = {row_device(r) for r in related}
    require(not any(m['device'] in devices for m in mounts), 'SOURCE_OR_PARTITION_MOUNTED')
    for row in related:
        require('mountpoints' in row and not any(row['mountpoints'] or []), 'SOURCE_MOUNT_STATE_UNKNOWN_OR_USED')
    return devices

def require_source_write_protected(related):
    """Observe existing kernel write protection; never set/clear read-only flags."""
    for row in related:
        ro_path = Path('/sys/dev/block/%d:%d/ro' % row_device(row))
        try:
            status = ro_path.read_text().strip()
        except OSError as exc:
            raise SafetyError('SOURCE_WRITE_PROTECTION_REQUIRED') from exc
        require(status == '1', 'SOURCE_WRITE_PROTECTION_REQUIRED')

def require_readonly_fd(fd, fcntl):
    try:
        readonly = struct.unpack('i', fcntl.ioctl(fd, 0x125e, b'\0'*4))[0]  # BLKROGET
    except (OSError, struct.error) as exc:
        raise SafetyError('SOURCE_WRITE_PROTECTION_REQUIRED') from exc
    require(readonly == 1, 'SOURCE_WRITE_PROTECTION_REQUIRED')

def preflight(source, destination, expected, require_capacity=True):
    mounts = live_environment()
    source = Path(source).resolve(strict=True)
    info = source.stat()
    require(stat.S_ISBLK(info.st_mode), 'SOURCE_NOT_BLOCK_DEVICE')
    dev = (os.major(info.st_rdev), os.minor(info.st_rdev))
    rows = lsblk_rows()
    row = find_source(rows, dev)
    identity = disk_identity(row)
    expected_matches(identity, expected)
    require_unique_identity(rows, identity)
    related = descendants(rows, row)
    devices = require_unmounted(related, mounts)
    require_source_write_protected(related)
    for r in related:
        sysnode = Path('/sys/dev/block/%d:%d' % row_device(r))
        require(sysnode.exists(), 'SOURCE_SYSFS_MISSING')
        holders = sysnode / 'holders'
        require(holders.is_dir() and not list(holders.iterdir()), 'SOURCE_HAS_HOLDERS')
    for line in Path('/proc/swaps').read_text().splitlines()[1:]:
        path = Path(decode_mount(line.split()[0]))
        entry = path.stat()
        swapdev = ((os.major(entry.st_rdev), os.minor(entry.st_rdev)) if stat.S_ISBLK(entry.st_mode)
                   else (os.major(entry.st_dev), os.minor(entry.st_dev)))
        require(swapdev not in devices, 'SOURCE_IN_SWAP_USE')
    destination = regular_path(destination)
    require(destination.is_dir(), 'DESTINATION_DIRECTORY_REQUIRED')
    deststat = destination.stat()
    destdev = (os.major(deststat.st_dev), os.minor(deststat.st_dev))
    # Restrict v1 to local plain filesystems with hard links; no network/LVM/RAID ambiguity.
    destmounts = [m for m in mounts if m['device'] == destdev and
                  (str(destination) == m['path'] or str(destination).startswith(m['path'].rstrip('/') + '/'))]
    require(destmounts, 'DESTINATION_MOUNT_UNKNOWN')
    mount = max(destmounts, key=lambda m: len(m['path']))
    require(mount['fs'] in ('ext4', 'xfs', 'ntfs3') and 'rw' in mount['options'], 'DESTINATION_FILESYSTEM_UNSUPPORTED')
    require(physical_parent(rows, destdev) != dev, 'SOURCE_EQUALS_DESTINATION_DISK')
    if require_capacity:
        require(shutil.disk_usage(destination).free >= identity['Size'] + RESERVE, 'DESTINATION_CAPACITY_INSUFFICIENT')
    return source, destination, identity, dev

@contextlib.contextmanager
def output_directory(path):
    """Pin a no-symlink directory fd on Linux; fixture writes use ordinary paths elsewhere."""
    path = regular_path(path)
    require(path.is_dir(), 'DESTINATION_DIRECTORY_REQUIRED')
    fd = None
    if sys.platform == 'linux':
        fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        def create(name, binary=True):
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,180}', name), 'OUTPUT_NAME_INVALID')
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, 'O_NOFOLLOW'):
                flags |= os.O_NOFOLLOW
            out = os.open(name if fd is not None else str(path / name), flags, 0o600,
                          **({'dir_fd': fd} if fd is not None else {}))
            return os.fdopen(out, 'wb' if binary else 'w', **({} if binary else {'encoding':'utf-8'}))
        yield path, fd, create
    finally:
        if fd is not None:
            os.close(fd)

def digest_file(file, size):
    h, count = hashlib.sha256(), 0
    while True:
        data = file.read(CHUNK)
        if not data:
            break
        count += len(data)
        require(count <= size, 'READBACK_LENGTH_MISMATCH')
        h.update(data)
    require(count == size, 'READBACK_LENGTH_MISMATCH')
    return h.hexdigest()

def copy_stream(stream, destination, name, identity, mode, final_check=lambda: None):
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,80}', name), 'OUTPUT_NAME_INVALID')
    require(not re.fullmatch(r'(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])', name), 'OUTPUT_NAME_INVALID')
    size = identity['Size']
    require(isinstance(size, int) and size > 0 and size % identity['LogicalSectorSize'] == 0, 'SOURCE_SIZE_INVALID')
    require(shutil.disk_usage(destination).free >= size + RESERVE, 'DESTINATION_CAPACITY_INSUFFICIENT')
    base = name + '.raw'
    filenames = [base, base+'.partial', base+'.manifest.json', base+'.manifest.json.partial', base+'.events.jsonl']
    count = 0
    with output_directory(destination) as (directory, dirfd, create):
        require(not any((directory / f).exists() for f in filenames), 'OUTPUT_ALREADY_EXISTS')
        # Lock by creating the unique log first. A losing concurrent invocation never modifies it.
        with create(base+'.events.jsonl', False) as log:
            def event(state, **fields):
                log.write(json.dumps(dict(Utc=utc(), State=state, BytesCompleted=count,
                    ExpectedBytes=size, Source=identity, **fields), ensure_ascii=True) + '\n')
                log.flush()
                os.fsync(log.fileno())
            try:
                event('partial', Mode=mode)
                h = hashlib.sha256()
                next_progress = 256 * 1024 * 1024
                with create(base+'.partial') as output:
                    while count < size:
                        data = stream.read(min(CHUNK, size-count))
                        require(data, 'SOURCE_SHORT_READ')
                        require(len(data) <= size-count, 'SOURCE_OVERREAD')
                        view = memoryview(data)
                        while view:
                            n = output.write(view)
                            require(n is not None and 0 < n <= len(view), 'OUTPUT_SHORT_WRITE')
                            view = view[n:]
                        h.update(data)
                        count += len(data)
                        if count >= next_progress:
                            event('copying', DurableImage=False)
                            next_progress = count + 256 * 1024 * 1024
                    require(stream.read(1) == b'', 'SOURCE_LONGER_THAN_EXPECTED')
                    output.flush()
                    os.fsync(output.fileno())
                event('copied')
                readflags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
                readfd = os.open(base+'.partial' if dirfd is not None else str(directory/(base+'.partial')),
                                 readflags, **({'dir_fd':dirfd} if dirfd is not None else {}))
                with os.fdopen(readfd, 'rb') as reader:
                    require(stat.S_ISREG(os.fstat(reader.fileno()).st_mode), 'READBACK_NOT_REGULAR')
                    require(digest_file(reader, size) == h.hexdigest(), 'READBACK_HASH_MISMATCH')
                final_check()
                manifest = dict(SchemaVersion=1, State='verified', Size=size, Sha256=h.hexdigest(),
                    CreatedUtc=utc(), RestoreTested=False, IntegrityOnly=True,
                    Metadata=dict(Source=identity, AcquisitionMode=mode, FullSectorImage=True,
                                  SourceWriteProtected=(mode == 'offline-block'),
                                  GuestConsistency='offline-environment' if mode=='offline-block' else 'fixture-only'),
                    Tool='EdgeBoxOfflineImage/1')
                with create(base+'.manifest.json.partial', False) as out:
                    json.dump(manifest, out, indent=2)
                    out.write('\n'); out.flush(); os.fsync(out.fileno())
                # Hard-link promotion is atomic and refuses to replace an existing destination.
                # Unlike rename on POSIX, it cannot overwrite a concurrently-created final name.
                for partial, final in [(base+'.partial', base), (base+'.manifest.json.partial', base+'.manifest.json')]:
                    kwargs = {'src_dir_fd':dirfd,'dst_dir_fd':dirfd} if dirfd is not None else {}
                    src = partial if dirfd is not None else str(directory/partial)
                    dst = final if dirfd is not None else str(directory/final)
                    os.link(src, dst, **kwargs)
                    os.unlink(partial if dirfd is not None else str(directory/partial),
                              **({'dir_fd':dirfd} if dirfd is not None else {}))
                if dirfd is not None:
                    os.fsync(dirfd)
                event('verified', Sha256=h.hexdigest(), RestoreTested=False)
                return manifest
            except BaseException as exc:
                try:
                    event('failed', ErrorType=type(exc).__name__, Error=str(exc), Errno=getattr(exc,'errno',None))
                except Exception:
                    pass
                raise

def acquire(source, destination, name, expected):
    source, destination, identity, dev = preflight(source, destination, expected)
    import fcntl
    fd = os.open(str(source), os.O_RDONLY | os.O_EXCL | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        require(stat.S_ISBLK(st.st_mode) and (os.major(st.st_rdev),os.minor(st.st_rdev)) == dev, 'OPENED_SOURCE_CHANGED')
        actual_size = struct.unpack('Q', fcntl.ioctl(fd, 0x80081272, b'\0'*8))[0]  # BLKGETSIZE64
        actual_sector = struct.unpack('I', fcntl.ioctl(fd, 0x1268, b'\0'*4))[0]  # BLKSSZGET
        require(actual_size == identity['Size'] and actual_sector == identity['LogicalSectorSize'], 'OPENED_SOURCE_GEOMETRY_CHANGED')
        require_readonly_fd(fd, fcntl)
        def recheck():
            require_readonly_fd(fd, fcntl)
            _, _, current, currentdev = preflight(source, destination, expected, require_capacity=False)
            require(current == identity and currentdev == dev, 'SOURCE_CHANGED')
        recheck()
        with os.fdopen(fd, 'rb', buffering=0, closefd=False) as stream:
            return copy_stream(stream, destination, name, identity, 'offline-block', recheck)
    finally:
        os.close(fd)

def fixture_copy(source, destination, name, sector):
    source = regular_path(source)
    require(source.is_file() and stat.S_ISREG(source.stat().st_mode), 'FIXTURE_REGULAR_FILE_REQUIRED')
    require(sector in (512,4096), 'SECTOR_SIZE_UNSUPPORTED')
    identity = dict(UniqueId='fixture-only', SerialNumber='fixture-only', Model='synthetic-file',
                    Size=source.stat().st_size, LogicalSectorSize=sector)
    with source.open('rb') as stream:
        before = os.fstat(stream.fileno())
        def recheck():
            after = os.fstat(stream.fileno())
            require((before.st_size,before.st_mtime_ns) == (after.st_size,after.st_mtime_ns), 'FIXTURE_SOURCE_CHANGED')
        return copy_stream(stream, destination, name, identity, 'fixture-file', recheck)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('acquire','fixture-copy'):
        p = sub.add_parser(action)
        p.add_argument('--source',required=True);p.add_argument('--destination',required=True)
        p.add_argument('--name',required=True)
        if action=='acquire':
            p.add_argument('--expect-serial',required=True);p.add_argument('--expect-model',required=True)
            p.add_argument('--expect-size',required=True,type=int)
            p.add_argument('--expect-sector-size',required=True,type=int,choices=[512,4096])
        else:
            p.add_argument('--sector-size',type=int,choices=[512,4096],default=512)
    a=parser.parse_args()
    try:
        if a.action=='acquire':
            result=acquire(a.source,a.destination,a.name,dict(SerialNumber=a.expect_serial,Model=a.expect_model,
                           Size=a.expect_size,LogicalSectorSize=a.expect_sector_size))
        else:
            result=fixture_copy(a.source,a.destination,a.name,a.sector_size)
        print(json.dumps(result,indent=2))
        return 0
    except Exception as exc:
        print(json.dumps(dict(State='failed',ErrorType=type(exc).__name__,Error=str(exc),
                              Errno=getattr(exc,'errno',None))),file=sys.stderr)
        return 1

if __name__=='__main__':
    sys.exit(main())
