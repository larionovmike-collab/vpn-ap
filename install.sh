#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly APP_NAME="vpn-ap-installer"
readonly STATE_DIR="/var/lib/${APP_NAME}"
readonly BACKUP_ROOT="/var/backups/${APP_NAME}"
readonly LOG_FILE="/var/log/${APP_NAME}.log"
readonly AP_IF="wlan0"
readonly SOCKS_PORT="1080"
readonly REDSOCKS_PORT="12345"
readonly DNSCRYPT_PORT="5300"

TTY=/dev/tty
BACKUP_DIR=""
MANIFEST=""
REMOTE_KEY_ADDED=0
PUBKEY_BLOB=""

log() {
    printf '%s | %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local rc=$?
    log "Installation stopped at line $1 (exit $rc). Existing default routes and management interface were not changed."
    log "Backup: ${BACKUP_DIR:-not created}"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root: curl ... | sudo bash"
    [[ -r $TTY && -w $TTY ]] || die "An interactive terminal is required for secure prompts."
}

prompt() {
    local variable=$1 label=$2 default=${3:-} value
    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$label" "$default" >"$TTY"
    else
        printf '%s: ' "$label" >"$TTY"
    fi
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

confirm() {
    local answer
    printf '%s [y/N]: ' "$1" >"$TTY"
    IFS= read -r answer <"$TTY"
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]]
}

