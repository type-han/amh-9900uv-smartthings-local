"""로컬 3.4로 상태만 조회한다 (쓰기 없음).
사용: python tools/local_status.py [--id DeviceID] [--ip IP] [--devices secrets/devices.json]
"""
import argparse
import json
import time
import warnings

warnings.filterwarnings("ignore")
import tinytuya  # noqa: E402
from tuya_dev import load_device  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--id")
ap.add_argument("--ip")
ap.add_argument("--devices")
a = ap.parse_args()
d = load_device(a.id, a.devices)
t = time.time()
dev = tinytuya.Device(d["id"], a.ip or d["ip"], d["key"], version=float(d["version"]))
dev.set_socketTimeout(5)
st = dev.status()
print("elapsed %.2fs" % (time.time() - t))
print(json.dumps(st, ensure_ascii=False))
dev.close()
