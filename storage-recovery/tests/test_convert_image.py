import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('convert_image',ROOT/'convert_image.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)

class ConversionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='EdgeBoxConvertTests_')
        self.root=Path(self.tmp.name)
        self.raw=self.root/'source.raw';self.raw.write_bytes(bytes(range(256))*16)
        self.qemu=self.root/('qemu-img.exe' if os.name=='nt' else 'qemu-img');self.qemu.write_bytes(b'fixture only, never executed')
        self.output=self.root/'result.vhdx'
        self.manifest={'SchemaVersion':1,'State':'verified','Size':4096,'Sha256':hashlib.sha256(self.raw.read_bytes()).hexdigest(),
          'Metadata':{'Source':{'Size':4096,'LogicalSectorSize':512,'UniqueId':'fixture-id','SerialNumber':'fixture-serial'},
                      'AcquisitionMode':'fixture-file','FullSectorImage':True}}
        self.save_manifest();self.calls=[]
        self.sector_patch=mock.patch.object(c,'read_vhdx_sector_size',return_value=512);self.sector_patch.start();self.addCleanup(self.sector_patch.stop)
    def tearDown(self): self.tmp.cleanup()
    def save_manifest(self): Path(str(self.raw)+'.manifest.json').write_text(json.dumps(self.manifest),encoding='utf-8')
    def runner(self,executable,args,timeout,record):
        self.calls.append(args)
        if args[0]=='--version': return 'qemu-img fixture'
        if args[0]=='convert': Path(args[-1]).write_bytes(b'fake container'+self.raw.read_bytes());return ''
        if args[0]=='info': return json.dumps({'format':'vhdx','virtual-size':4096})
        return ''
    def convert(self,**kw):
        return c.convert(self.raw,self.output,self.qemu,allow_fixture=True,runner=kw.pop('runner',self.runner),**kw)
    def test_success_contract(self):
        r=self.convert();self.assertEqual(r['State'],'verified');self.assertFalse(r['BootTested']);self.assertFalse(r['RestoreTested'])
        self.assertTrue(r['Verification']['LogicalCompare']);self.assertEqual(r['Sha256'],hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual([x[0] for x in self.calls],['--version','convert','info','check','compare'])
        self.assertNotIn('-r',sum(self.calls,[]));self.assertNotIn('--salvage',sum(self.calls,[]));self.assertNotIn('-U',sum(self.calls,[]))
        self.assertEqual(self.raw.stat().st_size,4096)
    def test_existing_output_rejected(self):
        self.output.write_bytes(b'keep');self.assertRaises(c.ConversionError,self.convert);self.assertEqual(self.output.read_bytes(),b'keep')
    def test_manifest_state(self):
        self.manifest['State']='copied';self.save_manifest();self.assertRaises(c.ConversionError,self.convert);self.assertFalse(self.calls)
    def test_hash_corruption(self):
        self.raw.write_bytes(b'x'*4096);self.assertRaises(c.ConversionError,self.convert);self.assertFalse(self.calls)
    def test_size_mismatch(self):
        self.raw.write_bytes(b'x');self.assertRaises(c.ConversionError,self.convert)
    def test_4kn_rejected(self):
        self.manifest['Metadata']['Source']['LogicalSectorSize']=4096;self.save_manifest();self.assertRaises(c.ConversionError,self.convert)
    def test_fixture_gate(self):
        self.assertRaises(c.ConversionError,c.convert,self.raw,self.output,self.qemu,runner=self.runner)
    def test_non_full_sector_rejected(self):
        self.manifest['Metadata']['FullSectorImage']=False;self.save_manifest();self.assertRaises(c.ConversionError,self.convert)
    def test_offline_source_requires_write_protection(self):
        self.manifest['Metadata']['AcquisitionMode']='offline-block';self.save_manifest()
        self.assertRaises(c.ConversionError,self.convert);self.assertFalse(self.calls)
    def test_unknown_mode_rejected(self):
        self.manifest['Metadata']['AcquisitionMode']='live';self.save_manifest();self.assertRaises(c.ConversionError,self.convert)
    def test_no_source_identity(self):
        del self.manifest['Metadata']['Source']['UniqueId'];self.save_manifest();self.assertRaises(c.ConversionError,self.convert)
    def test_boolean_size(self):
        self.manifest['Size']=True;self.save_manifest();self.assertRaises(c.ConversionError,self.convert)
    def test_insufficient_capacity(self):
        with mock.patch.object(c.shutil,'disk_usage',return_value=mock.Mock(free=10)):
            self.assertRaises(c.ConversionError,self.convert)
    def test_wrong_virtual_size(self):
        def runner(exe,args,timeout,record):
            if args[0]=='info':return json.dumps({'format':'vhdx','virtual-size':8192})
            return self.runner(exe,args,timeout,record)
        self.assertRaises(c.ConversionError,self.convert,runner=runner);self.assertFalse(self.output.exists())
    def test_backing_file_rejected(self):
        def runner(exe,args,timeout,record):
            if args[0]=='info':return json.dumps({'format':'vhdx','virtual-size':4096,'backing-filename':'other'})
            return self.runner(exe,args,timeout,record)
        self.assertRaises(c.ConversionError,self.convert,runner=runner);self.assertFalse(self.output.exists())
    def test_compare_failure_does_not_publish(self):
        def runner(exe,args,timeout,record):
            if args[0]=='compare':raise c.ConversionError('logical mismatch')
            return self.runner(exe,args,timeout,record)
        self.assertRaises(c.ConversionError,self.convert,runner=runner);self.assertFalse(self.output.exists())
        self.assertIn('failed',Path(str(self.output)+'.events.jsonl').read_text())
    def test_check_failure_does_not_publish(self):
        def runner(exe,args,timeout,record):
            if args[0]=='check':raise c.ConversionError('broken')
            return self.runner(exe,args,timeout,record)
        self.assertRaises(c.ConversionError,self.convert,runner=runner);self.assertFalse(self.output.exists())
    def test_qemu_timeout(self):
        with mock.patch.object(c.subprocess,'run',side_effect=subprocess.TimeoutExpired(['qemu'],1)):
            self.assertRaises(c.ConversionError,c.run_qemu,self.qemu,['info'],1,lambda *a:None)
    def test_no_overwrite_publish_race(self):
        def runner(exe,args,timeout,record):
            result=self.runner(exe,args,timeout,record)
            if args[0]=='compare':self.output.write_bytes(b'concurrent protected')
            return result
        self.assertRaises(FileExistsError,self.convert,runner=runner);self.assertEqual(self.output.read_bytes(),b'concurrent protected')
    def test_unsafe_paths(self):
        for p in ['\\\\.\\PhysicalDrive0','\\\\server\\share\\raw','//server/share/raw']:
            with self.subTest(path=p):self.assertRaises(c.ConversionError,c.safe_path,p)
        if os.name=='nt':
            for p in ['NUL','test.','foo.raw:ads']:
                with self.subTest(path=p):self.assertRaises(c.ConversionError,c.safe_path,p)
    def test_symlink(self):
        link=self.root/'link.raw'
        try:link.symlink_to(self.raw)
        except OSError:self.skipTest('symlink permission absent')
        self.assertRaises(c.ConversionError,c.safe_path,link)
    @unittest.skipUnless(os.name=='nt','Windows mandatory sharing test')
    def test_windows_source_write_denied(self):
        with c.locked_source(self.raw):
            with self.assertRaises(OSError):
                with open(self.raw,'r+b') as f:f.write(b'x')
    @unittest.skipUnless(os.environ.get('QEMU_IMG_TEST_EXE'),'real qemu-img path not configured')
    def test_real_qemu_pipeline(self):
        self.sector_patch.stop()
        r=c.convert(self.raw,self.output,os.environ['QEMU_IMG_TEST_EXE'],allow_fixture=True,timeout=60)
        self.assertEqual(r['VirtualSize'],4096)
        self.assertTrue(r['Verification']['LogicalSectorSize'])
        self.assertTrue(r['Verification']['LogicalCompare'])
    def test_wrong_output_sector(self):
        with mock.patch.object(c,'read_vhdx_sector_size',return_value=4096):
            self.assertRaises(c.ConversionError,self.convert)
        self.assertFalse(self.output.exists())
    def test_invalid_timeout(self):self.assertRaises(c.ConversionError,self.convert,timeout=0)

if __name__=='__main__':unittest.main()
