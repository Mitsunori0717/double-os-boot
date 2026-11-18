# Edge Box オフライン全領域イメージ取得

`offline_image.py acquire` は、Linux Live 環境で物理ディスクの先頭から末尾まで読み取り、未使用領域も含む単一RAWファイルに保存します。**生ディスクへ書き込む機能、マウント解除、ディスク設定変更、VM停止はありません。** 実機取得は未検証です。以下はSSDと保守停止を準備した後の実行方法であり、バックアップ済みという意味ではありません。

## 対応環境と事前条件

- Python 3.9以上、`lsblk` が利用できる、非永続型のDebian Live / Clonezilla Liveを想定します。
- root権限、カーネル起動引数 `boot=live`、`/run/live/medium`、overlay/squashfsのLiveルートが必要です。他のLive方式は推測で通さず拒否します。
- Windowsホストと対象FSBPを正常終了済みであること。休止、Saved、Pausedではなく完全停止します。Linux Liveで元VMを起動しません。ツールは検出したVMプロセスがある場合も拒否します。専用の保守Liveセッションを使い、自動マウントや他のディスクツールを並行稼働させないでください。
- ソースは識別できる物理ディスク全体のみ。モデル、シリアル、実バイト数、論理セクタを明示して照合します。シリアルが取得できないUSB変換器やマッピング方式は対象外です。
- **元ディスクと全パーティションのカーネル読取り専用状態が既に有効 (`ro=1`) であること。** 自動設定はせず、未設定・不明なら `SOURCE_WRITE_PROTECTION_REQUIRED` で拒否します。
- 元ディスクと全パーティションがマウントされていないこと。swap・holder等で利用中の場合は拒否します。自動解除や強制的な修復はしません。
- 保存先は**別の物理ディスク上の、マウント済みローカルext4/xfs/ntfs3領域**です。NAS、LVM、RAID、btrfs、多重マッピング、FAT/exFAT、ntfs-3g/FUSEは初版の対象外です。Windowsへ直接持ち込むSSDには、Linux側が対応する場合はNTFS3方式が候補です。ext4/xfsを選んだ場合、Windowsへ移す別経路が必要です。
- 元容量＋1GiB以上の空きを要求します。約1TBの元SSDには保存用2TB級を推奨します。SSDの初期化・フォーマットはこのツールでは行いません。

## 構成確認と実取得

まず、メーカーの保全・移行条件と正常停止を確認し、Live環境で対象を読み取り確認します。

```sh
lsblk --bytes --paths --output NAME,TYPE,SIZE,LOG-SEC,MODEL,SERIAL,WWN,MOUNTPOINTS
```

以下の値は**説明用プレースホルダー**です。実測値と交換してください。`/dev/sda`やWindowsのDisk 0を固定的に信用しません。

```sh
sudo python3 offline_image.py acquire \
  --source /dev/disk/by-id/REPLACE_WITH_VERIFIED_SOURCE \
  --destination /mnt/verified-backup-ssd \
  --name edgebox-YYYYMMDD \
  --expect-model 'EXACT MODEL' \
  --expect-serial 'EXACT SERIAL' \
  --expect-size 1000204886016 \
  --expect-sector-size 512
```

出力は `<name>.raw`、`<name>.raw.manifest.json`、`<name>.raw.events.jsonl`。途中は `.partial` が残り、失敗時は再利用・自動再開しません。原因確認後、別名で最初から取得します。元ディスクの読取りエラーをゼロ埋めしたり、不良セクタを黙ってスキップしたりしません。

### 読取り専用保護の準備は別途承認して行う

`O_EXCL` だけでは、排他を要求しない別の生デバイス書込みをすべて防げません。そのため本ツールは、ソース全体と各パーティションのsysfs `ro` が `1` であること、および開いたソースハンドルの `BLKROGET` が `1` であることを取得前後に確認します。保護フラグを変えるコードはありません。

運用担当者が対象と影響を確認して**別途承認を得た後**、専用Live環境でカーネル読取り専用保護を準備します。以下は手動作業の例で、ツールが実行するコマンドではありません。全対象の識別が完了するまで実行しないでください。

