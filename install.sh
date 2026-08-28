#!/usr/bin/env bash
set -e

REPO="https://github.com/takeshi7502/xray_vless_ws_server.git"
INSTALL_DIR="${HOME}/vless"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${GREEN}  Xray VLESS-WS Server - Quick Install${NC}"
echo -e "${CYAN}====================================================${NC}"
echo

# Install git if needed
if ! command -v git >/dev/null 2>&1; then
    echo -e " ${YELLOW}[!]${NC} git not found. Installing..."
    if [ -n "${TERMUX_VERSION:-}" ] || [[ "${PREFIX:-}" == *"com.termux"* ]]; then
        pkg install git -y 2>&1 | tail -3
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y -qq git
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y git
    else
        echo -e " ${RED}[ERR]${NC} Cannot install git. Please install manually."
        exit 1
    fi
fi

# Clone or update
if [ -d "$INSTALL_DIR/.git" ]; then
    echo -e " ${GREEN}[OK]${NC} Found existing install at $INSTALL_DIR"
    cd "$INSTALL_DIR"
    git pull --ff-only 2>/dev/null || true
else
    echo -e " ${GREEN}[*]${NC} Cloning to $INSTALL_DIR..."
    git clone "$REPO" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

echo
exec bash run.sh