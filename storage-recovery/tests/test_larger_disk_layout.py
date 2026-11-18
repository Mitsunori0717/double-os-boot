"""All layouts are synthetic byte arrays, never physical disk reads/writes."""
import struct
import sys
from pathlib import Path
import unittest
import uuid

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import larger_disk_layout as l


def gpt(sector=512, count=128):
    n=128;blocks=(count*128+sector-1)//sector
    raw=bytearray(n*sector);raw[510:512]=b'\x55\xaa';raw[450]=0xee
    struct.pack_into('<II',raw,454,1,n-1)
    entries=bytearray(blocks*sector)
    entries[:16]=uuid.UUID('ebd0a0a2-b9e5-4433-87c0-68b6b72699c7').bytes_le
    entries[16:32]=uuid.UUID('12345678-1111-2222-3333-123456789abc').bytes_le
    struct.pack_into('<QQ',entries,32,2+blocks,90)
    disk=uuid.UUID('12345678-1111-2222-3333-123456789abd').bytes_le
    for here,other,loc in ((1,n-1,2),(n-1,1,n-1-blocks)):
        h=bytearray(sector);h[:8]=b'EFI PART'
        struct.pack_into('<II',h,8,0x10000,92)
        struct.pack_into('<QQQQ',h,24,here,other,2+blocks,n-2-blocks)
        h[56:72]=disk
        struct.pack_into('<QIII',h,72,loc,count,128,l.crc(entries[:count*128]))
        struct.pack_into('<I',h,16,l.crc(h[:92]))
        raw[here*sector:(here+1)*sector]=h
        raw[loc*sector:(loc+blocks)*sector]=entries
    raw[(2+blocks)*sector:90*sector]=b'X'*((90-2-blocks)*sector)
    return raw


def apply(raw, plan):
    result=bytearray(raw)+bytearray(plan['TargetSize']-len(raw))
    intervals=[]
    for p in plan['Patches']:
        start=p['Offset'];end=start+len(p['Data'])
        assert start>=0 and end<=len(result)
        assert all(end<=a or start>=b for a,b in intervals)
        intervals.append((start,end));result[start:end]=p['Data']
    return result


def refresh_header(raw,offset,sector):
    struct.pack_into('<I',raw,offset+16,0)
    struct.pack_into('<I',raw,offset+16,l.crc(raw[offset:offset+92]))


