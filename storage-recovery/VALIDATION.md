# 元ソース時点の検証履歴

この文書は元コミット dcc9718 の試験記録です。改修版の最新結果は [ルートの VALIDATION.md](../VALIDATION.md) を参照してください。過去の Cloud 試験を今回の再実施として扱いません。

# 非破壊検証結果（2026-11-18）

## 実施済み

| 検証 | 結果 |
|---|---|
| Windows PowerShell 5.1 基盤 | 128 assertions 合格 |
| 隔離VMフロー（Hyper-V完全mock） | 90 assertions 合格 |
| Hyper-Vコマンド配線（native commands完全mock） | 40 assertions 合格 |
| Windows Python: オフライン取得 | 28 unittest 合格 |
| Windows Python: VHDX変換 | 25件中23合格、2 skip |
| Cloud Linux Python: VHDX変換 | 25件中24合格、1 skip |
| 既存setup回帰検証 | 全合格 |
| Git差分 whitespace検査 | 合格 |

Windowsでskipした実QEMU変換とsymlink検査はCloudで合格。CloudでskipしたWindows共有ロック試験はWindowsで合格しました。QEMU 10.0.13 (Debian 1:10.0.13+ds-0+deb13u1) を公式Debianパッケージのハッシュ確認後にクラウド一時領域へ展開して使用しました。ユーザーPCにQEMUをインストールしていません。

実QEMUでは通常の合成RAWだけを扱い、convert/info/check/compare、仮想容量、VHDXの512-byte論理セクタメタデータ、読み戻しSHA-256を確認しました。4KiB、1MiB+512、16MiBの追加容量試験と、2MiBの一連の変換も実施しました。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File storage-recovery\tests\run-all.ps1
```

独立安全レビューの指摘により、source write protection必須、対象指紋照合、復元先の実在/状態照合、MAC/VM ID/TPMの未保証表示、fixtureから実運用への誤昇格拒否、原本を起動に使わない処理を強化しています。

## 未実施・保証しないもの

- 実SSDの全量取得、実Live環境でのkernel read-only/排他、NTFS3書込・USB抜去・停電
- Windows版QEMUの実変換（ロック自体はWindows上で試験済み）
- 実Hyper-Vの新規VM作成/起動、ゲストOS起動、Edge Box 画面/機能/認証
- 別PCのUEFI/デバイス互換、TPM/暗号化鍵/メーカーのライセンス移行
- 不良セクタがある故障媒体の救出、複数ディスク/NIC、RAID/LVM、4Kn変換

元SSD、既存VM、MAC、ネットワーク接続、ブート設定を変更していません。開発テストは通常ファイルとmockだけです。実機復旧成功の代わりにはなりません。

## 一般Windows拡張の追加検証

- Windows台帳: 66 assertions（全OS問い合わせをmock、現PC台帳は取得せず）
- Windows適合判定/プロファイル: 105 assertions
- 台帳→判定→Hyper-V profile schema・CLI: 66 assertions
- 既存128/90/40 assertions、Python53件中51合格・2skip、setup回帰も再実行して合格

暗号化状態だけの問い合わせ、秘密の余剰フィールド/例外非漏洩、UEFI/BIOSとディスク依存、enumのJSON往復、partition範囲、unknown拒否、Windows11/BitLockerと保全可否の分離、誤った作業者記録、CLI既存出力保護を試験しました。新Windows collectorはモック検証であり、実Windows PCのWMI/BitLocker/firmware応答は未検証です。全LBA取得・復元・Windows/インストール済みアプリの起動は実施していません。前段のCloud QEMU結果はPR #94時点の同一変換器の試験記録であり、今回はCloud試験を再実行していません。


## 復旧機能拡張版の検証（2026-11-18）

storage-recovery/tests/run-all.ps1 の最終結果:
- 既存PowerShell: 128 / 90 / 40 / 66 / 105 / 66 assertions 合格。
- v2隔離Hyper-V: 50 assertions 合格。
- v2 Windows評価・profile: 213 assertions 合格（前準備として旧105も再実行）。
- Python: 108 tests中106合格、2 skip。実QEMU未設定とWindows symlink権限不足によるskipで、合格扱いにはしていません。
- setup全回帰合格。

新しい物理復元はファイル/メモリstreamとモックで全LBA、512/4Kn、短いI/O、書込・flush・readback失敗、宛先誤選択、image/manifest改変、同一媒体、mount、確認不足、lease失敗を検証しました。Linux Liveの実ブロックデバイス操作は未実施です。

複数diskセットは依存全点、順序、hash、時刻窓、重複、fixture混入、秘密フィールド、既存出力保護を検証。正常停止・同時静止はoperator attestationであり自動証明ではありません。

v2 VMは新規VMのみの新local protector/vTPM、全VHDX先行検証と稼働copy、全disk接続、SecureBoot/CPU/memory/隔離readback、TPM失敗時にStartしないことをmockで検証。Windows11・BitLocker・複数diskのprofileを含みます。旧TPM秘密の移植、実Win11起動、BitLocker実解除、実アプリ動作、ライセンスは未実施・未保証です。

開発中は実物理SSDへの読書き、既存VMの変更、ホストセキュリティ設定の変更を行っていません。CLI/ドキュメントは実運用の最終確認を省略させません。以前の未対応記述は旧版の試験記録であり、新版の対応範囲はRECOVERY-COMPLETION.mdと各v2手順を参照してください。

大容量復元も追加検証済み: 512/4KnのGPTを最小1セクタおよび追加64セクタへ適応し、partition内容不変更、両header/array CRC、末尾backup移設、ゼロtail、全target期待SHAと読戻しを検証。MBRはGPT痕跡/hybrid/extended/dynamic/未知を拒否。これは合成ディスクbytesの検証であり実媒体試験ではありません。


## Linux通常ファイルによるクロス環境検証

実装commit 7aeaac71d652f63c7318e7a3c271bac920746d3bを別Linux環境へcloneしてSHA一致を確認。Python 3.12.14で同じ108 testsを実行し、106成功・2skip・失敗0でした。skipは未導入のQEMUとWindows専用sharing試験です。Linux kernel read leaseは通常の一時ファイルで実機能を検証しました。全テストを読んで物理デバイス入口がmockまたは拒否であることを確認してから実行し、実/dev/block・VMを操作していません。

大容量GPT/MBR経路を含む独立read-only安全レビューも合格。指摘された入力画像の排他、複数ディスクの静止期間、MBR上のGPT痕跡の拒否を修正して再検証しました。
