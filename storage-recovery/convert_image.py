"""Verified, file-only raw -> VHDX conversion. Never opens a physical disk."""
from __future__ import annotations
import argparse
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import struct
import uuid
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

class ConversionError(RuntimeError):
    pass

def utc():
    return datetime.now(timezone.utc).isoformat()

def safe_path(value, *, exists=True):
    text = os.fspath(value)
    if not text or text.startswith(('\\\\', '//', '\\??\\')) or any(ord(c) < 32 for c in text):
        raise ConversionError('UNSAFE_PATH')
    if os.name == 'nt':
        for part in re.split(r'[\\/]', text):
            if part.endswith(('.', ' ')) or re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', part, re.I):
                raise ConversionError('UNSAFE_WINDOWS_NAME')
        if ':' in text[2:]:
            raise ConversionError('ALTERNATE_STREAM_REJECTED')
    path = Path(os.path.abspath(text))
    for item in [path, *path.parents]:
        if item.exists() or item.is_symlink():
            st = item.lstat()
            if stat.S_ISLNK(st.st_mode) or getattr(st, 'st_file_attributes', 0) & 0x400:
                raise ConversionError('SYMLINK_OR_REPARSE_REJECTED')
    if exists:
        st = path.stat()
        if not stat.S_ISREG(st.st_mode):
            raise ConversionError('REGULAR_FILE_REQUIRED')
    elif not path.parent.is_dir():
        raise ConversionError('PARENT_DIRECTORY_REQUIRED')
    if os.name == 'nt':
        drive_type = ctypes.windll.kernel32.GetDriveTypeW(str(path.anchor))
        if drive_type not in (2, 3):
            raise ConversionError('LOCAL_DISK_REQUIRED')
    return path

def hash_stream(stream):
    stream.seek(0)
    h = hashlib.sha256()
    while True:
        block = stream.read(4 * 1024 * 1024)
        if not block:
            break
        h.update(block)
    return h.hexdigest()

def hash_file(path):
    with open(path, 'rb') as f:
        return hash_stream(f)

@contextlib.contextmanager
def locked_source(path):
    """Mandatory Windows sharing restriction or Linux kernel read lease, not flock."""
    if os.name == 'nt':
        import msvcrt
        from ctypes import wintypes
        k = ctypes.WinDLL('kernel32', use_last_error=True)
        k.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        k.CreateFileW.restype = wintypes.HANDLE
        handle = k.CreateFileW(str(path), 0x80000000, 1, None, 3, 0x08000000, None)
        if handle == wintypes.HANDLE(-1).value:
            raise ConversionError('SOURCE_READ_LOCK_FAILED: ' + str(ctypes.get_last_error()))
        try:
            fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
        except BaseException:
            k.CloseHandle(handle)
            raise
        with os.fdopen(fd, 'rb') as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ConversionError('REGULAR_FILE_REQUIRED')
            yield f
    elif sys.platform.startswith('linux'):
        import fcntl
        if not hasattr(fcntl, 'F_SETLEASE'):
            raise ConversionError('SOURCE_READ_LEASE_UNAVAILABLE')
        def broken(_signum, _frame):
            raise ConversionError('SOURCE_READ_LEASE_BROKEN')
        old = signal.signal(signal.SIGIO, broken)
        f = open(path, 'rb')
        leased = False
        try:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise ConversionError('REGULAR_FILE_REQUIRED')
            try:
                fcntl.fcntl(f.fileno(), fcntl.F_SETLEASE, fcntl.F_RDLCK)
            except OSError as e:
                raise ConversionError('SOURCE_READ_LEASE_FAILED: ' + str(e)) from e
            leased = True
            yield f
        finally:
            if leased:
                fcntl.fcntl(f.fileno(), fcntl.F_SETLEASE, fcntl.F_UNLCK)
            f.close()
            signal.signal(signal.SIGIO, old)
    else:
        raise ConversionError('SOURCE_LOCK_UNSUPPORTED_OS')

def validate_manifest(m):
    if not isinstance(m, dict) or m.get('SchemaVersion') != 1 or m.get('State') != 'verified' or m.get('Metadata', {}).get('FullSectorImage') is not True:
        raise ConversionError('UNVERIFIED_FULL_SECTOR_SOURCE')
    size = m.get('Size')
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0 or size % 512:
        raise ConversionError('INVALID_RAW_SIZE')
    if not re.fullmatch('[0-9a-fA-F]{64}', str(m.get('Sha256', ''))):
        raise ConversionError('INVALID_RAW_HASH')
    source = m.get('Metadata', {}).get('Source', {})
    if source.get('Size') != size or source.get('LogicalSectorSize') != 512:
        raise ConversionError('SOURCE_SIZE_OR_SECTOR_UNSUPPORTED')
    if not source.get('UniqueId') or not source.get('SerialNumber'):
        raise ConversionError('SOURCE_IDENTITY_MISSING')
    if m.get('Metadata', {}).get('AcquisitionMode') not in ('offline-block', 'fixture-file'):
        raise ConversionError('UNKNOWN_ACQUISITION_MODE')
    if m['Metadata']['AcquisitionMode'] == 'offline-block' and m['Metadata'].get('SourceWriteProtected') is not True:
        raise ConversionError('SOURCE_WRITE_PROTECTION_UNVERIFIED')
    return size

