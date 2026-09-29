#!/usr/bin/env python3
"""Lokales Dashboard für eine FENECON-FEMS-Anlage (OpenEMS).

Der Server fragt die REST/JSON-API des FEMS regelmäßig ab, speichert die Werte
in einer SQLite-Datenbank und liefert eine Webseite samt JSON-API aus, die die
Daten grafisch darstellt. Nur die Python-Standardbibliothek wird benötigt.

    python3 server.py              # Server starten (Einstellungen aus config.json)
    python3 server.py --check      # Verbindung zum FEMS testen, Kanäle auflisten
    python3 server.py --demo       # ohne FEMS, mit simulierten Daten
"""

import argparse
import base64
import json
import math
import os
import random
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")

DEFAULTS = {
    "fems_url": "http://192.168.178.50",
    "username": "x",
    "password": "user",
    "poll_seconds": 5,
    "store_seconds": 60,
    "listen_host": "127.0.0.1",
    "listen_port": 8080,
    "database": "fems.sqlite",
    "timeout_seconds": 8,
    "demo": False,
}

# Leistungswerte (W) aus dem Summen-Component "_sum" des FEMS.
# Vorzeichen: Netz + = Bezug / - = Einspeisung, Batterie + = Entladen / - = Laden.
POWER_CHANNELS = {
    "production": ["ProductionActivePower"],
    "consumption": ["ConsumptionActivePower"],
    "grid": ["GridActivePower"],
    "ess": ["EssDischargePower", "EssActivePower"],
    "soc": ["EssSoc"],
}

# Zählerstände (Wh), steigen monoton.
ENERGY_CHANNELS = {
    "e_production": ["ProductionActiveEnergy"],
    "e_consumption": ["ConsumptionActiveEnergy"],
    "e_grid_buy": ["GridBuyActiveEnergy"],
    "e_grid_sell": ["GridSellActiveEnergy"],
    "e_ess_charge": ["EssDcChargeEnergy", "EssActiveChargeEnergy"],
    "e_ess_discharge": ["EssDcDischargeEnergy", "EssActiveDischargeEnergy"],
}

# Energieflüsse pro Tag; Zähler und die aus der Leistung integrierten Werte.
FLOWS = {
    "production": "e_production",
    "consumption": "e_consumption",
    "grid_buy": "e_grid_buy",
    "grid_sell": "e_grid_sell",
    "ess_charge": "e_ess_charge",
    "ess_discharge": "e_ess_discharge",
}

COLUMNS = list(POWER_CHANNELS) + list(ENERGY_CHANNELS) + ["i_" + f for f in FLOWS]


def load_config(path):
    cfg = dict(DEFAULTS)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            cfg.update(json.load(fh))
    for key in DEFAULTS:
        env = os.environ.get("FEMS_" + key.upper())
        if env is not None:
            cfg[key] = type(DEFAULTS[key])(env) if not isinstance(DEFAULTS[key], bool) \
                else env.lower() in ("1", "true", "yes", "ja")
    return cfg


# --------------------------------------------------------------------------
# FEMS-Zugriff
# --------------------------------------------------------------------------

class FemsClient:
    """Liest Kanäle über die OpenEMS-REST-API: GET /rest/channel/<component>/<channel>."""

    def __init__(self, base_url, username, password, timeout):
        self.base = base_url.rstrip("/")
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.headers = {"Authorization": "Basic " + token, "Accept": "application/json"}
        self.timeout = timeout

    def channels(self, address):
        """Liefert {"_sum/EssSoc": 57, ...}; address darf Regex enthalten ("_sum/.*")."""
        url = self.base + "/rest/channel/" + urllib.parse.quote(address, safe="/.*|()")
        req = urllib.request.Request(url, headers=self.headers)
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        items = data if isinstance(data, list) else [data]
        return {it["address"]: it.get("value") for it in items if "address" in it}

    def read_sample(self):
        values = self.channels("_sum/.*")
        sample = {}
        for key, names in {**POWER_CHANNELS, **ENERGY_CHANNELS}.items():
            sample[key] = None
            for name in names:
                v = values.get("_sum/" + name)
                if v is not None:
                    sample[key] = float(v)
                    break
        return sample


