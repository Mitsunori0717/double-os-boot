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
SUDO=""
if [[ $EUID -ne 0 ]]; then
    VIRSH="sudo virsh"
    SUDO="sudo"
fi

if ! $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 起動定義 '$VM_NAME' がありません。baremetal/02-create-windows-vm.sh で作成してください。" >&2
    exit 1
fi

# 常時予約モード (02 の --reserve-at-boot) なら動的な確保・解放は行わない
BOOT_RESERVE_CONF=/etc/sysctl.d/90-double-os-boot-hugepages.conf

# Windows に割り当て済みのメモリ量から必要な HugePages 数 (2MB 単位) を算出
need_pages() {
    local mem_kib
    mem_kib=$($VIRSH dumpxml "$VM_NAME" | grep -oP '(?<=<memory unit=.KiB.>)[0-9]+' | head -1)
    echo $(( mem_kib / 2048 ))
}

free_pages()  { awk '/HugePages_Free/{print $2}'  /proc/meminfo; }
total_pages() { awk '/HugePages_Total/{print $2}' /proc/meminfo; }

# Windows 用メモリを確保する (起動直前に呼ぶ)
allocate_memory() {
    [[ -f "$BOOT_RESERVE_CONF" ]] && return 0
    local need cur_total cur_free target
    need=$(need_pages)
    cur_free=$(free_pages)
    (( cur_free >= need )) && return 0
    cur_total=$(total_pages)
    target=$(( cur_total - cur_free + need ))
    echo "Windows 用メモリを確保しています ($(( need * 2 / 1024 ))GB)..."
    $SUDO sysctl -qw vm.nr_hugepages="$target"
    if (( $(free_pages) < need )); then
        # 断片化している場合はメモリをデフラグして再試行
        echo "  メモリの断片化を解消して再試行しています..."
        echo 1 | $SUDO tee /proc/sys/vm/compact_memory >/dev/null
        sleep 2
        $SUDO sysctl -qw vm.nr_hugepages="$target"
    fi
    if (( $(free_pages) < need )); then
        echo "エラー: メモリを確保できませんでした ($(free_pages)/$need ページ)。" >&2
        echo "  対処: (a) Linux 側のメモリ使用量を減らして再実行" >&2
        echo "        (b) Linux を再起動してから再実行 (断片化の完全解消)" >&2
        echo "        (c) 常時予約モードに切り替える (README「メモリの分配」参照):" >&2
        echo "            echo \"vm.nr_hugepages = $need\" | sudo tee $BOOT_RESERVE_CONF && sudo reboot" >&2
        $SUDO sysctl -qw vm.nr_hugepages="$(( cur_total ))"   # 失敗時は元に戻す
        return 1
    fi
}

# Windows 停止後にメモリを Linux へ返す
release_memory() {
    [[ -f "$BOOT_RESERVE_CONF" ]] && return 0
    $SUDO sysctl -qw vm.nr_hugepages=0
    echo "Windows 用メモリを解放しました (Linux 側で利用可能になりました)。"
}

state=$($VIRSH domstate "$VM_NAME")

case "$ACTION" in
    status)
        echo "Windows ($VM_NAME): $state"
        exit 0
        ;;
    stop)
        if [[ "$state" == "running" ]]; then
            echo "Windows にシャットダウンを要求しました。終了を待っています..."
            $VIRSH shutdown "$VM_NAME"
            for _ in $(seq 1 60); do
                sleep 3
                [[ "$($VIRSH domstate "$VM_NAME")" == "shut off" ]] && break
            done
            if [[ "$($VIRSH domstate "$VM_NAME")" == "shut off" ]]; then
                echo "Windows が終了しました。"
                release_memory
            else
                echo "3 分待っても終了しません。Windows 側の画面を確認してください。"
                echo "(終了後のメモリ解放は次回の本スクリプト実行時に自動で行われます)"
            fi
        else
            echo "Windows は起動していません ($state)。"
            release_memory
        fi
        exit 0
        ;;
    force)
        read -rp "強制電源断します。保存していないデータは失われます。よろしいですか? (y/N): " ans
        if [[ "$ans" == "y" ]]; then
            $VIRSH destroy "$VM_NAME"
            release_memory
        fi
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

allocate_memory || exit 1

echo "Windows を起動しています... (モニター1に BIOS 画面 → Windows が表示されます)"
$VIRSH start "$VM_NAME"

echo
echo "起動しました。"
echo "  - 画面        : Windows 専有 GPU に接続されたモニターに直接表示されます"
echo "  - 終了        : Windows 内で通常どおりシャットダウン"
echo "  - ファイル共有: Windows 側から \\\\<LinuxのIP>\\shared (04 で設定した共有)"
echo "  - キーボード切替: 左右 Ctrl 同時押し (05 を設定した場合)"
