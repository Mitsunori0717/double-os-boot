#!/usr/bin/env bash
#
# 同時起動モードの Windows 起動定義を作成する
#
# ポイント:
#   - C: の物理ディスクそのものを渡す (仮想ディスクは作らない)
#   - 実 GPU を PCI パススルーで専有させる (モニター1へネイティブ出力)
#   - CPU コアを固定割り当て (ピンニング) し、Linux 側と物理的に分離
#   - メモリは HugePages で起動時に確保
#   - 仮想画面 (SPICE/VNC) は付けない — 画面は専有 GPU から直接出る
#
# 使い方:
#   sudo bash 02-create-windows-vm.sh \
#       --windows-disk /dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_XXXX \
#       --gpu 0000:01:00.0 \
#       --memory 16 --cpus 8
#
#   --windows-disk : 00-check-hardware.sh が表示した by-id パス (ディスク全体)
#   --gpu          : Windows に専有させる GPU の PCI アドレス。同一カードの
#                    付随ファンクション (.1 = HDMIオーディオ等) は自動で追加
#   --usb-controller <PCIアドレス> : (任意) USB コントローラごと専有させる場合
#
set -euo pipefail

VM_NAME="windows"
WIN_DISK=""
GPU_ADDR=""
USB_ADDR=""
MEMORY_GB=16
CPUS=8

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           VM_NAME="$2";   shift 2 ;;
        --windows-disk)   WIN_DISK="$2";  shift 2 ;;
        --gpu)            GPU_ADDR="$2";  shift 2 ;;
        --usb-controller) USB_ADDR="$2";  shift 2 ;;
        --memory)         MEMORY_GB="$2"; shift 2 ;;
        --cpus)           CPUS="$2";      shift 2 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi
if [[ -z "$WIN_DISK" || -z "$GPU_ADDR" ]]; then
    echo "使い方: sudo bash $0 --windows-disk /dev/disk/by-id/... --gpu 0000:01:00.0 [--memory 16] [--cpus 8]" >&2
    exit 1
fi
if [[ ! -b "$WIN_DISK" ]]; then
    echo "エラー: ディスクが見つかりません: $WIN_DISK" >&2
    exit 1
fi

REAL_DISK=$(readlink -f "$WIN_DISK")
DISK_NAME=$(basename "$REAL_DISK")

# --- 安全確認 1: Windows ディスクが Linux にマウントされていないこと ---
if lsblk -no MOUNTPOINT "$REAL_DISK" | grep -q .; then
    echo "エラー: $REAL_DISK のパーティションがマウントされています。" >&2
    lsblk "$REAL_DISK" >&2
    echo "アンマウントしてから再実行してください: sudo umount /dev/${DISK_NAME}*" >&2
    exit 1
fi

# --- 安全確認 2: Linux 自身のルートが載っているディスクではないこと ---
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
if [[ -n "$ROOT_DISK" && "$ROOT_DISK" == "$DISK_NAME" ]]; then
    echo "エラー: 指定ディスクは Linux のシステムディスクです。Windows のディスクを指定してください。" >&2
    exit 1
fi

# --- 安全確認 3: GPU が vfio-pci に予約されていること ---
GPU_SHORT="${GPU_ADDR#0000:}"
drv=$(lspci -nnk -s "$GPU_SHORT" | grep "Kernel driver in use" | awk -F': ' '{print $2}' || true)
if [[ "$drv" != "vfio-pci" ]]; then
    echo "エラー: GPU $GPU_ADDR のドライバが '$drv' です (vfio-pci である必要があります)。" >&2
    echo "01-configure-iommu.sh を実行して再起動したか確認してください。" >&2
    exit 1
fi

echo "==> 必要パッケージをインストールしています..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-kvm libvirt-daemon-system virtinst ovmf virt-manager

systemctl enable --now libvirtd
virsh net-info default >/dev/null 2>&1 && virsh net-autostart default >/dev/null && \
    (virsh net-list | grep -q "default.*active" || virsh net-start default)

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 定義 '$VM_NAME' は既に存在します。削除するには: sudo virsh undefine $VM_NAME --nvram" >&2
    exit 1
fi

