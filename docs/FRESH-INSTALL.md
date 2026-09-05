# 新規 PC への導入手順 — 何も入っていない PC から EdgeBox 同時起動まで

このシステム一式 (EdgeBox の VM 同時起動・左右モニターの自動表示・CPU コア分割・
リアルタイム監視) を、**まっさらな PC に最初から入れる**ときの手順です。
所要はおよそ 1 時間 (Windows のセットアップと Windows Update を除く)。

> 既に動いている PC の**更新**であれば、この手順は不要です。`update.cmd` をダブルクリックしてください。

## 用意するもの

| 品目 | 条件 |
|---|---|
| PC | **Windows 11 Pro** (Home は Hyper-V が無いため不可)。Intel VT-x / VT-d 対応 CPU。メモリ **16 GB 以上** (推奨 32 GB)。モニター 2 台。LAN ポート **2 つ** (1 つは工作機械のライン専用) |
| EdgeBox のディスク | 元の装置から取り外した物理ディスク (SATA / NVMe)。**無改造のまま**使います。フォーマットや初期化は絶対にしない |
| ツール一式 | 稼働中の PC の `C:\double-os-boot` を USB メモリにコピー、または GitHub から取得 (手順 ⑤) |
| ケーブル | ライン側の LAN ケーブル (EdgeBox が工作機械と話す経路) |

## 手順

### ① BIOS の設定

PC の電源を入れ、BIOS 設定画面に入ります (多くは起動直後に `Del` または `F2`)。

| 項目 | 設定 |
|---|---|
| Intel Virtualization Technology (VT-x) | **有効** |
| VT-d | **有効** |
| Fast Boot | **無効** (有効だと F8 の起動デバイス選択が使えず、切り分けができなくなる) |
| 起動順序 | **Windows のディスクを先頭** (EdgeBox のディスクを先頭にすると EdgeBox が素で起動してしまう) |

### ② Windows 11 Pro のセットアップ

通常どおりセットアップし、**ローカルの管理者アカウント**で使う想定です。Windows Update を済ませて再起動しておきます。

### ③ EdgeBox のディスクを取り付ける

PC の電源を切り、EdgeBox のディスクを取り付けて起動します。**Windows でそのディスクに触らないこと**
(「ディスクの初期化」を求められても**キャンセル**。フォーマットもしない)。

管理者の PowerShell (スタートボタン右クリック →『ターミナル (管理者)』) で:

```powershell
Get-Disk | Format-Table Number, FriendlyName, Size, OperationalStatus, PartitionStyle
```

**確認**: EdgeBox のディスクが見えていること (番号を控える。多くは `0` か `1`)。Windows 側ではなく EdgeBox 側の型番であることを FriendlyName で確かめる。

### ④ Hyper-V を有効にする

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

再起動を求められたら再起動します。

**確認**: 再起動後、スタートメニューに「Hyper-V マネージャー」がある。

### ⑤ ツール一式を `C:\double-os-boot` に置く

どちらかの方法で。

**方法 A: 稼働中の PC からコピー (工場ではこちらが確実)**

稼働中の PC の `C:\double-os-boot` を USB メモリで丸ごと持ってきて、新しい PC の `C:\double-os-boot` に置きます。
そのあと、**前の PC の固有情報を必ず消します** (残っていると、前の PC のディスク番号・コア構成・表示設定をそのまま使ってしまいます):

```powershell
Get-ChildItem C:\double-os-boot -Recurse -File -Include *.json,*.conf,*.xml,*.ico,*.vbs,*.flag,*-log.txt,display-status.txt,display-error.txt | Remove-Item -Force
Remove-Item C:\double-os-boot\windows-cpu-partition\tools -Recurse -Force -ErrorAction SilentlyContinue
```

**方法 B: GitHub から取得**

`C:\double-os-boot` フォルダーを作り、そこに更新スクリプトだけを置いて実行すると、残りを取りに行きます:

```powershell
New-Item -ItemType Directory -Path C:\double-os-boot -Force | Out-Null
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Mitsunori0717/double-os-boot/claude/windows-linux-dual-boot-lwgj28/update.ps1" -OutFile C:\double-os-boot\update.ps1
```

### ⑥ 最新化とブロック解除

```powershell
C:\double-os-boot\update.cmd
```

(方法 B の直後は `powershell -NoProfile -ExecutionPolicy Bypass -File C:\double-os-boot\update.ps1` で実行。`update.cmd` はこれで取得されます)

**確認**: 「更新しました (N 件)」。以後、ツールの更新はいつでも `update.cmd` のダブルクリックで済みます。

### ⑦ ライン側 LAN ポートの名前を控える

