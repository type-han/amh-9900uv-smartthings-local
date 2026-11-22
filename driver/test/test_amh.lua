-- 오프라인 단위 테스트: DP ↔ SmartThings 매핑과 안전 검사
-- 실행 (driver/ 에서): lua5.3 test/test_amh.lua
package.path = "src/?.lua;" .. package.path
local amh = require "amh"

local pass, fail = 0, 0
local function eq(name, got, want)
  local function s(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local p = {}
    for _, k in ipairs(keys) do p[#p + 1] = k .. "=" .. s(v[k] == nil and v[tonumber(k)] or v[k]) end
    return "{" .. table.concat(p, ",") .. "}"
  end
  if s(got) == s(want) then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. ": got " .. s(got) .. " want " .. s(want)) end
end
local function by_comp(list)
  local t = {}
  for _, u in ipairs(list) do t[u.component .. ":" .. u.kind] = u.value end
  return t
end

local full = { ["1"] = true, ["13"] = 60, ["14"] = 58, ["16"] = false, ["19"] = "cancel", ["21"] = true,
               ["23"] = "level_3", ["26"] = true, ["29"] = false, ["101"] = false }
eq("full state", by_comp(amh.updates(full, full)), {
  ["main:switch"] = "on", ["humidityTarget:mode"] = "60%", ["main:humidity"] = 58, ["sleep:switch"] = "off",
  ["sterilize:switch"] = "on", ["mist:mode"] = "3단계", ["heat:switch"] = "on", ["childLock:switch"] = "off" })

local st = {}
for k, v in pairs(full) do st[k] = v end
st["101"] = true; st["13"] = 100
eq("auto on push", by_comp(amh.updates({ ["101"] = true, ["13"] = 100 }, st)),
   { ["mist:mode"] = "자동", ["humidityTarget:mode"] = "100%" })
st["101"] = false; st["23"] = "level_1"
eq("auto off + level", by_comp(amh.updates({ ["101"] = false, ["23"] = "level_1" }, st)), { ["mist:mode"] = "1단계" })
eq("timer ignored", by_comp(amh.updates({ ["19"] = "2h" }, st)), {})

-- 명령
eq("mist auto", amh.mist_command("자동", { ["101"] = false }), { ["101"] = true })
eq("mist level manual", amh.mist_command("2단계", { ["101"] = false }), { ["23"] = "level_2" })
eq("mist level from auto", amh.mist_command("1단계", { ["101"] = true }), { ["101"] = false, ["23"] = "level_1" })
eq("mist unknown", amh.mist_command("취침", {}), nil)
eq("target 65%", amh.target_command("65%"), { ["13"] = 65 })
eq("target 100%", amh.target_command("100%"), { ["13"] = 100 })
eq("target 40% refused", amh.target_command("40%"), nil)
eq("target 63% refused", amh.target_command("63%"), nil)
eq("modes count", #amh.TARGET_MODES, 12)

-- 안전 검사
eq("safe ok", amh.is_safe({ ["1"] = true, ["23"] = "level_2", ["13"] = 45 }), true)
eq("unsafe timer", (amh.is_safe({ ["19"] = "1h" })), nil)
eq("unsafe level", (amh.is_safe({ ["23"] = "level_4" })), nil)
eq("unsafe humidity", (amh.is_safe({ ["13"] = 40 })), nil)
eq("unsafe type", (amh.is_safe({ ["1"] = 1 })), nil)

-- 설정 검사
local ip, id, key = amh.check_prefs({ ipAddress = " 192.168.0.9 ", deviceId = "ebxxxxxxxxxxxxxxxxxxxx", localKey = "0123456789abcdef" })
eq("prefs ok", { ip, id, key }, { "192.168.0.9", "ebxxxxxxxxxxxxxxxxxxxx", "0123456789abcdef" })
eq("prefs short key", (amh.check_prefs({ ipAddress = "1.2.3.4", deviceId = "ebxxxxxxxxxxxxxxxxxxxx", localKey = "abc" })), nil)
eq("prefs empty", (amh.check_prefs({})), nil)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
