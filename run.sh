#!/usr/bin/env bash
set -o pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$SCRIPT_DIR" || exit 1

# Systemd
SERVICE_NAME="xray-vless"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Defaults mirroring main.py
DEF_PORT_QUICK="127.0.0.1:8888"
DEF_PORT_NAMED="127.0.0.1:8888"
DEF_PORT_DIRECT="0.0.0.0:80"
DEF_FAKE_SNI="api24-normal-alisg.tiktokv.com,vnpt.theworkpc.com"
DEF_WS_PATH="/tiktok4g"
DEF_WS_HOST="trycloudflare.com"
DEF_TRANSPORT="websocket"

# Runtime variables
RUN_MODE=""; PORT=""; UUID=""; FAKE_SNI=""; WS_PATH=""; WS_HOST=""; TUNNEL_TOKEN=""; ENABLE_WARP="false"; WEBHOOK_URL=""; TRANSPORT="websocket"

header(){ echo -e "${CYAN}===================================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${CYAN}===================================================${NC}"; }
ok(){ echo -e "${GREEN}OK: $1${NC}"; }
warn(){ echo -e "${YELLOW}WARN: $1${NC}"; }
err(){ echo -e "${RED}ERR: $1${NC}"; }
info(){ echo -e "${BLUE}INFO: $1${NC}"; }
ask_yes_no(){ local ans hint default="${2:-y}"; [ "$default" = "y" ] && hint="Y/n" || hint="y/N"; read -r -p "$1 [$hint]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy]$ ]]; }
ask_val(){ local prompt="$1" default="$2" ans; read -r -p "$prompt [$default]: " ans; [ -n "$ans" ] && echo "$ans" || echo "$default"; }
env_get(){ grep -E "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2-; }

run_as_root(){
    if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

uuid_gen(){
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null
    fi
}

# =========== Python dependency bootstrap ===========
detect_python(){
    if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        echo "$SCRIPT_DIR/.venv/bin/python"; return
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo python3; return
    fi
    if command -v python >/dev/null 2>&1; then
        if python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
            echo python; return
        fi
    fi
    err "Python 3 not found. Install: sudo apt-get install python3 python3-venv python3-pip"
}

install_venv_package(){
    local py="$1"
    command -v apt-get >/dev/null 2>&1 || return 1
    local pyver
    pyver="$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "3")"
    info "Auto-installing python${pyver}-venv python3-pip via apt..."
    run_as_root apt-get update -qq 2>/dev/null
    run_as_root apt-get install -y -qq "python${pyver}-venv" python3-pip 2>&1 | tail -5
}

ensure_python_deps(){
    local py="$1"
    if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
        return 0
    fi

    warn "Missing Python dependencies (python-dotenv, requests, zstandard). Installing..."

    # Already in a venv? pip install directly.
    if "$py" -c 'import sys; sys.exit(0 if hasattr(sys, "real_prefix") or (hasattr(sys, "base_prefix") and sys.base_prefix != sys.prefix) else 1)' 2>/dev/null; then
        "$py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -5
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed into virtualenv."; return 0
        fi
        err "pip install failed."; return 1
    fi

    # Try pip --user
    if "$py" -m pip install --user -q python-dotenv requests zstandard 2>/dev/null; then
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed (--user)."; return 0
        fi
    fi

    # Try --break-system-packages (PEP 668)
    if "$py" -m pip install --break-system-packages -q python-dotenv requests zstandard 2>/dev/null; then
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed (--break-system-packages)."; return 0
        fi
    fi

    # Create project-local .venv
    info "Creating project-local virtualenv (.venv/)..."
    rm -rf "$SCRIPT_DIR/.venv"
    if ! "$py" -m venv "$SCRIPT_DIR/.venv" 2>/dev/null || [ ! -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        # Missing python3-venv package — try to auto-install it
        install_venv_package "$py"
        rm -rf "$SCRIPT_DIR/.venv"
        "$py" -m venv "$SCRIPT_DIR/.venv" 2>/dev/null
    fi

    if [ ! -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        err "Failed to create .venv."; return 1
    fi

    local venv_py="$SCRIPT_DIR/.venv/bin/python"
    "$venv_py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -5
    if "$venv_py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
        ok "Dependencies installed into .venv/."
        PYBIN="$venv_py"; return 0
    fi
    err "Failed to install dependencies into .venv."; return 1
}

run_python(){
    PYBIN="$(detect_python)"
    [ -z "$PYBIN" ] && return 1
    ok "Using Python: $PYBIN"
    ensure_python_deps "$PYBIN" || return 1
    "$PYBIN" main.py
}

# =========== .env ===========
write_env(){
    {
        echo "RUN_MODE=$RUN_MODE"
        echo "PORT=$PORT"
        echo "XRAY_UUID=$UUID"
        echo "FAKE_SNI=$FAKE_SNI"
        echo "WS_PATH=$WS_PATH"
        echo "WS_HOST=$WS_HOST"
        echo "TRANSPORT=$TRANSPORT"
        echo "ENABLE_WARP=$ENABLE_WARP"
        echo "WEBHOOK_URL=$WEBHOOK_URL"
        echo "TUNNEL_TOKEN=$TUNNEL_TOKEN"
    } > .env
    ok "Written .env (RUN_MODE=$RUN_MODE)"
}

load_existing(){
    [ -f .env ] || return 0
    UUID="$(env_get XRAY_UUID)"; FAKE_SNI="$(env_get FAKE_SNI)"
    WS_PATH="$(env_get WS_PATH)"; WS_HOST="$(env_get WS_HOST)"
    TUNNEL_TOKEN="$(env_get TUNNEL_TOKEN)"; ENABLE_WARP="$(env_get ENABLE_WARP)"
    WEBHOOK_URL="$(env_get WEBHOOK_URL)"; TRANSPORT="$(env_get TRANSPORT)"
}

# =========== Modes ===========
quick_mode(){
    header "1. Quick Tunnel (trycloudflare.com)"
    info "Fastest way, no domain required. Cloudflare gives a random hostname each run."
    load_existing
    local def_uuid; def_uuid="${UUID:-$(uuid_gen)}"
    local def_sni; def_sni="${FAKE_SNI:-$DEF_FAKE_SNI}"
    local def_path; def_path="${WS_PATH:-$DEF_WS_PATH}"
    UUID="$(ask_val "VLESS UUID" "$def_uuid")"
    FAKE_SNI="$(ask_val "FAKE_SNI (zero-rated domains, comma separated)" "$def_sni")"
    WS_PATH="$(ask_val "WebSocket path" "$def_path")"
    RUN_MODE="quick_tunnel"; PORT="$DEF_PORT_QUICK"; WS_HOST="$DEF_WS_HOST"
    TUNNEL_TOKEN=""; TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env
    echo
    warn "Quick Tunnel hostname (*.trycloudflare.com) changes every restart."
    info "For a FIXED domain: use mode 2 (Named Tunnel) / mode 3 (Direct)."
    echo
    run_python
}

named_mode(){
    header "2. Named Cloudflare Tunnel + custom domain"
    info "Requires a domain already added to Cloudflare Zero Trust."
    echo -e "${CYAN}Before continuing, in Cloudflare Zero Trust dashboard:${NC}"
    echo -e "  1. Networks -> Tunnels -> Create a tunnel -> Cloudflared -> copy the connector token."
    echo -e "  2. Public Hostname: hostname = your domain, Service = ${GREEN}http://127.0.0.1:8888${NC}"
    echo -e "  (No A/AAAA record pointing to this machine is needed - the tunnel connects outbound.)"
    echo
    read -r -p "Press Enter when ready..." _
    load_existing
    local def_host; def_host="${WS_HOST:-}"; [ "$def_host" = "trycloudflare.com" ] && def_host=""
    local def_token; def_token="${TUNNEL_TOKEN:-}"
    WS_HOST="$(ask_val "Domain (e.g. vless.example.com)" "$def_host")"
    TUNNEL_TOKEN="$(ask_val "Tunnel connector token" "$def_token")"
    if [ -z "$WS_HOST" ] || [ "$WS_HOST" = "trycloudflare.com" ]; then
        err "A custom domain is required."; return 1
    fi
    if [ -z "$TUNNEL_TOKEN" ]; then
        err "A tunnel connector token is required."; return 1
    fi
    RUN_MODE="named_tunnel"; PORT="$DEF_PORT_NAMED"
    UUID="${UUID:-$(uuid_gen)}"; FAKE_SNI="${FAKE_SNI:-$DEF_FAKE_SNI}"
    WS_PATH="${WS_PATH:-$DEF_WS_PATH}"; TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env; echo; run_python
}

direct_mode(){
    header "3. Direct Cloudflare proxied DNS -> VPS"
    info "No cloudflared. Cloudflare edge forwards plaintext HTTP/WebSocket to this VPS on port 80."
    echo -e "${CYAN}Before continuing, in Cloudflare DNS for your domain:${NC}"
    echo -e "  1. Add record: ${GREEN}vless.example.com -> A -> <your VPS IP>${NC}, turn proxy ${GREEN}ON (orange cloud)${NC}."
    echo -e "  2. SSL/TLS -> encryption mode = ${GREEN}Flexible${NC}."
    echo -e "  3. Allow inbound TCP ${GREEN}80${NC} from Cloudflare IP ranges only (recommended)."
    echo
    read -r -p "Press Enter when ready..." _
    load_existing
    local def_host; def_host="${WS_HOST:-}"; [ "$def_host" = "trycloudflare.com" ] && def_host=""
    local def_port; def_port="$DEF_PORT_DIRECT"
    WS_HOST="$(ask_val "Domain (e.g. vless.example.com)" "$def_host")"
    PORT="$(ask_val "Origin listen address:port" "$def_port")"
    if [ -z "$WS_HOST" ] || [ "$WS_HOST" = "trycloudflare.com" ]; then
        err "A Cloudflare-proxied domain is required."; return 1
    fi
    RUN_MODE="direct"; UUID="${UUID:-$(uuid_gen)}"
    FAKE_SNI="${FAKE_SNI:-$DEF_FAKE_SNI}"; WS_PATH="${WS_PATH:-$DEF_WS_PATH}"
    TUNNEL_TOKEN=""; TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env; echo; run_python
}

# =========== Process management ===========
kill_runtime_processes(){
    local found=0
    for pid in /proc/[0-9]*; do
        [ -d "$pid" ] || continue
        local p="${pid##*/}"
        local cwd=""; cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
        [ "$cwd" = "$SCRIPT_DIR" ] || continue
        local exe=""; exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
        case "$exe" in
            "$SCRIPT_DIR/xray"|"$SCRIPT_DIR/cloudflared"|"$SCRIPT_DIR/wgcf-cli")
                kill "$p" 2>/dev/null && { found=1; ok "Stopped $p ($(basename "$exe"))"; } ;;
        esac
        local cmdline=""; cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
            *main.py*) kill "$p" 2>/dev/null && { found=1; ok "Stopped $p (main.py)"; } ;;
        esac
    done
    [ "$found" = "1" ] || return 0
    sleep 1
    for pid in /proc/[0-9]*; do
        [ -d "$pid" ] || continue
        local p="${pid##*/}"
        local cwd=""; cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
        [ "$cwd" = "$SCRIPT_DIR" ] || continue
        local exe=""; exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
        case "$exe" in
            "$SCRIPT_DIR/xray"|"$SCRIPT_DIR/cloudflared"|"$SCRIPT_DIR/wgcf-cli") kill -9 "$p" 2>/dev/null ;; esac
        local cmdline=""; cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
        case "$cmdline" in *main.py*) kill -9 "$p" 2>/dev/null ;; esac
    done
}

# =========== Systemd service manager ===========
service_install(){
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd not available on this system."; return 1
    fi
    if [ "$(id -u)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
        err "Need root or sudo."; return 1
    fi
    if [ ! -f .env ]; then
        err "No .env found. Configure a mode (1-3) from main menu first."; return 1
    fi

    PYBIN="$(detect_python)"
    [ -z "$PYBIN" ] && return 1
    ok "Using Python: $PYBIN"
    ensure_python_deps "$PYBIN" || return 1

    # Resolve absolute path
    local py_abs
    if [[ "$PYBIN" = /* ]]; then py_abs="$PYBIN"
    else py_abs="$(command -v "$PYBIN" 2>/dev/null)"; fi
    py_abs="$(readlink -f "$py_abs" 2>/dev/null || echo "$py_abs")"

    # Stop existing
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        warn "Service already running. Stopping first..."
        run_as_root systemctl stop "$SERVICE_NAME"
    fi

    info "Creating systemd unit: $SERVICE_NAME"
    run_as_root tee "$SERVICE_FILE" >/dev/null <<UNIT
[Unit]
Description=Xray VLESS-WS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$py_abs $SCRIPT_DIR/main.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
UNIT

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "$SERVICE_NAME" 2>/dev/null
    run_as_root systemctl start "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        ok "Service $SERVICE_NAME installed, enabled, and running."
        info "Auto-starts on boot. View logs: journalctl -u $SERVICE_NAME -f"
    else
        err "Service failed to start."
        info "Check: journalctl -u $SERVICE_NAME -e --no-pager -n 30"
    fi
}

service_stop(){
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Service is not running."; return 0
    fi
    run_as_root systemctl stop "$SERVICE_NAME"
    ok "Service stopped."
}

service_restart(){
    if [ ! -f "$SERVICE_FILE" ]; then
        err "Service not installed. Use 'Install & Start' first."; return 1
    fi
    run_as_root systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        ok "Service restarted."
    else
        err "Service failed to restart."
        info "Check: journalctl -u $SERVICE_NAME -e --no-pager -n 30"
    fi
}

service_logs(){
    if [ ! -f "$SERVICE_FILE" ]; then
        err "Service not installed."; return 1
    fi
    info "Showing live logs. Press Ctrl+C to stop."
    echo
    journalctl -u "$SERVICE_NAME" -f --no-pager -n 50
}

service_status(){
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd not available."; return 1
    fi
    if [ ! -f "$SERVICE_FILE" ]; then
        info "Service $SERVICE_NAME is not installed."; return 0
    fi
    systemctl status "$SERVICE_NAME" --no-pager -l
}

service_uninstall(){
    if [ ! -f "$SERVICE_FILE" ]; then
        info "Service $SERVICE_NAME is not installed."; return 0
    fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        run_as_root systemctl stop "$SERVICE_NAME"
        ok "Stopped."
    fi
    run_as_root systemctl disable "$SERVICE_NAME" 2>/dev/null
    run_as_root rm -f "$SERVICE_FILE"
    run_as_root systemctl daemon-reload
    ok "Service $SERVICE_NAME disabled and removed."
}

service_manager(){
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd is not available on this system."; return 1
    fi
    while true; do
        header "Service Manager (systemd)"
        # Status line
        local status_text
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            status_text="${GREEN}● Running${NC}"
        elif [ -f "$SERVICE_FILE" ]; then
            status_text="${YELLOW}● Stopped${NC}"
        else
            status_text="${RED}● Not installed${NC}"
        fi
        echo -e "  Service : ${CYAN}${SERVICE_NAME}${NC}"
        echo -e "  Status  : $status_text"
        if [ -f .env ]; then
            echo -e "  Mode    : ${CYAN}$(env_get RUN_MODE)${NC}  →  $(env_get WS_HOST)"
        else
            echo -e "  Config  : ${RED}No .env (configure mode 1-3 first)${NC}"
        fi
        echo
        echo "1. Install & Enable & Start"
        echo "2. Stop"
        echo "3. Restart"
        echo "4. View logs (live)"
        echo "5. Status"
        echo "6. Disable & Remove service"
        echo "7. Back to main menu"
        read -r -p "Choice [1-7]: " SVC_CHOICE
        case "$SVC_CHOICE" in
            1) service_install ;;
            2) service_stop ;;
            3) service_restart ;;
            4) service_logs ;;
            5) service_status ;;
            6) service_uninstall ;;
            7) return ;;
            *) err "Invalid choice" ;;
        esac
        echo
        read -r -p "Press Enter to continue..." _
    done
}

# =========== Uninstall ===========
uninstall_mode(){
    header "5. Uninstall"
    info "Stops running processes and deletes ONLY files this project downloaded or generated."
    echo -e "${YELLOW}Will remove:${NC}"
    echo "  - Binaries: xray, cloudflared, wgcf-cli (and .exe variants)"
    echo "  - Generated: .env, config.json, wgcf.json, wgcf.xray.json, frp_info.json, frp_info.config, frpc.toml, config.yml"
    echo "  - Temp: xray.zip, cloudflared_temp.archive, wgcf-cli.tar.zstd"
    echo "  - Folders: xray_bin, wgcf_bin, __pycache__, .venv"
    [ -f "$SERVICE_FILE" ] && echo -e "  - Systemd service: ${CYAN}$SERVICE_NAME${NC}"
    echo
    info "Source files (main.py, run.sh, docs, .git, requirements.txt) are NEVER touched."
    echo
    if ! ask_yes_no "Proceed with uninstall?" "n"; then
        info "Canceled."; return 0
    fi
    # Remove systemd service first
    if [ -f "$SERVICE_FILE" ]; then service_uninstall; fi
    kill_runtime_processes
    local removed=0; local item
    for item in xray xray.exe cloudflared cloudflared.exe wgcf-cli wgcf-cli.exe \
                .env config.json wgcf.json wgcf.xray.json frp_info.json frp_info.config \
                frpc.toml config.yml xray.zip cloudflared_temp.archive wgcf-cli.tar.zstd; do
        [ -e "$item" ] && rm -rf -- "$item" && { ok "Removed $item"; removed=1; }
    done
    for item in xray_bin wgcf_bin __pycache__ .venv; do
        [ -d "$item" ] && rm -rf -- "$item" && { ok "Removed $item/"; removed=1; }
    done
    [ "$removed" = "0" ] && info "Nothing to remove - already clean." || ok "Uninstall complete."
}

# =========== Main menu ===========
while true; do
    header "Xray VLESS-WS Server"
    echo "1. Quick Tunnel (trycloudflare.com) - fastest, no domain"
    echo "2. Named Cloudflare Tunnel + custom domain"
    echo "3. Direct Cloudflare proxied DNS -> VPS"
    echo "4. Service Manager (systemd)"
    echo "5. Uninstall (remove downloaded binaries + generated files)"
    echo "6. Exit"
    read -r -p "Choice [1-6]: " MENU_CHOICE
    case "$MENU_CHOICE" in
        1) quick_mode ;;
        2) named_mode ;;
        3) direct_mode ;;
        4) service_manager ;;
        5) uninstall_mode ;;
        6) exit 0 ;;
        *) err "Invalid choice" ;;
    esac
    echo
    read -r -p "Press Enter to return to menu..." _
done