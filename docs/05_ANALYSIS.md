# 5. 분석 과정 (다른 Tuya 가습기에 응용할 때)

AMH-9900UV를 어떻게 분석했는지 요약합니다. 비슷한 Tuya WiFi 기기를 로컬화할 때 같은 순서로 하면 됩니다.

## 5-1. 기기 찾기

```bash
python -m tinytuya scan
```

- Tuya 기기는 UDP 6667로 자신을 알립니다 (`gwId`, `productKey`, `version`). 공개 키로 복호화됩니다.
- TCP 전 포트 스캔: 6668만 열려 있었습니다 → Tuya 로컬 제어 포트.
- **프로토콜 버전**이 중요합니다. 3.3은 CRC32, 3.4는 HMAC-SHA256 + 세션 키 협상, 3.5는 AES-GCM입니다. 이 드라이버는 3.4만 구현합니다.

## 5-2. Local Key와 DP 사양

1. [01_LOCAL_KEY.md](01_LOCAL_KEY.md)대로 tinytuya wizard로 Local Key를 받습니다.
2. DP 사양을 받습니다. 이 제품은 표준 명령 세트가 비어 있어 wizard의 DP 매핑도 비어 있었습니다. thing model API는 동작했습니다:
   ```bash
   cd secrets && python ../tools/get_spec.py <DeviceID>
   ```
   DP 번호, 코드, 타입, 범위가 나옵니다 ([03_PROTOCOL.md](03_PROTOCOL.md) 3-2).

## 5-3. 동작 관찰 (읽기 전용)

```bash
python tools/monitor.py 20
```

로컬 연결을 열어 두고 기기가 보내는 변화만 기록합니다. 그동안 앱과 본체 버튼으로 하나씩 조작합니다.
- 앱이 실제로 쓰는 값 범위 (예: 목표 습도 45–100)
- DP끼리의 연동 (예: 전원을 끄면 가열·살균도 꺼짐, 자동을 켜면 목표 습도 100)
- 앱이 막는 조작 (예: 꺼진 상태에서 단계 변경)

## 5-4. 쓰기 테스트

```bash
python tools/write_test.py
```

5-3에서 **앱이 쓰는 값만** 한 번에 하나씩 보내고, push로 확인한 뒤 시작 상태로 되돌립니다.
이 단계에서 "자동 중에 단계만 보내면 자동이 유지된다"(앱은 자동 해제도 같이 보냄)를 찾았습니다.

## 5-5. 순수 Lua 구현

SmartThings 허브의 Lua 환경에는 암호 라이브러리가 없습니다. AES-128, SHA-256, HMAC을 직접 구현했습니다 (`driver/src/aes.lua`, `sha256.lua`).
- 기준 벡터: `tools/gen_vectors.py`가 Python cryptography와 tinytuya로 만든 값과 **바이트 단위로** 비교 (`test/test_crypto.lua`)
- 속도: 메시지 하나(만들기 + 검증 + 복호화)에 PC에서 약 1ms. 메시지가 작아서 허브에서도 충분합니다.

### 허브 소켓에서 주의할 것
- 타임아웃된 `receive`의 부분 결과는 믿지 않습니다 (cosock 버전마다 다름).
- `select`로 기다린 뒤 헤더 16바이트 → 본문 len바이트를 블로킹 `receive(n)`로 정확히 읽습니다 (`driver/src/transport.lua`).
- 처음에 `receive(1024)`를 썼더니 1024바이트가 찰 때까지 기다려서 모든 응답이 타임아웃만큼 늦었습니다 (협상 3초 → 수정 후 8ms).

## 다른 모델에 응용할 때

- 프로토콜이 **3.4**인지 (`tinytuya scan`의 Version). 3.3/3.5면 `tuya34.lua`를 고쳐야 합니다.
- DP 번호와 범위는 제품마다 다릅니다. `driver/src/amh.lua`의 매핑과 허용 값, `driver/profiles/`를 바꿉니다.
- 새 DP나 값은 **앱에서 쓰는 값만**, 한 번에 하나씩 시험하세요.

결과를 [이슈](https://github.com/type-han/amh-9900uv-smartthings-local/issues/new/choose)로 알려 주시면 지원 모델을 늘리는 데 도움이 됩니다.
