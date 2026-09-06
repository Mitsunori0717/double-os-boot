#!/usr/bin/env bash
#
# 様子を見ながらの性能調整: Windows への CPU / メモリ割り当てをあとから変更する
#
#   - PC 全体の再起動は不要。Windows (同時起動側) を一度シャットダウンして
#     本スクリプトを実行し、Windows を起動し直すだけで反映される
#   - Linux 側・FsBP 等の占有ソフトには一切影響しない
#
# 使い方:
#   bash 06-tune-resources.sh --show                 # 現在の割り当てと使用状況を表示
#   sudo bash 06-tune-resources.sh --cpuset 4-23     # Windows に渡す論理 CPU を変更
#   sudo bash 06-tune-resources.sh --memory 20       # Windows のメモリを 20GB に変更
#   sudo bash 06-tune-resources.sh --cpuset 2-27 --memory 24   # 同時変更も可
#
set -euo pipefail

VM_NAME="windows"
CPUSET=""
MEMORY_GB=""
SHOW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)   VM_NAME="$2";   shift 2 ;;
        --cpuset) CPUSET="$2";    shift 2 ;;
        --memory) MEMORY_GB="$2"; shift 2 ;;
        --show)   SHOW=1;         shift ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

VIRSH="virsh"
[[ $EUID -ne 0 ]] && VIRSH="sudo virsh"

if ! $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 起動定義 '$VM_NAME' がありません。" >&2
    exit 1
fi

if [[ $SHOW -eq 1 ]]; then
    echo "=== Windows ($VM_NAME) の現在の割り当て ==="
    $VIRSH dominfo "$VM_NAME" | grep -E "State|CPU|memory|メモリ|状態" || true
    echo
    echo "--- CPU ピンニング (vCPU → 物理論理CPU) ---"
    $VIRSH vcpupin "$VM_NAME" || true
    echo
    if [[ -d /sys/devices/cpu_core && -d /sys/devices/cpu_atom ]]; then
        echo "--- この CPU のコア構成 ---"
        echo "  P コア (高性能): 論理 CPU $(cat /sys/devices/cpu_core/cpus)"
        echo "  E コア (高効率): 論理 CPU $(cat /sys/devices/cpu_atom/cpus)"
        echo
    fi
    echo "--- HugePages (Windows 用に確保済みのメモリ) ---"
    grep -E "HugePages_Total|HugePages_Free|Hugepagesize" /proc/meminfo
    echo
    echo "観察のヒント:"
    echo "  Linux 側の負荷   : htop (Windows 専用コアが遊んでいるか、Linux 側が詰まっていないか)"
    echo "  Windows 側の負荷 : Windows 内のタスクマネージャー → パフォーマンス"
    echo "  → Windows の CPU が常時高いなら --cpuset で渡すコアを増やす、"
    echo "    Linux/FsBP 側が詰まるなら Windows 側を減らす、が基本方針です。"
    exit 0
fi

if [[ -z "$CPUSET" && -z "$MEMORY_GB" ]]; then
    echo "使い方: bash $0 --show | sudo bash $0 [--cpuset <範囲>] [--memory <GB>]" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "エラー: 変更には sudo が必要です。" >&2
    exit 1
fi

state=$(virsh domstate "$VM_NAME")
if [[ "$state" == "running" ]]; then
    echo "エラー: '$VM_NAME' が起動中です。Windows をシャットダウンしてから実行してください。" >&2
    echo "        (bash baremetal/03-start-windows.sh --stop)" >&2
    exit 1
fi

TOTAL_CPUS=$(nproc)

if [[ -n "$CPUSET" ]]; then
    if ! [[ "$CPUSET" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
        echo "エラー: --cpuset の形式が不正です (例: 4-23 または 4-15,16-23)" >&2
        exit 1
    fi
    CPUS=0
    IFS=',' read -ra ranges <<< "$CPUSET"
    for r in "${ranges[@]}"; do
        if [[ "$r" == *-* ]]; then
            lo="${r%-*}"; hi="${r#*-}"
            if (( lo > hi || hi >= TOTAL_CPUS )); then
                echo "エラー: 範囲 '$r' が不正です (論理 CPU は 0-$((TOTAL_CPUS-1)))" >&2
                exit 1
            fi
            CPUS=$(( CPUS + hi - lo + 1 ))
        else
            (( r < TOTAL_CPUS )) || { echo "エラー: 番号 '$r' が範囲外です" >&2; exit 1; }
            CPUS=$(( CPUS + 1 ))
        fi
    done
    if [[ $CPUS -ge $TOTAL_CPUS ]]; then
        echo "エラー: 全論理 CPU を Windows に渡すことはできません (Linux 側の分が必要)。" >&2
        exit 1
    fi
    echo "==> CPU 割り当てを変更: ${CPUS} スレッド (論理 CPU $CPUSET)"
    virt-xml "$VM_NAME" --edit --vcpus "$CPUS",cpuset="$CPUSET"
fi

if [[ -n "$MEMORY_GB" ]]; then
    if ! [[ "$MEMORY_GB" =~ ^[0-9]+$ ]]; then
        echo "エラー: --memory は GB 単位の整数で指定してください。" >&2
        exit 1
    fi
    echo "==> メモリ割り当てを変更: ${MEMORY_GB}GB"
    virt-xml "$VM_NAME" --edit \
        --memory memory=$(( MEMORY_GB * 1024 )),currentMemory=$(( MEMORY_GB * 1024 ))

    # 常時予約モード (02 の --reserve-at-boot) の場合のみ、予約量も合わせて更新。
    # 既定 (オンデマンド) では 03-start-windows.sh が起動時に新しい量を自動確保する。
    BOOT_RESERVE_CONF=/etc/sysctl.d/90-double-os-boot-hugepages.conf
    if [[ -f "$BOOT_RESERVE_CONF" ]]; then
        HUGEPAGES=$(( MEMORY_GB * 1024 / 2 ))
        cat > "$BOOT_RESERVE_CONF" <<EOF
vm.nr_hugepages = $HUGEPAGES
EOF
        sysctl -p "$BOOT_RESERVE_CONF" >/dev/null || true
        actual=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
        if (( actual < HUGEPAGES )); then
            echo "    注意: 常時予約の即時確保が ${actual}/${HUGEPAGES} ページに留まりました"
            echo "          (メモリ断片化)。増量分を確実に反映するには Linux を一度再起動してください。"
        fi
    fi
fi

echo
echo "変更を保存しました。次回の Windows 起動 (bash baremetal/03-start-windows.sh) から反映されます。"
echo "現在の設定確認: bash $0 --show"
