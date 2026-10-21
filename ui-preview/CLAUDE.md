# Claude: Edge Box の UI デザインを編集するための入口

このフォルダを渡されたら、[README.md](README.md) と [AGENTS.md](AGENTS.md) を先に読んでください。プレビューの編集から GitHub 本体への統合までを引き継げるように構成されています。

## 先に理解すること

これは Web サイトではなく、Windows PowerShell 5.1 + Windows Forms のネイティブ UI です。HTML/CSS への置き換えは必要ありません。`start.cmd` が一覧、`preview.ps1` が各画面への入口です。各プレビューは本体を実行せず、サンプルだけを使います。

`cpu/cpu-ui-theme.ps1` は本体と同じ C# 描画部品です。C# 5 / Windows PowerShell 5.1 の Add-Type でコンパイル可能な書き方を保ってください。CPU の配置、小画面、監視の描画は cpu/*-layout.ps1 / monitor-drawing.ps1、ホストの設定 UI は host/views/*.view.ps1 を編集します。

`cpu/preview-cpu.ps1` と `host/preview-host.ps1` はサンプル供給と安全な操作を担当します。ここだけを変えても本体のデザインには反映されません。manifest の designFile にあるファイルを編集してください。共通テーマだけではホスト画面の色は変わりません。

## 本体へ戻す方法

- source.json に元の GitHub リポジトリと基準コミットがあります。manifest に本体のファイル、元のハッシュ、置換する範囲があります。
- 完成したら最新の Git クローンを用意し、`integrate.ps1 -TargetRoot <clone>` → `integrate.ps1 -TargetRoot <clone> -Apply` の順で取り込みます。先に全対象を照合し、競合や PowerShell 構文エラーがあれば書き込み前に止まります。
- 統合前後で範囲外の機能を保持します。特に、管理者判定・VM の操作・CPU 割り当て・検査・レジストリ・資格情報の保存を変更しません。
- UI も更新済みでツールが停止した場合、ハッシュを上書きして強制適用しないでください。基準コミットの元ソースと最新を比較してデザインを移し直します。
- verify.ps1 と本体の setup/tests/run-tests.ps1 を通し、通常の commit / push と PR を作成します。既定ブランチの最新との競合を確認してから、確認待ちにせず **merge commit で自動マージ**します。

依頼が「デザインを調整」だけならプレビューで反復し、「統合」「完成したらマージ」も含まれていれば GitHub への反映まで完了させます。実機の稼働フォルダへ直接デザインを適用する必要はありません。
