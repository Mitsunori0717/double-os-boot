# double-os-boot — 物理デュアルブート + 同時起動システム

C ドライブに **物理インストールされた Windows 11**、D ドライブ (別ディスク) に **物理インストールされた Linux** を、

1. **ネイティブ・デュアルブート** — GRUB でどちらかを選んで素の状態で起動(仮想化ゼロ)
2. **同時起動モード** — Linux をネイティブ起動したまま、同じ物理 C: ディスクから Windows を起動し、専有させた実 GPU でモニター1にネイティブ描画

の **2 通りで起動できる** ようにするスクリプトとドキュメント一式です。
どちらのモードでも、ディスクの中身は同一の物理インストールです。仮想ディスクは使いません。

```
【モード1: ネイティブ・デュアルブート (通常運用・問題切り分け用)】

  電源ON → GRUB メニュー → Windows (C: ネイティブ起動)  … 仮想化レイヤーなし
                          → Linux   (D: ネイティブ起動)  … 仮想化レイヤーなし

【モード2: 同時起動 (ハードウェア分割)】

 ┌───────────────────────────────────────────────────────────┐
 │ 物理 PC                                                    │
 │                                                            │
 │  Linux (D: ディスクからネイティブ起動)                        │
 │   ├─ GPU2 (iGPU等) ──► モニター2                            │
 │   └─ KVM/VFIO = ハードウェアの所有権を仕切る薄い調停層         │
 │        │                                                   │
 │        └─ Windows (C: の物理ディスクそのものから起動)          │
 │             ├─ GPU1 を1枚まるごと専有 ──► モニター1 (ネイティブ描画)│
 │             ├─ C: 物理ディスクを専有 (仮想ディスク不使用)       │
 │             └─ USB コントローラ専有 (キーボード/マウス直結可)    │
 │                                                            │
 │  データ共有: Samba (D: 上の共有フォルダを両OSから読み書き)      │
 └───────────────────────────────────────────────────────────┘
```

## まず正直な技術的事実

**1 つの CPU を、2 つの OS が仲介なしに同時所有することは物理的に不可能です。**
CPU コア・MMU・割り込みコントローラの支配権を持てる OS は常に 1 つだけであり、
これはソフトウェアの工夫ではなく x86 アーキテクチャの仕様です。

そのうえで、物理法則の範囲で「仮想化っぽさ」を極限まで排除したのが本システムです。
同時起動モードにおいても:

| ハードウェア | 所有形態 |
|---|---|
| GPU (モニター1側) | Windows が **実物を1枚専有**。NVIDIA/AMD の純正ドライバが実ハードを直接制御し、モニターへは GPU から直接出力。エミュレーションでも画面転送でもない |
| C: ディスク | Windows が **物理ディスクそのもの** を専有。NTFS・ブート構成・インストール内容はネイティブ起動時と同一 |
| USB | USB コントローラごと Windows に専有させれば、キーボード・マウス・USB 機器も直結 |
| CPU コア | コアを分割して固定割り当て (ピンニング)。Windows 専用コアには Linux のプロセスが載らない |
| メモリ | 起動時に物理的に確保 (HugePages)。スワップ等の干渉なし |

KVM が担うのは「どのハードをどちらが所有するか」の調停と、CPU の VT-x による直接実行の入口だけです。
実測性能はネイティブ比 95〜98% が一般的です。

## 問題切り分けを最優先した設計

「ソフトの不具合が Windows のせいか、仮想化のせいか、ソフトのせいか分からなくなる」
— この問題への回答が、**同一の物理 Windows を両モードで起動できる** という本設計の核心です。

```
ソフトで問題発生 (同時起動モード中)
        │
        ▼
再起動して GRUB から Windows をネイティブ起動 (仮想化レイヤーが物理的に存在しない状態)
        │
        ├─ 再現する   → Windows または ソフト自体の問題。調停層は無関係と確定
        └─ 再現しない → 調停層 (KVM/VFIO) 起因と確定 → docs/TROUBLESHOOTING.md へ
```

切り分けたい作業・重要な作業は常にネイティブ起動で行い、
「両方の画面を同時に使いたい日常作業」だけ同時起動モードを使う、という運用を推奨します。

## 必要環境

