# Xray VLESS-WS Server (Proof of Concept)

[Xem phiên bản Tiếng Việt](https://vincentng295.github.io/xray_vless_ws_server/README_vi)

An educational Python proof-of-concept that runs an **Xray-Core** VLESS-WebSocket server and exposes it through **Cloudflare** in three ways. Use the bundled `run.sh` to pick a mode interactively; it writes a valid `.env` and starts the server.

## Quick start

### Linux / VPS / WSL
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/takeshi7502/xray_vless_ws_server/main/install.sh)
```

### Termux (Android)
```bash
pkg install curl -y && bash <(curl -fsSL https://raw.githubusercontent.com/takeshi7502/xray_vless_ws_server/main/install.sh)
```

The install script clones the repo to `~/vless` and launches the interactive menu.

Pick a mode:

1. **Quick Tunnel** — fastest, no domain. Cloudflare assigns a random `*.trycloudflare.com` hostname on every start.
2. **Named Tunnel** — fixed custom domain via a Cloudflare Named Tunnel (connector token).
3. **Direct** — fixed custom domain via Cloudflare proxied DNS pointing straight to your VPS (no `cloudflared`).

## Mode comparison

| | Quick Tunnel | Named Tunnel | Direct |
|---|---|---|---|
| Requires a domain | No | Yes (Zero Trust) | Yes (Cloudflare DNS) |
| Runs `cloudflared` | Yes | Yes | No |
| Hostname | Random each start | Fixed | Fixed |
| Origin port for Xray | loopback `8888` | loopback `8888` | public `80` |
| Client link port | TLS `443` | TLS `443` | TLS `443` |
| Upstream to Cloudflare | outbound | outbound | inbound (proxied DNS) |

## 1. Quick Tunnel (`quick_tunnel`)

Default mode. The script downloads `cloudflared` if needed, starts a temporary tunnel pointing at `http://127.0.0.1:8888`, parses the random `*.trycloudflare.com` hostname, and prints VLESS links.

- The hostname changes on every restart (no uptime guarantee).
- For a fixed hostname, use a Cloudflare Worker in front of the tunnel, or use mode 2 / mode 3.

## 2. Named Tunnel (`named_tunnel`)

Requires a domain added to Cloudflare Zero Trust.

In the Cloudflare Zero Trust dashboard:

1. **Networks → Tunnels → Create a tunnel → Cloudflared**, then copy the connector token.
2. Add a **Public Hostname**: hostname = your domain, service = `http://127.0.0.1:8888`.

The tunnel only connects **outbound**, so you do **not** need an A/AAAA record pointing at this machine and do **not** need to open inbound Xray ports.

## 3. Direct (`direct`)

No `cloudflared` is downloaded or run. Cloudflare's edge terminates TLS and forwards plaintext HTTP/WebSocket to your VPS origin.

1. In Cloudflare DNS: add `vless.example.com → A → <your VPS IP>`, proxy **ON** (orange cloud).
2. Cloudflare **SSL/TLS → encryption mode = Flexible**.
3. Origin Xray listens on `0.0.0.0:80` (plaintext WebSocket).

> [!WARNING]
> In Direct mode the origin leg (Cloudflare → VPS) is plaintext HTTP/WebSocket. For stronger security use a reverse proxy with a certificate and switch SSL/TLS to Full/Full (strict).

> [!TIP]
> Restrict inbound TCP `80` to Cloudflare IP ranges only, so the origin cannot be reached directly.

## Configuration (`.env`)

`run.sh` writes this file for you. See `.env.example` for all three mode presets.

```ini
RUN_MODE=quick_tunnel
PORT=127.0.0.1:8888
XRAY_UUID=
FAKE_SNI=api24-normal-alisg.tiktokv.com#Free Tiktok,vnpt.theworkpc.com#Free Vina Ko Nen
WS_PATH=/tiktok4g
WS_HOST=trycloudflare.com
TRANSPORT=websocket
ENABLE_WARP=false
WEBHOOK_URL=
TUNNEL_TOKEN=
COUNTRY_CODE=
PORT_MODE=both
```

| Key | Meaning |
|---|---|
| `RUN_MODE` | `quick_tunnel`, `named_tunnel`, or `direct` |
| `PORT` | Comma-separated Xray inbound listen addresses/ports |
| `XRAY_UUID` | VLESS client UUID (auto-generated if blank) |
| `FAKE_SNI` | Comma-separated list of domains with optional `#remark` for link naming |
| `WS_PATH` | WebSocket path |
| `WS_HOST` | Custom domain for Named/Direct, or `trycloudflare.com` for Quick |
| `TRANSPORT` | `websocket` (currently the only supported value) |
| `ENABLE_WARP` | `true` to route outbound through Cloudflare WARP |
| `WEBHOOK_URL` | Optional endpoint to receive connection payloads |
| `TUNNEL_TOKEN` | Connector token for Named Tunnel mode only |
| `COUNTRY_CODE` | Optional 2-letter country code (e.g. `VN`, `JP`) for flag prefix in link names |
| `PORT_MODE` | Link output filter: `both` (default), `80` only, or `443` only |

## Running on a VPS

Use the one-liner install above, or run `bash run.sh` for the guided interactive menu. The origin never terminates TLS itself; Cloudflare handles TLS on port 443.

## Disclaimer

This is an educational proof of concept. It does not guarantee zero-rating, unmetered traffic, or bypass of any carrier's DPI. Use responsibly and comply with your network provider's terms and applicable law.