# Edge Box セットアップ・ストレージ復旧

Windows 上の Edge Box 環境を構築するセットアップと、全領域バックアップから物理ディスクまたは隔離 Hyper-V VM に復旧するツールです。バージョンは `2026.11.19.2`。元ソースのコミットと実機検証の状態は [release.json](release.json) に記録しています。

## 最初に開くもの

| 目的 | 入口 |
|---|---|
| 新しい Windows PC に Edge Box を構築 | [導入手順](docs/FRESH-INSTALL.md)、`setup-all.cmd` |
| データ収集中の自動再起動を禁止 | 管理者で手順 12 を実行。Windows Update、システム障害、サービス回復、再起動タスクの適用結果は手順 12 の状態表示で確認 |
| Edge Box を終了し、Windows を手動で終了・再起動 | デスクトップの「全部シャットダウン」 |
| Windows の終了に時間がかかった理由を確認 | Windows PowerShell で「windows-host/shutdown-diagnostics.ps1」を実行。管理者で実行するとサービス別の記録も参照可能 |
| 現在のセットアップ状態だけを確認 | `setup/check-status.cmd` |
| OS・アプリ・データを全領域バックアップ | [復旧機能の対応表](storage-recovery/README.md) |
| RAW から交換 SSD へ復元 | [物理復元](storage-recovery/PHYSICAL-RESTORE.md) |
| RAW から別 PC の隔離 VM を作成 | [VM 復旧手順](storage-recovery/RECOVERY-PIPELINE.md) |
| 開発用の非破壊テスト | `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-all.ps1` |

セットアップは実際の Windows 設定を変更します。開発テストは通常ファイルと模擬コマンドを使います。`verified` は保存データの整合性を示し、OS 起動、アプリ動作、ライセンスの復旧成功を示しません。

## 必要な環境

- セットアップ・VM 復旧: Windows PowerShell 5.1、Hyper-V を利用できる Windows、実行時の管理者権限。セットアップでは Windows 11 Pro / Enterprise / Education、Edge Box 導入済みの物理ディスクを前提とします。
- RAW 取得・物理復元: 専用の非永続 Linux Live、Python 3.10 以上、root、対象の独立した basic ディスク。取得元は kernel read-only が必要です。
- RAW → VHDX: Windows または Linux、Python 3.10 以上、別途入手した信頼できる `qemu-img`。Python の追加パッケージは不要です。
- CPU 完全分離: 対応する CPU 構成と Hyper-V CPU groups。必要な Microsoft 製ツールは実セットアップ時に署名を確認して取得します。利用できない機種で成功扱いにはしません。

## この配布物について

添付されていた 55 ファイルは、[元リポジトリ](https://github.com/Mitsunori0717/double-os-boot/tree/dcc9718ee6ea66675da0b5e3bf9c6142dd0995e1) の同一コミットの Git blob と全件一致を確認しました。欠落していた `windows-host`、`windows-cpu-partition`、配布用 `installer` を同じ版から補完し、対象識別・異常時停止・復旧検証・配布検証を修正しています。詳細は [変更内容](CHANGELOG.md) を参照してください。

この配布物にはセットアップ・復旧に必要なソース、テスト、説明書を収録します。ZIP 版の更新は新しい配布 ZIP 全体を展開して行います。端末固有の設定・ログ・回復キー・RAW・VHDX・取得ツールは含めません。リポジトリ配置で使用する既存の更新スクリプトはリポジトリ側に残しています。

## 配布 ZIP の作成と検証

`package-files.txt` が同梱ファイルの明示リストです。必須実装の不足、既存出力、シンボリックリンク・再解析ポイントは拒否します。

```powershell
python -B tools/package.py build --output '..\EdgeBox-Recovery-2026.11.19.2-source.zip'
python -B tools/package.py verify '..\EdgeBox-Recovery-2026.11.19.2-source.zip'
```

ZIP 内の `package-manifest.json` には全同梱ファイルのサイズと SHA-256 が入ります。これは破損・取り違えの検出用で、電子署名ではありません。実行用 EXE の作成は [installer/README.md](installer/README.md) を参照してください。

## 検証範囲

[今回の検証記録](VALIDATION.md) と [実機受入手順](docs/HARDWARE-ACCEPTANCE.md) を参照してください。実 SSD への書戻し、Hyper-V ゲスト起動、Edge Box 機能・認証の試験は未実施です。予備媒体での受入結果を確認してから運用へ進めます。

## リポジトリにある独立ツール

元プロジェクトの [UI デザインプレビュー](https://github.com/Mitsunori0717/double-os-boot/tree/claude/windows-linux-dual-boot-lwgj28/ui-preview) と [Windows アプリ整理](https://github.com/Mitsunori0717/double-os-boot/tree/claude/windows-linux-dual-boot-lwgj28/windows-app-manager) は、引き続き独立ツールとしてリポジトリに残しています。セットアップ・復旧の配布 ZIP には含めません。
