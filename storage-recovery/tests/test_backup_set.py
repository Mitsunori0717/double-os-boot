"""Temporary regular files only; no devices, VM commands or external queries."""
import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backup_set as b


class BackupSetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.paths = []
        self.disks = []
        now = dt.datetime.now(dt.timezone.utc)
        for i in range(2):
            raw = self.root / ('disk%d.raw' % i)
            raw.write_bytes(bytes([i]) * 8192)
            disk = dict(UniqueId='test-%d' % i, Model='synthetic', SerialNumber='serial-%d' % i,
                        Size=8192, LogicalSectorSize=4096 if i else 512)
            self.disks.append(disk)
            manifest = dict(SchemaVersion=1, State='verified', Size=8192,
                CreatedUtc=(now-dt.timedelta(minutes=5)).isoformat(), Sha256=hashlib.sha256(raw.read_bytes()).hexdigest(),
                Metadata=dict(Source=disk, FullSectorImage=True, AcquisitionMode='fixture-file',
                              SourceWriteProtected=False, GuestConsistency='fixture-only'))
            Path(str(raw)+'.manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
            self.paths.append(raw)
        self.spec = dict(SchemaVersion=1, Topology='simple-independent', BootDiskUniqueId='test-0',
            ExpectedDisks=self.disks, Attestation=dict(Shutdown='full-shutdown', AllDependentDisksIncluded=True,
                NoWritesDuringAcquisition=True, QuiescentStartUtc=(now-dt.timedelta(hours=1)).isoformat(),
                QuiescentEndUtc=(now-dt.timedelta(minutes=1)).isoformat()))
        self.output = self.root/'set.json'

    def tearDown(self):
        self.tmp.cleanup()

    def build(self):
        return b.build(self.paths, self.spec, self.output, fixture=True)

    def test_fixture_roundtrip_and_no_boot_claim(self):
        ledger = self.build()
        self.assertEqual(b.verify(self.output, allow_fixture=True), ledger)
        self.assertFalse(ledger['BootTested'])
        self.assertFalse(ledger['AutomaticRestoreAuthorized'])
        self.assertEqual(ledger['Consistency'], 'operator-attested-not-proven')
        self.assertEqual(ledger['Members'][1]['Source']['LogicalSectorSize'],4096)
        self.assertNotIn(str(self.root), self.output.read_text())

    def test_production_refuses_fixture(self):
        with self.assertRaisesRegex(b.SetError,'FIXTURE_OR_UNKNOWN'):
            b.build(self.paths, self.spec, self.output)
        self.build()
        with self.assertRaisesRegex(b.SetError,'FIXTURE_SET_REFUSED'):
            b.verify(self.output)

    def test_all_attestations_required(self):
        for key,val in [('Shutdown','hibernated'),('AllDependentDisksIncluded',False),('NoWritesDuringAcquisition',1)]:
            with self.subTest(key=key):
                spec=copy.deepcopy(self.spec);spec['Attestation'][key]=val
                with self.assertRaises(b.SetError): b.specification(spec)

    def test_schema_and_secrets_rejected(self):
        for key in ('RecoveryKey','Password','Notes'):
            spec=copy.deepcopy(self.spec);spec[key]='secret'
            with self.assertRaises(b.SetError): b.specification(spec)
        spec=copy.deepcopy(self.spec);spec['ExpectedDisks'][0]['SerialNumber']='111111-222222-333333-444444-555555-666666-777777-888888'
        with self.assertRaisesRegex(b.SetError,'SECRET_PATTERN'): b.specification(spec)

    def test_unsupported_topologies(self):
        for t in ('raid','storage-spaces','dynamic','unknown',''):
            spec=copy.deepcopy(self.spec);spec['Topology']=t
            with self.assertRaisesRegex(b.SetError,'TOPOLOGY'): b.specification(spec)

    def test_incomplete_duplicate_and_order(self):
        for paths in (self.paths[:1], [self.paths[0]]*2, list(reversed(self.paths))):
            with self.assertRaises(b.SetError): b.verify_members(paths,self.spec,allow_fixture=True)
        spec=copy.deepcopy(self.spec);spec['ExpectedDisks'][1]=spec['ExpectedDisks'][0]
        with self.assertRaisesRegex(b.SetError,'DUPLICATE'): b.specification(spec)
        spec=copy.deepcopy(self.spec);spec['BootDiskUniqueId']='missing'
        with self.assertRaisesRegex(b.SetError,'BOOT_DISK'): b.specification(spec)

    def test_corrupt_raw_and_manifest(self):
        self.build();self.paths[0].write_bytes(b'x'*8192)
        with self.assertRaisesRegex(b.SetError,'RAW_HASH'): b.verify(self.output,allow_fixture=True)

    def test_changed_manifest_rejected_even_with_unchanged_raw(self):
        self.build()
        p=Path(str(self.paths[0])+'.manifest.json');p.write_text(p.read_text()+'\n')
        with self.assertRaisesRegex(b.SetError,'SET_MEMBER_CHANGED'): b.verify(self.output,allow_fixture=True)

    def test_set_success_claim_rejected(self):
        ledger=self.build();ledger['BootTested']=True;self.output.write_text(json.dumps(ledger))
        with self.assertRaisesRegex(b.SetError,'UNSUPPORTED_SUCCESS'): b.verify(self.output,allow_fixture=True)

    def test_boolean_schema_and_size_rejected(self):
        p=Path(str(self.paths[0])+'.manifest.json');original=json.loads(p.read_text())
        for field in ('SchemaVersion','Size'):
            value=copy.deepcopy(original);value[field]=True;p.write_text(json.dumps(value))
            with self.subTest(field=field):
                with self.assertRaises(b.SetError): self.build()
        p.write_text(json.dumps(original))
        ledger=self.build();ledger['SchemaVersion']=True;self.output.write_text(json.dumps(ledger))
        with self.assertRaisesRegex(b.SetError,'SET_SCHEMA_INVALID'): b.verify(self.output,allow_fixture=True)

    def test_traversal_rejected(self):
        ledger=self.build();ledger['Members'][0]['RawFile']='../disk0.raw';self.output.write_text(json.dumps(ledger))
        with self.assertRaisesRegex(b.SetError,'MEMBER_PATH'): b.verify(self.output,allow_fixture=True)

    def test_existing_output_and_partial_preserved(self):
        self.output.write_text('keep')
        with self.assertRaisesRegex(b.SetError,'OUTPUT_EXISTS'): self.build()
        self.assertEqual(self.output.read_text(),'keep')
        self.output.unlink();partial=Path(str(self.output)+'.partial');partial.write_text('keep partial')
        with self.assertRaises(FileExistsError): self.build()
        self.assertEqual(partial.read_text(),'keep partial')

    def test_flush_failure_never_publishes(self):
        with patch.object(b.os,'fsync',side_effect=OSError('secret-path')):
            with self.assertRaises(OSError): self.build()
        self.assertFalse(self.output.exists())
        self.assertTrue(Path(str(self.output)+'.partial').exists())

    def test_bad_time_and_outside_acquisition(self):
        for t in ('2020-01-01','not-date','2999-01-01T00:00:00Z'):
            spec=copy.deepcopy(self.spec);spec['Attestation']['QuiescentEndUtc']=t
            with self.assertRaises(b.SetError): b.specification(spec)
        spec=copy.deepcopy(self.spec);spec['Attestation']['QuiescentStartUtc']=spec['Attestation']['QuiescentEndUtc']
        with self.assertRaises(b.SetError): b.specification(spec)

    def test_size_and_geometry_and_duplicate_json(self):
        self.paths[0].write_bytes(b'x')
        with self.assertRaisesRegex(b.SetError,'RAW_SIZE'): self.build()
        import io
        with self.assertRaisesRegex(b.SetError,'DUPLICATE_JSON_KEY'): b.load_json(io.BytesIO(b'{"x":1,"x":2}'))
        spec=copy.deepcopy(self.spec);spec['ExpectedDisks'][0]['LogicalSectorSize']=True
        with self.assertRaises(b.SetError): b.specification(spec)

    def test_identical_bytes_different_physical_identities_allowed(self):
        self.paths[1].write_bytes(self.paths[0].read_bytes())
        p=Path(str(self.paths[1])+'.manifest.json');m=json.loads(p.read_text());m['Sha256']=hashlib.sha256(self.paths[1].read_bytes()).hexdigest();p.write_text(json.dumps(m))
        ledger=self.build()
        self.assertEqual(ledger['Members'][0]['Sha256'],ledger['Members'][1]['Sha256'])
        self.assertNotEqual(ledger['Members'][0]['Source'],ledger['Members'][1]['Source'])


if __name__=='__main__':
    unittest.main()
