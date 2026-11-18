# OS全領域バックアップから別PCの隔離VMまで

## 実装済みの経路と実機未確認の範囲

1. **Linux Liveで全LBAをRAW保存**: [OFFLINE-IMAGER.md](OFFLINE-IMAGER.md)。物理ソースを読み取り専用・排他で開き、全量保存と読み戻しSHA-256を検査します。
2. **RAWをVHDXへ変換**: [VHDX-CONVERSION.md](VHDX-CONVERSION.md)。新規通常ファイルだけに出力し、QEMUの形式検査・仮想容量・論理内容比較を行います。
3. **別Windows PCに新規隔離VMを作成**: この手順。保管VHDXを直接起動せず、検証した稼働用コピーを作り、ネットワーク未接続で登録します。

コードと合成ファイル試験はありますが、実SSD取得・Hyper-V実起動・FSBP機能/ライセンス・異機種互換は未検証です。どんなPCでも復旧できる保証ではありません。ソースOS/FSBPを正常終了する保守時間、Live起動媒体、管理者権限、対応SSDが必要です。これらの停止・起動・設定変更を開発試験では実行していません。

## 初版の対応条件

- 単一の物理パススルーディスク、単一NICの既存Hyper-V構成を対象にします。
- RAWの論理セクタサイズは512 bytes。4Kn、複数ディスク/NIC、差分VHDXチェーン、RAID/LVMのホスト側構成は拒否または別評価です。
- 既存VM IDを新規IDにすることを明示承認する方式です。元VM ID保持が必須ならこの経路を使わず、正規Importとライセンス移行を検討してください。
- vTPM必須/不明は拒否。暗号化・機器固有鍵の依存が解決していない場合も進めません。鍵そのものはログやGitに入れません。
- VM世代とSecure Boot設定は元構成から取り、未知の場合は停止します。エラー時に勝手にSecure BootをOffへ変えません。
- MACは明示的に新規または保持を選びます。保持してもFSBP認証が通る保証はありません。NICは常にスイッチ未接続、MAC spoofingは有効にしません。

## 容量の考え方

約1TBの元SSDなら、RAW原本1世代の保存媒体は2TBが目安です。RAW、変換VHDX、稼働用VHDXを**同じ媒体**にすべて置くと最悪約3TB＋管理/拡張余裕が必要なので4TBが安全です。別媒体に分ける場合も変換側・復旧PC側の空きを個別に確保してください。動的VHDXは将来拡張し得るため、現在のファイルサイズだけで運用余裕を見積もりません。

## 1. 元ホストの構成を保存する

管理者PowerShellで読み取り専用Inventoryを実行し、新規ファイル名で保管します。`VmInventoryComplete=false`やErrorsがあれば止めて原因を解消します。収集はVMを停止しません。

```powershell
.\storage-recovery.ps1 -Action Inventory
```

JSON出力を元ホストの台帳として別媒体へ保存します。VM世代、RAM/CPU、NIC/MAC、物理ディスク割当、Firmware/BIOS、VLAN、TPMの情報を含みますが、Hyper-Vの完全エクスポートや秘密鍵の保全ではありません。ゲストの暗号化やUEFI内の独自エントリーなど、追加確認が必要なものもあります。

## 2. 正常停止・オフライン取得・VHDX変換

[全領域取得](OFFLINE-IMAGER.md)の条件と対象識別を確認し、承認済み保守時間に元FSBPとホストを正常終了します。Live環境でRAWとmanifestを取得します。Windows側OfflineだけではVMが書込み中かもしれないため、Windows稼働中にこの物理取得を実行しません。

別PCの変換例（値は実環境に置き換える）：

```powershell
python -B .\convert_image.py --raw 'E:\Backup\edgebox.raw' --output 'D:\RecoveryArchive\edgebox.vhdx' --qemu-img 'C:\ApprovedTools\qemu-img.exe'
```

出力先の親フォルダーは事前に用意し、存在するVHDXを上書きしません。QEMUは公式プロジェクトの配布案内に従って入手・検証します。このツールはQEMUを勝手にダウンロード/インストールしません。`--allow-fixture`は合成テスト専用で、復旧VM構築側はfixture由来を受け付けません。

## 3. 復旧プロファイルを作る

