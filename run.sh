#!/usr/bin/env bash
set -o pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$SCRIPT_DIR" || exit 1

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

# Prompt with a default value; empty input keeps the default.
ask_val(){ local prompt="$1" default="$2" ans; read -r -p "$prompt [$default]: " ans; [ -n "$ans" ] && echo "$ans" || echo "$default"; }

env_get(){ grep -E "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2-; }

uuid_gen(){
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null
    fi
}

# --- Python dependency bootstrap ---
detect_python(){
    # Prefer project .venv, then python3, then python (verify Python 3)
    if [ -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        echo "$SCRIPT_DIR/.venv/bin/python"
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo python3
        return
    fi
    if command -v python >/dev/null 2>&1; then
        if python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
            echo python
            return
        fi
    fi
    err "Python 3 not found. Install python3 on Debian/Ubuntu: sudo apt-get install python3 python3-venv python3-pip"
}

ensure_python_deps(){
    local py="$1"
    # Check if runtime deps are already importable
    if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
        return 0
    fi

    warn "Missing Python dependencies (python-dotenv, requests, zstandard). Installing..."

    # Determine if we are already in a venv
    if "$py" -c 'import sys; sys.exit(0 if hasattr(sys, "real_prefix") or (hasattr(sys, "base_prefix") and sys.base_prefix != sys.prefix) else 1)' 2>/dev/null; then
        "$py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -5
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed into virtualenv."
            return 0
        fi
        err "pip install failed. Check the output above."
        return 1
    fi

    # Try user install first (safest for system Python)
    if "$py" -m pip install --user -q python-dotenv requests zstandard 2>/dev/null; then
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed (--user)."
            return 0
        fi
    fi

    # PEP 668: --break-system-packages fallback
    if "$py" -m pip install --break-system-packages -q python-dotenv requests zstandard 2>/dev/null; then
        if "$py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
            ok "Dependencies installed (--break-system-packages)."
            return 0
        fi
    fi

    # Create project-local venv
    info "Creating project-local virtualenv (.venv/)..."
    if ! "$py" -m venv --help >/dev/null 2>&1; then
        err "The 'venv' module is not available."
        if [ "$(uname -s)" = "Linux" ] && (command -v apt-get >/dev/null 2>&1); then
            info "On Debian/Ubuntu, install it with: sudo apt-get install python3-venv python3-pip"
        fi
        return 1
    fi

    "$py" -m venv "$SCRIPT_DIR/.venv"
    if [ ! -x "$SCRIPT_DIR/.venv/bin/python" ]; then
        err "Failed to create .venv."
        return 1
    fi
    local venv_py="$SCRIPT_DIR/.venv/bin/python"
    "$venv_py" -m pip install -q python-dotenv requests zstandard 2>&1 | tail -5
    if "$venv_py" -c "import dotenv, requests, zstandard" 2>/dev/null; then
        ok "Dependencies installed into .venv/."
        PYBIN="$venv_py"
        return 0
    fi
    err "Failed to install dependencies into .venv. Check the output above."
    return 1
}

run_python(){
    PYBIN="$(detect_python)"
    [ -z "$PYBIN" ] && return 1
    ok "Using Python: $PYBIN"
    ensure_python_deps "$PYBIN" || return 1
    "$PYBIN" main.py
}

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
    UUID="$(env_get XRAY_UUID)"
    FAKE_SNI="$(env_get FAKE_SNI)"
    WS_PATH="$(env_get WS_PATH)"
    WS_HOST="$(env_get WS_HOST)"
    TUNNEL_TOKEN="$(env_get TUNNEL_TOKEN)"
    ENABLE_WARP="$(env_get ENABLE_WARP)"
    WEBHOOK_URL="$(env_get WEBHOOK_URL)"
    TRANSPORT="$(env_get TRANSPORT)"
}

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

    RUN_MODE="quick_tunnel"
    PORT="$DEF_PORT_QUICK"
    WS_HOST="$DEF_WS_HOST"
    TUNNEL_TOKEN=""
    TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env

    echo
    warn "Quick Tunnel hostname (*.trycloudflare.com) changes every restart."
    info "For a FIXED domain: use a Cloudflare Worker, or run.sh mode 2 (Named Tunnel) / mode 3 (Direct)."
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
        err "A custom domain is required for Named Tunnel mode."
        return 1
    fi
    if [ -z "$TUNNEL_TOKEN" ]; then
        err "A tunnel connector token is required for Named Tunnel mode."
        return 1
    fi

    RUN_MODE="named_tunnel"
    PORT="$DEF_PORT_NAMED"
    UUID="${UUID:-$(uuid_gen)}"
    FAKE_SNI="${FAKE_SNI:-$DEF_FAKE_SNI}"
    WS_PATH="${WS_PATH:-$DEF_WS_PATH}"
    TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env
    echo
    run_python
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
        err "A Cloudflare-proxied domain is required for Direct mode."
        return 1
    fi

    RUN_MODE="direct"
    UUID="${UUID:-$(uuid_gen)}"
    FAKE_SNI="${FAKE_SNI:-$DEF_FAKE_SNI}"
    WS_PATH="${WS_PATH:-$DEF_WS_PATH}"
    TUNNEL_TOKEN=""
    TRANSPORT="${TRANSPORT:-$DEF_TRANSPORT}"
    write_env
    echo
    run_python
}

