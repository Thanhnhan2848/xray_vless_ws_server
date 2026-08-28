#!/usr/bin/env bash
set -o pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$SCRIPT_DIR" || exit 1

# Detect Termux
IS_TERMUX=false
if [ -n "${TERMUX_VERSION:-}" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
    IS_TERMUX=true
fi

SERVICE_NAME="xray-vless"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DEF_PORT_QUICK="127.0.0.1:8888"
DEF_PORT_NAMED="127.0.0.1:8888"
DEF_PORT_DIRECT="0.0.0.0:80"
DEF_FAKE_SNI="api24-normal-alisg.tiktokv.com#Free Tiktok,vnpt.theworkpc.com#Free Vina Ko Nen"
DEF_WS_PATH="/tiktok4g"
DEF_WS_HOST="trycloudflare.com"
DEF_TRANSPORT="websocket"

RUN_MODE=""; PORT=""; UUID=""; FAKE_SNI=""; WS_PATH=""; WS_HOST=""; TUNNEL_TOKEN=""; ENABLE_WARP="false"; WEBHOOK_URL=""; TRANSPORT="websocket"; COUNTRY_CODE=""; CUSTOM_DOMAIN=""; PORT_MODE=""; SUBSCRIPTION_SYNC_URL=""; SUBSCRIPTION_SYNC_TOKEN=""; SUBSCRIPTION_NODE_ID=""

header(){ echo; echo -e "${CYAN}===================================================${NC}"; echo -e "${GREEN} $1${NC}"; echo -e "${CYAN}===================================================${NC}"; }
ok(){ echo -e " ${GREEN}[OK]${NC} $1"; }
warn(){ echo -e " ${YELLOW}[!]${NC}  $1"; }
err(){ echo -e " ${RED}[ERR]${NC} $1"; }
info(){ echo -e " ${BLUE}[i]${NC}  $1"; }
pause_next(){ echo; read -r -p " Press Enter to continue..." _; }
ask_yes_no(){ local ans hint default="${2:-y}"; [ "$default" = "y" ] && hint="Y/n" || hint="y/N"; read -r -p " $1 [$hint]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy]$ ]]; }
ask_val(){ local prompt="$1" default="$2" ans; read -r -p " $prompt [$default]: " ans; [ -n "$ans" ] && echo "$ans" || echo "$default"; }
ask_country(){
    local ans cc
    echo
    echo -e " ${BLUE}[i]${NC}  Server country flag (optional)"
    echo -e "      Hint: VN  JP  US  SG  DE  FR  KR  HK  TW  NL  GB  AU  CA"
    read -r -p " Country code (Enter to skip) [${COUNTRY_CODE:-}]: " ans
    if [ -n "$ans" ]; then
        cc="$(printf '%s' "$ans" | tr 'a-z' 'A-Z' | tr -dc 'A-Z')"
        COUNTRY_CODE="${cc:0:2}"
    fi
    [ -n "$COUNTRY_CODE" ] && ok "Country: $COUNTRY_CODE" || info "No country flag."
}
ask_fake_sni(){
    local choice
    echo
    echo -e " ${BLUE}[i]${NC}  FAKE_SNI selection:"
    echo "   1) Free Tiktok  (api24-normal-alisg.tiktokv.com)"
    echo "   2) Free Vina Ko Nen  (vnpt.theworkpc.com)"
    echo "   3) Both (default)"
    echo "   Or type a custom FAKE_SNI value"
    read -r -p " Choose [1/2/3/custom]: " choice
    case "$choice" in
        1) FAKE_SNI="api24-normal-alisg.tiktokv.com#Free Tiktok" ;;
        2) FAKE_SNI="vnpt.theworkpc.com#Free Vina Ko Nen" ;;
        3|"") FAKE_SNI="$DEF_FAKE_SNI" ;;
        *) FAKE_SNI="$choice" ;;
    esac
    ok "FAKE_SNI: $FAKE_SNI"
}
ask_port_mode(){
    local choice
    echo
    echo -e " ${BLUE}[i]${NC}  Port selection for VLESS links:"
    echo "   1) Port 80 only (NO TLS)"
    echo "   2) Port 443 only (TLS)"
    echo "   3) Both 80 + 443 (default)"
    read -r -p " Choose [1/2/3]: " choice
    case "$choice" in
        1) PORT_MODE="80" ;;
        2) PORT_MODE="443" ;;
        3|"") PORT_MODE="both" ;;
        *) PORT_MODE="both" ;;
    esac
    ok "Port mode: $PORT_MODE"
}
ask_subscription_sync(){
    local enabled
    echo
    echo -e " ${BLUE}[i]${NC}  Multi-VPS subscription sync (optional)"
    echo "      Enter keeps current value; type - to disable sync."
    read -r -p " Hub sync URL [${SUBSCRIPTION_SYNC_URL:-}]: " enabled
    if [ "$enabled" = "-" ]; then
        SUBSCRIPTION_SYNC_URL=""
        SUBSCRIPTION_SYNC_TOKEN=""
        SUBSCRIPTION_NODE_ID=""
        info "Subscription sync disabled for this VPS."
    elif [ -n "$enabled" ] || [ -n "$SUBSCRIPTION_SYNC_URL" ]; then
        [ -n "$enabled" ] && SUBSCRIPTION_SYNC_URL="$enabled"
        SUBSCRIPTION_NODE_ID="$(ask_val "Node ID (unique: vps-jp-1)" "${SUBSCRIPTION_NODE_ID:-}")"
        SUBSCRIPTION_SYNC_TOKEN="$(ask_val "Hub sync token" "${SUBSCRIPTION_SYNC_TOKEN:-}")"
        [ -z "$SUBSCRIPTION_NODE_ID" ] && { err "Node ID is required when sync is enabled."; return 1; }
        [ -z "$SUBSCRIPTION_SYNC_TOKEN" ] && { err "Hub token is required when sync is enabled."; return 1; }
        ok "This VPS will sync as: $SUBSCRIPTION_NODE_ID"
    else
        info "Subscription sync disabled for this VPS."
    fi
}

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

