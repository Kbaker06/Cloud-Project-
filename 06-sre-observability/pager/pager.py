"""A fake pager: receives Alertmanager webhooks and prints them like an on-call phone would.

    docker compose logs -f pager
"""

import json
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

ICONS = {"page": "\U0001f6a8 PAGE", "ticket": "\U0001f3ab TICKET"}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (http.server naming)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        kind = ICONS.get(self.path.strip("/"), self.path)
        now = datetime.now(timezone.utc).strftime("%H:%M:%S")
        for alert in body.get("alerts", []):
            state = "RESOLVED" if alert["status"] == "resolved" else "FIRING  "
            labels = alert.get("labels", {})
            ann = alert.get("annotations", {})
            print(f"[{now}] {kind} {state} {labels.get('alertname')}: {ann.get('summary', '')}", flush=True)
            if alert["status"] == "firing" and ann.get("runbook_url"):
                print(f"           runbook: {ann['runbook_url']}", flush=True)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    print("pager listening on :8000", flush=True)
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
