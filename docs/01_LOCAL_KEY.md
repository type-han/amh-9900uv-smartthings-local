# 1. Local Key 받기

Tuya 기기는 LAN에서 직접 제어할 수 있지만, 통신이 기기별 **Local Key**(16자)로 암호화됩니다.
이 키는 기기를 앱에 등록할 때 Tuya 클라우드가 만들어서 기기에 넣으므로, **LAN에서는 알아낼 수 없고 클라우드에서 한 번 받아야** 합니다.
한 번 받으면 이후 클라우드 없이 동작합니다.

> ⚠️ Local Key와 Tuya IoT Platform의 Access Secret은 비밀번호와 같습니다. 이슈·게시글·스크린샷에 올리지 마세요.

## 1-0. 준비

| 항목 | 설명 |
|---|---|
| 앱 | 가습기가 **Tuya Smart** 또는 **Smart Life** 앱에 등록되어 있어야 합니다 (검증: Tuya Smart) |
| PC | Python 3.7 이상 + [tinytuya](https://github.com/jasonacox/tinytuya) (`python -m pip install tinytuya`) |
| 네트워크 | PC와 가습기가 같은 LAN |

### 가습기 확인

```bash
python -m tinytuya scan
```

`productKey: 7f3qvffhri6hox6t`, `Version: 3.4` 인 기기가 AMH-9900UV입니다. IP와 Device ID(`gwId`)를 메모하세요.
앱에서도 확인할 수 있습니다: 기기 화면 → ✎(편집) → **기기 정보**의 **가상 ID** = Device ID.

## 1-1. Tuya IoT Platform 개발자 계정

1. https://iot.tuya.com 가입 (앱 계정과 별개. 같은 이메일을 써도 됩니다). 계정 유형은 **개인 개발자**.

## 1-2. 클라우드 프로젝트

1. **Cloud → Development → Create Cloud Project**
   - Industry: **Smart Home**, Development Method: **Smart Home**
   - Data Center: **여러 개를 함께 선택**합니다 (Western America, Eastern America, Central Europe, Western Europe, India).
     계정이 어느 곳인지 몰라도 1-3에서 기기가 보이는 곳이 정답입니다. 대한민국 계정은 **Western America**였습니다 (검증 1건).
2. API 서비스 승인 화면에서 **IoT Core**와 **Authorization Token Management**가 들어 있는지 확인합니다.

## 1-3. 앱 계정 연결

1. 프로젝트 → **Devices** 탭 → **Link Tuya App Account** → **Add App Account** → QR 코드
2. 휴대폰 앱 → **나(Me)** → 오른쪽 위 스캔 아이콘으로 찍고 승인 (연결 방식은 Automatic)
3. Devices 목록 위의 데이터 센터 선택을 바꿔 가며 **가습기가 보이는 곳**을 찾습니다. 그곳이 계정의 데이터 센터입니다.

## 1-4. IoT Core 구독 확인

wizard에서 `Code 28841001: 'IoT Core service is not subscribed.'`가 나오면:

1. **Cloud → Cloud Services**에서 **IoT Core** → **Trial Edition (무료)** 구독
2. 프로젝트 → **Service API** 탭에서 IoT Core가 승인되어 있는지 확인 (없으면 Go to Authorize)
3. 몇 분 뒤 wizard 다시 실행

## 1-5. tinytuya wizard

프로젝트 → **Overview**에서 Access ID와 Access Secret을 확인한 뒤, 레포 폴더에서:

```bash
mkdir secrets      # git에서 제외되는 폴더
cd secrets
python -m tinytuya wizard
```

| 질문 | 입력 |
|---|---|
| API Key | Access ID |
| API Secret | Access Secret |
| Device ID | 가습기 Device ID |
| Region | 1-3에서 찾은 곳: `us` = Western America, `us-e` = Eastern America, `eu` = Central Europe, `eu-w` = Western Europe, `in` = India, `cn` = China |
| Download DP Name mappings? | Y (실패해도 키는 받아집니다) |
| Poll local devices? | **Y** (IP와 프로토콜 버전도 채워짐) |

결과는 `secrets/devices.json`에 저장됩니다. 가습기 항목의 `key`가 Local Key입니다. 확인만 하려면:

```bash
python -c "import json;print([d['key'] for d in json.load(open('devices.json',encoding='utf-8')) if d.get('product_id')=='7f3qvffhri6hox6t'])"
```

### 로컬 접속 확인

```bash
cd ..
python tools/local_status.py
```

`{"dps": {"1": true, "13": 60, ...}}`처럼 나오면 키가 맞습니다.

## 주의

- 가습기를 앱에서 **삭제 후 재등록하거나 WiFi를 다시 설정하면 Local Key가 바뀝니다.** wizard를 다시 실행하고 SmartThings 기기 설정의 Local Key도 바꾸세요.
- IoT Core 무료 체험이 끝나도 이미 받은 키는 계속 쓸 수 있습니다.
- 키를 받은 뒤 IoT Platform 프로젝트에서 앱 계정 연결을 해제해도 로컬 제어에는 영향이 없습니다.
