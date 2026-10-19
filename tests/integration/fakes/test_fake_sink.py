"""Queue acknowledgement and recorder contracts for the Telegram fixture."""

import importlib.util
import json
import threading
from pathlib import Path
from urllib.request import Request, urlopen


def test_telegram_queue_retains_updates_until_acknowledged(tmp_path):
    spec = importlib.util.spec_from_file_location(
        "fake_sink", Path(__file__).with_name("fake_sink.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    log = tmp_path / "requests.log"
    server = module.make_server(0, log)
    thread = threading.Thread(target=server.serve_forever)
    thread.start()

    def request(path, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        with urlopen(
            Request(f"http://127.0.0.1:{server.server_port}{path}", data=data), timeout=3
        ) as response:
            return json.load(response)

    try:
        updates = [{"update_id": 7}, {"update_id": 8}]
        assert request("/control", {"updates": updates})["ok"]
        assert request("/bottest/getUpdates?timeout=0&limit=1")["result"] == updates[:1]
        assert request("/bottest/getUpdates?offset=7")["result"] == updates
        assert request("/bottest/getUpdates?offset=8")["result"] == updates[1:]
        assert request("/bottest/getUpdates?offset=9")["result"] == []
        assert request("/bottest/sendMessage", {"chat_id": "allowed", "text": "reply"})["ok"]
        rows = request("/control")["requests"]
        assert [row["method"] for row in rows] == ["GET"] * 4 + ["POST"]
        assert json.loads(rows[-1]["body"])["text"] == "reply"
        assert [json.loads(line) for line in log.read_text().splitlines()] == rows
        request("/control", {"reset": True})
        assert request("/control") == {"requests": [], "updates": []}
    finally:
        server.shutdown()
        thread.join(timeout=3)
        server.server_close()
