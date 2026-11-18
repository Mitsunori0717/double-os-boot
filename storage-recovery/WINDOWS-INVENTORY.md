# Windows 物理PCの復旧用・読み取り専用インベントリ

`WindowsRecoveryInventory.psm1` の `Get-WindowsRecoveryInventory` は、Windowsを含む全ディスク保全の前に構成を確認する補助台帳です。モジュールのimportだけでは問い合わせません。呼び出し時も読み取りのみで、停止・休止解除・暗号化解除・ディスク状態変更・バックアップ取得は行いません。

```powershell
Import-Module .\WindowsRecoveryInventory.psm1
$inventory = Get-WindowsRecoveryInventory
$inventory | ConvertTo-Json -Depth 12
```

CLIで新規JSONへ保存する場合は `windows-recovery.ps1` のHelpを参照してください。識別情報を含むため、台帳をGitや公開共有へ保存しないでください。

## 記録する情報

- `Get-Disk`の識別情報、実容量、セクタ、GPT/MBR、Boot/System状態とパーティション。`Win32_DiskDrive`の番号集合と照合し、省略されたディスクや未知の構成を検知します。
- 現在のWindowsのSystemDrive、OS版・ビルド・アーキテクチャ・ProductType。
- UEFI/BIOS、Secure Boot状態。権限不足等を無効扱いにせずUnknownで残します。
- BitLockerの保護・暗号化進捗・暗号方式・ロック状態のみ。回復パスワード、保護者ID、鍵、TPM所有者認証は問い合わせず、収集・出力しません。
- Fast Startupと休止の設定値。設定値は、今回完全終了したことや休止データが存在しないことの証明にはなりません。

`IsBoot` は現在のWindowsを含む側、`IsSystem` は起動に必要なシステム側を指します。別ディスクに分かれていれば両方を必要ディスク候補として記録します。EFI/Activeパーティションは追加の候補として区別します。パーティションの範囲・重複・セクタ整列などが不明なら完全な観測結果としません。GPTではIsActiveがnullでも正常なため、BIOS/MBRのActive状態と混同しません。

## 「全部」の限界

`SnapshotComplete=true` は、対象の状態問い合わせがそろったという意味だけです。バックアップ完成、静止、全アプリの移植可能性や他PCでの起動成功を示しません。

- 現在のWindowsの起動ディスク依存を対象にします。他OS/複数ブート、RAID/Storage Spaces/仮想ディスク等は追加評価が必要です。
- フォルダへの別ボリュームマウント、ネットワークストレージ、クラウド未ダウンロードファイル、アプリ固有の外部依存は自動判定できずUnknownのままです。
- TPMがないことと、OSやアプリがTPMに依存しないことは別です。TPMの有無・所有情報は収集せず、依存をUnknownとします。回復キーやライセンス条件は別の安全な手順で確認してください。
- BitLockerのProtectionStatusがOffでも、暗号化されたまま保護を一時停止している可能性があります。ConversionStatusと併せて確認します。空の結果・アクセス拒否を「暗号化なし」とはみなしません。
- エラーログは固定コード・例外型・HRESULTのみで、プロバイダーの生オブジェクトや例外メッセージを出力しません。

## 検証

`powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-windows-inventory.ps1`

全問い合わせをモック化した非破壊テストです。今回の開発では実PCのインベントリ問い合わせは行っていません。

参考: [MSFT_Disk](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-disk)、[MSFT_Partition](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition)、[Win32_EncryptableVolume](https://learn.microsoft.com/en-us/windows/win32/secprov/win32-encryptablevolume)、[Confirm-SecureBootUEFI](https://learn.microsoft.com/en-us/powershell/module/secureboot/confirm-securebootuefi)。
