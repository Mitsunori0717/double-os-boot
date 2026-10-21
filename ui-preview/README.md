# Edge Box UI デザインプレビュー

このフォルダだけを持ち出し、Claude などの AI でデザインを編集して Windows 上で確認できます。Windows PowerShell 5.1 / .NET Framework / Windows Forms を使うため、追加のパッケージや管理者権限は不要です。

## ダウンロードして開く

1. GitHub の **Code → Download ZIP** から取得して展開します。
2. `ui-preview` フォルダを好きな作業場所へコピーします。このフォルダだけで動きます。
3. `start.cmd` をダブルクリックします。

全画面を 1 つのウィンドウで表示します。左の一覧をクリックするか、`Ctrl+PgUp` / `Ctrl+PgDn` で画面がすぐに切り替わります。上部に、その画面の編集ファイルを表示します。

- プレビューのファイル (`.ps1` / `.json`) を保存すると、同じ画面・同じ位置のまま自動で開き直します。手動では `F5` か「開き直す」ボタンです。
- 編集ミスで画面を表示できない時は、プレビュー内かコンソールにエラーを表示します。直して保存すれば自動で開き直します。
- CPU 割り当て (メイン画面) はウィンドウいっぱいに広がります。ウィンドウの大きさを変えて、リサイズ時の見え方も確認できます。
- タイトルバーや実際のウィンドウの大きさを見る時は「別ウィンドウで開く」を押します。
- 黒いコンソールのウィンドウを閉じると、プレビューも終了します。

## プレビューを最新版にする

`update.cmd` をダブルクリックすると、GitHub の最新の `ui-preview` だけを取得してこのフォルダへ上書きします。内容が変わるファイルは、上書き前に `backups\<日時>\` へ保存します。手元で編集したデザインはそこから取り戻せます。GitHub に無いファイルは消しません。

- `update.cmd -Check` (または `update-preview.ps1 -Check`) は、更新される内容の確認だけを行います。
- ZIP の取得が遮断される環境では、自動で 1 ファイルずつの取得に切り替えます。
- 非公開リポジトリの場合は、GitHub のトークンを 1 行だけ書いた `update-token.txt` をこのフォルダか 1 つ上のフォルダに置きます。このファイルはコミットしません。
- プレビューを開いたまま更新した場合は、自動で開き直します。

`export-preview.ps1` を実行すれば、このフォルダだけの ZIP も作成できます。既定の出力先は Windows の一時フォルダ内の `EdgeBox-UI-Preview.zip` です。

## 対象画面と編集ファイル

| 画面 | 編集するファイル | 本体の取り込み先 |
|---|---|---|
| CPU の共通配色・フォント・ボタン・カード・ダイアログ | `cpu/cpu-ui-theme.ps1` | `windows-cpu-partition/cpu-ui-theme.ps1` |
| CPU 割り当ての HOME / SETTING (左メニューのアプリ名・MONITOR を含む) | `cpu/console-layout.ps1` | `windows-cpu-partition/cpu-console.ps1` の画面組み立て部分 |
| 監視のグラフ・負荷 | `cpu/monitor-drawing.ps1`、`cpu/monitor-layout.ps1` | `windows-cpu-partition/cpu-monitor.ps1` の描画・配置部分 |
| アプリ割り当て・コア選択・起動中アプリ・インストール済みアプリ選択 | `cpu/apps-layout.ps1`、`cpu/core-chooser-layout.ps1`、`cpu/process-picker-layout.ps1`、`cpu/installed-app-picker-layout.ps1` | `windows-cpu-partition/cpu-console.ps1` の各ダイアログ |
| 左右モニター・全画面・解像度 | `host/views/display.view.ps1` | `windows-host/03-field-display-kiosk.ps1` の設定画面 |
| 自動サインイン | `host/views/auto-logon-main.view.ps1`、`host/views/auto-logon-actions.view.ps1` | `windows-host/06-auto-logon.ps1` の設定画面 |
| 設定アイコンから開くサインイン画面 | `host/views/settings.view.ps1` | `windows-host/08-settings-console.ps1` の設定画面 |

起動・CPU 分割・監視の実測・設定保存・レジストリ操作はプレビューへ取り込んでいません。VM、CPU、メモリ、アプリ、アカウント、ログは固定サンプルです。保存・適用を押しても実機には反映されません。アプリの実ファイルを選ぶボタンはプレビューでは無効です。

プレビュー専用の表示ウィンドウ (`preview.ps1` / `viewer.ps1`)、更新コマンド、サンプル供給コードは本体へ取り込みません。本体のセットアップはコマンド形式のため、GUI のプレビュー対象は上記です。CPU 共通テーマはホスト設定画面には自動で伝わらないため、統一する場合は `host/views` の配色も編集します。

## Claude に渡す指示

最初に [CLAUDE.md](CLAUDE.md) と [AGENTS.md](AGENTS.md) を読ませてください。例えば次の依頼で始められます。

> このフォルダの CLAUDE.md と AGENTS.md を読み、Edge Box のすべての設定画面のデザインを調整してください。最初はプレビュー内だけで編集し、処理・設定キー・識別子は維持してください。完成後は GitHub の最新ソースへデザインを統合し、検証して PR をマージコミットで自動マージしてください。

デザインの要望や画像をこの依頼へ追加できます。取り込みに必要な元リポジトリ、基準コミット、対応範囲、検証コマンドはこのフォルダに保存してあります。

## プレビューの検証

このフォルダだけで全画面とサンプル操作を検証できます。

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\verify.ps1
```

