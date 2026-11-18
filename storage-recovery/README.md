# Edge Box ストレージ保全・復旧

Windows・Edge Box の全領域バックアップ、物理 SSD への書戻し、別 PC の隔離 Hyper-V VM 復旧を扱います。現在の対応範囲は下表が基準です。Windows 用の PowerShell 補助関数と、Linux Live 用の物理書込みコマンドを区別してください。

| 工程 | 実装・条件 | 手順 |
|---|---|---|
| 構成収集 | PowerShell。ディスク、VM、Windows、暗号化状態を読取り専用で収集 | [Windows 台帳](WINDOWS-INVENTORY.md) |
| 全 LBA RAW 取得 | 非永続 Linux Live、root、未使用・kernel read-only の独立ディスク。512 / 4096 byte 論理セクタ | [オフライン取得](OFFLINE-IMAGER.md) |
| 複数媒体の保全 | 全 RAW・manifest の識別とハッシュ、順序、作業者が記録した静止期間を照合 | [バックアップセット](BACKUP-SET.md) |
| 物理 SSD へ書戻し | Linux Live の `restore_image.py`。既定は計画だけ。同容量・同セクタ、明示モードでは検証済み basic GPT / primary MBR の大容量先 | [物理復元](PHYSICAL-RESTORE.md) |
| RAW → VHDX | `convert_image.py` と別途用意した QEMU。512 byte 論理セクタのみ、論理内容比較あり | [VHDX 変換](VHDX-CONVERSION.md) |
| v1 隔離 VM | 単一ディスク・単一 NIC、Gen1 / Gen2、TPM 依存なし、元媒体と RAW ハッシュの照合 | [VM 復旧](RECOVERY-PIPELINE.md) |
| v2 隔離 VM | Gen2 / GPT / UEFI、最大 8 独立ディスク、単一 NIC。条件付きで Windows 11、新 vTPM、BitLocker の正規手動解除 | [Windows 評価](WINDOWS-PLAN.md) |

4Kn の保全・同セクタ物理復元は、4Kn VHDX 変換対応を意味しません。縮小復元、RAID / Storage Spaces / LVM / dynamic disk、故障媒体の救出、旧 TPM 秘密の複製、任意ハードウェアの完全再現は対象外です。大容量復元でもパーティション自体は拡張しません。

## 実行の区別

- `storage-recovery.ps1` の `PhysicalBackup` / `PhysicalRestore` は拒否を維持しています。Windows 稼働中の物理取得・書戻しは提供しません。
- `StorageRecovery.psm1` の `New-RestorePlan` は計画のみです。物理書込みは `restore_image.py restore` が担います。
- 物理復元は宛先全データを上書きします。対象識別、元媒体・保存媒体の除外、実行直前の再照合、確認トークン、対話確認を通過して初めて実行します。
- VM は `-Create` で新規作成し、`-StartIsolated` を追加したときだけ起動要求します。既存 VM を変更せず、保管原本から稼働コピーを作り、NIC をスイッチ未接続に保ちます。

## 検証と復旧成功

`partial → copied / written → verified` を区別します。短い I/O、flush 失敗、読み戻し不一致は成功になりません。`verified` は保存・変換・書戻しデータの一致であり、OS 起動やアプリ・ライセンス復旧の証明ではありません。Hyper-V が `Running` でも `BootTested` / `RestoreTested` / `LicenseValidated` は false のままです。

実 SSD 取得・書戻し、Live の実ブロックデバイス排他、Hyper-V ゲスト起動、FSBP・Windows の実動作・認証試験は未実施です。[今回の非破壊検証](../VALIDATION.md) と [実機受入手順](../docs/HARDWARE-ACCEPTANCE.md) を参照してください。

RAW、VHDX、稼働コピーを同時に保存する場合は元媒体合計容量の約 3 倍に加え、形式情報・空き予約・失敗時の partial を見積もります。暗号化キーと TPM 内部の秘密、NAS や別媒体だけにあるデータは単一 RAW から復元できません。

## この版への移行

旧 v1 プロファイルは、元台帳と RAW manifest から `New-RecoveryVmProfile` または `New-WindowsRecoveryVmProfile` で再生成してください。`SourceSerialNumber`、`SourceSize`、`SourceLogicalSectorSize` が必須となり、実行時に変換 manifest と照合します。手書きで検証済みフラグを追加しないでください。

VM 作成途中の失敗は VMRoot の `recovery-failure.json` と `recovery.events.jsonl` に記録します。残った VM・partial・コピーを確認してから、新しい VM 名・保存先で再試行します。自動削除・自動再開は行いません。

## 非破壊テスト

配布物のルートで実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-all.ps1
# qemu-img を用意して実変換も必須にする場合
$env:QEMU_IMG_TEST_EXE = 'C:\ApprovedTools\qemu-img.exe'
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-all.ps1 -RequireQemu
```

詳しい一連の流れは [RECOVERY-COMPLETION.md](RECOVERY-COMPLETION.md)、Clonezilla の別方式は [OFFLINE-RECOVERY.md](OFFLINE-RECOVERY.md) を参照してください。Clonezilla の圧縮セットと本ツールの RAW / manifest は互換形式ではありません。
