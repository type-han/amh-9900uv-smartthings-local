"""tools/ 스크립트 공용: tinytuya wizard가 만든 devices.json에서 가습기 정보를 읽는다.

기본 위치는 레포의 secrets/devices.json (git에서 제외됨).
--id를 주지 않으면 AMH-9900UV(productKey 7f3qvffhri6hox6t)나 가습기 분류(jsq) 기기가 하나일 때 그것을 고른다.
local_key는 화면에 출력하지 않는다.
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFAULT_DEVICES = os.path.join(ROOT, "secrets", "devices.json")
AMH_PRODUCT_KEY = "7f3qvffhri6hox6t"


def load_device(dev_id=None, path=None):
    path = path or DEFAULT_DEVICES
    if not os.path.exists(path):
        raise SystemExit("devices.json not found: %s (docs/01_LOCAL_KEY.md 참고)" % path)
    devs = json.load(open(path, encoding="utf-8"))
    if dev_id:
        found = [d for d in devs if d.get("id") == dev_id]
    else:
        found = [d for d in devs if d.get("product_id") == AMH_PRODUCT_KEY] or \
                [d for d in devs if d.get("category") == "jsq"]
    if len(found) != 1:
        names = ", ".join("%s (%s)" % (d.get("name"), d.get("id")) for d in devs)
        raise SystemExit("기기를 하나로 정할 수 없습니다. --id <DeviceID>로 지정하세요. devices.json: " + names)
    d = found[0]
    if not d.get("ip"):
        raise SystemExit("devices.json에 %s의 IP가 없습니다. wizard에서 로컬 스캔을 Y로 하거나 --ip로 지정하세요." % d["id"])
    if not d.get("key") or not d.get("version"):
        raise SystemExit("devices.json에 %s의 key 또는 version이 없습니다." % d["id"])
    return d


def log_path(name):
    import datetime
    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    return os.path.join(ROOT, "logs", "%s_%s.log" % (name, datetime.date.today().strftime("%Y%m%d")))