ライン側の LAN ケーブルを挿してから:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed
```

**Status が Up** のうち、ライン側のものの **Name** (例: `イーサネット 2`) を控えます。
もう一方 (事務所 LAN / インターネット側) と取り違えないこと。

### ⑧ EdgeBox の VM を作って起動する

```powershell
cd C:\double-os-boot\windows-host
.\00-field-launcher.ps1 -NetAdapterName "<⑦で控えた Name>"
```

自動で次が進みます。EdgeBox のディスクが 1 台だけなら候補として表示され、確認を求められます (`y`)。

1. ⑦ の LAN ポートに外部スイッチ `EdgeBox-External` を作成
2. VM『EdgeBox』を作成 (6 仮想プロセッサ / 8 GB / EdgeBox のディスクを無改造で接続)
3. 起動してコンソール窓を表示

> ⚠️ 起動画面で **Ctrl キーを押しっぱなしにしない**こと (機種によってはファクトリーリセットが選ばれます)。

**確認**: コンソール窓に EdgeBox の起動画面が出て、数分で起動が完了する。

> 「外部スイッチがありません」と出た場合は `-NetAdapterName` の指定漏れです。
> 工作機械から到達できない VM を作らないよう、わざと止まるようにしてあります。

### ⑨ EdgeBox の管理画面につなぐ

```powershell
Get-VMNetworkAdapter -VMName EdgeBox | Select-Object -ExpandProperty IPAddresses
```

表示された IP (例: `192.168.0.205`) をブラウザで開き、管理画面が出ることを確認します。
IP は EdgeBox 側の設定で決まるため、前の PC と同じディスクなら通常は同じ IP です。

Windows 側の EdgeBox 専用アプリをインストールし、接続先にこの IP を設定します。

### ⑩ 起動時の自動化とアイコンを登録する

```powershell
cd C:\double-os-boot\windows-host
.\03-field-display-kiosk.ps1 -Install   # ログオン時に 左=EdgeBox コンソール / 右=管理画面 を自動表示 + VM の自動起動
.\00-field-launcher.ps1 -Setup           # 『EdgeBox 起動』アイコン
.\08-settings-console.ps1 -Setup         # 『EdgeBox設定』アイコン (表示 URL・自動サインイン等)
.\05-shutdown-all.ps1 -Setup             # 『全部シャットダウン』アイコン
powercfg /h off                          # 高速スタートアップ無効 (電源 ON での自動起動を確実にする)
```

右画面の URL が ⑨ の IP と違う場合は、『EdgeBox設定』の [画面表示] タブで直します。

任意 (使うなら):

```powershell
.\06-auto-logon.ps1 -Setup               # サインイン画面を省略 (電源 ON で直接デスクトップへ)
.\04-reboot-to-field-native.ps1 -Setup   # 『EdgeBox 単独起動』アイコン (切り分け用。UEFI の起動項目を選ぶ)
.\07-boot-appearance.ps1                 # 起動時の見た目を黒でそろえる
```

**確認**: `.\03-field-display-kiosk.ps1` を引数なしで実行すると、今すぐ左右の画面に表示される。

### ⑪ CPU コア分割を入れる

エクスプローラーで `C:\double-os-boot\windows-cpu-partition\setup.cmd` を**ダブルクリック**。
デスクトップとスタートメニューに『CPU割り当て』『EdgeBox 監視』ができます。

『CPU割り当て』を開き:

1. 対象の VM が **EdgeBox** になっていることを確認
2. かんたん設定の **「P コア = Windows / E コア = EdgeBox (推奨)」** を押す
   (P/E の無い CPU では「EdgeBox は最低数だけ」)
3. 検査結果が「適用できます」であることを確認して **[この内容で適用]**

続けて、管理者の PowerShell で撤退手順の予行と実測:

```powershell
cd C:\double-os-boot\windows-cpu-partition
.\cpu-partition.ps1 -SelfTest             # 「予行 合格 (10/10)」
.\cpu-partition.ps1 -Verify -Seconds 30   # 「分割は効いています」/ 割合 95% 以上
```

### ⑫ メモリを確認する

『CPU割り当て』の下の「メモリの割り当て」欄で、EdgeBox が **8 GB** になっていることを確認します。
通常はこのままで問題ありません (変えるのは、管理画面が重い等の症状が出てからで十分)。

### ⑬ 再起動して総合確認

PC を再起動し、サインイン後 5 分待ってから確認します。

| 確認 | 期待 |
|---|---|
| VM が勝手に起動し、左に EdgeBox のコンソール、右に管理画面 | 出ている |
| `.\cpu-partition.ps1 -Verify -Seconds 30` | 「自動タスク: Ready / 前回実行 〈再起動後の時刻〉 (成功)」、割合 95% 以上 |
| 『EdgeBox 監視』 | 緑の棒が EdgeBox 用コア (緑枠) だけに出る |

### ⑭ 収集の継続確認 (最重要)

翌日と数日後に、EdgeBox の管理画面でデータの欠落・遅延がないか確認します。
**設備が動き続けることが、本当の合格条件です。**

## 困ったとき・戻し方

| 状況 | 操作 |
|---|---|
| CPU 分割を全部やめる | `.\cpu-partition.ps1 -Undo` (即時・再起動不要) |
| VM が「別のプロセスが使用中」(0x80070020) で起動しない | `.\02-start-field-vm.ps1 -Repair` |
| 画面が黒いまま操作できない | `fix-black-screen.cmd` をダブルクリック (管理者にしない) |
| EdgeBox を素の装置として起動して切り分けたい | 再起動 → F8 → EdgeBox のディスクを選択 (VM は残したままで可。**両方から同時に起動しない**) |
| 完全に導入前へ戻す | `Remove-VM EdgeBox -Force` → `Set-Disk -Number <番号> -IsOffline $false`。ディスクは無改造なので、これだけで元に戻る |

詳しい検証の考え方は [VERIFICATION.md](VERIFICATION.md)、各機能の説明は
[windows-host/README.md](../windows-host/README.md) と
[windows-cpu-partition/README.md](../windows-cpu-partition/README.md) を参照してください。