validate_inputs() {
    local ssid_bytes password_bytes
    ssid_bytes=$(LC_ALL=C printf '%s' "$AP_SSID" | wc -c)
    password_bytes=$(LC_ALL=C printf '%s' "$AP_PASSWORD" | wc -c)
    (( ssid_bytes >= 1 && ssid_bytes <= 32 )) || die "SSID must contain 1-32 bytes."
    (( password_bytes >= 8 && password_bytes <= 63 )) || die "WiFi password must contain 8-63 bytes."
    [[ $AP_SSID != *$'\n'* && $AP_SSID != *$'\r'* ]] || die "SSID contains a newline."
    [[ $AP_PASSWORD != *$'\n'* && $AP_PASSWORD != *$'\r'* ]] || die "WiFi password contains a newline."
    [[ $VPS_USER =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || die "Invalid VPS login."
    local octet octets
    [[ $VPS_HOST =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "VPS address must be an IPv4 address."
    IFS=. read -r -a octets <<<"$VPS_HOST"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || die "VPS address must be an IPv4 address."
    done
    [[ -n $VPS_PASSWORD ]] || die "VPS password cannot be empty."
}

backup_file() {
    local path=$1 encoded
    encoded=${path#/}
    if [[ -e $path || -L $path ]]; then
        mkdir -p "$BACKUP_DIR/files/$(dirname "$encoded")"
        cp -a "$path" "$BACKUP_DIR/files/$encoded"
        printf '%s|present\n' "$path" >>"$MANIFEST"
    else
        printf '%s|absent\n' "$path" >>"$MANIFEST"
    fi
}

write_file() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    install -D -o root -g root -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

wait_for_port() {
    local address=$1 port=$2 attempts=${3:-20}
    while (( attempts-- > 0 )); do
        if timeout 1 bash -c "</dev/tcp/${address}/${port}" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

select_ap_network() {
    local local_networks remote_networks selected
    # Ignore the installer-owned wlan0 network so an idempotent rerun selects it again.
    local_networks=$(ip -o -4 address show | awk -v ap="$AP_IF" '$2 != ap'; \
        ip -4 route show table all | awk -v ap="$AP_IF" '$0 !~ (" dev " ap "( |$)")')
    remote_networks=""
    if [[ $AUTH_MODE == key ]]; then
        remote_networks=$(SSHPASS="$VPS_PASSWORD" sshpass -e ssh -n "${SSH_OPTIONS[@]}" \
            "$VPS_USER@$VPS_HOST" 'ip -o -4 address show; ip -4 route show table all')
    fi

    selected=$(LOCAL_NETWORKS="$local_networks" REMOTE_NETWORKS="$remote_networks" python3 <<'PY'
import ipaddress, os, re

used = []
for text in (os.environ['LOCAL_NETWORKS'], os.environ['REMOTE_NETWORKS']):
    for token in re.findall(r'(?<![0-9.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?', text):
        try:
            if '/' in token:
                used.append(ipaddress.ip_network(token, strict=False))
            else:
                used.append(ipaddress.ip_network(token + '/32'))
        except ValueError:
            pass

candidates = [
    '10.77.0.0/24', '10.88.0.0/24', '10.99.0.0/24',
    '172.29.77.0/24', '172.30.77.0/24', '192.168.77.0/24',
    '192.168.88.0/24', '192.168.99.0/24'
]
for candidate in map(ipaddress.ip_network, candidates):
    if not any(candidate.overlaps(network) for network in used):
        print(candidate)
        break
else:
    raise SystemExit('No non-overlapping candidate subnet found')
PY
    )
    [[ -n $selected ]] || die "Could not select a non-overlapping AP subnet."
    AP_SUBNET=$selected
    # selected is always one of the /24 candidates above.
    AP_PREFIX=${selected%0/24}
    AP_GATEWAY="${AP_PREFIX}1"
    DHCP_START="${AP_PREFIX}50"
    DHCP_END="${AP_PREFIX}200"
}

write_state() {
    mkdir -p "$STATE_DIR"
    {
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'VPS_HOST=%q\n' "$VPS_HOST"
        printf 'VPS_USER=%q\n' "$VPS_USER"
        printf 'AP_SSID=%q\n' "$AP_SSID"
        printf 'AP_SUBNET=%q\n' "$AP_SUBNET"
        printf 'AP_GATEWAY=%q\n' "$AP_GATEWAY"
        printf 'AUTH_MODE=%q\n' "$AUTH_MODE"
        printf 'PUBKEY_BLOB=%q\n' "$PUBKEY_BLOB"
        printf 'REMOTE_KEY_ADDED=%q\n' "$REMOTE_KEY_ADDED"
    } >"$STATE_DIR/state.env"
    chmod 600 "$STATE_DIR/state.env"
}

require_root
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
log "Starting interactive installation"

prompt AP_SSID "WiFi access point name" "AP-PI"
prompt_secret AP_PASSWORD "WiFi password (8-63 characters)"
prompt VPS_HOST "VPS IPv4 address"
prompt VPS_USER "VPS SSH login" "root"
prompt_secret VPS_PASSWORD "VPS SSH password"
prompt AUTH_MODE "Tunnel authentication mode: password (no VPS changes) or key" "password"
AUTH_MODE=${AUTH_MODE,,}
case "$AUTH_MODE" in
    password|key) ;;
    *) die "Authentication mode must be 'password' or 'key'." ;;
esac

validate_inputs

[[ -d /sys/class/net/$AP_IF ]] || die "$AP_IF was not found."
DEFAULT_IF=$(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
[[ -n $DEFAULT_IF ]] || die "No IPv4 default route was found."
[[ $DEFAULT_IF != "$AP_IF" ]] || die "The management default route uses $AP_IF; refusing to convert it into an AP."

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
MANIFEST="$BACKUP_DIR/manifest"
mkdir -p "$BACKUP_DIR"
touch "$MANIFEST"
ip -4 route show table all >"$BACKUP_DIR/raspberry-routes.txt"
iptables-save >"$BACKUP_DIR/raspberry-iptables.txt" 2>/dev/null || true
ip6tables-save >"$BACKUP_DIR/raspberry-ip6tables.txt" 2>/dev/null || true
nft list ruleset >"$BACKUP_DIR/raspberry-nftables.txt" 2>/dev/null || true
log "Pre-change state saved to $BACKUP_DIR"

TARGETS=(
    "$STATE_DIR/vps-known_hosts"
    /root/.ssh/vpn-ap-socks
    /root/.ssh/vpn-ap-socks.pub
    /etc/vpn-ap-installer/vps-password
    "$STATE_DIR/state.env"
    /etc/NetworkManager/conf.d/90-vpn-ap-unmanaged.conf
    /etc/systemd/system/vpn-ap-interface.service
    /etc/hostapd/hostapd.conf
    /etc/default/hostapd
    /etc/dnsmasq.d/vpn-ap.conf
    /etc/dnscrypt-proxy/dnscrypt-proxy.toml
    /etc/redsocks-vpn-ap.conf
    /etc/systemd/system/vpn-ap-socks.service
    /etc/systemd/system/vpn-ap-redsocks.service
    /usr/local/sbin/vpn-ap-transparent-up
    /etc/systemd/system/vpn-ap-transparent.service
    /usr/local/sbin/vpn-ap-watchdog
    /etc/systemd/system/vpn-ap-watchdog.service
    /etc/systemd/system/vpn-ap-watchdog.timer
)
for target in "${TARGETS[@]}"; do backup_file "$target"; done
for service in hostapd dnsmasq dnscrypt-proxy redsocks; do
    printf '%s|%s|%s\n' "$service" \
        "$(systemctl is-active "$service" 2>/dev/null || true)" \
        "$(systemctl is-enabled "$service" 2>/dev/null || true)" \
        >>"$BACKUP_DIR/services-state.txt"
done
log "All configuration targets and prior service states backed up"

export DEBIAN_FRONTEND=noninteractive
POLICY_CREATED=0
if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    POLICY_CREATED=1
fi
cleanup_policy() {
    if (( POLICY_CREATED )); then rm -f /usr/sbin/policy-rc.d; fi
}
trap 'cleanup_policy' EXIT

apt-get update
apt-get install -y hostapd dnsmasq redsocks dnscrypt-proxy openssh-client sshpass \
    curl ca-certificates iptables iw rfkill dnsutils python3
cleanup_policy
POLICY_CREATED=0
log "Required packages installed"

IW_DUMP=$(mktemp)
iw list >"$IW_DUMP"
grep -qE '^[[:space:]]+\* AP$' "$IW_DUMP" || die "$AP_IF does not advertise AP mode support."
rm -f "$IW_DUMP"

KNOWN_HOSTS="$STATE_DIR/vps-known_hosts"
mkdir -p "$STATE_DIR" /root/.ssh
chmod 700 /root/.ssh
TMP_HOSTS=$(mktemp)
ssh-keyscan -T 8 -H "$VPS_HOST" >"$TMP_HOSTS" 2>/dev/null
[[ -s $TMP_HOSTS ]] || die "Could not retrieve the VPS SSH host key."
printf '\nVPS SSH host key fingerprint:\n' >"$TTY"
ssh-keygen -lf "$TMP_HOSTS" >"$TTY"
confirm "Confirm that this fingerprint belongs to your VPS" || die "VPS fingerprint was not accepted."
install -o root -g root -m 600 "$TMP_HOSTS" "$KNOWN_HOSTS"
rm -f "$TMP_HOSTS"

SSH_OPTIONS=(-p 22 -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no)
if [[ $AUTH_MODE == key ]]; then
    SSHPASS="$VPS_PASSWORD" sshpass -e ssh -n "${SSH_OPTIONS[@]}" \
        "$VPS_USER@$VPS_HOST" 'printf VPS_LOGIN_OK' | grep -q VPS_LOGIN_OK
    log "VPS shell access verified for restricted-key installation"
else
    log "VPS host key pinned; password will be validated only by the SOCKS forwarding connection"
fi

select_ap_network
if [[ $AUTH_MODE == key ]]; then
    log "Selected AP subnet $AP_SUBNET after checking Raspberry and VPS routes; management remains on $DEFAULT_IF"
else
    log "Selected AP subnet $AP_SUBNET from Raspberry routes; no VPS shell command was executed"
fi

KEY_FILE=/root/.ssh/vpn-ap-socks
PASSWORD_FILE=/etc/vpn-ap-installer/vps-password
if [[ $AUTH_MODE == password ]]; then
    write_file "$PASSWORD_FILE" 0600 <<EOF
$VPS_PASSWORD
EOF
    TEST_TUNNEL=(sshpass -f "$PASSWORD_FILE" ssh -n -p 22 \
        -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS")
    SSH_EXEC="/usr/bin/sshpass -f $PASSWORD_FILE /usr/bin/ssh -N -T -D 127.0.0.1:$SOCKS_PORT -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectionAttempts=3 -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS $VPS_USER@$VPS_HOST"
    log "Password authentication selected; VPS configuration will not be changed"
else
    if [[ ! -s $KEY_FILE || ! -s $KEY_FILE.pub ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "vpn-ap-forwarding" -f "$KEY_FILE"
        log "Created a dedicated SSH forwarding key"
    fi
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"
    read -r PUBKEY_TYPE PUBKEY_BLOB PUBKEY_COMMENT <"$KEY_FILE.pub"
    AUTH_LINE="restrict,port-forwarding,command=\"/bin/false\" $PUBKEY_TYPE $PUBKEY_BLOB vpn-ap-forwarding"
    REMOTE_RESULT=$(printf '%s\n%s\n' "$PUBKEY_BLOB" "$AUTH_LINE" | \
        SSHPASS="$VPS_PASSWORD" sshpass -e ssh "${SSH_OPTIONS[@]}" "$VPS_USER@$VPS_HOST" \
        'set -eu; umask 077; read -r blob; read -r line; mkdir -p "$HOME/.ssh" "$HOME/.vpn-ap-backups"; touch "$HOME/.ssh/authorized_keys"; cp -a "$HOME/.ssh/authorized_keys" "$HOME/.vpn-ap-backups/authorized_keys.'"$TIMESTAMP"'"; chmod 700 "$HOME/.ssh"; chmod 600 "$HOME/.ssh/authorized_keys"; if grep -qF "$blob" "$HOME/.ssh/authorized_keys"; then echo EXISTING; else printf "\n%s\n" "$line" >>"$HOME/.ssh/authorized_keys"; echo ADDED; fi')
    if [[ $REMOTE_RESULT == *ADDED* ]]; then REMOTE_KEY_ADDED=1; fi
    TEST_TUNNEL=(ssh -n -p 22 -o BatchMode=yes -o IdentitiesOnly=yes \
        -o ConnectTimeout=10 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -i "$KEY_FILE")
    SSH_EXEC="/usr/bin/ssh -N -T -D 127.0.0.1:$SOCKS_PORT -o BatchMode=yes -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ConnectionAttempts=3 -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS -i $KEY_FILE $VPS_USER@$VPS_HOST"
    log "Dedicated forwarding key verified in VPS authorized_keys (backup: ~/.vpn-ap-backups/authorized_keys.$TIMESTAMP)"
fi
unset VPS_PASSWORD SSHPASS AUTH_LINE
write_state

timeout 25 "${TEST_TUNNEL[@]}" -N -T -D 127.0.0.1:1099 "$VPS_USER@$VPS_HOST" &
TEST_SSH_PID=$!
sleep 3
kill -0 "$TEST_SSH_PID" 2>/dev/null || die "Dedicated forwarding key test failed."
curl --socks5-hostname 127.0.0.1:1099 --connect-timeout 8 --max-time 15 \
    --fail --silent https://1.1.1.1/cdn-cgi/trace >/dev/null || die "Dedicated forwarding data test failed."
kill "$TEST_SSH_PID" 2>/dev/null || true
wait "$TEST_SSH_PID" 2>/dev/null || true
log "$AUTH_MODE authentication accepts SSH dynamic forwarding"

write_file /etc/NetworkManager/conf.d/90-vpn-ap-unmanaged.conf 0644 <<EOF
[keyfile]
unmanaged-devices=interface-name:$AP_IF
EOF

write_file /etc/systemd/system/vpn-ap-interface.service 0644 <<EOF
[Unit]
Description=VPN AP $AP_IF interface
After=NetworkManager.service
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/rfkill unblock wlan
ExecStart=/usr/sbin/ip link set dev $AP_IF up
ExecStart=/usr/sbin/ip address replace $AP_GATEWAY/24 dev $AP_IF

[Install]
WantedBy=multi-user.target
EOF

COUNTRY=$(iw reg get 2>/dev/null | awk '/country [A-Z][A-Z]:/ {gsub(":", "", $2); print $2; exit}')
[[ $COUNTRY =~ ^[A-Z]{2}$ ]] || COUNTRY=US
write_file /etc/hostapd/hostapd.conf 0600 <<EOF
interface=$AP_IF
driver=nl80211
ctrl_interface=/run/hostapd
ssid=$AP_SSID
country_code=$COUNTRY
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
unset AP_PASSWORD

write_file /etc/default/hostapd 0644 <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

write_file /etc/dnsmasq.d/vpn-ap.conf 0644 <<EOF
interface=$AP_IF
bind-dynamic
port=53
no-resolv
filter-AAAA
server=127.0.0.1#$DNSCRYPT_PORT
dhcp-authoritative
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,12h
dhcp-option=option:router,$AP_GATEWAY
dhcp-option=option:dns-server,$AP_GATEWAY
dhcp-leasefile=/var/lib/misc/dnsmasq-vpn-ap.leases
EOF

write_file /etc/dnscrypt-proxy/dnscrypt-proxy.toml 0644 <<EOF
listen_addresses = ['127.0.0.1:$DNSCRYPT_PORT']
server_names = ['cloudflare']
proxy = 'socks5://127.0.0.1:$SOCKS_PORT'
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
odoh_servers = false
require_dnssec = true
require_nolog = true
require_nofilter = false
force_tcp = true

[sources]
  [sources.'public-resolvers']
  url = 'https://download.dnscrypt.info/resolvers-list/v2/public-resolvers.md'
  cache_file = '/var/cache/dnscrypt-proxy/public-resolvers.md'
  minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
  refresh_delay = 72
  prefix = ''
EOF

write_file /etc/redsocks-vpn-ap.conf 0644 <<EOF
base {
    log_debug = off;
    log_info = on;
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 0.0.0.0;
    local_port = $REDSOCKS_PORT;
    ip = 127.0.0.1;
    port = $SOCKS_PORT;
    type = socks5;
}
EOF

write_file /etc/systemd/system/vpn-ap-socks.service 0644 <<EOF
[Unit]
Description=VPN AP SSH SOCKS5 tunnel
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$SSH_EXEC
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

write_file /etc/systemd/system/vpn-ap-redsocks.service 0644 <<'EOF'
[Unit]
Description=VPN AP transparent TCP to SSH SOCKS
After=vpn-ap-socks.service
Requires=vpn-ap-socks.service

[Service]
Type=simple
ExecStart=/usr/sbin/redsocks -c /etc/redsocks-vpn-ap.conf
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

write_file /usr/local/sbin/vpn-ap-transparent-up 0755 <<EOF
#!/bin/sh
set -eu
iptables -t nat -N VPN_AP_REDSOCKS 2>/dev/null || true
for network in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 $VPS_HOST/32; do
    iptables -t nat -C VPN_AP_REDSOCKS -d "\$network" -j RETURN 2>/dev/null || iptables -t nat -I VPN_AP_REDSOCKS 1 -d "\$network" -j RETURN
done
iptables -t nat -C VPN_AP_REDSOCKS -p tcp -j REDIRECT --to-ports $REDSOCKS_PORT 2>/dev/null || iptables -t nat -A VPN_AP_REDSOCKS -p tcp -j REDIRECT --to-ports $REDSOCKS_PORT
iptables -t nat -C PREROUTING -i $AP_IF -s $AP_SUBNET -p tcp -j VPN_AP_REDSOCKS 2>/dev/null || iptables -t nat -I PREROUTING 1 -i $AP_IF -s $AP_SUBNET -p tcp -j VPN_AP_REDSOCKS
iptables -N VPN_AP_FAIL_CLOSED 2>/dev/null || true
iptables -C FORWARD -j VPN_AP_FAIL_CLOSED 2>/dev/null || iptables -I FORWARD 1 -j VPN_AP_FAIL_CLOSED
iptables -C VPN_AP_FAIL_CLOSED -i $AP_IF -s $AP_SUBNET -j DROP 2>/dev/null || iptables -A VPN_AP_FAIL_CLOSED -i $AP_IF -s $AP_SUBNET -j DROP
ip6tables -N VPN_AP6_FAIL_CLOSED 2>/dev/null || true
ip6tables -C FORWARD -j VPN_AP6_FAIL_CLOSED 2>/dev/null || ip6tables -I FORWARD 1 -j VPN_AP6_FAIL_CLOSED
ip6tables -C VPN_AP6_FAIL_CLOSED -i $AP_IF -j DROP 2>/dev/null || ip6tables -A VPN_AP6_FAIL_CLOSED -i $AP_IF -j DROP
EOF

write_file /etc/systemd/system/vpn-ap-transparent.service 0644 <<'EOF'
[Unit]
Description=VPN AP transparent TCP redirect and fail-closed policy
After=vpn-ap-redsocks.service dnsmasq.service dnscrypt-proxy.service
Requires=vpn-ap-redsocks.service dnsmasq.service dnscrypt-proxy.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpn-ap-transparent-up

[Install]
WantedBy=multi-user.target
EOF

dnsmasq --test
redsocks -t -c /etc/redsocks-vpn-ap.conf
dnscrypt-proxy -check -config /etc/dnscrypt-proxy/dnscrypt-proxy.toml
systemctl daemon-reload
systemd-analyze verify vpn-ap-interface.service vpn-ap-socks.service \
    vpn-ap-redsocks.service vpn-ap-transparent.service
log "Generated configurations passed syntax checks"

if command -v nmcli >/dev/null; then
    nmcli general reload || true
    nmcli device set "$AP_IF" managed no || true
fi
systemctl unmask hostapd.service dnsmasq.service dnscrypt-proxy.service 2>/dev/null || true
systemctl enable --now vpn-ap-interface.service
systemctl enable --now vpn-ap-socks.service
wait_for_port 127.0.0.1 "$SOCKS_PORT" 25 || die "SOCKS listener did not start."

EXPECTED_IP=$(curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" --connect-timeout 8 \
    --max-time 20 --fail --silent https://1.1.1.1/cdn-cgi/trace | awk -F= '$1=="ip" {print $2}')
[[ $EXPECTED_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not verify the SOCKS exit IPv4."
log "SSH SOCKS verified; exit IPv4 is $EXPECTED_IP"

systemctl enable --now dnscrypt-proxy.service
for _ in {1..20}; do
    if dig @127.0.0.1 -p "$DNSCRYPT_PORT" example.com A +short | grep -qE '^[0-9]+\.'; then break; fi
    sleep 1
done
dig @127.0.0.1 -p "$DNSCRYPT_PORT" example.com A +short | grep -qE '^[0-9]+\.' || die "DNSCrypt over SOCKS test failed."

systemctl enable --now vpn-ap-redsocks.service
systemctl enable --now dnsmasq.service
systemctl enable --now hostapd.service

write_file /usr/local/sbin/vpn-ap-watchdog 0755 <<EOF
#!/bin/sh
set -eu
STATE=/run/vpn-ap-watchdog.failures
if output=\$(curl --socks5-hostname 127.0.0.1:$SOCKS_PORT --connect-timeout 5 --max-time 12 --fail --silent https://1.1.1.1/cdn-cgi/trace 2>/dev/null) && printf '%s\n' "\$output" | grep -qx 'ip=$EXPECTED_IP'; then
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

write_file /etc/systemd/system/vpn-ap-watchdog.service 0644 <<'EOF'
[Unit]
Description=VPN AP SSH SOCKS end-to-end health check
After=vpn-ap-socks.service vpn-ap-redsocks.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpn-ap-watchdog
EOF

write_file /etc/systemd/system/vpn-ap-watchdog.timer 0644 <<'EOF'
[Unit]
Description=Check VPN AP SSH SOCKS every 20 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=20s
AccuracySec=2s
Unit=vpn-ap-watchdog.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemd-analyze verify vpn-ap-watchdog.service vpn-ap-watchdog.timer
systemctl enable --now vpn-ap-transparent.service vpn-ap-watchdog.timer
systemctl start vpn-ap-watchdog.service

for service in vpn-ap-interface hostapd dnsmasq vpn-ap-socks vpn-ap-redsocks \
    dnscrypt-proxy vpn-ap-transparent vpn-ap-watchdog.timer; do
    systemctl is-active --quiet "$service" || die "$service is not active."
done
iptables -t nat -C PREROUTING -i "$AP_IF" -s "$AP_SUBNET" -p tcp -j VPN_AP_REDSOCKS
iptables -C FORWARD -j VPN_AP_FAIL_CLOSED
ip6tables -C FORWARD -j VPN_AP6_FAIL_CLOSED
[[ $(ip -4 route show default | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}') == "$DEFAULT_IF" ]] || die "Default route changed unexpectedly."

write_state
log "Installation completed successfully"
printf '\nInstallation complete.\nSSID: %s\nAP gateway: %s\nExpected Internet IPv4: %s\nBackup: %s\n' \
    "$AP_SSID" "$AP_GATEWAY" "$EXPECTED_IP" "$BACKUP_DIR" >"$TTY"
