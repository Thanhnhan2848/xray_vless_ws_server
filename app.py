from flask import Flask
import threading
import os
import time
import re
import glob

app = Flask(__name__)

# Biến toàn cục để lưu link
tunnel_url = "Đang khởi tạo..."
vless_links = []

def run_main():
    global tunnel_url, vless_links
    try:
        os.environ["PORT"] = "127.0.0.1:8888"
        from main import main
        main()
    except Exception as e:
        print(f"[ERROR] main crashed: {e}")
        import traceback
        traceback.print_exc()

def watch_links():
    global tunnel_url, vless_links
    while True:
        # Tìm file chứa ra link
        for f in ["frp_info.config", "frp_info.json"]:
            if os.path.exists(f):
                try:
                    with open(f, "r", encoding="utf-8") as file:
                        content = file.read()
                        # Tìm trycloudflare.com
                        match = re.search(r'https://[a-z0-9-]+\.trycloudflare\.com', content)
                        if match:
                            tunnel_url = match.group(0)
                        # Tìm các link vless
                        links = re.findall(r'vless://[^\s]+', content)
                        if links:
                            vless_links = links
                except:
                    pass
        time.sleep(3)

@app.route("/")
def home():
    html = f"""
    <html>
    <head><title>Xray VLESS-WS</title>
    <style>
        body {{ font-family: Arial; background: #111; color: #eee; padding: 30px; }}
        .box {{ background: #1e1e1e; padding: 20px; border-radius: 10px; margin-bottom: 20px; }}
        a {{ color: #4fc3f7; }}
        pre {{ background: #000; padding: 15px; border-radius: 8px; overflow-x: auto; white-space: pre-wrap; }}
    </style>
    </head>
    <body>
        <h2>Xray VLESS-WS Server</h2>
        <div class="box">
            <b>Cloudflare Tunnel:</b><br>
            <a href="{tunnel_url}" target="_blank">{tunnel_url}</a>
        </div>
        <div class="box">
            <b>VLESS Links:</b>
            <pre>{chr(10).join(vless_links) if vless_links else "Đang chờ tạo link..."}</pre>
        </div>
        <p>Trang sẽ tự cập nhật khi có link mới (refresh lại sau 10-20 giây).</p>
    </body>
    </html>
    """
    return html

@app.route("/health")
def health():
    return "ok", 200

if __name__ == "__main__":
    render_port = int(os.environ.get("PORT", 10000))

    # Chạy main ở background
    t1 = threading.Thread(target=run_main, daemon=True)
    t1.start()

    # Theo dõi file link
    t2 = threading.Thread(target=watch_links, daemon=True)
    t2.start()

    time.sleep(4)
    print(f"[*] Flask listening on 0.0.0.0:{render_port}")
    app.run(host="0.0.0.0", port=render_port, debug=False)