# --- HugePages の設定 (メモリを起動時に物理確保し、断片化・スワップの影響を排除) ---
echo "==> HugePages を設定しています (${MEMORY_GB}GB 分)..."
HUGEPAGES=$(( MEMORY_GB * 1024 / 2 ))   # 2MB ページ
cat > /etc/sysctl.d/90-double-os-boot-hugepages.conf <<EOF
vm.nr_hugepages = $HUGEPAGES
EOF
sysctl -p /etc/sysctl.d/90-double-os-boot-hugepages.conf >/dev/null || \
    echo "    注意: HugePages の即時確保に失敗しました (メモリ断片化)。再起動後に確保されます。"

# --- GPU の全ファンクションを収集 (本体 + HDMI オーディオ等) ---
HOSTDEV_ARGS=()
DEV_PREFIX="${GPU_SHORT%.*}"
for fn_path in /sys/bus/pci/devices/0000:${DEV_PREFIX}.*; do
    fn="${fn_path##*/}"
    HOSTDEV_ARGS+=( --hostdev "pci_${fn//[:.]/_}" )
    echo "    パススルー対象: $fn ($(lspci -s "${fn#0000:}" | cut -d' ' -f2-))"
done
if [[ -n "$USB_ADDR" ]]; then
    HOSTDEV_ARGS+=( --hostdev "pci_${USB_ADDR//[:.]/_}" )
    echo "    パススルー対象 (USB): $USB_ADDR"
fi

# --- CPU ピンニング: 末尾の物理コアを Windows 専用に割り当てる ---
TOTAL_CPUS=$(nproc)
if [[ $CPUS -ge $TOTAL_CPUS ]]; then
    echo "エラー: --cpus は論理 CPU 総数 ($TOTAL_CPUS) より少なくしてください (Linux 側の分が必要)。" >&2
    exit 1
fi
PIN_START=$(( TOTAL_CPUS - CPUS ))

echo "==> Windows 起動定義 '$VM_NAME' を作成しています..."
virt-install \
    --name "$VM_NAME" \
    --osinfo win11 \
    --memory $(( MEMORY_GB * 1024 )) \
    --memorybacking hugepages=yes \
    --vcpus "$CPUS",cpuset="$PIN_START-$((TOTAL_CPUS-1))" \
    --cpu host-passthrough,cache.mode=passthrough,topology.sockets=1,topology.cores=$(( CPUS / 2 )),topology.threads=2 \
    --boot uefi \
    --disk path="$WIN_DISK",format=raw,bus=sata,cache=none,io=native \
    --network network=default,model=e1000e \
    --graphics none \
    --video none \
    --sound none \
    --controller type=usb,model=qemu-xhci \
    --features hyperv.relaxed.state=on,hyperv.vapic.state=on,hyperv.spinlocks.state=on,hyperv.spinlocks.retries=8191 \
    --clock offset=localtime,rtc_tickpolicy=catchup,hpet_present=no \
    "${HOSTDEV_ARGS[@]}" \
    --noautoconsole \
    --import \
    --noreboot

echo
echo "起動定義を作成しました。"
echo "  名前       : $VM_NAME"
echo "  ディスク   : $WIN_DISK (物理ディスク直接起動)"
echo "  GPU        : $GPU_ADDR とその付随ファンクション (モニター出力は GPU から直接)"
echo "  CPU        : ${CPUS} スレッド (論理 CPU $PIN_START-$((TOTAL_CPUS-1)) を専用割り当て)"
echo "  メモリ     : ${MEMORY_GB}GB (HugePages)"
echo
echo "次の手順:"
echo "  1. sudo bash baremetal/04-setup-file-sharing.sh   # データ共有"
echo "  2. sudo bash baremetal/05-share-keyboard-mouse.sh # キーボード/マウス共有 (任意)"
echo "  3. bash baremetal/03-start-windows.sh             # 同時起動!"
echo
echo "注意: 初回起動時、OVMF が Windows Boot Manager を見つけられない場合は"
echo "      起動直後に ESC 連打 → Boot Manager からディスクを選択してください"
echo "      (docs/TROUBLESHOOTING.md 参照)。"
