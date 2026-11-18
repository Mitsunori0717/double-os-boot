# OS全領域バックアップから別PCの隔離VMまで

## 実装済みの経路と実機未確認の範囲

1. **Linux Liveで全LBAをRAW保存**: [OFFLINE-IMAGER.md](OFFLINE-IMAGER.md)。物理ソースを読み取り専用・排他で開き、全量保存と読み戻しSHA-256を検査します。
2. **RAWをVHDXへ変換**: [VHDX-CONVERSION.md](VHDX-CONVERSION.md)。新規通常ファイルだけに出力し、QEMUの形式検査・仮想容量・論理内容比較を行います。
3. **別Windows PCに新規隔離VMを作成**: この手順。保管VHDXを直接起動せず、検証した稼働用コピーを作り、ネットワーク未接続で登録します。

コードと合成ファイル試験はありますが、実SSD取得・Hyper-V実起動・FSBP機能/ライセンス・異機種互換は未検証です。どんなPCでも復旧できる保証ではありません。ソースOS/FSBPを正常終了する保守時間、Live起動媒体、管理者権限、対応SSDが必要です。これらの停止・起動・設定変更を開発試験では実行していません。

## v1 経路の対応条件（v2 の拡張は後述）

- v1 は単一の物理パススルーディスク、単一NICの既存Hyper-V構成を対象にします。v2 は後述の単一起動ディスク＋データディスク集合に対応します。
- RAWの論理セクタサイズは512 bytes。v1 の複数ディスク、複数NIC、4KnのVHDX変換、差分VHDXチェーン、RAID/LVMのホスト側構成は拒否または別評価です。v2の複数独立ディスク集合は後述。
- 既存VM IDを新規IDにすることを明示承認する方式です。元VM ID保持が必須ならこの経路を使わず、正規Importとライセンス移行を検討してください。
- v1 はvTPM必須/不明を拒否。v2 は後述の新規vTPMを明示設定する経路のみ対応。暗号化・機器固有鍵の依存が解決していない場合も進めません。鍵そのものはログやGitに入れません。
- VM世代とSecure Boot設定は元構成から取り、未知の場合は停止します。エラー時に勝手にSecure BootをOffへ変えません。
- v1 のMACは明示的に新規または保持を選びます。v2は新規MACのみです。保持してもFSBP認証が通る保証はありません。NICは常にスイッチ未接続、MAC spoofingは有効にしません。

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

旧版の v1 profile は上記の生成コマンドで再生成してください。元媒体の `SourceSerialNumber`、`SourceSize`、`SourceLogicalSectorSize` を必須保存し、VM 作成時に VHDX manifest と照合します。

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

RAW取得・変換ログは対象/バイト数/例外/ハッシュ/使用ツールを記録します。VM側はVMRootの`recovery.events.jsonl`と`recovery-result.json`を使用します。途中失敗時は`recovery-failure.json`に工程、作成VMのID・観測状態、残存コピーを記録します。ログにライセンスキーやディスク内容を載せません。途中失敗分を成功扱いせず、同じ名前で再開/上書きしない設計です。

ハッシュとmanifestは改ざん検知の整合性資料であり電子署名ではありません。両方同時に改変された場合の真正性を保証しないため、原本と台帳は保護して別に保管してください。UEFI独自ブート情報やハードウェア依存ライセンスが原因で起動しない場合は、メーカーの復元/移行手順が必要です。


## ProfileVersion 2: Windows 11、新規 vTPM、複数ディスク

v1 の単一ディスク・非 TPM 経路は互換維持しています。v2 は **Generation 2、新しい VM ID/MAC、NIC 1 枚、起動ディスク 1 枚とデータディスク最大 7 枚**に限定します。既存 VM を変更する経路ではありません。v2 プロファイルの生成・作業者証拠については [WINDOWS-PLAN.md](WINDOWS-PLAN.md) を参照してください。

- Windows 11: 4 GiB 以上のメモリ、2 個以上の仮想 CPU、64 GiB 以上の起動仮想ディスク、Secure Boot On / MicrosoftWindows、新規 vTPM が必要です。
- ホスト CPU の Windows 11 対応は `HostWindows11CpuSupported=true` の作業者確認を要求します。ツールは対応 CPU 一覧、世代別の命令セット、ライセンス条件を自動実証していません。適切な公式要件と実機で確認してください。
- `TpmPolicy=NewLocalProtector` は新しい VM にだけ新しいローカル key protector と vTPM を作ります。**元 PC/VM の TPM 秘密、Windows Hello、TPM に結び付いた証明書・アプリ秘密は復元しません。**
- `OriginalTpmSecretsRequired=false` と `AcceptNewTpmIdentity=true` が必要です。元の TPM 秘密が必須または不明なら進めません。
- BitLocker 暗号化ディスクは `BitLockerState=Encrypted` と、対応する正規の回復キーを別保管・対象と一致確認済み・手動解除を受け入れる確認が必要です。`RecoveryKeyStoredSeparately` / `RecoveryKeyMatchesSource` / `AcceptManualUnlock` は全て true、`RecoveryUnlockPolicy=UserConsoleOnly` とします。**回復キーそのものを JSON、ログ、コマンド引数へ入力しません。** コピーした VM の画面で本人が必要時に入力します。暗号化解除成功は未保証です。
- Win10/Server の v2 は最低 2 GiB・1 CPU。TPM が不要なら `TpmPolicy=None` を指定できます。TPM や暗号化の未知情報を既定値で許可しません。
- 全ディスクの論理セクタは 512 bytes。4Kn RAW→VHDX は引き続き拒否します。

