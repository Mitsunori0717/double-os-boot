#!/usr/bin/env bash
#
# Linux ゲスト (Ubuntu / Debian 系) のセットアップスクリプト
#
# 行うこと:
#   1. Hyper-V 統合サービス (IP 通知・時刻同期など) のインストール
#   2. xrdp のインストールと有効化 (Windows 側から RDP で全画面表示するため)
#   3. Windows の共有フォルダ (SMB) を /mnt/shared に自動マウント
#
# 使い方 (Ubuntu のターミナルで):
#   sudo bash setup-guest.sh --host-ip 192.168.1.10 --share-user taro [--share-name Shared] [--mount-point /mnt/shared]
#
set -euo pipefail

HOST_IP=""
SHARE_USER=""
SHARE_NAME="Shared"
MOUNT_POINT="/mnt/shared"

usage() {
    echo "使い方: sudo bash $0 --host-ip <WindowsホストのIP> --share-user <Windowsユーザー名> [--share-name Shared] [--mount-point /mnt/shared]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-ip)     HOST_IP="$2";     shift 2 ;;
        --share-user)  SHARE_USER="$2";  shift 2 ;;
        --share-name)  SHARE_NAME="$2";  shift 2 ;;
        --mount-point) MOUNT_POINT="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$HOST_IP" && -n "$SHARE_USER" ]] || usage

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi

# sudo 実行時の実際のログインユーザー (共有フォルダの所有者にする)
LOGIN_USER="${SUDO_USER:-$(logname)}"
LOGIN_UID=$(id -u "$LOGIN_USER")
LOGIN_GID=$(id -g "$LOGIN_USER")

echo "==> パッケージをインストールしています..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    linux-tools-virtual linux-cloud-tools-virtual \
    xrdp \
    cifs-utils

echo "==> xrdp を有効化しています..."
# Ubuntu の既定セッションで xrdp から色プロファイル等の認証ダイアログが出ないようにする
POLKIT_DIR=/etc/polkit-1/localauthority/50-local.d
if [[ -d /etc/polkit-1 ]]; then
    mkdir -p "$POLKIT_DIR"
    cat > "$POLKIT_DIR/45-allow-colord.pkla" <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
fi
adduser xrdp ssl-cert >/dev/null 2>&1 || true
systemctl enable --now xrdp

echo "==> 共有フォルダの自動マウントを設定しています..."
CRED_FILE=/etc/cifs-credentials
if [[ ! -f "$CRED_FILE" ]]; then
    echo "Windows 側の認証情報を入力してください (共有フォルダ接続用)。"
    read -rp "Windows ユーザー名 [$SHARE_USER]: " input_user
    input_user="${input_user:-$SHARE_USER}"
    read -rsp "Windows パスワード: " input_pass
    echo
    cat > "$CRED_FILE" <<EOF
username=$input_user
password=$input_pass
EOF
    chmod 600 "$CRED_FILE"
fi

mkdir -p "$MOUNT_POINT"

FSTAB_LINE="//$HOST_IP/$SHARE_NAME $MOUNT_POINT cifs credentials=$CRED_FILE,uid=$LOGIN_UID,gid=$LOGIN_GID,iocharset=utf8,file_mode=0664,dir_mode=0775,nofail,_netdev,x-systemd.automount 0 0"
if ! grep -qF "//$HOST_IP/$SHARE_NAME " /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
else
    echo "    /etc/fstab に既存のエントリがあるためスキップしました。"
fi

systemctl daemon-reload
if mount "$MOUNT_POINT" 2>/dev/null || mountpoint -q "$MOUNT_POINT"; then
    echo "    共有フォルダを $MOUNT_POINT にマウントしました。"
else
    echo "    警告: マウントに失敗しました。IP・共有名・認証情報を確認してください。" >&2
    echo "    手動確認: sudo mount -t cifs //$HOST_IP/$SHARE_NAME $MOUNT_POINT -o credentials=$CRED_FILE" >&2
fi

echo
echo "セットアップが完了しました。"
echo "  - 共有フォルダ : //$HOST_IP/$SHARE_NAME -> $MOUNT_POINT (起動時に自動マウント)"
echo "  - xrdp        : 有効 (ポート 3389)"
echo
echo "重要: RDP 接続時は Linux のこのデスクトップからログアウトしておいてください。"
echo "      (同一ユーザーでのローカルログインと RDP ログインは同時にできません)"
echo
echo "次の手順: Windows 側で windows\\04-launch-linux-monitor2.ps1 を実行すると、"
echo "          モニター2 にこの Linux が全画面表示されます。"
