#!/usr/bin/env python3
"""fanctl — quiet, temperature-driven control of Coolmoon case fans over RF 433 MHz.

The Coolmoon RF hub has 4 speeds (0 = stopped .. 3 = max) but its remote only has
relative "speed +" / "speed -" buttons. The hub clamps at both ends (no wrap-around),
so pressing "speed -" 4 times always lands on 0 — that is how we re-sync our idea
of the current speed.

Buttons are pressed through an ESP32 + CC1101 running ESPHome (see ../esphome).

Config (environment):
  FANCTL_HOST  ESP32 address (IP or mDNS name), default rf433-cc1101.local
  FANCTL_KEY   ESPHome api.encryption.key of that device (required)

Local HTTP API for the KDE widget: http://127.0.0.1:8766
  GET  /state   current state, thresholds, stats, history
  POST /config  {"mode":"auto"|"manual","manual_level":0..3,"preset":"quiet|balance|cool|custom",
                 "thresholds":{"gpu":[a,b,c],"cpu":[..],"nvme":[..]},"gpu_fan_rule":bool}
  POST /press   {"name":"mode +"|"mode -"|"R"|"G"|"B"|"white"}  — lighting buttons
Settings are stored in ~/.config/fanctl.json.
"""
import asyncio, collections, glob, json, logging, os, re, subprocess, time
from aioesphomeapi import APIClient

HOST = os.environ.get("FANCTL_HOST", "rf433-cc1101.local")
KEY = os.environ.get("FANCTL_KEY", "")
CFG_PATH = os.path.expanduser("~/.config/fanctl.json")
HTTP_PORT = 8766

# Coolmoon command numbers (= button order on the remote, low byte of the 24-bit code)
CMD = {"on": 1, "auto": 2, "off": 3, "speed +": 4, "mode +": 5, "brightness +": 6, "speed -": 7,
       "mode -": 8, "brightness -": 9, "R": 10, "G": 11, "B": 12, "white": 21}
# Buttons the widget may press. "off" is excluded: when the hub is off it ignores speed commands.
LIGHT_BUTTONS = {"mode +", "mode -", "R", "G", "B", "white"}
IDEMPOTENT = {"R", "G", "B", "white"}   # safe to send twice in case one burst is lost

# Temperature (°C) at which speed 1, 2, 3 kicks in, per sensor
PRESETS = {
    "quiet":   {"gpu": [60, 70, 78], "cpu": [70, 80, 88], "nvme": [60, 68, 74]},
    "balance": {"gpu": [55, 65, 75], "cpu": [65, 75, 85], "nvme": [55, 65, 72]},
    "cool":    {"gpu": [48, 58, 68], "cpu": [58, 68, 78], "nvme": [50, 60, 68]},
}
DEFAULT_CFG = {"mode": "auto", "manual_level": 1, "preset": "balance",
               "thresholds": PRESETS["balance"], "gpu_fan_rule": True}

HYST = 6             # step down only when temperature is HYST below the threshold
DOWN_HOLD = 30       # ... and stays there this many seconds
MIN_DWELL = 30       # minimum seconds on a speed after any change
SMOOTH = 5           # moving average over N samples (N * POLL seconds)
GPU_FAN_MIN_T = 50   # "GPU fan is spinning -> at least speed 1" applies from this GPU temp
POLL = 2
GAP = 1.5            # pause between RF button presses
RESYNC_EDGE = 15 * 60   # re-send the edge press (0 or 3) this often
RESYNC_MID = 60 * 60    # re-home (to 0 and back up) for speeds 1-2 this often
HISTORY_SEC = 30 * 60

log = logging.getLogger("fanctl")


def load_cfg():
    cfg = json.loads(json.dumps(DEFAULT_CFG))
    try:
        cfg.update(json.load(open(CFG_PATH)))
    except Exception:
        pass
    if cfg["preset"] in PRESETS:
        cfg["thresholds"] = json.loads(json.dumps(PRESETS[cfg["preset"]]))
    return cfg


def save_cfg(cfg):
    tmp = CFG_PATH + ".tmp"
    json.dump(cfg, open(tmp, "w"), ensure_ascii=False, indent=1)
    os.replace(tmp, CFG_PATH)


def hwmon_temp(name):
    for h in glob.glob("/sys/class/hwmon/hwmon*"):
        if open(f"{h}/name").read().strip() == name:
            return int(open(f"{h}/temp1_input").read()) / 1000
    return None


def cpu_temp():
    # Intel: coretemp; AMD: k10temp
    return hwmon_temp("coretemp") or hwmon_temp("k10temp")


def gpu_state():
    """(temperature, own fan %) of an NVIDIA GPU, or (None, None)."""
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=temperature.gpu,fan.speed", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=5).stdout
        t, fan = out.strip().splitlines()[0].split(",")
        return float(t), float(fan)
    except Exception:
        return None, None


def level_for(t, ups, cur):
    """Speed for one sensor: up on threshold, down with hysteresis."""
    lvl = sum(t >= u for u in ups)
    if lvl < cur:
        keep = sum(t >= u - HYST for u in ups)
        lvl = max(lvl, min(keep, cur))
    return lvl


