"""Pure conservative GPT/MBR expansion planner. No files or devices are opened.

The executor must copy source bytes and zero ALL target bytes beyond source_size
before applying these patches, then verify the complete transformed destination.
This plan does not resize partitions, repair BCD, or establish bootability.
"""
import struct
import uuid
import zlib


class LayoutError(ValueError):
    pass


def need(ok, code):
    if not ok:
        raise LayoutError(code)


def crc(data):
    return zlib.crc32(data) & 0xffffffff


# Only standalone basic partition types whose locations can remain unchanged.
GPT_TYPES = {
    'c12a7328-f81f-11d2-ba4b-00a0c93ec93b',  # EFI system
    'e3c9e316-0b5c-4db8-817d-f92df00215ae',  # Microsoft reserved
    'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7',  # Microsoft basic data
    'de94bba4-06d1-4d40-a16a-bfd50179d6ac',  # Windows recovery
    '0fc63daf-8483-4772-8e79-3d69d8477de4',  # Linux filesystem
    '0657fd6d-a4ab-43c4-84e5-0933c84b4f4f',  # Linux swap
    '21686148-6449-6e6f-744e-656564454649',  # BIOS boot
}
MBR_TYPES = {0x07, 0x0b, 0x0c, 0x0e, 0x06, 0x83, 0x82, 0xef, 0x27}


