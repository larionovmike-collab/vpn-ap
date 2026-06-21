#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE=/var/lib/vpn-ap-installer/panel-backup
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -r $STATE ]] || { echo "Panel backup state was not found." >&2; exit 1; }
BACKUP=$(cat "$STATE")
[[ -d $BACKUP && -r $BACKUP/manifest ]] || { echo "Panel backup is missing: $BACKUP" >&2; exit 1; }

systemctl disable --now vpn-ap-panel.service 2>/dev/null || true
while IFS='|' read -r path status; do
    if [[ $status == present ]]; then
        install -d "$(dirname "$path")"
        cp -a "$BACKUP/files/${path#/}" "$path"
    else
        rm -f "$path"
    fi
done <"$BACKUP/manifest"
systemctl daemon-reload
if [[ -e /etc/systemd/system/vpn-ap-panel.service ]]; then
    systemctl enable --now vpn-ap-panel.service
fi
printf 'Panel rollback completed from %s\n' "$BACKUP"
