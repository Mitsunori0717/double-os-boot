# Offline physical SSD restore (experimental, hardware not validated)

`restore_image.py` restores every LBA from a verified production `offline_image.py`
image to a DIFFERENT physical SSD. This is destructive, not an in-place repair.
No physical restore has been executed during development. Synthetic 512-byte and
4096-byte tests do not prove actual controller, firmware, power-loss or OS boot behavior.

## Safety boundary

- Boot a dedicated, nonpersistent Debian/Clonezilla Live environment as root. No
  running VM, automounter, disk utility, other root writer or concurrent restore.
  This program never stops VMs, unmounts filesystems or changes read-only flags.
- Keep the original SSD disconnected when possible. Its recorded serial/unique
  identity is forbidden as a restore target. Connect only the replacement SSD,
  Live boot medium and image/log storage where practical.
- The operator must identify exact target model, serial, unique ID, byte capacity,
  logical sector size and Linux major:minor. Disk order/path alone is insufficient.
  WWN is used where present; otherwise the acquisition tool's explicit
  `serial:<model>:<serial>` fallback is used. Empty/ambiguous identities fail closed.
- Target must be an unmounted whole physical disk, without holders or swap usage.
  Live boot, mounted partitions, image/manifest/log-containing disks are protected.
  Plain ext4/xfs/ntfs3 local image/log storage only; mapped/network storage unknown
  means refusal. Other mount namespaces or privileged concurrent writers are NOT
  excluded by Linux O_EXCL/flock: dedicated exclusive offline operation is required.
- RAID, Storage Spaces, Windows dynamic disks and multi-disk source dependencies
  are unsupported. Active mapped/holder topology is rejected; dormant proprietary
  metadata inside an image is NOT automatically identified by this release. Do not
  use a source whose basic single-physical-disk layout cannot be established.
  Execution additionally requires `--basic-single-disk-image-confirmed`: an
  operator attestation, NOT an automatic detection result. A whole-disk image can
  still be one member of a multi-disk installation. Before affirming this flag,
  separately assess all required boot/app/data disks and their recovery order.
  This API restores exactly one image to one SSD; it does not orchestrate a set or
  prove that the restored SSD alone contains a complete runnable system.
- Default mode requires exact target capacity and matching logical sector size.
  512 and 4096 logical sectors are supported without conversion. A larger SSD
  requires explicit `--larger-target-layout` on BOTH plan and restore. Only validated
  canonical basic GPT or primary-only basic MBR is accepted. No partition resizing
  or arbitrary GPT repair is performed; see the transformation section below.
  Smaller SSDs and logical-sector changes always fail. Check actual byte capacity
  and logical sector size before purchasing; marketed GB alone is insufficient.
- Only verified, full-sector, write-protected offline-block acquisition manifests
  are accepted. Fixture, partial or modified images are rejected. SHA-256 protects
  integrity, not authenticity: a maliciously replaced image+manifest is not signed.
- Source image AND manifest are retained under the existing kernel read-lease
  mechanism (`convert_image.locked_source`) throughout the operation. Lease
  unavailability, a lease-break notification, or loss of the read lease fails
  closed. Filesystems without Linux leases cannot be used even if otherwise
  readable; copying the backup to a supported local filesystem is a separate
  operator step. Target has exclusive open and cooperative flock.
  Identity and geometry are checked again immediately before writes and after
  readback. Root can override these conditions; this is not hostile-root protection.

## Plan, then explicitly confirm

Use `python3 restore_image.py --help`. All arguments must be actual observed values.
The plan performs image hashing and read-only inventory; it does NOT open target
for write. Example placeholders deliberately require replacement:

```sh
python3 restore_image.py plan \
  --image /mnt/backup/machine.raw \
  --manifest /mnt/backup/machine.raw.manifest.json \
  --target /dev/disk/by-id/REPLACEMENT-SSD \
  --log-directory /mnt/backup --name restore-UNIQUE-RUN \
  --expect-serial REPLACEMENT-SERIAL --expect-model 'EXACT MODEL' \
  --expect-unique-id EXACT-WWN --expect-device 8:16 \
  --expect-size EXACT-BYTE-COUNT --expect-sector-size 512
```