| 項目 | 要件 |
|---|---|
| CPU | Intel VT-x + VT-d / AMD-V + AMD-Vi (IOMMU)。ここ数年の CPU はほぼ対応 |
| マザーボード | UEFI で IOMMU (VT-d / AMD-Vi) を有効化できること |
| GPU | **2 系統必要**: Windows 専有用に 1 枚 (dGPU 推奨) + Linux 用に 1 系統 (iGPU で可) |
| ディスク | Windows 用と Linux 用は **別々の物理ディスク** (例: NVMe #1 = C:、NVMe #2 = D:) |
| モニター | 2 枚。モニター1 を Windows 専有 GPU に、モニター2 を Linux 側 GPU に接続 |
| メモリ | 32 GB 推奨 (Windows に 16 GB 固定割り当ての場合) |
| Linux | Ubuntu 24.04 LTS を想定 (Debian 系なら概ね動作) |

## セットアップ手順

### STEP 0: デュアルブートの構築 (未構築の場合)

Windows が入った PC に、2 本目のディスクへ Linux をインストールして GRUB で選択起動できるようにします。
→ **[docs/DUAL-BOOT-SETUP.md](docs/DUAL-BOOT-SETUP.md)**

この時点で「モード1: ネイティブ・デュアルブート」は完成です。以降は同時起動モードの追加設定です。

### STEP 1: ハードウェア適合チェック (Linux 側で実行)

```bash
sudo bash baremetal/00-check-hardware.sh
```

IOMMU の有効状態、GPU の IOMMU グループ分離、Windows ディスクの特定など、
同時起動モードの成立条件を全て検査し、次のステップで使う値 (PCI アドレス等) を表示します。

### STEP 2: IOMMU と GPU 切り離しの設定

```bash
# STEP 1 の出力に表示された GPU の vendor:device ID を指定
sudo bash baremetal/01-configure-iommu.sh --gpu-ids "10de:2484,10de:228b"
sudo reboot
```

カーネル起動パラメータに IOMMU を設定し、Windows 専有 GPU を Linux のドライバから
切り離して VFIO に予約させます。再起動後、その GPU は Linux からは見えなくなります。

### STEP 3: Windows 起動定義の作成

```bash
# STEP 1 の出力から Windows ディスクの by-id パスと GPU の PCI アドレスを指定
sudo bash baremetal/02-create-windows-vm.sh \
    --windows-disk /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_XXXXX \
    --gpu 0000:01:00.0 \
    --memory 16 --cpus 8
```

物理 C: ディスク・実 GPU・CPU コア・メモリの割り当てを定義します。
仮想ディスクは作成しません — C: の物理ディスクをそのまま起動します。

### STEP 4: データ共有の設定

```bash
sudo bash baremetal/04-setup-file-sharing.sh --shared-dir /srv/shared
```

Linux 側に Samba 共有を作成します。Windows 側からは `\\<LinuxのIP>\shared` を
Z: ドライブ等に割り当てれば、双方向のファイル交換ができます。

### STEP 5: キーボード・マウス共有 (任意)

```bash
sudo bash baremetal/05-share-keyboard-mouse.sh
```

1 組のキーボード・マウスを **左右 Ctrl 同時押し** で Windows ⇔ Linux 切り替えできるようにします
(evdev パススルー)。物理的に 2 組つなぐ、または USB 切替器を使う場合は不要です。

## 日常の使い方

| やりたいこと | 操作 |
|---|---|
| Windows だけを素で使う (切り分け・ゲーム・重要作業) | 電源ON → GRUB で Windows を選択 |
| Linux だけを素で使う | 電源ON → GRUB で Linux を選択 |
| 両方同時に使う | GRUB で Linux を起動 → `bash baremetal/03-start-windows.sh` → モニター1に Windows が起動 |
| 同時起動中の Windows を終了 | Windows 内で通常通りシャットダウン |
| ファイルを渡す | Windows: `Z:\` ⇔ Linux: `/srv/shared` |
| キーボード/マウスの切替 | 左右 Ctrl 同時押し (STEP 5 設定時) |

**重要な運用ルール**: 同時起動中、Linux 側から C: ディスクを絶対にマウントしないでください
(スクリプトが自動で保護設定を行いますが、手動マウントは破損の原因になります)。

## リポジトリ構成

```
baremetal/00-check-hardware.sh       適合チェックと設定値の洗い出し
baremetal/01-configure-iommu.sh      IOMMU 有効化 + GPU の VFIO 予約
baremetal/02-create-windows-vm.sh    物理ディスク/GPU/CPU 割り当て定義の作成
baremetal/03-start-windows.sh        同時起動モードで Windows を起動/停止
baremetal/04-setup-file-sharing.sh   Samba によるデータ共有
baremetal/05-share-keyboard-mouse.sh 1組のキーボード/マウスを両OSで共有
docs/DUAL-BOOT-SETUP.md              ネイティブ・デュアルブートの構築手順
docs/ARCHITECTURE.md                 技術解説 (なぜこの設計か・何がどこまで可能か)
docs/TROUBLESHOOTING.md              トラブルシューティング
alternatives/hyperv/                 (参考) Hyper-V による簡易構成。GPU 専有なし・要件が緩い
```

## 制約と注意点 (正直な列挙)

- **Windows ライセンス**: ネイティブ起動時と同時起動時でハードウェア構成が変わって見えるため、
  ライセンス認証が 2 つのデバイスプロファイルを持つ形になります。Microsoft アカウント紐付けの
  デジタルライセンスなら「ハードウェアを変更しました」から再認証できます。
- **一部のアンチチートゲーム**は hypervisor の存在を検出して起動を拒否します。
  該当ゲームはネイティブ起動側でプレイしてください (そのために両モードがあります)。
- GPU が 1 枚しかない環境では同時起動モードは実用になりません (シングル GPU パススルーは
  Linux 側の画面を失うため要件を満たせません)。iGPU 付き CPU なら iGPU + dGPU で成立します。
- 高速スタートアップ (Windows の休止状態ブート) は必ず無効化してください
  (`docs/DUAL-BOOT-SETUP.md` 参照)。有効のままだと NTFS が休止状態でロックされ、
  ディスク破損の危険があります。
