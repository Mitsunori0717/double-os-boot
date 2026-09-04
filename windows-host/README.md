# 構成B: Windows ホスト + EdgeBox の同時起動

Linux 側が **EdgeBox**(メーカー製の専用機システム。原型は FANUC の FsBP で、署名検証付きの
改造不可イメージ)である構成です。EdgeBox はホスト(土台)役にできないため、
主構成(`baremetal/`)とはホストとゲストを反転させます。

```
Windows 11(ホスト・ネイティブ動作 = メイン業務はフルスピード)
 ├─ モニター1: Windows のメイン業務・EdgeBox 専用アプリ
 ├─ モニター2: EdgeBox の管理画面(ブラウザ)/ コンソール窓
 └─ Hyper-V
      └─ EdgeBox VM
           ├─ EdgeBox の物理ディスクを無改造のまま起動(コピー・変換なし)
           └─ 外部スイッチ経由で工場ラインの機械と通信
```

## 主構成との違い

| 観点 | 主構成 (baremetal/) | この構成 (windows-host/) |
|---|---|---|
| ホスト | Linux (Ubuntu) | Windows 11 Pro |
| ネイティブ側 | Linux | **Windows(重い業務側が素で動く)** |
| CPU 分割 | コア単位の厳密な固定 | 標準では仮想プロセッサ数の割り当てのみ。**別口ツール ([../windows-cpu-partition/](../windows-cpu-partition/README.md)) でコア単位の固定割り当てが可能** (本構成とは独立・入れなくても本構成は完結) |
| GPU | 2系統必要 | **1系統でよい**(EdgeBox は画面をネットワーク経由で提供するため) |
| 切り分け | GRUB でネイティブ比較 | UEFI 起動メニュー(F8)で EdgeBox をネイティブ起動して比較 |

## 前提

- Windows 11 **Pro**(Hyper-V が必要。Home の場合は VMware Workstation 等で同様の構成が可能)
- EdgeBox と工作機械の接続が **Ethernet(LAN)** であること
  (Hyper-V は USB 機器を VM に渡せません。USB ドングル等が必須なら VMware を使用)
- ⚠️ **EdgeBox イメージの VM 動作はメーカーサポート外です。** ライセンスや機器認証が
  ハードウェアに紐付いている場合、起動しても機能しない可能性があります。
  ディスクは無改造なので、その場合はネイティブ起動運用に戻してください(下記)

## いちばん簡単な使い方: おまかせ起動 (00-field-launcher.ps1)

**`field-start.cmd` をダブルクリック**するだけで、次を全部自動でやります。

1. **既存 VM を探す** — 名前が違っても、EdgeBox のディスクを起動する VM があればそれを使う
   (旧構成の VM がそのまま活きるので作り直し不要)
2. **対象ディスクを決める** — 既存 VM / 前回の記録 / 自動検出 の順で判断
3. **起動を妨げる状態を片付ける** — 二重接続の除去、他 VM が掴んでいる接続の解除
   (停止中のみ・VM とデータは残す)、ディスクのオフライン化
4. **VM が無ければ作成する**
5. **起動してコンソールを表示する**

```powershell
.\00-field-launcher.ps1              # おまかせ起動 (field-start.cmd と同じ)
.\00-field-launcher.ps1 -Status      # 何が使われるかだけ確認 (変更しない)
.\00-field-launcher.ps1 -Setup       # デスクトップに『EdgeBox 起動』アイコンを作成
```

ディスクの中身には一切触れません。VM の作成は「VM がまったく無い場合」だけです。
細かく手順を分けて実行したい場合は、以下の個別スクリプトを使ってください。

## 手順 (個別に実行する場合)

```powershell
# 1. Hyper-V 有効化 (未実施の場合。要再起動)
..\alternatives\hyperv\windows\01-enable-hyperv.ps1

# 2. ディスク番号・NIC 名・既存スイッチを確認
Get-Disk
Get-NetAdapter
Get-VMSwitch

# 3-a. VM 作成 (既に外部スイッチがある場合はそれを指定するのが確実)
.\01-create-field-vm.ps1 -DiskNumber 0 -SwitchName "EdgeBox-External"

# 3-b. スイッチをこれから作る場合 (-NetAdapterName は Get-NetAdapter の「Name」。IP でも可)
.\01-create-field-vm.ps1 -DiskNumber 0 -NetAdapterName "イーサネット"

# 4. 起動
.\02-start-field-vm.ps1
```

> 1 枚の LAN ポートを 2 つの外部スイッチに割り当てることはできません。
> 指定した NIC が既存スイッチに使われている場合は、**そのスイッチを自動で再利用**します
> (新規作成しないため、ネットワークが切断されません)。

