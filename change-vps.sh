#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly STATE_FILE=/var/lib/vpn-ap-installer/state.env
readonly LOG_FILE=/var/log/vpn-ap-installer.log
readonly SOCKS_PORT=1080
readonly TEST_PORT=1099
TTY=/dev/tty
COMMITTED=0
TEST_PID=""
NEW_FIREWALL_RULE_ADDED=0

log() { printf '%s | CHANGE-VPS | %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }

cleanup_test() {
    if [[ -n ${TEST_PID:-} ]]; then
        kill "$TEST_PID" 2>/dev/null || true
        wait "$TEST_PID" 2>/dev/null || true
    fi
    rm -f "${TMP_PASSWORD:-}" "${TMP_HOSTS:-}"
}

rollback_committed_change() {
    set +e
    if (( COMMITTED )); then
        log "Switch failed; restoring previous VPS configuration"
        for path in \
            /var/lib/vpn-ap-installer/vps-known_hosts \
            /etc/vpn-ap-installer/vps-password \
            /etc/systemd/system/vpn-ap-socks.service \
            /usr/local/sbin/vpn-ap-transparent-up \
            /usr/local/sbin/vpn-ap-watchdog \
            /var/lib/vpn-ap-installer/state.env; do
            encoded=${path#/}
            if [[ -e "$CHANGE_BACKUP/files/$encoded" ]]; then
                install -d "$(dirname "$path")"
                cp -a "$CHANGE_BACKUP/files/$encoded" "$path"
            else
                rm -f "$path"
            fi
        done
        if (( NEW_FIREWALL_RULE_ADDED )); then
            iptables -t nat -D VPN_AP_REDSOCKS -d "$NEW_VPS_HOST/32" -j RETURN 2>/dev/null || true
        fi
        systemctl daemon-reload
        systemctl restart vpn-ap-socks.service vpn-ap-redsocks.service vpn-ap-transparent.service 2>/dev/null || true
        COMMITTED=0
    fi
}

die() {
    log "ERROR: $*"
    rollback_committed_change
    exit 1
}

restore_on_error() {
    local rc=$?
    set +e
    cleanup_test
    rollback_committed_change
    exit "$rc"
}
trap restore_on_error ERR
trap cleanup_test EXIT

prompt() {
    local variable=$1 label=$2 default=${3:-} value
    printf '%s [%s]: ' "$label" "$default" >"$TTY"
    IFS= read -r value <"$TTY"
    printf -v "$variable" '%s' "${value:-$default}"
}

prompt_secret() {
    local variable=$1 label=$2 value
    printf '%s: ' "$label" >"$TTY"
    IFS= read -r -s value <"$TTY"
    printf '\n' >"$TTY"
    printf -v "$variable" '%s' "$value"
}

validate_ipv4() {
    local value=$1 octet octets
    [[ $value =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$value"
    for octet in "${octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}

backup_path() {
    local path=$1 encoded=${1#/}
    if [[ -e $path || -L $path ]]; then
        mkdir -p "$CHANGE_BACKUP/files/$(dirname "$encoded")"
        cp -a "$path" "$CHANGE_BACKUP/files/$encoded"
    fi
}

wait_for_port() {
    local attempts=25
    while (( attempts-- > 0 )); do
        timeout 1 bash -c "</dev/tcp/127.0.0.1/$SOCKS_PORT" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -r $TTY && -w $TTY ]] || die "An interactive terminal is required."
[[ -r $STATE_FILE ]] || die "The existing deployment state was not found."
# shellcheck disable=SC1090
source "$STATE_FILE"

OLD_VPS_HOST=$VPS_HOST
OLD_AUTH_MODE=${AUTH_MODE:-unknown}
OLD_REMOTE_KEY_ADDED=${REMOTE_KEY_ADDED:-0}
OLD_EXPECTED_IP=${EXPECTED_IP:-}
DEFAULT_IF=$(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')

prompt NEW_VPS_HOST "New VPS IPv4 address" "$OLD_VPS_HOST"
prompt NEW_VPS_USER "New VPS SSH login" "${VPS_USER:-root}"
prompt_secret NEW_VPS_PASSWORD "New VPS SSH password"
validate_ipv4 "$NEW_VPS_HOST" || die "Invalid VPS IPv4 address."
[[ $NEW_VPS_USER =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || die "Invalid VPS login."
[[ -n $NEW_VPS_PASSWORD ]] || die "VPS password cannot be empty."

TMP_HOSTS=$(mktemp)
TMP_PASSWORD=$(mktemp)
chmod 600 "$TMP_PASSWORD"
printf '%s\n' "$NEW_VPS_PASSWORD" >"$TMP_PASSWORD"
unset NEW_VPS_PASSWORD

ssh-keyscan -T 8 -H "$NEW_VPS_HOST" >"$TMP_HOSTS" 2>/dev/null
[[ -s $TMP_HOSTS ]] || die "Could not retrieve the new VPS SSH host key."
printf '\nNew VPS SSH host key fingerprint:\n' >"$TTY"
ssh-keygen -lf "$TMP_HOSTS" >"$TTY"
printf 'Confirm that this fingerprint belongs to the new VPS [y/N]: ' >"$TTY"
IFS= read -r answer <"$TTY"
[[ $answer == y || $answer == Y ]] || die "Fingerprint was not accepted."

log "Testing the new VPS in parallel; the current tunnel remains active"
timeout 30 sshpass -f "$TMP_PASSWORD" ssh -n -N -T -D "127.0.0.1:$TEST_PORT" \
    -p 22 -o PreferredAuthentications=password,keyboard-interactive \
    -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TMP_HOSTS" \
    "$NEW_VPS_USER@$NEW_VPS_HOST" &
TEST_PID=$!
sleep 3
kill -0 "$TEST_PID" 2>/dev/null || die "The new password tunnel did not start."
NEW_EXPECTED_IP=$(curl --socks5-hostname "127.0.0.1:$TEST_PORT" \
    --connect-timeout 8 --max-time 20 --fail --silent \
    https://1.1.1.1/cdn-cgi/trace | awk -F= '$1=="ip" {print $2}')
validate_ipv4 "$NEW_EXPECTED_IP" || die "The new tunnel did not provide a valid Internet exit IPv4."
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true
TEST_PID=""
log "New tunnel passed end-to-end test; exit IPv4 is $NEW_EXPECTED_IP"

CHANGE_BACKUP="/var/backups/vpn-ap-installer/vps-change-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CHANGE_BACKUP"
for path in \
    /var/lib/vpn-ap-installer/vps-known_hosts \
    /etc/vpn-ap-installer/vps-password \
    /etc/systemd/system/vpn-ap-socks.service \
    /usr/local/sbin/vpn-ap-transparent-up \
    /usr/local/sbin/vpn-ap-watchdog \
    /var/lib/vpn-ap-installer/state.env; do backup_path "$path"; done
log "Current VPS configuration backed up to $CHANGE_BACKUP"

COMMITTED=1
install -D -o root -g root -m 600 "$TMP_HOSTS" /var/lib/vpn-ap-installer/vps-known_hosts
install -D -o root -g root -m 600 "$TMP_PASSWORD" /etc/vpn-ap-installer/vps-password

cat >/etc/systemd/system/vpn-ap-socks.service <<EOF
[Unit]
Description=VPN AP SSH SOCKS5 tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/sshpass -f /etc/vpn-ap-installer/vps-password /usr/bin/ssh -N -T -D 127.0.0.1:$SOCKS_PORT -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectionAttempts=3 -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/var/lib/vpn-ap-installer/vps-known_hosts $NEW_VPS_USER@$NEW_VPS_HOST
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/vpn-ap-socks.service

python3 - "$OLD_VPS_HOST" "$NEW_VPS_HOST" /usr/local/sbin/vpn-ap-transparent-up <<'PY'
from pathlib import Path
import sys
old, new, filename = sys.argv[1:]
path = Path(filename)
text = path.read_text()
needle = old + '/32'
if needle not in text:
    raise SystemExit('Old VPS exclusion was not found in transparent firewall script')
path.write_text(text.replace(needle, new + '/32'))
PY
chmod 755 /usr/local/sbin/vpn-ap-transparent-up

cat >/usr/local/sbin/vpn-ap-watchdog <<EOF
#!/bin/sh
set -eu
STATE=/run/vpn-ap-watchdog.failures
if output=\$(curl --socks5-hostname 127.0.0.1:$SOCKS_PORT --connect-timeout 5 --max-time 12 --fail --silent https://1.1.1.1/cdn-cgi/trace 2>/dev/null) && printf '%s\n' "\$output" | grep -qx 'ip=$NEW_EXPECTED_IP'; then
    rm -f "\$STATE"
    exit 0
fi
failures=0
if [ -r "\$STATE" ]; then failures=\$(cat "\$STATE" 2>/dev/null || printf 0); fi
failures=\$((failures + 1))
printf '%s\n' "\$failures" >"\$STATE"
if [ "\$failures" -ge 2 ]; then
    logger -t vpn-ap-watchdog 'SOCKS check failed twice; restarting tunnel stack'
    systemctl restart vpn-ap-socks.service
    systemctl restart vpn-ap-redsocks.service
    systemctl restart vpn-ap-transparent.service
    rm -f "\$STATE"
fi
EOF
chmod 755 /usr/local/sbin/vpn-ap-watchdog

if ! iptables -t nat -C VPN_AP_REDSOCKS -d "$NEW_VPS_HOST/32" -j RETURN 2>/dev/null; then
    iptables -t nat -I VPN_AP_REDSOCKS 1 -d "$NEW_VPS_HOST/32" -j RETURN
    NEW_FIREWALL_RULE_ADDED=1
fi
systemctl daemon-reload
systemctl restart vpn-ap-socks.service
wait_for_port || die "Permanent SOCKS listener did not recover."
FINAL_IP=$(curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" --connect-timeout 8 \
    --max-time 20 --fail --silent https://1.1.1.1/cdn-cgi/trace | awk -F= '$1=="ip" {print $2}')
[[ $FINAL_IP == "$NEW_EXPECTED_IP" ]] || die "Permanent tunnel exit IP verification failed."
systemctl restart vpn-ap-redsocks.service vpn-ap-transparent.service
systemctl start vpn-ap-watchdog.service
systemctl is-active --quiet vpn-ap-socks.service
systemctl is-active --quiet vpn-ap-redsocks.service
systemctl is-active --quiet vpn-ap-transparent.service
[[ $(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}') == "$DEFAULT_IF" ]] || die "Default route changed unexpectedly."

{
    printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
    printf 'VPS_HOST=%q\n' "$NEW_VPS_HOST"
    printf 'VPS_USER=%q\n' "$NEW_VPS_USER"
    printf 'AP_SSID=%q\n' "$AP_SSID"
    printf 'AP_SUBNET=%q\n' "$AP_SUBNET"
    printf 'AP_GATEWAY=%q\n' "$AP_GATEWAY"
    printf 'AUTH_MODE=%q\n' password
    printf 'EXPECTED_IP=%q\n' "$NEW_EXPECTED_IP"
    printf 'PUBKEY_BLOB=%q\n' ""
    printf 'REMOTE_KEY_ADDED=%q\n' 0
    printf 'LAST_VPS_CHANGE_BACKUP=%q\n' "$CHANGE_BACKUP"
} >"$STATE_FILE"
chmod 600 "$STATE_FILE"

COMMITTED=0
log "VPS switch completed successfully"
if [[ $OLD_AUTH_MODE == key && $OLD_REMOTE_KEY_ADDED == 1 ]]; then
    log "NOTICE: the installer key on old VPS $OLD_VPS_HOST was not removed automatically"
fi
printf '\nVPS changed successfully. New exit IPv4: %s\nBackup: %s\n' \
    "$NEW_EXPECTED_IP" "$CHANGE_BACKUP" >"$TTY"