スクリーンショットも保存する場合:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\verify.ps1 -ScreenshotDirectory "$env:TEMP\EdgeBox-UI-Screenshots"
```

最初に表示する画面は `preview.ps1 -Screen Monitor` のように指定できます (`Console`、`Monitor`、`Apps`、`CoreChooser`、`Processes`、`InstalledApps`、`Display`、`AutoLogon`、`Settings`)。単独のウィンドウで開く場合は `cpu/preview-cpu.ps1 -Screen <画面>` か `host/preview-host.ps1 -Screen <画面>` を実行します。`verify.ps1` は 1 つのウィンドウで全画面を順に切り替える検証 (`viewer.ps1 -SelfTest`) も行います。

## 完成後に本体へ取り込む

GitHub リポジトリは [Mitsunori0717/double-os-boot](https://github.com/Mitsunori0717/double-os-boot)。作成時の取得先と既定ブランチは `claude/windows-linux-dual-boot-lwgj28` です。取り込み時に `update.ps1` と GitHub の既定ブランチを再確認してください。

最新のリポジトリを Git クローンし、作業ブランチを作ってから、編集したプレビューフォルダで実行します。`C:\work\double-os-boot` はクローン先の例です。

```powershell
# 変更予定を確認するだけ
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrate.ps1 -TargetRoot C:\work\double-os-boot

# 確認できたデザインをソースへ取り込む
powershell -NoProfile -ExecutionPolicy Bypass -File .\integrate.ps1 -TargetRoot C:\work\double-os-boot -Apply
```

取り込みは `cpu/manifest.json` と `host/manifest.json` の対応範囲だけを書き換えます。対応範囲の外の設定処理・検査・保存処理は保持します。元の UI が別の修正で変わっていた場合は停止します。ハッシュを書き換えて回避せず、最新ソースと比較してデザインを調整してください。元の UI が同じなら、ファイル内の別の処理が更新されていても取り込めます。

取り込み後は `git diff` でデザインだけの差分であることを確認し、クローン側で次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File setup\tests\run-tests.ps1
```

その後は通常の commit / push、PR 作成を行い、既定ブランチの最新を再取得して競合が無いことを確認してから **merge commit** で自動マージします。競合を直した場合は再検証します。force push はしません。編集したプレビューフォルダのソースも同じ PR に含め、次の調整へ引き継いでください。
