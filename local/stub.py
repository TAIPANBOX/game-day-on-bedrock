#!/usr/bin/env python3
"""D5 game day local stub: answers /v1/messages the way Bedrock answers,
picked by the FAULT env var. Stdlib only, loopback only.

FAULT=throttle -> 429, x-amzn-ErrorType: ThrottlingException
FAULT=retired  -> 400, x-amzn-ErrorType: ValidationException
FAULT=ok       -> 200, a minimal Anthropic Messages-shaped answer with usage

Listens on 127.0.0.1:4200.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAULT = os.environ.get("FAULT", "ok")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # keep stderr quiet except for what we care about; still show method/path/status
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body) if body else {}
        except Exception:
            payload = {}

        if self.path != "/v1/messages":
            self.send_response(404)
            self.end_headers()
            return

        if FAULT == "throttle":
            resp = {"message": "Too many requests, please wait before trying again."}
            data = json.dumps(resp).encode()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("x-amzn-ErrorType", "ThrottlingException")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif FAULT == "retired":
            resp = {"message": "The provided model identifier is invalid."}
            data = json.dumps(resp).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("x-amzn-ErrorType", "ValidationException")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:  # ok
            model = payload.get("model", "claude-haiku")
            resp = {
                "id": "msg_stub_ok",
                "type": "message",
                "role": "assistant",
                "model": model,
                "content": [{"type": "text", "text": "stub ok response"}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 12, "output_tokens": 8},
            }
            data = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


def main():
    addr = ("127.0.0.1", 4200)
    httpd = ThreadingHTTPServer(addr, Handler)
    print(f"stub listening on http://{addr[0]}:{addr[1]} FAULT={FAULT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
