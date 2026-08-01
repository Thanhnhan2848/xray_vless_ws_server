# Giao Thức Bypass Xray VLESS-WS: Lợi Dụng Dải IP Anycast Dùng Chung (Proof of Concept)

Một dự án Proof of Concept (PoC) tự động bằng Python phục vụ cho mục đích giáo dục, trình diễn cách tận dụng **Xray-Core** và các **Cloudflare Tunnel** tạm thời (`trycloudflare.com`) để thiết lập một proxy VLESS-WebSocket an toàn. Kho lưu trữ này hoạt động như một môi trường thử nghiệm cục bộ nhằm xác thực khả năng vượt tường lửa kiểm tra gói tin sâu Layer 7 trên các mạng di động được miễn phí data (ví dụ: các gói cước TikTok) trước khi triển khai lên hạ tầng production thực tế.

Ý tưởng của dự án này được khơi nguồn từ đây: [Giải Mã Lỗ Hổng: Hành Trình Khám Phá Kỹ Thuật Tách Lớp Layer-7](https://vincentng295.github.io/xray_vless_ws_server/IDEAS_vi)

---

## Kiến Trúc: Bản Thử Nghiệm (PoC) vs. Hạ Tầng Thực Tế (Production)

Việc hiểu rõ sự khác biệt giữa bộ suite thử nghiệm tạm thời này và các kiến trúc thương mại thực tế (**phuonglien4g.com**) là vô cùng quan trọng:

### 1. Bản Thử Nghiệm Này (Môi Trường Thử Nghiệm)
* **Hạ Tầng:** Sử dụng một Cloudflare Tunnel tạm thời được tạo động thông qua lệnh `cloudflared tunnel --url`.
* **Hạn Chế:** Cloudflare sẽ cấp ngẫu nhiên một subdomain (e.g., `*.trycloudflare.com`) sau mỗi lần thực thi script. Cơ chế này rất tuyệt để xác thực logic mạng nhanh chóng, miễn phí và không cần cấu hình phức tạp, nhưng **không phù hợp cho môi trường production lâu dài** do tên miền không cố định, giới hạn tần suất gọi API (rate limiting), và suy giảm hiệu năng khi có nhiều người dùng cùng lúc.

### 2. Hạ Tầng Thương Mại / Production Thực Tế
Để xây dựng một hệ thống ổn định, tốc độ cao và có thể chia sẻ cho nhiều người giống như các nhà cung cấp thương mại lớn, bạn cần nâng cấp các thành phần sau:
* **Máy Chủ Ảo Riêng (VPS) Dedicated:** Thuê một VPS Linux (Ubuntu) có IP Công khai cố định. Xray sẽ chạy native trực tiếp trên VPS, tiếp nhận các kết nối băng thông cao trên các cổng mạng tiêu chuẩn (ví dụ: 80, 443) nhằm tối ưu độ trễ (peering latency).
* **Cloudflare for SaaS (Custom Hostnames):** Thay vì sử dụng các đường dẫn tạm thời, một tên miền giá rẻ (ví dụ: `.com`, `.xyz`) sẽ được đăng ký và trỏ về Cloudflare. Bằng cách sử dụng tính năng Enterprise/SaaS của Cloudflare (**Custom Hostnames** kết hợp với một **Fallback Origin** trỏ về IP của VPS), quản trị viên có thể tách biệt vĩnh viễn các lớp mạng. Điều này cho phép bất kỳ IP Cloudflare hoặc SNI nào nằm trong danh sách trắng đều có thể đóng vai trò là cổng vào (entry gateway), trong khi vẫn điều hướng các gói tin ngầm một cách an toàn về phía VPS cốt lõi.

---

## Nguyên Lý Vận Hành Kỹ Thuật

Cơ chế cốt lõi dựa trên việc nhà mạng whitelist theo dải IP/ASN, tách biệt hoàn toàn với việc SNI/Host thực tế có được kiểm tra hay không:


```

[ Thiết Bị Client ]
│
│ (1) Phân giải DNS domain api24-normal-alisg.tiktokv.com
│     -> ra một IP Cloudflare Anycast mà chính TikTok cũng đang dùng
▼
[ Tường Lửa / DPI Nhà Mạng ] ─── (Chỉ kiểm tra: IP/ASN đích có nằm trong dải
│                                  whitelist TikTok/Cloudflare không? -> có -> cho qua
│                                  miễn phí, KHÔNG kiểm tra SNI hay Host Header)
│
│ (2) Gói TLS ClientHello gửi tới IP đó — SNI = your-random.trycloudflare.com
│     (KHÔNG PHẢI api24-normal-alisg.tiktokv.com — xem main.py: trường `sni`
│     trong link vless được set bằng tunnel host, domain tiktok chỉ dùng để
│     phân giải ra IP đích)
▼
[ Edge Node Cloudflare ]
│
├─ Kết thúc kết nối TLS dựa trên SNI (tunnel host) vừa nêu trên.
├─ Đọc HTTP Host Header ẩn bên trong: [your-random.trycloudflare.com].
└─ Ánh xạ payload của host vào đường hầm (tunnel) tạm thời đang hoạt động.
│
▼ (Chuyển tiếp lưu lượng xuống đường hầm máy cục bộ)
[ Tiến Trình Xray Cục Bộ ] ───> Giải mã payload VLESS -> Phân giải ra Internet công cộng

```

1. **Cơ Chế Vượt DPI:** Ứng dụng V2ray phía client set trường `Address` thành một tên miền được nhà mạng miễn phí (zero-rated), chẳng hạn `api24-normal-alisg.tiktokv.com`. Domain này **chỉ dùng để tra cứu DNS** để client kết nối tới đúng IP Cloudflare Anycast mà TikTok cũng đang phân giải ra. Trường `SNI` thực sự được gửi trong TLS ClientHello lại là tunnel host Cloudflare (ví dụ `your-random.trycloudflare.com`), **không phải** domain TikTok — đây là hai trường khác nhau, được thiết kế có chủ đích như vậy.
2. **Whitelist Theo IP/ASN, Không Phải Kiểm Tra Nội Dung:** Nhà mạng di động (MNO) dường như đang whitelist dựa trên **địa chỉ IP đích hoặc dải ASN/prefix** thuộc Cloudflare (cùng dải mà lưu lượng TikTok thật sự cũng đi qua), thay vì kiểm tra SNI hay HTTP Host header. Miễn IP đích nằm trong dải được whitelist, nhà mạng sẽ cho qua miễn phí — bất kể SNI hay Host thực sự là gì.
3. **Trùng Dải Anycast:** Vì các node API của TikTok vốn định tuyến native qua **Hạ tầng Toàn cầu Cloudflare Anycast**, dải IP mà nhà mạng whitelist (thô, theo range) vô tình bao trùm luôn mọi tenant khác dùng chung dải anycast đó, kể cả các tunnel tạm thời.
4. **Điều Hướng Lớp Layer 7 (Layer 7 Redirect):** Edge node kết thúc TLS dựa trên SNI được gửi tới, kiểm tra trường `Host Header` ẩn bên trong (`host=xxxx.trycloudflare.com`), và chuyển tiếp kết nối proxy xuống môi trường đang thực thi của bạn.

Dựa trên phân tích trên, hệ thống tường lửa/DPI của nhà mạng cần thực thi các quy tắc sau để vá lỗ hổng này:

1. Không Chỉ Whitelist Theo IP/ASN: Whitelist cả một dải IP CDN là "lưu lượng TikTok" là quá thô, vì bất kỳ tenant nào khác dùng chung dải anycast đó (Cloudflare, CloudFront, v.v.) cũng được hưởng lợi miễn phí theo. Tường lửa cần kiểm tra ít nhất SNI trong TLS ClientHello và/hoặc HTTP Host header thực sự được gửi trên kết nối, chứ không chỉ dựa vào IP đích.
2. Đối Chiếu SNI/Host Với Danh Sách Hostname TikTok Đã Biết: Tường lửa nên xác thực rằng SNI trong TLS ClientHello (và HTTP Host header, nếu quan sát được) thực sự khớp với một hostname TikTok đã biết — thay vì mặc định rằng "IP đích nằm trong dải CDN của TikTok" nghĩa là "đây là lưu lượng TikTok". Một kết nối có SNI là hostname không liên quan (ví dụ `*.trycloudflare.com`) nhưng dùng chung dải IP với TikTok thì không nên tự động được hưởng chính sách miễn phí data.


---

## Khả Năng Tương Thích Với Các Nhà Cung Cấp CDN Khác

Mặc dù bản Proof of Concept cụ thể này sử dụng hạ tầng của Cloudflare (`cloudflared` và dải IP Cloudflare Anycast) để đơn giản hóa việc triển khai cục bộ, nhưng cơ chế cốt lõi - **Tách lớp Layer 7 (Layer 7 Decoupling)** - hoàn toàn không bị giới hạn bởi một nhà cung cấp duy nhất.

Về mặt kiến trúc, kỹ thuật này hoạt động tương tự trên bất kỳ mạng phân phối nội dung đa phân nhánh (Multi-tenant CDN) hoặc nền tảng Edge Computing nào có chung cấu trúc định tuyến, bao gồm:
* **Amazon CloudFront (AWS):** Bằng cách kết hợp một hostname được miễn phí data phân giải về hạ tầng của AWS (chỉ dùng cho mục đích phân giải DNS / xác định dải IP đích) với một trường HTTP Host Header hoặc phân phối cấu hình (Distribution Origin) bên trong trỏ về tài nguyên AWS tương ứng.
* **Akamai / Fastly / Gcore:** Chỉ cần Tường lửa nhà mạng (MNO) định tuyến lưu lượng lớp vỏ ngoài đến đúng các Edge Node của nhà cung cấp đó, hạ tầng biên hoàn toàn có thể bóc tách lớp payload và chuyển tiếp dữ liệu ngầm về các backend độc lập.

---

## Các Tính Năng Của Script

- **Điều Phối Môi Trường Cục Bộ Tự Động:** Tự động xác thực và khởi tạo các phụ thuộc tệp `.env` cục bộ.
- **Quản Lý Binary Theo Kiến Trúc Tự Động:** Các script injector độc lập đi kèm (`download-xray.py`, `download-cloudflared.py`) tự động nhận diện kernel nền tảng của client để tải về các file thực thi chuẩn xác nhất.
- **Ghi Log Công Cụ Bất Đồng Bộ:** Giám sát đa luồng đồng thời theo thời gian thực luồng log trạng thái của cả hai file thực thi proxy.
- **Tích Hợp Giao Diện Giám Sát Web (Web UI Monitor):** Truyền tiếp log theo thời gian thực thông qua một background HTTP daemon được tích hợp sẵn (`logging_site.py`).
- **Tương Thích GitHub Actions:** Hỗ trợ các script daemon tùy chọn cho phép các môi trường chạy headless cục bộ duy trì trạng thái hoạt động trên các runner phát triển upstream.

---

## Cài Đặt & Sử Dụng

Dự án mã nguồn mở này đã được viết tối ưu bằng Python, tự động tải phiên bản Xray và Cloudflared phù hợp với hệ điều hành của bạn mà không cần cài đặt thủ công.
Mở Terminal / Command Prompt lên và chạy tuần tự các lệnh sau:

```
# Tải source code từ kho lưu trữ về máy
git clone https://github.com/vincentng295/xray_vless_ws_server

# Di chuyển vào thư mục dự án
cd xray_vless_ws_server

# Cài đặt các thư viện Python cần thiết 
pip install -r requirements.txt

# Bật server lên (Lần sau chỉ cần chạy lệnh này)
python main.py
```

Kết quả: Sau khi chạy, hệ thống sẽ ghi cấu hình v2ray vào trong file `frp_info.config`. Bạn chỉ cần sao chép link nhập vào ứng dụng v2rayNG/Shadowrocket để sử dụng.

---

## Cấu Hình Tệp Môi Trường (`.env`)

```ini
PORT=127.0.0.1:8888,0.0.0.0:443,0.0.0.0:80
XRAY_UUID=5ccad305-e243-4bb2-abf0-1e37189ce4e8
FAKE_SNI=api24-normal-alisg.tiktokv.com
WS_PATH=/tiktok4g
WS_HOST=trycloudflare.com
WEBHOOK_URL=

```

> **Lưu ý về tên biến:** `FAKE_SNI` là tên biến cũ được giữ lại để tương thích ngược; mặc dù tên gọi như vậy, giá trị này chỉ được dùng làm trường **Address** để phân giải DNS — nó không được gửi đi như SNI trong TLS. SNI thực sự trong bắt tay TLS là tunnel host của Cloudflare (xem `WS_HOST` và cách trường `sni=` được dựng trong hàm `print_vless_links` của `main.py`).

> **Lưu ý Quan Trọng Về SNI:** Các cấu hình cũ thường dựa vào `link.e.tiktok.com`. Tuy nhiên, các bản ghi định tuyến hiện tại chỉ ra rằng `link.e.tiktok.com` được phân giải qua **Amazon CloudFront (AWS)**. Vì cơ chế tunnel của Cloudflare không thể phân giải hoặc can thiệp vào các trường host được gửi đến các tầng node đối thủ của AWS, **`api24-normal-alisg.tiktokv.com`** là bắt buộc đối với bản PoC tập trung vào Cloudflare này để đảm bảo truyền tải dữ liệu thành công tại edge.

---

## Lời Cảm Ơn

Bằng cách dịch ngược các dịch vụ bypass 4G thương mại trong cộng đồng, cơ chế cấu trúc của framework này đã được xác thực thành công.
