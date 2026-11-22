-- client.lua 실기기 테스트 (cosock 0.2.0, 허브 밖): 접속 → 전체 상태 → 목표 습도 ±5 후 복원 → 연결 유지
-- 실행 (driver/ 에서): eval "$(luarocks --lua-version 5.3 path)"; TUYA_KEY=<key> lua5.3 test/test_client.lua <IP> <DeviceID> [초]
package.path = "src/?.lua;" .. package.path
local cosock = require "cosock"
local json = require "dkjson"
local client_mod = require "client"
local amh = require "amh"

local ip, dev_id, secs = arg[1], arg[2], tonumber(arg[3] or "30")
local key = os.getenv("TUYA_KEY")
assert(ip and dev_id and key and #key == 16, "usage")
math.randomseed(os.time())
local t0 = cosock.socket.gettime()
local function log(fmt, ...) print(string.format("%7.3f " .. fmt, cosock.socket.gettime() - t0, ...)) end

local events, connects, disconnects = {}, 0, 0
local c = client_mod.new({
  ip = ip, dev_id = dev_id, key = key, json = json,
  log = { info = function(m) log("[info] %s", m) end, warn = function(m) log("[warn] %s", m) end, debug = function() end },
  on_dps = function(changed, state, full)
    for _, u in ipairs(amh.updates(changed, state)) do
      log("event %s %s = %s%s", u.component, u.kind, tostring(u.value), full and " (full)" or "")
      events[#events + 1] = u
    end
  end,
  on_connect = function() connects = connects + 1; log("on_connect") end,
  on_disconnect = function(r) disconnects = disconnects + 1; log("on_disconnect %s", r) end,
})

local result = false
cosock.spawn(function()
  c:start()
  local s = cosock.socket
  while not c.connected do s.sleep(0.1) end
  while not c.state["13"] do s.sleep(0.1) end
  local start13 = c.state["13"]
  local target = start13 <= 95 and start13 + 5 or start13 - 5
  local function set_wait(v)
    local t = s.gettime()
    assert(amh.is_safe({ ["13"] = v }))
    c:set({ ["13"] = v })
    while c.state["13"] ~= v and s.gettime() - t < 3 do s.sleep(0.05) end
    log("13 = %d %s in %.0f ms", v, c.state["13"] == v and "confirmed" or "NOT confirmed", (s.gettime() - t) * 1000)
    return c.state["13"] == v
  end
  local ok1 = set_wait(target)
  local ok2 = set_wait(start13)
  log("holding connection %d s", secs)
  s.sleep(secs)
  result = ok1 and ok2 and c.connected and disconnects == 0
  log("connected=%s connects=%d disconnects=%d events=%d", tostring(c.connected), connects, disconnects, #events)
  c:stop()
  s.sleep(1)
  os.exit(result and 0 or 1)
end, "test")
cosock.run()