class LargerLayoutTests(unittest.TestCase):
    def planning(self,raw,extra=64,sector=512):
        return l.plan(len(raw),len(raw)+extra*sector,sector,lambda o,n:bytes(raw[o:o+n]))

    def test_gpt_512_and_4kn_preserve_partitions(self):
        for sector in (512,4096):
            raw=gpt(sector)
            p=self.planning(raw,64,sector);out=apply(raw,p)
            self.assertEqual(p['Layout'],'GPT');self.assertFalse(p['PartitionsResized'])
            self.assertEqual(out[2*sector:91*sector],raw[2*sector:91*sector])
            # Valid output can itself be planned for another growth, checking both CRCs.
            p2=self.planning(out,1,sector)
            self.assertEqual(p2['PartitionCount'],1)
            self.assertEqual(out[56+sector:72+sector],raw[56+sector:72+sector])
            self.assertFalse(p['BootTested'])

    def test_one_sector_growth_has_nonoverlap_patches(self):
        for sector in (512,4096):
            raw=gpt(sector,128)
            out=apply(raw,self.planning(raw,1,sector))
            self.planning(out,1,sector)

    def test_zeroes_old_backup_and_tail(self):
        raw=gpt();out=apply(raw,self.planning(raw,64))
        self.assertEqual(out[95*512:159*512],bytes(64*512))

    def test_both_header_crc_invalid(self):
        for offset in (512,127*512):
            raw=gpt();raw[offset+16]^=1
            with self.assertRaisesRegex(l.LayoutError,'HEADER_CRC'):self.planning(raw)

    def test_entry_crc_and_copy_mismatch(self):
        raw=gpt();raw[2*512+80]^=1
        with self.assertRaisesRegex(l.LayoutError,'COPIES_DISAGREE'):self.planning(raw)
        raw=gpt();raw[2*512+80]^=1;raw[95*512+80]^=1
        with self.assertRaisesRegex(l.LayoutError,'ENTRIES_CRC'):self.planning(raw)

    def test_hybrid_and_bad_protective_mbr(self):
        raw=gpt();raw[466]=7
        with self.assertRaisesRegex(l.LayoutError,'HYBRID'):self.planning(raw)
        raw=gpt();struct.pack_into('<I',raw,458,12)
        with self.assertRaisesRegex(l.LayoutError,'PROTECTIVE'):self.planning(raw)

    def mutate_entries(self,raw,fn):
        entries=bytearray(raw[1024:17408]);fn(entries)
        raw[1024:17408]=entries;raw[95*512:127*512]=entries
        for offset in (512,127*512):
            struct.pack_into('<I',raw,offset+88,l.crc(entries));refresh_header(raw,offset,512)

    def test_unknown_dynamic_guid(self):
        raw=gpt()
        self.mutate_entries(raw,lambda e:e.__setitem__(slice(0,16),uuid.UUID('5808c8aa-7e8f-42e0-85d2-e1e90434cfb3').bytes_le))
        with self.assertRaisesRegex(l.LayoutError,'UNKNOWN_TYPE'):self.planning(raw)

    def test_duplicate_guid_overlap_and_outside(self):
        raw=gpt();self.mutate_entries(raw,lambda e:e.__setitem__(slice(128,256),e[:128]))
        with self.assertRaisesRegex(l.LayoutError,'GUID_INVALID'):self.planning(raw)
        raw=gpt()
        def overlap(e):
            e[128:256]=e[:128];e[144:160]=uuid.uuid4().bytes_le
        self.mutate_entries(raw,overlap)
        with self.assertRaisesRegex(l.LayoutError,'OVERLAP'):self.planning(raw)
        raw=gpt();self.mutate_entries(raw,lambda e:struct.pack_into('<Q',e,40,127))
        with self.assertRaisesRegex(l.LayoutError,'RANGE_INVALID'):self.planning(raw)

    def test_unknown_revision_header_size_and_geometry(self):
        for field,val in ((8,0x20000),(12,96),(80,5000),(84,256)):
            raw=gpt();struct.pack_into('<I',raw,512+field,val);refresh_header(raw,512,512)
            with self.assertRaises(l.LayoutError):self.planning(raw)

    def test_mbr_basic_growth_is_zero_tail_only(self):
        raw=bytearray(128*512);raw[510:512]=b'\x55\xaa';raw[446]=0x80;raw[450]=7
        struct.pack_into('<II',raw,454,1,100)
        p=self.planning(raw);self.assertEqual(p['Layout'],'MBR');self.assertEqual(p['Patches'],[])
        out=apply(raw,p);self.assertEqual(out[:len(raw)],raw);self.assertEqual(out[len(raw):],bytes(64*512))

    def test_mbr_unknown_extended_dynamic_and_limit(self):
        for typ in (5,0xf,0x42,0x99):
            raw=bytearray(128*512);raw[510:512]=b'\x55\xaa';raw[450]=typ;struct.pack_into('<II',raw,454,1,100)
            with self.assertRaisesRegex(l.LayoutError,'UNKNOWN_TYPE'):self.planning(raw)
        raw[450]=7
        with self.assertRaisesRegex(l.LayoutError,'2TIB'):l.plan(len(raw),2**41+512,512,lambda o,n:bytes(raw[o:o+n]))

    def test_mbr_with_either_residual_gpt_signature_refused(self):
        for sector in (512,4096):
            for lba in (1,127):
                raw=bytearray(128*sector);raw[510:512]=b'\x55\xaa';raw[450]=7
                struct.pack_into('<II',raw,454,2,90)
                raw[lba*sector:lba*sector+8]=b'EFI PART'
                with self.subTest(sector=sector,lba=lba):
                    with self.assertRaisesRegex(l.LayoutError,'RESIDUAL_GPT'):
                        self.planning(raw,64,sector)

    def test_bad_sizes_short_reads_and_no_growth(self):
        raw=gpt()
        for source,target,sector in ((True,1024,512),(len(raw),len(raw),512),(len(raw),len(raw)+1,512),(len(raw),2**51,512),(len(raw),len(raw)*2,1024)):
            with self.assertRaises(l.LayoutError):l.plan(source,target,sector,lambda o,n:bytes(raw[o:o+n]))
        with self.assertRaisesRegex(l.LayoutError,'SHORT'):l.plan(len(raw),len(raw)*2,512,lambda o,n:b'')


if __name__=='__main__':unittest.main()