class DemoClient:
    """Simuliert eine Anlage mit ca. 10 kWp PV und 10 kWh Speicher."""

    PEAK_W = 9000
    CAPACITY_WH = 10000
    MAX_ESS_W = 5000

    def __init__(self):
        self.soc_wh = 5000.0
        self.counters = {k: 1_000_000.0 for k in ENERGY_CHANNELS}
        self.last = None
        self.cloud = 1.0

    def step(self, ts, dt):
        t = datetime.fromtimestamp(ts)
        hour = t.hour + t.minute / 60 + t.second / 3600
        season = 0.55 + 0.45 * math.cos((t.timetuple().tm_yday - 172) / 365 * 2 * math.pi)
        day_len = 8 + 8 * season
        sunrise = 13.2 - day_len / 2
        x = (hour - sunrise) / day_len
        sun = math.sin(math.pi * x) ** 1.5 if 0 < x < 1 else 0.0
        self.cloud = min(1.0, max(0.25, self.cloud + random.uniform(-0.04, 0.04)))
        # Tägliche Grundbewölkung, damit sich die Tage unterscheiden.
        day_factor = 0.45 + 0.55 * random.Random(t.toordinal()).random()
        production = self.PEAK_W * season * sun * self.cloud * day_factor

        base = 350 + 150 * math.sin(hour / 24 * 2 * math.pi)
        if 6.5 < hour < 8 or 17.5 < hour < 21.5:
            base += 900
        if random.random() < 0.03:
            base += random.choice([1500, 2200, 3500])
        consumption = base + random.uniform(-60, 60)

        surplus = production - consumption
        if surplus > 0:  # laden
            room = (self.CAPACITY_WH - self.soc_wh) * 3600 / dt
            ess = -min(surplus, self.MAX_ESS_W, room)
        else:  # entladen
            avail = (self.soc_wh - 0.05 * self.CAPACITY_WH) * 3600 / dt
            ess = min(-surplus, self.MAX_ESS_W, max(0.0, avail))
        self.soc_wh -= ess * dt / 3600
        grid = consumption - production - ess

        wh = dt / 3600
        c = self.counters
        c["e_production"] += production * wh
        c["e_consumption"] += consumption * wh
        c["e_grid_buy"] += max(grid, 0) * wh
        c["e_grid_sell"] += max(-grid, 0) * wh
        c["e_ess_charge"] += max(-ess, 0) * wh
        c["e_ess_discharge"] += max(ess, 0) * wh
        return {
            "production": round(production),
            "consumption": round(consumption),
            "grid": round(grid),
            "ess": round(ess),
            "soc": round(self.soc_wh / self.CAPACITY_WH * 100),
            **{k: round(v, 1) for k, v in c.items()},
        }

    def read_sample(self):
        now = time.time()
        dt = 5 if self.last is None else max(1.0, now - self.last)
        self.last = now
        return self.step(now, dt)


# --------------------------------------------------------------------------
# Speicherung
# --------------------------------------------------------------------------

