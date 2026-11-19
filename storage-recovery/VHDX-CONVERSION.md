# raw イメージから検証済み VHDX を作る

`convert_image.py` は `offline_image.py` で取得・読み戻し検査済みの **通常 raw ファイル**を、別 PC の Hyper-V で利用する独立 VHDX に変換します。物理ディスク・既存 VM・ネットワーク設定は操作しません。

## 用意するもの

- Python 3（標準ライブラリのみ）。
- 信頼できる配布元の `qemu-img`。このツールは自動ダウンロードやインストールをしません。[QEMU 公式ダウンロード案内](https://www.qemu.org/download/)または OS の公式パッケージを使い、配布元・署名/ハッシュを確認してください。Windows 実機には今回インストールしていません。
- `disk.raw` と `disk.raw.manifest.json`。manifest は秘密鍵署名ではなく整合性台帳です。原本を別保管し、第三者から渡された manifest の自己申告だけを信頼しないでください。
- 新しい出力名と、raw 全容量に加えて 1GiB または 1% の大きい方以上の空き。raw を保存したまま VHDX を作る場合は両方分が必要です。1TB SSD の raw と最悪ケースの VHDX を同じ2TB媒体に同居させる容量は保証されません。保存用と復旧作業用を分けるか4TB以上を検討してください。

```powershell
python .\convert_image.py --raw 'E:\Backup\edgebox.raw' --output 'F:\Recovery\edgebox.vhdx' --qemu-img 'C:\Program Files\qemu\qemu-img.exe'
```

Linux でも同じ引数を使用できます。入力ファイルにカーネルの read lease を取得できないファイルシステムや権限では中断します。Windows は入力を「他の読取りのみ許可」で開き、書込み・削除との競合を拒否します。VM が使用するファイルや変換中に書き換わるファイルは使わないでください。

`fixture-file` 取得物は通常拒否します。合成試験の場合だけ `--allow-fixture` を追加します。テストを許可しても `BootTested` / `RestoreTested` は true になりません。

## 検証すること

1. raw の manifest、元識別情報、全バイト長、SHA-256、論理セクタ512を確認。
2. 新しい専用一時ディレクトリ内へ dynamic VHDX を生成。既存出力を上書きしない。
3. `qemu-img info` で仮想サイズの厳密一致と独立VHDXを確認。
4. `qemu-img check` を修復オプションなしで実行。
5. 生成されたVHDXの両領域テーブルと論理セクタmetadataを読み、512バイトを確認。
6. `qemu-img compare` で raw と VHDX の**仮想ディスク内容**を比較。形式が異なるファイル自体のハッシュ同値は要求しない。
7. 元 raw の長さ・更新時刻・同一性・SHA-256を再確認。VHDXを読み戻してSHA-256を取得。
8. 成功した場合だけ final VHDX と manifest を新規公開する。

[QEMU 公式コマンド資料](https://www.qemu.org/docs/master/tools/qemu-img.html)に基づき、force-share、salvage、repair、既存ディスクへの変換は使用しません。512以外の論理セクタ、差分/親ディスク、UNC・再解析ポイント・デバイスパスは拒否します。

## 出力と障害時

- `edgebox.vhdx`：検証済み独立コンテナー
- `edgebox.vhdx.manifest.json`：コンテナーハッシュ、元rawハッシュ、仮想サイズ、検査結果、QEMU版と実行ファイルハッシュ
- `edgebox.vhdx.events.jsonl`：工程、時刻、終了コード、標準出力/エラー末尾、例外
- `edgebox.vhdx.conversion.lock`：同じ出力名の再実行・二重開始を防ぐ実行記録。成功後も保持
- `.edgebox-convert-*`：中断時の未完成ファイル。自動削除・自動再開しない

失敗時は元 raw を保持し、ログを確認して新しい出力名でやり直します。プロセス強制終了時に最終ログが残らない場合も、final manifest がない成果物を成功扱いにしません。データが破損しているのに修復して続行する機能はありません。

## 次の段階

この結果は「仮想ディスク内容の一致」です。別PCでのブート、Edge Box認証、MAC/VM識別子、TPM/暗号化キー、機器互換は別の検証です。元イメージを保存したまま、新規のネットワーク隔離VMへ復旧用コピーを接続してください。Edge Boxのライセンス移行を回避する機能はありません。

## 非破壊検証の実績

- Windows：mock QEMU＋通常ファイル試験、入力への書込みがWindowsの共有制御で拒否されることを確認。
- Cloud Linux：公式Debian qemu-utils 10.0.13を一時フォルダーへ展開し、通常の合成rawファイルで実際の convert / info / check / compare を実行。4KiB、1MiB+512、16MiBの厳密サイズと内容一致を確認し、2MiBの完全パイプラインも検証。
- 本物のストレージ、Edge Box、Hyper-V VM起動、Windows版QEMUによる実変換は未検証です。
