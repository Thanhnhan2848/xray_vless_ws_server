# Xray VLESS-WS Bypass Protocol: Anycast IP-Range Piggybacking (Proof of Concept)

[Xem phiên bản Tiếng Việt](README_vi.MD)

An automated, educational Python-based Proof of Concept (PoC) demonstrating how to leverage **Xray-Core** and ephemeral **Cloudflare Tunnels (`trycloudflare.com`)** to establish a secure VLESS-WebSocket proxy. This repository serves as a localized staging environment to validate Layer 7 deep-packet inspection (DPI) bypasses over zero-rated carrier networks (e.g., TikTok bundles) before committing to production infrastructure.

The idea of this project came from here: [The Anatomy of a Loophole: A Tech-Enthusiast's Journey into Layer-7 Decoupling](https://vincentng295.github.io/xray_vless_ws_server/IDEAS)

---

## Architecture: PoC vs. Production Infrastructure

Understanding the difference between this temporary testing suite and commercial architectures (such as **betltone.com** or **phuonglien4g.com**) is crucial:

### 1. This Proof of Concept (Testing Environment)
* **Infrastructure:** Utilizes an ephemeral Cloudflare Tunnel generated dynamically via `cloudflared tunnel --url`.
* **Limitation:** Cloudflare dynamically assigns a random subdomain (e.g., `*.trycloudflare.com`) on every script execution. It is excellent for free, fast, zero-configuration network logic validation, but **unsuitable for persistent production environments** due to unstable domains, potential rate limiting, and performance degradation under high multi-user stress.

### 2. Commercial / Production Infrastructure
To build a resilient, high-speed, and shareable system similar to major commercial providers, you must upgrade the components:
* **Dedicated Virtual Private Servers (VPS):** A Linux VPS (Ubuntu) equipped with a dedicated Public IP is leased. Xray runs natively, accepting direct high-throughput connections on standard network ports (e.g., 80, 443) with optimal peering latency.
* **Cloudflare for SaaS (Custom Hostnames):** Instead of ephemeral paths, a cheap vanity domain (e.g., `.com`, `.xyz`) is registered and linked to Cloudflare. By utilizing Cloudflare’s Enterprise/SaaS feature (**Custom Hostnames** combined with a **Fallback Origin** pointing to the VPS IP), administrators can permanently split network layers. This allows any arbitrary Cloudflare IP or whitelisted SNI to act as the entry gateway while securely directing under-the-hood packets to the core VPS.

---

## Technical Operating Principle

The core mechanism relies on IP/ASN-level whitelisting at the carrier, decoupled from what is actually inspected (or not inspected) at the TLS/HTTP layer:


```

[ Client Device ]
│
│ (1) DNS lookup of api24-normal-alisg.tiktokv.com
│     -> resolves to a Cloudflare Anycast IP that TikTok itself uses
▼
[ Telco DPI / Firewall ] ─── (Only checks: is destination IP/ASN in the
│                              whitelisted TikTok/Cloudflare range? -> yes -> forwards,
│                              unmetered, WITHOUT inspecting SNI or Host header)
│
│ (2) TLS ClientHello sent to that IP — SNI = your-random.trycloudflare.com
│     (NOT api24-normal-alisg.tiktokv.com — see main.py: `sni` in the vless
│     link is set to the tunnel host, the tiktok domain is only used to
│     resolve the destination IP)
▼
[ Cloudflare Edge Node ]
│
├─ terminates the TLS connection using the SNI (tunnel host) presented above.
├─ reads the inner HTTP Host Header: [your-random.trycloudflare.com].
└─ maps the host payload to your authenticated active ephemeral tunnel.
│
▼ (Forwards traffic down the local machine tunnel pipeline)
[ Local Xray Instance ] ───> Decrypts VLESS payload -> Resolves to Public Internet

```

1. **The DPI Bypass:** The client's V2ray app sets the `Address` field to a zero-rated carrier domain like `api24-normal-alisg.tiktokv.com`. This is only used to perform a **DNS lookup** so the client connects to whichever Cloudflare Anycast IP TikTok itself resolves to. The `SNI` sent in the actual TLS ClientHello is the Cloudflare tunnel host (e.g. `your-random.trycloudflare.com`), **not** the TikTok domain — the two are different fields on purpose.
2. **IP/ASN Whitelisting, Not Content Inspection:** The Mobile Network Operator (MNO) appears to whitelist traffic based on destination **IP address or ASN/prefix range** owned by Cloudflare (the same ranges TikTok's own traffic lands on), rather than inspecting the SNI or HTTP Host header at all. As long as the destination IP falls in the whitelisted range, the carrier passes the traffic unmetered — regardless of what SNI or Host is actually presented.
3. **Anycast Realignment:** Because TikTok routes API nodes natively through **Cloudflare Anycast Global Infrastructure**, the carrier's coarse IP-range whitelist happens to also cover every other Cloudflare tenant sharing that same anycast range, including ephemeral tunnels.
4. **The Layer 7 Redirect:** The edge node terminates TLS using the presented SNI, inspects the `Host Header` (`host=xxxx.trycloudflare.com`), and passes the proxy connection down to your executing environment.

Based on this, the carrier's DPI firewall must enforce the following to mitigate this exploit:

1. Move Beyond IP/ASN-Only Whitelisting: Whitelisting an entire CDN IP range as "TikTok traffic" is too coarse, since any tenant on that same shared anycast range (Cloudflare, CloudFront, etc.) benefits for free. The gateway must inspect at least the TLS SNI and/or HTTP Host header actually presented on the connection, not just the destination IP.
2. SNI/Host Verification Against Known TikTok Hostnames: The firewall should verify that the SNI presented in the TLS ClientHello (and the HTTP Host header, if visible) actually matches a known TikTok hostname — rather than trusting that "destination IP is in TikTok's CDN range" implies "this is TikTok traffic." A connection whose SNI is an unrelated hostname (e.g. `*.trycloudflare.com`) sharing the same IP range as TikTok should not automatically inherit the zero-rating.

---

## CDN Provider Interoperability

While this specific Proof of Concept utilizes Cloudflare infrastructure (`cloudflared` and Cloudflare Anycast IPs) for local ease of deployment, the underlying core mechanism - **Layer 7 Decoupling** - is provider-agnostic. 

The structural technique successfully extends to any multi-tenant Content Delivery Network (CDN) or Edge computing platform operating under similar routing architectures, including:
* **Amazon CloudFront (AWS):** By pairing a zero-rated hostname that resolves to AWS infrastructure (e.g., legacy TikTok endpoints, used purely for its DNS resolution / destination IP range) with an inner HTTP Host Header or custom origin distribution mapped to an AWS CloudFront configuration.
* **Akamai / Fastly / Gcore:** As long as the Mobile Network Operator (MNO) routes the whitelisted perimeter traffic to the respective provider's edge nodes, the edge infrastructure can process and forward encapsulated payloads down to separate targeted backends.

---

## Script Features

- **Dynamic Local Environment Orchestration:** Automated verification and generation of localized `.env` dependencies.
- **Auto-Architecture Binary Management:** Bundled standalone injectors (`download-xray.py`, `download-cloudflared.py`) detect client platform kernels to pull current runtime binaries natively.
- **Asynchronous Engine Logging:** Concurrent multi-threaded monitoring nodes tracking state logs for both proxy binaries.
- **Embedded Web UI Monitor:** Real-time log relay through an integrated background HTTP daemon (`logging_site.py`).
- **GitHub Actions Compatibility:** Optional daemon scripts allowing localized headless environments to stay active on upstream development runners.

---

## Installation & Usage

This open-source project is written in Python and automatically downloads the appropriate Xray and Cloudflared binaries for your operating system — no manual installation required.
Open a Terminal / Command Prompt and run the following commands in order:

```
# Clone the source code
git clone https://github.com/vincentng295/xray_vless_ws_server

# Move into the project directory
cd xray_vless_ws_server

# Install the required Python dependencies
pip install -r requirements.txt

# Start the server (subsequent runs only need this command)
python main.py
```

Result: once running, the system writes the v2ray configuration into the `frp_info.config` file. Just copy the link into v2rayNG/Shadowrocket to use it.

---

## Configuration (`.env`)

```ini
PORT=127.0.0.1:8888,0.0.0.0:443,0.0.0.0:80
XRAY_UUID=5ccad305-e243-4bb2-abf0-1e37189ce4e8
FAKE_SNI=api24-normal-alisg.tiktokv.com
WS_PATH=/tiktok4g
WS_HOST=trycloudflare.com
WEBHOOK_URL=

```

> **Naming Note:** `FAKE_SNI` is a legacy name kept for compatibility with existing configs; despite the name, this value is used as the connection **Address** for DNS resolution only — it is not sent as the TLS SNI. The actual SNI presented in the TLS handshake is the Cloudflare tunnel host (see `WS_HOST` and how `sni=` is built in `main.py`'s `print_vless_links`).

> **Important SNI Note:** Older configurations relied on `link.e.tiktok.com`. However, current routing records indicate `link.e.tiktok.com` resolves through **Amazon CloudFront (AWS)**. Because Cloudflare's tunneling mechanism cannot resolve or manipulate incoming host fields landing on rival AWS node layers, **`api24-normal-alisg.tiktokv.com`** is required for this Cloudflare-centric PoC to guarantee successful edge delivery.

---

## Acknowledgements

By reverse engineering commercial 4G bypass services like `betltone.com`, `phuonglien4g.com`, and similar community providers, the structural mechanics of this framework were successfully verified.
