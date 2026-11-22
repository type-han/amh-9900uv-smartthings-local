"""Tuya 클라우드에서 기기의 DP 사양(thing model)을 받아 표로 보여 준다.
tinytuya wizard를 실행한 폴더(tinytuya.json이 있는 곳, 보통 secrets/)에서 실행합니다.

사용: cd secrets && python ../tools/get_spec.py <DeviceID> [out.json]
- 이 제품은 표준 명령 세트(/functions)가 비어 있어서 thing model API를 쓴다.
"""
import json
import sys
import warnings

warnings.filterwarnings("ignore")
import tinytuya  # noqa: E402

if len(sys.argv) < 2:
    raise SystemExit(__doc__)
dev = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else "thing_model.json"
c = tinytuya.Cloud()
r = c.cloudrequest("/v2.0/cloud/thing/%s/model" % dev)
if not r.get("success"):
    raise SystemExit("cloud error: %s" % json.dumps(r, ensure_ascii=False))
model = json.loads(r["result"]["model"])
json.dump(model, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
for svc in model.get("services", []):
    for p in svc.get("properties", []):
        line = "%-4s %-20s %-3s %s | %s" % (p.get("abilityId"), p.get("code"), p.get("accessMode"),
                                            json.dumps(p.get("typeSpec"), ensure_ascii=False), p.get("name"))
        sys.stdout.buffer.write((line + "\n").encode("utf-8"))
print("saved", out)
