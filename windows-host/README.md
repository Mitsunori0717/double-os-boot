# 構成B: Windows + EdgeBox の同時起動

Linux 側が **EdgeBox** (メーカー製の専用機システム。原型は FANUC の FsBP で、署名検証付きの
改造不可イメージ) である構成です。EdgeBox は土台 (ホスト) 役にできないため、
主構成 (`baremetal/`) とは役割を反転し、**Windows を土台にして EdgeBox を Hyper-V で同時起動**します。

```
Windows 11 Pro (ネイティブ動作 = メイン業務はフルスピード)
 ├─ 左モニター : EdgeBox のコンソールを全画面で固定表示 (見張り役が常に維持)
 ├─ 右モニター : 通常の Windows デスクトップ (メイン業務・EdgeBox 専用アプリ)
 ├─ CPU        : P コア 8 + E コア 4 = Windows / E コア 8 = EdgeBox に完全分離 (windows-cpu-partition)
 └─ Hyper-V
      └─ EdgeBox
           ├─ EdgeBox の物理ディスクを無改造のまま起動 (コピー・変換なし)
           └─ 外部スイッチ経由で工場ラインの機械と通信
```

## 完成形 (電源 ON からの流れ)

1. 電源 ON → 自動サインイン (省略可)
2. CPU 分割の起動タスクが EdgeBox を E コアに固定してから EdgeBox を起動
3. 左画面に「EdgeBox 起動中」の黒い画面 (右画面は覆わない)
4. 左画面に EdgeBox のコンソールが全画面で表示される。右画面は通常のデスクトップのまま
5. 以後、左の全画面が外れても約 1 秒で戻る。自分で解除するには **ESC を 1 秒長押し** か **Alt+F11**
   (どちらも Windows 側を操作しているときに効く)。自分で解除したときは自動で戻さない (再固定は Alt+F11)
6. 左画面を一時的に Windows で使いたいときは **Ctrl+Alt+K を 1 秒長押し** でコンソールを収納 (最小化)。
   もう一度長押しすると左画面の全画面に戻る

人の操作はどこにも要りません。

## 主構成との違い

| 観点 | 主構成 (baremetal/) | この構成 (windows-host/) |
|---|---|---|
| 土台 | Linux (Ubuntu) | Windows 11 Pro |
| ネイティブ側 | Linux | **Windows (重い業務側が素で動く)** |
| CPU 分割 | isolcpus + vcpupin | **[../windows-cpu-partition/](../windows-cpu-partition/README.md)** の full モード (minroot + CPU グループ)。同格の完全分離 |
| GPU | 2 系統必要 | **1 系統でよい** (EdgeBox は画面をネットワーク経由で提供するため) |
| 切り分け | GRUB でネイティブ比較 | UEFI 起動メニュー (F8) で EdgeBox をネイティブ起動して比較 |

## 前提

- Windows 11 **Pro** (Hyper-V が必要)
- EdgeBox と工作機械の接続が **Ethernet (LAN)** であること (Hyper-V は USB 機器を EdgeBox に渡せません)
- モニター 2 枚。Windows の「メイン ディスプレイ」は右のモニターにしておく
- ⚠️ **EdgeBox イメージの仮想環境での動作はメーカーサポート外です。** ライセンスや機器認証が
  ハードウェアに紐付いている場合、起動しても機能しない可能性があります。
  ディスクは無改造なので、その場合はネイティブ起動運用に戻せます (下記)

## 導入

新規 PC への導入は **[../docs/FRESH-INSTALL.md](../docs/FRESH-INSTALL.md)** (①から順に) が最短です。
要点だけ:

```powershell
# 1. Hyper-V 有効化 (未実施の場合。要再起動)
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All

# 2. EdgeBox の作成と起動 (おまかせ。外部スイッチがまだ無い新規 PC の初回だけ -NetAdapterName を付ける)
cd C:\double-os-boot\windows-host
.\00-field-launcher.ps1 -NetAdapterName "<Get-NetAdapter の Name>"

# 3. 自動化とアイコンの登録
.\03-field-display-kiosk.ps1 -Install   # ログオン時の自動表示 + EdgeBox の自動起動
.\08-settings-console.ps1 -Setup        # 『EdgeBox設定』
.\10-restart-edgebox.ps1 -Setup         # 『EdgeBox 再起動』『EdgeBox 画面』
.\00-field-launcher.ps1 -Setup          # 『EdgeBox 起動』
.\05-shutdown-all.ps1 -Setup            # 『全部シャットダウン』
.\06-auto-logon.ps1 -Setup              # 『自動サインイン設定』(任意)
powercfg /h off                         # 高速スタートアップ無効

# 4. CPU の完全分離 (別フォルダ)
..\windows-cpu-partition\setup.cmd      # ダブルクリック → 『CPU割り当て』で [この内容で適用] → 再起動
```

