# Edge Box の CPU 画面プレビュー

このフォルダだけで Windows PowerShell 5.1 の標準 WinForms を使って起動できます。管理者権限、Hyper-V、Edge Box のインストール、追加ツールは不要です。親フォルダの `start.cmd` では、全画面を 1 つのウィンドウで切り替えて確認できます。

```powershell
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\preview-cpu.ps1 -Screen Console
```

`-Screen` には次を指定できます。

| 指定 | 表示する画面 |
|---|---|
| `Console` | Core Split / Settings |
| `Monitor` | CPU・メモリの監視 |
| `Apps` | アプリの割り当て。追加ボタンから下記の選択画面も開けます |
| `CoreChooser` | アプリのコア選択 |
| `Processes` | 実行中のアプリ選択 |
| `InstalledApps` | インストール済みアプリ選択 |

データはすべて固定のサンプルです。コアやメモリの操作はプレビュー内だけで動きます。適用・保存・解除ボタンから実機の設定、VM、タスク、アプリの実行状態を変更することはありません。実行中・インストール済みの一覧も実機から取得しません。実際のファイルを選ぶボタンはプレビューでは無効です。プレビューを閉じると操作内容は破棄されます。

## AI で編集するファイル

| ファイル | 調整する内容 |
|---|---|
| `cpu-ui-theme.ps1` | 共通の配色、文字、ボタン、タイル、カード、入力部品など |
| `console-layout.ps1` | コンソールの各画面、配置、幅、高さ、余白 |
| `monitor-drawing.ps1` | 監視グラフの描画、配置、凡例 |
| `monitor-layout.ps1` | 監視ウィンドウ、上部バー、入力部品 |
| `apps-layout.ps1` | アプリの割り当て画面 |
| `core-chooser-layout.ps1` | アプリのコア選択画面 |
| `process-picker-layout.ps1` | 実行中アプリの選択画面 |
| `installed-app-picker-layout.ps1` | インストール済みアプリの選択画面 |

これらは本番 UI から抽出したデザイン部分です。将来の統合に使う本番の変数・関数・コントロールの名前と、既存のイベント接続は維持してください。テーマ内の C# は Windows PowerShell 5.1 でコンパイルできる C# 5 の文法を使います。日本語を含む `.ps1` は UTF-8 BOM 付きで保存します。デザインを変えたら PowerShell を起動し直してください。既存プロセスでコンパイル済みの C# は読み直せません。

`preview-cpu.ps1` はサンプルデータ・安全な代替処理・確認用の起動処理です。`manifest.json` は統合先と元データのハッシュを記録しています。この 2 ファイルは通常のデザイン調整では編集しません。本番の処理をプレビューへ追加しないでください。

プレビューでは表示名を「Edge Box」にしています。既存の VM 名、タスク名、ファイル名、クラス名はそのままです。

## 動作確認

```powershell
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\preview-cpu.ps1 -Screen Console -SmokeTest
powershell -NoProfile -Sta -ExecutionPolicy Bypass -File .\preview-cpu.ps1 -Screen Monitor -SmokeTest -ScreenshotDirectory "$env:TEMP\EdgeBoxPreview"
```

`-SmokeTest` は画面を画面外で描画して自動で閉じます。Console では全 5 ページとコアのクリックを確認します。任意の `-ScreenshotDirectory` を指定した場合だけ PNG をその場所に保存します。実機の再起動や VM の終了は行いません。その他の画面も `-Screen` を変えて確認できます。

## 最後に本番へ統合する

親フォルダの統合手順を使ってください。`manifest.json` は元のソースと対応する範囲を記録しています。テーマはファイル全体、レイアウトは開始・終了マーカーの間だけを統合します。VM・CPU・メモリの適用、プロセスの固定、アプリの設定保存、監視の実測を行う処理は統合対象に含めていません。

本番側が更新されて元の範囲のハッシュが変わった場合は、その差分を確認してからデザインを合わせ直します。プレビューを開くだけで本番へ統合されることはありません。
