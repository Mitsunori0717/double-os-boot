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
- 実Hyper-Vの新規VM作成/起動、ゲストOS起動、FSBP画面/機能/認証
- 別PCのUEFI/デバイス互換、TPM/暗号化鍵/メーカーのライセンス移行
- 不良セクタがある故障媒体の救出、複数ディスク/NIC、RAID/LVM、4Kn変換

元SSD、既存VM、MAC、ネットワーク接続、ブート設定を変更していません。開発テストは通常ファイルとmockだけです。実機復旧成功の代わりにはなりません。

## 一般Windows拡張の追加検証

- Windows台帳: 66 assertions（全OS問い合わせをmock、現PC台帳は取得せず）
- Windows適合判定/プロファイル: 105 assertions
- 台帳→判定→Hyper-V profile schema・CLI: 66 assertions
- 既存128/90/40 assertions、Python53件中51合格・2skip、setup回帰も再実行して合格

暗号化状態だけの問い合わせ、秘密の余剰フィールド/例外非漏洩、UEFI/BIOSとディスク依存、enumのJSON往復、partition範囲、unknown拒否、Windows11/BitLockerと保全可否の分離、誤った作業者記録、CLI既存出力保護を試験しました。新Windows collectorはモック検証であり、実Windows PCのWMI/BitLocker/firmware応答は未検証です。全LBA取得・復元・Windows/インストール済みアプリの起動は実施していません。前段のCloud QEMU結果はPR #94時点の同一変換器の試験記録であり、今回はCloud試験を再実行していません。
