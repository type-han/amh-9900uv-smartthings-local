"""로컬 3.4 연결을 유지하며 기기가 보내는 DP 변화를 기록한다 (읽기 전용: 조회와 하트비트만 보냄).
앱이나 본체 버튼으로 조작하면서 돌리면 어떤 DP가 어떻게 바뀌는지 알 수 있다.

사용: python tools/monitor.py [분, 기본 30] [--id DeviceID] [--ip IP]
로그: logs/monitor_<날짜>.log  (Ctrl+C로 종료)
"""
import argparse
import datetime
import json
import time
import warnings

warnings.filterwarnings("ignore")
import tinytuya  # noqa: E402
from tuya_dev import load_device, log_path  # noqa: E402

NAMES = {"1": "전원", "13": "목표습도", "14": "현재습도", "16": "취침", "19": "타이머",
         "21": "살균", "23": "분무단계", "26": "가열", "29": "차일드락", "101": "자동"}
HEARTBEAT_SEC = 9

ap = argparse.ArgumentParser()
ap.add_argument("minutes", nargs="?", type=float, default=30)
ap.add_argument("--id")
ap.add_argument("--ip")
ap.add_argument("--devices")
a = ap.parse_args()
d = load_device(a.id, a.devices)
ip = a.ip or d["ip"]
path = log_path("monitor")
log = open(path, "a", encoding="utf-8")


def out(msg):
    line = "%s %s" % (datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3], msg)
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()


def connect():
    dev = tinytuya.Device(d["id"], ip, d["key"], version=float(d["version"]), persist=True)
    dev.set_socketTimeout(2)
    return dev


state = {}


def handle(data, src):
    if not data:
        return
    if "Error" in data:
        if str(data.get("Err")) != "902":  # 902 = 수신 대기 시간 초과 (정상)
            out("ERROR %s" % json.dumps(data, ensure_ascii=False))
        return
    dps = data.get("dps") or {}
    changes = []
    for k, v in dps.items():
        if state.get(k, object()) != v:
            changes.append("%s(%s): %s -> %s" % (NAMES.get(k, "?"), k, json.dumps(state.get(k), ensure_ascii=False),
                                                json.dumps(v, ensure_ascii=False)))
            state[k] = v
    if changes:
        out("[%s] " % src + " | ".join(changes))


out("=== monitor start (%.0f min), log %s" % (a.minutes, path))
end = time.time() + a.minutes * 60
dev = None
last_hb = 0
try:
    while time.time() < end:
        if dev is None:
            try:
                dev = connect()
                handle(dev.status(), "query")
                out("connected; full state: %s" % json.dumps(state, ensure_ascii=False))
                last_hb = time.time()
            except Exception as e:
                out("connect failed: %r, retry in 5s" % e)
                dev = None
                time.sleep(5)
                continue
        try:
            if time.time() - last_hb >= HEARTBEAT_SEC:
                dev.heartbeat(nowait=True)
                last_hb = time.time()
            handle(dev.receive(), "push")
        except Exception as e:
            out("connection lost: %r, reconnecting" % e)
            try:
                dev.close()
            except Exception:
                pass
            dev = None
except KeyboardInterrupt:
    pass
out("=== monitor end")
