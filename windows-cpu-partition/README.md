# windows-cpu-partition — Windows 用 CPU コア分割ツール (別口・独立)

Windows と Hyper-V EdgeBox の間で **CPU コアを分割し、両者の処理が混ざらないように固定**する
独立ツールです。GUI の設定コンソール (`cpu-console.ps1`)、リアルタイム監視 (`cpu-monitor.ps1`)、
その実体 (`cpu-partition.ps1` / `cpu-apps.ps1`) の構成です。
**Windows 側のアプリを特定のコアに固定する機能**も同じ画面から設定できます。

**このフォルダは他の構成から独立しています。** `windows-host/` とはファイルも設定も共有しません
(EdgeBox を起動するときだけ、`windows-host` 側が「固定してから起動する」ためにこのツールを呼びます)。
どの Hyper-V の登録にも使えます (対象は `-VMName` で指定。既定は `EdgeBox`。名前が実在しなければ
EdgeBox のディスクを持つ登録を自動で見つけます)。

## 標準の割り当てと保証 (i7-14700: P コア 8 + E コア 12 の場合)

```
 論理CPU:  0 ... 15 | 16 17 18 19 | 20 21 22 23 24 25 26 27
           P0 .. P7 | E0 E1 E2 E3 | E4 E5 E6 E7 E8 E9 E10 E11
           └─ Windows (P コア 8 + E コア 4 = 20 スレッド) ─┘ └── EdgeBox (E コア 8) ──┘
```

| 決まり | 内容 |
|---|---|
| 方式 | 既定は **full (完全分割)**。runtime に切り替えることもできる |
| EdgeBox | **E コア専用**。末尾の E コアを最低 8 個。増やすことはできる (再起動が必要) が、P コアは割り当てられない |
| Windows | 残り全部 (P コア 8 + E コア 4)。『アプリの割り当て』で、この 12 コアの中からアプリごとに個別指定できる |
| 保証 | full では **Windows は CPU 20-27 に載れず、EdgeBox は CPU 0-19 に載れない** (双方向とも構造的) |
| 確認 | 『EdgeBox 監視』の「分離の状態」が両方 0.0% |

## 仕組み (なぜ「不可能」ではないのか)

Windows クライアント版の Hyper-V には、コア固定の GUI も PowerShell コマンドもありません。
しかし土台のハイパーバイザーと OS には、次の機構が備わっています。

| 機構 | 何をするか | Linux での対応物 |
|---|---|---|
| **minroot** (`bcdedit hypervisorrootproc`) | ハイパーバイザー起動時に、**Windows 自体を先頭 N 個の論理 CPU に封じ込める**。Windows のプロセスも割り込みも残りのコアには一切載らなくなる | `isolcpus` |
| **CPU グループ** (Microsoft 製 `CpuGroups.exe`) | EdgeBox を指定した論理 CPU 集合に固定する (ハイパーバイザー内部の HCS インターフェース) | libvirt の `<vcpupin>` |
| **root スケジューラの実体** (runtime 用) | クライアント版の既定では、EdgeBox の CPU は `vmmem` という Windows のプロセスのスレッドとして動く。そのプロセスにコア固定 (アフィニティ) を掛ければ EdgeBox の実行が物理固定される | QEMU の vCPU スレッドへの `taskset` |

## 2 つのモード

### full モード — 完全分割 (既定。再起動 1 回)

```powershell
.\cpu-partition.ps1 -Apply -Mode full -HostLps "0-19" -GuestLps "20-27"   # 設定書き込み (設定コンソールなら [この内容で適用])
Restart-Computer                                                          # 再起動 → 以後は自動
```

- ハイパーバイザーのスケジューラを **core** に切り替え (この CPU では classic として動作・報告されます。分離の効き目はスケジューラの種類に依りません)
- **minroot** で Windows を先頭 20 論理 CPU に封じ込め (タスクマネージャーで見える CPU 数自体が 20 になる)
- **CPU グループ** で EdgeBox を CPU 20-27 に固定
- 再起動後は起動タスク `CpuPartition-Boot` が **CPU グループを作成して EdgeBox を固定し、そのあと EdgeBox を起動**します。
  CPU グループは再起動で消えるため、**起動のたびに作り直し、5 分ごとに確かめ直します**
