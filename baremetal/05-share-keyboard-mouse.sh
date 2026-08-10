#!/usr/bin/env bash
#
# 1 組のキーボード・マウスを Windows / Linux 両方で使えるようにする (evdev パススルー)
#
# 仕組み:
#   物理キーボード・マウスの入力イベントを QEMU に直接渡し、
#   「左右の Ctrl キー同時押し」で入力先を Windows ⇔ Linux で切り替える。
#   USB 切替器や 2 組目のキーボードは不要。
#
# 使い方:
#   sudo bash 05-share-keyboard-mouse.sh              # 対話的にデバイスを選択
#   sudo bash 05-share-keyboard-mouse.sh --name windows
#
set -euo pipefail

VM_NAME="windows"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) VM_NAME="$2"; shift 2 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi

if ! virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 起動定義 '$VM_NAME' がありません。先に 02-create-windows-vm.sh を実行してください。" >&2
    exit 1
fi
if [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
    echo "エラー: '$VM_NAME' が起動中です。停止してから実行してください。" >&2
    exit 1
fi

echo "検出された入力デバイス (/dev/input/by-id/):"
echo
mapfile -t devices < <(find /dev/input/by-id/ -name '*-event-kbd' -o -name '*-event-mouse' | sort)
if [[ ${#devices[@]} -eq 0 ]]; then
    echo "エラー: 入力デバイスが見つかりません。" >&2
    exit 1
fi
for i in "${!devices[@]}"; do
    echo "  [$i] ${devices[$i]}"
done
echo
read -rp "キーボードの番号: " kbd_idx
read -rp "マウスの番号: " mouse_idx
KBD="${devices[$kbd_idx]}"
MOUSE="${devices[$mouse_idx]}"

echo
echo "  キーボード: $KBD"
echo "  マウス    : $MOUSE"
echo

# virt-xml で evdev 入力デバイスを追加
# grabToggle=ctrl-ctrl → 左右 Ctrl 同時押しで入力先を切り替え
echo "==> 起動定義に evdev パススルーを追加しています..."
virt-xml "$VM_NAME" --add-device \
    --input "type=evdev,source.dev=$KBD,source.grab=all,source.grabToggle=ctrl-ctrl,source.repeat=on"
virt-xml "$VM_NAME" --add-device \
    --input "type=evdev,source.dev=$MOUSE"

# QEMU プロセスが入力デバイスを開けるよう cgroup ACL を許可
QEMU_CONF=/etc/libvirt/qemu.conf
if ! grep -q "double-os-boot evdev" "$QEMU_CONF"; then
    cat >> "$QEMU_CONF" <<EOF

# double-os-boot evdev: 入力デバイスへのアクセス許可
cgroup_device_acl = [
    "/dev/null", "/dev/full", "/dev/zero",
    "/dev/random", "/dev/urandom",
    "/dev/ptmx", "/dev/kvm", "/dev/userfaultfd",
    "$KBD", "$MOUSE"
]
EOF
    systemctl restart libvirtd
    echo "    qemu.conf を更新し libvirtd を再起動しました。"
fi

echo
echo "設定が完了しました。"
echo "  - Windows 起動中に【左右の Ctrl キーを同時押し】すると、"
echo "    キーボード・マウスの入力先が Windows ⇔ Linux で切り替わります。"
echo "  - 解除するには: sudo virt-xml $VM_NAME --remove-device --input type=evdev (2回実行)"
