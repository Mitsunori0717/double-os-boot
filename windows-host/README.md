# 構成B: Windows ホスト + メーカー専用機 Linux の同時起動

Linux 側が **メーカー製の専用機システム**(例: FANUC EdgeBox / FsBP。署名検証付きの
改造不可イメージ)だった場合の構成です。専用機はホスト(土台)役にできないため、
主構成(`baremetal/`)とはホストとゲストを反転させます。

```
Windows 11(ホスト・ネイティブ動作 = メイン業務はフルスピード)
 ├─ モニター1: Windows のメイン業務・FsBP 専用アプリ
 ├─ モニター2: EdgeBox の管理画面(ブラウザ)/ コンソール窓
 └─ Hyper-V
      └─ EdgeBox VM
           ├─ 専用機の物理ディスクを無改造のまま起動(コピー・変換なし)
           └─ 外部スイッチ経由で工場ラインの機械と通信
```

## 主構成との違い

| 観点 | 主構成 (baremetal/) | この構成 (windows-host/) |
|---|---|---|
| ホスト | Linux (Ubuntu) | Windows 11 Pro |
| ネイティブ側 | Linux | **Windows(重い業務側が素で動く)** |
| CPU 分割 | コア単位の厳密な固定 | 標準では仮想プロセッサ数の割り当てのみ。**別口ツール ([../windows-cpu-partition/](../windows-cpu-partition/README.md)) でコア単位の固定割り当てが可能** (本構成とは独立・入れなくても本構成は完結) |
| GPU | 2系統必要 | **1系統でよい**(専用機は画面をネットワーク経由で提供するため) |
| 切り分け | GRUB でネイティブ比較 | UEFI 起動メニュー(F8)で専用機をネイティブ起動して比較 |

## 前提

- Windows 11 **Pro**(Hyper-V が必要。Home の場合は VMware Workstation 等で同様の構成が可能)
- 専用機と工作機械の接続が **Ethernet(LAN)** であること
  (Hyper-V は USB 機器を VM に渡せません。USB ドングル等が必須なら VMware を使用)
- ⚠️ **専用機イメージの VM 動作はメーカーサポート外です。** ライセンスや機器認証が
  ハードウェアに紐付いている場合、起動しても機能しない可能性があります。
  ディスクは無改造なので、その場合はネイティブ起動運用に戻してください(下記)

## 手順

```powershell
# 1. Hyper-V 有効化 (未実施の場合。要再起動)
..\alternatives\hyperv\windows\01-enable-hyperv.ps1

# 2. ディスク番号と NIC 名を確認
Get-Disk
Get-NetAdapter

# 3. VM 作成 (専用機ディスクが 0、有線 LAN が "イーサネット" の例)
#    -NetAdapterName には Get-NetAdapter の「Name」を指定 (IP アドレスでも逆引きします)
.\01-create-field-vm.ps1 -DiskNumber 0 -NetAdapterName "イーサネット"

# 4. 起動
.\02-start-field-vm.ps1
```

起動後、`Get-VMNetworkAdapter -VMName EdgeBox` で IP を確認し、
ブラウザでその IP を開けば専用機の管理画面が使えます(モニター2に全画面配置を推奨)。

Windows 側の FsBP 専用アプリの接続先にも、この IP を設定します。

## 自動起動 (PC 起動時に専用機も自動で立ち上げる)

```powershell
Set-VM -Name EdgeBox -AutomaticStartAction Start -AutomaticStartDelay 30
powercfg /h off                  # 高速スタートアップ無効 (自動起動を確実にする)
.\06-auto-logon.ps1 -Setup       # サインイン画面を省略し、電源 ON で直接デスクトップへ
```

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
2. 一時的にネイティブ起動したいだけの場合: PC を再起動し **F8** で専用機のディスクを選択
   (VM 定義は残したままで共存できます。**同時に両方から起動しないこと**)
3. 完全に元へ戻す場合:
   ```powershell
   Remove-VM EdgeBox -Force
   Set-Disk -Number <番号> -IsOffline $false
   ```
   ディスクは無改造のため、これだけで導入前の状態に戻ります。

## 注意

- VM 稼働中、専用機ディスクは Windows からオフライン(不可視)です。オンラインに
  戻すのは VM を削除・停止した後にしてください(同時アクセス防止)
- チェックポイント(スナップショット)は物理ディスクのため使えません
- 専用機の起動画面で **Ctrl キーを押しっぱなしにしない**こと(機種によっては
  ファクトリーリセットが選択されます)
- **GPU を増設しても専用機 VM には直結できません**(GPU 直結 = DDA は Windows Server
  専用機能)。専用機は画面をネットワーク越しに提供するため VM 側に GPU は不要です。
  増設 GPU はホスト Windows のメイン業務用に使うのが正解です
