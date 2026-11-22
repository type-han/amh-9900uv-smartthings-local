-- AES-128 ECB (순수 Lua 5.3). Tuya 3.4 로컬 프로토콜용.
-- 블록 단위 암복호화 + PKCS7 패딩만 제공한다. 메시지가 작아서(수백 바이트) 속도보다 단순함을 우선했다.

local M = {}

local sbox, inv = {}, {}
do
  -- S-box를 직접 계산한다 (표를 손으로 옮기다 생기는 오타를 피하려고).
  local function rotl8(x, s) return ((x << s) | (x >> (8 - s))) & 0xFF end
  local p, q = 1, 1
  repeat
    p = (p ~ (p << 1) ~ ((p & 0x80) ~= 0 and 0x1B or 0)) & 0xFF   -- p * 3
    q = (q ~ (q << 1)) & 0xFF                                       -- q / 3
    q = (q ~ (q << 2)) & 0xFF
    q = (q ~ (q << 4)) & 0xFF
    if (q & 0x80) ~= 0 then q = q ~ 0x09 end
    local x = q ~ rotl8(q, 1) ~ rotl8(q, 2) ~ rotl8(q, 3) ~ rotl8(q, 4)
    sbox[p] = x ~ 0x63
  until p == 1
  sbox[0] = 0x63
  for i = 0, 255 do inv[sbox[i]] = i end
end

local function xtime(a)
  a = a << 1
  if a > 0xFF then a = (a ~ 0x1B) & 0xFF end
  return a
end

local function mul(a, b)
  local r = 0
  while b > 0 do
    if (b & 1) ~= 0 then r = r ~ a end
    a = xtime(a)
    b = b >> 1
  end
  return r
end

-- 곱셈 결과를 미리 표로 만들어 둔다 (MixColumns / InvMixColumns)
local m2, m3, m9, m11, m13, m14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
  m2[i], m3[i] = mul(i, 2), mul(i, 3)
  m9[i], m11[i], m13[i], m14[i] = mul(i, 9), mul(i, 11), mul(i, 13), mul(i, 14)
end

-- 키 확장: 16바이트 키 → 176바이트 라운드 키 (0-based 배열)
local function expand(key)
  assert(#key == 16, "AES-128 key must be 16 bytes")
  local w = {}
  for i = 0, 15 do w[i] = key:byte(i + 1) end
  local rcon = 1
  for i = 16, 175, 4 do
    local t0, t1, t2, t3 = w[i - 4], w[i - 3], w[i - 2], w[i - 1]
    if i % 16 == 0 then
      t0, t1, t2, t3 = sbox[t1] ~ rcon, sbox[t2], sbox[t3], sbox[t0]
      rcon = xtime(rcon)
    end
    w[i], w[i + 1], w[i + 2], w[i + 3] =
      w[i - 16] ~ t0, w[i - 15] ~ t1, w[i - 14] ~ t2, w[i - 13] ~ t3
  end
  return w
end

local function add_round_key(s, w, r)
  local o = r * 16
  for i = 0, 15 do s[i] = s[i] ~ w[o + i] end
end

-- 상태 배열 s[0..15]는 열 우선 (s[c*4 + r])
local function encrypt_block(w, blk, pos)
  local s = {}
  for i = 0, 15 do s[i] = blk:byte(pos + i) end
  add_round_key(s, w, 0)
  for round = 1, 10 do
    for i = 0, 15 do s[i] = sbox[s[i]] end
    -- ShiftRows
    s[1], s[5], s[9], s[13] = s[5], s[9], s[13], s[1]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[15], s[3], s[7], s[11]
    if round < 10 then
      for c = 0, 12, 4 do
        local a0, a1, a2, a3 = s[c], s[c + 1], s[c + 2], s[c + 3]
        s[c]     = m2[a0] ~ m3[a1] ~ a2 ~ a3
        s[c + 1] = a0 ~ m2[a1] ~ m3[a2] ~ a3
        s[c + 2] = a0 ~ a1 ~ m2[a2] ~ m3[a3]
        s[c + 3] = m3[a0] ~ a1 ~ a2 ~ m2[a3]
      end
    end
    add_round_key(s, w, round)
  end
  return string.char(s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7],
                     s[8], s[9], s[10], s[11], s[12], s[13], s[14], s[15])
end

local function decrypt_block(w, blk, pos)
  local s = {}
  for i = 0, 15 do s[i] = blk:byte(pos + i) end
  add_round_key(s, w, 10)
  for round = 9, 0, -1 do
    -- InvShiftRows
    s[1], s[5], s[9], s[13] = s[13], s[1], s[5], s[9]
    s[2], s[6], s[10], s[14] = s[10], s[14], s[2], s[6]
    s[3], s[7], s[11], s[15] = s[7], s[11], s[15], s[3]
    for i = 0, 15 do s[i] = inv[s[i]] end
    add_round_key(s, w, round)
    if round > 0 then
      for c = 0, 12, 4 do
        local a0, a1, a2, a3 = s[c], s[c + 1], s[c + 2], s[c + 3]
        s[c]     = m14[a0] ~ m11[a1] ~ m13[a2] ~ m9[a3]
        s[c + 1] = m9[a0] ~ m14[a1] ~ m11[a2] ~ m13[a3]
        s[c + 2] = m13[a0] ~ m9[a1] ~ m14[a2] ~ m11[a3]
        s[c + 3] = m11[a0] ~ m13[a1] ~ m9[a2] ~ m14[a3]
      end
    end
  end
  return string.char(s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7],
                     s[8], s[9], s[10], s[11], s[12], s[13], s[14], s[15])
end

function M.pkcs7_pad(data)
  local n = 16 - (#data % 16)
  return data .. string.rep(string.char(n), n)
end

-- 패딩이 틀리면 nil
function M.pkcs7_unpad(data)
  local n = data:byte(#data)
  if not n or n < 1 or n > 16 or n > #data then return nil end
  for i = #data - n + 1, #data do
    if data:byte(i) ~= n then return nil end
  end
  return data:sub(1, #data - n)
end

-- ECB 암호화. pad=false면 data 길이가 16의 배수여야 한다.
function M.ecb_encrypt(key, data, pad)
  if pad ~= false then data = M.pkcs7_pad(data) end
  assert(#data % 16 == 0, "data length must be a multiple of 16")
  local w = expand(key)
  local out = {}
  for pos = 1, #data, 16 do out[#out + 1] = encrypt_block(w, data, pos) end
  return table.concat(out)
end

-- ECB 복호화. unpad=false가 아니면 PKCS7 패딩을 벗긴다 (틀리면 nil).
function M.ecb_decrypt(key, data, unpad)
  if #data == 0 or #data % 16 ~= 0 then return nil end
  local w = expand(key)
  local out = {}
  for pos = 1, #data, 16 do out[#out + 1] = decrypt_block(w, data, pos) end
  local plain = table.concat(out)
  if unpad == false then return plain end
  return M.pkcs7_unpad(plain)
end

return M