`field-start.cmd` (= `00-field-launcher.ps1`) は、既存 EdgeBox の検出 → 競合の片付け →
(無ければ) 作成 → 起動 → コンソール表示 まで自動で進みます。ディスクの中身には一切触れません。
登録名が EdgeBox でなくても、EdgeBox のディスクを持つ登録を自動で見つけます。

## 画面表示 (03-field-display-kiosk.ps1)

| 画面 | 既定の動き |
|---|---|
| 左 | EdgeBox のコンソール (vmconnect) を**全画面**で表示。上部の接続バー (「localhost 上の EdgeBox」の帯) は消す |
| 右 | **通常の Windows デスクトップ** (起動中も覆わない) |
| 起動中 | 左画面だけに「EdgeBox 起動中」の黒い画面を出し、コンソールを全画面にする直前に消える |

右画面に管理画面のブラウザを出したい場合だけ、『EdgeBox設定』の [画面表示] タブで URL を入れます (空欄 = デスクトップ)。

**左画面の見張り役** (左がコンソールのとき常に動作):

1. コンソールの全画面が外れたら (最小化も含む) 約 1 秒で左画面の全画面に戻す
   (判定は「枠なしの窓がモニターを覆っているか」。最大化しただけの窓は全画面とみなさない)
2. 上部の接続バーが出てきたら消す
3. 左画面に出てきた他の窓は右画面へ移す (アプリは必ず右画面から起動する)
4. コンソール窓そのものが閉じられたら、EdgeBox が動いていれば左画面の表示を立ち上げ直す

自分で全画面を解除するには、**ESC を 1 秒長押し**するか、**Alt+F11** を押します
(Ctrl+Alt+Break を自分で押した場合も同じ扱い)。自分で解除したときは自動で戻しません。
再固定は **Alt+F11** です (キーは設定ファイルの `LeftGuardHotkey` で変更可)。

**コンソールの収納 ⇔ 全画面** (左画面を一時的に Windows で使うとき):
**Ctrl+Alt+K を 1 秒長押し**するとコンソール窓を収納 (最小化) して左画面を明け渡し、
もう一度長押しすると窓を戻して左画面の全画面に固定し直します (キーは設定ファイルの `StowHotkey` で変更可)。
収納中は見張り役が自動で戻すことはありません (Alt+F11 でも戻せます)。

> **更新後に『EdgeBox 再起動』『EdgeBox 画面』が効かない / Ctrl+Alt+K が効かないとき**:
> 旧版のアイコン用タスクは「1 時間で停止・多重起動不可」の設定で、表示処理が残す見張り役のせいで
> タスクが「実行中」のままになり、アイコンを押しても何も起きませんでした (1 時間後には見張り役ごと止められる)。
> 管理者の PowerShell で `.\10-restart-edgebox.ps1 -Setup` を一度実行するとタスクを作り直します
> (以後は表示処理のたびに設定を自動で直すので、次回からは不要)。見張り役は表示処理を
> 立ち上げ直したときに入れ替わるため、更新直後は『EdgeBox 画面』を一度押してください。

ESC 長押しの解除は、キーを離してから切り替えを送り、解除できたかを確かめて最大 4 回繰り返します
(全画面のときは本体の窓ではなく、モニターを覆っている窓を前面にしてから送る)。
それでも解除できない環境では、代わりにコンソールを収納 (最小化) して左画面を明け渡します
(案内が出ます。戻すのは Ctrl+Alt+K 長押し)。

> キーは **Windows 側を操作しているとき** (右画面のアプリやデスクトップにフォーカスがあるとき) に効きます。
> コンソールの中にキー入力が入っている間は、vmconnect がキーを EdgeBox へ渡して横取りするため、
> 見張り役からは見えません。その場合は右画面を一度クリックしてから押してください。
> 普通の ESC (短押し) は Windows のアプリでよく使うので、長押しだけを合図にしています。

全画面への切り替えは Ctrl+Alt+Break の送信で行い、送る前に映像の入力窓へキーボードフォーカスを
移します (EdgeBox の起動直後はフォーカスが別の場所にあり、効かないことがあったため)。
記録は `display-log.txt`、設定は `display-config.json` (『EdgeBox設定』で編集)。

