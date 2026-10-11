"""Run the Swift SSE client against a local server; no relay or API keys needed."""
import json
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


acknowledged = threading.Event()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/ack":
            acknowledged.set()
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path != "/stream":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def frame(payload):
            return ("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode("utf-8")

        try:
            delta = frame({"type": "reply_delta", "stream_id": "api-test",
                           "text": "小雪，🌊", "done": False, "api_session": "test"})
            # Feed small writes, including splits inside Chinese/emoji code points.
            for byte in b"retry: 3000\n: connected\n\n" + delta:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
            if not acknowledged.wait(8):
                self.close_connection = True
                return
            self.wfile.write(frame({"id": 42, "author": "ai", "kind": "reply",
                                    "text": "小雪，🌊", "meta": {"stream_id": "api-test"}}))
            self.wfile.flush()
            # Keep the connection open. The client must not wait for EOF.
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run(
            [sys.argv[1], f"http://127.0.0.1:{server.server_port}"], timeout=20,
        )
        sys.exit(result.returncode)
    finally:
        server.shutdown()
        server.server_close()
