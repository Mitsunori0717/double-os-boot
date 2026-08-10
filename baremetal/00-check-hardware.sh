#!/usr/bin/env bash
#
# 同時起動モードの成立条件チェック + 後続ステップで使う設定値の洗い出し
#
# 検査項目:
#   1. CPU の仮想化支援 (VT-x / AMD-V)
#   2. IOMMU (VT-d / AMD-Vi) の有効状態
#   3. GPU の一覧と IOMMU グループの分離状況
#   4. Windows がインストールされた物理ディスクの特定
#
# 使い方:
#   sudo bash 00-check-hardware.sh
#
set -euo pipefail

ok()   { echo -e "  [\e[32mOK\e[0m]   $*"; }
ng()   { echo -e "  [\e[31mNG\e[0m]   $*"; }
warn() { echo -e "  [\e[33m注意\e[0m] $*"; }

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi

FAIL=0

echo "===================================================="
echo " 1. CPU 仮想化支援機能"
echo "===================================================="
if grep -qE 'vmx|svm' /proc/cpuinfo; then
    if grep -q vmx /proc/cpuinfo; then
        ok "Intel VT-x が利用可能です"
        CPU_VENDOR=intel
    else
        ok "AMD-V が利用可能です"
        CPU_VENDOR=amd
    fi
else
    ng "CPU 仮想化支援 (VT-x / AMD-V) が見つかりません。UEFI 設定で有効化してください。"
    CPU_VENDOR=unknown
    FAIL=1
fi

# P/E コア混成 CPU (Intel 12世代以降) の場合はコア構成を表示
if [[ -d /sys/devices/cpu_core && -d /sys/devices/cpu_atom ]]; then
    echo
    echo "この CPU は P コア / E コア混成です:"
    echo "  P コア (高性能)   : 論理 CPU $(cat /sys/devices/cpu_core/cpus)"
    echo "  E コア (高効率)   : 論理 CPU $(cat /sys/devices/cpu_atom/cpus)"
    echo "  → 02-create-windows-vm.sh では --cpuset でどちらを Windows に渡すか明示してください。"
fi

echo
echo "===================================================="
echo " 2. IOMMU (VT-d / AMD-Vi)"
echo "===================================================="
if compgen -G "/sys/class/iommu/*" > /dev/null; then
    ok "IOMMU はカーネルで有効です"
    IOMMU_ON=1
else
    IOMMU_ON=0
    if [[ "$CPU_VENDOR" == "intel" ]]; then
        warn "IOMMU が無効です。次の 2 点を確認してください:"
        echo "         - UEFI 設定で VT-d を有効化"
        echo "         - baremetal/01-configure-iommu.sh の実行 (カーネルパラメータ intel_iommu=on)"
    else
        warn "IOMMU が無効です。UEFI 設定で AMD-Vi (SVM/IOMMU) を有効化し、01-configure-iommu.sh を実行してください。"
    fi
fi

