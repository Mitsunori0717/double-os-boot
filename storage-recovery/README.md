# Edge Box ストレージ保全・別PC VM復旧

## 入口

**[OS全領域バックアップ → VHDX → 隔離Hyper-V VMの手順](RECOVERY-PIPELINE.md)** に、実際に使用できるコマンドと確認事項をまとめています。

| 工程 | 実装 | 安全な既定 |
|---|---|---|
| 元構成の収集 | `storage-recovery.ps1 -Action Inventory` | 読取りのみ。権限/情報不足は不完全と表示 |
| 全LBA RAW取得 | `offline_image.py acquire` | 非永続Linux Live・root・未使用の識別済みディスクのみ。ソースは読取り専用/排他 |
| RAW→VHDX | `convert_image.py` | 既存通常ファイルのみ。新規出力、原本保持、論理内容比較 |
| VMプロファイル | `New-RecoveryVmProfile` | 元ディスク/RAW hash照合、未知の判断は未確認のまま拒否 |
| 別PCのVM構築 | `restore-vm.ps1` | 計画のみ。`-Create`明示で新規隔離VM、`-StartIsolated`明示で初回起動 |

**実SSDの取得・Hyper-V実起動・FSBP復旧/認証の実機試験は未実施です。** ソフトウェアのファイル試験やVM操作のmock試験を、実機成功に読み替えません。実際の操作前には正常停止の保守時間、対象/保存先、管理者権限、メーカーの復元/ライセンス条件を確認してください。

この実装は、既存VMや物理ディスクへの復元書込、ディスク初期化、MAC変更、VM停止、ネットワーク接続を自動で行いません。明示して新規作成するVMだけを設定し、NICをスイッチ未接続に保ちます。

## 重要な制限

- Disk番号やWindowsのOfflineだけを信頼しません。識別情報、mount/VM利用、容量、論理セクタを検査します。
- 全領域取得はLinux Live専用。Windows稼働中の物理ディスク取得は提供しません。
- 変換/VM経路は512-byte論理セクタ、単一ディスク/単一NICが初版の範囲。4Kn、RAID/LVM、差分VHDX、複数媒体、vTPM必須/不明は別評価または拒否します。
- Hyper-V VM IDは新しくなります。元IDが必須なら進めません。MAC保持だけでライセンス認証が通るとは限りません。
- ハッシュ/manifestは電子署名ではありません。原本と台帳を別に保護してください。
- RAW、変換VHDX、稼働コピーを同じ場所に置く場合は三つ分の最悪容量を見積もります。約1TB元媒体なら、RAW1世代保存用は2TB、三つをまとめるなら4TBが安全側の目安です。

## 詳細手順

- [Linux Live全領域取得](OFFLINE-IMAGER.md)
- [QEMUによるVHDX変換と検証](VHDX-CONVERSION.md)
- [一連の復旧と隔離VM](RECOVERY-PIPELINE.md)
- [Clonezillaの別方式・公式媒体検証](OFFLINE-RECOVERY.md)

Clonezillaの`device-image/savedisk`はディスク全体を復元対象にできますが、対応FSの使用中ブロック中心に保存する方式です。未使用領域を含む全LBA RAW取得とは区別してください。Clonezillaの複数圧縮ファイル形式と、本モジュールの通常ファイル/manifest形式は互換ではありません。

## 補助PowerShellモジュール

`StorageRecovery.psm1`は、構成収集、事前安全判定、通常イメージファイルのコピー/読み戻し検査、物理復元の**計画だけ**を提供します。物理書込関数はありません。`Allowed=true`は計画条件の確認であり、実行や復旧成功ではありません。

`storage-recovery.ps1`のWindows版`PhysicalBackup`/`PhysicalRestore`アクションは引き続き拒否されます。実取得はLinux Live専用コマンドを使用します。`CopyImage`は独自manifest付きの既存通常ファイルだけを扱います。

```powershell
# 読取り専用
.\storage-recovery.ps1 -Action Inventory
# 通常ファイル+独自manifestの整合検査
.\storage-recovery.ps1 -Action Verify -ImagePath 'E:\Backup\edgebox.raw'
# 新しい別名に複製。既存宛先や途中ファイルを上書きしません。
.\storage-recovery.ps1 -Action CopyImage -ImagePath 'E:\Backup\edgebox.raw' -DestinationPath 'F:\Backup\edgebox-copy.raw'
```

`Write-ImageFromStream`は下位の通常ストリーム用処理で、物理ディスクを開きません。fixture入力を実機バックアップの証拠にはできません。`New-RestorePlan`は元SSD、ホストOS、画像保存先、VM接続先、容量/セクタ不一致を拒否しますが、物理書込はしません。

## 状態とログ

`partial → copied → verified`を区別し、短い読取り、I/O/flush失敗、読み戻し不一致を成功にしません。中断物を自動再開・上書きしません。エラーログには工程、処理/予定バイト、例外/OSコードを含め、秘密やディスク内容を入れません。

`verified`は保存/変換データの整合性であり、復旧起動成功ではありません。VMが`Running`でも`BootTested`、`RestoreTested`、`LicenseValidated`はfalseのままです。隔離した実機で確認して初めて評価できます。

## 非破壊テスト

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1

# 個別実行:
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-hyperv-recovery.ps1
python -B -m unittest discover -s tests -p 'test_*.py' -v
```

PowerShellのHyper-V試験は全操作をmock化し、実コマンド呼出しを禁止します。Pythonは通常ファイルとmockを使用し、実ディスクを触りません。QEMUを用いた合成RAWの実変換試験はクラウドの一時ファイルのみで別途実施しました。実機/Live起動/停電やUSB故障/FSBPライセンス確認はこれらに含みません。

## Windows・一般OSのインストール状態を含む保存

[対応範囲、Windows事前台帳、暗号化・休止・複数ディスクと復旧制限](GENERAL-OS-RECOVERY.md) を参照してください。
