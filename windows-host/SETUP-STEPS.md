# 構成B セットアップ手順書 (①〜⑩)

対象環境: Windows 11 Pro (ディスク1=SanDisk) / EdgeBox (ディスク0=KIOXIA) /
LAN ポート5つ / 工作機械との接続は Ethernet。

| 手順 | 内容 | 完了確認 |
|---|---|---|
| ① | 後片付け: `wsl --unmount \\.\PHYSICALDRIVE0` | `Get-Disk` で両ディスクが見える |
| ② | Hyper-V 有効化: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` → 再起動 | Hyper-V マネージャーが存在 |
| ③ | リポジトリ ZIP を `C:\double-os-boot` に配置 | `windows-host\01-create-field-vm.ps1` がある |
| ④ | ライン側 LAN ポートを決めてケーブル接続、`Get-NetAdapter` で **Name** をメモ (IP からも逆引き可: `Get-NetIPAddress -AddressFamily IPv4 \| Select IPAddress,InterfaceAlias`) | Status: Up の Name を控えた |
| ⑤ | VM 作成: `.\01-create-field-vm.ps1 -DiskNumber 0 -NetAdapterName "<Name>"` (確認プロンプトで KIOXIA を確認して y)。**既に外部スイッチがある環境では `-SwitchName "<Get-VMSwitch の名前>"` を使う** | Hyper-V マネージャーに EdgeBox |
| ⑥ | 初回起動: `.\02-start-field-vm.ps1`。起動中 **Ctrl 長押し厳禁** (工場出荷リセット) | コンソールに EdgeBox の画面 |
| ⑦ | IP 確認: `Get-VMNetworkAdapter -VMName EdgeBox`。ブラウザで管理画面を開く | 管理画面が開き収集再開 |
| ⑧ | Windows 側 EdgeBox アプリの接続先に ⑦ の IP を設定 | アプリからデータが見える |
| ⑨ | 起動時の自動表示 + VM 自動起動: `.\03-field-display-kiosk.ps1 -Install` (VM の自動起動も一緒に設定される。VM 名が EdgeBox でなくても自動で見つける) | 電源ONだけで収集開始・左に EdgeBox・右に管理画面 |
| ⑩ | 予行: F8 からネイティブ起動できることを確認。撤退手順 (`Remove-VM` + `Set-Disk -IsOffline $false`) を把握 | ネイティブ起動を1回確認 |

## いちばん簡単な導入・起動 (①〜⑥をまとめて行う)

`field-start.cmd` をダブルクリックするだけで (外部スイッチがまだ無い新規 PC の初回だけは上の `-NetAdapterName` 付きで)、既存 VM の検出 → 競合の片付け →
(必要なら) VM 作成 → 起動 まで自動で進む。日常の起動もこれ 1 つで済む。

```powershell
.\00-field-launcher.ps1 -NetAdapterName "<Get-NetAdapter の Name>"   # 新規 PC の初回 (外部スイッチがまだ無い)
.\00-field-launcher.ps1 -Status   # 何が使われるかだけ確認 (変更しない)
.\00-field-launcher.ps1 -Setup    # デスクトップに『EdgeBox 起動』アイコンを作成
```

## 運用ルール

1. EdgeBox の起動画面で **Ctrl キーを押しっぱなしにしない** (Factory reset が選択される)
2. VM 運用中にディスク0を手動でオンラインに戻さない (同時アクセスによる破損防止)

## 日常運用

- 朝: PC 電源 ON → 30秒後に EdgeBox 自動起動 → 収集開始
- 夕: `.\02-start-field-vm.ps1 -Stop` → Windows をシャットダウン
- 切り分け: 問題発生時は F8 → KIOXIA を選択して EdgeBox をネイティブ起動し、再現比較

## 不具合時の切り分けフロー (Windows か / EdgeBox か / VM か)

3つの切替スイッチで層を確定する:

| スイッチ | 操作 | 意味 |
|---|---|---|
| ① EdgeBox ネイティブ起動 | 再起動 → F8 → KIOXIA を選択 | VM 層を外した素の EdgeBox (ディスク同一・無改造のため完全比較) |
| ② Hyper-V 一時停止 | `bcdedit /set hypervisorlaunchtype off` → 再起動 (復帰は `auto`) | 仮想化層ゼロの素の Windows |
| ③ 管理画面直接アクセス | ブラウザで EdgeBox の IP | アプリを介さない到達確認 |

- 収集が止まった → ①で再現するなら EdgeBox 側 (メーカーに相談可)。再現しないなら VM 層
- アプリが繋がらない → ③で開けるならアプリ/Windows 側。開けないなら EdgeBox/VM 側 → ①へ
- Windows が不調 → ②で再現するなら Windows/アプリ自体。再現しないなら Hyper-V との干渉

どの切替も可逆でデータには触れない。再起動 1〜2 回で必ずどれかの層に確定する。

## CPU の取り分保証 (任意・別口ツール)

CPU コアを Windows と EdgeBox に分割して固定割り当てできる。構成Bからは独立した
別口ツール `..\windows-cpu-partition\` として保存してある (互いに干渉しない)。
再起動不要の runtime モードと、完全分割の full モードの 2 段階。詳細はそのフォルダの README。

```powershell
cd ..\windows-cpu-partition
.\cpu-partition.ps1 -HostCores 4                      # 分割案の確認 (変更なし)
.\cpu-partition.ps1 -Apply -Mode runtime -HostCores 4 # 適用 (EdgeBox を専用コアへ固定)
.\cpu-partition.ps1 -Verify                           # 実測 (各コアで誰が動いたか)
.\cpu-partition.ps1 -Undo                             # 全解除
```

> 旧手順の `Set-VMProcessor -VMName EdgeBox -Reserve 100` は、クライアント版 Windows の
> 既定構成 (root スケジューラ) では **機能しない** ことが判明したため撤回
> (処理能力の予約・上限・重みはハイパーバイザーがスケジュールする構成でのみ有効という公式仕様)。
> 設定済みでも害はないが、保証にはなっていない。上記スクリプトが正しい代替。

## 便利機能 (手順⑨の代わり/追加)

### サブモニターへの EdgeBox 全画面自動表示 (03-field-display-kiosk.ps1)

```powershell
.\03-field-display-kiosk.ps1            # 動作確認 (今すぐ表示)
.\03-field-display-kiosk.ps1 -Install   # ログオン時の自動表示を登録 (VM の自動起動も設定)
```

既定は **左 = EdgeBox のコンソール (EdgeBox の起動画面) / 右 = 管理画面 `https://192.168.0.205/`**。
右画面の URL は『EdgeBox設定』の[画面表示]タブで変更できる (再登録は不要)。
VM 名が EdgeBox でなくても (旧名称のままでも)、EdgeBox のディスクを持つ VM を自動で見つける。