def plan(source_size, target_size, sector_size, read_at):
    """Return copy/zero geometry and byte patches; read_at(offset,length) is pure input.

    Only canonical basic GPT and primary-only MBR are supported. Unknown layout,
    hybrid MBR, dynamic disks, RAID/LVM/Spaces GUIDs and noncanonical GPT refuse.
    read_at must read an immutable, already verified image, not a live disk.
    """
    need(type(source_size) is int and type(target_size) is int and type(sector_size) is int,
         'INTEGER_GEOMETRY_REQUIRED')
    need(sector_size in (512, 4096) and source_size > 0 and target_size > source_size and target_size <= 2**50
         and source_size % sector_size == 0 and target_size % sector_size == 0,
         'LARGER_ALIGNED_TARGET_REQUIRED')
    source_lbas, target_lbas = source_size // sector_size, target_size // sector_size
    need(6 <= source_lbas < target_lbas <= 2**64-1, 'LBA_RANGE_INVALID')

    def read(offset, length):
        need(0 <= offset and 0 < length <= 16*1024*1024 and offset+length <= source_size,
             'READ_RANGE_INVALID')
        data = read_at(offset, length)
        need(isinstance(data, bytes) and len(data) == length, 'SHORT_OR_INVALID_READ')
        return data

    mbr = read(0, sector_size)
    need(mbr[510:512] == b'\x55\xaa', 'MBR_SIGNATURE_INVALID')
    records = [mbr[446+i*16:462+i*16] for i in range(4)]
    populated = [x for x in records if any(x)]
    need(populated, 'EMPTY_LAYOUT_UNSUPPORTED')
    patches = []
    result = dict(SchemaVersion=1, SourceSize=source_size, TargetSize=target_size,
        LogicalSectorSize=sector_size, CopySourceBytes=source_size,
        ZeroTailOffset=source_size, ZeroTailLength=target_size-source_size,
        PartitionsResized=False, BootTested=False, RequiresVerifiedImmutableImage=True,
        RequiresExplicitTransformApproval=True, Patches=patches)

    if not any(x[4] == 0xee for x in populated):
        need(read(sector_size, 8) != b'EFI PART' and
             read((source_lbas-1)*sector_size, 8) != b'EFI PART',
             'MBR_WITH_RESIDUAL_GPT_REFUSED')
        need(source_size <= 2**41 and target_size <= 2**41, 'MBR_2TIB_LIMIT')
        parts = []
        active = 0
        for entry in populated:
            need(entry[0] in (0, 0x80) and entry[4] in MBR_TYPES, 'MBR_NONBASIC_OR_UNKNOWN_TYPE')
            active += entry[0] == 0x80
            start, count = struct.unpack_from('<II', entry, 8)
            need(start >= 1 and count > 0 and start+count <= source_lbas, 'MBR_PARTITION_RANGE_INVALID')
            parts.append((start,start+count-1))
        need(active <= 1, 'MBR_MULTIPLE_ACTIVE')
        parts.sort()
        need(all(parts[i-1][1] < parts[i][0] for i in range(1,len(parts))), 'PARTITION_OVERLAP')
        result.update(Layout='MBR', PartitionCount=len(parts), NewUnallocatedBytes=target_size-source_size)
        return result

    need(len(populated) == 1 and records[0] == populated[0] and populated[0][4] == 0xee,
         'HYBRID_OR_NONCANONICAL_PROTECTIVE_MBR')
    pmbr = populated[0]
    need(pmbr[0] == 0 and struct.unpack_from('<I',pmbr,8)[0] == 1 and
         struct.unpack_from('<I',pmbr,12)[0] == min(source_lbas-1,0xffffffff), 'PROTECTIVE_MBR_RANGE_INVALID')

    def header(data, current, alternate):
        need(data[:8] == b'EFI PART', 'GPT_SIGNATURE_INVALID')
        rev, size, expected, reserved = struct.unpack_from('<IIII',data,8)
        need(rev == 0x10000 and size == 92 and reserved == 0 and not any(data[92:]), 'GPT_HEADER_UNSUPPORTED')
        check=bytearray(data[:92]);struct.pack_into('<I',check,16,0)
        need(crc(check) == expected, 'GPT_HEADER_CRC_INVALID')
        here, other, first, last = struct.unpack_from('<QQQQ',data,24)
        need(here == current and other == alternate, 'GPT_HEADER_LOCATION_INVALID')
        guid=data[56:72]
        need(any(guid), 'GPT_DISK_GUID_ZERO')
        entries, count, stride, entries_crc=struct.unpack_from('<QIII',data,72)
        need(stride == 128 and 128 <= count <= 4096, 'GPT_ENTRY_GEOMETRY_UNSUPPORTED')
        blocks=(count*stride+sector_size-1)//sector_size
        return dict(first=first,last=last,guid=guid,entries=entries,count=count,stride=stride,
                    entries_crc=entries_crc,blocks=blocks)

    primary=read(sector_size,sector_size)
    backup=read((source_lbas-1)*sector_size,sector_size)
    a=header(primary,1,source_lbas-1);b=header(backup,source_lbas-1,1)
    need(all(a[k] == b[k] for k in ('first','last','guid','count','stride','entries_crc','blocks')),
         'GPT_HEADERS_DISAGREE')
    blocks=a['blocks']
    need(a['entries'] == 2 and b['entries'] == source_lbas-1-blocks,
         'GPT_ENTRY_LOCATION_NONCANONICAL')
    need(2+blocks <= a['first'] <= a['last'] < b['entries'], 'GPT_USABLE_RANGE_INVALID')
    entries=read(a['entries']*sector_size,blocks*sector_size)
    backup_entries=read(b['entries']*sector_size,blocks*sector_size)
    need(entries == backup_entries, 'GPT_ENTRY_COPIES_DISAGREE')
    need(crc(entries[:a['count']*128]) == a['entries_crc'], 'GPT_ENTRIES_CRC_INVALID')
    need(not any(entries[a['count']*128:]), 'GPT_ENTRY_PADDING_NONZERO')
    parts=[]; guids=set()
    for index in range(a['count']):
        entry=entries[index*128:(index+1)*128]
        if not any(entry[:16]):
            need(not any(entry), 'GPT_UNUSED_ENTRY_NONZERO')
            continue
        need(str(uuid.UUID(bytes_le=entry[:16])) in GPT_TYPES, 'GPT_NONBASIC_OR_UNKNOWN_TYPE')
        guid=entry[16:32]
        need(any(guid) and guid not in guids, 'GPT_PARTITION_GUID_INVALID')
        guids.add(guid)
        start,end=struct.unpack_from('<QQ',entry,32)
        need(a['first'] <= start <= end <= a['last'], 'GPT_PARTITION_RANGE_INVALID')
        parts.append((start,end))
    need(parts, 'EMPTY_LAYOUT_UNSUPPORTED')
    parts.sort()
    need(all(parts[i-1][1] < parts[i][0] for i in range(1,len(parts))), 'PARTITION_OVERLAP')
    new_entries=target_lbas-1-blocks
    new_last=new_entries-1
    need(new_last >= a['last'], 'GPT_TARGET_GEOMETRY_INVALID')

    def updated(original, current, alternate, entry_lba):
        out=bytearray(original)
        struct.pack_into('<QQ',out,24,current,alternate)
        struct.pack_into('<Q',out,48,new_last)
        struct.pack_into('<Q',out,72,entry_lba)
        struct.pack_into('<I',out,16,0)
        struct.pack_into('<I',out,16,crc(out[:92]))
        return bytes(out)

    protective=bytearray(mbr)
    struct.pack_into('<I',protective,446+12,min(target_lbas-1,0xffffffff))
    patches.extend([
        dict(Offset=0,Data=bytes(protective),Purpose='protective-mbr-range'),
        dict(Offset=sector_size,Data=updated(primary,1,target_lbas-1,2),Purpose='primary-gpt-header'),
        dict(Offset=b['entries']*sector_size,Data=b'\0'*(min(blocks+1,new_entries-b['entries'])*sector_size),Purpose='erase-old-backup-gpt'),
        dict(Offset=new_entries*sector_size,Data=entries,Purpose='relocated-backup-entries'),
        dict(Offset=(target_lbas-1)*sector_size,Data=updated(backup,target_lbas-1,1,new_entries),Purpose='relocated-backup-header'),
    ])
    # Old backup erase stops where the relocated backup begins, so patches never overlap.
    result.update(Layout='GPT',PartitionCount=len(parts),OldBackupHeaderLba=source_lbas-1,
        NewBackupHeaderLba=target_lbas-1,NewLastUsableLba=new_last,
        DiskGuidPreserved=True,PartitionEntriesPreserved=True)
    return result
