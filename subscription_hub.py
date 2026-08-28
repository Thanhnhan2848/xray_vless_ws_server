#!/usr/bin/env python3
"""Authenticated VLESS subscription aggregation hub.

Run this only on the VPS that publishes the public subscription. Nodes POST their
current VLESS links to /sync; this server writes a de-duplicated merged file that
nginx can expose as the single subscription URL.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
import time
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Iterable

NODE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,80}$")
WRITE_LOCK = threading.Lock()


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(content)
        temp_name = handle.name
    os.replace(temp_name, path)
    # nginx workers must be able to read generated subscription files.
    os.chmod(path, 0o644)


def normalise_links(payloads: object) -> list[str]:
    if not isinstance(payloads, list):
        raise ValueError("payloads must be an array")
    if len(payloads) > 100:
        raise ValueError("maximum 100 links per node")
    links: list[str] = []
    for value in payloads:
        if not isinstance(value, str):
            raise ValueError("every payload must be a string")
        link = value.strip()
        if not link.startswith("vless://") or len(link) > 4096:
            raise ValueError("payload must be a valid VLESS URI")
        links.append(link)
    return links


def merge_node_files(nodes_dir: Path, output_path: Path, max_age_seconds: int = 0) -> tuple[int, list[str]]:
    seen: set[str] = set()
    merged: list[str] = []
    expired: list[str] = []
    now = time.time()
    for node_file in sorted(nodes_dir.glob("*.config")):
        if max_age_seconds and now - node_file.stat().st_mtime > max_age_seconds:
            expired.append(node_file.stem)
            node_file.unlink(missing_ok=True)
            continue
        for raw_line in node_file.read_text(encoding="utf-8").splitlines():
            link = raw_line.strip()
            if link and link not in seen:
                seen.add(link)
                merged.append(link)
    atomic_write(output_path, "\n".join(merged) + ("\n" if merged else ""))
    return len(merged), expired


def node_status(nodes_dir: Path) -> list[dict[str, object]]:
    nodes: list[dict[str, object]] = []
    for node_file in sorted(nodes_dir.glob("*.config")):
        links = sum(1 for line in node_file.read_text(encoding="utf-8").splitlines() if line.strip())
        nodes.append({"node_id": node_file.stem, "links": links, "updated_at": int(node_file.stat().st_mtime)})
    return nodes


def make_handler(token: str, nodes_dir: Path, output_path: Path, max_age_seconds: int):
    class SubscriptionHubHandler(BaseHTTPRequestHandler):
        server_version = "VLESSSubscriptionHub/1.0"

        def log_message(self, format: str, *args: object) -> None:
            print(f"[{self.log_date_time_string()}] {self.address_string()} {format % args}")

        def send_json(self, status: HTTPStatus, body: dict) -> None:
            encoded = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def authorised(self) -> bool:
            return self.headers.get("Authorization") == f"Bearer {token}"

        def do_GET(self) -> None:
            if self.path == "/health":
                self.send_json(HTTPStatus.OK, {"ok": True})
            elif self.path == "/nodes":
                if not self.authorised():
                    self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid token"})
                    return
                with WRITE_LOCK:
                    total, expired = merge_node_files(nodes_dir, output_path, max_age_seconds)
                    nodes = node_status(nodes_dir)
                self.send_json(HTTPStatus.OK, {"ok": True, "nodes": nodes, "total_links": total, "expired": expired})
            else:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_DELETE(self) -> None:
            prefix = "/nodes/"
            if not self.path.startswith(prefix):
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if not self.authorised():
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid token"})
                return
            node_id = self.path[len(prefix):]
            if not NODE_ID_PATTERN.fullmatch(node_id):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid node_id"})
                return
            with WRITE_LOCK:
                node_file = nodes_dir / f"{node_id}.config"
                if not node_file.exists():
                    self.send_json(HTTPStatus.NOT_FOUND, {"error": "node not found"})
                    return
                node_file.unlink()
                total, expired = merge_node_files(nodes_dir, output_path, max_age_seconds)
            print(f"[OK] Removed node '{node_id}'; merged total: {total}")
            self.send_json(HTTPStatus.OK, {"ok": True, "removed_node": node_id, "total_links": total, "expired": expired})

        def do_POST(self) -> None:
            if self.path != "/sync":
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            if not self.authorised():
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid token"})
                return
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
                if not 1 <= content_length <= 512_000:
                    raise ValueError("invalid request size")
                payload = json.loads(self.rfile.read(content_length).decode("utf-8"))
                node_id = payload.get("node_id", "")
                if not isinstance(node_id, str) or not NODE_ID_PATTERN.fullmatch(node_id):
                    raise ValueError("node_id may only contain letters, numbers, dot, dash, underscore")
                links = normalise_links(payload.get("payloads"))
            except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
                return

            with WRITE_LOCK:
                atomic_write(nodes_dir / f"{node_id}.config", "\n".join(links) + ("\n" if links else ""))
                total, expired = merge_node_files(nodes_dir, output_path, max_age_seconds)
            print(f"[OK] Synced node '{node_id}': {len(links)} links; merged total: {total}")
            self.send_json(HTTPStatus.OK, {"ok": True, "node_id": node_id, "total_links": total, "expired": expired})

    return SubscriptionHubHandler


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate VLESS links from multiple VPS nodes")
    parser.add_argument("--token", required=True, help="shared secret required from every node")
    parser.add_argument("--output", required=True, type=Path, help="merged config file nginx serves")
    parser.add_argument("--data-dir", default="subscription_nodes", type=Path, help="directory for each node's latest links")
    parser.add_argument("--bind", default="127.0.0.1", help="listen IP; use 127.0.0.1 with nginx reverse proxy")
    parser.add_argument("--port", default=9998, type=int, help="listen port")
    parser.add_argument("--max-age-hours", default=0, type=int, help="remove nodes not synced within this many hours; 0 disables expiry")
    args = parser.parse_args()

    if len(args.token) < 24:
        parser.error("--token must be at least 24 characters")
    if args.max_age_hours < 0:
        parser.error("--max-age-hours cannot be negative")
    args.data_dir.mkdir(parents=True, exist_ok=True)
    max_age_seconds = args.max_age_hours * 3600
    with WRITE_LOCK:
        total, expired = merge_node_files(args.data_dir, args.output, max_age_seconds)
    if expired:
        print(f"[OK] Removed expired nodes at startup: {', '.join(expired)}")
    handler = make_handler(args.token, args.data_dir, args.output, max_age_seconds)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    print(f"Subscription hub listening on http://{args.bind}:{args.port}")
    print(f"Merged output: {args.output.resolve()}")
    server.serve_forever()


if __name__ == "__main__":
    main()