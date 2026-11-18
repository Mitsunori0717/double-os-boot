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
