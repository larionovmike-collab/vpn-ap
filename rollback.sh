#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly STATE_FILE=/var/lib/vpn-ap-installer/state.env
readonly LOG_FILE=/var/log/vpn-ap-installer.log
TTY=/dev/tty

log() { printf '%s | ROLLBACK | %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -r $STATE_FILE ]] || die "Deployment state was not found at $STATE_FILE."
# The state file is root-owned, mode 0600, and generated with shell-escaped values.
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -d $BACKUP_DIR && -r $BACKUP_DIR/manifest ]] || die "Backup is missing: $BACKUP_DIR"

printf 'Rollback deployment using backup %s? [y/N]: ' "$BACKUP_DIR" >"$TTY"
IFS= read -r answer <"$TTY"
[[ $answer == y || $answer == Y ]] || exit 0

systemctl disable --now vpn-ap-watchdog.timer vpn-ap-watchdog.service \
    vpn-ap-transparent.service vpn-ap-redsocks.service vpn-ap-socks.service 2>/dev/null || true
systemctl disable --now hostapd.service dnsmasq.service dnscrypt-proxy.service \
    redsocks.service vpn-ap-interface.service 2>/dev/null || true

iptables -t nat -D PREROUTING -i wlan0 -s "$AP_SUBNET" -p tcp -j VPN_AP_REDSOCKS 2>/dev/null || true
iptables -D FORWARD -j VPN_AP_FAIL_CLOSED 2>/dev/null || true
iptables -t nat -F VPN_AP_REDSOCKS 2>/dev/null || true
iptables -t nat -X VPN_AP_REDSOCKS 2>/dev/null || true
iptables -F VPN_AP_FAIL_CLOSED 2>/dev/null || true
iptables -X VPN_AP_FAIL_CLOSED 2>/dev/null || true
ip6tables -D FORWARD -j VPN_AP6_FAIL_CLOSED 2>/dev/null || true
ip6tables -F VPN_AP6_FAIL_CLOSED 2>/dev/null || true
ip6tables -X VPN_AP6_FAIL_CLOSED 2>/dev/null || true
ip address del "$AP_GATEWAY/24" dev wlan0 2>/dev/null || true

while IFS='|' read -r path status; do
    if [[ $status == present ]]; then
        install -d "$(dirname "$path")"
        cp -a "$BACKUP_DIR/files/${path#/}" "$path"
    else
        rm -f "$path"
    fi
done <"$BACKUP_DIR/manifest"

systemctl daemon-reload
if command -v nmcli >/dev/null; then nmcli general reload || true; fi

if [[ -r $BACKUP_DIR/services-state.txt ]]; then
    while IFS='|' read -r service was_active was_enabled; do
        if [[ $was_enabled == enabled ]]; then systemctl enable "$service" 2>/dev/null || true; fi
        if [[ $was_active == active ]]; then systemctl start "$service" 2>/dev/null || true; fi
    done <"$BACKUP_DIR/services-state.txt"
fi

if [[ ${REMOTE_KEY_ADDED:-0} == 1 ]]; then
    printf 'VPS SSH password (to remove only the installer key): ' >"$TTY"
    IFS= read -r -s VPS_PASSWORD <"$TTY"
    printf '\n' >"$TTY"
    KNOWN_HOSTS=/var/lib/vpn-ap-installer/vps-known_hosts
    printf '%s\n' "$PUBKEY_BLOB" | SSHPASS="$VPS_PASSWORD" sshpass -e ssh \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no "$VPS_USER@$VPS_HOST" \
        'set -eu; umask 077; read -r blob; mkdir -p "$HOME/.vpn-ap-backups"; cp -a "$HOME/.ssh/authorized_keys" "$HOME/.vpn-ap-backups/authorized_keys.rollback.$(date +%Y%m%d-%H%M%S)"; tmp=$(mktemp); awk -v blob="$blob" '\''index($0, blob) == 0'\'' "$HOME/.ssh/authorized_keys" >"$tmp"; cat "$tmp" >"$HOME/.ssh/authorized_keys"; rm -f "$tmp"'
    unset VPS_PASSWORD SSHPASS
    log "Installer forwarding key removed from VPS after a remote authorized_keys backup"
fi

log "Rollback completed. Package installation was intentionally retained."
printf 'Rollback complete. Reboot is not required; inspect services and networking before any reboot.\n' >"$TTY"