class Hub:
    def __init__(self):
        self.c = None; self.keys = {}; self.level = None; self.lock = asyncio.Lock()

    async def connect(self):
        c = APIClient(HOST, 6053, None, noise_psk=KEY)

        async def on_stop(expected_disconnect=False):
            if self.c is c:
                log.warning("lost connection to ESP")
                self.c = None

        await asyncio.wait_for(c.connect(on_stop=on_stop, login=True), 15)
        ents, _ = await c.list_entities_services()
        # ESPHome buttons are matched by the command number in their name, e.g. "Coolmoon 04 speed +"
        bynum = {}
        for e in ents:
            m = re.search(r"\b(\d{2})\b", e.name)
            if type(e).__name__ == "ButtonInfo" and m:
                bynum[int(m.group(1))] = e.key
        self.keys = {name: bynum[n] for name, n in CMD.items() if n in bynum}
        missing = [n for n in ("on", "speed +", "speed -") if n not in self.keys]
        if missing:
            raise RuntimeError(f"ESPHome device has no buttons {missing} (names must contain the command number, e.g. '04')")
        self.c = c
        log.info("ESP connected")

    async def press(self, name, n=1):
        # lock per single press, so lighting presses can slip in between speed presses
        for _ in range(n):
            async with self.lock:
                if self.c is None:
                    raise ConnectionError("no connection to ESP")
                self.c.button_command(self.keys[name]); await asyncio.sleep(GAP)

    async def home(self, target):
        await self.press("on")
        await self.press("speed -", 4)
        await self.press("speed +", target)
        self.level = target

    async def set(self, target):
        if self.level is None:
            return await self.home(target)
        d = target - self.level
        if d: await self.press("speed +" if d > 0 else "speed -", abs(d))
        if target in (0, 3):  # push against the end stop to be sure
            await self.press("speed +" if target == 3 else "speed -")
        self.level = target


