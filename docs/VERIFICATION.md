# 検証手順書 — 未検証部分をどう確かめるか

実装済みだが実機で確認していない部分について、**稼働中の収集を止めない順序**で
検証する手順です。段階が上がるほど影響が大きくなるので、上から順に行ってください。

各段階に **合格基準** と **戻し方** を明記しています。戻し方が確認できない段階には進まないでください。

| 段階 | 内容 | 収集への影響 | 所要 |
|---|---|---|---|
| 0 | 現状の記録 (ベースライン) | なし | 10分 |
| 1 | CPU 分割 runtime モード | なし (可逆・稼働中に適用可) | 30分 |
| 2 | アプリ単位のコア割り当て | なし (テスト用アプリで先に確認) | 20分 |
| 3 | CPU 分割 full モード | **PC 再起動が必要** | 1時間 + 経過観察 |
| 4 | 主構成 (Linux ホスト) | **別マシンが必要** | 1〜2日 |

## 実機での到達点 (2026-08 時点)

| 項目 | 状態 |
|---|---|
| 導入 (`update.cmd` / `setup.cmd` / 実行ポリシー回避) | ✅ 確認済み |
| 設定コンソール (GUI) の表示・タイル選択・プリセット | ✅ 確認済み |
| `-Apply -Mode runtime` の適用 | ✅ 確認済み |
| `-Verify` の実測 (VM 実行が計画コアに 100%) | ✅ 確認済み |
| 自動タスク `CpuPartition-Pin` の登録 | ✅ 確認済み |
| **`-Undo` で戻せること** | ⬜ **未確認 (最優先)** |
| **VM 再起動後も効くこと** (1-4) | ⬜ 未確認 |
| **Windows 再起動後も効くこと** (1-5) | ⬜ 未確認 |
| **収集が止まらないこと** (1-3) | ⬜ 未確認 (24時間の経過観察) |
| 混雑時間帯でもコアが足りること (1-6) | ⬜ 未確認 |
| アプリ単位の割り当て (`cpu-apps.ps1`) | ⬜ 未確認 (段階 2) |
| full モード (minroot) | ⬜ 未確認 (段階 3。必要になったときだけ) |

> **未確認 = 動かないという意味ではありません。**「実機で確かめていない」という意味です。
> ただし工場設備では、**確かめていないものは動かないものとして扱う**のが安全です。

---

## 段階 0: 現状の記録 (ベースライン)

変更前の状態を控えます。何かおかしくなったとき「元がどうだったか」が分からないと
切り分けができません。

```powershell
cd C:\double-os-boot\windows-cpu-partition

# 1. CPU 構成と現在の割り当て状況
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -VMName FIELDsystem > baseline-status.txt

# 2. 分割なしの状態での実測 (30秒採取)
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -VMName FIELDsystem -Verify -Seconds 30 > baseline-verify.txt

# 3. VM の設定
Get-VM FIELDsystem | Format-List Name, State, Uptime, ProcessorCount, MemoryAssigned > baseline-vm.txt
Get-VMProcessor -VMName FIELDsystem | Format-List * >> baseline-vm.txt
```

**合格基準**: 3 つのファイルが作成され、`baseline-verify.txt` に各 CPU の
「VM実行%」が出ていること。

> ゲストの CPU 使用がほぼゼロだと判定できません。その場合は **収集が忙しい時間帯**に
> 採り直すか、`-Seconds 60` で長めに採取してください。ここで数値が出ないなら、
> 段階 1 の効果も測れません。

---

## 段階 1: CPU 分割 runtime モード

**稼働中の VM にそのまま適用できます。再起動不要・`-Undo` で即座に戻せます。**

### 1-1. 適用

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-console.ps1 -Setup -VMName FIELDsystem
```
デスクトップの『CPU割り当て』アイコンから、i7-14700 なら
**「P コア = Windows / E コア = FIELDsystem (推奨)」** を選んで [この内容で適用]。

コマンドで行う場合:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 `
  -Apply -Mode runtime -VMName FIELDsystem -HostLps "0-15" -GuestLps "16-27"
```

### 1-2. 効いているかの実測

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -VMName FIELDsystem -Verify -Seconds 30
```

**合格基準**:
- 出力冒頭の **「現在の固定: vmmem(PID …) = CPU …」が計画どおりの範囲**であること。
  これが最も確実な判定で、Windows のスケジューラはこの範囲外でスレッドを走らせない
- 「計画どおりゲスト用コア上で実行された割合」が **95% 以上**
- ゲスト用コア の「VM実行%」が、ホスト用コアより明確に高い
- ベースライン (段階 0) では分散していた実行が、割り当てコアに集中している

