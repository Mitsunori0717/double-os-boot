# Windows・一般OSのインストール状態を含むディスク保全

## 何を「丸ごと」保存するか

`offline_image.py acquire` はファイルの選択コピーではなく、識別した**物理ディスクの先頭から末尾まで全LBA**を保存します。GPT/MBR、EFI/システム予約、OS、回復パーティション、同じディスクにインストールされたアプリ・設定・ユーザーデータ、未使用領域も対象です。Windowsの再インストールやアプリの再構築を目的とした手順ではありません。既存の [取得→検証→VHDX→隔離VM](RECOVERY-PIPELINE.md) を使います。

ただし「ディスクにあるバイトを保存」と「別PCで元と同じように使える」は別です。別ディスクのアプリ/データ、NAS、クラウドの未ダウンロードファイル、外付け機器、TPM内の秘密、認証サーバー、USBドングル、ファームウェア設定はそのディスクのRAWに含まれません。これらを自動的に収集・移転したとは表示しません。

## 対応の境界

| 対象 | 全LBA保存 | 本実装での自動VMプロファイル |
|---|---|---|
| 単一ディスクのWindows、複数パーティション | Linux Liveでの既存安全条件を満たせば対象 | 対応OS・世代・暗号化・依存確認が合格した場合のみ |
| Windows 11 | 対象 | v2 の既知 build・UEFI/GPT・新 vTPM・移行先 CPU 確認等を満たす場合のみ。旧 TPM 秘密は再現しない |
| BitLocker / Device Encryption | 暗号化されたバイトをそのまま保全 | v2 は完全暗号化状態とキー別保管・ID 照合の申告がある場合に計画可能。本人による隔離ゲスト console 入力が必要。解除成功は未検証 |
| 複数ディスクにまたがるOS/アプリ/データ | 個別 raw の取得と整合した集合が必要 | v2 は最大8枚、全依存・同一静止期間・無書込の申告と集合 hash 結合が必要。未知/RAID/Spaces/スパンは拒否 |
| Linuxや他OS | 生ディスク保全自体はOS非依存 | Windows用評価器では拒否。既存Edge Box経路とは区別 |
| 4Kn | 既存取得の安全条件で保存可 | 現VHDX変換/VM経路は512-byte論理セクタのみ |
| RAID / Storage Spaces / 動的・スパン構成 | 完全性・依存関係未確認 | 自動対応としない |

「対応」は非破壊テスト済みのソフトウェア経路の範囲であり、Windows実機起動・全アプリ動作・認証成功の保証ではありません。Windows 10等を保存できることは、そのOSの保守期限や安全性を保証するものでもありません。

## 事前台帳と判断

`WindowsRecoveryInventory.psm1` は明示して呼び出した場合に限り、元Windowsのディスク/パーティション、OS・起動用ディスク、ファームウェア、Secure Boot、暗号化**状態**、高速スタートアップ/休止設定を読み取ります。不明・アクセス拒否は不明のままにします。回復キー、プロダクトキー、BitLocker保護者情報、TPMの鍵は取得しません。

`WindowsRecoveryPlan.psm1` は台帳・RAW manifest・作業者の別途確認証跡を照合して、保全とVM作成の適合性を分けて判定します。台帳を取得した時点ではWindowsが稼働中なので、その後の正常完全終了を証明できません。作業者の確認は自動的な実証ではなく、実取得時にはLinux Live側の静止・読取専用・別物理保存先の再検査も必要です。未知の値を安全とみなしません。

台帳とmanifestは機器識別情報を含むため、公開Gitや共有チャットへ貼らず、バックアップとともに権限制限した場所へ保管してください。ハッシュは改ざん防止署名ではありません。

## 正常完全終了と暗号化

Windowsの通常のシャットダウンは、高速スタートアップにより休止ファイルを使う場合があります。作業者が正常な完全終了を確認して専用Liveから起動し、元ディスクをマウントせずに取得します。休止ファイルの削除、NTFSの強制解除、電源断、BitLockerの無効化/保護中断、TPM clearを本システムは行いません。稼働中WindowsのRAW取得やVSSによるホットイメージは今回の経路ではありません。[Microsoft: 電源状態](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states)

