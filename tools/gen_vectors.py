"""Lua 구현 검증용 테스트 벡터를 만든다 (가짜 키만 사용. 실제 local_key는 쓰지 않음).
기준: Python cryptography(AES), hashlib/hmac(SHA-256), tinytuya 1.20.0 pack_message(프레임).
출력: driver/test/vectors.lua
"""
import hashlib
import hmac
import os
import struct
import warnings

warnings.filterwarnings("ignore")
from tinytuya.core.crypto_helper import AESCipher  # noqa: E402
from tinytuya.core.message_helper import pack_message, TuyaMessage  # noqa: E402
from tinytuya.core import header as H  # noqa: E402

KEY = b"0123456789abcdef"            # 가짜 local_key
DEV = "ebxxxxxxxxxxxxxxxxxxxx"         # 가짜 Device ID
N1 = bytes(range(16))                  # 클라이언트 nonce (고정)
N2 = bytes(range(0xA0, 0xB0))          # 기기 nonce (고정)


def enc(key, data, pad=True):
    return AESCipher(key).encrypt(data, False, pad=pad)


def hm(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()


v = []


def add(name, data):
    v.append((name, data.hex() if isinstance(data, bytes) else data))


# 1) AES
add("fips_key", bytes(range(16)))
add("fips_pt", bytes.fromhex("00112233445566778899aabbccddeeff"))
add("fips_ct", enc(bytes(range(16)), bytes.fromhex("00112233445566778899aabbccddeeff"), pad=False))
for n in (0, 5, 16, 33, 100):
    pt = bytes((i * 7 + 3) & 0xFF for i in range(n))
    add("aes_pt_%d" % n, pt)
    add("aes_ct_%d" % n, enc(KEY, pt))

# 2) SHA-256 / HMAC
for name, msg in (("empty", b""), ("abc", b"abc"), ("long", bytes(i & 0xFF for i in range(1000)))):
    add("sha_msg_" + name, msg)
    add("sha_" + name, hashlib.sha256(msg).digest())
add("hmac_k1", b"Jefe"); add("hmac_m1", b"what do ya want for nothing?"); add("hmac_1", hm(b"Jefe", b"what do ya want for nothing?"))
add("hmac_k2", b"\xaa" * 131); add("hmac_m2", b"Test Using Larger Than Block-Size Key - Hash Key First")
add("hmac_2", hm(b"\xaa" * 131, b"Test Using Larger Than Block-Size Key - Hash Key First"))

# 3) 협상 1단계 프레임 (seq 1, cmd 3, local_key로 암호화)
step1 = pack_message(TuyaMessage(1, H.CT.SESS_KEY_NEG_START, None, enc(KEY, N1), 0, True, H.PREFIX_55AA_VALUE, False), hmac_key=KEY)
add("neg_step1", step1)

# 4) 기기 응답 (cmd 4, retcode 0): AES(local_key, N2 + HMAC(local_key, N1))
body = enc(KEY, N2 + hm(KEY, N1))
hdr = struct.pack(">IIII", H.PREFIX_55AA_VALUE, 1, H.CT.SESS_KEY_NEG_RESP, 4 + len(body) + 36)
raw = hdr + struct.pack(">I", 0) + body
add("neg_resp", raw + hm(KEY, raw) + struct.pack(">I", H.SUFFIX_VALUE))

# 5) 협상 3단계 프레임 (seq 2, cmd 5) + 세션 키
step3 = pack_message(TuyaMessage(2, H.CT.SESS_KEY_NEG_FINISH, None, enc(KEY, hm(KEY, N2)), 0, True, H.PREFIX_55AA_VALUE, False), hmac_key=KEY)
add("neg_step3", step3)
SK = enc(KEY, bytes(a ^ b for a, b in zip(N1, N2)), pad=False)
add("session_key", SK)

# 6) 세션 키로 만든 명령 프레임 (seq 3: CONTROL_NEW, seq 4: DP_QUERY_NEW)
ctrl_json = b'{"protocol":5,"t":1795350000,"data":{"dps":{"23":"level_3","101":false}}}'
add("ctrl_json", ctrl_json)
add("ctrl_frame", pack_message(TuyaMessage(3, H.CT.CONTROL_NEW, None, enc(SK, H.PROTOCOL_34_HEADER + ctrl_json), 0, True, H.PREFIX_55AA_VALUE, False), hmac_key=SK))
add("query_frame", pack_message(TuyaMessage(4, H.CT.DP_QUERY_NEW, None, enc(SK, b"{}"), 0, True, H.PREFIX_55AA_VALUE, False), hmac_key=SK))

# 7) 기기 STATUS push (cmd 8, retcode 0, 버전 헤더 포함 평문)
st_json = b'{"protocol":4,"t":1795350001,"data":{"dps":{"14":61}}}'
add("status_json", st_json)
body = enc(SK, H.PROTOCOL_34_HEADER + st_json)
hdr = struct.pack(">IIII", H.PREFIX_55AA_VALUE, 7, H.CT.STATUS, 4 + len(body) + 36)
raw = hdr + struct.pack(">I", 0) + body
add("status_frame", raw + hm(SK, raw) + struct.pack(">I", H.SUFFIX_VALUE))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "driver", "test", "vectors.lua")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    f.write("-- tools/gen_vectors.py 로 생성 (가짜 키). 직접 고치지 말 것.\nreturn {\n")
    f.write('  KEY = "%s", DEV = "%s", N1 = "%s",\n' % (KEY.hex(), DEV, N1.hex()))
    for name, h in v:
        f.write('  %s = "%s",\n' % (name, h))
    f.write("}\n")
print("wrote", out, len(v), "vectors")