### 全ディスクを一つの静止した集合として扱う

`Sources` 配列は先頭 `Role=Boot,ControllerLocation=0`、以降 `Role=Data,ControllerLocation=1..7` です。各要素に元 RAW の `SourceImageSha256,SerialNumber,Size,LogicalSectorSize` を保持します。hash、シリアル、順序、コントローラー位置を曖昧にしません。

`SourceSetComplete=true`（全依存ディスクを含む）、`SourceSetQuiescedTogether=true`、`NoWritesDuringAcquisition=true`、`QuiescentStartUtc/QuiescentEndUtc` が必要です。InventoryCollectedUtc ≤ QuiescentStartUtc ≤ QuiescentEndUtc ≤ EvidenceRecordedUtc の時系列も検査します。OS と全依存ディスクを同じ停止区間で保持し、途中に再起動・書込みを挟まないでください。単に別々の日の検証済みイメージを集めても、DB・アプリ・起動依存の整合性は保証されません。

`SourceSetSha256` は以下の純粋関数で Sources の順序付き識別情報に結び付きます。

```powershell
Import-Module .\HyperVRecovery.psm1
Get-RecoverySourceSetHash -Sources $profile.Sources
```

セットハッシュと停止確認は**完全性の結合と作業者申告**です。署名付き証明でも、ツールが停止区間を観測し続けた証明でもありません。VHDX manifest の CreatedUtc は変換日時であり、RAW の取得日時とは区別します。

### 別ホストでの計画と作成

パスの順序は Sources の Boot→Data と一致させます。全 VHDX と manifest の原本ハッシュ、元 RAW ハッシュ、シリアル、実容量・論理セクタを照合します。全ファイルの読み取りロックを保持して検証し、全ての新規稼働コピーの読み戻し検証を終えてから VM を作ります。

```powershell
# 計画だけ。VMやキー保護機構は作らない。
.\restore-vm.ps1 -VhdxPath 'E:\Archive\os.vhdx' `
  -DataVhdxPaths @('E:\Archive\data.vhdx') `
  -ProfilePath 'E:\Archive\windows-v2-profile.json' `
  -VMName 'Windows-Recovery-01' -VMRoot 'D:\RecoveryVMs\Windows-Recovery-01'

# 運用時に内容を確認して実行。既定は作成後Off、起動には別途-StartIsolated。
.\restore-vm.ps1 -VhdxPath 'E:\Archive\os.vhdx' `
  -DataVhdxPaths @('E:\Archive\data.vhdx') `
  -ProfilePath 'E:\Archive\windows-v2-profile.json' `
  -VMName 'Windows-Recovery-01' -VMRoot 'D:\RecoveryVMs\Windows-Recovery-01' -Create
```

-Create の確認対象には新規 vTPM 設定も含みます。既存 VM、ホストの一般設定、原本 VHDX、実ディスクは変更しません。プロファイルから任意の key protector や既存 VM ID を読み込む機能はありません。

新規 VM は起動前に Off/ネットワーク未接続/物理ディスクなし/全稼働コピーの接続、Secure Boot、固定メモリ/CPU、CPU互換モード無効、各ディスクのSCSI位置、要求した vTPM が有効なことを読み返して確認します。途中失敗なら起動しません。作成済みの新規 VM や部分コピーは調査用に保持し、自動削除しません。ログにはディスク番号と処理済みバイト数を記録します。

この vTPM はローカルホスト用の新規設定です。その新 VM をさらに別ホストへ移す場合の protector 移行は別課題です。VM が Running でも Windows 起動・BitLocker解除・アプリ動作・ライセンス検証を終えた意味ではなく、BootTested/RestoreTested/LicenseValidated は false のままです。

### 実装根拠と試験範囲

- [Windows 11 の VM 要件](https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements)
- [Set-VMKeyProtector](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmkeyprotector)
- [Enable-VMTPM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/enable-vmtpm)

`tests/test-hyperv-v2.ps1` は合成ファイルと差し替えた Hyper-V 関数だけを使います。新規 key protector/vTPM コマンドの配線も mock 検査であり、開発中に実行したものではありません。実 SSD、実 Hyper-V、Windows 11 ゲスト起動、BitLocker 手動解除は実機未検証です。
