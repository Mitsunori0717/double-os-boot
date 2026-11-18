import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('offline_image', Path(__file__).resolve().parents[1]/'offline_image.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class OfflineImageTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='EdgeBoxOfflineTests_')
        self.root=Path(self.tmp.name)
        self.identity=dict(UniqueId='id',SerialNumber='serial',Model='model',Size=1024,LogicalSectorSize=512)
        self.data=bytes(range(256))*4
    def tearDown(self): self.tmp.cleanup()
    def copy(self, stream=None, name='test', final_check=lambda:None):
        return m.copy_stream(stream or io.BytesIO(self.data),self.root,name,self.identity,'fixture-file',final_check)
    def test_round_trip_every_sector(self):
        result=self.copy()
        self.assertEqual((self.root/'test.raw').read_bytes(),self.data)
        self.assertEqual(result['Sha256'],m.hashlib.sha256(self.data).hexdigest())
        self.assertFalse(result['RestoreTested'])
        self.assertEqual(result['Metadata']['AcquisitionMode'],'fixture-file')
        self.assertTrue(result['Metadata']['FullSectorImage'])
        self.assertEqual(json.loads((self.root/'test.raw.manifest.json').read_text()),result)
        self.assertFalse((self.root/'test.raw.partial').exists())
        self.assertEqual([json.loads(x)['State'] for x in (self.root/'test.raw.events.jsonl').read_text().splitlines()],['partial','copied','verified'])
    def test_no_overwrite(self):
        self.copy()
        with self.assertRaisesRegex(m.SafetyError,'OUTPUT_ALREADY_EXISTS'): self.copy()
        self.assertEqual((self.root/'test.raw').read_bytes(),self.data)
    def test_existing_final_never_overwritten_on_publish(self):
        def collision(): (self.root/'test.raw').write_bytes(b'protected')
        with self.assertRaises(FileExistsError): self.copy(final_check=collision)
        self.assertEqual((self.root/'test.raw').read_bytes(),b'protected')
        self.assertFalse((self.root/'test.raw.manifest.json').exists())
    def test_short_read(self):
        with self.assertRaisesRegex(m.SafetyError,'SOURCE_SHORT_READ'): self.copy(io.BytesIO(b'abc'))
        self.assertFalse((self.root/'test.raw').exists())
        self.assertEqual(json.loads((self.root/'test.raw.events.jsonl').read_text().splitlines()[-1])['BytesCompleted'],3)
    def test_long_read(self):
        with self.assertRaisesRegex(m.SafetyError,'SOURCE_LONGER'): self.copy(io.BytesIO(self.data+b'!'))
        self.assertFalse((self.root/'test.raw').exists())
    def test_short_chunks_supported(self):
        class Short(io.BytesIO):
            def read(self,n=-1): return super().read(min(n,17))
        self.copy(Short(self.data))
        self.assertEqual((self.root/'test.raw').read_bytes(),self.data)
    def test_io_error_fails(self):
        class Broken(io.BytesIO):
            def read(self,n=-1): raise OSError(5,'simulated device read error')
        with self.assertRaises(OSError): self.copy(Broken())
        log=json.loads((self.root/'test.raw.events.jsonl').read_text().splitlines()[-1])
        self.assertEqual(log['Errno'],5);self.assertEqual(log['State'],'failed')
        self.assertFalse((self.root/'test.raw.manifest.json').exists())
    def test_fsync_error_fails(self):
        with mock.patch.object(m.os,'fsync',side_effect=OSError(5,'flush failed')):
            with self.assertRaises(OSError): self.copy()
        self.assertFalse((self.root/'test.raw').exists())
    def test_no_space_fails(self):
        with mock.patch.object(m.shutil,'disk_usage',return_value=mock.Mock(free=1023)):
            with self.assertRaisesRegex(m.SafetyError,'CAPACITY'): self.copy()
        self.assertEqual(list(self.root.iterdir()),[])
    def test_final_identity_failure_no_commit(self):
        def changed(): raise m.SafetyError('SOURCE_CHANGED')
        with self.assertRaisesRegex(m.SafetyError,'SOURCE_CHANGED'): self.copy(final_check=changed)
        self.assertTrue((self.root/'test.raw.partial').exists())
        self.assertFalse((self.root/'test.raw').exists())
    def test_readback_corrupt_no_commit(self):
        with mock.patch.object(m,'digest_file',return_value='0'*64):
            with self.assertRaisesRegex(m.SafetyError,'READBACK_HASH'): self.copy()
        self.assertFalse((self.root/'test.raw').exists())
    def test_output_name(self):
        for name in ('../bad','/dev/sda','a/b','a\\b','.hidden','NUL','COM1',''):
            with self.subTest(name=name):
                with self.assertRaises(m.SafetyError): self.copy(name=name)
    def test_special_paths_fixture(self):
        for path in ('/dev/sda','/proc/kcore','/sys/devices','\\\\.\\PhysicalDrive0','\\\\server\\share'):
            with self.subTest(path=path):
                with self.assertRaises(m.SafetyError): m.regular_path(path)
    def test_fixture_regular_copy(self):
        p=self.root/'input.bin';p.write_bytes(self.data)
        result=m.fixture_copy(p,self.root,'fixture',512)
        self.assertEqual(result['Metadata']['Source']['Model'],'synthetic-file')
    def test_fixture_directory_refused(self):
        with self.assertRaisesRegex(m.SafetyError,'REGULAR'): m.fixture_copy(self.root,self.root,'fixture',512)
    def test_fixture_unaligned_refused(self):
        p=self.root/'input.bin';p.write_bytes(b'abc')
        with self.assertRaisesRegex(m.SafetyError,'SIZE_INVALID'): m.fixture_copy(p,self.root,'fixture',512)
    def test_nonlinux_acquire_refused(self):
        with mock.patch.object(m.sys,'platform','win32'):
            with self.assertRaisesRegex(m.SafetyError,'LINUX_ROOT'): m.acquire('unused',self.root,'disk',self.identity)
    def test_identity_missing_or_wrong(self):
        row={'type':'disk','serial':'s','model':'m','size':1024,'log-sec':512}
        ident=m.disk_identity(row)
        self.assertEqual(ident['UniqueId'],'serial:m:s')
        for key in ('serial','model','size','log-sec'):
            broken=row.copy();broken[key]=None
            with self.assertRaises(m.SafetyError): m.disk_identity(broken)
        with self.assertRaisesRegex(m.SafetyError,'MISMATCH'): m.expected_matches(ident,self.identity)
    def test_duplicate_physical_identity(self):
        row={'type':'disk','serial':'s','model':'m','size':1024,'log-sec':512}
        identity=m.disk_identity(row)
        m.require_unique_identity([row],identity)
        with self.assertRaisesRegex(m.SafetyError,'AMBIGUOUS'): m.require_unique_identity([row,row.copy()],identity)
    def test_unknown_ambiguous_device(self):
        r={'maj:min':'8:0'}
        with self.assertRaises(m.SafetyError): m.find_source([], (8,0))
        with self.assertRaises(m.SafetyError): m.find_source([r,r], (8,0))
    def test_topology_rejects_mapped_storage(self):
        rows=[{'name':'/dev/sda','type':'disk','maj:min':'8:0'},
              {'name':'/dev/sda1','pkname':'/dev/sda','type':'part','maj:min':'8:1'}]
        self.assertEqual(m.physical_parent(rows,(8,1)),(8,0))
        rows[0]['type']='lvm'
        with self.assertRaises(m.SafetyError): m.physical_parent(rows,(8,1))
    def test_descendant_mapping_rejected(self):
        rows=[{'name':'/dev/sda','type':'disk','maj:min':'8:0'},
              {'name':'/dev/mapper/x','pkname':'/dev/sda','type':'crypt','maj:min':'253:0'}]
        with self.assertRaises(m.SafetyError): m.descendants(rows,rows[0])
    def test_mount_parse(self):
        result=m.mount_rows('20 1 8:1 / /mnt/backup\\040ssd rw - ext4 /dev/sda1 rw')
        self.assertEqual(result[0]['path'],'/mnt/backup ssd')
        self.assertEqual(result[0]['device'],(8,1))
    def test_mounted_or_unknown_source_refused(self):
        rows=[{'maj:min':'8:0','mountpoints':[None]}, {'maj:min':'8:1','mountpoints':[None]}]
        self.assertEqual(m.require_unmounted(rows,[]),{(8,0),(8,1)})
        with self.assertRaisesRegex(m.SafetyError,'MOUNTED'):
            m.require_unmounted(rows,[{'device':(8,1)}])
        rows[1]['mountpoints']=['/mnt/source']
        with self.assertRaisesRegex(m.SafetyError,'MOUNT_STATE'): m.require_unmounted(rows,[])
        del rows[1]['mountpoints']
        with self.assertRaisesRegex(m.SafetyError,'MOUNT_STATE'): m.require_unmounted(rows,[])
    def test_kernel_write_protection_required_for_every_device(self):
        rows=[{'maj:min':'8:0'}, {'maj:min':'8:1'}]
        with mock.patch.object(m.Path,'read_text',side_effect=['1\n','1\n']) as reader:
            m.require_source_write_protected(rows)
            self.assertEqual(reader.call_count,2)
        for values in (['0','1'],['1','0'],['1',''],['1','garbage']):
            with self.subTest(values=values), mock.patch.object(m.Path,'read_text',side_effect=values):
                with self.assertRaisesRegex(m.SafetyError,'SOURCE_WRITE_PROTECTION_REQUIRED'):
                    m.require_source_write_protected(rows)
        with mock.patch.object(m.Path,'read_text',side_effect=PermissionError('cannot read ro')):
            with self.assertRaisesRegex(m.SafetyError,'SOURCE_WRITE_PROTECTION_REQUIRED'):
                m.require_source_write_protected(rows)
    def test_open_fd_requires_kernel_readonly(self):
        fake=mock.Mock()
        fake.ioctl.return_value=m.struct.pack('i',1)
        m.require_readonly_fd(99,fake)
        fake.ioctl.assert_called_once_with(99,0x125e,b'\0'*4)
        for value in (0,2,-1):
            fake.ioctl.return_value=m.struct.pack('i',value)
            with self.assertRaisesRegex(m.SafetyError,'SOURCE_WRITE_PROTECTION_REQUIRED'):
                m.require_readonly_fd(99,fake)
        fake.ioctl.side_effect=OSError(5,'ioctl failed')
        with self.assertRaisesRegex(m.SafetyError,'SOURCE_WRITE_PROTECTION_REQUIRED'):
            m.require_readonly_fd(99,fake)
    def test_exclusive_read_only_acquisition_adapter(self):
        fakefcntl=mock.Mock()
        fakefcntl.ioctl.side_effect=[m.struct.pack('Q',1024),m.struct.pack('I',512),m.struct.pack('i',1),m.struct.pack('i',1),m.struct.pack('i',1)]
        fake_stat=mock.Mock(st_mode=m.stat.S_IFBLK,st_rdev=800)
        def copying(stream,destination,name,identity,mode,callback):
            self.assertEqual(mode,'offline-block')
            callback()
            return {'State':'verified'}
        with mock.patch.dict(sys.modules,{'fcntl':fakefcntl}), \
             mock.patch.object(m,'preflight',return_value=(Path('/dev/source'),self.root,self.identity,(8,0))) as pre, \
             mock.patch.object(m.os,'O_NOFOLLOW',0x20000,create=True), \
             mock.patch.object(m.os,'open',return_value=99) as opened, \
             mock.patch.object(m.os,'close') as closed, \
             mock.patch.object(m.os,'fstat',return_value=fake_stat), \
             mock.patch.object(m.os,'major',return_value=8,create=True), \
             mock.patch.object(m.os,'minor',return_value=0,create=True), \
             mock.patch.object(m.os,'fdopen',return_value=io.BytesIO(self.data)), \
             mock.patch.object(m,'copy_stream',side_effect=copying):
            result=m.acquire('source',self.root,'disk',self.identity)
            self.assertEqual(result['State'],'verified')
            flags=opened.call_args.args[1]
            self.assertTrue(flags & m.os.O_EXCL)
            self.assertFalse(flags & m.os.O_WRONLY)
            self.assertFalse(flags & m.os.O_RDWR)
            self.assertEqual(pre.call_count,3)
            closed.assert_called_once_with(99)
    def test_digest_length(self):
        with self.assertRaises(m.SafetyError): m.digest_file(io.BytesIO(b'x'),2)
        with self.assertRaises(m.SafetyError): m.digest_file(io.BytesIO(b'xx'),1)

if __name__=='__main__': unittest.main()
