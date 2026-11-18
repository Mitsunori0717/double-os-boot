# Windows 復旧計画と隔離 VM プロファイル

この処理は JSON の適合性確認とプロファイル生成だけです。ディスク取得、停止、設定変更、VHDX のマウント、VM の作成・起動は行いません。管理者権限はこの評価自体には不要です。

## 入力

1. `WindowsRecoveryInventory.psm1` で取得した一般 Windows PC 台帳。取得方法は Windows inventory の説明を参照。
2. 既存 `offline_image.py` がオフライン・書き込み保護された元ディスクから取得した全領域 raw の `.manifest.json`。
3. 下記の作業者確認記録。稼働中台帳は、その後の正常シャットダウンを証明できません。

元 Windows を完全シャットダウンしてからオフライン取得してください。高速スタートアップによるハイブリッド終了や休止状態を正常停止と扱わないでください。このツールは電源操作や BitLocker の解除を自動実行しません。

記録は raw の SHA-256、元ディスクのシリアル・実バイト容量に結び付きます。取得元と台帳はシリアル・容量・論理セクタが一致し、同じ識別の候補が複数あれば拒否します。Windows の UniqueId と Linux の by-id は異なり得るため文字列同値を要求せず、台帳側 ID を生成プロファイルに保持します。

## 作業者確認記録のテンプレート

以下は**未確認のテンプレート**です。このままではプロファイル生成は拒否されます。確認済みの事実だけを記録してください。キー、回復パスワード、ライセンス文字列を入力する欄はありません。

```json
{
  "SchemaVersion": 1,
  "Operator": "Unconfirmed",
  "RecordedUtc": "Unconfirmed",
  "SourceImageSha256": "Unconfirmed",
  "SerialNumber": "Unconfirmed",
  "Size": 0,
  "FullShutdownVerified": false,
  "FastStartupNotUsed": false,
  "NotHibernated": false,
  "AllApplicationDataOnSourceDisk": false,
  "NoExternalStorageDependencies": false,
  "TpmDependencyAbsent": false,
  "IdentityChangeAccepted": false
}
```

- `RecordedUtc`: ISO 8601 UTC。台帳取得以降、確認記録時の日時。
- `AllApplicationDataOnSourceDisk`: インストール済みアプリ、設定、ユーザーデータが対象ディスクに含まれることを確認。別ディスクのアプリ・データ・DB、外部保存先があれば true にしない。
- `NoExternalStorageDependencies`: 別ボリューム、NAS、クラウドのみのファイル、外部データへの依存がないことを確認。未確認は false のまま。
- `TpmDependencyAbsent`: 元 TPM/ハードウェアの秘密に依存する起動・アプリを必要としないことを確認。単に BitLocker が Off という理由では true にしない。
- `IdentityChangeAccepted`: 新しい VM ID と MAC を使うことを受け入れる。ライセンス再認証が不要と保証する意味ではない。

作業者記録は署名付き証明ではなく自己申告です。依存関係の完全性をプログラムが証明したことにはなりません。

## 実行例

リポジトリの `storage-recovery` ディレクトリで実行します。パスは実際の保存先に置き換え、新規の出力名を使います。

```powershell
.\windows-recovery.ps1 -Action Assess -InventoryPath E:\Backup\windows-inventory.json -RawManifestPath E:\Backup\windows.raw.manifest.json -EvidencePath E:\Backup\operator-evidence.json -OutputPath E:\Backup\assessment.json

.\windows-recovery.ps1 -Action Profile -InventoryPath E:\Backup\windows-inventory.json -RawManifestPath E:\Backup\windows.raw.manifest.json -EvidencePath E:\Backup\operator-evidence.json -OutputPath E:\Backup\windows-vm-profile.json
```

モジュールを直接呼ぶ場合:

```powershell
Import-Module .\WindowsRecoveryPlan.psm1 -Force
$i = Get-Content -LiteralPath E:\Backup\windows-inventory.json -Raw | ConvertFrom-Json
$m = Get-Content -LiteralPath E:\Backup\windows.raw.manifest.json -Raw | ConvertFrom-Json
$e = Get-Content -LiteralPath E:\Backup\operator-evidence.json -Raw | ConvertFrom-Json
Test-WindowsRecoverySuitability -Inventory $i -RawManifest $m -Evidence $e
$p = New-WindowsRecoveryVmProfile -Inventory $i -RawManifest $m -Evidence $e -MemoryStartupBytes 4GB -ProcessorCount 2
$p | ConvertTo-Json -Depth 8
```

