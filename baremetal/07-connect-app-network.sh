#!/usr/bin/env bash
#
# Windows の FsBP クライアントアプリ ⇔ Linux の FsBP 本体 の接続設定
#
# 仕組み:
#   同時起動モードでは、Linux と Windows の間に常設の内部ネットワークがあります
#   (libvirt default ネットワーク / virbr0)。物理 LAN やインターネットを経由しない
#   OS 間直結の仮想イーサネットで、遅延は 1ms 未満です。
#
#     Windows 側から見た Linux (FsBP 本体) のアドレス: 192.168.122.1 (固定・不変)
#     Linux 側から見た Windows のアドレス            : --static-vm-ip で固定可能
#
# 使い方:
#   bash 07-connect-app-network.sh --show
#       現在の接続情報 (両側の IP・疎通) を表示
#
#   sudo bash 07-connect-app-network.sh --allow-ports "502/tcp,4840/tcp"
#       FsBP が待ち受けるポートを Windows からの接続向けに開放
#       (ポート番号は FsBP のマニュアル/設定画面で確認)
#
#   sudo bash 07-connect-app-network.sh --static-vm-ip 192.168.122.50
#       Windows 側の IP を固定 (Linux → Windows 方向の接続や監視に必要な場合)
#
#   sudo bash 07-connect-app-network.sh --add-lan-nic enp3s0
#       (任意) Windows を物理 LAN にも直接参加させる 2 枚目の NIC を追加
#       Windows アプリが工場ラインの機器へ直接アクセスする必要がある場合のみ
#
set -euo pipefail

VM_NAME="windows"
SHOW=0
ALLOW_PORTS=""
STATIC_IP=""
LAN_IFACE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)          VM_NAME="$2";     shift 2 ;;
        --show)          SHOW=1;           shift ;;
        --allow-ports)   ALLOW_PORTS="$2"; shift 2 ;;
        --static-vm-ip)  STATIC_IP="$2";   shift 2 ;;
        --add-lan-nic)   LAN_IFACE="$2";   shift 2 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

VIRSH="virsh"
[[ $EUID -ne 0 ]] && VIRSH="sudo virsh"

if ! $VIRSH dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "エラー: 起動定義 '$VM_NAME' がありません。" >&2
    exit 1
fi

