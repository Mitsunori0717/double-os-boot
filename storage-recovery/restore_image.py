#!/usr/bin/env python3
"""Explicit destructive offline restore. Default plan is read-only; never autodetect a target."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
import offline_image as oi
from convert_image import locked_source

require = oi.require
MAX_MANIFEST = 65536

def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'DUPLICATE_MANIFEST_KEY')
        result[key] = value
    return result

@contextlib.contextmanager
def verified_image(image, manifest):
    with contextlib.ExitStack() as locks:
        image, manifest = oi.regular_path(image), oi.regular_path(manifest)
        mf = locks.enter_context(locked_source(manifest))
        require(stat.S_ISREG(os.fstat(mf.fileno()).st_mode), 'MANIFEST_NOT_REGULAR')
        raw = mf.read(MAX_MANIFEST + 1)
        require(len(raw) <= MAX_MANIFEST, 'MANIFEST_TOO_LARGE')
        m = json.loads(raw.decode('utf-8'), object_pairs_hook=no_duplicates)
        require(isinstance(m, dict) and type(m.get('SchemaVersion')) is int and m.get('SchemaVersion') == 1 and m.get('State') == 'verified', 'VERIFIED_MANIFEST_REQUIRED')
        meta = m.get('Metadata', {})
        require(isinstance(meta, dict) and meta.get('AcquisitionMode') == 'offline-block' and meta.get('FullSectorImage') is True and meta.get('SourceWriteProtected') is True and meta.get('GuestConsistency') == 'offline-environment', 'PRODUCTION_OFFLINE_IMAGE_REQUIRED')
        source = meta.get('Source', {})
        require(isinstance(source, dict), 'SOURCE_IDENTITY_REQUIRED')
        size = m.get('Size'); sector = source.get('LogicalSectorSize')
        require(type(size) is int and size > 0 and type(sector) is int and sector in (512, 4096) and size % sector == 0 and type(source.get('Size')) is int and source.get('Size') == size, 'IMAGE_GEOMETRY_INVALID')
        for key in ('SerialNumber', 'Model', 'UniqueId'):
            require(isinstance(source.get(key), str) and source[key].strip() and 'fixture' not in source[key].lower(), 'SOURCE_IDENTITY_REQUIRED')
        require(isinstance(m.get('Sha256'), str) and re.fullmatch('[0-9a-f]{64}', m['Sha256']), 'IMAGE_HASH_INVALID')
        stream = locks.enter_context(locked_source(image))
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_size == size, 'IMAGE_NOT_REGULAR_OR_SIZE_MISMATCH')
        require(oi.digest_file(stream, size) == m['Sha256'], 'IMAGE_HASH_MISMATCH')
        stream.seek(0)
        manifest_before = os.fstat(mf.fileno())
        def verify_manifest():
            check_lease(mf)
            now = os.fstat(mf.fileno())
            require((now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns) == (manifest_before.st_dev, manifest_before.st_ino, manifest_before.st_size, manifest_before.st_mtime_ns), 'MANIFEST_CHANGED')
            mf.seek(0)
            require(mf.read(MAX_MANIFEST + 1) == raw, 'MANIFEST_CHANGED')
        stream._restore_verify_manifest = verify_manifest
        check_lease(stream); verify_manifest()
        yield stream, m, before, image, manifest

def check_lease(stream):
    if sys.platform == 'linux':
        import fcntl
        require(fcntl.fcntl(stream.fileno(), fcntl.F_GETLEASE) == fcntl.F_RDLCK, 'SOURCE_READ_LEASE_NOT_HELD')

def check_image(stream, before, m, rehash=False):
    check_lease(stream)
    if hasattr(stream, '_restore_verify_manifest'): stream._restore_verify_manifest()
    now = os.fstat(stream.fileno())
    require((now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns, now.st_ctime_ns) == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns), 'IMAGE_CHANGED')
    if rehash:
        stream.seek(0)
        require(oi.digest_file(stream, m['Size']) == m['Sha256'], 'IMAGE_CHANGED')
        stream.seek(0)

def require_external_file(path, rows, mounts, targetdev):
    path = oi.regular_path(path)
    info = path.stat()
    dev = os.major(info.st_dev), os.minor(info.st_dev)
    matching = [m for m in mounts if m['device'] == dev and (str(path) == m['path'] or str(path).startswith(m['path'].rstrip('/') + '/'))]
    require(matching, 'FILE_STORAGE_MOUNT_UNKNOWN')
    mount = max(matching, key=lambda m: len(m['path']))
    require(mount['fs'] in ('ext4', 'xfs', 'ntfs3'), 'FILE_STORAGE_UNSUPPORTED')
    require(oi.physical_parent(rows, dev) != targetdev, 'TARGET_CONTAINS_IMAGE_MANIFEST_OR_LOG')
    return path

def validate_target_identity(identity, dev, expected, m, larger_target_layout=False):
    for key in ('SerialNumber', 'Model', 'UniqueId', 'Size', 'LogicalSectorSize'):
        require(identity.get(key) == expected.get(key), 'TARGET_IDENTITY_MISMATCH:' + key)
    require(list(dev) == expected.get('DeviceNumber'), 'TARGET_DEVICE_NUMBER_CHANGED')
    if larger_target_layout is True:
        require(identity['Size'] > m['Size'] and identity['Size'] % identity['LogicalSectorSize'] == 0, 'LARGER_TARGET_REQUIRED')
    else:
        require(identity['Size'] == m['Size'], 'EXACT_TARGET_CAPACITY_REQUIRED')
    require(identity['LogicalSectorSize'] == m['Metadata']['Source']['LogicalSectorSize'], 'SECTOR_SIZE_MISMATCH')
    source = m['Metadata']['Source']
    require(identity['SerialNumber'] != source['SerialNumber'] and identity['UniqueId'] != source['UniqueId'], 'ORIGINAL_SOURCE_DISK_PROTECTED')

def target_preflight(target, image, manifest, logdir, expected, m, larger_target_layout=False):
    mounts = oi.live_environment()
    target = Path(target).resolve(strict=True)
    info = target.stat()
    require(stat.S_ISBLK(info.st_mode), 'TARGET_NOT_BLOCK_DEVICE')
    dev = os.major(info.st_rdev), os.minor(info.st_rdev)
    rows = oi.lsblk_rows(); row = oi.find_source(rows, dev)
    identity = oi.disk_identity(row)
    oi.require_unique_identity(rows, identity)
    validate_target_identity(identity, dev, expected, m, larger_target_layout)
    related = oi.descendants(rows, row); devices = oi.require_unmounted(related, mounts)
    for r in related:
        node = Path('/sys/dev/block/%d:%d' % oi.row_device(r))
        require((node / 'holders').is_dir() and not list((node / 'holders').iterdir()), 'TARGET_HAS_HOLDERS_OR_UNKNOWN')
    for line in Path('/proc/swaps').read_text().splitlines()[1:]:
        swap = Path(oi.decode_mount(line.split()[0])).stat()
        swapdev = (os.major(swap.st_rdev), os.minor(swap.st_rdev)) if stat.S_ISBLK(swap.st_mode) else (os.major(swap.st_dev), os.minor(swap.st_dev))
        require(swapdev not in devices, 'TARGET_IN_SWAP_USE')
    for path in (image, manifest, logdir):
        require_external_file(path, rows, mounts, dev)
    require(Path(logdir).is_dir(), 'LOG_DIRECTORY_REQUIRED')
    return target, identity, dev

def confirmation_token(identity, dev, m, target_hash=None, layout_mode="exact-copy"):
    content = dict(Target=identity, DeviceNumber=list(dev), ImageSha256=m['Sha256'], Size=m['Size'], TargetSha256=target_hash or m['Sha256'], LayoutMode=layout_mode)
    return hashlib.sha256(json.dumps(content, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def check_target_fd(fd, identity, dev):
    import fcntl
    st = os.fstat(fd)
    require(stat.S_ISBLK(st.st_mode) and (os.major(st.st_rdev), os.minor(st.st_rdev)) == dev, 'OPEN_TARGET_CHANGED')
    size = struct.unpack('Q', fcntl.ioctl(fd, 0x80081272, b'\0'*8))[0]
    sector = struct.unpack('I', fcntl.ioctl(fd, 0x1268, b'\0'*4))[0]
    ro = struct.unpack('i', fcntl.ioctl(fd, 0x125e, b'\0'*4))[0]
    require(size == identity['Size'] and sector == identity['LogicalSectorSize'], 'OPEN_TARGET_GEOMETRY_CHANGED')
    require(ro == 0, 'TARGET_WRITE_PROTECTED')

class LayoutImage:
    """Read-only bounded source + zero tail + explicit nonoverlapping byte patches."""
    def __init__(self, source, source_size, target_size, patches):
        require(type(source_size) is int and type(target_size) is int and 0 < source_size < target_size, 'LARGER_TARGET_REQUIRED')
        checked = []
        for offset, data in patches:
            require(type(offset) is int and offset >= 0 and isinstance(data, bytes) and len(data) > 0 and offset + len(data) <= target_size, 'LAYOUT_PATCH_INVALID')
            checked.append((offset, data))
        checked.sort(key=lambda p: p[0])
        for first, second in zip(checked, checked[1:]):
            require(first[0] + len(first[1]) <= second[0], 'LAYOUT_PATCH_OVERLAP')
        self.source, self.source_size, self.size = source, source_size, target_size
        self.patches, self.position = tuple(checked), 0

    def seek(self, offset, whence=0):
        require(type(offset) is int and whence == 0 and 0 <= offset <= self.size, 'LAYOUT_SEEK_INVALID')
        self.position = offset
        return offset

    def read(self, count=-1):
        require(type(count) is int and count >= 0, 'BOUNDED_LAYOUT_READ_REQUIRED')
        length = min(count, self.size - self.position)
        if length == 0: return b''
        start, end = self.position, self.position + length
        data = bytearray(length)
        if start < self.source_size:
            n = min(end, self.source_size) - start
            self.source.seek(start)
            raw = self.source.read(n)
            require(len(raw) == n, 'LAYOUT_SOURCE_SHORT_READ')
            data[:n] = raw
        for offset, patch in self.patches:
            left, right = max(start, offset), min(end, offset + len(patch))
            if left < right:
                data[left-start:right-start] = patch[left-offset:right-offset]
        self.position = end
        return bytes(data)

def prepare_restore_view(source, m, target_size, larger_target_layout=False):
    if larger_target_layout is not True:
        require(target_size == m['Size'], 'EXACT_TARGET_CAPACITY_REQUIRED')
        return source, m['Sha256'], dict(Mode='exact-copy', PartitionsResized=False)
    from larger_disk_layout import plan, LayoutError
    def read_at(offset, length):
        source.seek(offset)
        return source.read(length)
    try:
        layout = plan(m['Size'], target_size, m['Metadata']['Source']['LogicalSectorSize'], read_at)
    except LayoutError as exc:
        raise oi.SafetyError('LAYOUT_REJECTED:' + str(exc)) from exc
    patches = [(p['Offset'], p['Data']) for p in layout['Patches']]
    view = LayoutImage(source, m['Size'], target_size, patches)
    digest = oi.digest_file(view, target_size)
    view.seek(0)
    summary = {key: value for key, value in layout.items() if key != 'Patches'}
    summary['Mode'] = 'larger-target-' + layout['Layout'].lower()
    summary['Patches'] = [dict(Offset=p['Offset'], Length=len(p['Data']), Purpose=p['Purpose'], Sha256=hashlib.sha256(p['Data']).hexdigest()) for p in layout['Patches']]
    return view, digest, summary

def restore_stream(source, target, size, sha256, event, recheck, sync):
    """Mechanism tested on memory/ordinary files. Caller owns ALL physical safety gates."""
    written = 0
    phase = 'prewrite'
    try:
        recheck(); source.seek(0); target.seek(0)
        event('partial', BytesCompleted=0, Phase=phase)
        phase = 'writing'; digest = hashlib.sha256(); next_progress = 256 * 1024 * 1024
        while written < size:
            data = source.read(min(oi.CHUNK, size-written))
            require(data and len(data) <= size-written, 'IMAGE_SHORT_READ')
            digest.update(data); view = memoryview(data)
            while view:
                n = target.write(view)
                require(type(n) is int and 0 < n <= len(view), 'TARGET_SHORT_WRITE')
                written += n; view = view[n:]
            if written >= next_progress:
                event('partial', BytesCompleted=written, Phase=phase)
                next_progress = written + 256 * 1024 * 1024
        require(source.read(1) == b'' and digest.hexdigest() == sha256, 'IMAGE_CHANGED_DURING_WRITE')
        phase = 'flush'; target.flush(); sync(target)
        event('written', BytesCompleted=written, Phase=phase)
        phase = 'readback'; target.seek(0)
        require(oi.digest_file(target, size) == sha256, 'TARGET_READBACK_MISMATCH')
        phase = 'final-recheck'; recheck()
        event('verified', BytesCompleted=written, Phase=phase, BootTested=False)
        return dict(State='verified', BytesCompleted=written, Sha256=sha256, BootTested=False)
    except BaseException as exc:
        try: event('failed', BytesCompleted=written, Phase=phase, ErrorCode=str(exc) if isinstance(exc, oi.SafetyError) else 'IO_OR_RUNTIME_FAILURE', ErrorType=type(exc).__name__, Errno=getattr(exc, 'errno', None), TargetMayBePartiallyOverwritten=phase != 'prewrite')
        except Exception: pass
        raise

def sync_target(target):
    import fcntl
    os.fsync(target.fileno())
    # BLKFLSBUF flushes and invalidates this exclusive target's kernel block cache.
    # Failure is fatal: a cache-only comparison must not be called verified readback.
    fcntl.ioctl(target.fileno(), 0x1261)

def confirm_terminal(identity, dev, image_hash):
    require(sys.stdin.isatty() and sys.stdout.isatty(), 'INTERACTIVE_TARGET_CONFIRMATION_REQUIRED')
    text = 'ERASE ' + identity['SerialNumber'] + ' ' + str(identity['Size']) + ' ' + image_hash[:16]
    print('PERMANENT DATA LOSS: every sector of the following SSD will be overwritten.')
    print(json.dumps(dict(Target=identity, DeviceNumber=list(dev)), indent=2))
    print('This cannot be undone by this tool. Type exactly: ' + text)
    require(input('Confirmation: ') == text, 'DESTRUCTIVE_CONFIRMATION_CANCELLED')

def physical_restore(image, manifest, target, logdir, name, expected, token=None, exclusive=False, execute=False, basic_single_disk_image_confirmed=False, larger_target_layout=False):
    require(re.fullmatch('[A-Za-z0-9][A-Za-z0-9_-]{0,80}', name), 'LOG_NAME_INVALID')
    oi.live_environment()  # Refuse non-Live/non-Linux execution before hashing a potentially huge image.
    with verified_image(image, manifest) as (source, m, before, image, manifest):
        target, identity, dev = target_preflight(target, image, manifest, logdir, expected, m, larger_target_layout)
        view, target_hash, layout = prepare_restore_view(source, m, identity['Size'], larger_target_layout)
        check_image(source, before, m)
        expected_token = confirmation_token(identity, dev, m, target_hash, layout['Mode'])
        if not execute:
            return dict(State='plan-only', Target=identity, DeviceNumber=list(dev), ImageSha256=m['Sha256'], ConfirmationToken=expected_token, Destructive=True, RequiredTargetBytes=identity['Size'], TargetSha256=target_hash, Layout=layout, BasicSingleDiskConfirmationRequired=True, MultiDiskSetDependencies='NotAssessed', Warning='Entire target overwritten; review Layout before approving. No partition resizing. Boot and licensing not verified.')
        require(basic_single_disk_image_confirmed is True, 'BASIC_SINGLE_DISK_IMAGE_CONFIRMATION_REQUIRED')
        require(exclusive is True and token == expected_token, 'EXPLICIT_DESTRUCTIVE_CONFIRMATION_REQUIRED')
        import fcntl
        with oi.output_directory(logdir) as (_, dirfd, create):
            with create(name+'.restore.events.jsonl', False) as log:
                def event(state, **fields):
                    log.write(json.dumps(dict(Utc=oi.utc(), State=state, Target=identity, DeviceNumber=list(dev), ExpectedBytes=identity['Size'], ImageSha256=m['Sha256'], TargetSha256=target_hash, Layout=layout, **fields))+'\n')
                    log.flush(); os.fsync(log.fileno())
                event('preflight', BytesCompleted=0)
                # O_EXCL protects against ordinary mounted/claimed devices; flock coordinates this tool.
                # Neither prevents a privileged hostile raw writer: dedicated Live ownership is mandatory.
                fd = None
                try:
                    print(json.dumps(dict(SourceImageSha256=m['Sha256'], TargetSha256=target_hash, Layout=layout), indent=2))
                    confirm_terminal(identity, dev, target_hash)
                    fd = os.open(str(target), os.O_RDWR | os.O_EXCL | os.O_NOFOLLOW)
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    def recheck():
                        check_target_fd(fd, identity, dev)
                        current_path, current, currentdev = target_preflight(target, image, manifest, logdir, expected, m, larger_target_layout)
                        require(current_path == target and current == identity and currentdev == dev, 'TARGET_CHANGED')
                        check_image(source, before, m)
                    check_image(source, before, m, rehash=True)
                    with os.fdopen(fd, 'r+b', buffering=0, closefd=False) as output:
                        result = restore_stream(view, output, identity['Size'], target_hash, event, recheck, sync_target)
                        result.update(SourceImageSha256=m['Sha256'], Layout=layout, TargetBytes=identity['Size'])
                        return result
                except BaseException as exc:
                    try: event('failed', ErrorCode=str(exc) if isinstance(exc, oi.SafetyError) else 'IO_OR_RUNTIME_FAILURE', ErrorType=type(exc).__name__, Errno=getattr(exc, 'errno', None), TargetState='InspectPriorProgressEvents; do not assume unchanged')
                    except Exception: pass
                    raise
                finally:
                    if fd is not None: os.close(fd)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('plan', 'restore'))
    for name in ('image','manifest','target','log-directory','name','expect-serial','expect-model','expect-unique-id','expect-device'):
        p.add_argument('--'+name, required=True)
    p.add_argument('--expect-size', required=True, type=int)
    p.add_argument('--expect-sector-size', required=True, type=int, choices=(512,4096))
    p.add_argument('--confirm-erase-token')
    p.add_argument('--larger-target-layout', action='store_true', help='Explicit larger basic GPT relocation or basic primary MBR zero-tail; no partition resizing')
    p.add_argument('--offline-exclusive-ownership', action='store_true')
    p.add_argument('--basic-single-disk-image-confirmed', action='store_true', help='Operator confirms basic non-RAID/non-Spaces/non-dynamic source and separately assessed all disk-set dependencies; not automatic detection')
    a = p.parse_args()
    try:
        require(re.fullmatch(r'\d+:\d+', a.expect_device), 'DEVICE_NUMBER_REQUIRED')
        expected = dict(SerialNumber=a.expect_serial, Model=a.expect_model, UniqueId=a.expect_unique_id, Size=a.expect_size, LogicalSectorSize=a.expect_sector_size, DeviceNumber=list(map(int,a.expect_device.split(':'))))
        result = physical_restore(a.image,a.manifest,a.target,a.log_directory,a.name,expected,a.confirm_erase_token,a.offline_exclusive_ownership,a.action=='restore',a.basic_single_disk_image_confirmed,a.larger_target_layout)
        print(json.dumps(result, indent=2)); return 0
    except Exception as exc:
        print(json.dumps(dict(State='failed', ErrorCode=str(exc) if isinstance(exc, oi.SafetyError) else 'IO_OR_RUNTIME_FAILURE', ErrorType=type(exc).__name__, Errno=getattr(exc,'errno',None))), file=sys.stderr); return 1

if __name__ == '__main__':
    sys.exit(main())
