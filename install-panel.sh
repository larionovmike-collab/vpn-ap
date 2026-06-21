#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly PANEL_DIR=/opt/vpn-ap-panel
readonly CONFIG_DIR=/etc/vpn-ap-installer
readonly BACKUP_ROOT=/var/backups/vpn-ap-installer
readonly RAW_BASE_DEFAULT=https://raw.githubusercontent.com/larionovmike-collab/vpn-ap/refs/heads/main
TTY=/dev/tty

log() { printf '%s | PANEL | %s\n' "$(date -Is)" "$*" | tee -a /var/log/vpn-ap-installer.log; }
die() { log "ERROR: $*"; exit 1; }
prompt() { local var=$1 text=$2 default=$3 value; printf '%s [%s]: ' "$text" "$default" >"$TTY"; IFS= read -r value <"$TTY"; printf -v "$var" '%s' "${value:-$default}"; }
secret() { local var=$1 text=$2 value; printf '%s: ' "$text" >"$TTY"; IFS= read -r -s value <"$TTY"; printf '\n' >"$TTY"; printf -v "$var" '%s' "$value"; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -r $TTY && -w $TTY ]] || die "An interactive terminal is required."
log "Starting wired HTTPS panel installation"
[[ -r /var/lib/vpn-ap-installer/state.env ]] || die "Install the VPN AP before installing the panel."