起動後、`Get-VMNetworkAdapter -VMName EdgeBox` で IP を確認し、
ブラウザでその IP を開けば EdgeBox の管理画面が使えます(モニター2に全画面配置を推奨)。

Windows 側の EdgeBox 専用アプリの接続先にも、この IP を設定します。

## 自動起動 (PC 起動時に EdgeBox も自動で立ち上げる)

```powershell
.\03-field-display-kiosk.ps1 -Install   # ログオン時の自動表示 + VM の自動起動 (30 秒後) を設定
powercfg /h off                  # 高速スタートアップ無効 (自動起動を確実にする)
.\06-auto-logon.ps1 -Setup       # サインイン画面を省略し、電源 ON で直接デスクトップへ
```

VM の自動起動だけを手で入れる場合: `Set-VM -Name <VM名> -AutomaticStartAction Start -AutomaticStartDelay 30`

`06-auto-logon.ps1` でロック画面とパスワード入力を省略すると、電源 ON だけで
VM 起動 → サインイン → 左右モニターへの自動表示 (`03-field-display-kiosk.ps1`) まで
人の操作なしにそろいます。アカウント名とパスワードはデスクトップの
『自動サインイン設定』アイコンからいつでも変更できます (`-Disable` で元に戻せます)。

## CPU コアの分割割り当て (任意・別口ツール)

主構成の isolcpus + vcpupin に相当するコア分割は、**独立ツール
[../windows-cpu-partition/](../windows-cpu-partition/README.md)** で行えます
(本構成のスクリプト・設定とは切り離されており、互いに干渉しません)。
EdgeBox VM に使う場合は VM 名が既定値のため、追加の指定は不要です。

導入は **`..\windows-cpu-partition\setup.cmd` をダブルクリックするだけ** で、
デスクトップに『CPU割り当て』アイコンが作られます
(管理者への昇格とファイルのブロック解除も自動。PowerShell の実行ポリシーの影響を受けません)。

P コア / E コアをタイルで選んで割り当てられ、動かない設定・矛盾した設定は
理由を表示して適用できないようになっています。コマンドで操作することもできます:

```powershell
.\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4   # 再起動不要で適用
.\cpu-partition.ps1 -Verify                             # 実測 (各コアで誰が動いたか)
```

## 画面が黒いまま操作できないとき (復旧ツール)

`fix-black-screen.cmd` をダブルクリック (または `.\99-fix-black-screen.ps1`)。
次を順に確認して直します。**管理者にしないでください** (デスクトップを通常権限で起動するため)。

1. 起動中スプラッシュ / 黒背景の残骸を閉じる (必要な場面だけ自動で昇格します)
2. デスクトップ本体 (explorer.exe) が止まっていれば起動し直す
3. EdgeBox のコンソール窓の状態を報告 (`-CloseConsole` で閉じる。VM は動いたまま)

| 見え方 | 正体 |
|---|---|
| 全面が黒く、クリックしても何も起きない | 起動中スプラッシュの残骸、または explorer が停止 |
| 黒いがアイコンだけ消えている・窓は前面に出る | コンソール表示用の黒背景の残骸 |
| アイコンもタスクバーも無い | explorer.exe が動いていない |

## ネイティブ起動に戻す(切り分け・撤退手順)

1. VM を停止: `.\02-start-field-vm.ps1 -Stop`
2. 一時的にネイティブ起動したいだけの場合: PC を再起動し **F8** で EdgeBox のディスクを選択
   (VM 定義は残したままで共存できます。**同時に両方から起動しないこと**)
3. 完全に元へ戻す場合:
   ```powershell
   Remove-VM EdgeBox -Force
   Set-Disk -Number <番号> -IsOffline $false
   ```
   ディスクは無改造のため、これだけで導入前の状態に戻ります。

## 注意

- VM 稼働中、EdgeBox のディスクは Windows からオフライン(不可視)です。オンラインに
  戻すのは VM を削除・停止した後にしてください(同時アクセス防止)
- チェックポイント(スナップショット)は物理ディスクのため使えません
- EdgeBox の起動画面で **Ctrl キーを押しっぱなしにしない**こと(機種によっては
  ファクトリーリセットが選択されます)
- **GPU を増設しても EdgeBox の VM には直結できません**(GPU 直結 = DDA は Windows Server
  専用機能)。EdgeBox は画面をネットワーク越しに提供するため VM 側に GPU は不要です。
  増設 GPU はホスト Windows のメイン業務用に使うのが正解です