## CPU の完全分離 (windows-cpu-partition)

CPU の分割は独立フォルダ **[../windows-cpu-partition/](../windows-cpu-partition/README.md)** が担当します
(ファイルも設定も共有しませんが、EdgeBox を起動するときだけ順番を譲ります: 下記)。

- 既定は **full モード**: minroot で Windows を CPU 0-19 (P コア 8 + E コア 4) に封じ込め、
  CPU グループで EdgeBox を CPU 20-27 (E コア 8) に固定。**両方向とも構造的に混ざりません**
- EdgeBox は E コア専用で最低 8 個。P コアは Windows 専用。Windows 側のアプリは 12 コアの中で個別指定可
- CPU グループは再起動で消えるため、起動タスクが起動のたびに作り直し、5 分ごとに確かめます
- **EdgeBox を起動する経路 (電源 ON・『EdgeBox 再起動』・『EdgeBox 画面』・手動起動) はすべて、
  起動前に CPU グループへの固定を先に行います** (実行中は固定できないため)
- 成立したかは『EdgeBox 監視』の「分離の状態」で確認できます (両方 0.0% が正常)

## ワンクリック操作 (デスクトップのアイコン)

| アイコン | 動き |
|---|---|
| **EdgeBox 起動** | おまかせ起動 (field-start.cmd と同じ) |
| **EdgeBox 再起動** | 正常シャットダウン → CPU グループに固定 → 起動 → 電源 ON と同じ画面表示。強制電源断はしない |
| **EdgeBox 画面** | 左画面にコンソールを全画面で表示 (止まっていれば固定してから起動)。自動では閉じない |
| **EdgeBox設定** | 全設定を 1 画面で: [画面表示] [自動サインイン] [起動と見た目] |
| **全部シャットダウン** | EdgeBox を正常停止してから Windows をシャットダウン |
| **自動サインイン設定** | サインイン画面の省略の設定/解除 |
| **EdgeBox 単独起動** | EdgeBox を安全停止 → 再起動して EdgeBox をネイティブ単独起動 (切り分け用。次回は自動で Windows に戻る) |
| **CPU割り当て** / **EdgeBox 監視** | windows-cpu-partition の設定コンソール / リアルタイム監視 |

> 左のコンソール窓は**既定では閉じません**。閉じてほしい場合だけ『EdgeBox設定』の [画面表示] で
> オンにできます (閉じても EdgeBox は動き続けます)。
> 万一コンソール窓が消えても EdgeBox は別物です: `Get-VM EdgeBox` が Running なら動いています。

## 更新のしかた

リポジトリ直下の **`update.cmd` をダブルクリック** (ZIP の取得・展開・上書き・ブロック解除まで自動。
Git は不要)。端末ごとの設定ファイル (display-config.json / cpu-partition.json など) は残ります。
詳しくはリポジトリ直下の README を参照。

## 画面が黒いまま操作できないとき (復旧ツール)

`fix-black-screen.cmd` をダブルクリック (または `.\99-fix-black-screen.ps1`)。
次を順に確認して直します。**管理者にしないでください** (デスクトップを通常権限で起動するため)。

1. 起動中スプラッシュ / 黒背景の残骸を閉じる (必要な場面だけ自動で昇格します)
2. デスクトップ本体 (explorer.exe) が止まっていれば起動し直す
3. EdgeBox のコンソール窓の状態を報告 (`-CloseConsole` で閉じる。EdgeBox は動いたまま)

| 見え方 | 正体 |
|---|---|
| 全面が黒く、クリックしても何も起きない | 起動中スプラッシュの残骸、または explorer が停止 |
| 黒いがアイコンだけ消えている・窓は前面に出る | コンソール表示用の黒背景の残骸 |
| アイコンもタスクバーも無い | explorer.exe が動いていない |

## ネイティブ起動に戻す (切り分け・撤退手順)

1. EdgeBox を停止: `.\02-start-field-vm.ps1 -Stop`
2. 一時的にネイティブ起動したいだけの場合: PC を再起動し **F8** で EdgeBox のディスクを選択
   (『EdgeBox 単独起動』アイコンなら F8 連打は不要。EdgeBox の定義は残したままで共存できます。**同時に両方から起動しないこと**)
3. 完全に元へ戻す場合:
   ```powershell
   ..\windows-cpu-partition\cpu-partition.ps1 -Undo   # CPU 分割を解除 (その後 1 回再起動)
   Remove-VM EdgeBox -Force
   Set-Disk -Number <番号> -IsOffline $false
   ```
   ディスクは無改造のため、これだけで導入前の状態に戻ります。

