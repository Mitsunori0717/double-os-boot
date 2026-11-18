"""File-only integrity ledger for offline, independently attached disk sets."""
import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys

from convert_image import safe_path, locked_source, hash_stream, check_locked_file, ConversionError


class SetError(RuntimeError):
    pass


def require(value, code):
    if not value:
        raise SetError(code)


def keys(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected), 'SCHEMA_KEYS_INVALID')


def timestamp(value):
    require(isinstance(value, str) and len(value) <= 40, 'TIMESTAMP_INVALID')
    try:
        result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise SetError('TIMESTAMP_INVALID') from None
    require(result.tzinfo is not None, 'TIMESTAMP_ZONE_REQUIRED')
    return result


def identity(value):
    keys(value, ('UniqueId', 'SerialNumber', 'Model', 'Size', 'LogicalSectorSize'))
    for name in ('UniqueId', 'SerialNumber', 'Model'):
        text = value[name]
        require(isinstance(text, str) and text.strip() and len(text) <= 256 and
                not any(ord(c) < 32 for c in text), 'IDENTITY_INVALID')
        # No user-supplied notes, credentials or recovery-key fields are accepted.
        require(not re.search(r'\b\d{6}(?:-\d{6}){7}\b', text), 'SECRET_PATTERN_REJECTED')
    require(type(value['Size']) is int and value['Size'] > 0 and
            type(value['LogicalSectorSize']) is int and value['LogicalSectorSize'] in (512, 4096)
            and value['Size'] % value['LogicalSectorSize'] == 0, 'GEOMETRY_INVALID')
    return dict(value)


def specification(value):
    keys(value, ('SchemaVersion', 'Topology', 'BootDiskUniqueId', 'ExpectedDisks', 'Attestation'))
    require(type(value['SchemaVersion']) is int and value['SchemaVersion'] == 1, 'SCHEMA_VERSION_INVALID')
    require(value['Topology'] == 'simple-independent', 'TOPOLOGY_UNSUPPORTED')
    disks = value['ExpectedDisks']
    require(isinstance(disks, list) and 1 <= len(disks) <= 16, 'DISK_COUNT_INVALID')
    disks = [identity(x) for x in disks]
    require(len({d['UniqueId'] for d in disks}) == len(disks) and
            len({(d['Model'], d['SerialNumber']) for d in disks}) == len(disks), 'DUPLICATE_DISK_IDENTITY')
    require(value['BootDiskUniqueId'] in {d['UniqueId'] for d in disks}, 'BOOT_DISK_MISSING')
    a = value['Attestation']
    keys(a, ('Shutdown', 'AllDependentDisksIncluded', 'NoWritesDuringAcquisition',
             'QuiescentStartUtc', 'QuiescentEndUtc'))
    require(a['Shutdown'] == 'full-shutdown' and a['AllDependentDisksIncluded'] is True and
            a['NoWritesDuringAcquisition'] is True, 'QUIESCENCE_ATTESTATION_REQUIRED')
    start, end = timestamp(a['QuiescentStartUtc']), timestamp(a['QuiescentEndUtc'])
    require(start < end <= dt.datetime.now(dt.timezone.utc), 'QUIESCENT_WINDOW_INVALID')
    return value


def load_json(stream):
    raw = stream.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, 'JSON_TOO_LARGE')
    def unique(pairs):
        result = {}
        for k, v in pairs:
            require(k not in result, 'DUPLICATE_JSON_KEY')
            result[k] = v
        return result
    try:
        return json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise SetError('JSON_INVALID') from None


