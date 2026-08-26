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
