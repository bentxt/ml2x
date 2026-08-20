#!/usr/bin/env python3

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SYNTHETIC_MODEL = "hf:moonshotai/Kimi-K3"
OLLAMA_MODEL = "deepseek-v4-flash:0731-cloud"

PROVIDERS = {
    SYNTHETIC_MODEL: (
        "https://api.synthetic.new/anthropic",
        "SYNTHETIC_API_KEY",
        "Synthetic",
    ),
    OLLAMA_MODEL: (
        "https://ollama.com",
        "OLLAMA_API_KEY",
        "Ollama Cloud",
    ),
}

FORWARDED_REQUEST_HEADERS = (
    "accept",
    "anthropic-beta",
    "anthropic-version",
    "content-type",
    "user-agent",
)

SKIPPED_RESPONSE_HEADERS = {
    "connection",
    "content-length",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


class RouterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ClaudeProviderRouter/1.0"

    def log_message(self, format_string, *args):
        sys.stderr.write("router: " + (format_string % args) + "\n")

    def send_json(self, status, value):
        payload = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def authorized(self):
        expected = "Bearer " + os.environ["CLAUDE_ROUTER_TOKEN"]
        return self.headers.get("Authorization") == expected

    def do_HEAD(self):
        # Claude Code probes compatible API endpoints before starting.
        if self.path == "/api/hello":
            self.send_response(200)
        elif not self.authorized():
            self.send_response(401)
        else:
            self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        if not self.authorized():
            self.send_json(
                401,
                {"type": "error", "error": {"type": "authentication_error", "message": "Unauthorized"}},
            )
            return

        if self.path == "/health":
            self.send_json(200, {"status": "ok"})
            return

        if self.path.rstrip("/") == "/v1/models":
            self.send_json(
                200,
                {
                    "data": [
                        {"id": SYNTHETIC_MODEL, "display_name": "Synthetic Kimi K3"},
                        {"id": OLLAMA_MODEL, "display_name": "Ollama DeepSeek V4 Flash 0731"},
                    ]
                },
            )
            return

        self.send_json(
            404,
            {"type": "error", "error": {"type": "not_found_error", "message": "Not found"}},
        )

    def do_POST(self):
        if not self.authorized():
            self.send_json(
                401,
                {"type": "error", "error": {"type": "authentication_error", "message": "Unauthorized"}},
            )
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length)
            request_json = json.loads(body)
        except (ValueError, json.JSONDecodeError):
            self.send_json(
                400,
                {"type": "error", "error": {"type": "invalid_request_error", "message": "Invalid JSON request"}},
            )
            return

        model = request_json.get("model")
        provider = PROVIDERS.get(model)
        if provider is None:
            self.send_json(
                400,
                {
                    "type": "error",
                    "error": {
                        "type": "invalid_request_error",
                        "message": f"No provider route configured for model {model!r}",
                    },
                },
            )
            return

        base_url, key_name, provider_name = provider
        upstream_url = base_url + self.path
        upstream_headers = {
            name: self.headers[name]
            for name in FORWARDED_REQUEST_HEADERS
            if name in self.headers
        }
        upstream_headers["Authorization"] = "Bearer " + os.environ[key_name]
        upstream_headers.setdefault("Content-Type", "application/json")

        request = urllib.request.Request(
            upstream_url,
            data=body,
            headers=upstream_headers,
            method="POST",
        )

        self.log_message("routing %s to %s", model, provider_name)
        try:
            response = urllib.request.urlopen(request, timeout=3600)
        except urllib.error.HTTPError as error:
            response = error
        except (urllib.error.URLError, TimeoutError) as error:
            self.send_json(
                502,
                {
                    "type": "error",
                    "error": {
                        "type": "api_error",
                        "message": f"{provider_name} request failed: {error}",
                    },
                },
            )
            return

        try:
            self.send_response(response.status)
            for name, value in response.headers.items():
                if name.lower() not in SKIPPED_RESPONSE_HEADERS:
                    self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            response.close()
            self.close_connection = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    required = ("SYNTHETIC_API_KEY", "OLLAMA_API_KEY", "CLAUDE_ROUTER_TOKEN")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        parser.error("missing environment variables: " + ", ".join(missing))

    server = ThreadingHTTPServer(("127.0.0.1", 0), RouterHandler)
    port = server.server_address[1]
    with open(args.port_file, "x", encoding="utf-8") as port_file:
        port_file.write(str(port))
    os.chmod(args.port_file, 0o600)
    sys.stderr.write(f"router: listening on http://127.0.0.1:{port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