class Controller:
    # reason codes (translated by the widget): gpu, cpu, nvme, gpu_fan, cool, cooling, manual, nodata
    def __init__(self):
        self.cfg = load_cfg()
        self.hub = Hub()
        self.want = 0
        self.below_since = None
        self.reason = ""
        self.temps = {}
        self.esp_ok = False
        self.esp_lost_at = None
        self.history = collections.deque()          # (ts, level, gpu, cpu, nvme)
        self.time_in = [0.0, 0.0, 0.0, 0.0]          # seconds on each speed today
        self.day = time.strftime("%Y-%m-%d")
        self.changes_today = 0
        self.last_tick = time.time()
        self.wake = asyncio.Event()
        self.samples = {k: collections.deque(maxlen=SMOOTH) for k in ("cpu", "gpu", "nvme")}
        self.changed_at = 0.0
        self.fresh = False

    def state(self):
        return {"level": self.hub.level, "target": self.want, "esp": self.esp_ok and self.hub.c is not None,
                "esp_lost_at": self.esp_lost_at, "reason": self.reason,
                "temps": self.temps, "cfg": self.cfg, "presets": PRESETS,
                "time_in": [round(x) for x in self.time_in], "changes_today": self.changes_today,
                "history": [list(h) for h in self.history][::5]}   # one point per ~10 s

    def apply_cfg(self, new):
        cfg = self.cfg
        if (new.get("mode") == "auto" and cfg["mode"] != "auto") or "preset" in new or "thresholds" in new:
            self.fresh = True   # mode or thresholds changed — re-evaluate right away, no hysteresis
        for k in ("mode", "manual_level", "preset", "gpu_fan_rule"):
            if k in new: cfg[k] = new[k]
        if "thresholds" in new:
            cfg["thresholds"] = new["thresholds"]; cfg["preset"] = "custom"
        elif cfg["preset"] in PRESETS:
            cfg["thresholds"] = json.loads(json.dumps(PRESETS[cfg["preset"]]))
        cfg["manual_level"] = max(0, min(3, int(cfg["manual_level"])))
        save_cfg(cfg)
        self.below_since = None
        self.wake.set()
        log.info(f"settings: {cfg['mode']} preset={cfg['preset']} manual={cfg['manual_level']}")

    def decide(self):
        raw = {"cpu": cpu_temp(), "nvme": hwmon_temp("nvme")}
        raw["gpu"], gfan = gpu_state()
        for k, v in raw.items():
            if v is not None: self.samples[k].append(v)
        avg = {k: (round(sum(d) / len(d), 1) if d and raw[k] is not None else None) for k, d in self.samples.items()}
        c, g, n = avg["cpu"], avg["gpu"], avg["nvme"]
        self.temps = {"cpu": c, "gpu": g, "gpu_fan": gfan, "nvme": n}
        cfg, th = self.cfg, self.cfg["thresholds"]
        if cfg["mode"] == "manual":
            self.reason = "manual"
            self.below_since = None
            return cfg["manual_level"]
        if c is None or (g is None and n is None):
            self.reason = "nodata"
            return 3
        cur = 0 if self.fresh else self.want
        cand = {"cpu": level_for(c, th["cpu"], cur)}
        if g is not None: cand["gpu"] = level_for(g, th["gpu"], cur)
        if n is not None: cand["nvme"] = level_for(n, th["nvme"], cur)
        if cfg["gpu_fan_rule"] and gfan and g is not None and g >= GPU_FAN_MIN_T:
            cand["gpu_fan"] = 1
        src, new = max(cand.items(), key=lambda kv: kv[1])
        if self.fresh:
            self.fresh = False
            self.below_since = None
            self.reason = src if new else "cool"
            return new
        if new > self.want:
            self.below_since = None
            self.reason = src
            return new
        if new < self.want:
            self.reason = "cooling"
            if time.monotonic() - self.changed_at < MIN_DWELL:
                return self.want
            self.below_since = self.below_since or time.monotonic()
            if time.monotonic() - self.below_since >= DOWN_HOLD:
                self.below_since = None
                self.reason = src if new else "cool"
                return new
            return self.want
        self.below_since = None
        if self.reason in ("", "manual", "cooling", "nodata"):
            self.reason = src if new else "cool"
        return new

    def account(self):
        now = time.time()
        today = time.strftime("%Y-%m-%d")
        if today != self.day:
            self.day, self.time_in, self.changes_today = today, [0.0] * 4, 0
        if self.hub.level is not None:
            self.time_in[self.hub.level] += now - self.last_tick
        self.last_tick = now
        t = self.temps
        self.history.append((round(now), self.hub.level, t.get("gpu"), t.get("cpu"), t.get("nvme")))
        while self.history and self.history[0][0] < now - HISTORY_SEC:
            self.history.popleft()

    async def run(self):
        last_edge = last_mid = time.monotonic()
        while True:
            try:
                if self.hub.c is None:
                    if not KEY:
                        raise RuntimeError("FANCTL_KEY is not set (ESPHome api.encryption.key)")
                    await self.hub.connect(); self.hub.level = None
                self.esp_ok = True
                if self.esp_lost_at:
                    log.info(f"ESP connection restored after {round(time.time() - self.esp_lost_at)} s")
                self.esp_lost_at = None
                self.want = self.decide()
                now = time.monotonic()
                if self.hub.level != self.want:
                    t = self.temps
                    log.info(f"CPU {t['cpu']} GPU {t['gpu']} (fan {t['gpu_fan']}%) NVMe {t['nvme']} -> speed {self.want} ({self.reason})")
                    if self.hub.level is not None: self.changes_today += 1
                    await self.hub.set(self.want)
                    self.changed_at = time.monotonic()
                    last_edge = last_mid = now
                elif self.want in (0, 3) and now - last_edge > RESYNC_EDGE:
                    await self.hub.press("on"); await self.hub.set(self.want); last_edge = now
                elif self.want in (1, 2) and now - last_mid > RESYNC_MID:
                    await self.hub.home(self.want); last_mid = now
            except Exception as e:
                log.warning(f"error: {e!r}, reconnecting")
                self.esp_ok = False
                self.esp_lost_at = self.esp_lost_at or time.time()
                try: await self.hub.c.disconnect()
                except Exception: pass
                self.hub.c = None
                await asyncio.sleep(10)
            self.account()
            self.wake.clear()
            try:
                await asyncio.wait_for(self.wake.wait(), POLL)
            except asyncio.TimeoutError:
                pass

    async def http(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 5)
            lines = head.decode(errors="ignore").split("\r\n")
            method, path = lines[0].split(" ")[:2]
            length = next((int(l.split(":")[1]) for l in lines if l.lower().startswith("content-length:")), 0)
            body = await reader.readexactly(length) if length else b""
            code, out = 200, None
            if method == "GET" and path.startswith("/state"):
                out = self.state()
            elif method == "POST" and path.startswith("/config"):
                self.apply_cfg(json.loads(body or b"{}")); out = self.state()
            elif method == "POST" and path.startswith("/press"):
                name = json.loads(body or b"{}").get("name", "")
                if self.hub.c is None:
                    code, out = 503, {"error": "no connection to ESP32"}
                elif name not in LIGHT_BUTTONS or name not in self.hub.keys:
                    code, out = 400, {"error": "unknown button"}
                else:
                    asyncio.create_task(self.hub.press(name, 2 if name in IDEMPOTENT else 1))
                    out = {"ok": True}
            elif method == "OPTIONS":
                out = {}
            else:
                code, out = 404, {"error": "not found"}
            data = json.dumps(out, ensure_ascii=False).encode()
            writer.write(f"HTTP/1.1 {code} OK\r\nContent-Type: application/json; charset=utf-8\r\n"
                         f"Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\n"
                         f"Content-Length: {len(data)}\r\nConnection: close\r\n\r\n".encode() + data)
            await writer.drain()
        except Exception as e:
            log.warning(f"http: {e!r}")
        finally:
            writer.close()


async def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ctl = Controller()
    await asyncio.start_server(ctl.http, "127.0.0.1", HTTP_PORT)
    await ctl.run()

asyncio.run(main())
