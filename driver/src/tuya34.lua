-- Tuya 로컬 프로토콜 3.4: 프레임 조립/해석, 세션 키 협상 (소켓 없음, 순수 함수)
--
-- 프레임: 000055aa | seq(4) | cmd(4) | len(4) | [retcode(4), 기기→클라이언트] | AES-ECB 암호문 | HMAC-SHA256(32) | 0000aa55
--   len = (retcode) + 암호문 + 32 + 4,  HMAC = HMAC(key, 헤더 ~ 암호문 끝)
--   key = 협상 전 local_key, 협상 후 세션 키
-- 근거: tinytuya 1.20.0 (XenonDevice.py, message_helper.py). docs/03_PROTOCOL.md 3-4 참고.

local aes = require "aes"
local sha = require "sha256"

local M = {}

M.CMD = {
  SESS_KEY_NEG_START = 0x03, SESS_KEY_NEG_RESP = 0x04, SESS_KEY_NEG_FINISH = 0x05,
  CONTROL = 0x07, STATUS = 0x08, HEART_BEAT = 0x09, DP_QUERY = 0x0a,
  CONTROL_NEW = 0x0d, DP_QUERY_NEW = 0x10, UPDATEDPS = 0x12,
}
local C = M.CMD

local PREFIX = "\0\0\x55\xaa"
local SUFFIX = "\0\0\xaa\x55"
local VERSION_HEADER = "3.4" .. string.rep("\0", 12)
-- 이 명령들은 평문 앞에 버전 헤더를 붙이지 않는다
local NO_HEADER = {
  [C.DP_QUERY] = true, [C.DP_QUERY_NEW] = true, [C.UPDATEDPS] = true, [C.HEART_BEAT] = true,
  [C.SESS_KEY_NEG_START] = true, [C.SESS_KEY_NEG_RESP] = true, [C.SESS_KEY_NEG_FINISH] = true,
  [0x40] = true,
}

local Session = {}
Session.__index = Session