class Store:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        with self.connect() as db:
            cols = ", ".join(f"{c} REAL" for c in COLUMNS)
            db.execute(f"CREATE TABLE IF NOT EXISTS samples (ts INTEGER PRIMARY KEY, dt REAL, {cols})")

    def connect(self):
        return sqlite3.connect(self.path)

    def insert(self, rows):
        names = ["ts", "dt"] + COLUMNS
        sql = f"INSERT OR REPLACE INTO samples ({', '.join(names)}) VALUES ({', '.join('?' * len(names))})"
        with self.lock, self.connect() as db:
            db.executemany(sql, [[r.get(n) for n in names] for r in rows])

    def is_empty(self):
        with self.connect() as db:
            return db.execute("SELECT COUNT(*) FROM samples").fetchone()[0] == 0

    def series(self, start, end, max_points=720):
        """Leistungsverlauf zwischen start und end (Unix-Zeit), ggf. verdichtet."""
        span = max(1, end - start)
        bucket = max(60, int(math.ceil(span / max_points / 60.0)) * 60)
        with self.connect() as db:
            rows = db.execute(
                """SELECT (ts / ?) * ?, AVG(production), AVG(consumption), AVG(grid), AVG(ess), AVG(soc)
                   FROM samples WHERE ts >= ? AND ts < ? GROUP BY ts / ? ORDER BY 1""",
                (bucket, bucket, start, end, bucket),
            ).fetchall()
        keys = ["ts", "production", "consumption", "grid", "ess", "soc"]
        return {"bucket_seconds": bucket,
                "points": [dict(zip(keys, [r[0]] + [None if v is None else round(v, 1) for v in r[1:]]))
                           for r in rows]}

    def daily_energy(self, first, last):
        """Energie (Wh) je Kalendertag. Zählerdifferenz, sonst integrierte Leistung."""
        parts = []
        for flow, counter in FLOWS.items():
            parts.append(f"MIN({counter}), MAX({counter}), COUNT({counter}), SUM(i_{flow})")
        with self.connect() as db:
            rows = db.execute(
                f"""SELECT date(ts, 'unixepoch', 'localtime') AS d, COUNT(*), {', '.join(parts)}
                    FROM samples WHERE d >= ? AND d <= ? GROUP BY d ORDER BY d""",
                (first.isoformat(), last.isoformat()),
            ).fetchall()
        result = []
        for row in rows:
            day = {"date": row[0], "samples": row[1]}
            for i, flow in enumerate(FLOWS):
                lo, hi, n, integ = row[2 + 4 * i: 6 + 4 * i]
                if n and n >= row[1] * 0.9 and hi is not None and hi >= lo:
                    day[flow] = round(hi - lo, 1)
                else:
                    day[flow] = round(integ or 0.0, 1)
            result.append(day)
        return result


def add_ratios(entry):
    cons, prod = entry.get("consumption") or 0, entry.get("production") or 0
    buy, sell = entry.get("grid_buy") or 0, entry.get("grid_sell") or 0
    entry["autarky"] = round(max(0.0, 1 - buy / cons) * 100, 1) if cons > 0 else None
    entry["self_consumption"] = round(max(0.0, 1 - sell / prod) * 100, 1) if prod > 0 else None
    return entry


def rollup(days, group):
    if group == "day":
        return [add_ratios(d) for d in days]
    width = 7 if group == "month" else 4
    out = {}
    for d in days:
        key = d["date"][:width]
        agg = out.setdefault(key, {"date": key, "samples": 0, **{f: 0.0 for f in FLOWS}})
        agg["samples"] += d["samples"]
        for f in FLOWS:
            agg[f] = round(agg[f] + d[f], 1)
    return [add_ratios(v) for v in out.values()]


# --------------------------------------------------------------------------
# Abfrage-Schleife
# --------------------------------------------------------------------------

