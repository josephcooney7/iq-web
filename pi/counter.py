#!/usr/bin/env python3
"""Stapleton IQ single-camera counter: one camera on a Pi 5, people detection
on the AI HAT+ (Hailo), line-crossing counts sent through iq_uploader.py.

    python3 counter.py check      # are the camera and the AI HAT+ found?
    python3 counter.py aim        # saves ~/stapleton-iq/aim.jpg with the counting line drawn
    python3 counter.py run        # count and upload (what the service runs)
    python3 counter.py run --no-upload   # count and print only
    python3 counter.py selftest   # tests the counting logic, no hardware needed

Settings live in ~/stapleton-iq/camera.json (optional, see DEFAULTS).
"""

import argparse
import json
import math
import os
import sys
import time

DEFAULT_SETTINGS = os.path.expanduser("~/stapleton-iq/camera.json")
DEFAULTS = {
    "line_y": 0.5,           # counting line, 0 = top of picture, 1 = bottom
    "in_direction": "down",  # people walking toward the bottom of the picture count as "in"
    "min_score": 0.5,        # how sure the AI must be that it's a person
    "max_jump": 0.12,        # furthest a person can move between frames (fraction of width)
    "max_missed": 8,         # frames a person can vanish (e.g. behind someone) before we forget them
    "dead_zone": 0.05,
    "zones": [],             # ignore boxes [x1, y1, x2, y2]: nobody inside them is counted
    "lines": None,           # set from the phone page; None = one line straight across at line_y       # band either side of the line; a person must fully clear it to count
    "fps": 15,
    "flip": True,            # camera board mounts upside down in the case
    "model": None,           # path to a .hef; picked automatically when empty
}
MODEL_CANDIDATES = [
    "/usr/share/hailo-models/yolov8s_h8.hef",    # AI HAT+ 26 TOPS (Hailo-8)
    "/usr/share/hailo-models/yolov6n_h8.hef",
    "/usr/share/hailo-models/yolov8s_h8l.hef",   # AI HAT+ 13 TOPS (Hailo-8L)
    "/usr/share/hailo-models/yolov6n_h8l.hef",
]
SENSOR_SIZE = (2304, 1296)   # full field of view, binned
FRAME_SIZE = (640, 360)      # what the AI looks at (16:9, full width kept)
SNAP_SIZE = (1280, 720)


