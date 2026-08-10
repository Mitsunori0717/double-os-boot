#!/usr/bin/env bash
#
# 同時起動モード: Linux を使ったまま Windows をモニター1に起動する / 停止する
#
# 使い方:
#   bash 03-start-windows.sh            # 起動
#   bash 03-start-windows.sh --stop     # 通常シャットダウン要求 (Windows のスタートメニューからでも可)
#   bash 03-start-windows.sh --force-off # 強制電源断 (フリーズ時のみ。データ損失の可能性あり)
#   bash 03-start-windows.sh --status   # 状態表示
#
set -euo pipefail

VM_NAME="windows"
ACTION="start"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      VM_NAME="$2"; shift 2 ;;
        --stop)      ACTION="stop"; shift ;;
        --force-off) ACTION="force"; shift ;;
        --status)    ACTION="status"; shift ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

VIRSH="virsh"
if [[ $EUID -ne 0 ]]; then
    VIRSH="sudo virsh"
fi

if ! $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 起動定義 '$VM_NAME' がありません。baremetal/02-create-windows-vm.sh で作成してください。" >&2
    exit 1
fi

state=$($VIRSH domstate "$VM_NAME")

case "$ACTION" in
    status)
        echo "Windows ($VM_NAME): $state"
        exit 0
        ;;
    stop)
        if [[ "$state" == "running" ]]; then
            echo "Windows にシャットダウンを要求しました。"
            $VIRSH shutdown "$VM_NAME"
        else
            echo "Windows は起動していません ($state)。"
        fi
        exit 0
        ;;
    force)
        read -rp "強制電源断します。保存していないデータは失われます。よろしいですか? (y/N): " ans
        [[ "$ans" == "y" ]] && $VIRSH destroy "$VM_NAME"
        exit 0
        ;;
esac

if [[ "$state" == "running" ]]; then
    echo "Windows は既に起動しています。モニター1を確認してください。"
    exit 0
fi

# 起動前の安全確認: Windows ディスクが Linux にマウントされていないこと
# (定義からディスクパスを取得して確認)
disk_path=$($VIRSH domblklist "$VM_NAME" | awk 'NR>2 && $2 != "" && $2 != "-" {print $2; exit}')
if [[ -n "$disk_path" && -e "$disk_path" ]]; then
    real_disk=$(readlink -f "$disk_path")
    if lsblk -no MOUNTPOINT "$real_disk" 2>/dev/null | grep -q .; then
        echo "エラー: Windows ディスク ($real_disk) が Linux にマウントされています。" >&2
        echo "同時アクセスは NTFS 破損の原因になるため起動を中止しました。" >&2
        echo "アンマウントしてから再実行してください: sudo umount ${real_disk}*" >&2
        exit 1
    fi
fi

echo "Windows を起動しています... (モニター1に BIOS 画面 → Windows が表示されます)"
$VIRSH start "$VM_NAME"

echo
echo "起動しました。"
echo "  - 画面        : Windows 専有 GPU に接続されたモニターに直接表示されます"
echo "  - 終了        : Windows 内で通常どおりシャットダウン"
echo "  - ファイル共有: Windows 側から \\\\<LinuxのIP>\\shared (04 で設定した共有)"
echo "  - キーボード切替: 左右 Ctrl 同時押し (05 を設定した場合)"
