# ネイティブ・デュアルブートの構築手順

C ドライブ (物理ディスク #1) の Windows 11 を残したまま、
D ドライブ相当の物理ディスク #2 に Linux をインストールし、
電源投入時に GRUB でどちらかを選んで **素の状態 (仮想化ゼロ) で起動** できるようにします。

ここまでが「モード1」で、これ自体が完結したデュアルブート環境です。
同時起動 (モード2) を使わない日は、このモードだけで運用できます。

## 0. 事前準備 (Windows 側で実施)

### 0-1. 高速スタートアップの無効化 【必須】

Windows の「高速スタートアップ」は実体が休止状態 (ハイバネーション) であり、
有効のままだと NTFS がロックされたまま電源が切れます。
この状態のディスクに他 OS がアクセスするとファイルシステム破損の原因になります。

管理者権限の PowerShell で:

```powershell
powercfg /h off
```

### 0-2. BitLocker の確認

BitLocker が有効な場合、ブート構成の変化で回復キーを求められることがあります。
**必ず回復キーを控えてから** 作業してください
(設定 → プライバシーとセキュリティ → デバイスの暗号化 / または `manage-bde -status`)。

### 0-3. バックアップ

ディスク操作を伴うため、重要データのバックアップを強く推奨します。

### 0-4. UEFI 設定

PC 起動時に UEFI 設定画面に入り、以下を確認・変更します:

| 項目 | 設定 |
|---|---|
| Intel VT-x / AMD SVM | 有効 (同時起動モードで必要) |
| Intel VT-d / AMD IOMMU | 有効 (同時起動モードで必要) |
| セキュアブート | Ubuntu は対応しているため有効のままで可 |
| SATA モード | AHCI (RAID/RST は Linux から見えないことがある) |

## 1. Linux のインストール

1. [Ubuntu Desktop 24.04 LTS の ISO](https://ubuntu.com/download/desktop) を取得し、
   [Rufus](https://rufus.ie/) 等で USB メモリに書き込む
2. USB から起動 (起動時に F12/F8 等でブートメニュー)
3. インストーラーの「インストールの種類」で **「それ以外」(手動パーティショニング) を選択**
4. **インストール先として物理ディスク #2 (D: 相当) を選択**
   - ここで間違えると Windows を消します。ディスクの容量・型番をよく確認してください
   - ディスク #2 に以下を作成:
     - EFI システムパーティション: 512 MB (ディスク #2 に独立して作るのがポイント)
     - `/` (ext4): 残り全部 (スワップはファイルで賄われるため省略可)
   - **「ブートローダをインストールするデバイス」もディスク #2 を指定**
     (Windows ディスクの EFI 領域に相乗りさせない — 分離しておくと相互に無影響)
5. インストール完了後、再起動

## 2. GRUB に Windows を登録

Ubuntu 起動後、ターミナルで:

```bash
sudo apt update
sudo apt install -y os-prober
echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a /etc/default/grub
sudo update-grub
```

`Windows Boot Manager (on /dev/nvme0n1p1)` のような行が出力されれば登録成功です。
次回起動から GRUB メニューに Ubuntu と Windows が並びます。

### 起動選択の既定値・待ち時間の調整 (任意)

`/etc/default/grub`:

```
GRUB_DEFAULT=0        # 既定で起動するメニュー番号 (0始まり)。saved にすると前回選択を記憶
GRUB_TIMEOUT=5        # メニュー表示秒数
```

変更後は `sudo update-grub`。

## 3. 動作確認

1. 再起動 → GRUB で **Windows** を選択 → いつもの Windows がそのまま起動すること
2. 再起動 → GRUB で **Ubuntu** を選択 → Linux が起動すること
3. どちらの OS も仮想化レイヤーなしの素の起動であることを確認
   (Windows: タスクマネージャー → パフォーマンス → CPU の「仮想マシン: いいえ」)

ここまでで従来型デュアルブートは完成です。
同時起動モードの構築は [README の STEP 1](../README.md#セットアップ手順) から続けてください。

## 補足: 時刻ズレ対策

Windows と Linux はハードウェア時計の解釈 (ローカル時刻 vs UTC) が異なるため、
OS を行き来すると時計がずれることがあります。Linux 側で:

```bash
sudo timedatectl set-local-rtc 1 --adjust-system-clock
```

を実行して Windows に合わせるのが簡単です。