```sh
# 読取り確認。実測したソースと各パーティションで確認する。
sudo blockdev --getro /dev/VERIFIED_SOURCE
# 設定変更なので別途承認後にのみ、運用担当者が手動で実行する例。
sudo blockdev --setro /dev/VERIFIED_SOURCE
```

ソース全体だけの設定で全パーティションの観測値が `1` になるとは推測せず、各パーティションも確認します。必要な個別保護の準備は運用担当者が扱い、取得プログラムには回避フラグを設けません。既に開かれている書込みや不明な利用状態がある場合は、強制解除せず保守セッションをやり直します。ソースの保護を解除する操作や自動マウントを並行実行しないでください。

### 整合性保護

- ソースを `O_RDONLY | O_EXCL | O_NOFOLLOW` で開き、全取得・検証中に排他ハンドルを保持します。Linuxカーネルのブロック排他が取得できなければ拒否します。
- 開いたハンドルのmajor/minorと、ioctlの容量・論理セクタを照合します。取得前後にマウント・holder・識別情報を再確認します。
- ディスク全領域を正確なバイト数だけ保存し、flush/fsyncします。保存先を読み戻したSHA-256がコピー時と一致しなければ成功としません。
- 最終ファイル名は既存ファイルを置換しない方法で公開します。同名再実行・並行実行は拒否します。
- ログは工程、UTC時刻、処理済み/予定バイト、識別情報、例外、errnoを記録します。ディスク内容やライセンス秘密をログへ出しません。

**O_EXCLとカーネル読取り専用保護は同時利用を避ける補助であり、rootが保護を解除する操作やデバイス故障に対する保証ではありません。** Live実行中は他のディスク管理・仮想化処理を開始しない保守運用が必要です。ソースOSが正常終了したことを本ツールだけで証明できず、FSBPのDB整合性・暗号化キー・機器ライセンスは別確認です。

## 別PCのVMへ

RAWには物理SSDの全バイトが入りますが、Hyper-VのNIC/MAC・VM ID・起動順序などは別のホスト構成です。正しい構成台帳を別途保管してください。

生成manifestは `SchemaVersion=1`, `State=verified`, `Size`, `Sha256`, `Metadata.Source` を含みます。`Metadata.AcquisitionMode=offline-block` と `FullSectorImage=true` を記録します。`RestoreTested=false` のままで、別PC起動成功や認証成功を示しません。

RAWとmanifestは、後段の通常ファイル用RAW→VHDX変換ツールへ渡せます。元RAWは変更せず、変換後も内容を照合し、ネットワーク未接続の新規VMへ配置する経路を使用します。既存VMや元SSDを復元先にしません。

## 非破壊テスト専用モード

```powershell
python -B offline_image.py fixture-copy --source .\synthetic.bin --destination .\test-output --name fixture --sector-size 512
python -B -m unittest discover -s tests -p test_offline_image.py -v
```

fixture-copy は通常ファイル限定です。デバイス、UNC、symlink/reparse pointを拒否し、manifestに `fixture-file` / `fixture-only` を残します。これを実機取得の証拠にしないでください。

## 残る実機試験

実SSDの全量取得と所要時間、Live環境ごとの排他・NTFS3動作、USB切断、復元先VHDXのHyper-V起動、FSBPのデータ/認証、他PCの互換性は未検証です。暗号化/TPM依存やメーカー移行条件で復元できない場合があります。SHA-256は署名ではないため、RAWとmanifestを同時に改ざんされた場合の真正性は保証しません。

## 技術根拠

- Linuxのブロックデバイスに対する `O_EXCL` と利用中デバイスの `EBUSY`: [Linux man-pages open(2)](https://man7.org/linux/man-pages/man2/open.2.html)。本ツールは排他失敗を回避する再試行や強制解除をしません。
- NTFS3のカーネルドライバとmount種別: [Linux Kernel NTFS3 documentation](https://www.kernel.org/doc/html/latest/filesystems/ntfs3.html)。Live環境のドライバ対応は実機検証が必要です。

- 読取り専用状態の確認／設定は [util-linux blockdev(8)](https://man7.org/linux/man-pages/man8/blockdev.8.html)、`BLKROGET` の定義は [Linux UAPI fs.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/fs.h) を参照。本ツールはGETのみを使用し、SETは使用しません。
