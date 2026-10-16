# 新しい PC への導入

`build-installer.cmd` をダブルクリックすると `EdgeBox-Setup.exe` ができます。
Windows 標準の .NET Framework で自己展開 EXE を作ります。起動時に UAC が出ます。

新しい PC に EXE をコピーし、「管理者として実行」してください。
`C:\EdgeBox` に一式を配置して、一括セットアップを起動します。
セットアップは現在の状態を確認し、未完了の手順だけを実行します。
必要なディスク・LAN の選択と自動サインインのパスワード入力以外は自動で進み、必要時には通常の方法で再起動します。

一括の `setup-all.cmd` と、`setup` 内の番号別バッチを両方同梱します。
失敗時は `C:\EdgeBox\setup\logs\日時-実行ID\summary.txt` に原因・対処法・再実行するバッチが出ます。
既存の設定やログは配布物に含めず、既存 PC の更新時も端末固有の設定は残します。
同梱対象は `windows-host`、`windows-cpu-partition`、`setup` のソースと説明書、およびルートの起動・更新バッチです。

ZIP だけを作って渡す場合は次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\build-installer.ps1 -ZipOnly
```

生成された `installer\EdgeBox-Setup.zip` を新しい PC のローカルディスクへ展開して `setup-all.cmd` を実行します。
ZIP と EXE の中のセットアップ一式は同じです。
配布物には別 PC の設定・進捗・ログ・資格情報・取得済み実行ファイルを含めません。

導入条件・番号一覧・再実行・ログについては [../setup/README.md](../setup/README.md)。
FSBP が入った Edge Box の物理ディスクが別途必要です。FSBP 自体の導入やメーカー固有のアプリ設定は自動化しません。

配置先を変える場合は、EXE と同じ payload.zip がある場所から `install.ps1 -InstallDir "D:\EdgeBox"` を実行できます。