- EdgeBox 実行中は CPU グループへの割り当てが失敗する (実機: 0x80048007) ため、割り当ては **EdgeBox の停止中 (起動前)** に行い、
  実行中の確認では固定済みのグループに触りません (ほどくと固定が外れる瞬間ができるため)。
  `windows-host` の起動・再起動スクリプトは、EdgeBox を起動する前にこの固定を先に行います
- EdgeBox の自動起動は起動タスクに任せます (`-Undo` で元の自動起動設定に戻す)
- 成立状態は `cpu-full-status.json` に書かれ、設定コンソールの上部と『EdgeBox 監視』に出ます

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

- EdgeBox の CPU 実行 (`vmmem`) を **EdgeBox 用コアへ物理固定**、`vmmem` の優先度を High に
- **Windows 側の締め出し (常駐 `CpuPartition-Watch`)**: 3 秒ごとに、`vmmem` 以外の**全プロセス**を
  Windows 用コアへ固定し直す (新しく起動したプロセスも数秒以内に戻る)。固定できないのは保護された
  システムプロセス (csrss, services など) だけで、名前を記録と監視画面に出す。`-NoContain` で無効化
- EdgeBox の起動を検知して再適用するタスク `CpuPartition-Pin` (2 分ごと。常駐が止まっていれば起こす)

**保証の強さ**: EdgeBox → Windows 用コアには載らない。Windows のプロセス → EdgeBox 用コアには載らない。
残るのは固定できない保護プロセスとカーネル・割り込みの分だけ (通常 1% 未満)。それも無くすのが full。

### どちらを選ぶか

| | full (既定) | runtime |
|---|---|---|
| 再起動 | 1 回 | 不要 (稼働中の EdgeBox に後から適用可) |
| Windows 標準構成 | スケジューラ変更 (サポート外構成) | 維持 (公式サポート内) |
| EdgeBox → Windows 用コア | **構造的に不可能** | 載らない (物理固定) |
| Windows のプロセス → EdgeBox 用コア | **構造的に不可能** | 載らない (常駐が固定し続ける) |
| Windows のカーネル・割り込み → EdgeBox 用コア | **構造的に不可能** | わずかに残る (通常 1% 未満) |
| 戻し方 | `-Undo` + 再起動 | `-Undo` (即時) |

## 設定コンソール (GUI) — 『CPU割り当て』

**`setup.cmd` をダブルクリック**してください。管理者への昇格・ファイルのブロック解除・
アイコン (『CPU割り当て』『EdgeBox 監視』) の作成まで一度に済みます。以後は PowerShell を開く必要はありません。
黒いコンソール窓も UAC の確認も出ません (管理者権限付きのタスクを経由するため)。

```
 この PC の CPU   Intel Core i7-14700 — 20 コア / 28 スレッド (P コア 8 + E コア 12)
                 ハイパーバイザーのスケジューラ: classic   minroot: 有効 — Windows は 20 論理 CPU に封じ込め中
                 完全分割: 成立 — Windows は CPU 0-19 に封じ込め (minroot) / EdgeBox は CPU 20-27 に固定 (CPU グループ)
 対象と方式      対象の登録名: EdgeBox   方式: ( ) runtime  (●) full (完全分割・再起動 1 回。推奨)   EdgeBox 側の最低コア数: 8
 P コア (性能重視) — 8 コア / 16 スレッド
  [P0 Windows] [P1 Windows] ... [P7 Windows]                          ← P コアは Windows 専用 (クリックで Windows ⇔ 未割当)
 E コア (効率重視) — 12 コア / 12 スレッド
  [E0 Windows] [E1 Windows] [E2 Windows] [E3 Windows] [E4 EdgeBox] ... [E11 EdgeBox]
 この内容で割り当てます   Windows : 12 コア / 20 スレッド (P 8 / E 4)  CPU 0-19
                          EdgeBox : 8 コア / 8 スレッド (P 0 / E 8)   CPU 20-27
 検査結果                 適用できます                                  [この内容で適用]
```

