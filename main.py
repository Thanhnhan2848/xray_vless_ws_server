import os
import json
import re
import socket
from urllib import request
from sys import prefix
from dotenv import load_dotenv
import threading
import subprocess
import platform
import uuid
import time
from logging_site import RealtimeLogger
import requests
import importlib

xray_downloader = importlib.import_module("download-xray")
cloudflared_downloader = importlib.import_module("download-cloudflared")
wgcf_downloader = importlib.import_module("download-wgcf")

def main():
    # =========================================
    # CONFIG SERVER (Cloudflare Tunnel)
    # =========================================
    default_configs = {
        "PORT": "127.0.0.1:8888",
        "XRAY_UUID": str(uuid.uuid4()),
        "FAKE_SNI": "api24-normal-alisg.tiktokv.com,vnpt.theworkpc.com",
        "WS_PATH": "/tiktok4g",
        "WS_HOST": "trycloudflare.com",
        "TRANSPORT": "websocket",
        "ENABLE_WARP": "false",
        "WEBHOOK_URL": "",
        "TUNNEL_TOKEN": "",
        "RUN_MODE": "quick_tunnel"
    }
    START_TIME = int(time.time())

    def get_os_env(name):
        return os.getenv(name, default_configs.get(name))

    def get_public_url():
        # Get ip via ipify
        try:
            ip = requests.get("https://api.ipify.org").text
            return ip
        except Exception as e:
            print(f"[!] Failed to get public IP: {e}")
            return "0.0.0.0"

    def init_env_file():
        env_path = ".env"
        # Support multiple ports format.
        # Default: localhost:8888

        if not os.path.exists(env_path):
            print("[*] File .env does not exist. Using default configuration...")
            with open(env_path, "w", encoding="utf-8") as f:
                for key, value in default_configs.items():
                    f.write(f"{key}={value}\n")
            print("[+] Generated .env configuration.")
        else:
            print("[*] Found .env configuration.")

    init_env_file()
    load_dotenv()

    # Read raw PORT string from .env
    PORT_ENV = get_os_env("PORT")
    UUID = get_os_env("XRAY_UUID")
    FAKE_SNI = get_os_env("FAKE_SNI")
    WS_PATH = get_os_env("WS_PATH")
    WS_HOST = get_os_env("WS_HOST")
    WEBHOOK_URL = get_os_env("WEBHOOK_URL")
    TUNNEL_TOKEN = get_os_env("TUNNEL_TOKEN").strip()
    ENABLE_WARP = get_os_env("ENABLE_WARP").lower() == "true"
    DEBUG_MODE = os.getenv("DEBUG_MODE", "false").lower() == "true"
    RUN_MODE = get_os_env("RUN_MODE").strip().lower()

    # Normalize RUN_MODE. Old .env files without RUN_MODE default to quick_tunnel.
    ALLOWED_RUN_MODES = ("quick_tunnel", "named_tunnel", "direct")
    if RUN_MODE not in ALLOWED_RUN_MODES:
        print(f"[!] Unknown RUN_MODE '{RUN_MODE}', falling back to 'quick_tunnel'.")
        RUN_MODE = "quick_tunnel"

    # Validate per-mode requirements before downloading/launching anything.
    if RUN_MODE == "named_tunnel":
        if not WS_HOST.strip() or WS_HOST.strip() == "trycloudflare.com":
            print("[ERROR] RUN_MODE=named_tunnel requires WS_HOST to be your custom domain (not trycloudflare.com).")
            return
        if not TUNNEL_TOKEN:
            print("[ERROR] RUN_MODE=named_tunnel requires TUNNEL_TOKEN.")
            return
    elif RUN_MODE == "direct":
        if not WS_HOST.strip() or WS_HOST.strip() == "trycloudflare.com":
            print("[ERROR] RUN_MODE=direct requires WS_HOST to be your Cloudflare-proxied domain.")
            return

    # TRANSPORT: "websocket" only for now — xhttp is temporarily disabled
    # (was unstable / needs more testing behind Cloudflare Tunnel).
    TRANSPORT = get_os_env("TRANSPORT").strip().lower()
    if TRANSPORT == "xhttp":
        print("[!] TRANSPORT=xhttp is temporarily disabled, falling back to 'websocket'.")
        TRANSPORT = "websocket"
    elif TRANSPORT != "websocket":
        print(f"[!] Unknown TRANSPORT '{TRANSPORT}', falling back to 'websocket'.")
        TRANSPORT = "websocket"

    # Parse multi-port configuration
    # Supported formats: "8888" (defaults to 0.0.0.0), "127.0.0.1:8888", "0.0.0.0:443,0.0.0.0:80"
    inbound_ports = []
    for p_item in PORT_ENV.split(","):
        p_item = p_item.strip()
        if ":" in p_item:
            parts = p_item.split(":")
            listen_ip = ":".join(parts[:-1])
            port_num = int(parts[-1])
            inbound_ports.append((listen_ip, port_num))
        else:
            inbound_ports.append(("0.0.0.0", int(p_item)))

    # Cloudflare tunnel will point to the first port in the list
    CLOUDFLARE_TARGET_IP = inbound_ports[0][0]
    CLOUDFLARE_TARGET_PORT = inbound_ports[0][1]
    # If listening on all interfaces, force cloudflared to connect via localhost
    if CLOUDFLARE_TARGET_IP == "0.0.0.0":
        CLOUDFLARE_TARGET_IP = "127.0.0.1"

    if RUN_MODE == "direct":
        direct_ip, direct_port = inbound_ports[0]
        if direct_port != 80:
            print(f"[!] DIRECT MODE: origin is listening on port {direct_port}. Cloudflare Flexible expects an HTTP origin on port 80.")
        print("[!] DIRECT MODE: origin leg is plaintext WebSocket (no TLS). Set Cloudflare SSL/TLS to 'Flexible'.")

    def send_webhook(data):
        if not WEBHOOK_URL:
            return
        def task():
            try:
                response = requests.post(
                    WEBHOOK_URL,
                    json=data,
                    timeout=10
                )
                if response.status_code == 200:
                    print("[+] Webhook sent successfully!")
                else:
                    print(f"[-] Webhook failed with status: {response.status_code}")
            except Exception as e:
                print(f"[!] Error sending webhook: {e}")
        thread = threading.Thread(target=task)
        thread.daemon = True
        thread.start()

    if not WS_PATH.startswith("/"):
        WS_PATH = "/" + WS_PATH

    XRAY_BIN = "./xray.exe" if platform.system().lower() == "windows" else "./xray"
    CLF_BIN = "./cloudflared.exe" if platform.system().lower() == "windows" else "./cloudflared"
    WGCF_BIN = "./wgcf-cli.exe" if platform.system().lower() == "windows" else "./wgcf-cli"

    if not os.path.exists(XRAY_BIN):
        print(f"[ERROR] Unable to find xray path: {XRAY_BIN}")
        xray_downloader.install_xray()
    if RUN_MODE != "direct" and not os.path.exists(CLF_BIN):
        print(f"[ERROR] Unable to find Cloudflared path: {CLF_BIN}")
        cloudflared_downloader.install_cloudflared()

    wgcf_outbound = None

    if ENABLE_WARP:
        if not os.path.exists(WGCF_BIN):
            print(f"[ERROR] Unable to find WGCF path: {WGCF_BIN}")
            wgcf_downloader.install_wgcf()

        if not os.path.exists("wgcf.xray.json"):
            print("[*] Generating WARP account...")
            # Dont print output of wgcf-cli to avoid leaking sensitive info, but ensure it runs successfully
            subprocess.run([WGCF_BIN, "register"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([WGCF_BIN, "generate", "--xray"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        """
        this is content of wgcf.xray.json generated by wgcf-cli, which is used to configure WARP as an outbound in Xray.
        {
            "protocol": "wireguard",
            "settings": {
                ...
            },
            "tag": "wireguard"
        }
        """
        with open("wgcf.xray.json", "r") as f:
            wgcf_outbound = json.load(f)

    # =========================================
    # VLESS-WS CONFIG GENERATOR
    # =========================================
    def build_stream_settings():
        return {
            "network": "ws",
            "security": "none",
            "wsSettings": {
                "path": WS_PATH,
                "headers": {}
            }
        }

    def write_configs():
        inbounds = []
        for ip, port in inbound_ports:
            inbounds.append({
                "port": port,
                "listen": ip,
                "protocol": "vless",
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"]
                },
                "settings": {
                    "clients": [
                        {
                            "id": UUID,
                            "level": 0
                        }
                    ],
                    "decryption": "none"
                },
                "streamSettings": build_stream_settings()
            })

        xray_config = {
            "log": {
                "loglevel": "debug"
            },
            "inbounds": inbounds,
            "outbounds": [
                {
                    "protocol": "freedom",
                    "settings": {
                        "domainStrategy": "UseIPv4"
                    }
                }
            ]
        }

        # Change outbound to WARP if enabled
        if ENABLE_WARP and wgcf_outbound:
            xray_config["outbounds"].insert(0, wgcf_outbound)

        if os.path.exists("config.json"):
            try: os.remove("config.json")
            except: pass

        with open("config.json", "w", encoding="utf-8") as f:
            json.dump(xray_config, f, indent=2)

    write_configs()

    print(f"[*] Launching XRAY with multi-port inbounds...")
    # Using 'run' with extra environment or fallback handling is ideal,
    # but natively Xray logs the error to stderr and continues if other ports work.
    xp = subprocess.Popen(
        [XRAY_BIN, "run", "-c", "config.json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding='utf-8',
        errors='replace'
    )

    def launch_cloudflared():
        # direct mode does not use cloudflared at all.
        if RUN_MODE == "direct":
            return None

        if RUN_MODE == "named_tunnel":
            print("[*] Launching Cloudflare Named Tunnel (token mode)...")
            return subprocess.Popen(
                [CLF_BIN, "tunnel", "run", "--token", TUNNEL_TOKEN],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='utf-8',
                errors='replace'
            )

        print(f"[*] Launching Cloudflare Tunnel pointing to http://{CLOUDFLARE_TARGET_IP}:{CLOUDFLARE_TARGET_PORT}...")
        return subprocess.Popen(
            [CLF_BIN, "tunnel", "--protocol", "http2", "--url", f"http://{CLOUDFLARE_TARGET_IP}:{CLOUDFLARE_TARGET_PORT}"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding='utf-8',
            errors='replace'
        )

    clp = launch_cloudflared()

    cloudflare_url = None

    try:
        logger = RealtimeLogger(port=9999, password=None)
        logger_url = logger.start()
        print(f"[*] Logger Web UI is running at: {logger_url}")
    except Exception:
        logger = None

    def logger_push(message, source):
        if logger:
            logger.push_log(f"[{source}] {message}", source)
            print(f"[{source}] {message}") if DEBUG_MODE else None

    def monitor_xray(pipe):
        try:
            with pipe:
                for line in iter(pipe.readline, ''):
                    # Suppress or catch common permission denied / bind errors quietly for Termux environment
                    if "Permission denied" in line or "EACCES" in line or "address already in use" in line:
                        # Log silently to Web UI instead of crashing the main process stdout aggressively
                        if logger:
                            logger_push(f"[SILENT BIND WARNING] {line.strip()}", "XRAY")
                        continue

                    if logger:
                        logger_push(line.strip(), "XRAY")
        except Exception:
            pass

    def monitor_cloudflare(pipe):
        nonlocal cloudflare_url
        ansi_escape = re.compile(r'\x1b\[[0-9;]*[mK]')
        try:
            with pipe:
                for line in iter(pipe.readline, ''):
                    clean_line = ansi_escape.sub('', line)
                    print(f"[CLOUDFLARE LOG] {clean_line.strip()}")

                    if RUN_MODE == "named_tunnel":
                        # Named tunnel via token: the hostname is whatever was
                        # configured on the Cloudflare Zero Trust dashboard
                        # (WS_HOST), not something printed to stdout. Instead,
                        # watch for a "connection registered" log line to know
                        # the tunnel is actually up, then print links once.
                        if cloudflare_url is None and re.search(r'[Rr]egistered tunnel connection', clean_line):
                            cloudflare_url = WS_HOST
                            print_vless_links(cloudflare_url, UUID, FAKE_SNI, WS_PATH)
                        continue

                    match = re.search(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com', clean_line)
                    if match:
                        new_url = match.group(0).replace("https://", "")
                        if new_url != cloudflare_url:
                            if cloudflare_url:
                                print(f"[*] Detected new tunnel domain: {new_url} (was: {cloudflare_url})")
                            cloudflare_url = new_url
                            print_vless_links(cloudflare_url, UUID, FAKE_SNI, WS_PATH)
        except Exception as e:
            # print(e)
            pass

    threading.Thread(target=monitor_xray, args=(xp.stdout,), daemon=True).start()
    if clp is not None:
        threading.Thread(target=monitor_cloudflare, args=(clp.stdout,), daemon=True).start()

    def print_vless_links(tunnel_host, uuid_str, fake_sni, ws_path):
        import urllib.parse
        encoded_path = urllib.parse.quote(ws_path, safe='')

        tunnel_host_info = tunnel_host
        if WS_HOST and WS_HOST != "trycloudflare.com":
            tunnel_host_info = WS_HOST

        net_type = "ws"
        mode_param = ""

        payloads = []

        mode_prefix_map = {"quick_tunnel": "Quick Tunnel", "named_tunnel": "Named Tunnel", "direct": "Direct"}; mode_prefix = mode_prefix_map.get(RUN_MODE, "Tunnel")
        sni_list = fake_sni.split(",")

        for idx, sni_entry in enumerate(sni_list):
            sni_entry = sni_entry.strip()
            if "#" in sni_entry:
                sni, remark = sni_entry.split("#", 1)
                sni = sni.strip()
                remark = remark.strip() or f"{mode_prefix} {idx+1}"
            else:
                sni = sni_entry
                remark = f"{mode_prefix} {idx+1}"

            encoded_remark = urllib.parse.quote(remark, safe='')

            # TLS link: address=FAKE_SNI, sni=WS_HOST (domain that)
            # ISP only sees connection to FAKE_SNI (e.g. tiktok.com)
            # Cloudflare uses SNI to route to user's real domain
            payloads.append(
                f"vless://{uuid_str}@{sni}:443?type={net_type}&encryption=none&security=tls&path={encoded_path}&host={tunnel_host_info}&sni={tunnel_host_info}{mode_param}#{encoded_remark}%20TLS"
            )

            # NO-TLS link (non-standard, only for tunnel modes)
            if RUN_MODE != "direct":
                payloads.append(
                    f"vless://{uuid_str}@{sni}:80?type={net_type}&encryption=none&security=&path={encoded_path}&host={tunnel_host_info}{mode_param}#{encoded_remark}%20NO%20TLS"
                )

        if RUN_MODE == "direct":
            print("\n" + "="*70)
            print(" DIRECT MODE (Cloudflare proxied DNS -> origin :80)")
            print("="*70)
            print("="*70 + "\n")
        else:
            print("\n" + "="*70)
            print(" CONNECTED TO CLOUDFLARE TUNNEL")
            print("="*70)
            print("="*70 + "\n")

        with open("frp_info.config", "w", encoding='utf-8') as f:
            for payload in payloads:
                f.write(payload)
                f.write("\n") if payloads.index(payload) < len(payloads)-1 else None
                print(payload) if DEBUG_MODE else None
            print("Written to frp_info.config")

        frp_info = {
            "payloads": payloads,
            "ip": get_public_url(),
            "wshost": tunnel_host,
            "wspath": ws_path,
            "transport": TRANSPORT,
            "start_time": START_TIME,
        }

        send_webhook(frp_info)
        with open("frp_info.json", "w", encoding='utf-8') as f:
            json.dump(frp_info, f, indent=4)
            print("Written to frp_info.json")

    # Direct mode has no cloudflared process to scrape a hostname from,
    # so generate links immediately from the configured WS_HOST.
    if RUN_MODE == "direct":
        cloudflare_url = WS_HOST
        print("[!] Recommended: restrict origin port 80 to Cloudflare IP ranges only.")
        print_vless_links(cloudflare_url, UUID, FAKE_SNI, WS_PATH)

    try:
        while True:
            if RUN_MODE == "direct":
                # Only monitor Xray; there is no cloudflared process.
                if xp.poll() is not None:
                    print("\n[!] WARNING: Xray process has stopped.")
                    break
            else:
                # Termux workaround: We don't crash if Xray returns a code but cloudflared is still happily running on the local port 8888.
                # However, if both stop or core configuration is broken, we terminate.
                if xp.poll() is not None and clp.poll() is not None:
                    print("\n[!] WARNING: Both processes have stopped.")
                    break

                # If only cloudflared died (e.g. quick tunnel dropped/restarted), relaunch it.
                # This will get a brand new trycloudflare.com domain, which monitor_cloudflare
                # picks up and re-broadcasts via print_vless_links() + webhook automatically.
                if clp.poll() is not None and xp.poll() is None:
                    print("[!] Cloudflare Tunnel process stopped unexpectedly. Restarting...")
                    clp = launch_cloudflared()
                    threading.Thread(target=monitor_cloudflare, args=(clp.stdout,), daemon=True).start()

            time.sleep(1)

    except KeyboardInterrupt:
        print("\n[*] Stopping services...")
    finally:
        try: xp.terminate()
        except: pass
        if clp is not None:
            try: clp.terminate()
            except: pass

if __name__ == "__main__":
    main()