LAN_IF=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[[ -n $LAN_IF && $LAN_IF != wlan0 ]] || die "The wired management/default interface was not found."
LAN_CIDR=$(ip -o -4 address show dev "$LAN_IF" scope global | awk 'NR==1 {print $4}')
[[ -n $LAN_CIDR ]] || die "The wired interface has no IPv4 address."
LAN_IP=${LAN_CIDR%/*}
log "Wired interface detected: $LAN_IF ($LAN_CIDR)"

prompt PANEL_USER "Panel administrator login" "admin"
[[ $PANEL_USER =~ ^[A-Za-z_][A-Za-z0-9_.-]{2,31}$ ]] || die "Invalid panel login."
secret PANEL_PASSWORD "Panel administrator password (minimum 12 characters)"
(( ${#PANEL_PASSWORD} >= 12 )) || die "Panel password is too short."
secret PANEL_PASSWORD_CONFIRM "Repeat panel administrator password"
[[ $PANEL_PASSWORD == "$PANEL_PASSWORD_CONFIRM" ]] || die "Passwords do not match."
unset PANEL_PASSWORD_CONFIRM

export DEBIAN_FRONTEND=noninteractive
log "Installing panel dependencies"
apt-get update
apt-get install -y python3 openssl curl

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_ROOT/panel-$TIMESTAMP"
mkdir -p "$BACKUP/files"
TARGETS=(
    "$PANEL_DIR/vpn_ap_panel.py" "$PANEL_DIR/index.html"
    "$CONFIG_DIR/panel-auth.json" "$CONFIG_DIR/panel.crt" "$CONFIG_DIR/panel.key"
    /usr/local/sbin/vpn-ap-panel-start /usr/local/sbin/vpn-ap-change-vps
    /etc/systemd/system/vpn-ap-panel.service /var/lib/vpn-ap-installer/panel-backup
)
for path in "${TARGETS[@]}"; do
    if [[ -e $path ]]; then
        mkdir -p "$BACKUP/files/$(dirname "${path#/}")"
        cp -a "$path" "$BACKUP/files/${path#/}"
        printf '%s|present\n' "$path" >>"$BACKUP/manifest"
    else
        printf '%s|absent\n' "$path" >>"$BACKUP/manifest"
    fi
done
log "Panel targets backed up to $BACKUP"
printf '%s\n' "$BACKUP" >/var/lib/vpn-ap-installer/panel-backup
chmod 600 /var/lib/vpn-ap-installer/panel-backup

SOURCE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ -r "$SOURCE_ROOT/panel/vpn_ap_panel.py" && -r "$SOURCE_ROOT/panel/index.html" ]]; then
    cp "$SOURCE_ROOT/panel/vpn_ap_panel.py" "$TMP/"
    cp "$SOURCE_ROOT/panel/index.html" "$TMP/"
    CHANGE_VPS_SOURCE="$SOURCE_ROOT/change-vps.sh"
else
    RAW_BASE=${VPN_AP_RAW_BASE:-$RAW_BASE_DEFAULT}
    log "Downloading panel assets from $RAW_BASE"
    curl -fsSL "$RAW_BASE/panel/vpn_ap_panel.py" -o "$TMP/vpn_ap_panel.py"
    curl -fsSL "$RAW_BASE/panel/index.html" -o "$TMP/index.html"
    curl -fsSL "$RAW_BASE/change-vps.sh" -o "$TMP/change-vps.sh"
    CHANGE_VPS_SOURCE="$TMP/change-vps.sh"
fi
python3 -m py_compile "$TMP/vpn_ap_panel.py"
grep -q '<title>VPN AP</title>' "$TMP/index.html" || die "Panel HTML validation failed."

install -D -o root -g root -m 0755 "$TMP/vpn_ap_panel.py" "$PANEL_DIR/vpn_ap_panel.py"
install -D -o root -g root -m 0644 "$TMP/index.html" "$PANEL_DIR/index.html"
if [[ -r $CHANGE_VPS_SOURCE ]]; then
    install -D -o root -g root -m 0755 "$CHANGE_VPS_SOURCE" /usr/local/sbin/vpn-ap-change-vps
fi

PASSWORD_INPUT=$(mktemp)
printf '%s' "$PANEL_PASSWORD" >"$PASSWORD_INPUT"
unset PANEL_PASSWORD
python3 - "$PANEL_USER" "$PASSWORD_INPUT" "$CONFIG_DIR/panel-auth.json" <<'PY'
import base64, hashlib, json, os, sys
username, password_file, output = sys.argv[1:]
password = open(password_file, encoding='utf-8').read()
salt = os.urandom(16)
digest = hashlib.scrypt(password.encode(), salt=salt, n=2**15, r=8, p=1, dklen=32, maxmem=64 * 1024 * 1024)
os.makedirs(os.path.dirname(output), exist_ok=True)
with open(output, 'w', encoding='utf-8') as f:
    json.dump({'username': username, 'salt': base64.b64encode(salt).decode(), 'digest': base64.b64encode(digest).decode()}, f)
os.chmod(output, 0o600)
PY
rm -f "$PASSWORD_INPUT"

mkdir -p "$CONFIG_DIR"
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=$LAN_IP" -addext "subjectAltName=IP:$LAN_IP" \
    -keyout "$CONFIG_DIR/panel.key" -out "$CONFIG_DIR/panel.crt" >/dev/null 2>&1
chmod 600 "$CONFIG_DIR/panel.key" "$CONFIG_DIR/panel.crt"

cat >/usr/local/sbin/vpn-ap-panel-start <<'EOF'
#!/bin/sh
set -eu
iface=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -n "$iface" ] && [ "$iface" != wlan0 ]
cidr=$(ip -o -4 address show dev "$iface" scope global | awk 'NR==1 {print $4}')
[ -n "$cidr" ]
address=${cidr%/*}
exec /usr/bin/python3 /opt/vpn-ap-panel/vpn_ap_panel.py \
  --bind "$address" --network "$cidr" --port 8443 \
  --cert /etc/vpn-ap-installer/panel.crt --key /etc/vpn-ap-installer/panel.key \
  --auth /etc/vpn-ap-installer/panel-auth.json \
  --state /var/lib/vpn-ap-installer/state.env \
  --index /opt/vpn-ap-panel/index.html \
  --change-vps /usr/local/sbin/vpn-ap-change-vps
EOF
chmod 755 /usr/local/sbin/vpn-ap-panel-start

cat >/etc/systemd/system/vpn-ap-panel.service <<'EOF'
[Unit]
Description=VPN AP local wired HTTPS panel
After=network-online.target vpn-ap-socks.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/vpn-ap-panel-start
Restart=on-failure
RestartSec=3s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemd-analyze verify vpn-ap-panel.service
systemctl enable --now vpn-ap-panel.service
systemctl is-active --quiet vpn-ap-panel.service || die "Panel service failed to start."
curl --insecure --fail --silent "https://$LAN_IP:8443/" | grep -q '<title>VPN AP</title>' || die "Panel HTTPS check failed."
log "Panel installed successfully on wired interface $LAN_IF"
printf '\nPanel ready: https://%s:8443\nLogin: %s\nBackup: %s\n' "$LAN_IP" "$PANEL_USER" "$BACKUP" >"$TTY"