BitLocker回復情報は本人が元PCとは独立した安全な場所に保管し、対象と一致することを確認してください。48桁回復パスワード、回復キーファイルや秘密はログ・manifest・Git・チャットに入力しないでください。別PC、TPM、UEFI/起動構成の変化で回復が要求されることがあります。暗号化ディスクのコピーだけで鍵が復元できるとは限りません。[Microsoft: BitLocker回復](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-process)

## 復旧・仮想化時の注意

- UEFI/GPTはGeneration 2、BIOS/MBRはGeneration 1の候補ですが、パーティション方式だけでOS互換を推測しません。元のSecure Boot状態を尊重し、失敗時に勝手に無効化しません。
- Windows 11 VM は Generation 2・Secure Boot・新 vTPM 等を要求します。v2 は対応条件を満たす入力から計画を生成しますが、旧 TPM 秘密の移行や実機起動の成功を保証しません。[Microsoft: Windows 11要件](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements)
- アーカイブを元PCにMount-VHDして検査しません。ディスク署名の変更でBCD参照と一致しなくなる場合があります。Disk2vhdはBitLocker有効ボリューム非対応で、選択ボリューム変換なので全LBA原本の代わりにしません。[Microsoft: Disk2vhd](https://learn.microsoft.com/en-us/sysinternals/downloads/disk2vhd)
- 起動ドライバ/ストレージコントローラー、BCD、UEFI NVRAM、TPM/EFS証明書、ドメイン・アプリ認証等は別評価が必要です。BCD修復やドライバ注入は原本に対して自動実行しません。
- ハードウェア変更でWindows/アプリの再認証が必要な場合があります。ライセンス移転可否は元契約によります。[Microsoft: ハードウェア変更後の再認証](https://support.microsoft.com/en-us/windows/activation/reactivating-windows-after-a-hardware-change)
- 新規VMは新しいID、未接続NIC、原本ではなく検証済み稼働用コピーで作成します。起動操作の完了はOS起動・アプリ動作成功を意味しません。
- **物理SSDへの書戻し機能は提供していません。** 本システムの実復旧経路はVHDXと新規隔離VMです。別PCへのベアメタル復旧は機種・媒体・起動条件を確認した別の手順が必要です。

## 必要容量と実機確認

全LBA RAWは使用量ではなくディスクの実バイト容量が必要です。約1TBの元ディスクならRAW保管のみ2TB、RAW・VHDX・稼働コピーを一緒に置くなら最悪時を見て4TBが目安です。外部データディスクがあれば別途加算してください。復旧先の空き容量・論理セクタ・CPU/RAM・OS対応を確認します。

非破壊テストはモック/通常ファイルのみに限定します。実PCの設定変更、停止、取得、復元、Windowsやアプリの起動確認は実施しません。

### 実行入口

- [Windows台帳の読取と項目](WINDOWS-INVENTORY.md)
- [適合判定・未確認の作業記録テンプレート・VMプロファイル作成](WINDOWS-PLAN.md)
- windows-recovery.ps1 は引数なしでは説明だけです。Inventory は現在PCの台帳を読み、Assess / Profile はJSONだけを処理します。既存出力を上書きせず、失敗時は空/途中ファイルを残します。Profile が拒否された場合は先に Assess の理由コードを確認してください。


### v2 計画の注意

[Windows 計画 v2](WINDOWS-PLAN.md#schemaversion-2-windows-11bitlocker複数ディスク) の作業者記録が必要です。正常な完全停止後、全依存ディスクを同一静止期間に無書込で取得したことを確認し、各 raw の取得時刻と集合ハッシュを結び付けます。これらは申告であり、プログラムが停止・整合性を実証したものではありません。元の TPM 秘密を要求する構成は拒否します。

回復キー本文は収集・JSON保存・コマンド引数渡し・ログ出力しません。回復キー ID の照合も手動申告です。本人が別保管したキーを隔離ゲストの console に入力し、その後の Windows/アプリ/データ/ライセンス確認を行います。実機変更・物理書戻しはこの計画生成に含まれません。
