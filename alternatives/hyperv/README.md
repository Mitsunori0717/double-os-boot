# (参考) Hyper-V による簡易構成

本リポジトリの主構成 (ベアメタル・ハードウェア分割方式) が採用される前の初期案です。
**Windows をホストにして Linux を Hyper-V 仮想マシンとして動かし、モニター2 に RDP で表示** します。

## 主構成との違い

| 観点 | この構成 (Hyper-V) | 主構成 (baremetal/) |
|---|---|---|
| Linux の実体 | D: 上の仮想ディスク (VHDX) | D: の物理インストール |
| Linux の画面 | RDP による画面転送 | GPU からネイティブ出力 |
| GPU 要件 | 1 枚でよい | 2 系統必要 |
| ホスト側への影響 | Windows 自体が Hyper-V 上で動く形になる | Windows ネイティブ起動時は仮想化ゼロ |
| 問題切り分け | 困難 (仮想化層が常駐) | 容易 (ネイティブ起動で比較可能) |
| 難易度 | 低 | 中〜高 |

GPU が 1 系統しかない・Windows Pro しかない・とにかく簡単に済ませたい、という場合の
フォールバックとして残しています。手順はスクリプト内のコメントと引数説明を参照してください。

## 手順概要

```powershell
# 管理者 PowerShell で
.\windows\01-enable-hyperv.ps1          # Hyper-V 有効化 (要再起動)
.\windows\02-create-linux-vm.ps1 -IsoPath <UbuntuのISO>   # D:\LinuxVM に VM 作成
.\windows\03-setup-shared-folder.ps1    # D:\Shared を共有
# Ubuntu 内で
sudo bash linux/setup-guest.sh --host-ip <WindowsのIP> --share-user <ユーザー名>
# 以後、毎回これだけ
.\windows\04-launch-linux-monitor2.ps1  # モニター2 に Linux を全画面表示
```