class Poller(threading.Thread):
    def __init__(self, client, store, poll_seconds, store_seconds):
        super().__init__(daemon=True)
        self.client, self.store = client, store
        self.poll, self.store_every = poll_seconds, store_seconds
        self.live = {"ok": False, "ts": None, "error": "Noch keine Daten", "values": {}}
        self.buffer = []
        self.integrals = {f: 0.0 for f in FLOWS}
        self.prev = None
        self.bucket_start = None

    def integrate(self, sample, dt):
        wh = dt / 3600
        g, e = sample.get("grid"), sample.get("ess")
        pos = lambda v: max(v, 0) if v is not None else 0.0
        self.integrals["production"] += pos(sample.get("production")) * wh
        self.integrals["consumption"] += pos(sample.get("consumption")) * wh
        self.integrals["grid_buy"] += pos(g) * wh
        self.integrals["grid_sell"] += pos(-g if g is not None else None) * wh
        self.integrals["ess_charge"] += pos(-e if e is not None else None) * wh
        self.integrals["ess_discharge"] += pos(e) * wh

    def flush(self, now):
        if not self.buffer:
            return
        row = {"ts": int(self.bucket_start), "dt": now - self.bucket_start}
        for key in POWER_CHANNELS:
            vals = [s[key] for s in self.buffer if s.get(key) is not None]
            row[key] = sum(vals) / len(vals) if vals else None
        for key in ENERGY_CHANNELS:
            row[key] = self.buffer[-1].get(key)
        for flow, v in self.integrals.items():
            row["i_" + flow] = v
        self.store.insert([row])
        self.buffer = []
        self.integrals = {f: 0.0 for f in FLOWS}

    def run(self):
        while True:
            started = time.time()
            try:
                sample = self.client.read_sample()
                now = time.time()
                if self.bucket_start is None:
                    self.bucket_start = now
                dt = min(now - self.prev, 3 * self.poll) if self.prev else self.poll
                self.prev = now
                self.integrate(sample, dt)
                self.buffer.append(sample)
                self.live = {"ok": True, "ts": int(now), "error": None, "values": sample}
                # Jeweils zur vollen Minute (bzw. store_seconds) einen Datensatz schreiben.
                if int(now) // self.store_every != int(self.bucket_start) // self.store_every:
                    self.flush(now)
                    self.bucket_start = now
            except Exception as exc:  # Netzwerkfehler, Auth, ungültige Antwort ...
                self.live = {**self.live, "ok": False, "error": describe_error(exc)}
                self.prev = None
            time.sleep(max(0.5, self.poll - (time.time() - started)))


def describe_error(exc):
    if isinstance(exc, urllib.error.HTTPError):
        if exc.code == 401:
            return "HTTP 401: Benutzer/Passwort falsch (Standard: x / user)"
        if exc.code == 404:
            return "HTTP 404: REST-API nicht gefunden – ist die App 'REST/JSON Lesezugriff' aktiv? Port 80 oder 8084 probieren."
        return f"HTTP {exc.code}: {exc.reason}"
    if isinstance(exc, urllib.error.URLError):
        return f"FEMS nicht erreichbar: {exc.reason}"
    return f"{type(exc).__name__}: {exc}"


def backfill_demo(store, days):
    """Füllt eine leere Demo-Datenbank mit simulierten Minutenwerten."""
    sim = DemoClient()
    random.seed(42)
    start = int(time.time()) // 60 * 60 - days * 86400
    rows = []
    for ts in range(start, int(time.time()) - 60, 60):
        s = sim.step(ts, 60)
        row = {"ts": ts, "dt": 60, **s}
        row["i_production"] = max(s["production"], 0) / 60
        row["i_consumption"] = max(s["consumption"], 0) / 60
        row["i_grid_buy"] = max(s["grid"], 0) / 60
        row["i_grid_sell"] = max(-s["grid"], 0) / 60
        row["i_ess_charge"] = max(-s["ess"], 0) / 60
        row["i_ess_discharge"] = max(s["ess"], 0) / 60
        rows.append(row)
    store.insert(rows)
    return sim


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def parse_day(text, fallback):
    try:
        return date.fromisoformat(text)
    except (TypeError, ValueError):
        return fallback


def day_bounds(d):
    start = datetime(d.year, d.month, d.day)
    return int(start.timestamp()), int((start + timedelta(days=1)).timestamp())


