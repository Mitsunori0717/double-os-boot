import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import restore_image as ri

class RestoreTests(unittest.TestCase):
    def manifest(self, data, sector=512):
        return dict(SchemaVersion=1,State='verified',Size=len(data),Sha256=hashlib.sha256(data).hexdigest(),Metadata=dict(AcquisitionMode='offline-block',FullSectorImage=True,SourceWriteProtected=True,GuestConsistency='offline-environment',Source=dict(UniqueId='source-wwn',SerialNumber='source-serial',Model='source-model',Size=len(data),LogicalSectorSize=sector)))
    def test_stream_all_sectors_512_and_4kn(self):
        for sector in (512,4096):
            data=bytes(range(256))*(sector//256)*3
            out=io.BytesIO(b'Z'*len(data));events=[];checks=[]
            r=ri.restore_stream(io.BytesIO(data),out,len(data),hashlib.sha256(data).hexdigest(),lambda state,**kw: events.append((state,kw)),lambda: checks.append(1),lambda f: None)
            self.assertEqual(out.getvalue(),data);self.assertEqual(r['State'],'verified');self.assertFalse(r['BootTested']);self.assertEqual(len(checks),2)
            self.assertEqual(events[-1][0],'verified')
    def test_short_read_is_failed(self):
        events=[]
        with self.assertRaisesRegex(ri.oi.SafetyError,'IMAGE_SHORT_READ'):
            ri.restore_stream(io.BytesIO(b'a'),io.BytesIO(),512,'0'*64,lambda s,**k:events.append((s,k)),lambda:None,lambda f:None)
        self.assertEqual(events[-1][0],'failed');self.assertEqual(events[-1][1]['BytesCompleted'],1)
    def test_zero_write(self):
        class Bad(io.BytesIO):
            def write(self,b):return 0
        with self.assertRaisesRegex(ri.oi.SafetyError,'TARGET_SHORT_WRITE'):
            ri.restore_stream(io.BytesIO(b'a'*512),Bad(),512,'0'*64,lambda *a,**k:None,lambda:None,lambda f:None)
    def test_flush_failure(self):
        data=b'a'*512;events=[]
        def fail(f):raise OSError('flush fail')
        with self.assertRaises(OSError):ri.restore_stream(io.BytesIO(data),io.BytesIO(),512,hashlib.sha256(data).hexdigest(),lambda s,**k:events.append((s,k)),lambda:None,fail)
        self.assertEqual(events[-1][1]['Phase'],'flush');self.assertTrue(events[-1][1]['TargetMayBePartiallyOverwritten'])
    def test_readback_mismatch(self):
        class Bad(io.BytesIO):
            def read(self,n=-1):return b'z'*len(super().read(n))
        data=b'a'*512
        with self.assertRaisesRegex(ri.oi.SafetyError,'TARGET_READBACK_MISMATCH'):
            ri.restore_stream(io.BytesIO(data),Bad(),512,hashlib.sha256(data).hexdigest(),lambda *a,**k:None,lambda:None,lambda f:None)
    def test_initial_recheck_prevents_writes(self):
        target=io.BytesIO(b'original')
        def fail():raise ri.oi.SafetyError('changed')
        with self.assertRaises(ri.oi.SafetyError):ri.restore_stream(io.BytesIO(b'a'*512),target,512,'0'*64,lambda *a,**k:None,fail,lambda f:None)
        self.assertEqual(target.getvalue(),b'original')
    def test_source_hash_failure(self):
        with self.assertRaisesRegex(ri.oi.SafetyError,'IMAGE_CHANGED_DURING_WRITE'):
            ri.restore_stream(io.BytesIO(b'a'*512),io.BytesIO(),512,'0'*64,lambda *a,**k:None,lambda:None,lambda f:None)
    def test_verified_file_and_fixture_rejection(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);data=b'a'*512;(p/'image.raw').write_bytes(data);m=self.manifest(data)
            for mode in ('offline-block','fixture-file'):
                m['Metadata']['AcquisitionMode']=mode;(p/'manifest.json').write_text(json.dumps(m))
                if mode=='offline-block':
                    with ri.verified_image(p/'image.raw',p/'manifest.json') as (f,meta,before,*_):
                        self.assertEqual(f.read(),data);ri.check_image(f,before,meta,True)
                else:
                    with self.assertRaisesRegex(ri.oi.SafetyError,'PRODUCTION_OFFLINE_IMAGE_REQUIRED'):
                        with ri.verified_image(p/'image.raw',p/'manifest.json'):pass
    def test_tampered_image(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/'i').write_bytes(b'b'*512);(p/'m').write_text(json.dumps(self.manifest(b'a'*512)))
            with self.assertRaisesRegex(ri.oi.SafetyError,'IMAGE_HASH_MISMATCH'):
                with ri.verified_image(p/'i',p/'m'):pass
    def test_manifest_duplicates(self):
        with self.assertRaisesRegex(ri.oi.SafetyError,'DUPLICATE_MANIFEST_KEY'):ri.no_duplicates([('State','verified'),('State','failed')])
    def test_confirmation_binds_target_device_and_image(self):
        m=self.manifest(b'a'*512);id={'SerialNumber':'target','Size':512}
        token=ri.confirmation_token(id,(8,0),m)
        self.assertNotEqual(token,ri.confirmation_token(id,(8,16),m))
        self.assertNotEqual(token,ri.confirmation_token(dict(id,SerialNumber='other'),(8,0),m))
        self.assertNotEqual(token,ri.confirmation_token(id,(8,0),dict(m,Sha256='0'*64)))
    def test_target_identity_gates(self):
        for sector in (512,4096):
            m=self.manifest(b'a'*sector,sector)
            identity=dict(SerialNumber='target-serial',Model='target-model',UniqueId='target-wwn',Size=sector,LogicalSectorSize=sector)
            expected=dict(identity,DeviceNumber=[8,16])
            ri.validate_target_identity(identity,(8,16),expected,m)
            for field,value in [('SerialNumber','unexpected'),('UniqueId','different'),('Size',sector*2),('LogicalSectorSize',4096 if sector==512 else 512)]:
                with self.subTest(field=field,sector=sector):
                    with self.assertRaises(ri.oi.SafetyError):ri.validate_target_identity(dict(identity,**{field:value}),(8,16),expected,m)
            with self.assertRaisesRegex(ri.oi.SafetyError,'TARGET_DEVICE_NUMBER_CHANGED'):ri.validate_target_identity(identity,(8,32),expected,m)
            bigger=dict(identity,Size=sector*2)
            with self.assertRaisesRegex(ri.oi.SafetyError,'EXACT_TARGET_CAPACITY_REQUIRED'):ri.validate_target_identity(bigger,(8,16),dict(bigger,DeviceNumber=[8,16]),m)
            original=dict(identity,SerialNumber='source-serial')
            with self.assertRaisesRegex(ri.oi.SafetyError,'ORIGINAL_SOURCE_DISK_PROTECTED'):ri.validate_target_identity(original,(8,16),dict(original,DeviceNumber=[8,16]),m)
    def test_mounted_target_rejected(self):
        row={'maj:min':'8:16','mountpoints':[]}
        with self.assertRaises(ri.oi.SafetyError):ri.oi.require_unmounted([row],[dict(device=(8,16))])
        with self.assertRaises(ri.oi.SafetyError):ri.oi.require_unmounted([dict(row,mountpoints=['/boot'])],[])
    def test_source_storage_protected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);dev=(8,1)
            mounts=[dict(device=dev,path=str(p),fs='ext4')]
            with patch.object(ri.oi,'physical_parent',return_value=(8,16)), patch.object(ri.os,'major',return_value=8,create=True), patch.object(ri.os,'minor',return_value=1,create=True):
                with self.assertRaisesRegex(ri.oi.SafetyError,'TARGET_CONTAINS_IMAGE_MANIFEST_OR_LOG'):ri.require_external_file(p,[],mounts,(8,16))
    def test_os_write_failure_marks_target_uncertain(self):
        class Bad(io.BytesIO):
            def write(self,b):raise OSError('failure with unknown write extent')
        events=[]
        with self.assertRaises(OSError):ri.restore_stream(io.BytesIO(b'a'*512),Bad(),512,'0'*64,lambda s,**k:events.append((s,k)),lambda:None,lambda f:None)
        self.assertTrue(events[-1][1]['TargetMayBePartiallyOverwritten'])
    def test_plan_and_missing_attestation_never_open_target(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);data=b'a'*512;m=self.manifest(data)
            (p/'image').write_bytes(data);(p/'manifest').write_text(json.dumps(m))
            target=p/'NEVER-CREATED';identity=dict(m['Metadata']['Source'],SerialNumber='replacement',UniqueId='replacement-wwn')
            with patch.object(ri.oi,'live_environment',return_value=[]), patch.object(ri,'target_preflight',return_value=(target,identity,(8,16))), patch.object(ri,'confirm_terminal',side_effect=AssertionError('must not prompt')), patch.object(ri.oi,'output_directory',side_effect=AssertionError('must not write')):
                plan=ri.physical_restore(p/'image',p/'manifest',target,p,'run',{},execute=False)
                self.assertEqual(plan['State'],'plan-only');self.assertTrue(plan['BasicSingleDiskConfirmationRequired'])
                with self.assertRaisesRegex(ri.oi.SafetyError,'BASIC_SINGLE_DISK_IMAGE_CONFIRMATION_REQUIRED'):
                    ri.physical_restore(p/'image',p/'manifest',target,p,'run',{},plan['ConfirmationToken'],True,True)
                with self.assertRaisesRegex(ri.oi.SafetyError,'EXPLICIT_DESTRUCTIVE_CONFIRMATION_REQUIRED'):
                    ri.physical_restore(p/'image',p/'manifest',target,p,'run',{},'wrong',True,True,True)
            self.assertFalse(target.exists())
    def test_read_lease_failure_prevents_image_use(self):
        with patch.object(ri,'locked_source',side_effect=ri.oi.SafetyError('READ_LEASE_FAILED')):
            with self.assertRaisesRegex(ri.oi.SafetyError,'READ_LEASE_FAILED'):
                with ri.verified_image('ordinary-image','ordinary-manifest'):pass
    def test_manifest_stays_locked_during_yield(self):
        import contextlib
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);data=b'a'*512;(p/'image').write_bytes(data);(p/'manifest').write_text(json.dumps(self.manifest(data)))
            active=[]
            @contextlib.contextmanager
            def lock(path):
                with open(path,'rb') as f:
                    active.append(Path(path).name)
                    try:yield f
                    finally:active.remove(Path(path).name)
            with patch.object(ri,'locked_source',lock), patch.object(ri,'check_lease'):
                with ri.verified_image(p/'image',p/'manifest') as (f,m,before,*_):
                    self.assertEqual(set(active),{'image','manifest'});ri.check_image(f,before,m)
            self.assertEqual(active,[])
    def test_manifest_strict_numeric_types(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);data=b'a'*512;(p/'image').write_bytes(data)
            cases=[('SchemaVersion',True),('SchemaVersion',1.0),('SchemaVersion','1'),('SourceSize',True),('SourceSize',512.0),('SourceSize','512')]
            for field,value in cases:
                with self.subTest(field=field,value=value):
                    m=self.manifest(data)
                    if field=='SourceSize':m['Metadata']['Source']['Size']=value
                    else:m[field]=value
                    (p/'manifest').write_text(json.dumps(m))
                    with self.assertRaises(ri.oi.SafetyError):
                        with ri.verified_image(p/'image',p/'manifest'):pass
    def test_layout_stream_zero_tail_and_patch_boundaries(self):
        source=io.BytesIO(b'abcdefgh')
        stream=ri.LayoutImage(source,8,16,[(2,b'XY'),(10,b'123')])
        wanted=b'abXYefgh'+b'\0\0'+b'123'+b'\0'*3
        self.assertEqual(stream.read(3)+stream.read(6)+stream.read(20),wanted)
        self.assertEqual(stream.read(1),b'')
        stream.seek(0);self.assertEqual(ri.oi.digest_file(stream,16),hashlib.sha256(wanted).hexdigest())
        output=io.BytesIO(b'old data present')
        ri.restore_stream(stream,output,16,hashlib.sha256(wanted).hexdigest(),lambda *a,**k:None,lambda:None,lambda f:None)
        self.assertEqual(output.getvalue(),wanted);self.assertEqual(source.getvalue(),b'abcdefgh')
    def test_layout_rejects_invalid_patches(self):
        for patches in [[(-1,b'a')],[(15,b'ab')],[(2,b'ab'),(3,b'c')],[(0,bytearray(b'a'))],[(False,b'a')]]:
            with self.subTest(patches=patches):
                with self.assertRaises(ri.oi.SafetyError):ri.LayoutImage(io.BytesIO(b'abcdefgh'),8,16,patches)
        with self.assertRaises(ri.oi.SafetyError):ri.LayoutImage(io.BytesIO(),8,8,[])
        stream=ri.LayoutImage(io.BytesIO(b'short'),8,16,[])
        with self.assertRaisesRegex(ri.oi.SafetyError,'LAYOUT_SOURCE_SHORT_READ'):stream.read(8)
    def test_larger_mbr_full_target_readback(self):
        import struct
        for sector in (512,4096):
            data=bytearray(16*sector);data[510:512]=b'\x55\xaa'
            data[450]=7;struct.pack_into('<II',data,454,2,4)
            data[2*sector:6*sector]=b'P'*(4*sector)
            raw=bytes(data);m=self.manifest(raw,sector);source=io.BytesIO(raw)
            view,digest,layout=ri.prepare_restore_view(source,m,24*sector,True)
            self.assertEqual(layout['Mode'],'larger-target-mbr');self.assertFalse(layout['PartitionsResized'])
            wanted=raw+b'\0'*(8*sector)
            self.assertEqual(digest,hashlib.sha256(wanted).hexdigest())
            out=io.BytesIO(b'OLD'*(8*sector))
            ri.restore_stream(view,out,len(wanted),digest,lambda *a,**k:None,lambda:None,lambda f:None)
            self.assertEqual(out.getvalue(),wanted);self.assertEqual(source.getvalue(),raw)
            self.assertNotEqual(digest,m['Sha256'])
            with self.assertRaisesRegex(ri.oi.SafetyError,'EXACT_TARGET_CAPACITY_REQUIRED'):ri.prepare_restore_view(source,m,len(wanted),False)
    def test_larger_unknown_layout_rejected(self):
        data=b'X'*4096
        with self.assertRaisesRegex(ri.oi.SafetyError,'LAYOUT_REJECTED'):ri.prepare_restore_view(io.BytesIO(data),self.manifest(data),8192,True)
    def test_confirmation_binds_transformation(self):
        m=self.manifest(b'a'*512);identity={'SerialNumber':'target','Size':1024}
        exact=ri.confirmation_token(identity,(8,16),m)
        self.assertNotEqual(exact,ri.confirmation_token(identity,(8,16),m,'1'*64,'larger-target-gpt'))
        identity=dict(SerialNumber='replacement',UniqueId='replacement-wwn',Model='model',Size=1024,LogicalSectorSize=512)
        ri.validate_target_identity(identity,(8,16),dict(identity,DeviceNumber=[8,16]),m,True)
        with self.assertRaises(ri.oi.SafetyError):ri.validate_target_identity(identity,(8,16),dict(identity,DeviceNumber=[8,16]),m,False)
    def test_larger_gpt_end_to_end_synthetic(self):
        from test_larger_disk_layout import gpt, apply
        import larger_disk_layout
        for sector in (512,4096):
            raw=bytes(gpt(sector=sector,count=128))
            for extra in (1,64):
                with self.subTest(sector=sector,extra=extra):
                    source=io.BytesIO(raw);m=self.manifest(raw,sector);target_size=len(raw)+sector*extra
                    view,digest,layout=ri.prepare_restore_view(source,m,target_size,True)
                    plan=larger_disk_layout.plan(len(raw),target_size,sector,lambda offset,length:raw[offset:offset+length])
                    wanted=bytes(apply(raw,plan))
                    self.assertEqual(digest,hashlib.sha256(wanted).hexdigest())
                    out=io.BytesIO(b'X'*target_size)
                    ri.restore_stream(view,out,target_size,digest,lambda *a,**k:None,lambda:None,lambda f:None)
                    self.assertEqual(out.getvalue(),wanted);self.assertEqual(source.getvalue(),raw)
                    self.assertEqual(layout['Mode'],'larger-target-gpt');self.assertTrue(layout['PartitionEntriesPreserved'])
                    # The produced destination must parse again with matching CRCs and new backup location.
                    larger_disk_layout.plan(target_size,target_size+sector,sector,lambda offset,length:wanted[offset:offset+length])
    def test_terminal_required(self):
        with patch.object(sys.stdin,'isatty',return_value=False):
            with self.assertRaisesRegex(ri.oi.SafetyError,'INTERACTIVE_TARGET_CONFIRMATION_REQUIRED'):ri.confirm_terminal({'SerialNumber':'target','Size':512},(8,0),'a'*64)

if __name__=='__main__':unittest.main()