- P コア / E コアの区別は CPU 自身が申告する効率クラスから取得します (型番の決め打ちではありません)
- **タイルをクリック**するたびに Windows 用 → EdgeBox 用 → 未割当 と切り替わります (P コアは Windows 用 ⇔ 未割当)
- 既定の割り当て (末尾の E コア 8 個 = EdgeBox / 残り = Windows) は開いた時点で入っています
- 適用・解除・実測・監視はすべてこの画面から実行できます。full は「[この内容で適用] → 再起動」だけで完了します

### 動かない設定・矛盾した設定は適用できません (安全装置)

| 検査 | 適用を止める条件 |
|---|---|
| EdgeBox のコア | P コアが含まれている / E コアが最低数 (既定 **8**) 未満 / EdgeBox 用の E コアが末尾に続けて並んでいない |
| Windows の最低コア数 | Windows 側が 2 コア未満 (EdgeBox の I/O 処理も Windows 側で動くため。4 未満は注意表示) |
| 方式の前提 | runtime なのにスケジューラが root でない / full 用の設定が書き込み済みで矛盾している / minroot 中の runtime |
| full の連番規則 | Windows 側が CPU 0 からの続き番号でない (minroot の仕様)。[full 用に並べ直す] で自動修正 |
| 登録名・環境 | 対象の登録名が空 / Hyper-V が無効 |

### EdgeBox がまだ無くても設定できます

対象の EdgeBox がまだ作られていない場合 (名前は直接入力できます)、割り当てだけを保存し、
その EdgeBox を作成して起動した時点で自動タスクが適用します。

### アプリの割り当て — Windows 側のアプリを決めたコアで動かす

画面下の **[アプリの割り当てを編集...]** から、アプリ単位でコアを指定できます
([インストール済みから追加...] / [実行中から追加...] / [ファイルから追加...])。

- コアの選択肢は **Windows 用のコアだけ** (EdgeBox 用は表示されず、古い登録に含まれていても適用時に外されます)
- 優先度は 通常 / 高 / 低
- 登録すると起動のたびに自動で固定し直します (タスク `CpuPartition-Apps` が 1 分ごとに確認)

```powershell
.\cpu-apps.ps1 -Show        # 登録内容と現在の固定状況
.\cpu-apps.ps1 -Apply       # 今すぐ適用
.\cpu-apps.ps1 -Uninstall   # 自動適用をやめ、固定も解除 (登録内容は残る)
```

## リアルタイム監視 (『EdgeBox 監視』)

各論理 CPU の負荷とメモリの使用量を毎秒表示する別ウィンドウです。デスクトップの『EdgeBox 監視』か、
設定コンソールの [リアルタイム監視] から開きます。大きさは自由に変えられ、最小化してしまっておけます。

```
 Windows : 平均 6%   (割り当て CPU 0-19 / 20 論理)
 EdgeBox : 平均 5%   (割り当て CPU 20-27 / 8 論理)   状態: Running
 コア構成: P コア 8 (CPU 0-15) / E コア 12 (CPU 16-27)   合計 20 コア / 28 スレッド
 分離の状態: ○ 混ざっていません   EdgeBox が Windows 用コアで動いた割合 0.0%  /  Windows が EdgeBox 用コアで動いた割合 0.0%   (直近 60 秒)
 完全分離: ○ 成立

 Windows 用 (CPU 0-19 / 20 論理)        ← 番号順。上に CPU 番号と P0/E3 の印、下に使用率
  CPU 0  CPU 1 ... CPU 15  CPU 16 ... CPU 19
 EdgeBox 用 (CPU 20-27 / 8 論理)
  CPU 20 ... CPU 27
 メモリ  ■■■■□□□□□
  PC 全体 31.7 GB  Windows 使用中 13.2 GB  空き 10.5 GB (物理 67% 使用)  コミット率 45%  ページング 0 /秒
  EdgeBox 割り当て 8.0 GB (実メモリ 8.0 GB)  内部で使用中 2.1 GB / 内部の空き 5.9 GB (26% 使用)  要求 2.3 GB  圧力 28%  状態 OK
```

