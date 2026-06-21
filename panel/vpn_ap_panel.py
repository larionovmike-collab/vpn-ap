#!/usr/bin/env python3
import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shlex
import ssl
import subprocess
import tempfile
import threading
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SESSIONS = {}
LOGIN_FAILURES = {}
LOCK = threading.Lock()
SESSION_TTL = 3600
SERVICES = (
    "vpn-ap-socks.service", "vpn-ap-redsocks.service",
    "vpn-ap-transparent.service", "vpn-ap-watchdog.timer",
    "dnscrypt-proxy.service", "hostapd.service", "dnsmasq.service",
)


def run(args, timeout=30, check=True):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=check)


def read_state(path):
    result = {}
    if not path.exists():
        return result
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        try:
            parsed = shlex.split(value)
            result[key] = parsed[0] if parsed else ""
        except ValueError:
            continue
    return result


def update_state(path, updates):
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    found = set()
    output = []
    for line in lines:
        if "=" not in line:
            output.append(line)
            continue
        key = line.split("=", 1)[0]
        if key in updates:
            output.append(f"{key}={shlex.quote(str(updates[key]))}")
            found.add(key)
        else:
            output.append(line)
    for key, value in updates.items():
        if key not in found:
            output.append(f"{key}={shlex.quote(str(value))}")
    temporary = path.with_suffix(".tmp")
    temporary.write_text("\n".join(output) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def load_auth(path):
    return json.loads(path.read_text(encoding="utf-8"))


def verify_password(password, auth):
    salt = base64.b64decode(auth["salt"])
    expected = base64.b64decode(auth["digest"])
    actual = hashlib.scrypt(password.encode(), salt=salt, n=2**15, r=8, p=1, dklen=32, maxmem=64 * 1024 * 1024)
    return hmac.compare_digest(actual, expected)


class PanelServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, config):
        super().__init__(address, handler)
        self.config = config


