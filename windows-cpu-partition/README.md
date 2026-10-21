# windows-cpu-partition — Windows 用 CPU コア分割ツール (別口・独立)

Windows と Hyper-V Edge Box の間で **CPU コアを分割し、両者の処理が混ざらないように固定**する
独立ツールです。GUI の設定コンソール (`cpu-console.ps1`)、リアルタイム監視 (`cpu-monitor.ps1`)、
その実体 (`cpu-partition.ps1` / `cpu-apps.ps1`) の構成です。
2 つの画面の見た目 (配色・部品) は `cpu-ui-theme.ps1` にまとめています (設定や割り当ての処理は持ちません)。
**Windows 側のアプリを特定のコアに固定する機能**も同じ画面から設定できます。

**このフォルダは他の構成から独立しています。** `windows-host/` とはファイルも設定も共有しません
(Edge Box を起動するときだけ、`windows-host` 側が「固定してから起動する」ためにこのツールを呼びます)。
どの Hyper-V の登録にも使えます (対象は `-VMName` で指定。既定は `EdgeBox`。名前が実在しなければ
Edge Box のディスクを持つ登録を自動で見つけます)。

## 標準の割り当てと保証 (i7-14700: P コア 8 + E コア 12 の場合)

```
 論理CPU:  0 ... 15 | 16 17 18 19 | 20 21 22 23 24 25 26 27
           P0 .. P7 | E0 E1 E2 E3 | E4 E5 E6 E7 E8 E9 E10 E11
           └─ Windows (P コア 8 + E コア 4 = 20 スレッド) ─┘ └── Edge Box (E コア 8) ──┘
```

| 決まり | 内容 |
|---|---|
| 方式 | 既定は **full (完全分割)**。runtime に切り替えることもできる |
| Edge Box | **E コア専用**。末尾の E コアを最低 8 個。増やすことはできる (再起動が必要) が、P コアは割り当てられない |
| Windows | 残り全部 (P コア 8 + E コア 4)。『アプリの割り当て』で、この 12 コアの中からアプリごとに個別指定できる |
| 保証 | full では **Windows は CPU 20-27 に載れず、Edge Box は CPU 0-19 に載れない** (双方向とも構造的) |
| 確認 | 『Edge Box 監視』で、Windows 用の区画に緑 (Edge Box)、Edge Box 用の区画に青 (Windows) が載らない (使用率が赤くならない) |

## 仕組み (なぜ「不可能」ではないのか)

Windows クライアント版の Hyper-V には、コア固定の GUI も PowerShell コマンドもありません。
しかし土台のハイパーバイザーと OS には、次の機構が備わっています。

| 機構 | 何をするか | Linux での対応物 |
|---|---|---|
| **minroot** (`bcdedit hypervisorrootproc`) | ハイパーバイザー起動時に、**Windows 自体を先頭 N 個の論理 CPU に封じ込める**。Windows のプロセスも割り込みも残りのコアには一切載らなくなる | `isolcpus` |
| **CPU グループ** (Microsoft 製 `CpuGroups.exe`) | Edge Box を指定した論理 CPU 集合に固定する (ハイパーバイザー内部の HCS インターフェース) | libvirt の `<vcpupin>` |
| **root スケジューラの実体** (runtime 用) | クライアント版の既定では、Edge Box の CPU は `vmmem` という Windows のプロセスのスレッドとして動く。そのプロセスにコア固定 (アフィニティ) を掛ければ Edge Box の実行が物理固定される | QEMU の vCPU スレッドへの `taskset` |

## 2 つのモード

### full モード — 完全分割 (既定。再起動 1 回)

```powershell
.\cpu-partition.ps1 -Apply -Mode full -HostLps "0-19" -GuestLps "20-27"   # 設定書き込み (設定コンソールなら [この内容で適用])
Restart-Computer                                                          # 再起動 → 以後は自動
```

- ハイパーバイザーのスケジューラを **core** に切り替え (この CPU では classic として動作・報告されます。分離の効き目はスケジューラの種類に依りません)
- **minroot** で Windows を先頭 20 論理 CPU に封じ込め (タスクマネージャーで見える CPU 数自体が 20 になる)
- **CPU グループ** で Edge Box を CPU 20-27 に固定
- 再起動後は起動タスク `CpuPartition-Boot` が **CPU グループを作成して Edge Box を固定し、そのあと Edge Box を起動**します。
  CPU グループは再起動で消えるため、**起動のたびに作り直し、5 分ごとに確かめ直します**
