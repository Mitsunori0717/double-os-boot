# 複数ディスクのバックアップセット

`backup_set.py` は、既存 `offline_image.py` で取得した全 LBA RAW と manifest を、順序を持った一組として検証します。物理ディスクの取得・書込み・VM 操作は行いません。

## 対応範囲

- 1～16 台の単純な独立ディスク。OS、アプリ、データ、ブート領域が別ディスクにある場合はすべて含めます。
- 各ディスクの実バイト容量と論理セクタ（512 / 4096）を保持します。4Kn の RAW 保全対応は VHDX/ゲスト起動対応を意味しません。
- RAID、Storage Spaces、dynamic disk、スパン/ストライプ等、依存関係不明の構成は対象外です。単一メンバーを一式として登録してはいけません。
- 同じハッシュのディスクがあっても異なる識別子なら登録できます。空ディスク等は内容が同じになり得るためです。同一 UniqueId、または同一 Model + SerialNumber の重複は拒否します。

## 事前準備

すべての依存ディスクを調べ、Windows の高速スタートアップ/休止状態ではない正常な完全終了を行ってから、同じ静止期間中に取得してください。取得の途中で元 PC/VM を起動したり、いずれかのディスクを書き換えたりしないでください。

このプログラムは正常終了や同時点の整合性を実証しません。オペレーターの申告と manifest の作成時刻を比較するだけです。時刻は取得開始時刻ではなく、取得全期間の証明にもなりません。出力は常に `Consistency=operator-attested-not-proven`、`BootTested=false`、`RestoreTested=false`、`AutomaticRestoreAuthorized=false` です。

manifest の `CreatedUtc` は取得終了側の記録であり、取得開始時刻や全ディスクの整合性を証明する値ではありません。

同一のローカルフォルダーへ各 `disk0.raw` と `disk0.raw.manifest.json` 等を置きます。ファイル名は英数字で始まる英数字・`_`・`-`・`.` の 121 文字以内とし、`..` は使用できません。UNC、symlink/reparse は拒否します。読み取りロック/lease が使えない環境でも処理を拒否します。

仕様 JSON 例（数値・識別子・時刻は実際の manifest と作業記録に合わせてください）:

```json
{
  "SchemaVersion": 1,
  "Topology": "simple-independent",
  "BootDiskUniqueId": "disk-boot-id",
  "ExpectedDisks": [
    {"UniqueId":"disk-boot-id","SerialNumber":"serial-boot","Model":"model","Size":512000000000,"LogicalSectorSize":512},
    {"UniqueId":"disk-data-id","SerialNumber":"serial-data","Model":"model","Size":1024000000000,"LogicalSectorSize":4096}
  ],
  "Attestation": {
    "Shutdown":"full-shutdown",
    "AllDependentDisksIncluded":true,
    "NoWritesDuringAcquisition":true,
    "QuiescentStartUtc":"2026-11-18T01:00:00Z",
    "QuiescentEndUtc":"2026-11-18T03:00:00Z"
  }
}
```

`ExpectedDisks` の配列順がセットの明示的な順序です。`--raw` も同じ順序で指定します。ブートディスクは `BootDiskUniqueId` で一意に指定します。この順序は Hyper-V のコントローラー番号を自動設定するものではありません。復旧プロファイルの構成は別途確認してください。

```text
python backup_set.py build --specification set-spec.json --raw disk0.raw --raw disk1.raw --output set.json
python backup_set.py verify --set set.json
```

全 RAW と manifest の読み取りロックを保持し、サイズ・SHA-256・識別子集合・順序を検証します。出力は RAW と同じフォルダーに新規作成し、既存ファイルを置換しません。出力には相対ファイル名と manifest 自体のハッシュも含め、後の `verify` で再確認します。入力に秘密の鍵、パスワード、回復キー、自由記述メモを追加しないでください。仕様はフィールド allowlist と既知の回復キーパターン拒否を使いますが、任意文字列に隠された秘密を検出できる保証はありません。

## 失敗・真正性・実機検証

失敗時に `set.json.partial` が残る場合があります。これは成功台帳ではありません。既存の partial は上書きしません。原因を調べ、別の新しい出力名で再検証してください。CLI のエラーは固定コードのみで、OS エラーのローカルパスを表示しません。

台帳とハッシュは破損や不一致検出用で、電子署名ではありません。攻撃者が RAW と台帳の両方を書き換える場合、真正性を保証しません。信頼できる別媒体にも原本を保持してください。完成後に画像が変更される可能性があるため、実際の復旧経路でも実行直前に再検証する必要があります。

`fixture-build` と `verify --allow-fixture` は合成ファイル試験専用です。fixture 台帳は通常 `verify` では拒否し、本番成功状態に昇格しません。テストは一時ファイルのみで、実ディスクやゲストを動かしていません。セットの検証成功は BitLocker 解除、ライセンス再認証、アプリ動作、実機起動を保証しません。