def load_settings(path):
    s = dict(DEFAULTS)
    if os.path.exists(path):
        with open(path) as f:
            s.update(json.load(f))
    return s


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ---------------------------------------------------------------- counting
class LineCounter:
    """Follows people from frame to frame and reports line crossings.

    Lines come from settings["lines"]: [{"p": [x1, y1, x2, y2], "dir": 1 or -1,
    "count": "both" | "in" | "out"}], coordinates 0..1. Crossing to the side on the
    right of x1,y1 -> x2,y2 (below, for a left-to-right line) is "in" when dir is 1.
    A line with count "in" ignores people crossing it the other way, and vice versa.
    Without "lines", one full-width line at line_y is used (the old setting)."""

    def __init__(self, settings):
        self.max_jump = settings["max_jump"]
        self.max_missed = settings["max_missed"]
        self.dz = settings.get("dead_zone", 0.05)
        self.tracks = {}         # id -> {"x", "y", "vx", "vy", "missed", "sides"}
        self.next_id = 0
        self.counts = {"in": 0, "out": 0}
        self.set_lines(settings.get("lines"), settings["line_y"], settings["in_direction"])
        self.set_zones(settings.get("zones"))

    def set_zones(self, zones):
        """Boxes where people are ignored (e.g. a guard's post)."""
        self.zones = []
        for z in zones or []:
            x1, y1, x2, y2 = (float(v) for v in z)
            self.zones.append((min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)))

    def _ignored(self, x, y):
        return any(x0 <= x <= x1 and y0 <= y <= y1 for x0, y0, x1, y1 in self.zones)

    def set_lines(self, lines, line_y=0.5, in_direction="down"):
        if not lines:
            lines = [{"p": [0, line_y, 1, line_y], "dir": 1 if in_direction == "down" else -1,
                      "count": "both"}]
        self.lines = []
        for l in lines:
            x1, y1, x2, y2 = (float(v) for v in l["p"])
            length = math.hypot(x2 - x1, y2 - y1)
            if length < 0.02:
                continue                     # too short to be a line
            self.lines.append({"x1": x1, "y1": y1, "dx": x2 - x1, "dy": y2 - y1, "len": length,
                               "dir": 1 if int(l.get("dir", 1)) >= 0 else -1,
                               "count": l.get("count", "both")})
        self.tracks.clear()                  # sides were measured against the old lines

    def _side(self, line, x, y):
        """None = beside the line's ends, 0 = in the dead zone, -1/+1 = which side."""
        rx, ry = x - line["x1"], y - line["y1"]
        t = (rx * line["dx"] + ry * line["dy"]) / (line["len"] ** 2)
        if t < -0.03 or t > 1.03:
            return None
        d = (line["dx"] * ry - line["dy"] * rx) / line["len"]
        if d > self.dz:
            return 1
        if d < -self.dz:
            return -1
        return 0

    def _first_sides(self, x, y):
        out = []
        for line in self.lines:
            s = self._side(line, x, y)
            if s == 0:   # starts inside the dead zone: take the nearer side
                d = line["dx"] * (y - line["y1"]) - line["dy"] * (x - line["x1"])
                s = 1 if d >= 0 else -1
            out.append(s)
        return out

    def update(self, points):
        """points: list of (x, y) person centres, 0..1. Returns crossings, e.g. ["in"]."""
        crossings = []
        if self.zones:
            points = [(x, y) for x, y in points if not self._ignored(x, y)]
        # Compare each person with where each track should be now (last position + its speed).
        pairs = sorted(
            (math.hypot(px - (t["x"] + t["vx"] * (t["missed"] + 1)),
                        py - (t["y"] + t["vy"] * (t["missed"] + 1))), tid, i)
            for tid, t in self.tracks.items() for i, (px, py) in enumerate(points))
        used_t, used_p = set(), set()
        for d, tid, i in pairs:
            if d > self.max_jump or tid in used_t or i in used_p:
                continue
            used_t.add(tid); used_p.add(i)
            t = self.tracks[tid]
            px, py = points[i]
            for k, line in enumerate(self.lines):
                side = self._side(line, px, py)
                if side is None:
                    t["sides"][k] = None     # went round the end: must cross properly later
                    continue
                old = t["sides"][k]
                if side and old and side != old:
                    direction = "in" if (side > 0) == (line["dir"] > 0) else "out"
                    if line["count"] in ("both", direction):
                        self.counts[direction] += 1
                        crossings.append(direction)
                if side:
                    t["sides"][k] = side
            steps = t["missed"] + 1
            t["vx"] = 0.5 * t["vx"] + 0.5 * (px - t["x"]) / steps
            t["vy"] = 0.5 * t["vy"] + 0.5 * (py - t["y"]) / steps
            t.update(x=px, y=py, missed=0)
        for tid in list(self.tracks):
            if tid not in used_t:
                self.tracks[tid]["missed"] += 1
                if self.tracks[tid]["missed"] > self.max_missed:
                    del self.tracks[tid]
        for i, (px, py) in enumerate(points):
            if i not in used_p:
                self.tracks[self.next_id] = {"x": px, "y": py, "vx": 0.0, "vy": 0.0, "missed": 0,
                                              "sides": self._first_sides(px, py)}
                self.next_id += 1
        return crossings


# ---------------------------------------------------------------- hardware
def open_camera(settings, with_snap=False):
    from picamera2 import Picamera2
    from libcamera import Transform

    if not Picamera2.global_camera_info():
        sys.exit("No camera found. Check the ribbon cable (gold side, latch closed).")
    cam = Picamera2(0)
    flip = settings["flip"]
    cfg = cam.create_video_configuration(
        main={"size": SNAP_SIZE if with_snap else FRAME_SIZE, "format": "BGR888"},
        sensor={"output_size": SENSOR_SIZE},
        transform=Transform(hflip=flip, vflip=flip),
        controls={"FrameRate": settings["fps"]},
        buffer_count=4)
    cam.configure(cfg)
    cam.start()
    time.sleep(1.5)   # let exposure settle
    return cam


def find_model(settings):
    for path in [settings["model"]] + MODEL_CANDIDATES:
        if path and os.path.exists(path):
            return path
    return None


class PersonDetector:
    """Runs a YOLO .hef on the AI HAT+ and returns person centres (0..1)."""

    def __init__(self, model_path, min_score):
        from picamera2.devices import Hailo
        self.hailo = Hailo(model_path)
        self.h, self.w, _ = self.hailo.get_input_shape()
        self.min_score = min_score

    def people(self, frame):
        import numpy as np
        fh, fw = frame.shape[:2]
        # Fit the 16:9 frame into the model's square input without cropping the sides.
        scale = min(self.w / fw, self.h / fh)
        if scale != 1:
            ys = (np.arange(int(fh * scale)) / scale).astype(int)
            xs = (np.arange(int(fw * scale)) / scale).astype(int)
            frame = frame[ys][:, xs]
        ch, cw = frame.shape[:2]
        top, left = (self.h - ch) // 2, (self.w - cw) // 2
        canvas = np.zeros((self.h, self.w, 3), dtype=np.uint8)
        canvas[top:top + ch, left:left + cw] = frame[:, :, :3]
        result = self.hailo.run(canvas)
        persons = result[0] if len(result) else []   # class 0 = person
        out = []
        for det in persons:
            y0, x0, y1, x1, score = det[:5]
            if score < self.min_score:
                continue
            x = ((x0 + x1) / 2 * self.w - left) / cw
            y = ((y0 + y1) / 2 * self.h - top) / ch
            if 0 <= x <= 1 and 0 <= y <= 1:
                out.append((x, y))
        return out

    def close(self):
        self.hailo.close()


