-- 실기기 테스트 (luasocket): 3.4 협상 → 상태 조회 → 목표 습도를 5% 바꿨다가 되돌림 → push 수신 + 하트비트
-- 실행 (driver/ 에서): TUYA_KEY=<local_key> lua5.3 test/test_live.lua <IP> <DeviceID> [초]
-- 키는 환경 변수로만 받고 출력하지 않는다.
package.path = "src/?.lua;" .. package.path
local socket = require "socket"
local json = require "dkjson"
local tuya = require "tuya34"

local ip, dev_id, secs = arg[1], arg[2], tonumber(arg[3] or "20")
local key = os.getenv("TUYA_KEY")
assert(ip and dev_id and key and #key == 16, "usage: TUYA_KEY=... lua5.3 test/test_live.lua <IP> <DeviceID> [sec]")
math.randomseed(os.time() + math.floor(socket.gettime() * 1000) % 100000)

local t_start = socket.gettime()
local function log(fmt, ...)
  print(string.format("%7.3f " .. fmt, socket.gettime() - t_start, ...))
end

local sess = tuya.new(dev_id, key)
local sock = assert(socket.tcp())
sock:settimeout(3)
assert(sock:connect(ip, 6668))
log("tcp connected")

local transport = require "transport"
-- 최대 timeout초 동안 프레임 하나를 기다린다
local function read_frame(timeout)
  local ok, bytes = pcall(transport.wait_frame, sock, socket.select, math.max(timeout, 0))
  if not ok then return nil, (tostring(bytes):find("closed") and "closed" or bytes) end
  if not bytes then return nil, "timeout" end
  local f, _, err = tuya.parse(bytes)
  if not f then return nil, "parse: " .. tostring(err) end
  return f
end

local function open_dps(f)
  local plain, err = sess:open(f)
  if not plain then return nil, err end
  if plain == "" then return nil, "empty" end
  local obj = json.decode(plain)
  if type(obj) ~= "table" then return nil, "json: " .. plain end
  return obj.dps or (obj.data and obj.data.dps), plain
end

-- 1) 협상
local t0 = socket.gettime()
assert(sock:send(sess:neg_start()))
local f, err = read_frame(3)
assert(f, "no step2: " .. tostring(err))
local step3, e = sess:neg_finish(f)
assert(step3, e)
assert(sock:send(step3))
log("session negotiated in %.0f ms", (socket.gettime() - t0) * 1000)

-- 2) 상태 조회
assert(sock:send(sess:query()))
local state
repeat
  f, err = read_frame(3)
  assert(f, "no query reply: " .. tostring(err))
  local dps, raw = open_dps(f)
  log("recv cmd=0x%02x retcode=%s %s", f.cmd, tostring(f.retcode), dps and json.encode(dps) or tostring(raw))
  state = dps
until state
local start13 = state["13"]

-- 3) 쓰기: 목표 습도 ±5 (앱 범위 45–100) 후 되돌림
local function set_and_wait(dps, want_key, want_val)
  local t = socket.gettime()
  assert(sock:send(sess:control(dps)))
  while socket.gettime() - t < 3 do
    local fr = read_frame(3 - (socket.gettime() - t))
    if not fr then break end
    local d, raw = open_dps(fr)
    log("  recv cmd=0x%02x %s", fr.cmd, d and json.encode(d) or tostring(raw))
    if d and d[want_key] == want_val then
      log("SET %s ok in %.0f ms", tuya.encode_dps(dps), (socket.gettime() - t) * 1000)
      return true
    end
  end
  log("SET %s: no confirmation", tuya.encode_dps(dps))
  return false
end
local target = (start13 <= 95) and (start13 + 5) or (start13 - 5)
local ok1 = set_and_wait({ ["13"] = target }, "13", target)
local ok2 = set_and_wait({ ["13"] = start13 }, "13", start13)

-- 4) 하트비트를 보내며 push 수신
log("listening %d s (heartbeat every 9 s)", secs)
local last_hb, hb_ok, pushes = socket.gettime(), 0, 0
local stop = socket.gettime() + secs
while socket.gettime() < stop do
  if socket.gettime() - last_hb >= 9 then
    assert(sock:send(sess:heartbeat()))
    last_hb = socket.gettime()
  end
  local fr, er = read_frame(1)
  if fr then
    if fr.cmd == tuya.CMD.HEART_BEAT then hb_ok = hb_ok + 1
    else
      local d, raw = open_dps(fr)
      pushes = pushes + 1
      log("push cmd=0x%02x %s", fr.cmd, d and json.encode(d) or tostring(raw))
    end
  elseif er == "closed" then log("connection closed by device"); break end
end
sock:close()
log("done: write %s/%s, heartbeat replies %d, pushes %d", tostring(ok1), tostring(ok2), hb_ok, pushes)
os.exit((ok1 and ok2) and 0 or 1)