> **「Windows実行%」はホスト用コアで高くて当然です。**
> Hyper-V 有効時の Windows はルート パーティションとして動くため、
> ハイパーバイザーのカウンター上は Windows 自身も「ゲスト」に数えられます。
> -Verify はルート仮想プロセッサ分を引き算して VM だけを取り出しています
> (この引き算が無かった頃は、Windows の処理を「VM がはみ出している」と
> 誤判定していました)。

**70〜95% は runtime モードでは正常範囲**です (完全な締め出しは full モードの領域)。
70% 未満なら適用が効いていないので、自動タスクの登録を確認してください:
```powershell
Get-ScheduledTask -TaskName CpuPartition-Pin | Select TaskName, State
```

### 1-3. 収集が止まっていないことの確認 (最重要)

適用直後と **30分後・翌日** に、専用機の管理画面 (`https://192.168.0.205/`) で
データが継続して入っているか確認してください。

**合格基準**: 適用前後でデータの欠落・遅延がないこと。

### 1-4. VM 再起動後も効くか

```powershell
Stop-VM FIELDsystem            # 収集を止めてよいタイミングで
Start-VM FIELDsystem
Start-Sleep -Seconds 60
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -VMName FIELDsystem -Verify -Seconds 30
```

**合格基準**: 再起動後も割合が 95% 前後を維持していること
(自動タスク `CpuPartition-Pin` が効いている証拠)。

> VM を再起動すると `vmmem` は**別のプロセス (別 PID) として作り直される**ため、
> 手で入れたコア固定は必ず消えます。ここで割合が戻らない場合、自動タスクが
> 効いていないということなので、**電源を切るたびに手作業が必要な状態**になります。

### 1-5. Windows 再起動後も効くか (静かに失敗する経路)

1-4 と別に必ず行ってください。**この失敗はいちばん気付きにくい**からです。
コア分割が外れても Windows も EdgeBox も普通に動いてしまうため、
誰も気付かないまま「分割しているつもり」の運用が続きます。

```powershell
# Windows を再起動し、サインイン後 5 分ほど待ってから
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -Verify -Seconds 30
Get-ScheduledTaskInfo -TaskName CpuPartition-Pin | Select-Object TaskName, LastRunTime, LastTaskResult
Get-Content .\cpu-partition-log.txt -Tail 20
```

> ⚠️ `LastRunTime` / `LastTaskResult` は **`Get-ScheduledTaskInfo`** 側にあります。
> `Get-ScheduledTask` に `Select LastRunTime` を付けても**常に空欄**になり、
> 実際には走っていても「一度も実行されていない」ように見えます。
> (`-Verify` の出力にも自動タスクの前回実行時刻を出すようにしたので、
> 通常はそちらを見れば足ります。)

**合格基準**:
- 割合が 95% 以上に戻っていること
- `LastTaskResult` が `0` であること
- ログに再起動後の適用記録が残っていること
- **`vmmem` の PID が再起動前と変わっていること** (本当に再起動した証拠)

タスクは「起動 2 分後」「ログオン時」「VM 起動イベント」で走ります。
5 分待っても戻らない場合は、上のログに理由が出ています。

### 1-6. 混雑時間帯での余裕確認

段階 1 の測定は VM 使用率 5% 程度の時間帯で採ったものです。
**ライン稼働のピーク時**に一度採り直してください。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -VMName FIELDsystem -Verify -Seconds 60
```

**合格基準**: 「VM の実行合計」がゲスト用コアの総容量 (6 コアなら 600%) に対して
**十分な余裕がある**こと。目安として 300% (=半分) を超え続けるようなら、
ゲスト用コアを増やしてください (例: `-HostLps "0-15,24-27" -GuestLps "16-23"`)。

### 戻し方

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -Undo -VMName FIELDsystem -NoConfirm
```
即座に元へ戻ります (再起動不要)。

> ⚠️ **この戻し方こそ最初に予行しておいてください。**
> 冒頭に書いたとおり「戻し方が確認できない段階には進まない」のが本書の原則です。
> 実際に困るのは深夜や休日で、そのとき初めて `-Undo` を試すのでは遅すぎます。
>
> 予行はコマンド 1 つで行えます (収集は止まりません。所要 2 分):
>
> ```powershell
> .\cpu-partition.ps1 -SelfTest
> ```
>
> 解除 → 確認 → 再適用 → **自動タスクによる復元の確認**まで自動で行い、
> 各項目を OK / NG で判定します。**途中で失敗しても必ず元の割り当てに戻します**
> (手作業だと中断したときに分割が外れたまま残るため)。
>
> **合格基準**: 最後に「予行 合格」と表示されること。
> ここまで通れば、いつでも安全に撤退できます。

---

## 段階 2: アプリ単位のコア割り当て

**いきなり本番アプリで試さないでください。** メモ帳など無害なアプリで動作を確認してから
本番アプリに適用します。

### 2-1. テスト用アプリで確認

```powershell
notepad.exe    # メモ帳を起動しておく
```