def run_qemu(executable, args, timeout, record):
    start = time.monotonic()
    try:
        p = subprocess.run([str(executable), *args], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout, shell=False)
    except subprocess.TimeoutExpired as e:
        record('failed', {'Stage': args[0], 'Error': 'QEMU_TIMEOUT', 'TimeoutSeconds': timeout})
        raise ConversionError('QEMU_TIMEOUT: ' + args[0]) from e
    record('command', {'Stage': args[0], 'ExitCode': p.returncode, 'ElapsedSeconds': round(time.monotonic()-start, 3),
                       'Stdout': p.stdout[-16384:], 'Stderr': p.stderr[-16384:]})
    if p.returncode:
        raise ConversionError('QEMU_FAILED: ' + args[0] + ' exit=' + str(p.returncode))
    return p.stdout

def read_vhdx_sector_size(path):
    """Read the generated VHDX logical-sector metadata after qemu-img check.

    Not a general VHDX repair/parser: require both region tables to agree and
    fail closed on missing, duplicate or out-of-bounds metadata.
    """
    metadata_id=uuid.UUID('8b7ca206-4790-4b9a-b8fe-575f050f886e')
    sector_id=uuid.UUID('8141bf1d-a96f-4709-ba47-f233a8faab5f')
    with open(path,'rb') as f:
        size=os.fstat(f.fileno()).st_size
        if f.read(8)!=b'vhdxfile': raise ConversionError('VHDX_HEADER_INVALID')
        regions=[]
        for pos in (192*1024,256*1024):
            f.seek(pos);table=f.read(65536)
            if len(table)!=65536 or table[:4]!=b'regi':raise ConversionError('VHDX_REGION_INVALID')
            count=struct.unpack_from('<I',table,8)[0]
            if count>2047:raise ConversionError('VHDX_REGION_COUNT_INVALID')
            found=[]
            for i in range(count):
                entry=table[16+i*32:48+i*32]
                if uuid.UUID(bytes_le=entry[:16])==metadata_id:
                    offset,length=struct.unpack_from('<QI',entry,16)
                    if length<65536 or offset+length>size:raise ConversionError('VHDX_METADATA_BOUNDS')
                    found.append((offset,length))
            if len(found)!=1:raise ConversionError('VHDX_METADATA_REGION_MISSING')
            regions.append(found[0])
        if regions[0]!=regions[1]:raise ConversionError('VHDX_REGION_TABLES_DISAGREE')
        offset,length=regions[0];f.seek(offset);table=f.read(65536)
        if table[:8]!=b'metadata':raise ConversionError('VHDX_METADATA_SIGNATURE')
        count=struct.unpack_from('<H',table,10)[0]
        if count>2047:raise ConversionError('VHDX_METADATA_COUNT_INVALID')
        found=[]
        for i in range(count):
            entry=table[32+i*32:64+i*32]
            if uuid.UUID(bytes_le=entry[:16])==sector_id:
                itemoff,itemlen=struct.unpack_from('<II',entry,16)
                if itemlen!=4 or itemoff<65536 or itemoff+itemlen>length:raise ConversionError('VHDX_SECTOR_BOUNDS')
                f.seek(offset+itemoff);found.append(struct.unpack('<I',f.read(4))[0])
        if len(found)!=1 or found[0] not in (512,4096):raise ConversionError('VHDX_SECTOR_INVALID')
        return found[0]

def sync_file(path):
    with open(path, 'r+b') as f:
        f.flush()
        os.fsync(f.fileno())

def write_json_new(path, value):
    with open(path, 'x', encoding='utf-8') as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())

def publish_no_replace(source, destination):
    # Hard-link creation is atomic and fails if destination already exists.
    os.link(source, destination)
    os.unlink(source)