# ---------------------------------------------------------------- phone setup
class UnitSync:
    """Every 15 s asks the cloud for this unit's counting-line settings. When the
    phone setup page asks for a picture, sends ONE still frame (only then)."""

    def __init__(self, counter, settings, settings_path, config_path=None):
        import threading
        cfg_path = config_path or os.path.expanduser("~/stapleton-iq/config.json")
        with open(cfg_path) as f:
            cfg = json.load(f)
        self.url = cfg["supabase_url"].rstrip("/") + "/rest/v1/rpc/device_sync"
        self.key = cfg["anon_key"]
        self.device_id, self.device_key = cfg["device_id"], cfg["device_key"]
        self.counter, self.settings, self.settings_path = counter, settings, settings_path
        self.version = settings.get("settings_version")
        self.latest_frame = None
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.stop_event.set()

    def _call(self, snapshot=None):
        import urllib.request
        body = json.dumps({"p_device_id": self.device_id, "p_device_key": self.device_key,
                           "p_snapshot_b64": snapshot, "p_applied_version": self.version}).encode()
        req = urllib.request.Request(self.url, data=body, method="POST", headers={
            "apikey": self.key, "Authorization": "Bearer " + self.key,
            "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())

    def _jpeg(self):
        import base64, io
        from PIL import Image
        frame = self.latest_frame
        if frame is None:
            return None
        buf = io.BytesIO()
        Image.fromarray(frame[:, :, :3]).save(buf, "JPEG", quality=75)
        return base64.b64encode(buf.getvalue()).decode()

    def _apply(self, r):
        if r["version"] == self.version:
            return
        line_y, direction, lines = float(r["line_y"]), r["in_direction"], r.get("lines")
        zones = r.get("zones") or []
        self.counter.set_lines(lines, line_y, direction)
        self.counter.set_zones(zones)
        self.version = r["version"]
        changes = dict(line_y=line_y, in_direction=direction, lines=lines, zones=zones,
                       settings_version=self.version)
        self.settings.update(changes)
        try:
            saved = {}
            if os.path.exists(self.settings_path):
                with open(self.settings_path) as f:
                    saved = json.load(f)
            saved.update(changes)
            with open(self.settings_path, "w") as f:
                json.dump(saved, f, indent=2)
        except OSError as e:
            log(f"could not save settings: {e}")
        log(f"new counting lines from phone: {len(self.counter.lines)} line(s), "
            f"{len(self.counter.zones)} ignore zone(s), version {self.version}")

    def _loop(self):
        while not self.stop_event.is_set():
            try:
                r = self._call()
                self._apply(r)
                if r.get("snapshot_wanted"):
                    snap = self._jpeg()
                    if snap:
                        self._call(snapshot=snap)
                        log("sent one still picture for phone setup")
                        continue        # check again right away
            except Exception as e:      # never let setup problems stop counting
                log(f"phone-setup sync failed: {e}")
            self.stop_event.wait(15)


# ---------------------------------------------------------------- commands
def cmd_check(settings):
    ok = True
    try:
        from picamera2 import Picamera2
        found = Picamera2.global_camera_info()
        for c in found:
            print(f"camera {c['Num']}: {c['Model']}  {c.get('Id', '')}")
        if not found:
            print("PROBLEM: no camera found"); ok = False
    except ImportError:
        print("PROBLEM: picamera2 is not installed (sudo apt install python3-picamera2)"); ok = False
    model = find_model(settings)
    if model:
        print("AI model:", model)
    else:
        print("PROBLEM: no AI model found (sudo apt install hailo-all, then reboot)"); ok = False
    if not os.path.exists("/dev/hailo0"):
        print("PROBLEM: AI HAT+ not detected (/dev/hailo0 missing)"); ok = False
    print("ALL GOOD" if ok else "see problems above")
    return ok


def cmd_aim(settings, out_path):
    from PIL import Image, ImageDraw
    cam = open_camera(settings, with_snap=True)
    img = Image.fromarray(cam.capture_array("main")[:, :, :3])
    cam.stop(); cam.close()
    d = ImageDraw.Draw(img)
    w, h = img.size
    for line in LineCounter(settings).lines:
        x1, y1 = line["x1"] * w, line["y1"] * h
        x2, y2 = x1 + line["dx"] * w, y1 + line["dy"] * h
        colour = {"in": (40, 200, 80), "out": (255, 160, 0)}.get(line["count"], (255, 40, 40))
        d.line([(x1, y1), (x2, y2)], fill=colour, width=5)
    for x0, y0, x1, y1 in LineCounter(settings).zones:
        d.rectangle([x0 * w, y0 * h, x1 * w, y1 * h], outline=(150, 150, 150), width=4)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    img.save(out_path, quality=85)
    print("saved", out_path)
    print("Red = counts both ways, green = 'in' only, orange = 'out' only.")


def cmd_run(settings, upload, settings_path=DEFAULT_SETTINGS):
    up = sync = None
    if upload:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from iq_uploader import Uploader
        up = Uploader.from_config().start()
    model = find_model(settings)
    if not model:
        sys.exit("No AI model found. Run: sudo apt install hailo-all  (then reboot)")
    counter = LineCounter(settings)
    if upload:
        try:
            sync = UnitSync(counter, settings, settings_path).start()
        except Exception as e:
            log(f"phone setup not available: {e}")
    cam = open_camera(settings)
    det = PersonDetector(model, settings["min_score"])
    log(f"counting with {os.path.basename(model)}, line at {settings['line_y']}")
    frames, last_report = 0, time.time()
    try:
        while True:
            frame = cam.capture_array("main")
            if sync:
                sync.latest_frame = frame
            for direction in counter.update(det.people(frame)):
                log(f"crossing: {direction}")
                if up:
                    up.crossing(direction)
            frames += 1
            if time.time() - last_report >= 60:
                fps = frames / (time.time() - last_report)
                log("in/out %d/%d  (%.1f fps)" % (counter.counts["in"], counter.counts["out"], fps))
                frames, last_report = 0, time.time()
    except KeyboardInterrupt:
        pass
    finally:
        cam.stop(); cam.close()
        det.close()
        if sync:
            sync.stop()
        if up:
            up.stop()
        log("stopped")


def cmd_selftest(settings):
    """Walk fake people across the line and check each is counted exactly once."""
    import random
    random.seed(1)
    counter = LineCounter(settings)
    people, expected = [], {"in": 0, "out": 0}
    for n in range(300):
        down = random.random() < 0.7
        expected["in" if down else "out"] += 1
        people.append({"x": random.uniform(0.05, 0.95), "y": -0.1 if down else 1.1,
                       "v": (1 if down else -1) * random.uniform(0.02, 0.06), "start": n * 3})
    hover = [(random.uniform(0.05, 0.95), 0.5 + random.uniform(-0.03, 0.03)) for _ in range(3)]
    total = {"in": 0, "out": 0}
    for frame in range(300 * 3 + 100):
        pts = []
        for p in people:
            if frame < p["start"]:
                continue
            y = p["y"] + p["v"] * (frame - p["start"])
            if 0 <= y <= 1 and random.random() > 0.05:   # 5% missed detections
                pts.append((p["x"] + random.gauss(0, 0.003), y + random.gauss(0, 0.003)))
        for hx, hy in hover:   # people standing on the line, swaying: must not count
            pts.append((hx + random.gauss(0, 0.004), hy + random.gauss(0, 0.01)))
        for d in counter.update(pts):
            total[d] += 1
    print("expected", expected, "counted", total)
    ok = abs(total["in"] - expected["in"]) <= 3 and abs(total["out"] - expected["out"]) <= 3
    print("PASS" if ok else "FAIL")
    return ok


def main():
    p = argparse.ArgumentParser(description="Stapleton IQ single-camera counter")
    p.add_argument("command", choices=["check", "aim", "run", "selftest"])
    p.add_argument("--settings", default=DEFAULT_SETTINGS)
    p.add_argument("--no-upload", action="store_true")
    p.add_argument("--out", default=os.path.expanduser("~/stapleton-iq/aim.jpg"))
    args = p.parse_args()
    settings = load_settings(args.settings)
    if args.command == "check":
        sys.exit(0 if cmd_check(settings) else 1)
    elif args.command == "aim":
        cmd_aim(settings, args.out)
    elif args.command == "run":
        cmd_run(settings, upload=not args.no_upload, settings_path=args.settings)
    else:
        sys.exit(0 if cmd_selftest(settings) else 1)


if __name__ == "__main__":
    main()