-- dev_id: 22자 Device ID, local_key: 16바이트 문자열
function M.new(dev_id, local_key)
  assert(type(local_key) == "string" and #local_key == 16, "local_key must be 16 bytes")
  local s = setmetatable({ dev_id = dev_id, local_key = local_key }, Session)
  s:reset()
  return s
end

-- 연결을 새로 열 때마다 호출: 세션 키를 버리고 local_key로 돌아간다
function Session:reset()
  self.key = self.local_key
  self.seq = 1
  self.local_nonce = nil
  self.ready = false
end

-- 평문 → 프레임 바이트
function Session:frame(cmd, plain, key)
  key = key or self.key
  if not NO_HEADER[cmd] then plain = VERSION_HEADER .. plain end
  local enc = aes.ecb_encrypt(key, plain)
  local header = PREFIX .. string.pack(">I4I4I4", self.seq, cmd, #enc + 36)
  self.seq = self.seq + 1
  local body = header .. enc
  return body .. sha.hmac(key, body) .. SUFFIX
end

-- 버퍼에서 프레임 하나를 꺼낸다.
-- 반환: frame(table) , 남은 버퍼   |  nil, 버퍼 (데이터 부족)  |  nil, 버퍼, "에러"
-- 앞에 쓰레기가 있으면 다음 prefix까지 버린다.
function M.parse(buf)
  local start = buf:find(PREFIX, 1, true)
  if not start then
    -- prefix 일부가 끝에 걸쳐 있을 수 있으니 마지막 3바이트만 남긴다
    return nil, buf:sub(-3)
  end
  if start > 1 then buf = buf:sub(start) end
  if #buf < 16 then return nil, buf end
  local seq, cmd, len = string.unpack(">I4I4I4", buf, 5)
  if len < 36 or len > 4096 then
    return nil, buf:sub(5), "bad length " .. len
  end
  if #buf < 16 + len then return nil, buf end
  local frame_bytes = buf:sub(1, 16 + len)
  local rest = buf:sub(17 + len)
  if frame_bytes:sub(-4) ~= SUFFIX then
    return nil, buf:sub(5), "bad suffix"
  end
  local payload_len = len - 36
  local f = { seq = seq, cmd = cmd, signed = frame_bytes:sub(1, 16 + payload_len),
              mac = frame_bytes:sub(17 + payload_len, 16 + payload_len + 32) }
  local pos = 17
  -- 기기가 보내는 프레임은 암호문 앞에 retcode 4바이트가 붙는다 (암호문은 16의 배수)
  if payload_len % 16 == 4 then
    f.retcode = string.unpack(">I4", frame_bytes, 17)
    pos = 21
    payload_len = payload_len - 4
  end
  f.enc = frame_bytes:sub(pos, pos + payload_len - 1)
  return f, rest
end

-- 프레임 검증 + 복호화. 반환: 평문 | nil, "에러"
function Session:open(f, key)
  key = key or self.key
  if sha.hmac(key, f.signed) ~= f.mac then return nil, "hmac mismatch" end
  if #f.enc == 0 then return "" end
  local plain = aes.ecb_decrypt(key, f.enc)
  if not plain then return nil, "bad padding" end
  if plain:sub(1, 3) == "3.4" then plain = plain:sub(#VERSION_HEADER + 1) end
  return plain
end

-- 세션 키 협상 1단계: cmd 3 프레임. nonce는 테스트용으로만 넘긴다.
function Session:neg_start(nonce)
  self:reset()
  if not nonce then
    local t = {}
    for i = 1, 16 do t[i] = string.char(math.random(0, 255)) end
    nonce = table.concat(t)
  end
  assert(#nonce == 16)
  self.local_nonce = nonce
  return self:frame(C.SESS_KEY_NEG_START, nonce, self.local_key)
end

-- 협상 2단계 응답(cmd 4)을 검증하고 3단계 프레임(cmd 5)을 돌려준다. 세션 키도 설정한다.
-- 반환: frame_bytes | nil, "에러" (local_key가 틀리면 hmac 에러)
function Session:neg_finish(f)
  if f.cmd ~= C.SESS_KEY_NEG_RESP then return nil, "unexpected cmd " .. f.cmd end
  local plain, err = self:open(f, self.local_key)
  if not plain then return nil, "step2 " .. err .. " (wrong local_key?)" end
  if #plain < 48 then return nil, "step2 too short" end
  local remote = plain:sub(1, 16)
  if plain:sub(17, 48) ~= sha.hmac(self.local_key, self.local_nonce) then
    return nil, "step2 nonce hmac mismatch (wrong local_key?)"
  end
  local out = self:frame(C.SESS_KEY_NEG_FINISH, sha.hmac(self.local_key, remote), self.local_key)
  local x = {}
  for i = 1, 16 do x[i] = string.char(self.local_nonce:byte(i) ~ remote:byte(i)) end
  self.key = aes.ecb_encrypt(self.local_key, table.concat(x), false)
  self.ready = true
  return out
end

-- dps = { ["1"]=true, ["23"]="level_2", ["13"]=60 } → JSON (값은 boolean/정수/문자열만)
function M.encode_dps(dps)
  local keys = {}
  for k in pairs(dps) do keys[#keys + 1] = tostring(k) end
  table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = dps[k]
    if v == nil then v = dps[tonumber(k)] end
    local t = type(v)
    local js
    if t == "boolean" then js = tostring(v)
    elseif math.type(v) == "integer" then js = tostring(v)
    elseif t == "string" and not v:find('[%c"\\]') then js = '"' .. v .. '"'
    else error("unsupported dp value for " .. k) end
    parts[#parts + 1] = '"' .. k .. '":' .. js
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Session:query()
  return self:frame(C.DP_QUERY_NEW, "{}")
end

function Session:heartbeat()
  return self:frame(C.HEART_BEAT, string.format('{"gwId":"%s","devId":"%s"}', self.dev_id, self.dev_id))
end

function Session:control(dps, t)
  t = t or os.time()
  return self:frame(C.CONTROL_NEW,
    string.format('{"protocol":5,"t":%d,"data":{"dps":%s}}', t, M.encode_dps(dps)))
end

return M
