# CPU コアの分割割り当て (Windows ホスト版)

構成B (Windows ホスト + EdgeBox VM) で、**CPU コアを両 OS に分割して固定割り当て** するための
仕組みです。主構成 (Linux ホスト) が `isolcpus` + `vcpupin` で行っていることの Windows ホスト版で、
`10-cpu-partition.ps1` の 1 本で設定・実測・解除まで行います。

```
例: 8コア/16スレッドの CPU を「ホスト 4 コア / EdgeBox 4 コア」に分割

 論理CPU:  0  1  2  3  4  5  6  7 | 8  9 10 11 12 13 14 15
           └────── Windows ──────┘ └────── EdgeBox ───────┘
            メイン業務・FsBP アプリ    収集処理 (Windows の負荷の影響を受けない)
```

## なぜ「不可能」ではないのか (仕組みの正直な説明)

Windows クライアント版の Hyper-V には、コア固定の GUI も PowerShell コマンドもありません。
しかし土台のハイパーバイザーと OS には、次の 3 つの実物の機構が備わっています。

| 機構 | 何をするか | Linux での対応物 |
|---|---|---|
| **root スケジューラの実体** | クライアント版では、ゲスト VM の仮想 CPU は `vmmem` というホストプロセスのスレッドとして Windows が実行している。→ そのプロセスにコア固定 (アフィニティ) を掛ければ、**ゲストの CPU 実行そのものが物理固定される** | QEMU の vCPU スレッドへの `taskset`/`vcpupin` |
| **minroot** (`bcdedit hypervisorrootproc`) | ハイパーバイザー起動時に、**ホスト Windows 自体を先頭 N 個の論理 CPU に封じ込める**。Windows のプロセスも割り込みも残りのコアには一切載らなくなる | `isolcpus` (ホストをコアから締め出す) |
| **CPU グループ** (Microsoft 製 `CpuGroups.exe`) | VM を指定した論理 CPU 集合に固定する (ハイパーバイザー内部の HCS インターフェース) | libvirt の `<vcpupin>` |

これらを組み合わせ、環境に応じて 2 つのモードを提供します。

## 2 つのモード

### runtime モード — 再起動不要・Windows 標準構成のまま (まずこちらを推奨)

```powershell
.\10-cpu-partition.ps1 -Apply -Mode runtime -HostCores 4
```

- EdgeBox の CPU 実行 (`vmmem`) を **EdgeBox 用コアへ物理固定**
- VM のディスク/ネットワーク処理 (`vmwp`) を **ホスト用コアへ固定**
- `vmmem` の優先度を High に昇格 — Windows 側の処理が EdgeBox 用コアに
  来ても即座に押し出される (完全な立入禁止ではなく「最優先の先客」方式)
- VM の起動を Windows イベントで検知して自動再適用するタスクを登録
  (電源 ON → 自動起動の運用でも効き続ける)

**保証の強さ**: EdgeBox → ホスト用コアには載らない (物理固定)。
ホスト → EdgeBox 用コアに一瞬載ることはあるが、優先度で実効的に排除。
収集の取りこぼし対策としてはこれで十分なことが多いです。

### full モード — 完全分割 (Linux 主構成と同等。再起動 1 回 + コマンド 2 回)

```powershell
.\10-cpu-partition.ps1 -Apply -Mode full -HostCores 4   # ① 設定書き込み
Restart-Computer                                         # ② 再起動
.\10-cpu-partition.ps1 -Apply -Mode full                 # ③ 反映確認 + EdgeBox 固定
```

- ハイパーバイザーのスケジューラを **core** に切り替え (ゲストのコア割り当てを
  ハイパーバイザー自身が管理する方式。SMT 単位で分離するため安全性も高い)
- **minroot** でホスト Windows を先頭 N 論理 CPU に封じ込め
  (適用後、タスクマネージャーやシステム情報で Windows から見える CPU 数自体が減る)
- **CPU グループ** で EdgeBox を残りのコアへ固定

**保証の強さ**: 双方向とも物理分割。Windows がどれだけ暴れても EdgeBox 用コアには
構造的に到達できません (主構成の isolcpus + vcpupin と同格)。

**制約 (正直な列挙)**:
- スケジューラ変更はクライアント版 Windows では **Microsoft 公式サポート外**の構成です
  (動作実績は広く、`-Undo` で完全に既定へ戻せます。工場の専用 PC 向きの選択です)
