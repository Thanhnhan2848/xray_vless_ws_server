from flask import Flask, Response
import threading
import os
import time
import re

app = Flask(__name__)

tunnel_url = "Đang khởi tạo..."
vless_links = []
config_content = ""

def run_main():
    global tunnel_url, vless_links, config_content
    try:
        os.environ["PORT"] = "127.0.0.1:8888"
        from main import main
        main()
    except Exception as e:
        print(f"[ERROR] main crashed: {e}")
        import traceback
        traceback.print_exc()

def watch_links():
    global tunnel_url, vless_links, config_content
    while True:
        if os.path.exists("frp_info.config"):
            try:
                with open("frp_info.config", "r", encoding="utf-8") as f:
                    content = f.read().strip()
                    config_content = content

                    # Lấy trycloudflare.com
                    match = re.search(r'https://[a-z0-9-]+\.trycloudflare\.com', content)
                    if match:
                        tunnel_url = match.group(0)

                    # Lấy các link vless
                    links = re.findall(r'vless://[^\s\"\']+', content)
                    if links:
                        vless_links = links
            except:
                pass
        time.sleep(3)

@app.route("/")
def home():
    links_html = "<br>".join([f"<code>{link}</code>" for link in vless_links]) if vless_links else "Đang chờ tạo link..."
    
    html = f"""
    <html>
    <head>
        <title>Xray VLESS-WS</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {{ font-family: Arial, sans-serif; background: #111; color: #eee; padding: 20px; }}
            .box {{ background: #1e1e1e; padding: 16px; border-radius: 10px; margin-bottom: 16px; }}
            a {{ color: #4fc3f7; word-break: break-all; }}
            code {{ background: #000; padding: 8px; display: block; border-radius: 6px; margin: 8px 0; word-break: break-all; font-size: 13px; }}
            .sub {{ background: #0d47a1; padding: 12px; border-radius: 8px; }}
        </style>
    </head>
    <body>
        <h2>Xray VLESS-WS Server</h2>

        <div class="box sub">
            <b>Subscription URL (import trực tiếp):</b><br><br>
            <a href="/frp_info.config" target="_blank">https://xray-vless-ws-server.onrender.com/frp_info.config</a>
        </div>

        <div class="box">
            <b>Cloudflare Tunnel:</b><br>
            <a href="{tunnel_url}" target="_blank">{tunnel_url}</a>
        </div>

        <div class="box">
            <b>VLESS Links:</b><br>
            {links_html}
        </div>

        <p style="color:#aaa;font-size:13px">Refresh lại trang sau 15-30 giây nếu chưa thấy link.</p>
    </body>
    </html>
    """
    return html

@app.route("/frp_info.config")
def subscription():
    if config_content:
        return Response(config_content, mimetype="text/plain")
    return Response("Đang khởi tạo, vui lòng đợi vài giây rồi thử lại...", mimetype="text/plain")

@app.route("/health")
def health():
    return "ok", 200

if __name__ == "__main__":
    render_port = int(os.environ.get("PORT", 10000))

    t1 = threading.Thread(target=run_main, daemon=True)
    t1.start()

    t2 = threading.Thread(target=watch_links, daemon=True)
    t2.start()

    time.sleep(5)
    print(f"[*] Flask listening on 0.0.0.0:{render_port}")
    app.run(host="0.0.0.0", port=render_port, debug=False)
