"""로컬 3.4 쓰기 테스트. 앱에서 쓰는 값만 허용(SAFE)하고, 한 번에 하나씩 보내며 push를 기록한다.
끝나면 시작 때 상태로 되돌린다. 가습기가 켜져 있을 때 실행하세요 (각 기능이 잠깐씩 바뀝니다).

사용: python tools/write_test.py [--id DeviceID] [--ip IP]
로그: logs/write_test_<날짜>.log
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
# 앱에서 실제로 쓰는 값만 (docs/03_PROTOCOL.md). 타이머(19)는 테스트하지 않음.
SAFE = {
    1: {True, False},
    13: set(range(45, 101, 5)),
    16: {True, False},
    21: {True, False},
    23: {"level_1", "level_2", "level_3"},
    26: {True, False},
    29: {True, False},
    101: {True, False},
}
WAIT = 3.0  # 각 쓰기 후 push를 받는 시간

ap = argparse.ArgumentParser()
ap.add_argument("--id")
ap.add_argument("--ip")
ap.add_argument("--devices")
a = ap.parse_args()
d = load_device(a.id, a.devices)
log = open(log_path("write_test"), "a", encoding="utf-8")


def out(msg):
    line = "%s %s" % (datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3], msg)
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()


dev = tinytuya.Device(d["id"], a.ip or d["ip"], d["key"], version=float(d["version"]), persist=True)
dev.set_socketTimeout(1)
state = dict(dev.status()["dps"])
start = dict(state)
out("=== write test start; state %s" % json.dumps(start, ensure_ascii=False))
if start.get("1") is not True:
    raise SystemExit("가습기를 켠 상태에서 실행하세요 (앱은 꺼진 상태에서 조작을 막습니다).")


def collect(sec, t0):
    changes, first = [], None
    end = time.time() + sec
    while time.time() < end:
        data = dev.receive()
        if not data or "Error" in data:
            continue
        for k, v in (data.get("dps") or {}).items():
            if k == "14":
                state[k] = v
                continue
            if state.get(k) != v:
                if first is None:
                    first = time.time() - t0
                changes.append("%s(%s) %s->%s" % (NAMES.get(k, "?"), k, json.dumps(state.get(k)), json.dumps(v)))
                state[k] = v
    return changes, first


def write(dp, value, note=""):
    if value not in SAFE.get(dp, ()):
        raise SystemExit("REFUSED: dp %s value %r is not in SAFE" % (dp, value))
    t0 = time.time()
    dev.set_value(dp, value, nowait=True)
    changes, first = collect(WAIT, t0)
    lat = ("%.0fms" % (first * 1000)) if first is not None else "-"
    out("SET %s(%s)=%s %s| push %s | %s" % (NAMES[str(dp)], dp, json.dumps(value), ("[%s] " % note) if note else "",
                                             lat, " , ".join(changes) or "(변화 없음)"))


def write_multi(dps, note=""):
    for k, v in dps.items():
        if v not in SAFE.get(int(k), ()):
            raise SystemExit("REFUSED: %r" % dps)
    t0 = time.time()
    dev.set_multiple_values(dps, nowait=True)
    changes, first = collect(WAIT, t0)
    out("SET_MULTI %s [%s] | %s" % (json.dumps(dps), note, " , ".join(changes) or "(변화 없음)"))


try:
    t13 = 65 if start["13"] != 65 else 70
    write(13, t13); write(13, start["13"])
    other = "level_3" if start["23"] != "level_3" else "level_1"
    write(23, other); write(23, start["23"])
    for dp in (26, 21, 16, 29):
        cur = start[str(dp)]
        write(dp, not cur); write(dp, cur)
    # 자동 모드와 단계
    if start["101"] is False:
        write(101, True, "자동 켜기 (목표 습도가 100으로 바뀌는지)")
        write(23, other, "자동 중 다른 단계 (자동이 유지되는지)")
        if state.get("101"):
            write_multi({"101": False, "23": start["23"]}, "자동 해제 + 단계를 한 메시지로")
finally:
    time.sleep(1)
    for k in ("13", "23", "26", "21", "16", "29", "101"):
        if state.get(k) != start[k]:
            write(int(k), start[k], "복원")
    final = dict(dev.status()["dps"])
    diff = {k: (start[k], final.get(k)) for k in start if k != "14" and start[k] != final.get(k)}
    out("=== end; diff from start %s" % (json.dumps(diff, ensure_ascii=False) if diff else "없음"))
    dev.close()
