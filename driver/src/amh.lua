-- AMH-9900UV DP ↔ SmartThings 매핑 (순수 함수, 허브 밖에서 테스트 가능)
-- 근거: docs/03_PROTOCOL.md (클라우드 thing model, 앱 조작 관찰, 로컬 쓰기 테스트)

local M = {}

M.LEVELS = { level_1 = "1단계", level_2 = "2단계", level_3 = "3단계" }
M.AUTO = "자동"
M.MIST_MODES = { "1단계", "2단계", "3단계", "자동" }
M.TARGET_MODES = {}
for v = 45, 100, 5 do M.TARGET_MODES[#M.TARGET_MODES + 1] = v .. "%" end

-- on/off 스위치 컴포넌트 → DP
M.SWITCH_DPS = { main = "1", heat = "26", sterilize = "21", sleep = "16", childLock = "29" }
local SWITCH_COMPONENT = {}
for comp, dp in pairs(M.SWITCH_DPS) do SWITCH_COMPONENT[dp] = comp end

-- 보내도 되는 값: 앱에서 실제로 쓰는 값만 (docs/03_PROTOCOL.md 3-3, docs/04_SAFETY.md). 타이머(19)는 보내지 않는다.
local SAFE = {
  ["1"] = { [true] = true, [false] = true },
  ["16"] = { [true] = true, [false] = true },
  ["21"] = { [true] = true, [false] = true },
  ["26"] = { [true] = true, [false] = true },
  ["29"] = { [true] = true, [false] = true },
  ["101"] = { [true] = true, [false] = true },
  ["23"] = { level_1 = true, level_2 = true, level_3 = true },
  ["13"] = {},
}
for v = 45, 100, 5 do SAFE["13"][v] = true end

-- dps 전체가 안전하면 true, 아니면 nil, 이유
function M.is_safe(dps)
  for k, v in pairs(dps) do
    local allowed = SAFE[tostring(k)]
    if not allowed or not allowed[v] then
      return nil, string.format("dp %s = %s is not allowed", tostring(k), tostring(v))
    end
  end
  return true
end

local function mist_mode(state)
  if state["101"] == true then return M.AUTO end
  return M.LEVELS[state["23"]]
end

-- changed: 이번에 바뀐 dps, state: 합쳐진 전체 상태
-- 반환: { {component=, kind="switch"|"mode"|"humidity", value=}, ... }
function M.updates(changed, state)
  local out = {}
  for dp, v in pairs(changed) do
    local comp = SWITCH_COMPONENT[dp]
    if comp and type(v) == "boolean" then
      out[#out + 1] = { component = comp, kind = "switch", value = v and "on" or "off" }
    elseif dp == "14" and math.type(v) == "integer" then
      out[#out + 1] = { component = "main", kind = "humidity", value = v }
    elseif dp == "13" and math.type(v) == "integer" then
      out[#out + 1] = { component = "humidityTarget", kind = "mode", value = v .. "%" }
    end
  end
  if changed["23"] ~= nil or changed["101"] ~= nil then
    local m = mist_mode(state)
    if m then out[#out + 1] = { component = "mist", kind = "mode", value = m } end
  end
  return out
end

-- 분무량 모드 → 보낼 dps. state = 현재 전체 상태
function M.mist_command(mode, state)
  if mode == M.AUTO then return { ["101"] = true } end
  for level, name in pairs(M.LEVELS) do
    if name == mode then
      -- 자동 중에 단계를 고르면 앱처럼 자동도 같이 끈다 (기기는 23만 받으면 자동을 유지함)
      if state["101"] == true then return { ["101"] = false, ["23"] = level } end
      return { ["23"] = level }
    end
  end
  return nil
end

function M.target_command(mode)
  local v = tonumber((tostring(mode):match("^(%d+)%%?$")))
  if v and SAFE["13"][v] then return { ["13"] = v } end
  return nil
end

function M.trim(s)
  if type(s) ~= "string" then return nil end
  s = s:match("^%s*(.-)%s*$")
  return s ~= "" and s or nil
end

-- 설정값 검사. 반환: ip, dev_id, key | nil, 이유
function M.check_prefs(prefs)
  local ip = M.trim(prefs.ipAddress)
  local id = M.trim(prefs.deviceId)
  local key = prefs.localKey -- 키는 공백도 문자일 수 있으므로 앞뒤 공백만 잘라 본다
  key = type(key) == "string" and key:match("^%s*(.-)%s*$") or nil
  if not ip or not ip:match("^%d+%.%d+%.%d+%.%d+$") then return nil, "IP 주소가 비었거나 형식이 틀림" end
  if not id or not id:match("^[%w]+$") or #id < 20 then return nil, "Device ID가 비었거나 형식이 틀림" end
  if not key or #key ~= 16 then return nil, "Local Key는 16자여야 함" end
  return ip, id, key
end

return M