メモリは最低 2 GB、既定 4 GB。プロファイル生成でハードウェア資源を予約しません。実際の別ホスト側資源確認と隔離 VM 作成には既存 `HyperVRecovery.psm1` を使用します。生成されたアーカイブ VHDX を直接起動用にマウントせず、既存復旧機能が作る新規作業コピーを使います。

## 結果の意味

- `State=PlanOnly`: 評価のみ。
- `BackupPreservationSupported`: 全領域 raw の manifest が保全経路の必要条件を満たす。**取得実行の許可、ファイルの存在・読み戻し検証、復旧成功ではありません。** 評価時は raw を再ハッシュしません。
- `RecoveryProfileAllowed`: 入力と作業者記録がこの実装の VM 計画条件を満たす。起動成功・アプリ完全動作・再認証成功ではありません。
- `Reasons` / `PreservationReasons`: 拒否条件。未知情報を既定値で許可しません。
- `BootTested=false`, `RestoreTested=false`, `LicenseValidated=false`, `DataCompletenessVerified=false`: 未検証のまま維持します。

後続の変換は元 raw の実ハッシュを検証し、VM 復旧側は VHDX の実ハッシュと raw 由来ハッシュの結び付きを検証します。manifest は署名されていないため、ファイルと manifest を一緒に改ざんされた場合の真正性は保証できません。

## SchemaVersion 1 の互換経路

- x64 Windows 10 build 19044 / 19045、ProductType 1。
- x64 Windows Server 2016 / 2019 / 2022 build 14393 / 17763 / 20348、ProductType 3。
- OS Version は BuildNumber と一致する `10.0.<build>`。
- UEFI + GPT は Generation 2。Secure Boot 状態を確認し、On の場合は MicrosoftWindows テンプレート。
- BIOS + MBR は Generation 1。
- 単一ディスクで現在の Windows の起動と全アプリ・データが完結。複数起動依存ディスク、別ディスク上の EFI/System、未知の依存は拒否。
- 論理セクタ 512 のみ。4Kn raw の保全評価は可能だが VHDX プロファイルは拒否。
- 暗号化状態が既知で、列挙されたボリュームが Known / FullyDecrypted / Off / Unlocked / EncryptionMethod None / 0%、OS ボリュームのカバレッジが確認できること。
- Windows 11 は SchemaVersion 1 では拒否。新しい SchemaVersion 2 の条件は後述。
- ドメインコントローラー、ARM、未知の OS/build、未知・暗号化済みボリュームは自動プロファイル対象外。

この一覧は本ツールの実装対象であり、Microsoft のサポート期間やセキュリティ更新提供を保証しません。物理ハードウェアへの直接書き戻しはこの経路では実装していません。

OS と同じディスクにあるインストール済みアプリ・設定・ユーザーデータは全セクタ取得に含まれます。ただしドライバー、TPM、OEM/機器ライセンス、クラウド専用ファイル、別ディスク・NAS のデータはディスク内容だけでは再現できません。元の稼働 PC は変更せず、隔離されたコピーで実機復旧試験が必要です。

Generation 1 の起動ディスクは2TB超を拒否します。これは保全自体の容量上限ではなく、現Hyper-V起動経路の制限です。[Microsoft 世代比較](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v)


## SchemaVersion 2: Windows 11・BitLocker・複数ディスク

この経路も JSON の評価・プロファイル生成だけです。実機の停止、読み取り取得、解除、VM 作成は行いません。全依存ディスクを同じ正常停止期間に取得したことを作業者が確認します。独立したディスク集合の完全性はソフトが自動証明したものではありません。

