# windows-cpu-partition — Windows 用 CPU コア分割ツール (別口・独立)

Windows と Hyper-V EdgeBox の間で **CPU コアを分割して固定割り当て (ピンニング)**
するための独立ツールです。GUI の設定コンソール (`cpu-console.ps1`) と、その実体である
`cpu-partition.ps1` / `cpu-apps.ps1` の 3 本構成です。
**Windows 側のアプリを特定のコアに固定する機能** も同じ画面から設定できます。

**このフォルダは他の構成から独立しています。**
本リポジトリの EdgeBox 同時起動システム (構成B: `windows-host/` の EdgeBox 自動起動・画面表示)
とはファイルも設定も共有せず、入れても消しても互いに干渉しません。
どの Hyper-V EdgeBox にも使えます (対象 は `-VMName` で指定。既定値のみ `EdgeBox`)。

```
例: 8コア/16スレッドの CPU を「Windows 4 コア / EdgeBox 4 コア」に分割

 論理CPU:  0  1  2  3  4  5  6  7 | 8  9 10 11 12 13 14 15
           └────── Windows ──────┘ └────── EdgeBox ─────┘
            メイン業務・アプリ        EdgeBox の処理 (Windows の負荷の影響を受けない)
```

適用のタイミングは自由です: **Windows を起動した後、稼働中の EdgeBox に対して後から**
割り当てを掛けたり変更したりできます (runtime モード。再起動不要・即時反映)。

## なぜ「不可能」ではないのか (仕組みの正直な説明)

Windows クライアント版の Hyper-V には、コア固定の GUI も PowerShell コマンドもありません。
しかし土台のハイパーバイザーと OS には、次の 3 つの実物の機構が備わっています。

| 機構 | 何をするか | Linux での対応物 |
|---|---|---|
| **root スケジューラの実体** | クライアント版では、EdgeBox のEdgeBox の CPU は `vmmem` という Windows のプロセスのスレッドとして Windows が実行している。→ そのプロセスにコア固定 (アフィニティ) を掛ければ、**EdgeBox の CPU 実行そのものが物理固定される** | QEMU の vCPU スレッドへの `taskset`/`vcpupin` |
| **minroot** (`bcdedit hypervisorrootproc`) | ハイパーバイザー起動時に、**Windows 自体を先頭 N 個の論理 CPU に封じ込める**。Windows のプロセスも割り込みも残りのコアには一切載らなくなる | `isolcpus` (Windows をコアから締め出す) |
| **CPU グループ** (Microsoft 製 `CpuGroups.exe`) | EdgeBox を指定した論理 CPU 集合に固定する (ハイパーバイザー内部の HCS インターフェース) | libvirt の `<vcpupin>` |

これらを組み合わせ、環境に応じて 2 つのモードを提供します。

## 2 つのモード

### runtime モード — 再起動不要・Windows 標準構成のまま (まずこちらを推奨)

```powershell
.\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4
```

- EdgeBox の CPU 実行 (`vmmem`) を **EdgeBox 用コアへ物理固定**
- EdgeBox のディスク/ネットワーク処理 (`vmwp`) を **Windows 用コアへ固定**
- `vmmem` の優先度を High に昇格 — Windows 側の処理がEdgeBox 用コアに
  来ても即座に押し出される (完全な立入禁止ではなく「最優先の先客」方式)
- EdgeBox の起動を Windows イベントで検知して自動再適用するタスク
  (`CpuPartition-Pin`) を登録 — 電源 ON だけの運用でも効き続ける

**保証の強さ**: EdgeBox → Windows 用コアには載らない (物理固定)。
Windows → EdgeBox 用コアに一瞬載ることはあるが、優先度で実効的に排除。

### full モード — 完全分割 (Linux 主構成と同等。再起動 1 回 + コマンド 2 回)

```powershell
.\cpu-partition.ps1 -Apply -Mode full -HostCores 4   # ① 設定書き込み
Restart-Computer                                      # ② 再起動
.\cpu-partition.ps1 -Apply -Mode full                 # ③ 反映確認 + EdgeBox固定
```