def check_member(manifest, spec, allow_fixture):
    require(isinstance(manifest, dict) and type(manifest.get('SchemaVersion')) is int and manifest.get('SchemaVersion') == 1 and
            manifest.get('State') == 'verified', 'SOURCE_MANIFEST_UNVERIFIED')
    meta = manifest.get('Metadata', {})
    require(isinstance(meta, dict) and meta.get('FullSectorImage') is True, 'FULL_DISK_REQUIRED')
    mode = meta.get('AcquisitionMode')
    require(mode == 'offline-block' or (allow_fixture and mode == 'fixture-file'), 'FIXTURE_OR_UNKNOWN_SOURCE_REFUSED')
    if mode == 'offline-block':
        require(meta.get('SourceWriteProtected') is True and
                meta.get('GuestConsistency') == 'offline-environment', 'OFFLINE_SOURCE_REQUIRED')
    disk = identity(meta.get('Source'))
    require(type(manifest.get('Size')) is int and manifest.get('Size') == disk['Size'], 'MANIFEST_GEOMETRY_MISMATCH')
    require(isinstance(manifest.get('Sha256'), str) and
            re.fullmatch('[0-9a-fA-F]{64}', manifest['Sha256']), 'MANIFEST_HASH_INVALID')
    require(disk in spec['ExpectedDisks'], 'UNEXPECTED_DISK')
    a = spec['Attestation']
    require(timestamp(a['QuiescentStartUtc']) <= timestamp(manifest.get('CreatedUtc')) <=
            timestamp(a['QuiescentEndUtc']), 'ACQUISITION_OUTSIDE_ATTESTED_WINDOW')
    return disk, mode


@contextlib.contextmanager
def _verified_members(raw_paths, spec, *, allow_fixture=False):
    """Keep images and manifests locked through the caller's ledger publication."""
    require(type(allow_fixture) is bool, 'FIXTURE_PERMISSION_MUST_BE_BOOLEAN')
    specification(spec)
    require(len(raw_paths) == len(spec['ExpectedDisks']), 'DEPENDENT_DISK_SET_INCOMPLETE')
    paths = [safe_path(x) for x in raw_paths]
    require(all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,120}', p.name) and '..' not in p.name
                for p in paths), 'MEMBER_PATH_INVALID')
    require(len(set(paths)) == len(paths), 'DUPLICATE_IMAGE_PATH')
    require(len({p.parent for p in paths}) == 1, 'ONE_PORTABLE_SET_DIRECTORY_REQUIRED')
    members = []
    with contextlib.ExitStack() as stack:
        held = []
        for path in paths:
            manifest_path = safe_path(str(path) + '.manifest.json')
            mf = stack.enter_context(locked_source(manifest_path))
            rf = stack.enter_context(locked_source(path))
            held.extend(((mf, os.fstat(mf.fileno()), manifest_path),
                         (rf, os.fstat(rf.fileno()), path)))
            manifest = load_json(mf)
            disk, mode = check_member(manifest, spec, allow_fixture)
            require(os.fstat(rf.fileno()).st_size == disk['Size'], 'RAW_SIZE_MISMATCH')
            require(hash_stream(rf).lower() == manifest['Sha256'].lower(), 'RAW_HASH_MISMATCH')
            members.append(dict(RawFile=path.name, ManifestFile=manifest_path.name,
                ManifestSha256=hash_stream(mf), Sha256=manifest['Sha256'].lower(), Source=disk,
                AcquisitionMode=mode))
        require(len({m['Source']['UniqueId'] for m in members}) == len(members), 'DUPLICATE_IMAGE_DISK')
        require({m['Source']['UniqueId'] for m in members} ==
                {d['UniqueId'] for d in spec['ExpectedDisks']}, 'DEPENDENT_DISK_SET_INCOMPLETE')
        require([m['Source'] for m in members] == spec['ExpectedDisks'], 'DISK_ORDER_MISMATCH')
        def recheck():
            for stream, before, path in held:
                try:
                    check_locked_file(stream, before, path)
                except ConversionError as exc:
                    raise SetError('SOURCE_CHANGED_OR_LOCK_LOST') from exc
        recheck()
        yield members, recheck
        recheck()


def verify_members(raw_paths, spec, *, allow_fixture=False):
    """Verify a point-in-time snapshot; this never authorizes a later restore."""
    with _verified_members(raw_paths, spec, allow_fixture=allow_fixture) as (members, _):
        return members