# Stop only the processes launched from THIS repo folder, so the rest of the
# system is left untouched.
kill_runtime_processes(){
    local found=0
    for pid in /proc/[0-9]*; do
        [ -d "$pid" ] || continue
        local p="${pid##*/}"
        local cwd=""
        cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
        [ "$cwd" = "$SCRIPT_DIR" ] || continue
        local exe=""
        exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
        case "$exe" in
            "$SCRIPT_DIR/xray"|"$SCRIPT_DIR/cloudflared"|"$SCRIPT_DIR/wgcf-cli")
                kill "$p" 2>/dev/null && { found=1; ok "Stopped process $p ($(basename "$exe"))"; }
                ;;
        esac
        local cmdline=""
        cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
        case "$cmdline" in
            *main.py*)
                kill "$p" 2>/dev/null && { found=1; ok "Stopped process $p (python main.py)"; }
                ;;
        esac
    done
    if [ "$found" = "1" ]; then
        sleep 1
        for pid in /proc/[0-9]*; do
            [ -d "$pid" ] || continue
            local p="${pid##*/}"
            local cwd=""
            cwd="$(readlink "/proc/$p/cwd" 2>/dev/null || true)"
            [ "$cwd" = "$SCRIPT_DIR" ] || continue
            local exe=""
            exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
            case "$exe" in
                "$SCRIPT_DIR/xray"|"$SCRIPT_DIR/cloudflared"|"$SCRIPT_DIR/wgcf-cli") kill -9 "$p" 2>/dev/null ;;
            esac
            local cmdline=""
            cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
            case "$cmdline" in
                *main.py*) kill -9 "$p" 2>/dev/null ;;
            esac
        done
    fi
}

uninstall_mode(){
    header "4. Uninstall (remove everything this project installed)"
    info "Stops running processes and deletes ONLY files this project downloaded or generated."
    echo -e "${YELLOW}Will remove:${NC}"
    echo "  - Binaries: xray, cloudflared, wgcf-cli (and .exe variants)"
    echo "  - Generated: .env, config.json, wgcf.json, wgcf.xray.json, frp_info.json, frp_info.config, frpc.toml, config.yml"
    echo "  - Temp leftovers: xray.zip, cloudflared_temp.archive, wgcf-cli.tar.zstd"
    echo "  - Folders: xray_bin, wgcf_bin, __pycache__, .venv"
    echo
    info "Source files (main.py, run.sh, docs, .git, requirements.txt) are NEVER touched."
    echo
    if ! ask_yes_no "Proceed with uninstall?" "n"; then
        info "Canceled."
        return 0
    fi

    kill_runtime_processes

    local removed=0
    local item
    for item in xray xray.exe cloudflared cloudflared.exe wgcf-cli wgcf-cli.exe \
                .env config.json wgcf.json wgcf.xray.json frp_info.json frp_info.config \
                frpc.toml config.yml xray.zip cloudflared_temp.archive wgcf-cli.tar.zstd; do
        if [ -e "$item" ]; then
            rm -rf -- "$item" && { ok "Removed $item"; removed=1; }
        fi
    done
    for item in xray_bin wgcf_bin __pycache__ .venv; do
        if [ -d "$item" ]; then
            rm -rf -- "$item" && { ok "Removed $item/"; removed=1; }
        fi
    done

    if [ "$removed" = "0" ]; then
        info "Nothing to remove - already clean."
    else
        ok "Uninstall complete. The rest of the system was left untouched."
    fi
}

while true; do
    header "Xray VLESS-WS Server"
    echo "1. Quick Tunnel (trycloudflare.com) - fastest, no domain"
    echo "2. Named Cloudflare Tunnel + custom domain"
    echo "3. Direct Cloudflare proxied DNS -> VPS"
    echo "4. Uninstall (remove downloaded binaries + generated files)"
    echo "5. Exit"
    read -r -p "Choice [1-5]: " MENU_CHOICE
    case "$MENU_CHOICE" in
        1) quick_mode ;;
        2) named_mode ;;
        3) direct_mode ;;
        4) uninstall_mode ;;
        5) exit 0 ;;
        *) err "Invalid choice" ;;
    esac
    echo
    read -r -p "Press Enter to return to menu..." _
done