- ハイパーバイザーのスケジューラを **core** に切り替え (EdgeBox のコア割り当てを
  ハイパーバイザー自身が管理する方式。SMT 単位で分離するため安全性も高い)
- **minroot** でWindows を先頭 N 論理 CPU に封じ込め
  (適用後、タスクマネージャーで Windows から見える CPU 数自体が減る)
- **CPU グループ** でEdgeBox を残りのコアへ固定

**保証の強さ**: 双方向とも物理分割。Windows がどれだけ暴れてもEdgeBox 用コアには
構造的に到達できません (Linux の isolcpus + vcpupin と同格)。

**制約 (正直な列挙)**:
- スケジューラ変更はクライアント版 Windows では **Microsoft 公式サポート外**の構成です
  (動作実績は広く、`-Undo` で完全に既定へ戻せます。専用用途の PC 向きの選択です)
- CPU グループの操作には Microsoft 公式配布の `CpuGroups.exe` が必要です
  (スクリプトが取得を提案します。オフライン環境では別 PC でダウンロードして
  このフォルダの `tools\` に置いてください)。CPU グループは本来 Windows Server の
  機能のため、クライアント版で動かない環境もあります — その場合スクリプトは
  **minroot + 処理能力予約までの「準分割」** で止まり、どこまで効いているかを
  そのまま報告します (Windows 側の封じ込めだけでも効果の大半が得られます)
- Windows Server 2025 では `CpuGroups.exe` の不具合報告があります

### どちらを選ぶか

| | runtime | full |
|---|---|---|
| 再起動 | 不要 (稼働中の EdgeBox に後から適用可) | 1 回 |
| Windows 標準構成 | 維持 (公式サポート内) | スケジューラ変更 (サポート外構成) |
| EdgeBox → Windows 用コア | 載らない (物理固定) | 載らない (物理固定) |
| Windows → EdgeBox 用コア | 優先度で実効排除 | **構造的に不可能** |
| 戻し方 | `-Undo` (即時) | `-Undo` + 再起動 |

まず **runtime** で運用し、`-Verify` の実測で「Windows他実行%」がEdgeBox 用コアに
目立って残るようなら **full** に上げる、が推奨手順です。

## 設定コンソール (GUI) — おすすめの入口

コマンドを打たずに、画面でコアを選んで割り当てられます。

**`setup.cmd` をダブルクリック** してください。管理者への昇格・ファイルのブロック解除・
アイコンの作成まで一度に済みます。

以後は **PowerShell を開く必要はありません**。普通のアプリと同じように開けます。

| 開き方 | 場所 |
|---|---|
| デスクトップのアイコン | 『CPU割り当て』 |
| スタートメニュー | 「CPU」で検索しても出ます |
| タスクバー | スタートメニューで右クリック →『タスクバーにピン留めする』 |

**黒いコンソール窓は一切出ません**し、UAC の確認も出ません
(管理者権限付きのタスクを経由し、その起動を `wscript` で行うため)。

PowerShell から実行する場合は、実行ポリシーを回避する形で起動します:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-console.ps1 -Setup
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-console.ps1
```

> `.\cpu-console.ps1` と直接打つと、環境によっては
> 「デジタル署名されていません」と拒否されます (下の「最初につまずく点」参照)。

```
 この PC の CPU   Core i7-14700 - 20 コア / 28 スレッド (P コア 8 + E コア 12)
 ─────────────────────────────────────────────────────────
 P コア (性能重視) - 8 コア / 16 スレッド
  [P0 Windows ] [P1 Windows ] [P2 Windows ] ... クリックで切り替え
 E コア (効率重視) - 12 コア / 12 スレッド
  [E0 EdgeBox ] [E1 EdgeBox ] [E2 EdgeBox ] ...
 ─────────────────────────────────────────────────────────
 Windows : 8 コア / 16 スレッド (P 8 / E 0)   CPU 0-15
 EdgeBox : 12 コア / 12 スレッド (P 0 / E 12)  CPU 16-27
 検査結果: 問題ありません。この内容で適用できます。      [この内容で適用]
```

- **P コア / E コアを直接選べます**。区別は CPU 自身が申告する効率クラスから取得するため、
  型番の決め打ちではなく実機の構成そのものです (混成でない CPU なら 1 つの一覧で表示)
- **タイルをクリック**するたびに Windows 用 → EdgeBox 用 → 未割当 と切り替わります
- **かんたん設定**: 「P コア = Windows / E コア = EdgeBox (推奨)」「最低数だけ」「半分ずつ」「分割なし」
- 適用・解除・実測はすべてこの画面から実行できます (中身は `cpu-partition.ps1` が担当)

### EdgeBox がまだ無くても設定できます

対象の EdgeBox がまだ作られていない場合 (名前は直接入力できます)、ボタンは
**[保存 (EdgeBox 検出後に自動適用)]** に変わり、割り当てだけを保存します。
その EdgeBox を作成して起動した時点で、常駐タスク `CpuPartition-Pin` が検出して自動的に適用します。
先に CPU の配分を決めておいて、あとから EdgeBox を用意する、という順番で進められます。

### アプリの割り当て — Windows 側のアプリを決めたコアで動かす

画面下の **[アプリの割り当てを編集...]** から、アプリ単位でコアを指定できます。
追加は **[インストール済みから追加...]** が一番簡単です (スタートメニューとデスクトップの
ショートカット、および「プログラムのアンインストール」の情報から実行ファイルを集めて一覧にし、
名前で絞り込めます)。新しく入れたアプリもすぐ一覧に出ます。ほかに [実行中から追加...]
(いま動いているプロセスから) と [ファイルから追加...] (実行ファイルを直接指定) があります。

| 操作 | 内容 |
|---|---|
| ファイルから追加 | `.exe` を選んで登録 (パスで照合するため、同名の別アプリと混同しません) |
| 実行中のアプリから追加 | いま動いているアプリの一覧から選ぶ (ウィンドウを持つアプリが上に並びます) |
| コアを編集 | P/E を区別したコア一覧から選択。「Windows 側すべて」「P コアのみ」「E コアのみ」の一括指定つき |
| 優先度 | 通常 / 高 / 低。取り合いになったときの順番 (重要なアプリは『高』) |

- 登録すると **起動のたびに自動で固定し直します** (タスク `CpuPartition-Apps` が 1 分ごとに確認)
- 一覧から削除すると、いま動いている分の固定もその場で解除します
- EdgeBox 用のコアを選ぶと注意が表示されます (EdgeBox と取り合いになるため)

コマンドから確認・解除する場合:

```powershell
.\cpu-apps.ps1 -Show        # 登録内容と現在の固定状況
.\cpu-apps.ps1 -Apply       # 今すぐ適用
.\cpu-apps.ps1 -Uninstall   # 自動適用をやめ、固定も解除 (登録内容は残る)
```

### 動かない設定・矛盾した設定は適用できません (安全装置)

選ぶたびに検査し、問題があれば理由を表示して [この内容で適用] を押せなくします。

| 検査 | 適用を止める条件 |
|---|---|
| EdgeBox の最低コア数 | 割り当てが指定数 (既定 **4 コア**) 未満 — 画面右上で変更可 |
| Windows の最低コア数 | Windows 側が 2 コア未満 (EdgeBox の I/O 処理もWindows 側で動くため。4 未満は注意表示) |
| 方式の前提 | runtime なのにスケジューラが root でない / full 用の設定が書き込み済みで矛盾している |
| minroot 中の runtime | 隠れているコアには固定できないため、解除と再起動を案内 |
| full の連番規則 | Windows 側が CPU 0 からの続き番号でない (minroot の仕様)。[full 用に並べ直す] ボタンで自動修正 |
| 登録名 | 対象の 登録名が空 (EdgeBox が未作成なだけなら注意どまりで、保存できます) |
| 環境 | Hyper-V が無効 |

注意どまり (適用は可能) の例: 未割当コアがある、SMT ペアが左右に分かれている、
EdgeBox に P と E が混在、プロセッサ数と割り当て数が不一致 (適用時に自動調整)。

## リアルタイム監視 (『EdgeBox 監視』)

各コアの負荷と、メモリの使用量を毎秒表示する別ウィンドウです。
デスクトップ / スタートメニューの『EdgeBox 監視』、または設定コンソールの
[リアルタイム監視] ボタンから開きます。**大きさは自由に変えられ、最小化してしまっておけます**
(最小化中は測定を休みます)。

```
 Windows : 平均 6%   (割り当て CPU 0-15,22-27 / 22 論理)
 EdgeBox : 平均 5%   (割り当て CPU 16-21 / 6 論理)   状態: Running
 [P コア]  ▇▇ ▇▇ ▇▇ ...   [E コア]  ▇ ▇ ▇ ▇ ▇ ▇ ▇ ▇ ▇ ▇ ▇ ▇
 メモリ  ■■■■□□□□□□□□□□□□□□  PC 全体 64.0 GB  Windows 使用中 6.2 GB  EdgeBox 使用中 8.0 GB  空き 49.8 GB
```

| 要素 | 意味 |
|---|---|
| 棒の **緑** | その論理 CPU で EdgeBox が動いた割合 |
| 棒の **青** | Windows 自身が動いた割合 |
| 棒の **灰** | ハイパーバイザー内部の処理 |
| **枠の色** | CPU 割り当ての計画 (青 = Windows 用 / 緑 = EdgeBox 用) |
| メモリの棒 | Windows 使用中 (青) / EdgeBox 使用中 (緑) / 空き |

タスクマネージャーでは EdgeBox の分が「vmmem」という 1 つのプロセスにしか見えませんが、
ここでは **どのコアを誰が使っているか** がコア単位で分かります。
数値は `-Verify` と同じ方法 (ハイパーバイザーのカウンターからルート パーティション分を引く) で求めています。

「EdgeBox 使用中」は EdgeBox に実際に載っている物理メモリ (vmmem の実メモリ) です。
固定メモリの EdgeBox では割り当て量とほぼ同じになります (EdgeBox の内部でどれだけ使っているかは、
Windows からは見えません)。

```powershell
.\cpu-monitor.ps1                    # コマンドで開く場合
.\cpu-monitor.ps1 -IntervalMs 2000   # 2 秒ごと
```

## メモリの割り当て

CPU と同じ画面の「メモリの割り当て」で、PC 全体のメモリを Windows と EdgeBox に分けられます。

- **この PC の実メモリを読み取り**、それを超える指定や Windows 側が足りなくなる指定は
  理由を表示して適用できないようにしてあります
- 検査基準: EdgeBox は最低 4 GB (推奨 8 GB 以上) / Windows 側に最低 8 GB 残す /
  PC の半分以上を EdgeBox に渡す場合は注意を表示
- 固定メモリで設定します (動的メモリは装置向きではないため使いません)

**反映のタイミング**: メモリは EdgeBox の停止中にしか変更できません。
EdgeBox が実行中のときは「停止 → 設定 → 起動」を行うか確認が出ます (収集が数分止まります)。
停止は正常シャットダウンだけを試み、**強制電源断は行いません** (シャットダウンできない場合は
何も変更せず中止します)。

```powershell
.\cpu-partition.ps1 -MemoryGB 12              # EdgeBox 停止中なら即反映。実行中なら案内だけ
.\cpu-partition.ps1 -MemoryGB 12 -RestartVM   # 実行中でも 停止→設定→起動 で今すぐ反映
```

## 手順 (コマンドで操作する場合)

```powershell
# 0. 現状と分割案の確認 (何も変更しない)
.\cpu-partition.ps1
.\cpu-partition.ps1 -HostCores 4

# 1. 適用 (例: Windows に物理 4 コアを残し、残り全部をEdgeBox へ)
.\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4
#    別の 登録名なら: -VMName "MyVM" を付ける (既定は EdgeBox)

# 2. 実測で確認 (EdgeBox の稼働中に)
.\cpu-partition.ps1 -Verify

# 3. 元に戻したくなったら
.\cpu-partition.ps1 -Undo
```

- 適用時、EdgeBox のプロセッサ数は割り当てコア数と 1:1 になるよう自動調整されます
  (EdgeBox 停止中のみ変更可能。実行中なら注意表示のうえ次回に持ち越し)
- 分割の変更はいつでも可能です: 新しい指定で `-Apply` し直すだけ (runtime は即時反映)

### P/E コア混成 CPU (Intel 12 世代以降) の場合

混成 CPU では「コア数」指定が曖昧になるため、論理 CPU 番号での明示指定を求めます:

```powershell
# 例: P コア 8C16T + E コア 8C の場合 (論理 0-15 = P、16-23 = E)
#     メイン業務が重い → Windows に P コアを厚く、軽い常駐系の EdgeBox は E コアで十分
.\cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-15" -GuestLps "16-23"
```

番号と P/E の対応はタスクマネージャー (パフォーマンス → CPU → 論理プロセッサ表示) か、
`tools\CpuGroups.exe GetCpuTopology` で確認できます。
なお full モードの minroot は「先頭から N 個」方式のため、Windows 側は必ず論理 0 始まりの
連番になります (P コアがWindows 側に来る配置)。

## 実測 (-Verify) の見方

実機での例 (i7-14700 / Windows = CPU 0-15,22-27 / EdgeBox = CPU 16-21):

```
  現在の固定: vmmem(PID 5900) = CPU 16-21  ← OS が保証する実行可能範囲

 CPU 割り当て       EdgeBox実行%   Windows実行%      HV内部%
   8 Windows 用           0.0            1.0          1.0
  10 Windows 用           0.0            2.0          0.0
  16 EdgeBox 用          11.0           13.0         11.0
  17 EdgeBox 用           2.0            4.0          3.0
  20 EdgeBox 用           6.0            7.0          6.0
  26 Windows 用           0.0            2.0          0.0

 EdgeBox の CPU 実行のうち、計画どおりEdgeBox 用コア上で実行された割合: 100%
 → 分割は効いています。
 (参考) Windows 自身の実行合計: 52% / EdgeBox の実行合計: 30%
```

| 列 | 意味 |
|---|---|
| **現在の固定** | vmmem に設定されている実行可能な論理 CPU。**これがいちばん確実な答え**で、Windows のスケジューラはこの範囲外でスレッドを走らせない |
| **EdgeBox実行%** | その論理 CPU で EdgeBox のEdgeBoxコードが動いた割合 |
| **Windows実行%** | Windows 自身 (ルート パーティション) が動いた割合 |
| **HV内部%** | ハイパーバイザー自身の処理 (数 % なら正常) |

- **EdgeBox実行%** がEdgeBox 用コアに集中していれば分割は効いています。
  判定はこの列だけで行います (Windows 用コアがすべて 0.0 なら 100%)

> **「Windows実行%」がEdgeBox 用コアで高くても異常ではありません。**
> 上の例では Windows の実行 52% のうち 37% がEdgeBox 用コア (16-21) に出ています。
> 理由は 2 つあり、どちらも想定内です。
>
> 1. **EdgeBox のための仕事**: EdgeBox の I/O は最終的にWindows 側が処理します。上の例では
>    コアごとに EdgeBox実行% と Windows実行% がきれいに連動し (比はほぼ 1:1.2)、
>    EdgeBox が動いていないコアでは Windows 実行もほぼゼロです。EdgeBox の稼働に付随する
>    処理だと分かります
> 2. **E コアの性質**: Windows は既定で軽い背景処理を E コアへ回します
>    (ハイブリッド CPU のスケジューリング方針)
>
> runtime モードは「EdgeBox を専用コアへ閉じ込める」ものであって、
> 「そのコアから Windows を締め出す」ものではありません。
> 締め出したい場合が **full モード (minroot)** の出番です。
> なお「HV内部%」が EdgeBox実行% と同程度出るのは、EdgeBox の I/O が多い構成では普通です。

> **なぜ Windows 実行を分けて数えるのか**
> Hyper-V を有効にした Windows は、素のハードウェア上ではなく
> **ルート パーティション**として動きます。そのためハイパーバイザーの
> 論理プロセッサ カウンター `% Guest Run Time` には、EdgeBox だけでなく
> **Windows 自身の実行も含まれます**。ここを引き算しないと、Windows の処理まで
> 「EdgeBox がはみ出している」と誤判定します (v1 の -Verify はこの誤りがありました)。
> ルートプロセッサは論理 CPU と 1:1 で固定され移動しないため、
> `EdgeBox の実行 = LP の Guest − 同番号のルート VP の Guest` で正しく分離できます。

## トラブルシューティング

### 最初につまずく点: 「デジタル署名されていません」で実行できない

PowerShell の実行ポリシーによる拒否で、スクリプトの不具合ではありません。
原因は次のどちらかです。

```powershell
Get-ExecutionPolicy -List                                    # 適用中のポリシーを確認
Get-Item .\cpu-console.ps1 -Stream Zone.Identifier            # 表示されればネット由来のブロック有り
```

| 原因 | 対処 |
|---|---|
| ZIP でダウンロードしたファイルにブロック印 (Mark of the Web) が付いている | `Get-ChildItem C:\double-os-boot -Recurse | Unblock-File` で解除 (`setup.cmd` は自動で実行します) |
| 実行ポリシーが Restricted / AllSigned | 都度回避: `powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-console.ps1`  /  恒久設定: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |

いずれの場合も **`setup.cmd` から始めれば回避できます** (ブロック解除と Bypass 起動を代行)。
`setup.cmd` が作るデスクトップアイコンも Bypass 付きで登録されるため、以後は問題になりません。

### その他

| 症状 | 対処 |
|---|---|
| `-Verify` でEdgeBox実行がWindows 用コアに出る | `-Apply` 後に EdgeBox を再起動したか確認 → 自動タスク `CpuPartition-Pin` の登録を `Get-ScheduledTask` で確認 → だめなら再度 `-Apply` |
| full 第 2 段階で「反映されていません」 | 再起動したか確認。再起動済みなら、その PC では minroot が効かないため `-Undo` して runtime モードへ |
| CPU グループ作成に失敗する | EdgeBox を停止して再実行 (`Stop-VM <登録名>`)。それでも失敗する場合はクライアント版の制限 — 準分割のまま運用可 |
| EdgeBox の動きが悪くなった | 割り当てすぎ/細すぎを疑う。Windows 側は最低でも物理 2 コア (推奨 4 コア以上) 残す — EdgeBox のディスク/ネットワーク処理はWindows 側コアで動くため、Windows を細くしすぎると EdgeBox の I/O まで遅くなる |
| 元に全部戻したい | `.\cpu-partition.ps1 -Undo` → 再起動 |
| 「タスク XML に、書式設定が正しくない値または範囲外の値が含まれています」 | 自動タスクの登録形式が環境に合わないケース。現在は**機能の多い順に組み合わせを試して必ず登録する**ようにしてあるため、この失敗では止まりません。代わりに「EdgeBox 起動時の即時反映は不可」等の注記が出た場合は、その分だけ反映の速さが落ちるだけで、割り当て自体は効きます |

### 万一の復旧 (full モードの設定を手で消す)

full モードの設定で問題が出ても Windows 自体は普通に起動します (最悪でも Hyper-V が
起動しないだけ)。手動で戻す場合は管理者コマンドプロンプトで:

```
bcdedit /deletevalue hypervisorschedulertype
bcdedit /deletevalue hypervisorrootproc
```

Windows が起動できない場合 (通常起きません) は、回復環境 (WinRE) の
コマンドプロンプトから同じコマンドを実行してください。

## 設定・記録ファイル (すべてこのフォルダ内、Git 管理外)

| ファイル | 内容 |
|---|---|
| `cpu-partition.json` | 適用済みの分割計画 (自動タスクが参照) |
| `cpu-topology.json` | 検出したコア構成の控え (minroot でコアが見えなくなったとき表示に使う) |
| `cpu-partition-log.txt` | 自動適用の記録 (直近 200 行) |
| `cpu-apps.json` | アプリのコア割り当て (自動タスクが参照) |
| `cpu-apps-log.txt` | アプリ固定の記録 (直近 200 行) |
| `tools\CpuGroups.exe` | full モード用の Microsoft 公式ツール (任意) |

なお `setup.cmd` / `console.cmd` は、PowerShell の実行ポリシーに関係なく
コンソールを開くための入口です (中身は cpu-console.ps1 を Bypass で起動するだけ)。

削除して元に戻す場合は、先に `.\cpu-partition.ps1 -Undo` を実行してから
フォルダごと削除してください (自動タスクと bcdedit 設定が残らないように)。