- 対象: x64 Windows 10 build 19044/19045、Windows 11 build 22000/22621/22631/26100/26200、Server build 14393/17763/20348/26100。Version は `10.0.<build>` と一致。これはツールの入力適合範囲であり、Microsoft のサポート期間や実機起動保証ではありません。
- v2 は UEFI/GPT、Generation 2、512-byte 論理セクタ、1〜8 ディスク。起動候補が複数なら拒否。最初の raw は唯一の EFI/起動候補を含むディスク、残りは接続順の Data。OS とデータが別ディスクの場合も全依存を含めます。
- SATA/NVMe/USB/SCSI/ATA/SAS の基本ディスク構成を作業者が独立確認します。RAID、Storage Spaces、iSCSI、Virtual、File Backed Virtual、未知は拒否。Dynamic/スパン構成を通常ディスクと推定しません。
- Windows 11 は 4 GB 以上、2 CPU 以上、起動ディスク 64 GB 以上、Secure Boot On/MicrosoftWindows、新 vTPM、移行先 CPU 対応の明示確認を要求します。CPU 対応は作業者の申告であり実測ではありません。
- BitLocker は既知の FullyEncrypted/100%/既知 AES 方式か FullyDecrypted/0%/None のみ。進行中・中断・不明・ハードウェア暗号化は拒否します。暗号化された各ボリュームの回復キー ID と対象 image hash の結び付け、キー別保管・ID 照合の確認が必要です。鍵そのものは読み取りも出力もしません。
- 新 TPM は旧 TPM の秘密を再現できません。`OriginalTpmSecretsRequired` が true/不明なら拒否。Windows Hello、証明書、EFS、アプリ秘密、機器依存ライセンス等は別確認が必要です。解除は本人が隔離ゲストのコンソールで手入力します。

### v2 作業者記録

以下は**未確認テンプレート**です。実際に検証していないフラグを true にしないでください。未知のフィールド、回復パスワード等の欄、48 桁の秘密文字列は拒否対象です。コマンドライン、JSON、ログ、Git、チャットに回復キー本文を入れないでください。

```json
{
  "SchemaVersion": 2,
  "Operator": "Unconfirmed",
  "RecordedUtc": "Unconfirmed",
  "Sources": [],
  "SourceSetSha256": "Unconfirmed",
  "SourceSetComplete": false,
  "SourceSetQuiescedTogether": false,
  "NoWritesDuringAcquisition": false,
  "QuiescentStartUtc": "Unconfirmed",
  "QuiescentEndUtc": "Unconfirmed",
  "FullShutdownVerified": false,
  "FastStartupNotUsed": false,
  "NotHibernated": false,
  "AllDependentDisksBackedUp": false,
  "AllApplicationDataIncluded": false,
  "BasicStorageTopologyVerified": false,
  "NoExternalStorageDependencies": false,
  "IdentityChangeAccepted": false,
  "AcceptNewTpmIdentity": false,
  "OriginalTpmSecretsRequired": null,
  "HostWindows11CpuSupported": false,
  "BitLockerVolumes": [],
  "RecoveryKeyStoredSeparately": false,
  "RecoveryKeyMatchesSource": false,
  "AcceptManualUnlock": false
}
```

`Sources` は順序付き配列。各要素は `SourceImageSha256`, `SerialNumber`, `Size`, `LogicalSectorSize`, `Role`（先頭 Boot、以後 Data）, `ControllerLocation`（0 から連番）だけです。各 raw manifest と台帳に一致させます。`Get-RecoverySourceSetHash -Sources $e.Sources` はこの集合の整合ハッシュを計算します。ハッシュは申告の真実性や署名を保証しません。

暗号化ボリュームごとの `BitLockerVolumes` は `MountPoint`, `SourceImageSha256`, `RecoveryKeyId`（GUID のみ）, `SeparateStorageVerified`, `RecoveryKeyIdMatched` だけです。ID は手動確認用で、collector はキー本文も ID も収集していません。profile には ID を伝播しません。

静止期間は台帳取得以後、作業記録以前で、全 raw manifest の `CreatedUtc` がその開始〜終了内であることが必要です。作業中に起動や書き込みがなかったことは申告であり、時刻比較だけで整合性を実証しません。VHDX の `CreatedUtc` は変換時刻なので raw 取得時刻の代わりにはなりません。

```powershell
.\windows-recovery.ps1 -Action Profile -InventoryPath E:\Backup\inventory.json -RawManifestPath E:\Backup\boot.raw.manifest.json -AdditionalRawManifestPaths E:\Backup\data.raw.manifest.json -EvidencePath E:\Backup\evidence-v2.json -OutputPath E:\Backup\profile-v2.json
```

`-AdditionalRawManifestPaths` は Sources の Data 順です。VM 作成側も同じ順の VHDX を `-DataVhdxPaths` へ渡します。アーカイブは不変のまま、新規作業コピー、未接続 NIC、新 VM ID、新 TPM を使います。生成成功は OS 起動・解除・アプリ動作・ライセンス確認の成功ではありません。
