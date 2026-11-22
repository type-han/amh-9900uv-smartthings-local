-- Tuya 3.4 로컬 연결 하나를 유지하는 클라이언트 (cosock).
-- cosock 작업 하나가 소켓을 맡고, 다른 코루틴(명령 핸들러)은 outbox에 넣기만 한다 (SmartThings 커뮤니티 LAN 드라이버의 일반적인 구조).
-- 세션 키는 연결마다 새로 협상하므로, 명령 프레임은 보낼 때 소켓 작업 안에서 만든다.

local cosock = require "cosock"
local socket = cosock.socket
local tuya = require "tuya34"
local transport = require "transport"

local M = {}
M.__index = M

M.PORT = 6668
M.HEARTBEAT = 10      -- 초. tinytuya와 비슷한 간격
M.DEAD_AFTER = 35     -- 초. 이만큼 아무것도 못 받으면 끊고 다시 접속
M.CMD_GAP = 0.3       -- 초. 명령을 연달아 보낼 때 간격

--- opts: ip, dev_id, key, json (decode 함수가 있는 모듈), log {info,warn,debug},
---       on_dps(changed, state, full), on_connect(), on_disconnect(reason)
function M.new(opts)
  local self = setmetatable({}, M)
  self.ip = assert(opts.ip, "ip")
  self.dev_id = assert(opts.dev_id, "dev_id")
  self.key = assert(opts.key, "key")
  self.json = assert(opts.json, "json")
  self.log = opts.log or { info = print, warn = print, debug = function() end }
  self.on_dps = opts.on_dps or function() end
  self.on_connect = opts.on_connect or function() end
  self.on_disconnect = opts.on_disconnect or function() end
  self.state = {}
  self.outbox = {}
  self.running = false
  self.connected = false
  return self
end

--- dps 설정을 대기열에 넣는다 (어느 코루틴에서 불러도 됨). 연결이 없으면 버린다.
function M:set(dps)
  if not self.connected then
    self.log.warn("not connected; dropping command " .. tuya.encode_dps(dps))
    return false
  end
  table.insert(self.outbox, { kind = "control", dps = dps })
  return true
end

function M:query()
  if self.connected then table.insert(self.outbox, { kind = "query" }) end
end

function M:_send(sock, data)
  sock:settimeout(5)
  local i = 1
  while i <= #data do
    local sent, err, last = sock:send(data, i)
    if not sent then
      if err == "timeout" and last and last >= i then
        i = last + 1
      else
        return nil, err
      end
    else
      i = sent + 1
    end
  end
  self.last_tx = os.time()
  return true
end

-- 프레임 하나 처리. 오류는 error (호출자가 pcall)
function M:_handle(sess, bytes)
  local f, _, perr = tuya.parse(bytes)
  if not f then error("parse: " .. tostring(perr), 0) end
  self.last_rx = os.time()
  if f.cmd == tuya.CMD.HEART_BEAT then return end
  local plain, err = sess:open(f)
  if not plain then error("open cmd " .. f.cmd .. ": " .. err, 0) end
  if plain == "" then return end -- 제어 명령의 빈 응답
  local ok, obj = pcall(self.json.decode, plain)
  if not ok or type(obj) ~= "table" then
    self.log.warn("non-JSON payload (cmd " .. f.cmd .. "): " .. plain:sub(1, 80))
    return
  end
  local dps = obj.dps or (type(obj.data) == "table" and obj.data.dps)
  if type(dps) ~= "table" then return end
  local full = (f.cmd == tuya.CMD.DP_QUERY_NEW or f.cmd == tuya.CMD.DP_QUERY)
  local changed = {}
  for k, v in pairs(dps) do
    k = tostring(k)
    if full or self.state[k] ~= v then changed[k] = v end
    self.state[k] = v
  end
  if next(changed) then
    local okc, cerr = pcall(self.on_dps, changed, self.state, full)
    if not okc then self.log.warn("on_dps error: " .. tostring(cerr)) end
  end
end

-- 최대 wait초 기다려서 도착한 프레임을 모두 처리
function M:_pump(sock, sess, wait)
  local bytes = transport.wait_frame(sock, socket.select, wait)
  local n = 0
  while bytes and n < 20 do
    self:_handle(sess, bytes)
    n = n + 1
    bytes = transport.wait_frame(sock, socket.select, 0)
  end
  return n
end

function M:_session()
  local sock = assert(socket.tcp())
  sock:settimeout(5)
  local ok, err = sock:connect(self.ip, M.PORT)
  if not ok then sock:close(); return nil, "connect: " .. tostring(err) end
  self.outbox = {} -- 끊긴 동안 쌓인 명령은 버린다 (오래된 명령)

  local function fail(e)
    sock:close()
    return nil, e
  end

  -- 세션 키 협상
  local sess = tuya.new(self.dev_id, self.key)
  local sent, serr = self:_send(sock, sess:neg_start())
  if not sent then return fail("send neg start: " .. tostring(serr)) end
  local okw, bytes = pcall(transport.wait_frame, sock, socket.select, 5)
  if not okw then return fail("neg: " .. tostring(bytes)) end
  if not bytes then return fail("no answer to session negotiation") end
  local f = tuya.parse(bytes)
  if not f then return fail("neg: bad frame") end
  local step3, nerr = sess:neg_finish(f)
  if not step3 then return fail("negotiation failed: " .. tostring(nerr)) end
  sent, serr = self:_send(sock, step3)
  if not sent then return fail("send neg finish: " .. tostring(serr)) end

  sent, serr = self:_send(sock, sess:query())
  if not sent then return fail("send query: " .. tostring(serr)) end
  self.last_rx = os.time()
  self.connected = true
  self.log.info(string.format("tuya connected to %s:%d", self.ip, M.PORT))
  pcall(self.on_connect)

  while self.running do
    local item = table.remove(self.outbox, 1)
    if item then
      local frame
      if item.kind == "control" then frame = sess:control(item.dps) else frame = sess:query() end
      sent, serr = self:_send(sock, frame)
      if not sent then return fail("send: " .. tostring(serr)) end
      if item.kind == "control" then self.log.info("sent " .. tuya.encode_dps(item.dps)) end
    end
    -- 새 명령은 select가 모르므로 유휴 대기는 짧게 (0.2초)
    local okp, perr = pcall(self._pump, self, sock, sess, item and M.CMD_GAP or 0.2)
    if not okp then return fail(perr) end
    local now = os.time()
    if now - (self.last_tx or 0) >= M.HEARTBEAT then
      sent, serr = self:_send(sock, sess:heartbeat())
      if not sent then return fail("send heartbeat: " .. tostring(serr)) end
    end
    if now - self.last_rx > M.DEAD_AFTER then return fail("no data for " .. M.DEAD_AFTER .. "s") end
  end
  sock:close()
  return true
end

function M:start()
  if self.running then return end
  self.running = true
  cosock.spawn(function()
    local backoff = 2
    while self.running do
      local _, err = self:_session()
      if self.connected then
        self.connected = false
        pcall(self.on_disconnect, err or "stopped")
        backoff = 2
      end
      if not self.running then break end
      self.log.warn(string.format("tuya %s disconnected (%s), retry in %ds", self.ip, tostring(err), backoff))
      socket.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end, "tuya-" .. self.dev_id:sub(-6))
end

function M:stop()
  self.running = false
end

return M