def convert(raw, output, qemu, *, timeout=86400, allow_fixture=False, runner=run_qemu):
    raw = safe_path(raw)
    manifest_path = safe_path(str(raw)+'.manifest.json')
    output = safe_path(output, exists=False)
    executable = safe_path(qemu)
    if output.suffix.lower() != '.vhdx' or executable.name.lower() not in ('qemu-img', 'qemu-img.exe'):
        raise ConversionError('VHDX_AND_EXPLICIT_QEMU_PATH_REQUIRED')
    if timeout <= 0 or timeout > 7 * 86400:
        raise ConversionError('INVALID_TIMEOUT')
    if raw == output or raw == executable:
        raise ConversionError('SOURCE_DESTINATION_COLLISION')
    names = [output, Path(str(output)+'.manifest.json'), Path(str(output)+'.events.jsonl'), Path(str(output)+'.conversion.lock')]
    if any(p.exists() or p.is_symlink() for p in names):
        raise ConversionError('OUTPUT_ALREADY_EXISTS')
    with open(manifest_path, 'r', encoding='utf-8-sig') as f:
        m = json.load(f)
    size = validate_manifest(m)
    if m['Metadata']['AcquisitionMode'] == 'fixture-file' and not allow_fixture:
        raise ConversionError('FIXTURE_REQUIRES_EXPLICIT_ALLOW')
    # Worst-case dynamic allocation plus overhead; no reliance on sparse compression.
    required = size + max(1024**3, size // 100)
    if shutil.disk_usage(output.parent).free < required:
        raise ConversionError('DESTINATION_CAPACITY_INSUFFICIENT')
    lock_fd = os.open(names[3], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(lock_fd)
    work = None
    def record(state, details):
        with open(names[2], 'a', encoding='utf-8') as log:
            log.write(json.dumps({'Utc': utc(), 'State': state, **details}, ensure_ascii=False)+'\n')
            log.flush()
            os.fsync(log.fileno())
    try:
        record('partial', {'Stage':'validate-source','Source':str(raw),'Output':str(output),'ExpectedBytes':size})
        with locked_source(raw) as source:
            before = os.fstat(source.fileno())
            qemu_source = ('/proc/' + str(os.getpid()) + '/fd/' + str(source.fileno())) if sys.platform.startswith('linux') else str(raw)
            if before.st_size != size or hash_stream(source).lower() != m['Sha256'].lower():
                raise ConversionError('SOURCE_SIZE_OR_HASH_MISMATCH')
            # Fresh private output directory prevents accidental qemu overwrite.
            work = Path(tempfile.mkdtemp(prefix='.edgebox-convert-', dir=output.parent))
            partial = work / 'image.partial.vhdx'
            version = runner(executable, ['--version'], min(timeout, 60), record).strip()
            runner(executable, ['convert','-f','raw','-O','vhdx','-o','subformat=dynamic,block_state_zero=on',qemu_source,str(partial)], timeout, record)
            safe_path(partial)
            sync_file(partial)
            record('copied', {'Stage':'convert','ContainerBytes':partial.stat().st_size,'VerificationPending':True})
            info = json.loads(runner(executable, ['info','-f','vhdx','--output=json',str(partial)], timeout, record))
            if info.get('format') != 'vhdx' or info.get('virtual-size') != size or info.get('backing-filename'):
                raise ConversionError('VHDX_INFO_MISMATCH')
            runner(executable, ['check','-f','vhdx',str(partial)], timeout, record)
            if read_vhdx_sector_size(partial) != 512:
                raise ConversionError('VHDX_LOGICAL_SECTOR_MISMATCH')
            runner(executable, ['compare','-f','raw','-F','vhdx',qemu_source,str(partial)], timeout, record)
            after = os.fstat(source.fileno())
            path_after = raw.stat()
            if (path_after.st_dev,path_after.st_ino) != (after.st_dev,after.st_ino):
                raise ConversionError('SOURCE_PATH_REPLACED')
            if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) or hash_stream(source).lower() != m['Sha256'].lower():
                raise ConversionError('SOURCE_CHANGED')
            container_hash = hash_file(partial)
            result = {'SchemaVersion':1,'State':'verified','Format':'vhdx','Size':partial.stat().st_size,
                      'VirtualSize':size,'Sha256':container_hash,'LogicalSectorSize':512,
                      'SourceSha256':m['Sha256'].lower(),'Metadata':m['Metadata'],'FullSectorImage':True,
                      'SourceAcquisitionMode':m['Metadata']['AcquisitionMode'],'RestoreTested':False,'BootTested':False,
                      'CreatedUtc':utc(),'QemuVersion':version,'QemuExecutableSha256':hash_file(executable),
                      'Verification':{'VirtualSize':True,'QemuCheck':True,'LogicalCompare':True,'ReadbackSha256':True,'LogicalSectorSize':True},
                      'IntegrityOnly':True}
            pending_manifest = work / 'manifest.partial.json'
            write_json_new(pending_manifest,result)
            # Input remains locked until both files are published.
            publish_no_replace(partial,output)
            publish_no_replace(pending_manifest,names[1])
            record('verified', {'Stage':'complete','Sha256':container_hash,'RestoreTested':False,'BootTested':False})
            return result
    except BaseException as e:
        try:
            record('failed', {'Stage':'conversion','Exception':type(e).__name__,'Error':str(e),'PartialDirectory':str(work) if work else None,'ExpectedBytes':size})
        except Exception:
            pass
        raise
    finally:
        # Never clean partial data automatically. Lock is a durable run marker;
        # use a fresh output name for retries and inspect logs/partials.
        pass


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--raw', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--qemu-img', required=True, help='Explicit path to trusted qemu-img; never auto-installs')
    p.add_argument('--timeout', type=int, default=86400)
    p.add_argument('--allow-fixture', action='store_true')
    a = p.parse_args(argv)
    try:
        result=convert(a.raw,a.output,a.qemu_img,timeout=a.timeout,allow_fixture=a.allow_fixture)
        print(json.dumps(result,indent=2))
        return 0
    except Exception as e:
        print(json.dumps({'State':'failed','Exception':type(e).__name__,'Error':str(e)}),file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
