# Xray VLESS-WS Server (Proof of Concept)

[Xem bản tiếng Anh](https://vincentng295.github.io/xray_vless_ws_server/README)

Một proof-of-concept Python mang tính giáo dục, chạy máy chủ **Xray-Core** VLESS-WebSocket và mở ra internet qua **Cloudflare** theo ba cách. Dùng `run.sh` kèm theo để chọn chế độ một cách tương tác; script sẽ ghi file `.env` hợp lệ và khởi động máy chủ.

## Bắt đầu nhanh

### Linux / VPS / WSL
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/takeshi7502/xray_vless_ws_server/main/install.sh)
```

### Termux (Android)
```bash
pkg install curl -y && bash <(curl -fsSL https://raw.githubusercontent.com/takeshi7502/xray_vless_ws_server/main/install.sh)
```

Script sẽ tự clone repo vào `~/vless` và mở menu cài đặt.

Muốn gộp link của nhiều VPS vào một subscription? Xem [hướng dẫn Multi-VPS](MULTI_VPS_SUBSCRIPTION.md).

Chọn một chế độ:

1. **Quick Tunnel** — nhanh nhất, không cần domain. Cloudflare cấp một hostname `*.trycloudflare.com` ngẫu nhiên mỗi lần chạy.
2. **Named Tunnel** — domain cố định thông qua Cloudflare Named Tunnel (connector token).
3. **Direct** — domain cố định thông qua Cloudflare proxied DNS trỏ thẳng tới VPS (không dùng `cloudflared`).

## So sánh các chế độ

| | Quick Tunnel | Named Tunnel | Direct |
|---|---|---|---|
| Cần domain | Không | Có (Zero Trust) | Có (Cloudflare DNS) |
| Chạy `cloudflared` | Có | Có | Không |
| Hostname | Ngẫu nhiên mỗi lần chạy | Cố định | Cố định |
| Cổng origin cho Xray | loopback `8888` | loopback `8888` | public `80` |
| Cổng link client | TLS `443` | TLS `443` | TLS `443` |
| Đường lên Cloudflare | outbound | outbound | inbound (proxied DNS) |

## 1. Quick Tunnel (`quick_tunnel`)

Chế độ mặc định. Script tự tải `cloudflared` nếu thiếu, khởi động tunnel tạm trỏ tới `http://127.0.0.1:8888`, đọc hostname ngẫu nhiên `*.trycloudflare.com` và in link VLESS.

- Hostname thay đổi mỗi lần khởi động lại (không có đảm bảo uptime).
- Muốn hostname cố định: dùng Cloudflare Worker đặt trước tunnel, hoặc dùng chế độ 2 / chế độ 3.

## 2. Named Tunnel (`named_tunnel`)

Cần một domain đã thêm vào Cloudflare Zero Trust.

Trong dashboard Cloudflare Zero Trust:

1. **Networks → Tunnels → Create a tunnel → Cloudflared**, rồi copy connector token.
2. Thêm **Public Hostname**: hostname = domain của bạn, service = `http://127.0.0.1:8888`.

Tunnel chỉ kết nối **ra ngoài** (outbound), nên bạn **không** cần bản ghi A/AAAA trỏ về máy này và **không** cần mở cổng inbound cho Xray.

## 3. Direct (`direct`)

Không tải hay chạy `cloudflared`. Cloudflare edge kết thúc TLS và chuyển tiếp HTTP/WebSocket plaintext tới origin VPS.

1. Trong Cloudflare DNS: thêm `vless.example.com → A → <IP VPS>`, bật proxy (đám mây cam).
2. Cloudflare **SSL/TLS → encryption mode = Flexible**.
3. Origin Xray lắng nghe `0.0.0.0:80` (WebSocket plaintext).

> [!WARNING]
> Ở chế độ Direct, đoạn origin (Cloudflare → VPS) là HTTP/WebSocket plaintext. Muốn bảo mật hơn hãy dùng reverse proxy có chứng chỉ và đổi SSL/TLS sang Full/Full (strict).

> [!TIP]
> Chỉ mở inbound TCP `80` cho các dải IP của Cloudflare để origin không bị truy cập trực tiếp.

## Cấu hình (`.env`)

`run.sh` sẽ ghi file này cho bạn. Xem `.env.example` để có mẫu cho cả ba chế độ.

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

| Khóa | Ý nghĩa |
|---|---|
| `RUN_MODE` | `quick_tunnel`, `named_tunnel`, hoặc `direct` |
| `PORT` | Danh sách địa chỉ/cổng inbound của Xray, cách nhau bằng dấu phẩy |
| `XRAY_UUID` | UUID xác thực client VLESS (tự sinh nếu để trống) |
| `FAKE_SNI` | Danh sách domain kèm `#tên` tùy chọn để đặt tên link |
| `WS_PATH` | Đường dẫn WebSocket |
| `WS_HOST` | Domain riêng cho Named/Direct, hoặc `trycloudflare.com` cho Quick |
| `TRANSPORT` | `websocket` (hiện là giá trị duy nhất được hỗ trợ) |
| `ENABLE_WARP` | `true` để định tuyến outbound qua Cloudflare WARP |
| `WEBHOOK_URL` | Endpoint tùy chọn để nhận payload kết nối |
| `TUNNEL_TOKEN` | Connector token chỉ dùng cho chế độ Named Tunnel |
| `COUNTRY_CODE` | Mã quốc gia 2 ký tự (VD: `VN`, `JP`) để thêm cờ vào tên link |
| `PORT_MODE` | Lọc link xuất ra: `both` (mặc định), chỉ `80`, hoặc chỉ `443` |

## Chạy trên VPS

Dùng lệnh cài một dòng ở trên, hoặc chạy `bash run.sh` cho menu tương tác. Origin không tự kết thúc TLS; Cloudflare xử lý TLS trên cổng 443.

## Lưu ý

Đây là proof-of-concept mang tính giáo dục. Nó không đảm bảo zero-rating, miễn phí dung lượng, hay vượt DPI của bất kỳ nhà mạng nào. Hãy dùng có trách nhiệm và tuân thủ điều khoản của nhà mạng cũng như pháp luật hiện hành.