from __future__ import annotations

import argparse
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from app.runtime_service import PostchairRuntimeService


class PostchairRequestHandler(BaseHTTPRequestHandler):
    service: PostchairRuntimeService

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._write_json(HTTPStatus.OK, self.service.health())
            return
        if self.path == "/api/status":
            self._write_json(HTTPStatus.OK, self.service.backend_status())
            return
        if self.path == "/api/monitoring":
            self._write_json(HTTPStatus.OK, self.service.monitoring_state())
            return
        if self.path == "/api/notifications":
            self._write_json(HTTPStatus.OK, self.service.notification_settings())
            return
        if self.path == "/api/model":
            self._write_json(HTTPStatus.OK, self.service.model_catalog())
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:  # noqa: N802
        payload = self._read_json_body()
        if self.path == "/api/monitoring/start":
            response = self.service.start_monitoring(
                address=payload.get("address"),
                device_name=payload.get("device_name", "ESP32_SmartSensor"),
                scan_timeout=float(payload.get("scan_timeout", 5.0)),
            )
            self._write_json(HTTPStatus.OK, response)
            return
        if self.path == "/api/monitoring/stop":
            self._write_json(HTTPStatus.OK, self.service.stop_monitoring())
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_PUT(self) -> None:  # noqa: N802
        payload = self._read_json_body()
        if self.path == "/api/notifications":
            self._write_json(
                HTTPStatus.OK,
                self.service.update_notification_settings(payload),
            )
            return
        if self.path == "/api/model":
            self._write_json(
                HTTPStatus.OK,
                self.service.select_model(str(payload.get("filename", ""))),
            )
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return

    def _read_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length == 0:
            return {}
        raw_body = self.rfile.read(content_length)
        if not raw_body:
            return {}
        return json.loads(raw_body.decode("utf-8"))

    def _write_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Postchair local HTTP backend.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    return parser


def main() -> None:
    args = build_arg_parser().parse_args()
    service = PostchairRuntimeService()
    handler = type(
        "BoundPostchairRequestHandler",
        (PostchairRequestHandler,),
        {"service": service},
    )
    server = ThreadingHTTPServer((args.host, args.port), handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        service.stop_monitoring()
        server.server_close()


if __name__ == "__main__":
    main()
