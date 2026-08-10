#!/usr/bin/env bash
#
# IOMMU の有効化 + Windows 専有 GPU を Linux ドライバから切り離して VFIO に予約する
#
# 行うこと:
#   1. カーネル起動パラメータに IOMMU 有効化を追加 (intel_iommu=on / amd_iommu=on, iommu=pt)
#   2. /etc/modprobe.d/vfio.conf で指定 GPU を vfio-pci ドライバに予約
#      (GPU ドライバより先に vfio-pci が確保するよう softdep を設定)
#   3. initramfs と GRUB を更新
#
# 使い方:
#   sudo bash 01-configure-iommu.sh --gpu-ids "10de:2484,10de:228b"
#     (ID は 00-check-hardware.sh の出力にある vendor:device。GPU 本体と
#      付随する HDMI オーディオ等、同一カードの全ファンクション分を指定)
#
# 元に戻す:
#   sudo bash 01-configure-iommu.sh --revert
#
set -euo pipefail

GPU_IDS=""
REVERT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gpu-ids) GPU_IDS="$2"; shift 2 ;;
        --revert)  REVERT=1; shift ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi

GRUB_FILE=/etc/default/grub
VFIO_MODPROBE=/etc/modprobe.d/vfio.conf
VFIO_MODULES=/etc/modules-load.d/vfio.conf

if [[ $REVERT -eq 1 ]]; then
    echo "==> VFIO 設定を削除して元に戻します..."
    rm -f "$VFIO_MODPROBE" "$VFIO_MODULES"
    sed -i -E 's/ ?(intel_iommu=on|amd_iommu=on|iommu=pt|vfio-pci\.ids=[^" ]*)//g' "$GRUB_FILE"
    update-initramfs -u
    update-grub
    echo "完了しました。再起動すると GPU は Linux に戻ります。"
    exit 0
fi

if [[ -z "$GPU_IDS" ]]; then
    echo "使い方: sudo bash $0 --gpu-ids \"10de:2484,10de:228b\"" >&2
    echo "  (ID は 00-check-hardware.sh の出力を参照)" >&2
    exit 1
fi

# ID 形式の検証
if ! [[ "$GPU_IDS" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}(,[0-9a-fA-F]{4}:[0-9a-fA-F]{4})*$ ]]; then
    echo "エラー: --gpu-ids の形式が不正です (例: 10de:2484,10de:228b)" >&2
    exit 1
fi

# 指定 ID が Linux 表示用 GPU と重複していないかの簡易確認
echo "==> 指定された ID のデバイス:"
for id in ${GPU_IDS//,/ }; do
    lspci -d "$id" | sed 's/^/    /' || true
    if ! lspci -d "$id" | grep -q .; then
        echo "エラー: ID $id のデバイスが見つかりません。" >&2
        exit 1
    fi
done
echo
echo "重要: 上記に Linux の画面表示に使っている GPU が含まれていないことを確認してください。"
read -rp "続行しますか? (y/N): " ans
[[ "$ans" == "y" ]] || exit 0

# CPU ベンダー判定
if grep -q vmx /proc/cpuinfo; then
    IOMMU_PARAM="intel_iommu=on"
else
    IOMMU_PARAM="amd_iommu=on"
fi

echo "==> カーネル起動パラメータを設定しています..."
cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# 既存の関連パラメータを除去してから追加 (再実行しても重複しない)
sed -i -E 's/ ?(intel_iommu=on|amd_iommu=on|iommu=pt|vfio-pci\.ids=[^" ]*)//g' "$GRUB_FILE"
sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)\"/\1\2 $IOMMU_PARAM iommu=pt\"/" "$GRUB_FILE"
sed -i -E 's/"  +/" /; s/  +/ /g' "$GRUB_FILE"

echo "==> VFIO モジュール設定を作成しています..."
cat > "$VFIO_MODULES" <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
EOF

cat > "$VFIO_MODPROBE" <<EOF
# Windows 専有 GPU を vfio-pci に予約 (double-os-boot)
options vfio-pci ids=$GPU_IDS
# GPU ドライバより先に vfio-pci がデバイスを確保する
softdep nvidia pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep amdgpu pre: vfio-pci
softdep radeon pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF

echo "==> initramfs と GRUB を更新しています..."
update-initramfs -u
update-grub

echo
echo "設定が完了しました。再起動してください:  sudo reboot"
echo
echo "再起動後の確認:"
echo "  lspci -nnk -d ${GPU_IDS%%,*}"
echo "  → 'Kernel driver in use: vfio-pci' と表示されれば成功です。"
echo "  その後 baremetal/02-create-windows-vm.sh に進んでください。"