- CPU グループの操作には Microsoft 公式配布の `CpuGroups.exe` が必要です
  (スクリプトが取得を提案します。オフライン環境では別 PC でダウンロードして
  `windows-host\tools\` に置いてください)。CPU グループは本来 Windows Server の
  機能のため、クライアント版で動かない環境もあります — その場合スクリプトは
  **minroot + 処理能力予約までの「準分割」** で止まり、どこまで効いているかを
  そのまま報告します (ホスト側の封じ込めだけでも効果の大半が得られます)
- Windows Server 2025 では `CpuGroups.exe` の不具合報告があります (本構成の対象は
  Windows 11 Pro のため通常は無関係)

### どちらを選ぶか

| | runtime | full |
|---|---|---|
| 再起動 | 不要 | 1 回 |
| Windows 標準構成 | 維持 (公式サポート内) | スケジューラ変更 (サポート外構成) |
| EdgeBox → ホスト用コア | 載らない (物理固定) | 載らない (物理固定) |
| ホスト → EdgeBox 用コア | 優先度で実効排除 | **構造的に不可能** |
| 戻し方 | `-Undo` (即時) | `-Undo` + 再起動 |

まず **runtime** で運用し、`-Verify` の実測で「ホスト他実行%」が EdgeBox 用コアに
目立って残るようなら **full** に上げる、が推奨手順です。

## 手順

```powershell
# 0. 現状と分割案の確認 (何も変更しない)
.\10-cpu-partition.ps1
.\10-cpu-partition.ps1 -HostCores 4

# 1. 適用 (例: ホストに物理 4 コアを残し、残り全部を EdgeBox へ)
.\10-cpu-partition.ps1 -Apply -Mode runtime -HostCores 4

# 2. 実測で確認 (EdgeBox が収集動作している状態で)
.\10-cpu-partition.ps1 -Verify

# 3. 元に戻したくなったら
.\10-cpu-partition.ps1 -Undo
```

- 適用時、EdgeBox の仮想プロセッサ数は割り当てコア数と 1:1 になるよう自動調整されます
  (VM 停止中のみ変更可能。実行中なら注意表示のうえ次回に持ち越し)
- 分割の変更はいつでも可能です: 新しい指定で `-Apply` し直すだけ (runtime は即時反映)

### P/E コア混成 CPU (Intel 12 世代以降) の場合

混成 CPU では「コア数」指定が曖昧になるため、論理 CPU 番号での明示指定を求めます:

```powershell
# 例: P コア 8C16T + E コア 8C の場合 (論理 0-15 = P、16-23 = E)
#     メイン業務が重い → ホストに P コアを厚く、EdgeBox は E コアで十分
.\10-cpu-partition.ps1 -Apply -Mode runtime -HostLps "0-15" -GuestLps "16-23"
```

EdgeBox (データ収集) は軽い常駐処理のため、**E コア割り当てで通常十分**です。
番号と P/E の対応はタスクマネージャー (パフォーマンス → CPU → 論理プロセッサ表示) か、
`tools\CpuGroups.exe GetCpuTopology` で確認できます。
なお full モードの minroot は「先頭から N 個」方式のため、ホスト側は必ず論理 0 始まりの
連番になります (P コアがホスト側に来る配置になり、上記の推奨と一致します)。

## 実測 (-Verify) の見方

```
 CPU 割り当て     ゲスト実行%     ホスト他実行%
   0 ホスト用           0.2            41.3
   ...
   8 EdgeBox用         96.8             0.4
   ...
 EdgeBox の CPU 実行のうち、計画どおり EdgeBox 用コア上で実行された割合: 99.2%
```

- **ゲスト実行%** が EdgeBox 用コアに集中していれば分割は効いています
- runtime モードで「ホスト他実行%」が EdgeBox 用コアに数 % 残るのは正常です
  (完全にゼロへ落としたい場合が full モードの出番)

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `-Verify` でゲスト実行がホスト用コアに出る | `-Apply` 後に VM を再起動したか確認 → 自動タスク `EdgeBox-CPU-Pin` の登録を `Get-ScheduledTask` で確認 → だめなら再度 `-Apply` |
| full 第 2 段階で「反映されていません」 | 再起動したか確認。再起動済みなら、その PC では minroot が効かないため `-Undo` して runtime モードへ |
| CPU グループ作成に失敗する | VM を停止して再実行 (`.\02-start-field-vm.ps1 -Stop`)。それでも失敗する場合はクライアント版の制限 — 準分割のまま運用可 |
| EdgeBox の動きが悪くなった | 割り当てすぎ/細すぎを疑う。ホスト側は最低でも物理 2 コア (推奨 4 コア以上) 残す — VM のディスク/ネットワーク処理はホスト側コアで動くため、ホストを細くしすぎると EdgeBox の I/O まで遅くなる |
| 元に全部戻したい | `.\10-cpu-partition.ps1 -Undo` → 再起動 |

### 万一の復旧 (full モードの設定を手で消す)

full モードの設定で問題が出ても Windows 自体は普通に起動します (最悪でも Hyper-V が
起動しないだけ)。手動で戻す場合は管理者コマンドプロンプトで:

```
bcdedit /deletevalue hypervisorschedulertype
bcdedit /deletevalue hypervisorrootproc
```

Windows が起動できない場合 (通常起きません) は、回復環境 (WinRE) の
コマンドプロンプトから同じコマンドを実行してください。

## 設定・記録ファイル (すべて windows-host\ 内、Git 管理外)

| ファイル | 内容 |
|---|---|
| `cpu-partition.json` | 適用済みの分割計画 (02 起動スクリプトと自動タスクが参照) |
| `cpu-partition-log.txt` | 自動適用の記録 (直近 200 行) |
| `tools\CpuGroups.exe` | full モード用の Microsoft 公式ツール (任意) |