VM の起動と Web 画面の応答を待ってから、サブモニターに Edge キオスクモード (枠なし全画面) で表示する。
これと `Set-VM -AutomaticStartAction Start` の組み合わせで、電源 ON → ログオンだけで
「モニター1 = Windows / モニター2 = EdgeBox 全画面」になる。終了は Alt+F4。

コンソール表示 (console 指定) は **閉じずに残る** (既定)。閉じてほしい場合だけ『設定』の[画面表示]で
「自動で閉じる」をオンにできる (閉じても VM は動き続ける)。
全画面時に上部へ出る接続バー (「localhost 上の EdgeBox」の帯) は既定で非表示 (同じ画面で切り替え可)。

### ワンクリックで EdgeBox 単独起動 (04-reboot-to-field-native.ps1)

```powershell
.\04-reboot-to-field-native.ps1 -Setup   # 初回のみ: UEFI 起動エントリを選択・デスクトップにショートカット作成
```

以後はデスクトップの『EdgeBox 単独起動』をダブルクリック → VM を安全停止 →
再起動して EdgeBox がネイティブ単独起動する (F8 連打は不要)。
UEFI の「次回のみ起動先指定 (bootsequence)」を使うため 1 回で消費され、
**EdgeBox 利用後に次へ電源を入れると自動的に Windows に戻る** (戻し操作なし)。

### サインイン画面の省略 = 電源 ON で直接デスクトップへ (06-auto-logon.ps1)

