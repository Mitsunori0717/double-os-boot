# 新しい PC への導入

`build-installer.cmd` をダブルクリックすると `EdgeBox-Setup.exe` ができます。
Windows 標準の .NET Framework で自己展開 EXE を作ります。起動時に UAC が出ます。

新しい PC に EXE をコピーし、「管理者として実行」してください。
`C:\EdgeBox` に一式を配置して、一括セットアップを起動します。
セットアップは現在の状態を確認し、未完了の手順だけを実行します。
必要なディスク・LAN の選択と自動サインインのパスワード入力以外は自動で進み、再起動が必要な場合は保守担当者の手動操作を待ちます。

一括の `setup-all.cmd` と、`setup` 内の番号別バッチを両方同梱します。
失敗時は `C:\EdgeBox\setup\logs\日時-実行ID\summary.txt` に原因・対処法・再実行するバッチが出ます。
既存の設定やログは配布物に含めず、既存 PC の更新時も端末固有の設定は残します。
同梱対象は `package-files.txt` に列挙された全ソースです。`windows-host`、`windows-cpu-partition`、`setup`、`storage-recovery`、`installer`、説明書、検証スクリプト、配布ビルダー、必要なフォント・ライセンス・アイコン、ルートの起動バッチとリリース情報を含みます。元リポジトリの既定ブランチでこの改修版を置き換えないよう、ルートの更新スクリプトは同梱しません。

既存の出力 ZIP / EXE は上書きしません。作り直す場合は `-OutFile` で別の名前を指定してください。ビルド時と配置時の両方で必須依存ファイルを検査します。

ZIP だけを作って渡す場合は次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1 -ZipOnly
```

生成された `installer\EdgeBox-Setup.zip` を新しい PC のローカルディスクへ展開して `setup-all.cmd` を実行します。
ZIP と EXE の中のセットアップ一式は同じです。
配布物には別 PC の設定・進捗・ログ・資格情報・取得済み実行ファイルを含めません。

`payload-manifest.json` に各ファイルの長さと SHA-256 を記録します。EXE の配置処理は全項目の名前・重複・必須ファイル・ハッシュ・配置先を検証してから書き込みます。配置先のジャンクションなどの再解析ポイント、ZIP 内のリンクやドライブ外参照は拒否します。この台帳は破損確認用で、発行者を保証する電子署名ではありません。

端末固有の `setup/settings.json`、`windows-host/field-disk.identity.json`、旧形式の `field-disk.conf`、表示・CPU設定やログは配布対象外のため、再配置でも保持します。UAC の拒否・起動失敗は終了コード `1`、セットアップの結果は元の終了コード（正常 `0`、要再起動 `3010` など）を返します。配置途中のI/O障害では一部のソースが更新済みになる可能性があるため、原因を解消して同じ配布物で再実行してください。

導入条件・番号一覧・再実行・ログについては [../setup/README.md](../setup/README.md)。
Edge Box のシステムを導入済みの物理ディスクが別途必要です。Edge Box 自体の導入やメーカー固有のアプリ設定は自動化しません。

配置先を変える場合は、`install.ps1` と `package-safety.psm1` がある場所から `install.ps1 -PayloadPath "D:\配布\EdgeBox-Setup.zip" -InstallDir "D:\EdgeBox"` を実行できます。

開発用の非破壊検証は `powershell -NoProfile -ExecutionPolicy Bypass -File installer/tests/run-tests.ps1` です。一時ファイルとプロセス・UAC のmockを使い、実際の導入・VM操作・再起動は行いません。