# ==================== Termux ====================
termux_bootstrap(){
    $IS_TERMUX || return 0
    echo
    echo -e " ${GREEN}========================================${NC}"
    echo -e " ${GREEN}  Ban dang chay server tren Termux!${NC}"
    echo -e " ${GREEN}========================================${NC}"
    echo
    info "Checking Termux packages..."
    if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        info "Installing python & git..."
        pkg install python git -y 2>&1 | tail -5
    fi
    ok "Termux packages ready."
}

# ==================== Python bootstrap ====================
detect_python(){
    if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        if "$SCRIPT_DIR/.venv/bin/python" -m pip --version >/dev/null 2>&1; then
            echo "$SCRIPT_DIR/.venv/bin/python"; return
        fi
        warn "Broken .venv (no pip). Removing..."
        rm -rf "$SCRIPT_DIR/.venv"
    fi
    if command -v python3 >/dev/null 2>&1; then echo python3; return; fi
    if command -v python >/dev/null 2>&1; then
        if python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
            echo python; return
        fi
    fi
    err "Python 3 not found. Install: sudo apt install python3 python3-venv python3-pip"
}

install_venv_package(){
    local py="$1"
    command -v apt-get >/dev/null 2>&1 || return 1
    local pyver
    pyver="$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "3")"
    info "Auto-installing python${pyver}-venv python3-pip via apt..."
    run_as_root apt-get update -qq 2>/dev/null
    run_as_root apt-get install -y -qq "python${pyver}-venv" python3-pip 2>&1 | tail -3
}

