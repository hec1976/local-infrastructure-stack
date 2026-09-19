#!/usr/bin/env python3
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

AUDIT_URL = os.environ.get(
    "TEKO_AUDIT_EXPORT_URL",
    "https://config-manager.local/api/audit_export.php"
)
LOKI_URL = os.environ.get(
    "TEKO_LOKI_PUSH_URL",
    "http://127.0.0.1:3100/loki/api/v1/push"
)
TOKEN_FILE = Path(os.environ.get(
    "TEKO_AUDIT_EXPORT_TOKEN_FILE",
    "/opt/service/env/loki-export.token"
))
STATE_FILE = Path(os.environ.get(
    "TEKO_LOKI_STATE_FILE",
    "/var/lib/teko-loki-importer/state.json"
))
POLL_SECONDS = max(2, int(os.environ.get("TEKO_LOKI_POLL_SECONDS", "5")))
BATCH = max(1, min(1000, int(os.environ.get("TEKO_LOKI_BATCH", "500"))))
ONESHOT = os.environ.get("TEKO_LOKI_ONESHOT", "0").lower() in {"1", "true", "yes"}


def log(msg):
    print(msg, flush=True)


def read_token():
    token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    if len(token) < 32:
        raise RuntimeError("audit export token missing/too short")
    return token


def load_last_id():
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return max(0, int(data.get("last_id", 0)))
    except FileNotFoundError:
        return 0
    except Exception:
        return 0


def save_last_id(last_id):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"last_id": int(last_id)}) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_FILE)


def to_ns(ts):
    text = str(ts or "").strip()
    candidates = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S",
    ]
    for fmt in candidates:
        try:
            dt = datetime.strptime(text, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return str(int(dt.timestamp() * 1_000_000_000))
        except ValueError:
            pass
    return str(int(time.time() * 1_000_000_000))


def fetch_events(after_id, token):
    qs = urllib.parse.urlencode({"after_id": after_id, "limit": BATCH})
    req = urllib.request.Request(
        f"{AUDIT_URL}?{qs}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "teko-loki-importer/1.0",
        },
        method="GET",
    )
    # Local lab certificate is self-signed. Endpoint is local-only in Apache
    # and additionally protected by a random bearer token.
    ctx = ssl._create_unverified_context()
    with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
        data = json.load(resp)
    if not data.get("ok"):
        raise RuntimeError(f"audit export failed: {data}")
    return data


def push_events(events):
    streams = {}
    for ev in events:
        module = str(ev.get("module") or "unknown")[:128]
        result = str(ev.get("result") or "unknown")[:128]
        labels = (
            ("job", "config-manager-audit"),
            ("service", "config-manager-audit"),
        )
        line_obj = {
            "id": int(ev.get("id", 0)),
            "ts": ev.get("ts"),
            "user": ev.get("user"),
            "action": ev.get("action"),
            "identity": ev.get("identity"),
            "function": ev.get("function"),
            "result": ev.get("result"),
            "module": module,
            "payload": ev.get("payload"),
        }
        streams.setdefault(labels, []).append(
            [to_ns(ev.get("ts")), json.dumps(line_obj, ensure_ascii=False, separators=(",", ":"))]
        )

    payload = {
        "streams": [
            {"stream": dict(labels), "values": values}
            for labels, values in streams.items()
        ]
    }
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        LOKI_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        if resp.status not in (200, 204):
            raise RuntimeError(f"Loki push returned HTTP {resp.status}")


def main():
    token = read_token()
    last_id = load_last_id()
    log(f"starting, last_id={last_id}")

    while True:
        try:
            data = fetch_events(last_id, token)
            events = data.get("events") or []
            if events:
                push_events(events)
                last_id = int(data.get("last_id", last_id))
                save_last_id(last_id)
                log(f"imported {len(events)} events, last_id={last_id}")
                if len(events) >= BATCH and not ONESHOT:
                    continue
            if ONESHOT:
                return
        except Exception as exc:
            log(f"ERROR: {exc}")
            if ONESHOT:
                raise
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
