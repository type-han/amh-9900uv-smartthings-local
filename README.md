# AMH-9900UV → SmartThings 로컬 제어

Tuya 기반 WiFi 가습기 **AMH-9900UV**를 클라우드 없이, 집 LAN 안에서 **SmartThings Edge 드라이버**로 직접 제어합니다.

> **English summary** — Local (cloud-free) control of the AMH-9900UV humidifier (Tuya WiFi, local protocol 3.4)
> from SmartThings. The Edge driver talks to the humidifier directly over TCP 6668, with AES-128, HMAC-SHA256
> and the 3.4 session-key negotiation implemented in pure Lua (the hub has no crypto library). No bridge, no cloud
> at runtime. You need the device's Local Key once (via Tuya IoT Platform + tinytuya). Exposes power, mist level
> (1/2/3/auto), target humidity, heat, sterilization, sleep, child lock and current humidity.
> Unofficial, not affiliated with the manufacturer or Tuya. Docs are in Korean.

> ⚠️ **비공식 프로젝트입니다.** 제조사 및 Tuya와 관계가 없고, 제조사가 지원하는 방법이 아닙니다.
> 기기 고장이나 데이터 손실에 대한 책임은 사용자에게 있습니다. [면책](#면책)을 먼저 읽어 주세요.

---

## 어떻게 동작하나

```
  SmartThings 앱 / 자동화
          │
  SmartThings 허브 (이 레포의 Edge 드라이버)
          │  TCP 6668, Tuya 로컬 프로토콜 3.4 (AES-128 + HMAC-SHA256, 세션 키는 접속마다 새로 협상)
          ▼
       가습기  ──(그대로)──▶ Tuya 클라우드 ◀── Tuya Smart 앱 (계속 사용 가능)
```

- Tuya 기기는 LAN 제어 포트(6668)를 가지고 있습니다. 통신은 기기별 **Local Key**로 암호화됩니다.
- Local Key는 **처음 한 번만** Tuya 클라우드에서 받습니다. 그 뒤로는 인터넷 없이 동작합니다.
- 허브에는 암호 라이브러리가 없어서 AES·SHA-256·HMAC과 3.4 협상을 순수 Lua로 구현했습니다. 트래픽 우회, 브로커, 브리지 서버가 필요 없습니다.

## 준비물

| 항목 | 설명 |
|---|---|
| AMH-9900UV | Tuya Smart 또는 Smart Life 앱에 등록된 상태. `productKey 7f3qvffhri6hox6t`, 프로토콜 3.4 |
| SmartThings 허브 | Edge 드라이버를 지원하는 허브 (검증: 스마트 홈 허브 V4) |
| PC | Python 3.7+ 와 [tinytuya](https://github.com/jasonacox/tinytuya) (Local Key 받을 때), [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli/releases) (드라이버 설치) |
| Tuya IoT Platform 계정 | 무료. Local Key를 받을 때만 필요 |

## 빠른 시작

1. **Local Key 받기** — Tuya IoT Platform에 앱 계정을 연결하고 `python -m tinytuya wizard` → [docs/01_LOCAL_KEY.md](docs/01_LOCAL_KEY.md)
2. **가습기 IP 고정** — 공유기에서 가습기 MAC에 DHCP 예약
3. **드라이버 설치** — SmartThings CLI로 채널을 만들고 허브에 설치 → [docs/02_DRIVER_INSTALL.md](docs/02_DRIVER_INSTALL.md)
4. **기기 추가** — SmartThings 앱 → 기기 추가 → 주변 기기 검색 → "AMH-9900UV 가습기"가 생기면
   기기 설정에 **IP, Device ID, Local Key**를 입력합니다. 몇 초 안에 온라인이 됩니다.

## SmartThings에서 할 수 있는 것

| 앱 이름 | 기능 | 비고 |
|---|---|---|
| 가습기 | 전원, 현재 습도 | 자동화 조건으로 쓸 수 있음 |
| 분무량 | 1단계 / 2단계 / 3단계 / 자동 | 자동을 켜면 기기가 목표 습도를 100%로 바꿉니다 (앱과 같음) |
| 목표 습도 | 45% … 100% (5% 단위) | 앱 범위와 같음 |
| 가열 / 살균 / 취침 모드 / 차일드락 | 켜기·끄기 | |

검증 (2026-11-22, 허브 V4): SmartThings 명령 → 가습기 → 상태 반영까지 약 0.2초. 앱·본체 버튼 조작도 즉시 반영됩니다.

## 알려진 제한 / 주의

- **허브당 가습기 1대**만 지원합니다.
- 가습기 **IP를 고정**해야 합니다. 바뀌면 기기 설정의 IP를 고쳐야 합니다 (Edge 드라이버는 Tuya 브로드캐스트로 다시 찾을 수 없음).
- 가습기를 앱에서 재등록하거나 WiFi를 다시 설정하면 **Local Key가 바뀝니다.**
- 수위·물 부족·고장 코드는 기기가 보내지 않아서 표시할 수 없습니다.
- 꺼짐 타이머는 넣지 않았습니다. SmartThings 자동화로 대신하세요.
- 분무량·목표 습도 카드 제목이 "모드"로 보일 수 있습니다 (표준 `mode` capability의 한계).
- Tuya 로컬 프로토콜 **3.4만** 구현했습니다. 다른 모델에 응용하려면 [docs/05_ANALYSIS.md](docs/05_ANALYSIS.md)를 보세요.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/01_LOCAL_KEY.md](docs/01_LOCAL_KEY.md) | Tuya IoT Platform, tinytuya wizard로 Local Key 받기 |
| [docs/02_DRIVER_INSTALL.md](docs/02_DRIVER_INSTALL.md) | 드라이버 빌드·설치, 기기 추가, 로그 보기, 허브 밖 테스트 |
| [docs/03_PROTOCOL.md](docs/03_PROTOCOL.md) | DP 목록, 확인한 동작, 3.4 프레임과 협상 |
| [docs/04_SAFETY.md](docs/04_SAFETY.md) | 보내는 값 제한, Local Key 관리 |
| [docs/05_ANALYSIS.md](docs/05_ANALYSIS.md) | 어떻게 분석했는지 (다른 Tuya 기기에 응용할 때) |

## 레포 구성

```
driver/      Edge 드라이버 (Lua). config.yml, profiles/, src/, test/
  src/       init.lua (드라이버), client.lua (연결 유지), amh.lua (DP 매핑),
             tuya34.lua (프로토콜), transport.lua (소켓), aes.lua, sha256.lua (순수 Lua 암호)
tools/       Python 도구: 상태 조회, DP 변화 기록, 쓰기 테스트, DP 사양 받기, 테스트 벡터 생성
docs/        설명서
secrets/     (직접 만듦, git 제외) tinytuya wizard 결과 — Local Key가 들어 있음
```

## 면책

- 이 프로젝트는 개인이 자기 기기를 분석해서 만든 **비공식** 결과물이며, 제조사 및 Tuya와 관계가 없습니다. 제품명과 상표는 각 회사의 것입니다.
- 드라이버는 앱에서 쓰는 값만 보내도록 막아 두었지만, 모든 경우를 보장하지 않습니다.
- 본인 소유 기기와 본인 네트워크에서만 사용하세요.
- MIT 라이선스에 따라 "있는 그대로" 제공되며 어떠한 보증도 없습니다.

## 감사

- [tinytuya](https://github.com/jasonacox/tinytuya) — 프로토콜 기준 구현과 Local Key 도구
- SmartThings 커뮤니티의 Tuya 로컬 Edge 드라이버들 — 구조 참고

## 라이선스

[MIT](LICENSE)