ensure_python_deps(){
    local py="$1"
    if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then return 0; fi
    warn "Missing Python deps. Installing..."

    # If in a venv already
    if "$py" -c 'import sys; sys.exit(0 if hasattr(sys, "real_prefix") or (hasattr(sys, "base_prefix") and sys.base_prefix != sys.prefix) else 1)' 2>/dev/null; then
        if "$py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -3; then
            "$py" -c "import dotenv, requests, zstandard" 2>/dev/null && { ok "Deps installed."; return 0; }
        fi
        if [[ "$py" = "$SCRIPT_DIR/.venv/"* ]]; then
            warn "Broken .venv. Recreating..."
            rm -rf "$SCRIPT_DIR/.venv"
            py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
            [ -z "$py" ] && { err "No system Python3."; return 1; }
        else
            err "pip failed in external venv."; return 1
        fi
    fi

    # pip --user
    if "$py" -m pip install --user -q python-dotenv requests zstandard 2>/dev/null; then
        "$py" -c "import dotenv, requests, zstandard" 2>/dev/null && { ok "Deps installed (--user)."; return 0; }
    fi
    # --break-system-packages
    if "$py" -m pip install --break-system-packages -q python-dotenv requests zstandard 2>/dev/null; then
        "$py" -c "import dotenv, requests, zstandard" 2>/dev/null && { ok "Deps installed."; return 0; }
    fi

    # Create .venv
    info "Creating .venv..."
    rm -rf "$SCRIPT_DIR/.venv"
    if ! "$py" -m venv "$SCRIPT_DIR/.venv" 2>/dev/null || [ ! -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        install_venv_package "$py"
        rm -rf "$SCRIPT_DIR/.venv"
        "$py" -m venv "$SCRIPT_DIR/.venv" 2>/dev/null
    fi
    [ -x "$SCRIPT_DIR/.venv/bin/python" ] || { err "Failed to create .venv."; return 1; }
    local venv_py="$SCRIPT_DIR/.venv/bin/python"
    "$venv_py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -3
    if "$venv_py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
        ok "Deps installed into .venv/."
        PYBIN="$venv_py"; return 0
    fi
    err "Failed to install deps."; return 1
}

prepare_python(){
    PYBIN="$(detect_python)"
    [ -z "$PYBIN" ] && return 1
    ensure_python_deps "$PYBIN" || return 1
    # Resolve absolute
    if [[ "$PYBIN" = /* ]]; then PYBIN_ABS="$PYBIN"
    else PYBIN_ABS="$(command -v "$PYBIN" 2>/dev/null)"; fi
    PYBIN_ABS="$(readlink -f "$PYBIN_ABS" 2>/dev/null || echo "$PYBIN_ABS")"
    ok "Python ready: $PYBIN_ABS"
}

# ==================== .env ====================
write_env(){
    {
        echo "RUN_MODE=$RUN_MODE"; echo "PORT=$PORT"; echo "XRAY_UUID=$UUID"
        echo "FAKE_SNI=$FAKE_SNI"; echo "WS_PATH=$WS_PATH"; echo "WS_HOST=$WS_HOST"
        echo "TRANSPORT=$TRANSPORT"; echo "ENABLE_WARP=$ENABLE_WARP"
        echo "WEBHOOK_URL=$WEBHOOK_URL"; echo "TUNNEL_TOKEN=$TUNNEL_TOKEN"
        echo "COUNTRY_CODE=$COUNTRY_CODE"
        echo "CUSTOM_DOMAIN=$CUSTOM_DOMAIN"
        echo "PORT_MODE=$PORT_MODE"
        echo "SUBSCRIPTION_SYNC_URL=$SUBSCRIPTION_SYNC_URL"; echo "SUBSCRIPTION_SYNC_TOKEN=$SUBSCRIPTION_SYNC_TOKEN"; echo "SUBSCRIPTION_NODE_ID=$SUBSCRIPTION_NODE_ID"
    } > .env
    ok "Written .env (RUN_MODE=$RUN_MODE)"
}

load_existing(){
    [ -f .env ] || return 0
    UUID="$(env_get XRAY_UUID)"; FAKE_SNI="$(env_get FAKE_SNI)"
    WS_PATH="$(env_get WS_PATH)"; WS_HOST="$(env_get WS_HOST)"
    TUNNEL_TOKEN="$(env_get TUNNEL_TOKEN)"; ENABLE_WARP="$(env_get ENABLE_WARP)"
    WEBHOOK_URL="$(env_get WEBHOOK_URL)"; TRANSPORT="$(env_get TRANSPORT)"
    COUNTRY_CODE="$(env_get COUNTRY_CODE)"
    CUSTOM_DOMAIN="$(env_get CUSTOM_DOMAIN)"
    PORT_MODE="$(env_get PORT_MODE)"
    SUBSCRIPTION_SYNC_URL="$(env_get SUBSCRIPTION_SYNC_URL)"; SUBSCRIPTION_SYNC_TOKEN="$(env_get SUBSCRIPTION_SYNC_TOKEN)"; SUBSCRIPTION_NODE_ID="$(env_get SUBSCRIPTION_NODE_ID)"
}

# ==================== Systemd ====================
install_service(){
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd not available."; return 1
    fi
    if [ "$(id -u)" != "0" ] && ! command -v sudo >/dev/null 2>&1; then
        err "Need root or sudo."; return 1
    fi
    [ -f .env ] || { err "No .env found."; return 1; }
    prepare_python || return 1

    # Stop old if running
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && run_as_root systemctl stop "$SERVICE_NAME"

    info "Installing systemd service: $SERVICE_NAME"
    run_as_root tee "$SERVICE_FILE" >/dev/null <<UNIT
[Unit]
Description=Xray VLESS-WS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
ExecStart=$PYBIN_ABS $SCRIPT_DIR/main.py
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
    ok "Service started. Waiting for VLESS links..."
}

wait_and_show_links(){
    # Wait for frp_info.config to be written by main.py
    local tries=0
    while [ $tries -lt 30 ]; do
        if [ -f "$SCRIPT_DIR/frp_info.config" ] && [ -s "$SCRIPT_DIR/frp_info.config" ]; then
            sleep 2  # let main.py finish writing
            echo
            header "VLESS Links"
            echo
            cat "$SCRIPT_DIR/frp_info.config"
            echo
            ok "Copy any link above into v2rayNG / Shadowrocket."
            if [ "$RUN_MODE" = "quick_tunnel" ]; then
                warn "Quick Tunnel hostname changes on every restart."
                info "Check new links after restart: cat $SCRIPT_DIR/frp_info.config"
            fi
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
    done
    err "Timed out waiting for VLESS links."
    info "Check service: journalctl -u $SERVICE_NAME -e --no-pager -n 30"
    return 1
}

# ==================== Start server ====================
start_server(){
    rm -f "$SCRIPT_DIR/frp_info.config"
    if $IS_TERMUX; then
        prepare_python || return 1
        echo
        info "Starting server directly (Termux mode)..."
        info "Press Ctrl+C to stop the server."
        echo
        "$PYBIN_ABS" "$SCRIPT_DIR/main.py"
    else
        install_service || return 1
        wait_and_show_links
    fi
}

# ==================== Setup modes ====================
quick_mode(){
    header "1. Quick Tunnel (trycloudflare.com)"
    info "No domain required. Cloudflare gives a random hostname each run."
    load_existing
    UUID="$(ask_val "VLESS UUID" "${UUID:-$(uuid_gen)}")"
    ask_fake_sni
    WS_PATH="$(ask_val "WebSocket path" "${WS_PATH:-$DEF_WS_PATH}")"
    RUN_MODE="quick_tunnel"; PORT="$DEF_PORT_QUICK"
    # Save custom domain before overwriting (so named/direct can reuse it)
    [ -n "$WS_HOST" ] && [ "$WS_HOST" != "$DEF_WS_HOST" ] && CUSTOM_DOMAIN="$WS_HOST"
    WS_HOST="$DEF_WS_HOST"
    TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    ask_port_mode
    ask_subscription_sync || return 1
    ask_country
    write_env
    start_server
}

named_mode(){
    header "2. Named Cloudflare Tunnel + custom domain"
    info "Requires Cloudflare Zero Trust."
    echo -e " ${CYAN}In Zero Trust dashboard:${NC}"
    echo "   1. Networks -> Tunnels -> Create -> Cloudflared -> copy token."
    echo -e "   2. Public Hostname -> Service = ${GREEN}http://127.0.0.1:8888${NC}"
    echo
    read -r -p " Press Enter when ready..." _
    load_existing
    local def_host="${WS_HOST:-}"
    [ "$def_host" = "trycloudflare.com" ] || [ -z "$def_host" ] && def_host="${CUSTOM_DOMAIN:-}"
    WS_HOST="$(ask_val "Domain (e.g. vless.example.com)" "$def_host")"
    TUNNEL_TOKEN="$(ask_val "Tunnel connector token" "${TUNNEL_TOKEN:-}")"
    [ -z "$WS_HOST" ] || [ "$WS_HOST" = "trycloudflare.com" ] && { err "Domain required."; return 1; }
    [ -z "$TUNNEL_TOKEN" ] && { err "Token required."; return 1; }
    RUN_MODE="named_tunnel"; PORT="$DEF_PORT_NAMED"
    UUID="${UUID:-$(uuid_gen)}"
    ask_fake_sni
    WS_PATH="${WS_PATH:-$DEF_WS_PATH}"; TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    ask_port_mode
    ask_subscription_sync || return 1
    ask_country
    CUSTOM_DOMAIN="$WS_HOST"
    write_env
    start_server
}

direct_mode(){
    header "3. Direct Cloudflare proxied DNS -> VPS"
    info "No cloudflared. Cloudflare forwards to port 80."
    echo -e " ${CYAN}In Cloudflare DNS:${NC}"
    echo -e "   1. ${GREEN}vless.example.com -> A -> <VPS IP>${NC}, proxy ${GREEN}ON${NC} (orange cloud)"
    echo -e "   2. SSL/TLS -> ${GREEN}Flexible${NC}"
    echo -e "   3. Allow inbound TCP ${GREEN}80${NC} from Cloudflare IPs"
    echo
    read -r -p " Press Enter when ready..." _
    load_existing
    local def_host="${WS_HOST:-}"
    [ "$def_host" = "trycloudflare.com" ] || [ -z "$def_host" ] && def_host="${CUSTOM_DOMAIN:-}"
    WS_HOST="$(ask_val "Domain" "$def_host")"
    PORT="$(ask_val "Origin listen address:port" "$DEF_PORT_DIRECT")"
    [ -z "$WS_HOST" ] || [ "$WS_HOST" = "trycloudflare.com" ] && { err "Domain required."; return 1; }
    RUN_MODE="direct"; UUID="${UUID:-$(uuid_gen)}"
    ask_fake_sni
    WS_PATH="${WS_PATH:-$DEF_WS_PATH}"
    TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    ask_port_mode
    ask_subscription_sync || return 1
    ask_country
    CUSTOM_DOMAIN="$WS_HOST"
    write_env
    start_server
}

# ==================== Service manager ====================
service_manager(){
    if $IS_TERMUX; then
        warn "Service Manager is not available on Termux."
        info "On Termux, run a setup mode (1/2/3) to start the server directly."
        return 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd not available."; return 1
    fi
    while true; do
        header "Service Manager"
        local st
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            st="${GREEN}● Running${NC}"
        elif [ -f "$SERVICE_FILE" ]; then
            st="${YELLOW}● Stopped${NC}"
        else
            st="${RED}● Not installed${NC}"
        fi
        echo -e "  Service : ${CYAN}${SERVICE_NAME}${NC}    $st"
        [ -f .env ] && echo -e "  Mode    : ${CYAN}$(env_get RUN_MODE)${NC}  →  $(env_get WS_HOST)"
        echo
        echo " 1. Start"
        echo " 2. Stop"
        echo " 3. Restart"
        echo " 4. View logs (live)"
        echo " 5. Status"
        echo " 6. Show VLESS links"
        echo " 7. Reinstall service"
        echo " 8. Remove service"
        echo " 0. Back"
        read -r -p " Choice [0-8]: " c
        case "$c" in
            1) run_as_root systemctl start "$SERVICE_NAME" 2>/dev/null && ok "Started." || err "Failed." ;;
            2) run_as_root systemctl stop "$SERVICE_NAME" 2>/dev/null && ok "Stopped." || err "Not running." ;;
            3) run_as_root systemctl restart "$SERVICE_NAME" 2>/dev/null; sleep 2
               systemctl is-active --quiet "$SERVICE_NAME" && ok "Restarted." || err "Failed." ;;
            4) info "Ctrl+C to stop watching."; echo; journalctl -u "$SERVICE_NAME" -f --no-pager -n 50 ;;
            5) systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || info "Not installed." ;;
            6) if [ -f "$SCRIPT_DIR/frp_info.config" ] && [ -s "$SCRIPT_DIR/frp_info.config" ]; then
                   header "VLESS Links"; echo; cat "$SCRIPT_DIR/frp_info.config"; echo
               else info "No links yet. Start the service first."; fi ;;
            7) install_service ;;
            8) if [ -f "$SERVICE_FILE" ]; then
                   systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && run_as_root systemctl stop "$SERVICE_NAME"
                   run_as_root systemctl disable "$SERVICE_NAME" 2>/dev/null
                   run_as_root rm -f "$SERVICE_FILE"
                   run_as_root systemctl daemon-reload
                   ok "Service removed."
               else info "Not installed."; fi ;;
            0) return ;;
            *) err "Invalid choice" ;;
        esac
        pause_next
    done
}

# ==================== Uninstall ====================
uninstall_all(){
    header "Uninstall"
    info "Removes ONLY files this project downloaded/generated."
    echo -e " ${YELLOW}Will remove:${NC}"
    echo "   Binaries: xray, cloudflared, wgcf-cli"
    echo "   Generated: .env, config.json, wgcf.json, frp_info.*, config.yml"
    echo "   Folders: xray_bin, wgcf_bin, __pycache__, .venv"
    [ -f "$SERVICE_FILE" ] && echo -e "   Service: ${CYAN}$SERVICE_NAME${NC}"
    echo
    info "Source files are NEVER touched."
    echo
    ask_yes_no "Proceed?" "n" || { info "Canceled."; return; }
    # Service (skip on Termux)
    if ! $IS_TERMUX && [ -f "$SERVICE_FILE" ]; then
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && run_as_root systemctl stop "$SERVICE_NAME"
        run_as_root systemctl disable "$SERVICE_NAME" 2>/dev/null
        run_as_root rm -f "$SERVICE_FILE"
        run_as_root systemctl daemon-reload
        ok "Service removed."
    fi
    # Files
    local removed=0
    for f in xray xray.exe cloudflared cloudflared.exe wgcf-cli wgcf-cli.exe \
             .env config.json wgcf.json wgcf.xray.json frp_info.json frp_info.config \
             frpc.toml config.yml xray.zip cloudflared_temp.archive wgcf-cli.tar.zstd; do
        [ -e "$f" ] && rm -rf -- "$f" && { ok "Removed $f"; removed=1; }
    done
    for d in xray_bin wgcf_bin __pycache__ .venv; do
        [ -d "$d" ] && rm -rf -- "$d" && { ok "Removed $d/"; removed=1; }
    done
    [ "$removed" = "0" ] && info "Already clean." || ok "Done."
}

# ==================== Main menu ====================
termux_bootstrap
while true; do
    header "Xray VLESS-WS Server"
    $IS_TERMUX && echo -e "  ${GREEN}[Termux]${NC} Direct mode (no systemd)"
    # Show current status
    if ! $IS_TERMUX && command -v systemctl >/dev/null 2>&1 && [ -f "$SERVICE_FILE" ]; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo -e "  ${GREEN}● Service running${NC}  $(env_get RUN_MODE) → $(env_get WS_HOST)"
        else
            echo -e "  ${YELLOW}● Service stopped${NC}"
        fi
        echo
    fi
    echo " 1. Quick Tunnel (trycloudflare.com) - no domain needed"
    echo " 2. Named Cloudflare Tunnel + custom domain"
    echo " 3. Direct Cloudflare proxied DNS -> VPS"
    echo " 4. Service Manager (start/stop/logs/status)"
    echo " 5. Uninstall"
    echo " 0. Exit"
    read -r -p " Choice [0-5]: " MENU_CHOICE
    case "$MENU_CHOICE" in
        1) quick_mode ;;
        2) named_mode ;;
        3) direct_mode ;;
        4) service_manager ;;
        5) uninstall_all ;;
        0) exit 0 ;;
        *) err "Invalid choice" ;;
    esac
    pause_next
done