def build(raw_paths, spec, output, *, fixture=False):
    output = safe_path(output, exists=False)
    require(not output.exists(), 'OUTPUT_EXISTS')
    with _verified_members(raw_paths, spec, allow_fixture=fixture) as (members, recheck):
        require(output.parent == safe_path(raw_paths[0]).parent, 'SET_MUST_SHARE_IMAGE_DIRECTORY')
        result = dict(SchemaVersion=1, Kind='OfflineDiskSet', State='fixture-verified-set' if fixture else 'integrity-verified-set',
                      CreatedUtc=dt.datetime.now(dt.timezone.utc).isoformat(), Specification=spec, Members=members,
                      Consistency='operator-attested-not-proven', RestoreTested=False, BootTested=False,
                      AutomaticRestoreAuthorized=False, Fixture=bool(fixture))
        # A final ledger is published only while every verified member is still locked.
        partial = safe_path(str(output) + '.partial', exists=False)
        with open(partial, 'x', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=True, indent=2)
            f.write('\n'); f.flush(); os.fsync(f.fileno())
        recheck()
        os.link(partial, output)
        partial.unlink()
        return result


def verify(path, *, allow_fixture=False):
    require(type(allow_fixture) is bool, 'FIXTURE_PERMISSION_MUST_BE_BOOLEAN')
    path = safe_path(path)
    with locked_source(path) as stream:
        before = os.fstat(stream.fileno())
        ledger = load_json(stream)
        result = _verify_ledger(ledger, path, allow_fixture=allow_fixture)
        check_locked_file(stream, before, path)
        return result


def _verify_ledger(ledger, path, *, allow_fixture=False):
    keys(ledger, ('SchemaVersion', 'Kind', 'State', 'CreatedUtc', 'Specification', 'Members',
                  'Consistency', 'RestoreTested', 'BootTested', 'AutomaticRestoreAuthorized', 'Fixture'))
    require(type(ledger['SchemaVersion']) is int and ledger['SchemaVersion'] == 1 and ledger['Kind'] == 'OfflineDiskSet', 'SET_SCHEMA_INVALID')
    timestamp(ledger['CreatedUtc'])
    require(ledger['Fixture'] is False or (allow_fixture and ledger['Fixture'] is True), 'FIXTURE_SET_REFUSED')
    require(ledger['State'] == ('fixture-verified-set' if ledger['Fixture'] else 'integrity-verified-set'), 'SET_STATE_INVALID')
    require(ledger['Consistency'] == 'operator-attested-not-proven' and ledger['RestoreTested'] is False
            and ledger['BootTested'] is False and ledger['AutomaticRestoreAuthorized'] is False, 'UNSUPPORTED_SUCCESS_CLAIM')
    require(isinstance(ledger['Members'], list) and 1 <= len(ledger['Members']) <= 16, 'MEMBERS_INVALID')
    paths = []
    for member in ledger['Members']:
        keys(member, ('RawFile', 'ManifestFile', 'ManifestSha256', 'Sha256', 'Source', 'AcquisitionMode'))
        name = member['RawFile']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,120}', name)
                and '..' not in name and member['ManifestFile'] == name + '.manifest.json', 'MEMBER_PATH_INVALID')
        paths.append(path.parent / name)
    actual = verify_members(paths, ledger['Specification'], allow_fixture=allow_fixture and ledger['Fixture'])
    require(actual == ledger['Members'], 'SET_MEMBER_CHANGED')
    return ledger


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    for action in ('build', 'fixture-build'):
        p = sub.add_parser(action)
        p.add_argument('--specification', required=True); p.add_argument('--output', required=True)
        p.add_argument('--raw', action='append', required=True)
    p = sub.add_parser('verify'); p.add_argument('--set', required=True); p.add_argument('--allow-fixture', action='store_true')
    a = parser.parse_args(argv)
    try:
        if a.action == 'verify':
            result = verify(a.set, allow_fixture=a.allow_fixture)
        else:
            with locked_source(safe_path(a.specification)) as f:
                spec = load_json(f)
            result = build(a.raw, spec, a.output, fixture=a.action == 'fixture-build')
        print(json.dumps(dict(State=result['State'], MemberCount=len(result['Members']), BootTested=False)))
        return 0
    except Exception as exc:
        # OS messages may contain local paths. Only fixed type/code belongs on the console.
        code = str(exc) if isinstance(exc, SetError) else 'FILE_OR_LOCK_OPERATION_FAILED'
        print(json.dumps(dict(State='failed', Code=code)), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
