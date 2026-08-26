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
