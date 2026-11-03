#!/usr/bin/env python3
"""Stapleton IQ uploader: keeps per-minute crossing counts on the Pi and sends
them to the cloud database. Uses only the Python standard library.

Counts are written to a small local database first, so nothing is lost when
the LTE hotspot drops; they are sent as soon as the connection is back.

Ways to feed it crossings:
  * From the counting program (Python):
        from iq_uploader import Uploader
        up = Uploader.from_config(); up.start()
        up.crossing("in")            # each time someone crosses the line
  * From any program, one line per crossing ("in" or "out") on stdin:
        my_counter | python3 iq_uploader.py run
  * For testing without a camera:
        python3 iq_uploader.py simulate
  * Check the connection and key:
        python3 iq_uploader.py check
"""

import argparse
import json
import os
import random
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

VERSION = "0.1.0"
DEFAULT_CONFIG = os.path.expanduser("~/stapleton-iq/config.json")
UPLOAD_EVERY_S = 30
MAX_ROWS_PER_UPLOAD = 500


def current_minute():
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    return now.strftime("%Y-%m-%dT%H:%M:00Z")


def read_cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000, 1)
    except (OSError, ValueError):
        return None


def read_uptime():
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except (OSError, ValueError):
        return None


class Uploader:
    def __init__(self, supabase_url, anon_key, device_id, device_key, buffer_path):
        self.url = supabase_url.rstrip("/") + "/rest/v1/rpc/ingest"
        self.anon_key = anon_key
        self.device_id = device_id
        self.device_key = device_key
        os.makedirs(os.path.dirname(buffer_path) or ".", exist_ok=True)
        self.db = sqlite3.connect(buffer_path, check_same_thread=False, isolation_level=None)
        self.db.execute("pragma journal_mode=wal")
        # version goes up on every change; sent_version records what the cloud has.
        self.db.execute("""create table if not exists buckets (
            minute text primary key, in_count int not null default 0,
            out_count int not null default 0, version int not null default 0,
            sent_version int not null default -1)""")
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.last_error = None

    @classmethod
    def from_config(cls, path=DEFAULT_CONFIG):
        with open(path) as f:
            cfg = json.load(f)
        return cls(cfg["supabase_url"], cfg["anon_key"], cfg["device_id"], cfg["device_key"],
                   os.path.expanduser(cfg.get("buffer_path", "~/stapleton-iq/buffer.db")))

    def crossing(self, direction="in", n=1):
        col = "in_count" if direction == "in" else "out_count"
        with self.lock:
            self.db.execute(
                f"""insert into buckets (minute, {col}, version) values (?, ?, 1)
                    on conflict(minute) do update set {col} = {col} + excluded.{col},
                    version = version + 1""",
                (current_minute(), n))

    def pending(self):
        with self.lock:
            return self.db.execute(
                "select count(*) from buckets where version <> sent_version").fetchone()[0]

    def _post(self, counts, health):
        body = json.dumps({"p_device_id": self.device_id, "p_device_key": self.device_key,
                           "p_counts": counts, "p_health": health}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "apikey": self.anon_key, "Authorization": "Bearer " + self.anon_key,
            "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read() or b"null")

    def upload_once(self):
        """Send everything not yet sent. Returns the number of minutes sent."""
        sent = 0
        while True:
            with self.lock:
                rows = self.db.execute(
                    """select minute, in_count, out_count, version from buckets
                       where version <> sent_version order by minute limit ?""",
                    (MAX_ROWS_PER_UPLOAD,)).fetchall()
            pending_after = self.pending() - len(rows)
            health = {"cpu_temp_c": read_cpu_temp(), "uptime_s": read_uptime(),
                      "pending_minutes": max(pending_after, 0), "software_version": VERSION}
            if not rows and sent:
                return sent
            counts = [{"minute": m, "in": i, "out": o} for m, i, o, _ in rows]
            self._post(counts, health)
            with self.lock:
                self.db.executemany(
                    "update buckets set sent_version = ? where minute = ?",
                    [(v, m) for m, _, _, v in rows])
                # Keep 3 days locally as a backup, then tidy up.
                self.db.execute(
                    "delete from buckets where version = sent_version and minute < ?",
                    (datetime.fromtimestamp(time.time() - 3 * 86400, timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:00Z"),))
            sent += len(rows)
            if len(rows) < MAX_ROWS_PER_UPLOAD:
                return sent

    def _loop(self):
        delay = UPLOAD_EVERY_S
        while not self.stop_event.is_set():
            try:
                n = self.upload_once()
                if self.last_error:
                    log(f"connection back, sent {n} minute(s)")
                self.last_error = None
                delay = UPLOAD_EVERY_S
            except Exception as e:  # network down, server error, etc.
                msg = describe_error(e)
                if msg != self.last_error:
                    log(f"upload failed, will retry: {msg}")
                self.last_error = msg
                delay = min(delay * 2, 300)
            self.stop_event.wait(delay)

    def start(self):
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        self.stop_event.set()
        try:
            self.upload_once()
        except Exception as e:
            log(f"final upload failed, counts are saved locally: {describe_error(e)}")


def describe_error(e):
    if isinstance(e, urllib.error.HTTPError):
        try:
            detail = json.loads(e.read()).get("message", "")
        except Exception:
            detail = ""
        return f"HTTP {e.code} {detail}".strip()
    return str(e)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def main():
    p = argparse.ArgumentParser(description="Stapleton IQ uploader")
    p.add_argument("command", choices=["run", "simulate", "check"])
    p.add_argument("--config", default=DEFAULT_CONFIG)
    p.add_argument("--rate", type=float, default=20, help="simulate: people per minute")
    args = p.parse_args()

    up = Uploader.from_config(args.config)

    if args.command == "check":
        try:
            r = up._post([], {"software_version": VERSION, "cpu_temp_c": read_cpu_temp()})
            print("OK, the database accepted this unit:", r)
        except Exception as e:
            print("FAILED:", describe_error(e))
            sys.exit(1)
        return

    up.start()
    log(f"uploader running, {up.pending()} minute(s) waiting to send")
    try:
        if args.command == "simulate":
            while True:
                time.sleep(random.expovariate(args.rate / 60))
                up.crossing("in" if random.random() > 0.05 else "out")
        else:
            for line in sys.stdin:
                word = line.strip().lower()
                if word in ("in", "out"):
                    up.crossing(word)
    except KeyboardInterrupt:
        pass
    finally:
        up.stop()
        log("stopped")


if __name__ == "__main__":
    main()
