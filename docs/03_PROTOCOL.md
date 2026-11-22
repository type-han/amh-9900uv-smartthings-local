# 3. AMH-9900UV 프로토콜과 DP

직접 확인한 내용입니다 (2026-11-22, Tuya 로컬 프로토콜 3.4). 다른 펌웨어에서는 다를 수 있습니다.

## 3-1. 기기 정보

| 항목 | 값 |
|---|---|
| 제품명 | AMH-9900UV |
| Tuya 분류 | `jsq` (가습기) |
| productKey | `7f3qvffhri6hox6t` (제품 모델 값. 기기마다 다른 값이 아님) |
| 로컬 프로토콜 | **3.4**, TCP **6668** (열린 포트는 이것 하나) |
| 발견 | UDP 6667 브로드캐스트 (공개 키 `md5("yGAdlopoPVldABfn")`로 AES-ECB 복호화) |
| 표준 명령 세트 | 비어 있음 → 클라우드의 thing model(`/v2.0/cloud/thing/<id>/model`)로 DP를 확인 |

## 3-2. DP 목록

| DP | code | 접근 | 타입 / 범위 | 뜻 |
|---|---|---|---|---|
| 1 | `switch` | rw | bool | 전원 |
| 13 | `humidity_set` | rw | 45–100, 5 단위, % | 목표 습도 |
| 14 | `humidity_current` | ro | 0–100, % | 현재 습도 |
| 16 | `sleep` | rw | bool | 취침 모드 |
| 19 | `countdown_set` | rw | `cancel`, `1h` … `12h` | 꺼짐 타이머 |
| 21 | `sterilization` | rw | bool | 살균 |
| 23 | `level` | rw | `level_1`, `level_2`, `level_3` | 분무 단계 |
| 26 | `heat` | rw | bool | 가열 |
| 29 | `child_lock` | rw | bool | 차일드락 |
| 101 | `auto_mode` | rw | bool | 자동 모드 |

**없는 것**: 수위·물 부족, 고장 코드, 온도.

## 3-3. 확인한 동작

앱·본체 버튼으로 조작하면서 기록하고(`tools/monitor.py`), 로컬로 직접 써 보며(`tools/write_test.py`) 확인했습니다.

| 동작 | 결과 |
|---|---|
| 목표 습도 앱 범위 | 45–100 전부 (사양 범위와 같음). 본체 버튼은 100 다음에 45로 순환 |
| 분무 단계, 가열, 살균, 취침, 차일드락 | 각각 단독으로 바뀜. 다른 DP 변화 없음 |
| **자동 켜기** | 101 true와 함께 **목표 습도가 100으로 바뀜**. 자동을 꺼도 100 그대로 |
| 자동 중 앱에서 다른 조작 | 앱은 자동을 해제함 |
| 자동 중 로컬로 23만 쓰기 | **단계만 바뀌고 자동은 유지** → 앱은 101 false를 같이 보냄 |
| 자동 중 `{101:false, 23:단계}` 한 메시지 | 둘 다 반영 |
| **전원 끄기** | 가열 off, 살균 off, 단계 → level_2 가 함께 바뀜. **다시 켜도 복원되지 않음** |
| 꺼진 상태에서 조작 | 앱이 막음 |
| 상태 보고 | 모든 변화가 즉시 push (0x08). 쓰기 후 60–115ms |
| 동시 로컬 연결 | 최소 2개 허용 |

## 3-4. 3.4 프레임

```
000055aa | seq(4) | cmd(4) | len(4) | [retcode(4), 기기→클라이언트] | AES-128-ECB 암호문 | HMAC-SHA256(32) | 0000aa55
len = (retcode) + 암호문 + 32 + 4
HMAC = HMAC-SHA256(key, 헤더 ~ 암호문 끝)
key  = 협상 전 Local Key, 협상 후 세션 키
```

- 평문 앞에 버전 헤더 `"3.4" + 0x00×12`를 붙인다. 단, 조회(0x0a, 0x10), 0x12, 하트비트(0x09), 협상(0x03–0x05)은 붙이지 않는다.
- 기기가 보내는 STATUS의 평문도 버전 헤더로 시작한다.

### 세션 키 협상 (접속할 때마다)

```
→ 0x03  AES(LocalKey, 클라이언트 nonce 16B)
← 0x04  AES(LocalKey, 기기 nonce 16B + HMAC(LocalKey, 클라이언트 nonce))   ← 이 HMAC으로 키가 맞는지 확인
→ 0x05  AES(LocalKey, HMAC(LocalKey, 기기 nonce))
세션 키 = AES-ECB(LocalKey, 클라이언트 nonce XOR 기기 nonce)    (패딩 없이 16바이트)
```

### 명령과 응답 (실측)

| 보낸 것 | 받은 것 |
|---|---|
| 0x10 조회 `{}` | 0x10 `{"dps":{...전체}}` |
| 0x0d 제어 `{"protocol":5,"t":<epoch>,"data":{"dps":{"13":65}}}` | 0x0d 빈 응답 → 0x08 `{"protocol":4,"t":..,"data":{"dps":{"13":65}}}` |
| 0x09 하트비트 `{"gwId":"<id>","devId":"<id>"}` | 0x09 |

구현: [`driver/src/tuya34.lua`](../driver/src/tuya34.lua). 기준 구현은 [tinytuya](https://github.com/jasonacox/tinytuya) 1.20.0.

## 3-5. SmartThings 매핑 (드라이버)

| DP | 컴포넌트 | capability |
|---|---|---|
| 1 | main (가습기) | `switch` |
| 14 | main | `relativeHumidityMeasurement` |
| 23 + 101 | mist (분무량) | `mode`: 1단계 / 2단계 / 3단계 / 자동 |
| 13 | humidityTarget (목표 습도) | `mode`: 45% … 100% |
| 26 / 21 / 16 / 29 | heat / sterilize / sleep / childLock | `switch` |
| 19 | — | 넣지 않음 (SmartThings 자동화로 대신) |

- 분무량 표시: 101이 true면 "자동", 아니면 23의 단계.
- 분무량에서 단계를 고르면, 자동 중일 때 `{101:false, 23:단계}`를 한 메시지로 보낸다 (앱과 같은 동작).
- 꺼진 상태에서 전원 외 기능을 켜면 먼저 전원을 켜고 1.5초 뒤에 보낸다. 꺼진 상태에서 하위 기능을 끄는 명령은 전원을 켜지 않고 무시한다.