def make_handler(app):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=STATIC, **kwargs)

        def log_message(self, fmt, *args):
            pass

        def send_json(self, payload, status=200):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
            routes = {"/api/live": self.api_live, "/api/history": self.api_history,
                      "/api/energy": self.api_energy, "/api/channels": self.api_channels}
            if url.path in routes:
                try:
                    return routes[url.path](q)
                except Exception as exc:
                    return self.send_json({"error": describe_error(exc)}, 500)
            return super().do_GET()

        def api_live(self, q):
            today = date.today()
            days = app.store.daily_energy(today, today)
            self.send_json({**app.poller.live, "demo": app.demo, "poll_seconds": app.cfg["poll_seconds"],
                            "today": add_ratios(days[0]) if days else None})

        def api_history(self, q):
            d = parse_day(q.get("date"), date.today())
            span = max(1, min(31, int(q.get("days", 1))))
            start, _ = day_bounds(d)
            _, end = day_bounds(d + timedelta(days=span - 1))
            self.send_json({"date": d.isoformat(), "days": span, **app.store.series(start, end)})

        def api_energy(self, q):
            group = q.get("group", "day")
            if group not in ("day", "month", "year"):
                group = "day"
            last = parse_day(q.get("to"), date.today())
            default_first = {"day": last - timedelta(days=29),
                             "month": date(last.year, 1, 1),
                             "year": date(last.year - 9, 1, 1)}[group]
            first = parse_day(q.get("from"), default_first)
            self.send_json({"group": group, "from": first.isoformat(), "to": last.isoformat(),
                            "rows": rollup(app.store.daily_energy(first, last), group)})

        def api_channels(self, q):
            if app.demo:
                return self.send_json({"_sum/" + k: v for k, v in app.poller.live["values"].items()})
            self.send_json(app.client.channels(q.get("address", "_sum/.*")))

    return Handler


class App:
    def __init__(self, cfg):
        self.cfg = cfg
        self.demo = bool(cfg["demo"])
        db = cfg["database"]
        if self.demo and db == DEFAULTS["database"]:
            db = "demo.sqlite"
        self.store = Store(db if os.path.isabs(db) else os.path.join(HERE, db))
        if self.demo:
            self.client = DemoClient()
            if self.store.is_empty():
                print("Erzeuge 60 Tage Demo-Daten …")
                self.client = backfill_demo(self.store, 60)
                self.client.last = time.time() - cfg["poll_seconds"]
        else:
            self.client = FemsClient(cfg["fems_url"], cfg["username"], cfg["password"], cfg["timeout_seconds"])
        self.poller = Poller(self.client, self.store, cfg["poll_seconds"], cfg["store_seconds"])


def check(cfg):
    client = FemsClient(cfg["fems_url"], cfg["username"], cfg["password"], cfg["timeout_seconds"])
    print(f"Frage {client.base}/rest/channel/_sum/.* ab …")
    try:
        values = client.channels("_sum/.*")
    except Exception as exc:
        print("Fehler:", describe_error(exc))
        return 1
    for address in sorted(values):
        print(f"  {address:45} {values[address]}")
    sample = client.read_sample()
    missing = [k for k, v in sample.items() if v is None]
    print("\nVerbindung OK.", f"Nicht gefunden: {', '.join(missing)}" if missing else "Alle Kanäle vorhanden.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Lokales FEMS-Dashboard")
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--demo", action="store_true", help="simulierte Daten statt FEMS")
    ap.add_argument("--check", action="store_true", help="Verbindung testen und Kanäle auflisten")
    ap.add_argument("--port", type=int)
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.demo:
        cfg["demo"] = True
    if args.port:
        cfg["listen_port"] = args.port
    if args.check:
        return check(cfg)

    app = App(cfg)
    app.poller.start()
    server = ThreadingHTTPServer((cfg["listen_host"], cfg["listen_port"]), make_handler(app))
    src = "Demo-Modus" if app.demo else cfg["fems_url"]
    print(f"FEMS-Dashboard ({src}) läuft auf http://{cfg['listen_host']}:{cfg['listen_port']}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        app.poller.flush(time.time())
        print("\nBeendet.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