echo
echo "===================================================="
echo " 3. GPU と IOMMU グループ"
echo "===================================================="
echo "検出された GPU (VGA/3D/Display コントローラ):"
echo
GPU_COUNT=0
while IFS= read -r line; do
    GPU_COUNT=$((GPU_COUNT + 1))
    pci_addr=$(echo "$line" | awk '{print $1}')
    # vendor:device ID を取得
    ids=$(lspci -n -s "$pci_addr" | awk '{print $3}')
    echo "  GPU #$GPU_COUNT: $line"
    echo "           PCI アドレス   : 0000:$pci_addr"
    echo "           vendor:device  : $ids"
    # 同一デバイスの他ファンクション (HDMI オーディオ等) も列挙
    dev_prefix="${pci_addr%.*}"
    while IFS= read -r fn; do
        fn_addr=$(echo "$fn" | awk '{print $1}')
        [[ "$fn_addr" == "$pci_addr" ]] && continue
        fn_ids=$(lspci -n -s "$fn_addr" | awk '{print $3}')
        echo "           付随ファンクション: 0000:$fn_addr ($fn_ids) - $(echo "$fn" | cut -d' ' -f2-)"
    done < <(lspci | grep "^$dev_prefix")
    if [[ $IOMMU_ON -eq 1 ]]; then
        group_link="/sys/bus/pci/devices/0000:$pci_addr/iommu_group"
        if [[ -e "$group_link" ]]; then
            group=$(basename "$(readlink "$group_link")")
            members=$(ls "/sys/kernel/iommu_groups/$group/devices/" | wc -l)
            echo "           IOMMU グループ : $group (メンバー ${members} 個)"
            # グループに GPU 本体+付随ファンクション以外が同居していると分離が必要
            own_fns=$(lspci | grep -c "^$dev_prefix")
            if [[ $members -gt $own_fns ]]; then
                warn "      このグループには他のデバイスが同居しています。パススルー時はグループ全体が対象になります。"
                echo "           同居デバイス:"
                for d in /sys/kernel/iommu_groups/$group/devices/*; do
                    echo "             - $(lspci -s "${d##*/}" 2>/dev/null || echo "${d##*/}")"
                done
            fi
        fi
    fi
    echo
done < <(lspci | grep -Ei 'VGA|3D controller|Display controller')

if [[ $GPU_COUNT -ge 2 ]]; then
    ok "GPU が ${GPU_COUNT} 系統あります (Windows 専有用 + Linux 用に分離可能)"
elif [[ $GPU_COUNT -eq 1 ]]; then
    ng "GPU が 1 系統しかありません。同時起動モードには 2 系統必要です (iGPU の UEFI 有効化を確認してください)。"
    FAIL=1
else
    ng "GPU が検出できませんでした。"
    FAIL=1
fi

echo
echo "===================================================="
echo " 4. Windows がインストールされた物理ディスク"
echo "===================================================="
echo "NTFS パーティションを含むディスク:"
echo
WIN_DISK_FOUND=0
while IFS= read -r disk; do
    if lsblk -no FSTYPE "/dev/$disk" 2>/dev/null | grep -q ntfs; then
        WIN_DISK_FOUND=1
        model=$(lsblk -dno MODEL "/dev/$disk" | sed 's/ *$//')
        size=$(lsblk -dno SIZE "/dev/$disk")
        echo "  /dev/$disk  ($model, $size)"
        byid=$(find /dev/disk/by-id/ -lname "*/$disk" ! -name 'wwn-*' ! -name '*-part*' | head -1)
        echo "    by-id パス (02 スクリプトで使用):"
        echo "      $byid"
        # マウント状態の警告
        if lsblk -no MOUNTPOINT "/dev/$disk" | grep -q .; then
            warn "このディスクのパーティションが Linux にマウントされています。同時起動時は必ずアンマウントしてください。"
        fi
        echo
    fi
done < <(lsblk -dno NAME)

if [[ $WIN_DISK_FOUND -eq 0 ]]; then
    ng "NTFS を含むディスクが見つかりません。Windows ディスクが接続されているか確認してください。"
    FAIL=1
fi

echo "===================================================="
echo " 判定"
echo "===================================================="
if [[ $FAIL -eq 0 && $IOMMU_ON -eq 1 ]]; then
    ok "同時起動モードの前提条件を満たしています。"
    echo
    echo "次の手順:"
    echo "  sudo bash baremetal/01-configure-iommu.sh --gpu-ids \"<Windows専有GPUのvendor:device,付随オーディオのvendor:device>\""
elif [[ $FAIL -eq 0 ]]; then
    warn "IOMMU の有効化が必要です。01-configure-iommu.sh を実行し再起動後、本スクリプトを再実行して確認してください。"
else
    ng "満たせていない条件があります。上記の NG 項目を解決してください。"
    exit 1
fi
