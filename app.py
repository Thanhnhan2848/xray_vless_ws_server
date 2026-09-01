from flask import Flask
import threading
import os
import time
import sys

app = Flask(__name__)

@app.route("/")
def home():
    return "Xray VLESS-WS is running", 200

@app.route("/health")
def health():
    return "ok", 200

def run_main():
    try:
        # Ép Xray luôn dùng cổng nội bộ 8888
        os.environ["PORT"] = "127.0.0.1:8888"
        from main import main
        main()
    except Exception as e:
        print(f"[ERROR] main crashed: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    # Lấy cổng Render cấp (phải là số)
    render_port = int(os.environ.get("PORT", 10000))

    t = threading.Thread(target=run_main, daemon=True)
    t.start()

    time.sleep(6)

    print(f"[*] Flask listening on 0.0.0.0:{render_port}")
    app.run(host="0.0.0.0", port=render_port, debug=False)