After reviewing every target field and securing any existing target data, repeat
with action `restore`, the same parameters, `--confirm-erase-token TOKEN_FROM_PLAN`
and both `--offline-exclusive-ownership` and `--basic-single-disk-image-confirmed`.
  Do not provide the latter for unknown source layout or unassessed disk-set
  dependencies. A fresh interactive terminal confirmation is
MANDATORY: type `ERASE <serial> <byte-count> <target-hash-first-16>` exactly after the
full target and permanent data-loss warning. Piped/noninteractive confirmation is
rejected. The token is identity binding, not authorization by itself. If anything
changes, obtain a new plan. Never add automatic approval around this prompt.

The program creates a NEW `<name>.restore.events.jsonl` and refuses an existing
run name. States: preflight, partial, written, verified, failed. Progress records
include target, image digest, expected/written bytes and phase. Readback follows
fsync and Linux BLKFLSBUF target cache invalidation; cache flush failure is fatal.
`verified` means bytes read back matched, NOT that the OS booted or license worked.
It does not write a boot-tested claim or alter the source acquisition manifest.

Any failure after writing begins leaves the replacement potentially unusable.
A write exception may have changed bytes beyond the last recorded count. Stop,
preserve logs and inspect; do not boot or retry automatically. Resume is unsupported.
Loss of the logging disk or a flush error aborts the process. Power failure can
leave partial writes without a final event. Underlying device volatile caches and
firmware honesty still limit power-loss guarantees.

After success, shut down Live by the normal operator procedure and test the
replacement in an isolated environment. Do not attach original and clone to the
same production system/network: filesystem IDs, machine identities, MAC-bound
licenses and services may conflict. Hardware drivers, BitLocker/TPM, Secure Boot,
application data outside the source disk, and licensing remain separate issues.

## Tests (no physical device I/O)

```powershell
python -B -m unittest discover -s storage-recovery/tests -p test_restore_image.py
```

Tests use memory streams, temporary ordinary files, synthetic manifests and mocks.
They cover all bytes including zero/unused sectors, 512/4Kn, source corruption,
short I/O, flush/readback failure, protected source/image disks, exact geometry,
identity change, confirmation binding, and incomplete-write reporting. Linux
exclusive opens/ioctls/Live topology and real physical boot recovery remain untested.

References: Linux open(2) O_EXCL block-device semantics:
https://man7.org/linux/man-pages/man2/open.2.html
Linux block ioctl definitions:
https://github.com/torvalds/linux/blob/master/include/uapi/linux/fs.h

## Explicit larger-target transformation

`--larger-target-layout` is separate from default byte-identical restore. Its plan
validates the leased source layout before opening any target for write. Hybrid,
corrupt/noncanonical GPT, unsupported partition types, extended/logical MBR,
LDM/dynamic/Spaces/RAID/LVM layouts detected by the parser are refused. Dormant
proprietary metadata not represented by those partition types remains outside
automatic detection; operator layout/set attestation is still mandatory.

The expected target is constructed as source bytes + a completely zeroed added
tail, with only the planner's bounded changes:

- GPT: update protective MBR range and primary header; relocate backup partition
  entries/header to the target's real end; erase obsolete backup metadata; update
  affected header CRCs. Disk GUID, partition GUIDs and partition ranges stay intact.
- MBR: keep source bytes unchanged and zero the extra tail. Primary partitions
  remain exactly their original size; only basic primary layouts up to 2 TiB are
  accepted. No filesystem extension, conversion or boot repair.

All target bytes, including the new tail, are written and read back. Plan/logs keep
`ImageSha256` (unchanged input raw image), `TargetSha256` (transformed expected whole
SSD), layout mode and each patch offset/length/digest. Confirmation token and the
interactive erase text bind the expected TARGET hash. Source files are not edited.

Computing the expected target hash reads the source and hashes the zero tail;
plan time therefore scales with target size. Restore additionally writes and reads
back the entire target. A large SSD does not make its extra capacity available to
existing partitions automatically. Partition expansion is a separate operation,
not performed here. Hardware testing and OS boot testing remain outstanding.
