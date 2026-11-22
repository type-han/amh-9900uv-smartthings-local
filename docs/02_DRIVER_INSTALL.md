# 2. Edge 드라이버 설치

먼저 [01_LOCAL_KEY.md](01_LOCAL_KEY.md)대로 **가습기 IP, Device ID, Local Key**를 준비하세요.

## 2-0. 가습기 IP 고정

드라이버는 설정에 넣은 IP로 접속합니다. Edge 드라이버는 Tuya 브로드캐스트로 기기를 다시 찾을 수 없으므로,
**공유기에서 가습기 MAC에 DHCP 예약**을 해 두세요. IP가 바뀌면 기기가 오프라인이 되고, 설정의 IP를 고쳐야 합니다.

## 2-1. 직접 빌드해서 설치

채널 초대 링크는 아직 없습니다. SmartThings CLI로 직접 설치합니다 (10분 정도).

1. [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli/releases)를 받습니다 (검증 버전 2.1.3).
2. 로그인과 채널:
   ```bash
   smartthings login
   smartthings edge:channels:create -i driver/channel.json      # 출력된 channelId를 메모
   smartthings devices --type HUB                                # 허브 ID 확인
   smartthings edge:channels:enroll <허브ID> --channel <채널ID>
   ```
3. 패키징 + 채널 배정 + 허브 설치:
   ```bash
   smartthings edge:drivers:package driver --channel <채널ID> --hub <허브ID>
   ```
   출력 끝의 `Installed driver <드라이버ID>`를 메모해 두면 로그 볼 때 씁니다.
4. SmartThings 앱 → **기기 추가** → **주변 기기 검색**
   → 1분 안에 **"AMH-9900UV 가습기"** 가 생깁니다. 처음에는 오프라인입니다.
5. 기기 화면 → 오른쪽 위 **⋮ → 설정**:
   - **가습기 IP 주소**: 예) `192.168.1.50`
   - **Device ID**: 22자 (앱의 가상 ID)
   - **Local Key**: 16자
6. 저장하면 몇 초 안에 온라인이 되고 현재 상태가 표시됩니다.

> 이후 드라이버를 고쳐서 다시 올릴 때도 3번 명령 하나면 됩니다. 기기 설정값은 유지됩니다.

## 2-2. 로그 보기

허브 IP는 공유기 DHCP 목록이나 `smartthings devices <허브ID> -j`의 `localIP`로 확인합니다.

```bash
smartthings edge:drivers:logcat <드라이버ID> --hub-address <허브IP>
```

정상일 때:

```
humidifier 192.168.1.50, device id ebxxxxxxxxxxxxxxxxxxxx
tuya connected to 192.168.1.50:6668
<Device ...> emitting event: {"attribute_id":"humidity", ...}
```

| 로그 | 뜻 |
|---|---|
| `settings incomplete (...)` | 설정이 비었거나 형식이 틀림 (IP 형식, Device ID 20자 이상, Local Key 16자) |
| `connect: timeout` / `connection refused` 반복 | IP가 틀렸거나 가습기가 꺼짐 / IP가 바뀜 |
| `negotiation failed: step2 ... (wrong local_key?)` | **Local Key가 틀림** (가습기를 재등록해서 키가 바뀌었을 수 있음) |
| `no answer to session negotiation` | Device ID가 틀렸거나 다른 프로토콜 버전의 기기 |
| `no data for 35s` 후 재접속 | WiFi 끊김. 드라이버가 2초→60초 간격으로 다시 접속합니다 |
| `refusing command: dp ... is not allowed` | 앱에서 쓰지 않는 값이라 막음 ([04_SAFETY.md](04_SAFETY.md)) |

로그에는 Local Key가 남지 않습니다.

## 2-3. 허브 밖에서 테스트 (개발용)

리눅스에 Lua 5.3, luasocket, dkjson을 설치한 뒤 `driver/`에서:

```bash
lua5.3 test/test_crypto.lua    # AES / SHA-256 / HMAC / 3.4 프레임·협상 (네트워크 없음, 기준 벡터와 비교)
lua5.3 test/test_amh.lua       # DP ↔ SmartThings 매핑, 안전 검사
TUYA_KEY=<LocalKey> lua5.3 test/test_live.lua <IP> <DeviceID> 20     # 실기기: 협상 → 조회 → 목표 습도 ±5 후 복원
```

`test/test_client.lua`는 드라이버의 연결 코드(`client.lua`)를 [cosock](https://luarocks.org/modules/cosock/cosock) 0.2.0으로 실기기에서 돌립니다
(`luarocks --lua-version 5.3 install cosock`). 허브의 cosock은 PC용과 동작이 다를 수 있으니 PC에서 통과해도 허브에서 한 번 더 확인하세요.

기준 벡터(`test/vectors.lua`)는 `python tools/gen_vectors.py`가 Python cryptography와 tinytuya로 **가짜 키**를 써서 만듭니다.