HOST_IP=$(ip -4 addr show virbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
HOST_IP="${HOST_IP:-192.168.122.1}"

if [[ $SHOW -eq 1 || ( -z "$ALLOW_PORTS" && -z "$STATIC_IP" && -z "$LAN_IFACE" ) ]]; then
    echo "=== OS 間ネットワークの接続情報 ==="
    echo
    echo "Linux (FsBP 本体) 側:"
    echo "  Windows から接続するアドレス : $HOST_IP  ← FsBP クライアントの接続先にこれを設定"
    echo
    echo "Windows 側:"
    vm_state=$($VIRSH domstate "$VM_NAME")
    if [[ "$vm_state" == "running" ]]; then
        $VIRSH domifaddr "$VM_NAME" 2>/dev/null | tail -n +3 | head -5 || true
        vm_ip=$($VIRSH domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        if [[ -n "${vm_ip:-}" ]]; then
            echo "  Linux から Windows へのアドレス: $vm_ip"
            if ping -c1 -W2 "$vm_ip" >/dev/null 2>&1; then
                echo "  疎通: OK (ping 応答あり)"
            else
                echo "  疎通: ping 応答なし (Windows Defender ファイアウォールが ICMP を止めている可能性。TCP 接続には影響しない場合があります)"
            fi
        fi
    else
        echo "  (Windows は現在停止中です。起動すると IP が表示されます)"
    fi
    echo
    echo "FsBP の待ち受けポートの確認 (Linux 側で FsBP 起動中に):"
    echo "  ss -tlnp | grep -i FsBP    または    sudo ss -tlnp"
    echo
    echo "接続できない場合:"
    echo "  1. sudo bash $0 --allow-ports \"<ポート>/tcp\"   でポート開放"
    echo "  2. docs/TROUBLESHOOTING.md の「アプリ連携」節を参照"
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    echo "エラー: 設定変更には sudo が必要です。" >&2
    exit 1
fi

# --- ポート開放 (Windows → Linux 方向、内部ネットワークからのみ許可) ---
if [[ -n "$ALLOW_PORTS" ]]; then
    if ! [[ "$ALLOW_PORTS" =~ ^[0-9]+/(tcp|udp)(,[0-9]+/(tcp|udp))*$ ]]; then
        echo "エラー: --allow-ports の形式が不正です (例: 502/tcp,4840/tcp,5000/udp)" >&2
        exit 1
    fi
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
        IFS=',' read -ra ports <<< "$ALLOW_PORTS"
        for p in "${ports[@]}"; do
            port="${p%/*}"; proto="${p#*/}"
            ufw allow from 192.168.122.0/24 to any port "$port" proto "$proto" \
                comment "double-os-boot: FsBP app" >/dev/null
            echo "  開放: $port/$proto (内部ネットワーク 192.168.122.0/24 からのみ)"
        done
    else
        echo "  ufw は無効です。Linux 側でポートを塞ぐ設定が無ければ、そのまま接続できます。"
        echo "  (別のファイアウォールを使っている場合は 192.168.122.0/24 からの $ALLOW_PORTS を許可してください)"
    fi
fi

# --- Windows 側 IP の固定 (DHCP 予約) ---
if [[ -n "$STATIC_IP" ]]; then
    if ! [[ "$STATIC_IP" =~ ^192\.168\.122\.[0-9]+$ ]]; then
        echo "エラー: --static-vm-ip は 192.168.122.x の範囲で指定してください。" >&2
        exit 1
    fi
    mac=$(virsh domiflist "$VM_NAME" | awk '/network/{print $5; exit}')
    if [[ -z "$mac" ]]; then
        echo "エラー: '$VM_NAME' の内部ネットワーク NIC が見つかりません。" >&2
        exit 1
    fi
    flags=(--config)
    virsh net-list | grep -q "default.*active" && flags+=(--live)
    if virsh net-update default add ip-dhcp-host \
        "<host mac='$mac' ip='$STATIC_IP'/>" "${flags[@]}" 2>/dev/null; then
        echo "  Windows の IP を $STATIC_IP に固定しました (MAC: $mac)。"
        echo "  反映には Windows の再起動 (またはネットワーク再接続) が必要です。"
    else
        echo "  注意: 予約の追加に失敗しました。既に登録済みの可能性があります:" >&2
        virsh net-dumpxml default | grep "host mac" | sed 's/^/    /' >&2
    fi
fi

# --- (任意) 物理 LAN 直結 NIC の追加 ---
if [[ -n "$LAN_IFACE" ]]; then
    if ! ip link show "$LAN_IFACE" >/dev/null 2>&1; then
        echo "エラー: インターフェース '$LAN_IFACE' が見つかりません (ip link で確認)。" >&2
        exit 1
    fi
    if [[ "$(virsh domstate "$VM_NAME")" == "running" ]]; then
        echo "エラー: NIC の追加は Windows を停止してから実行してください。" >&2
        exit 1
    fi
    virt-xml "$VM_NAME" --add-device \
        --network "type=direct,source=$LAN_IFACE,source.mode=bridge,model=e1000e"
    echo "  物理 LAN ($LAN_IFACE) 直結の NIC を追加しました。"
    echo "  Windows は次回起動時、工場ラインの LAN に直接参加します (IP はラインの DHCP/固定設定に従う)。"
    echo "  注意: この NIC 経由では Linux ⇔ Windows の直接通信はできません (macvtap の仕様)。"
    echo "        OS 間の通信は引き続き内部ネットワーク ($HOST_IP) を使ってください。"
fi

echo
echo "完了しました。接続情報の確認: bash $0 --show"