class Handler(BaseHTTPRequestHandler):
    server_version = "VPNAPPanel/1"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def local_client(self):
        try:
            return ipaddress.ip_address(self.client_address[0]) in self.server.config["network"]
        except ValueError:
            return False

    def send_headers(self, status, content_type="application/json", length=0, cookie=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def json_response(self, status, data, cookie=None):
        payload = json.dumps(data, ensure_ascii=False).encode()
        self.send_headers(status, length=len(payload), cookie=cookie)
        self.wfile.write(payload)

    def body(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16384:
            raise ValueError("Request is too large")
        return json.loads(self.rfile.read(length) or b"{}")

    def session(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        token = cookie.get("vpn_ap_session")
        if not token:
            return None
        with LOCK:
            session = SESSIONS.get(token.value)
            if not session or session["expires"] < time.time():
                SESSIONS.pop(token.value, None)
                return None
            session["expires"] = time.time() + SESSION_TTL
            return session

    def require_auth(self, csrf=False):
        session = self.session()
        if not session:
            self.json_response(HTTPStatus.UNAUTHORIZED, {"error": "Требуется вход"})
            return None
        if csrf and not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), session["csrf"]):
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Некорректный CSRF token"})
            return None
        return session

    def do_GET(self):
        if not self.local_client():
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        if self.path == "/":
            payload = self.server.config["index"].read_bytes()
            self.send_headers(HTTPStatus.OK, "text/html; charset=utf-8", len(payload))
            self.wfile.write(payload)
        elif self.path == "/api/status":
            if not self.require_auth():
                return
            state = read_state(self.server.config["state"])
            statuses = {}
            for service in SERVICES:
                result = run(["systemctl", "is-active", service], check=False)
                statuses[service.replace(".service", "")] = result.stdout.strip() or "unknown"
            self.json_response(HTTPStatus.OK, {
                "services": statuses,
                "vps_host": state.get("VPS_HOST", ""),
                "vps_user": state.get("VPS_USER", ""),
                "exit_ip": state.get("EXPECTED_IP", ""),
                "ssid": state.get("AP_SSID", ""),
                "gateway": state.get("AP_GATEWAY", ""),
                "lan_url": f"https://{self.server.server_address[0]}:{self.server.server_address[1]}",
            })
        elif self.path == "/api/session":
            session = self.require_auth()
            if session:
                self.json_response(HTTPStatus.OK, {"csrf": session["csrf"]})
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self):
        if not self.local_client():
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        try:
            if self.path == "/api/login":
                self.login()
                return
            if not self.require_auth(csrf=True):
                return
            if self.path == "/api/vps/fingerprint":
                self.vps_fingerprint()
            elif self.path == "/api/vps/apply":
                self.vps_apply()
            elif self.path == "/api/ap/apply":
                self.ap_apply()
            elif self.path == "/api/tunnel/restart":
                run(["systemctl", "restart", "vpn-ap-socks.service"])
                self.json_response(HTTPStatus.OK, {"ok": True})
            elif self.path == "/api/logout":
                self.logout()
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            detail = getattr(exc, "stderr", "") or str(exc)
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": detail[-1200:]})
        except Exception as exc:
            self.json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    def login(self):
        now = time.time()
        address = self.client_address[0]
        with LOCK:
            failures = [stamp for stamp in LOGIN_FAILURES.get(address, []) if now - stamp < 300]
            LOGIN_FAILURES[address] = failures
        if len(failures) >= 5:
            self.json_response(HTTPStatus.TOO_MANY_REQUESTS, {"error": "Слишком много попыток. Подождите 5 минут."})
            return
        data = self.body()
        auth = self.server.config["auth"]
        valid = hmac.compare_digest(str(data.get("username", "")), auth["username"])
        valid = valid and verify_password(str(data.get("password", "")), auth)
        if not valid:
            with LOCK:
                LOGIN_FAILURES[address].append(now)
            time.sleep(1)
            self.json_response(HTTPStatus.UNAUTHORIZED, {"error": "Неверный логин или пароль"})
            return
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        with LOCK:
            SESSIONS[token] = {"csrf": csrf, "expires": now + SESSION_TTL}
            LOGIN_FAILURES.pop(address, None)
        cookie = f"vpn_ap_session={token}; Path=/; Max-Age={SESSION_TTL}; Secure; HttpOnly; SameSite=Strict"
        self.json_response(HTTPStatus.OK, {"ok": True, "csrf": csrf}, cookie)

    def logout(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        token = cookie.get("vpn_ap_session")
        if token:
            with LOCK:
                SESSIONS.pop(token.value, None)
        self.json_response(HTTPStatus.OK, {"ok": True}, "vpn_ap_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict")

    @staticmethod
    def validate_host_user(data):
        host = str(data.get("host", ""))
        user = str(data.get("user", ""))
        ipaddress.IPv4Address(host)
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", user):
            raise ValueError("Некорректный SSH-логин")
        return host, user

    def vps_fingerprint(self):
        host, _ = self.validate_host_user(self.body())
        with tempfile.NamedTemporaryFile(mode="w+", delete=False) as handle:
            temporary = handle.name
        try:
            scan = run(["ssh-keyscan", "-T", "8", "-H", host])
            Path(temporary).write_text(scan.stdout, encoding="utf-8")
            output = run(["ssh-keygen", "-lf", temporary]).stdout.strip().splitlines()
            fingerprints = [{"fingerprint": line.split()[1], "description": line} for line in output]
            self.json_response(HTTPStatus.OK, {"fingerprints": fingerprints})
        finally:
            Path(temporary).unlink(missing_ok=True)

    def vps_apply(self):
        data = self.body()
        host, user = self.validate_host_user(data)
        password = str(data.get("password", ""))
        fingerprint = str(data.get("fingerprint", ""))
        if not password or "\n" in password or "\r" in password or not fingerprint.startswith("SHA256:"):
            raise ValueError("Укажите пароль и подтверждённый fingerprint")
        fd, filename = tempfile.mkstemp(prefix="vpn-ap-vps-", dir="/run")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(f"{host}\n{user}\n{password}\n{fingerprint}\n")
            result = run([str(self.server.config["change_vps"]), "--config", filename], timeout=180)
            self.json_response(HTTPStatus.OK, {"ok": True, "message": result.stdout[-1000:]})
        finally:
            Path(filename).unlink(missing_ok=True)

    def ap_apply(self):
        data = self.body()
        ssid = str(data.get("ssid", ""))
        password = str(data.get("password", ""))
        country = str(data.get("country", "")).upper()
        channel = int(data.get("channel", 6))
        if not 1 <= len(ssid.encode()) <= 32 or "\n" in ssid or "\r" in ssid:
            raise ValueError("SSID должен содержать 1–32 байта")
        if password and (not 8 <= len(password.encode()) <= 63 or "\n" in password or "\r" in password):
            raise ValueError("WiFi-пароль должен содержать 8–63 байта")
        if not re.fullmatch(r"[A-Z]{2}", country) or channel not in range(1, 14):
            raise ValueError("Некорректная страна или канал")
        config = Path("/etc/hostapd/hostapd.conf")
        old = config.read_text(encoding="utf-8")
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        backup = Path(f"/var/backups/vpn-ap-installer/ap-change-{timestamp}")
        backup.mkdir(parents=True, mode=0o700)
        (backup / "hostapd.conf").write_text(old, encoding="utf-8")
        values = {"ssid": ssid, "country_code": country, "channel": str(channel)}
        if password:
            values["wpa_passphrase"] = password
        lines, seen = [], set()
        for line in old.splitlines():
            key = line.split("=", 1)[0] if "=" in line else ""
            if key in values:
                lines.append(f"{key}={values[key]}")
                seen.add(key)
            else:
                lines.append(line)
        for key, value in values.items():
            if key not in seen:
                lines.append(f"{key}={value}")
        temporary = config.with_suffix(".tmp")
        temporary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, config)
        try:
            run(["systemctl", "restart", "hostapd.service"])
            active = run(["systemctl", "is-active", "hostapd.service"]).stdout.strip()
            if active != "active":
                raise RuntimeError("hostapd не запустился")
            update_state(self.server.config["state"], {"AP_SSID": ssid})
        except Exception:
            config.write_text(old, encoding="utf-8")
            os.chmod(config, 0o600)
            run(["systemctl", "restart", "hostapd.service"], check=False)
            raise
        self.json_response(HTTPStatus.OK, {"ok": True, "backup": str(backup)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--network", required=True)
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert", required=True, type=Path)
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--auth", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--change-vps", required=True, type=Path)
    args = parser.parse_args()
    config = {
        "network": ipaddress.ip_network(args.network, strict=False),
        "auth": load_auth(args.auth), "state": args.state,
        "index": args.index, "change_vps": args.change_vps,
    }
    server = PanelServer((args.bind, args.port), Handler, config)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"VPN AP panel listening on https://{args.bind}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