```powershell
.\06-auto-logon.ps1 -Setup   # デスクトップに『自動サインイン設定』アイコンを作成
.\06-auto-logon.ps1          # PowerShell 上で対話設定する場合
```

ロック画面とパスワード入力を省略し、電源 ON から一気にデスクトップまで進む。
これで「電源を入れるだけ」で **VM 自動起動 → 自動サインイン → 左右モニターへの自動表示 (03)**
まで人の操作なしにそろう。スリープ・スクリーンセーバー復帰時のパスワード要求も外れる。

アカウント名とパスワードは、デスクトップの『自動サインイン設定』アイコンから
いつでも変更できる (Windows のパスワードを変えたときはここで設定し直す)。
チェックを外して保存すれば元のサインイン画面ありに戻る (`-Disable` でも同じ)。

パスワードは Windows の LSA 秘密領域に保存する (Sysinternals Autologon と同じ方式)。
レジストリへの平文保存は行わない。

> ⚠️ 電源を入れた人は誰でも Windows を操作できる状態になる。PC の設置場所が
> 管理されていることが前提。Win+L による手動ロックは今までどおり使える。

### 統合設定コンソール (08-settings-console.ps1) ← おすすめ

```powershell
.\08-settings-console.ps1 -Setup   # デスクトップに『EdgeBox設定』アイコンを作成
```

タブ切り替えで全設定を 1 画面にまとめたもの:
[画面表示] [自動サインイン] [起動と見た目]。
以後の設定変更はデスクトップの『EdgeBox設定』アイコンだけで完結する
(旧『EdgeBox表示設定』『自動サインイン設定』アイコンは自動で置き換え)。

### 起動時の見た目を黒でそろえる (07-boot-appearance.ps1)

```powershell
.\07-boot-appearance.ps1            # 設定 (-Disable で全部元に戻る)
```

ロック画面を飛ばし、サインイン画面を無地の暗色 + アカウント名非表示にし、
デスクトップの壁紙を黒一色にする。起動中スプラッシュ (03 の -Install で自動登録)
と合わせると、電源 ON から EdgeBox の画面が出るまでほぼ黒い画面でつながる。

> 注意: アカウント名を隠すため、手動サインイン時は名前も自分で入力することになる。

### 起動時「別のプロセスが使用中」(0x80070020) で失敗するとき

パススルー ディスクは「Windows からオフライン」かつ「1 つの VM だけが接続」でないと開けない。

```powershell
.\02-start-field-vm.ps1 -Repair     # 二重接続の削除・オフライン化を自動で行い、原因を表示
wsl --unmount \\.\PHYSICALDRIVE0    # WSL が掴んでいる場合 (その後 wsl --shutdown)
```

他 VM が同じディスクを使っている場合は、その VM を停止・削除してから再実行する
(旧構成の VM が残っていることが多い)。

### ワンクリックで再起動 / 左画面に表示 (10-restart-edgebox.ps1)

```powershell
.\10-restart-edgebox.ps1 -Setup   # 『EdgeBox 再起動』『EdgeBox 画面』のアイコンを作成
```

『EdgeBox 再起動』は正常シャットダウン → 起動 → 画面表示 (強制電源断はしない)。
『EdgeBox 画面』は左画面にコンソールを最大化で出し、自動では閉じない。
コンソール窓は既定では閉じない (閉じる設定にした場合も VM は動き続ける)。

### 画面が黒いまま操作できないとき (99-fix-black-screen.ps1)

```
fix-black-screen.cmd をダブルクリック   ※管理者にしないこと
```

起動中スプラッシュ・黒背景の残骸を閉じ、デスクトップ (explorer.exe) が止まっていれば
起動し直す。EdgeBox VM や CPU 割り当てには触れないため、いつ実行しても安全。

### BIOS の Fast Boot について

起動をさらに速くしたくなっても、**ASUS BIOS の Fast Boot は有効にしない**こと。
起動時のキー入力受付が省略され、切り分けに使う **F8 (起動デバイス選択) や BIOS 設定に
入れなくなる**ため、上記の切り分けフロー①が使えなくなる。
