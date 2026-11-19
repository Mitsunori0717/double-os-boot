# 改修版の検証記録

対象: `2026.11.19.1`、Windows PowerShell 5.1、Python 3.12。ユーザー指定により CI は判定に使用せず、ローカル検証を実施しました。実ディスク・稼働 VM・ホスト設定の変更を伴う試験は実施していません。

## 今回実施した検証

| 対象 | 内容 |
|---|---|
| 元ソース | 添付 55 ファイルの Git blob が元コミットと全件一致 |
| Python 全体 | 153 tests（復旧 129、配布・runner 22、追加 QEMU 2）。151 成功、2 skip（Windows のシンボリックリンク作成権限、Linux 専用ログ交換試験） |
| PowerShell | 復旧 8、セットアップ 1、ホスト起動・修復・CPU 3、配布 1 の計 13 スイート。通常ファイルと mock で検証 |
| Hyper-V 配線 | 実 cmdlet のパラメータ契約をメタデータで確認。VM 操作なし |
| セットアップ | 本物の判定関数、ID 不一致、依存不足、再開処理、ディスク照会失敗、作成途中失敗・後処理を mock 検証 |
| 起動入口 | 他 VM 使用拒否、作成拒否後の停止、Status 無変更、実子プロセスの引数・終了コードを検証 |
| 配布 | 必須実装・資産、既存出力保護、設定除外、ZIP パス・ハッシュを検証 |
| QEMU 実変換 | 4 KiB、1 MiB + 512 bytes、17 MiB の合成 RAW。変換・検査・論理内容比較を実施 |

追加の QEMU 統合試験では、`offline_image.py fixture-copy` → `convert_image.py` → QEMU で RAW 再出力まで CLI で実行し、元データと全量 SHA-256 が一致しました。1 MiB + 512 bytes と 17 MiB の 2 試験は、最終端と複数コピー単位の境界に異なるデータを置いて確認しています。

使用した QEMU は `11.1.0 (v11.1.0-12130-ge470268ff4)` です。[QEMU 公式の Windows 配布案内](https://www.qemu.org/download/#windows) から参照される [配布元](https://qemu.weilnetz.de/w64/) の `qemu-w64-setup-20260811.exe` を公開 SHA-512 と照合し、テスト用フォルダーへ必要な実行ファイルと DLL を展開しました。インストーラーを実行したり、システムへ QEMU を登録したりしていません。これらのバイナリは配布物へ含めません。

インストールされている Microsoft 製 CpuGroups.exe の署名が Windows PowerShell 5.1 の検証を通ることも確認しました。CPU グループ設定の試験には模擬 VM を使用しました。リポジトリ側のアプリ整理ツールの 12 テストスクリプトと、UI プレビューの画面表示試験とデザイン取り込みの統合テストもローカルで実施しました。

## 再現方法

```powershell
$env:QEMU_IMG_TEST_EXE = 'C:\ApprovedTools\qemu-img.exe'
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-all.ps1 -RequireQemu
```

QEMU を準備していない場合は環境変数と `-RequireQemu` を省略できます。その場合、実変換試験は skip として記録されます。`validation-results` の新しい実行フォルダーに各ログと `results.json` が残ります。テストの skip は成功に数えません。

## 未実施

- Linux Live の実ブロックデバイスに対する排他・read-only・取得・書戻し、停電や USB 障害。
- Hyper-V VM の実作成・起動、Windows 11 の起動、BitLocker の実解除。
- FSBP 機能、機器接続、メーカーのライセンス・認証移行。
- 実機の自動ログオン・CPU 完全分離・再起動後の表示と再開。

これらは [実機受入手順](docs/HARDWARE-ACCEPTANCE.md) で別に確認します。元ソースの過去の Cloud/Linux 記録は [履歴](storage-recovery/VALIDATION.md) に残していますが、改修後の Linux 実行結果ではありません。
