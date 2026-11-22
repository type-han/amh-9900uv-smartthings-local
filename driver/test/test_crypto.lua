-- 오프라인 단위 테스트: AES / SHA-256 / HMAC / Tuya 3.4 프레임·협상을 Python 기준 벡터와 비교
-- 실행 (driver/ 에서): lua5.3 test/test_crypto.lua
package.path = "src/?.lua;test/?.lua;" .. package.path
local aes = require "aes"
local sha = require "sha256"
local tuya = require "tuya34"
local V = require "vectors"

local function unhex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end
local hex = sha.hex
local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1
  else
    fail = fail + 1
    print("FAIL " .. name .. "\n  got  " .. tostring(got and hex(got)) .. "\n  want " .. hex(want))
  end
end

-- AES
check("fips encrypt", aes.ecb_encrypt(unhex(V.fips_key), unhex(V.fips_pt), false), unhex(V.fips_ct))
check("fips decrypt", aes.ecb_decrypt(unhex(V.fips_key), unhex(V.fips_ct), false), unhex(V.fips_pt))
local KEY = unhex(V.KEY)
for _, n in ipairs({ 0, 5, 16, 33, 100 }) do
  local pt, ct = unhex(V["aes_pt_" .. n]), unhex(V["aes_ct_" .. n])
  check("aes enc " .. n, aes.ecb_encrypt(KEY, pt), ct)
  check("aes dec " .. n, aes.ecb_decrypt(KEY, ct), pt)
end
check("bad padding -> nil", aes.ecb_decrypt(KEY, unhex(V.aes_ct_16):sub(1, 16)) == nil and "" or "x", "")

-- SHA-256 / HMAC
for _, n in ipairs({ "empty", "abc", "long" }) do
  check("sha " .. n, sha.digest(unhex(V["sha_msg_" .. n])), unhex(V["sha_" .. n]))
end
check("hmac rfc4231 #2", sha.hmac(unhex(V.hmac_k1), unhex(V.hmac_m1)), unhex(V.hmac_1))
check("hmac long key", sha.hmac(unhex(V.hmac_k2), unhex(V.hmac_m2)), unhex(V.hmac_2))

-- Tuya 3.4 협상
local s = tuya.new(V.DEV, KEY)
check("neg step1 frame", s:neg_start(unhex(V.N1)), unhex(V.neg_step1))
local f, rest = tuya.parse(unhex(V.neg_resp))
check("parse resp cmd", f and string.pack(">I4", f.cmd), string.pack(">I4", 4))
check("parse resp retcode", f and string.pack(">I4", f.retcode or 99), string.pack(">I4", 0))
check("parse resp rest", rest, "")
local step3, err = s:neg_finish(f)
if not step3 then print("neg_finish error: " .. err) end
check("neg step3 frame", step3, unhex(V.neg_step3))
check("session key", s.key, unhex(V.session_key))

-- 세션 키로 명령 프레임
local ctrl = s:frame(tuya.CMD.CONTROL_NEW, unhex(V.ctrl_json))
check("control frame", ctrl, unhex(V.ctrl_frame))
check("query frame", s:query(), unhex(V.query_frame))
check("encode_dps", tuya.encode_dps({ ["101"] = false, ["23"] = "level_3" }), '{"23":"level_3","101":false}')

-- STATUS push 해석 (앞에 쓰레기 + 두 프레임이 이어 붙은 경우 + 조각난 경우)
local sf = unhex(V.status_frame)
local buf = "\1\2\3" .. sf .. sf:sub(1, 20)
local f1, r1 = tuya.parse(buf)
check("status parse", f1 and string.pack(">I4", f1.cmd), string.pack(">I4", 8))
check("status open", f1 and s:open(f1), unhex(V.status_json))
local f2, r2 = tuya.parse(r1)
check("partial -> nil", f2 == nil and "" or "x", "")
check("partial keeps bytes", r2, sf:sub(1, 20))
local f3 = tuya.parse(r2 .. sf:sub(21))
check("partial completes", f3 and s:open(f3), unhex(V.status_json))
-- 위조 검사
local bad = sf:sub(1, 30) .. string.char(sf:byte(31) ~ 1) .. sf:sub(32)
local fb = tuya.parse(bad)
local ok, e = s:open(fb)
check("tampered -> hmac mismatch", e or "", "hmac mismatch")
-- 키가 틀리면 협상 실패
local s2 = tuya.new(V.DEV, "fedcba9876543210")
s2:neg_start(unhex(V.N1))
local x, e2 = s2:neg_finish((tuya.parse(unhex(V.neg_resp))))
check("wrong key -> error", (x == nil and e2:find("wrong local_key")) and "" or "x", "")

-- 속도 (허브 부담 가늠)
local t0 = os.clock()
for _ = 1, 200 do
  local fr = s:control({ ["23"] = "level_2", ["101"] = false })
  s:open((tuya.parse(fr)))
end
print(string.format("200 x (control frame + parse/verify/decrypt): %.3fs", os.clock() - t0))

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
