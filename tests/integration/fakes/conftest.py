import os

if not os.environ.get("TOR_SOCKS_PROXY", "").strip():
    os.environ["TOR_SOCKS_PROXY"] = "socks5h://127.0.0.1:1080"