元VM台帳と今回のRAWのシリアル・実容量・論理セクタ、元VMの割当先が一致する必要があります。RAWのSHA-256にプロファイルを結び付け、別イメージとの取り違えを防ぎます。

下記の承認フラグは、**新しいVM IDで問題ないことと、暗号化依存が解決済みであることを確認した場合だけ**指定してください。未指定では未確認状態となり、VM作成は拒否されます。

```powershell
Import-Module .\HyperVRecovery.psm1
$inventory = Get-Content 'E:\Backup\source-inventory.json' -Raw | ConvertFrom-Json
$raw = Get-Content 'E:\Backup\edgebox.raw.manifest.json' -Raw | ConvertFrom-Json
$profile = New-RecoveryVmProfile -Inventory $inventory -SourceVMName 'EdgeBox' `
  -SourceImageSha256 $raw.Sha256 -SourceFingerprint $raw.Metadata.Source `
  -AcceptNewVmId -MacPolicy Preserve -EncryptionDependenciesResolved
Test-RecoveryVmProfile $profile
$profile | ConvertTo-Json -Depth 12 | Set-Content 'D:\RecoveryArchive\new-recovery-profile.json' -Encoding UTF8
```

保存名は新しいものにします。同じホストに同じMACの既存VMがある場合、保持モードは拒否します。試験のために勝手に新MACへ変えて続行はしません。

## 4. 計画確認、新規VM作成、初回隔離起動

復旧先WindowsはHyper-V対応と管理者権限が必要です。空きCPU/RAMと保存先容量を事前検査します。VM名、VMRootは未使用のものを指定してください。VMRootの親ディレクトリだけを用意し、VMRoot自身は作成しません。

```powershell
# 読取り検証と計画だけ。VM/ディスク/フォルダーを作りません。
.\restore-vm.ps1 -VhdxPath 'D:\RecoveryArchive\edgebox.vhdx' `
  -ProfilePath 'D:\RecoveryArchive\new-recovery-profile.json' `
  -VMName 'EdgeBox-Recovery-01' -VMRoot 'D:\RecoveryVMs\EdgeBox-Recovery-01'

# 明示的に新規登録する。保管原本は維持し、稼働コピーだけを接続します。
# -StartIsolated を省けばVMはOffのままです。
.\restore-vm.ps1 -VhdxPath 'D:\RecoveryArchive\edgebox.vhdx' `
  -ProfilePath 'D:\RecoveryArchive\new-recovery-profile.json' `
  -VMName 'EdgeBox-Recovery-01' -VMRoot 'D:\RecoveryVMs\EdgeBox-Recovery-01' `
  -Create -StartIsolated
```

`-WhatIf`でも確認できます。実行時には対象を確認するPowerShellの承認を求めます。既存VM、既存フォルダー、保管原本、物理ディスクを上書きしません。新規VMは自動起動なし、正常シャットダウン、チェックポイント無効、スイッチ未接続に設定します。失敗時には新規のpartial/ログ/VMを自動削除せず、既存資産へ戻し操作もしません。

## 完了判定

`StartRequestedUnverified`やHyper-Vの`Running`は、OS起動・FSBP復旧成功ではありません。`BootTested`/`RestoreTested`/`LicenseValidated`はfalseのままです。コンソールでOS、FSBP画面、ライセンス、保存設定/データを確認し、必要機能の試験を行ってください。

工場ネットワークへの接続は別の確認工程です。元VM/元機器とMAC/IPを重複させず、工作機械へ意図しない通信をしない構成を確認するまで、ネットワーク隔離を解除しません。本ツールは隔離解除を実装していません。

## ログと制限

RAW取得・変換ログは対象/バイト数/例外/ハッシュ/使用ツールを記録します。VM側はVMRootの`recovery.events.jsonl`と`recovery-result.json`を使用します。ログにライセンスキーやディスク内容を載せません。途中失敗分を成功扱いせず、同じ名前で再開/上書きしない設計です。

ハッシュとmanifestは改ざん検知の整合性資料であり電子署名ではありません。両方同時に改変された場合の真正性を保証しないため、原本と台帳は保護して別に保管してください。UEFI独自ブート情報やハードウェア依存ライセンスが原因で起動しない場合は、メーカーの復元/移行手順が必要です。
