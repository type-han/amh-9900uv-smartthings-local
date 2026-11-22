-- 소켓에서 Tuya 프레임을 하나씩 정확히 읽는다 (luasocket / 허브 cosock 공용).
--
-- 읽기 규칙 (SmartThings 허브 cosock에서 배운 것):
-- * 타임아웃된 receive의 부분 결과는 믿지 않는다 (cosock 버전마다 동작이 다름).
-- * select로 기다린 뒤, 블로킹 receive(n)로 헤더 16바이트 → 본문 len바이트를 정확히 읽는다.
--   그 사이 타임아웃은 연결 오류로 본다.
-- * luasocket 내부 버퍼에 이미 데이터가 있으면 select가 모르므로, 논블로킹 1바이트 읽기로 먼저 확인한다
--   (허브 소켓에는 dirty()가 없다).

local M = {}

local PREFIX = "\0\0\x55\xaa"
M.READ_TIMEOUT = 5

local function read_exact(sock, n)
  if n == 0 then return "" end
  local data, err = sock:receive(n)
  if not data then error("read " .. n .. " bytes: " .. tostring(err), 0) end
  return data
end

-- 이미 받을 수 있는 바이트가 있으면 1바이트, 없으면 nil. 연결이 닫혔으면 error.
local function try_byte(sock)
  sock:settimeout(0)
  local b, err = sock:receive(1)
  if b and #b == 1 then return b end
  if err and err ~= "timeout" then error("read: " .. tostring(err), 0) end
  return nil
end

-- 프레임 하나를 블로킹으로 읽는다. first = 이미 읽은 첫 바이트(있으면).
function M.read_frame(sock, first)
  sock:settimeout(M.READ_TIMEOUT)
  local hdr = (first or "") .. read_exact(sock, 16 - #(first or ""))
  if hdr:sub(1, 4) ~= PREFIX then error("bad frame prefix", 0) end
  local len = string.unpack(">I4", hdr, 13)
  if len < 36 or len > 4096 then error("bad frame length " .. len, 0) end
  return hdr .. read_exact(sock, len)
end

-- 최대 wait초 기다려서 프레임이 오면 바이트를, 안 오면 nil을 돌려준다. 오류는 error.
-- select: socket.select (luasocket) 또는 cosock.socket.select (허브)
function M.wait_frame(sock, select, wait)
  local pre = try_byte(sock)
  if not pre then
    local readable = select({ sock }, {}, wait)
    if not readable or #readable == 0 then return nil end
  end
  return M.read_frame(sock, pre)
end

return M
