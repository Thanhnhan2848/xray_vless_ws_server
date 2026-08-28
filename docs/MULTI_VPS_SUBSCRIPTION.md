# One Subscription for Multiple VPS Servers

This project can push every node's current VLESS links into one central **subscription hub**. The hub combines them into one `merged.config` file, which nginx exposes through your existing subscription domain.

## Architecture

```text
VPS Japan ──POST /sync──┐
VPS Singapore ─POST /sync┼──> Central VPS: subscription_hub.py
Termux node ──POST /sync─┘          │
                                    └── merged.config ── nginx ──> one subscription URL
```

Each node sends its latest list when its tunnel is ready. This is important for Quick Tunnel because its `trycloudflare.com` hostname changes after a restart.

## 1. Set up the central VPS

Run these commands in the project directory on the VPS that already owns your subscription domain. Replace `CHANGE_THIS_TO_A_LONG_RANDOM_SECRET` with a private token of **at least 24 characters**.

```bash
cd ~/vless
python3 subscription_hub.py \
  --token 'CHANGE_THIS_TO_A_LONG_RANDOM_SECRET' \
  --output ~/vless/merged.config \
  --bind 127.0.0.1 --port 9998
```

Keep it running for a first test. For permanent use, create a systemd service:

```bash
sudo tee /etc/systemd/system/vless-subscription-hub.service >/dev/null <<'UNIT'
[Unit]
Description=VLESS multi-VPS subscription hub
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/root/vless
ExecStart=/usr/bin/python3 /root/vless/subscription_hub.py --token 'CHANGE_THIS_TO_A_LONG_RANDOM_SECRET' --output /root/vless/merged.config --bind 127.0.0.1 --port 9998
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now vless-subscription-hub
```

> [!IMPORTANT]
> If your repo is not `/root/vless`, replace `/root/vless` in the service with your actual project path.

## 2. Publish the hub safely through nginx

The hub listens only on `127.0.0.1:9998`; nginx gives it HTTPS on your existing subscription domain. Add this `location` block to the existing nginx `server` for the subscription domain:

```nginx
location = /sync {
    proxy_pass http://127.0.0.1:9998/sync;
    proxy_set_header Content-Type application/json;
    client_max_body_size 512k;
}

location = /frp_info.config {
    alias /root/vless/merged.config;
    default_type text/plain;
}
```

Then test and reload nginx:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Your one public subscription URL stays unchanged:

```text
https://vless5gtiktok.takeshi.dev/frp_info.config
```

> [!CAUTION]
> `/sync` is write-protected by the shared Bearer token, but keep the token private. Do not put it in screenshots, public issues, or a public `.env` file.

## 3. Configure every node VPS

On every VPS (or Termux node) that should contribute links, run `bash run.sh`, choose any mode, then fill the new optional prompts:

```text
Hub sync URL: https://vless5gtiktok.takeshi.dev/sync
Node ID: vps-jp-1
Hub sync token: CHANGE_THIS_TO_A_LONG_RANDOM_SECRET
```

- Use a **different Node ID** per VPS: `vps-jp-1`, `vps-sg-1`, `termux-vn-1`.
- Use the **same hub token** for every node.
- Press Enter at Hub sync URL to keep a node standalone.

When a node comes online, it prints:

```text
[OK] Subscription synced: node vps-jp-1
```

The hub overwrites only that node's last submitted links, then regenerates `merged.config` without duplicates.

## Verify

Central VPS:

```bash
sudo systemctl status vless-subscription-hub --no-pager
curl -fsS http://127.0.0.1:9998/health
wc -l ~/vless/merged.config
curl -fsSL https://vless5gtiktok.takeshi.dev/frp_info.config
```

Node VPS: rerun its mode or restart `xray-vless`; check its log for `Subscription synced`.

## Remove a node

Stop the node, then on the central VPS remove only its saved data file and restart/re-sync another node:

```bash
rm ~/vless/subscription_nodes/vps-jp-1.config
```

The hub rebuilds the merged file on the next successful sync. If you need an immediate rebuild, restart the hub after removing the file.