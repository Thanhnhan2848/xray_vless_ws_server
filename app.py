from flask import Flask
import threading
import os
import time

app = Flask(__name__)

@app.route("/")
def home():
    return "Xray VLESS-WS running", 200

@app.route("/health")
def health():
    return "ok", 200

def start_xray():
    # Chạy main gốc
    os.system("python main.py")

if __name__ == "__main__":
    # Chạy Xray + Tunnel ở background
    t = threading.Thread(target=start_xray, daemon=True)
    t.start()

    # Flask chạy cổng Render yêu cầu
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
