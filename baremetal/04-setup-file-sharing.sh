#!/usr/bin/env bash
#
# データ共有: Linux 側に Samba 共有を作成し、両 OS から同じフォルダを読み書きできるようにする
#
#   Linux 側   : /srv/shared (変更可)
#   Windows 側 : \\<LinuxのIP>\shared → Z: ドライブ等に割り当て
#
# ネイティブ・デュアルブート時 (排他起動) も、この共有フォルダは Linux 起動中いつでも
# LAN 内の他マシンから見えるため、そのまま使えます。
#
# 使い方:
#   sudo bash 04-setup-file-sharing.sh [--shared-dir /srv/shared] [--share-name shared]
#
set -euo pipefail

SHARED_DIR="/srv/shared"
SHARE_NAME="shared"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --shared-dir) SHARED_DIR="$2"; shift 2 ;;
        --share-name) SHARE_NAME="$2"; shift 2 ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "エラー: sudo で実行してください。" >&2
    exit 1
fi

LOGIN_USER="${SUDO_USER:-$(logname)}"

echo "==> Samba をインストールしています..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq samba

echo "==> 共有フォルダを作成しています: $SHARED_DIR"
mkdir -p "$SHARED_DIR"
chown "$LOGIN_USER":"$LOGIN_USER" "$SHARED_DIR"
chmod 775 "$SHARED_DIR"

SMB_CONF=/etc/samba/smb.conf
if ! grep -q "^\[$SHARE_NAME\]" "$SMB_CONF"; then
    cat >> "$SMB_CONF" <<EOF

# double-os-boot: Windows とのデータ共有
[$SHARE_NAME]
   path = $SHARED_DIR
   browseable = yes
   read only = no
   valid users = $LOGIN_USER
   create mask = 0664
   directory mask = 0775
EOF
    echo "    smb.conf に共有 [$SHARE_NAME] を追加しました。"
else
    echo "    smb.conf に共有 [$SHARE_NAME] は既に存在します。"
fi

echo "==> Samba ユーザーを設定します ($LOGIN_USER)。Windows からの接続時に使うパスワードを入力してください。"
smbpasswd -a "$LOGIN_USER"

systemctl enable --now smbd
systemctl restart smbd

# ファイアウォール (ufw 使用時のみ)
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow samba >/dev/null
    echo "    ufw で Samba を許可しました。"
fi

# libvirt の default ネットワーク (仮想ブリッジ) 側 IP と LAN 側 IP を表示
echo
echo "設定が完了しました。"
echo "  Linux 側フォルダ : $SHARED_DIR"
echo
echo "Windows 側での接続手順 (同時起動モード中の Windows 内で):"
VIRBR_IP=$(ip -4 addr show virbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
if [[ -n "${VIRBR_IP:-}" ]]; then
    echo "  1. エクスプローラーのアドレス欄に  \\\\$VIRBR_IP\\$SHARE_NAME"
else
    echo "  1. エクスプローラーのアドレス欄に  \\\\<LinuxのIP>\\$SHARE_NAME"
fi
echo "  2. ユーザー名 $LOGIN_USER と上で設定したパスワードを入力"
echo "  3. 右クリック →「ネットワークドライブの割り当て」で Z: 等に固定すると便利です"