| 要素 | 意味 |
|---|---|
| **コア構成** | P コア / E コアの数と CPU 番号。CPU 自身から取得 (minroot で隠れた CPU は保存した構成か計画から補う) |
| **分離の状態** | 両方向の混ざり具合。どちらかが 0.5% を超えると「△ 混ざっています」(赤) |
| **完全分離 / Windows 側の固定** | 分離の成立状態 (成立 / 再起動待ち / 未成立)。監視画面には仕組みの名前 (方式や固定の手段) は出さず、状態だけを出す |
| **区画** | Windows 用 / EdgeBox 用に分けて、それぞれ論理 CPU の番号順 |
| **CPU の下の使用率** | 合計使用率。区画に合わない側の実行が 1% を超えていれば赤 |
| 棒の色 | 緑 = EdgeBox の実行 / 青 = Windows の実行 / 灰 = ハイパーバイザー内部 |
| **P0 / E3 の印** | その論理 CPU が属するコア (橙 = P コア / 青緑 = E コア) |
| **メモリ 1 行目** | Windows 側の負荷: 物理メモリの使用率、コミット率 (仮想メモリの使い切り具合。90% 以上で赤)、ページング/秒 (ディスクへの退避。1000 以上で赤) |
| **メモリ 2 行目** | EdgeBox 内部: 割り当て量と、EdgeBox が Hyper-V の統合サービス (動的メモリの報告) で知らせてくる「内部で使用中 / 内部の空き / 要求 / 圧力」。報告が無い EdgeBox では「取得不可」と出る (外からは見えない) |

**「分離の状態」の判定方法 (VP 合計)**: ハイパーバイザーは「CPU ごとの実行時間」と
「EdgeBox の仮想プロセッサ (VP) ごとの実行時間」の 2 つの帳簿を持っています。
EdgeBox の 8 個の VP の実行時間の合計と、CPU 20-27 の実行時間の合計を突き合わせます。
CPU 20-27 には minroot で Windows が載れないので、

- EdgeBox の VP 合計のほうが大きければ、その差分は **EdgeBox が Windows 用の CPU で動いた分**
- CPU 20-27 の合計のほうが大きければ、その差分は **EdgeBox 以外 (Windows) が EdgeBox 用の CPU で動いた分**

CPU 番号の対応を仮定しないため、full (minroot + classic/core) でも正確です。
2 つの帳簿の読み取り時刻のずれ (数十ミリ秒) による ± の揺れは連続する区間で打ち消し合うので、
直近 60 秒分を符号付きで足してから 0 で切ります。**0.0% と出ていれば本当に混ざっていません**。
逆に 0 でない値が続くなら真の漏れで、記録 (`cpu-partition-log.txt`) に必ず痕跡が出ます。

```powershell
.\cpu-monitor.ps1                    # コマンドで開く場合
.\cpu-monitor.ps1 -IntervalMs 2000   # 2 秒ごと
```

## メモリの割り当て

設定コンソールの「メモリの割り当て」で、PC 全体のメモリを Windows と EdgeBox に分けられます。
実メモリを超える指定や Windows 側が足りなくなる指定 (最低 8 GB) は適用できません。固定メモリで設定します。
メモリは EdgeBox の停止中にしか変更できないため、実行中は「停止 → 設定 → 起動」を行うか確認が出ます
(正常シャットダウンだけを試み、強制電源断は行いません)。

```powershell
.\cpu-partition.ps1 -MemoryGB 12              # EdgeBox 停止中なら即反映。実行中なら案内だけ
.\cpu-partition.ps1 -MemoryGB 12 -RestartVM   # 実行中でも 停止→設定→起動 で今すぐ反映
```

## コマンドで操作する場合

```powershell
.\cpu-partition.ps1                                                   # 現状の確認 (何も変更しない)
.\cpu-partition.ps1 -Apply -Mode full -HostLps "0-19" -GuestLps "20-27"   # full を適用 → 再起動
.\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-19" -GuestLps "20-27" # runtime を適用 (再起動なし)
.\cpu-partition.ps1 -Verify -Seconds 30                               # 実測 (runtime 向け。full では『EdgeBox 監視』を使う)
.\cpu-partition.ps1 -SelfTest                                         # 撤退手順の予行 (収集は止まらない)
.\cpu-partition.ps1 -Undo                                             # 全解除 (full だった場合はその後 1 回再起動)
```