『CPU割り当て』→ [アプリの割り当てを編集...] → [実行中のアプリから追加...] →
`notepad` を選択 → [コアを編集...] で **CPU 0-3 だけ**にチェック → [保存して適用]

確認:
```powershell
$p = Get-Process notepad
[Convert]::ToString([int64]$p.ProcessorAffinity, 2).PadLeft(28, '0')
```

**合格基準**: 右から数えて 1〜4 桁目だけが `1` (= CPU 0-3 に固定されている)。
タスクマネージャー → 詳細 → notepad.exe 右クリック → 「関係の設定」でも同じことを確認できます。

### 2-2. 起動し直しても効くか

```powershell
Stop-Process -Name notepad
notepad.exe
Start-Sleep -Seconds 70    # 自動タスクは 1 分ごとに適用し直す
$p = Get-Process notepad
[Convert]::ToString([int64]$p.ProcessorAffinity, 2).PadLeft(28, '0')
```

**合格基準**: 再度 CPU 0-3 に固定されていること
(タスク `CpuPartition-Apps` が効いている証拠)。

### 2-3. 本番アプリへの適用

FsBP クライアントアプリを [ファイルから追加...] で登録し、**Windows 側コア (P コア)** を割り当て。
優先度は業務上重要なら『高』。

**合格基準**: アプリが通常どおり動作し、上記と同じ方法で固定を確認できること。

### 戻し方

一覧からアプリを削除して [保存して適用] (その場で固定も解除されます)。または:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-apps.ps1 -Uninstall
```

---

## 段階 3: CPU 分割 full モード

**PC の再起動が必要です。稼働中の収集が止まります。計画停止の時間を確保してください。**
また、クライアント版 Windows では Microsoft 公式サポート外の構成です。

### 前提: 段階 1 で不足だと分かった場合のみ

段階 1-2 の実測で「ホスト他実行%」がゲスト用コアに目立って残り、
それが実害 (収集の取りこぼし等) につながっている場合にだけ進んでください。
**runtime で足りているなら full にする必要はありません。**

### 3-1. 復旧手順を先に控える

紙かスマホに控えてから進んでください:
```
bcdedit /deletevalue hypervisorschedulertype
bcdedit /deletevalue hypervisorrootproc
```
Windows が起動しない事態は通常起きませんが、その場合は回復環境 (WinRE) の
コマンドプロンプトから同じコマンドを実行します。

### 3-2. 第 1 段階 (設定書き込み)

『CPU割り当て』で方式を **full** に切り替えて [この内容で適用] → 再起動。

### 3-3. 第 2 段階 (反映確認)

再起動後、もう一度 [この内容で適用]。

**合格基準**:
- タスクマネージャーの CPU 表示が **ホスト側の論理 CPU 数だけ**に減っている (minroot が効いた証拠)
- `-Verify` の割合が **99% 以上**
- CPU グループが作成できた場合は「完全分割が成立しました」と表示される
  (できない場合は「準分割」で止まり、その旨が表示される — これも想定内)

### 3-4. 経過観察

**1 週間**、収集の欠落・Windows 側の不調がないか観察してください。
異常があれば即座に戻します。

### 戻し方

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cpu-partition.ps1 -Undo -VMName FIELDsystem -NoConfirm
Restart-Computer
```

---

## 段階 4: 主構成 (Linux ホスト + KVM/VFIO)

**この PC では検証できません。** 現在の構成 (Windows ホスト + 専用機 VM) とは
ホストとゲストが逆で、次の条件がすべて必要です:

- Ubuntu 24.04 を入れる**別の物理ディスク**
- **GPU 2 系統** (Windows 専有用 dGPU + Linux 用 iGPU)
- IOMMU (VT-d) が有効化できる UEFI
- モニター 2 枚

### 検証するなら

検証用の別マシン (または現行機の休止期間) を用意し、`baremetal/00-check-hardware.sh` から
順に実行します。手順は README の STEP 1〜6 のとおりです。

### 現実的な判断

**現在の運用 (FANUC 専用機 + Windows) では、主構成は使えません。**
専用機はメーカー署名付きの改造不可イメージのため、ホスト役にできないからです
(これが構成B を作った理由です)。

したがって **主構成の未検証は、現在の運用上のリスクではありません**。
将来 Linux 側が自前の Ubuntu に置き換わる場合にだけ、検証が必要になります。

---

## 検証結果の記録

各段階の結果を残しておくと、後日の切り分けが楽になります。

| 段階 | 実施日 | 結果 | 備考 |
|---|---|---|---|
| 0 ベースライン | | | |
| 1 runtime 適用 | | | 割合: __% |
| 1 VM 再起動後 | | | 割合: __% |
| 2 アプリ (テスト) | | | |
| 2 アプリ (本番) | | | |
| 3 full モード | | | 実施する/しない |