## スクリプト一覧

| ファイル | 役割 |
|---|---|
| `field-start.cmd` / `00-field-launcher.ps1` | おまかせ起動 (検出 → 片付け → 作成 → 起動 → 表示) |
| `01-create-field-vm.ps1` | EdgeBox の作成 (物理ディスク直結・外部スイッチ) |
| `02-start-field-vm.ps1` | 起動 / 停止 / 状態 / 修復 (`-Repair`: 0x80070020 の解消) |
| `03-field-display-kiosk.ps1` | 画面表示の本体 (左の全画面・見張り役・起動中画面・ログオン時の自動表示 `-Install`) |
| `04-reboot-to-field-native.ps1` | 『EdgeBox 単独起動』(UEFI の次回のみ起動先指定) |
| `05-shutdown-all.ps1` | 『全部シャットダウン』 |
| `06-auto-logon.ps1` | サインイン画面の省略 (LSA 秘密領域に保存。平文保存はしない) |
| `07-boot-appearance.ps1` | 起動時の見た目を黒でそろえる |
| `08-settings-console.ps1` | 『EdgeBox設定』(統合設定コンソール) |
| `09-rename-to-edgebox.ps1` | 旧名称の登録を EdgeBox に改名 (CPU 分割の設定も追従) |
| `10-restart-edgebox.ps1` | 『EdgeBox 再起動』『EdgeBox 画面』 |
| `11-io-passthrough.ps1` | 入出力の素通し: メモリの固定 + LAN の直結 (SR-IOV)。引数なし = 確認のみ / `-Apply` = 適用 |
| `99-fix-black-screen.ps1` / `fix-black-screen.cmd` | 黒画面の復旧 |
| `SETUP-STEPS.md` | 手順書 (①〜⑩・運用ルール・切り分けフロー) |

## 入出力を素通しに近づける (11-io-passthrough.ps1)

CPU は完全分離で EdgeBox 専用のコアの上で直接動いています。残る「仮想化らしさ」は
メモリの割り当て方と、ディスク・LAN の入出力が Windows 側を経由することです。
このうち **メモリの固定** と **LAN の直結 (SR-IOV)** は次の 1 本で確認・適用できます。

```powershell
.\11-io-passthrough.ps1            # 現状と「あと何が必要か」を表示 (何も変えない)
.\11-io-passthrough.ps1 -Apply     # メモリ固定 + SR-IOV を適用 (EdgeBox を正常停止 → 適用 → 起動)
```

- **メモリの固定**: 動的メモリになっていれば、起動時の量で固定にします (`-MemoryGB 8` で量を指定可)
- **SR-IOV**: LAN アダプターがハードウェアで持つ分身を EdgeBox に直接渡します。有効になると
  EdgeBox の通信が Windows 側の CPU を経由しません。条件は 3 つで、確認画面に ○× で出ます:
  1. BIOS で VT-d と SR-IOV が有効 (× のときは理由と BIOS の項目名を表示)
  2. EdgeBox 用の LAN ポートのドライバーが SR-IOV 対応 (Intel I350 / X550 / I210 などのカードは対応。
     マザーボード内蔵の I225 / I226 / Realtek は非対応のことが多い)
  3. スイッチが SR-IOV 有効で作られている (`-Apply` が同じ名前・同じ設定で作り直します。
     Windows 側の固定 IP は控えて戻します)
- EdgeBox 側に対応ドライバーが無い場合は従来の経路のまま動き続けます (悪化はしません)。
  「EdgeBox が実際に直結で通信中」が ○ になれば成功です
- ディスクの直結 (NVMe をまるごと渡す) は Windows Server 専用機能のため、Pro ではできません

## 注意

- EdgeBox 稼働中、EdgeBox のディスクは Windows からオフライン (不可視) です。オンラインに
  戻すのは EdgeBox を削除・停止した後にしてください (同時アクセス防止)
- チェックポイント (スナップショット) は物理ディスクのため使えません
- EdgeBox の起動画面で **Ctrl キーを押しっぱなしにしない**こと (機種によっては
  ファクトリーリセットが選択されます)
- **GPU を増設しても EdgeBox には直結できません** (GPU 直結 = DDA は Windows Server
  専用機能)。EdgeBox は画面をネットワーク越しに提供するため EdgeBox 側に GPU は不要です
- BIOS の Fast Boot は有効にしないこと (F8 が使えなくなり、切り分けができなくなる)
