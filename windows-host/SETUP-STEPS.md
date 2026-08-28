# 構成B セットアップ手順書 (①〜⑩)

対象環境: Windows 11 Pro (ディスク1=SanDisk) / FANUC FIELD system (ディスク0=KIOXIA) /
LAN ポート5つ / 工作機械との接続は Ethernet。

| 手順 | 内容 | 完了確認 |
|---|---|---|
| ① | 後片付け: `wsl --unmount \\.\PHYSICALDRIVE0` | `Get-Disk` で両ディスクが見える |
| ② | Hyper-V 有効化: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` → 再起動 | Hyper-V マネージャーが存在 |
| ③ | リポジトリ ZIP を `C:\double-os-boot` に配置 | `windows-host\01-create-field-vm.ps1` がある |
| ④ | ライン側 LAN ポートを決めてケーブル接続、`Get-NetAdapter` で Name をメモ | Status: Up の Name を控えた |
| ⑤ | VM 作成: `.\01-create-field-vm.ps1 -DiskNumber 0 -NetAdapterName "<Name>"` (確認プロンプトで KIOXIA を確認して y) | Hyper-V マネージャーに FIELDsystem |
| ⑥ | 初回起動: `.\02-start-field-vm.ps1`。起動中 **Ctrl 長押し厳禁** (工場出荷リセット) | コンソールに FIELD system の画面 |
| ⑦ | IP 確認: `Get-VMNetworkAdapter -VMName FIELDsystem`。ブラウザで管理画面を開く | 管理画面が開き収集再開 |
| ⑧ | Windows 側 FsBP アプリの接続先に ⑦ の IP を設定 | アプリからデータが見える |
| ⑨ | モニター2 にブラウザ全画面 + 自動起動: `Set-VM -Name FIELDsystem -AutomaticStartAction Start -AutomaticStartDelay 30` | 電源ONだけで収集開始 |
| ⑩ | 予行: F8 からネイティブ起動できることを確認。撤退手順 (`Remove-VM` + `Set-Disk -IsOffline $false`) を把握 | ネイティブ起動を1回確認 |

## 運用ルール

1. FIELD system の起動画面で **Ctrl キーを押しっぱなしにしない** (Factory reset が選択される)
2. VM 運用中にディスク0を手動でオンラインに戻さない (同時アクセスによる破損防止)

## 日常運用

- 朝: PC 電源 ON → 30秒後に FIELD system 自動起動 → 収集開始
- 夕: `.\02-start-field-vm.ps1 -Stop` → Windows をシャットダウン
- 切り分け: 問題発生時は F8 → KIOXIA を選択して FIELD system をネイティブ起動し、再現比較

## 不具合時の切り分けフロー (Windows か / FsBP か / VM か)

3つの切替スイッチで層を確定する:

| スイッチ | 操作 | 意味 |
|---|---|---|
| ① FIELD ネイティブ起動 | 再起動 → F8 → KIOXIA を選択 | VM 層を外した素の FIELD system (ディスク同一・無改造のため完全比較) |
| ② Hyper-V 一時停止 | `bcdedit /set hypervisorlaunchtype off` → 再起動 (復帰は `auto`) | 仮想化層ゼロの素の Windows |
| ③ 管理画面直接アクセス | ブラウザで FIELD の IP | アプリを介さない到達確認 |

- 収集が止まった → ①で再現するなら FsBP 側 (FANUC に相談可)。再現しないなら VM 層
- アプリが繋がらない → ③で開けるならアプリ/Windows 側。開けないなら FIELD/VM 側 → ①へ
- Windows が不調 → ②で再現するなら Windows/アプリ自体。再現しないなら Hyper-V との干渉

どの切替も可逆でデータには触れない。再起動 1〜2 回で必ずどれかの層に確定する。

## CPU の取り分保証 (任意)

物理コア固定は Windows クライアント版 Hyper-V では不可のため、代わりに処理能力の予約で保証する:

```powershell
# VM 停止中に実行。割り当て vCPU 数ぶんの処理能力を常時確保
Set-VMProcessor -VMName FIELDsystem -Reserve 100
```

## 便利機能 (手順⑨の代わり/追加)

### サブモニターへの FIELD 全画面自動表示 (03-field-display-kiosk.ps1)

```powershell
.\03-field-display-kiosk.ps1            # 動作確認 (今すぐ表示)
.\03-field-display-kiosk.ps1 -Install   # ログオン時の自動表示を登録
```

VM の起動と Web 画面の応答を待ってから、サブモニターに Edge キオスクモード (枠なし全画面) で表示する。
これと `Set-VM -AutomaticStartAction Start` の組み合わせで、電源 ON → ログオンだけで
「モニター1 = Windows / モニター2 = FIELD system 全画面」になる。終了は Alt+F4。

### ワンクリックで FIELD 単独起動 (04-reboot-to-field-native.ps1)

```powershell
.\04-reboot-to-field-native.ps1 -Setup   # 初回のみ: UEFI 起動エントリを選択・デスクトップにショートカット作成
```

以後はデスクトップの『FIELD system 単独起動』をダブルクリック → VM を安全停止 →
再起動して FIELD system がネイティブ単独起動する (F8 連打は不要)。
UEFI の「次回のみ起動先指定 (bootsequence)」を使うため 1 回で消費され、
**FIELD 利用後に次へ電源を入れると自動的に Windows に戻る** (戻し操作なし)。

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

### 起動時の見た目を黒でそろえる (07-boot-appearance.ps1)

```powershell
.\07-boot-appearance.ps1            # 設定 (-Disable で全部元に戻る)
```

ロック画面を飛ばし、サインイン画面を無地の暗色 + アカウント名非表示にし、
デスクトップの壁紙を黒一色にする。起動中スプラッシュ (03 の -Install で自動登録)
と合わせると、電源 ON から FIELD の画面が出るまでほぼ黒い画面でつながる。

> 注意: アカウント名を隠すため、手動サインイン時は名前も自分で入力することになる。

### BIOS の Fast Boot について

起動をさらに速くしたくなっても、**ASUS BIOS の Fast Boot は有効にしない**こと。
起動時のキー入力受付が省略され、切り分けに使う **F8 (起動デバイス選択) や BIOS 設定に
入れなくなる**ため、上記の切り分けフロー①が使えなくなる。