- Edge Box 実行中は CPU グループへの割り当てが失敗する (実機: 0x80048007) ため、割り当ては **Edge Box の停止中 (起動前)** に行い、
  実行中の確認では固定済みのグループに触りません (ほどくと固定が外れる瞬間ができるため)。
  `windows-host` の起動・再起動スクリプトは、Edge Box を起動する前にこの固定を先に行います
- Edge Box の自動起動は起動タスクに任せます (`-Undo` で元の自動起動設定に戻す)
- 成立状態は `cpu-full-status.json` に書かれ、`.\cpu-partition.ps1` (引数なしの現状表示) に出ます

**制約 (正直な列挙)**:
- スケジューラ変更はクライアント版 Windows では **Microsoft 公式サポート外**の構成です
  (`-Undo` + 再起動で完全に既定へ戻せます。専用用途の PC 向きの選択です)
- CPU グループの操作には Microsoft 公式配布の `CpuGroups.exe` が必要です (適用時に自動取得。
  オフライン環境では別 PC でダウンロードして `tools\` に置いてください)。
  クライアント版で動かない環境では **minroot + 処理能力予約までの「準分割」** で止まり、その旨を赤で表示します
  (i7-14700 + Windows 11 の実機では動作を確認済み)
- 万一の復旧手順: 管理者コマンドプロンプトで `bcdedit /deletevalue hypervisorschedulertype` と
  `bcdedit /deletevalue hypervisorrootproc` (Windows 自体は普通に起動します)

### runtime モード — 再起動なし・Windows 標準構成のまま

```powershell
.\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-19" -GuestLps "20-27"
```

- Edge Box の CPU 実行 (`vmmem`) を **Edge Box 用コアへ物理固定**、`vmmem` の優先度を High に
- **Windows 側の締め出し (常駐 `CpuPartition-Watch`)**: 3 秒ごとに、`vmmem` 以外の**全プロセス**を
  Windows 用コアへ固定し直す (新しく起動したプロセスも数秒以内に戻る)。固定できないのは保護された
  システムプロセス (csrss, services など) だけで、名前を記録と現状表示に出す。`-NoContain` で無効化
- Edge Box の起動を検知して再適用するタスク `CpuPartition-Pin` (2 分ごと。常駐が止まっていれば起こす)

**保証の強さ**: Edge Box → Windows 用コアには載らない。Windows のプロセス → Edge Box 用コアには載らない。
残るのは固定できない保護プロセスとカーネル・割り込みの分だけ (通常 1% 未満)。それも無くすのが full。

### どちらを選ぶか

| | full (既定) | runtime |
|---|---|---|
| 再起動 | 1 回 | 不要 (稼働中の Edge Box に後から適用可) |
| Windows 標準構成 | スケジューラ変更 (サポート外構成) | 維持 (公式サポート内) |
| Edge Box → Windows 用コア | **構造的に不可能** | 載らない (物理固定) |
| Windows のプロセス → Edge Box 用コア | **構造的に不可能** | 載らない (常駐が固定し続ける) |
| Windows のカーネル・割り込み → Edge Box 用コア | **構造的に不可能** | わずかに残る (通常 1% 未満) |
| 戻し方 | `-Undo` + 再起動 | `-Undo` (即時) |

## 設定コンソール (GUI) — 『CPU割り当て』

**`setup.cmd` をダブルクリック**してください。管理者への昇格・ファイルのブロック解除・
アイコン (『CPU割り当て』『Edge Box 監視』) の作成まで一度に済みます。以後は PowerShell を開く必要はありません。
黒いコンソール窓も UAC の確認も出ません (管理者権限付きのタスクを経由するため)。

```
 左メニュー   CNCSCREEN CORE SPLIT (アプリ名)
              HOME / SETTING / MONITOR (『Edge Box 監視』を開く)
 HOME
   P コア (性能重視)  8 コア / 16 スレッド
     [P0 WINDOWS 0 1] [P1 WINDOWS 2 3] ... [P7 WINDOWS 14 15]
   E コア (効率重視)  12 コア / 12 スレッド
     [E0 WINDOWS 16] ... [E3 WINDOWS 19] [E4 EDGE BOX 20] ... [E11 EDGE BOX 27]
   検査結果                 適用できます
 操作バー     [● 適用できます] [● 適用済みの内容と同じです]     [分割を解除] | [この内容で適用] [閉じる]
```

| 画面 (左メニュー) | 内容 |
|---|---|
| **HOME** (開いたときの画面) | コアのタイル (1 物理コア = 1 枚)、検査結果 |
| **SETTING** | 登録名と Edge Box の状態、メモリの割り当て、アプリの割り当て |
| **MONITOR** | 『Edge Box 監視』を別ウィンドウで開く (画面は切り替わらない) |

各コアの動きは『Edge Box 監視』([MONITOR]) で確認できます。記録は `cpu-partition-log.txt` / `cpu-apps-log.txt` に残ります。
アプリ名は `cpu-ui-theme.ps1` の `$UiAppName` で変えられます。アプリ名の字体は、Eurostile がその PC に入っていれば Eurostile、無ければ同梱の Michroma (Eurostile 系の字体。`fonts\` に同梱、SIL Open Font License 1.1。全文は `fonts\OFL.txt`) です。アプリのアイコン (アプリ名の横・タイトルバー・タスクバー・デスクトップとスタートメニューの『CPU割り当て』) は `images\app-icon.png` / `images\app-icon.ico` です。ショートカットのアイコンは `setup.cmd` を実行したときに切り替わります。

- 下の操作バー ([分割を解除] [この内容で適用] [閉じる]、必要なときだけ [完全分離用に並べ直す]) はどの画面からでも使えます。Esc でも閉じます。[分割を解除] は「Edge Box が起動しなくなります」という注意を出し、[はい] のときだけ解除します
- 画面の切り替えは左メニューのほか Ctrl+1 (HOME) / Ctrl+2 (SETTING) でもできます。ウィンドウの大きさは自由に変えられ、狭いときはタイルが折り返します
- 色の意味はどの画面でも同じです: 青 = Windows、緑 = Edge Box、ミントグリーン (青み寄りの緑) = 正常・適用できる、赤 = エラー・適用できない
- P コア / E コアの区別は CPU 自身が申告する効率クラスから取得します (型番の決め打ちではありません)
- コアは Windows 用か Edge Box 用のどちらかです (未割当はありません)。並びの先頭側が Windows 用、末尾側が Edge Box 用で、境目は 1 か所です (完全分離の条件と同じ形)
- **タイルをクリック**して切り替えられるのは境目の両側の 2 枚だけです (Windows 用の末尾 → Edge Box 用 / Edge Box 用の先頭 → Windows 用)。境目から離れたタイルや P コア (Windows 専用) を押しても何も変わりません。Edge Box 用が 0 コア・Windows 用が 2 コア未満になる切り替えもしません
- 保存済みの割り当てが境目 1 か所の形でない場合 (旧版の未割当など) は、Edge Box 用の数を保ったまま末尾へ寄せて表示します
- 既定の割り当て (末尾の E コア 8 個 = Edge Box / 残り = Windows) は開いた時点で入っています
- 適用・解除・実測・監視はすべてこの画面から実行できます。完全分離は「[この内容で適用] → 再起動」だけで完了します
- 画面の方式名は「簡易分離」= runtime、「完全分離」= full です。画面には仕組みの名前 (minroot・CPU グループなど) を出しません

### 動かない設定・矛盾した設定は適用できません (安全装置)

| 検査 | 適用を止める条件 |
|---|---|
| Edge Box のコア | P コアが含まれている / E コアが最低数 (既定 **8**) 未満 / Edge Box 用の E コアが末尾に続けて並んでいない |
| Windows の最低コア数 | Windows 側が 2 コア未満 (Edge Box の I/O 処理も Windows 側で動くため。4 未満は注意表示) |
| 方式の前提 | runtime なのにスケジューラが root でない / full 用の設定が書き込み済みで矛盾している / minroot 中の runtime |
| full の連番規則 | Windows 側が CPU 0 からの続き番号でない (minroot の仕様)。[full 用に並べ直す] で自動修正 |
| 登録名・環境 | 対象の登録名が空 / Hyper-V が無効 |

### Edge Box がまだ無くても設定できます

対象の Edge Box がまだ作られていない場合 (名前は直接入力できます)、割り当てだけを保存し、
その Edge Box を作成して起動した時点で自動タスクが適用します。

### アプリの割り当て — Windows 側のアプリを決めたコアで動かす

SETTING の「アプリの割り当て」にある **[編集]** から、アプリ単位でコアを指定できます
([インストール済みから追加...] / [実行中から追加...] / [ファイルから追加...])。

- コアの選択肢は **Windows 用のコアだけ** (Edge Box 用は表示されず、古い登録に含まれていても適用時に外されます)
- 優先度は 通常 / 高 / 低
- 登録すると起動のたびに自動で固定し直します (タスク `CpuPartition-Apps` が 1 分ごとに確認)

```powershell
.\cpu-apps.ps1 -Show        # 登録内容と現在の固定状況
.\cpu-apps.ps1 -Apply       # 今すぐ適用
.\cpu-apps.ps1 -Uninstall   # 自動適用をやめ、固定も解除 (登録内容は残る)
```

## リアルタイム監視 (『Edge Box 監視』)

各スレッド (論理 CPU) の負荷を毎秒表示する別ウィンドウです。デスクトップの『Edge Box 監視』か、
設定コンソールの [MONITOR] から開きます。最小化してしまっておけます。

```
 Windows : 平均 6%   (割り当て CPU 0-19 / 20 スレッド)
 Edge Box : 平均 5%   (割り当て CPU 20-27 / 8 スレッド)   状態: Running

 Windows 用 (CPU 0-19 / 20 スレッド)        ← 番号順。上に CPU 番号と P0/E3 の印、下に使用率
  CPU 0  CPU 1 ... CPU 15  CPU 16 ... CPU 19
 Edge Box 用 (CPU 20-27 / 8 スレッド)       ← Windows 用と同じ幅・高さの縦長の棒
  CPU 20 ... CPU 27
```

| 要素 | 意味 |
|---|---|
| **この画面自身の負荷** | 上部の状態行に出る、監視画面そのものが使っている CPU (Windows が使える CPU 全体に対する %)。監視は読むだけで、閉じても分離には影響しない。Edge Box 用 CPU では一切動かない |
| **区画** | Windows 用 / Edge Box 用に分けて、それぞれ CPU 番号の順。どの区画も同じ大きさの棒で並べる |
| **CPU の下の使用率** | 合計使用率。区画に合わない側の実行が 1% を超えていれば赤 (赤い下線も付く) |
| 棒の色 | 緑 = Edge Box の実行 / 青 = Windows の実行 / 灰 = ハイパーバイザー内部 |
| **P0 / E3 の印** | その CPU が属するコア (明るい灰 = P コア / 暗い灰 = E コア) |

```powershell
.\cpu-monitor.ps1                    # コマンドで開く場合
.\cpu-monitor.ps1 -IntervalMs 2000   # 2 秒ごと
```

## メモリの割り当て

設定コンソールの「メモリの割り当て」で、PC 全体のメモリを Windows と Edge Box に分けられます。
実メモリを超える指定や Windows 側が足りなくなる指定 (最低 8 GB) は適用できません。固定メモリで設定します。
メモリは Edge Box の停止中にしか変更できないため、実行中は「停止 → 設定 → 起動」を行うか確認が出ます
(正常シャットダウンだけを試み、強制電源断は行いません)。

```powershell
.\cpu-partition.ps1 -MemoryGB 12              # Edge Box 停止中なら即反映。実行中なら案内だけ
.\cpu-partition.ps1 -MemoryGB 12 -RestartVM   # 実行中でも 停止→設定→起動 で今すぐ反映
```

## コマンドで操作する場合

```powershell
.\cpu-partition.ps1                                                   # 現状の確認 (何も変更しない)
.\cpu-partition.ps1 -Apply -Mode full -HostLps "0-19" -GuestLps "20-27"   # full を適用 → 再起動
.\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-19" -GuestLps "20-27" # runtime を適用 (再起動なし)
.\cpu-partition.ps1 -Verify -Seconds 30                               # 実測 (runtime 向け。full では『Edge Box 監視』を使う)
.\cpu-partition.ps1 -SelfTest                                         # 撤退手順の予行 (収集は止まらない)
.\cpu-partition.ps1 -Undo                                             # 全解除 (full だった場合はその後 1 回再起動)
```

- 混成 CPU では `-HostCores` (コア数指定) は曖昧になるため、論理 CPU 番号での明示指定 (`-HostLps` / `-GuestLps`) を求めます
- full の minroot は「先頭から N 個」方式のため、Windows 側は必ず論理 0 始まりの連番です
- `-Verify` は「CPU ごとの実行時間 − 同じ番号のルート VP の実行時間」で Edge Box の実行を推定します。
  この方法は 2 つの帳簿を別々の時刻に読んで毎秒 0 で切るため、正の偏り (見かけの値) が残ります。
  full の確認は『Edge Box 監視』の区画ごとの色と赤い使用率で行ってください

## 自動タスク・常駐の一覧

| 名前 | いつ動くか | 役割 |
|---|---|---|
| `CpuPartition-Boot` | 起動時 + 5 分ごと (full) | minroot の反映確認 → CPU グループを作成して Edge Box を固定 → Edge Box を起動。状態を `cpu-full-status.json` に記録 |
| `CpuPartition-Watch` | 常駐 (runtime) | 3 秒ごとに Windows 側の全プロセスを Windows 用コアへ固定。状態を `cpu-contain-status.json` に記録 |
| `CpuPartition-Pin` | Edge Box 起動時 + 2 分ごと (runtime) | vmmem / vmwp の固定を再適用。常駐が止まっていれば起こす |
| `CpuPartition-Apps` | 1 分ごと | 『アプリの割り当て』の固定を再適用 |
| `CpuPartition-Console` / `-Monitor` | アイコンから | 『CPU割り当て』『Edge Box 監視』を UAC なしで開く |

## トラブルシューティング

### 最初につまずく点: 「デジタル署名されていません」で実行できない

PowerShell の実行ポリシーによる拒否で、スクリプトの不具合ではありません。
**`setup.cmd` から始めれば回避できます** (ブロック解除と Bypass 起動を代行)。手動なら:

```powershell
Get-ChildItem C:\double-os-boot -Recurse | Unblock-File                       # ネット由来のブロック印を解除
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-console.ps1        # 都度回避
```

### その他

| 症状 | 対処 |
|---|---|
| `.\cpu-partition.ps1` の現状表示が「準分割 (Edge Box の固定が効いていません …)」と出る (full) | 記録 (`cpu-partition-log.txt`) を見る。「登録 '...' が見つかりません」なら登録名の不一致 (自動で直すが、設定コンソールで対象を確認)。「割り当てられません: 0x80048007」は Edge Box 実行中に固定しようとしたもの → 『Edge Box 再起動』で停止中に固定される。それでも駄目なら CpuGroups.exe が使えない環境: [分割を解除] → 再起動 → runtime で適用 |
| 『Edge Box 監視』で区画に合わない色・赤い使用率が出続ける | 60 秒待ってから判断する。それでも続くなら記録の末尾に「CPU グループを作成し…」が繰り返し出ていないか確認 (固定をほどいて作り直している) → 最新版に更新 |
| full 適用後に「反映されていません」 | 再起動したか確認。再起動済みなら、その PC では minroot が効かないため `-Undo` して runtime へ |
| Edge Box の動きが悪くなった | Windows 側を細くしすぎていないか (Edge Box のディスク/ネットワーク処理は Windows 側コアで動く)。標準の P8+E4 なら問題ない |
| 元に全部戻したい | `.\cpu-partition.ps1 -Undo` → 再起動 |
| 「タスク XML に、書式設定が正しくない値…」 | 自動タスクの登録形式が環境に合わないケース。機能の多い順に組み合わせを試して必ず登録するため、この失敗では止まらない |

## 設定・記録ファイル (すべてこのフォルダ内、Git 管理外)

| ファイル | 内容 |
|---|---|
| `cpu-partition.json` | 適用済みの分割計画 (自動タスクが参照。対象の登録名も含む) |
| `cpu-topology.json` | 検出したコア構成の控え (minroot でコアが見えなくなったとき表示に使う) |
| `cpu-partition-log.txt` | 適用・起動タスク・常駐の記録 (直近 200 行) |
| `cpu-full-status.json` | full モードの成立状態 (起動タスクが書く。監視画面が読む) |
| `cpu-contain-status.json` | runtime の締め出し (常駐) の状態 |
| `cpu-apps.json` / `cpu-apps-log.txt` | アプリのコア割り当てと記録 |
| `tools\CpuGroups.exe` | full モード用の Microsoft 公式ツール (適用時に自動取得) |

削除して元に戻す場合は、先に `.\cpu-partition.ps1 -Undo` を実行してから
フォルダごと削除してください (自動タスクと bcdedit 設定が残らないように)。