- 混成 CPU では `-HostCores` (コア数指定) は曖昧になるため、論理 CPU 番号での明示指定 (`-HostLps` / `-GuestLps`) を求めます
- full の minroot は「先頭から N 個」方式のため、Windows 側は必ず論理 0 始まりの連番です
- `-Verify` は「CPU ごとの実行時間 − 同じ番号のルート VP の実行時間」で EdgeBox の実行を推定します。
  この方法は runtime (root スケジューラ) では正確ですが、full ではルート VP が Windows 用 CPU の中を移動するため
  見かけの値が出ます。full の確認は『EdgeBox 監視』の「分離の状態」(VP 合計で判定) を使ってください

## 自動タスク・常駐の一覧

| 名前 | いつ動くか | 役割 |
|---|---|---|
| `CpuPartition-Boot` | 起動時 + 5 分ごと (full) | minroot の反映確認 → CPU グループを作成して EdgeBox を固定 → EdgeBox を起動。状態を `cpu-full-status.json` に記録 |
| `CpuPartition-Watch` | 常駐 (runtime) | 3 秒ごとに Windows 側の全プロセスを Windows 用コアへ固定。状態を `cpu-contain-status.json` に記録 |
| `CpuPartition-Pin` | EdgeBox 起動時 + 2 分ごと (runtime) | vmmem / vmwp の固定を再適用。常駐が止まっていれば起こす |
| `CpuPartition-Apps` | 1 分ごと | 『アプリの割り当て』の固定を再適用 |
| `CpuPartition-Console` / `-Monitor` | アイコンから | 『CPU割り当て』『EdgeBox 監視』を UAC なしで開く |

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
| 『EdgeBox 監視』が「準分割 — EdgeBox の固定が効いていません」と出る (full) | 記録 (`cpu-partition-log.txt`) を見る。「登録 '...' が見つかりません」なら登録名の不一致 (自動で直すが、設定コンソールで対象を確認)。「割り当てられません: 0x80048007」は EdgeBox 実行中に固定しようとしたもの → 『EdgeBox 再起動』で停止中に固定される。それでも駄目なら CpuGroups.exe が使えない環境: [分割を解除] → 再起動 → runtime で適用 |
| 「分離の状態」が 0 にならない | 60 秒待ってから判断する。それでも続くなら記録の末尾に「CPU グループを作成し…」が繰り返し出ていないか確認 (固定をほどいて作り直している) → 最新版に更新 |
| full 適用後に「反映されていません」 | 再起動したか確認。再起動済みなら、その PC では minroot が効かないため `-Undo` して runtime へ |
| EdgeBox の動きが悪くなった | Windows 側を細くしすぎていないか (EdgeBox のディスク/ネットワーク処理は Windows 側コアで動く)。標準の P8+E4 なら問題ない |
| 元に全部戻したい | `.\cpu-partition.ps1 -Undo` → 再起動 |
| 「タスク XML に、書式設定が正しくない値…」 | 自動タスクの登録形式が環境に合わないケース。機能の多い順に組み合わせを試して必ず登録するため、この失敗では止まらない |

## 設定・記録ファイル (すべてこのフォルダ内、Git 管理外)

| ファイル | 内容 |
|---|---|
| `cpu-partition.json` | 適用済みの分割計画 (自動タスクが参照。対象の登録名も含む) |
| `cpu-topology.json` | 検出したコア構成の控え (minroot でコアが見えなくなったとき表示に使う) |
| `cpu-partition-log.txt` | 適用・起動タスク・常駐の記録 (直近 200 行) |
| `cpu-full-status.json` | full モードの成立状態 (起動タスクが書く。設定コンソール・監視画面が読む) |
| `cpu-contain-status.json` | runtime の締め出し (常駐) の状態 (監視画面が読む) |
| `cpu-apps.json` / `cpu-apps-log.txt` | アプリのコア割り当てと記録 |
| `tools\CpuGroups.exe` | full モード用の Microsoft 公式ツール (適用時に自動取得) |

削除して元に戻す場合は、先に `.\cpu-partition.ps1 -Undo` を実行してから
フォルダごと削除してください (自動タスクと bcdedit 設定が残らないように)。
