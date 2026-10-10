# CrossMouse

## v0.2 — 실행/종료가 가능한 Mac·Windows 데스크톱 앱

기존 v0.1은 Windows에서 콘솔을 켜고, Mac에서는 메뉴 막대 토글을 이용해야 했습니다. **v0.2부터 두 운영체제 모두 창과 시작/중지/종료 제어 기능을 제공합니다.** 실행 파일은 GitHub **Actions**의 성공한 최신 빌드에서 다음 아티팩트를 받습니다.

| 플랫폼 | 다운로드할 아티팩트 | 실행 |
| --- | --- | --- |
| Mac | `CrossMouse-macOS` | `CrossMouseMac.app` (로컬 개발 빌드는 기존 `dist/CrossMouseMac.app`) |
| Windows 10/11 x64 | **`CrossMouse-Windows-GUI`** | `CrossMouse.exe` |

**Windows 기존 버전에서 업그레이드:** 실행 중인 검은 콘솔의 `CrossMouse.Windows.exe`를 `Ctrl+C`로 **먼저 종료**하세요. 그렇지 않으면 새 앱은 TCP 49431을 열 수 없어 '기존 수신기 종료' 오류를 표시합니다. 새 앱은 **기존 페어링 키 파일을 그대로 재사용**하며 IP·키를 다시 입력할 필요가 없습니다. Mac과 Windows GUI 모두 실행할 때는 명확한 상태창이 표시되고, 창을 닫거나 `앱 종료`를 누르면 종료됩니다. Windows에서 최소화하면 시스템 트레이에 남으며, 트레이 메뉴에서 재열기/시작/중지/종료할 수 있습니다.

**필립스를 Mac으로 다시 돌릴 때는 두 동작이 필요합니다.**

1. 필립스 모니터의 영상 입력을 DVI로 변경합니다.
2. **Mac CrossMouse 앱에서 'Mac 듀얼 모니터 (DVI)'**를 선택합니다. 그 순간 Windows로의 마우스 전달을 중지하고, 삼성 → 필립스를 평소의 Mac 확장 모니터처럼 쓸 수 있습니다.

Windows 화면으로 가려면 필립스 HDMI 입력으로 전환한 뒤 Mac 앱에서 **'Windows 사용 (HDMI)'**를 선택합니다. 앱에서 `연결 중지`를 누르면 페어링 통신을 끊고 모든 입력을 Mac으로 돌려주지만 **선택해 둔 Windows 모드는 유지**합니다. 다시 `연결 시작`을 누르면 모드를 재선택할 필요가 없습니다. 필립스를 DVI로 돌렸다면 앱의 **Mac 듀얼 모니터 (DVI)**로 직접 전환하세요. **DVI/HDMI 영상 입력 자체를 소프트웨어로 자동 변경하는 기능은 아직 없습니다.**

**재연결 수정(v0.2.1):** Windows 수신기를 교체·재실행한 뒤 Mac이 `Windows 연결 대기 중…`에 오래 머무는 문제를 줄이기 위해 TCP 연결 대기 상태와 인증 지연 시 새 연결로 자동 재시도하도록 했습니다. 약 7초 안에 인증이 완료되지 않으면 해당 시도를 끊고 2초 후 새 연결을 시도합니다. 먼저 Windows 앱에 `Mac 연결 대기 중` 또는 `연결됨`이 표시되는지 확인하세요. Windows에 `TCP 49431 사용 중`이 보이면 기존 검은 콘솔 수신기를 먼저 종료해야 합니다.

Windows 앱은 실행되지만 Mac에 계속 `연결 대기 중`이 보인다면 **Mac 앱에서 연결 중지 → 연결 시작**을 누르거나, Mac 터미널에서 `python3 scripts/diagnose-pairing.py`로 포트와 인증을 확인할 수 있습니다. 진단 스크립트는 Windows에 입력 이벤트를 보내지 않으며 페어링 키 값을 출력하지 않습니다. 진단 전에 Mac 앱 연결을 잠시 중지해 수신기를 비워두세요.

**마우스 이동의 반응성:** Mac은 TCP의 Nagle 지연을 끄고, 입력 이벤트를 약 **8ms 간격(최대 약 125Hz)**으로 묶어 전송합니다. Windows에서도 TCP 저지연 설정을 적용합니다. 이벤트 처리량이 높은 무선 마우스에서 패킷이 쌓이는 현상을 줄이기 위한 변경입니다. 화면 FPS나 네트워크 지연이 반드시 125fps/8ms가 된다는 뜻은 아닙니다. Wi-Fi 간섭·공유기 무선 구간(기존 측정 63~134ms 왕복)이나 Windows 디스플레이 설정도 실제 커서 부드러움에 영향을 줍니다. 연결이 더 느리면 같은 공유기의 유선 연결 또는 5/6GHz Wi-Fi 상태를 확인하세요.

**Mac에서 오른쪽 Windows PC로 마우스·키보드를 넘기는 개인용 소프트웨어 KVM (v0.2 시험 버전)**

현재 목표 장비: 덮어둔 MacBook Pro M5 Pro → 왼쪽/가운데의 삼성 스마트 모니터(Mac) → 오른쪽 필립스 271E1(Mac DVI / Windows HDMI). 키보드·마우스 무선 동글은 삼성 모니터에 그대로 연결합니다.

평소 필립스는 DVI를 선택해 Mac 듀얼 모니터로 사용합니다. Windows 사용 시에는 **필립스 입력을 수동으로 HDMI로 변경**한 다음, Mac CrossMouse 앱 창에서 **Windows 사용 (HDMI)**를 선택합니다. DVI로 돌아오면 **Mac 듀얼 모니터 (DVI)**를 선택합니다.

삼성 화면 **오른쪽 끝**으로 마우스를 이동하면 Windows로 넘겨지고, Windows 화면 **왼쪽 끝**으로 마우스를 보내면 다시 Mac으로 돌아옵니다. 키보드 입력도 Windows 제어 중에만 전달됩니다. 모드가 꺼져 있으면 정상적인 Mac 듀얼 모니터 동작을 건드리지 않습니다.

Windows를 조작하는 동안 Mac 커서는 삼성 모니터의 오른쪽 경계에 **고정**됩니다. 이 동작은 필립스가 HDMI로 바뀌어도 Mac이 필립스를 숨은 확장 화면으로 계속 인식하는 구성에서 특히 중요합니다. Windows가 복귀 신호를 보내거나 연결이 끊기면 Mac 커서를 다시 삼성 화면 안쪽으로 이동합니다. 이벤트 탭이 중지되거나 커서 고정에 실패해도 Windows 입력 제어를 해제하도록 설계했습니다.

> **주의: 시험 버전입니다.** 기존 v0.1의 실제 Mac ↔ Windows 마우스·키보드 공유는 실기기에서 동작을 확인했지만, **새 Windows GUI와 v0.2 속도 개선은 장시간 실사용 검증 전**입니다. 모니터 HDMI/DVI 자동 전환·클립보드·로그인 시 자동 실행은 **아직 구현되지 않았습니다.**

## 요구 사항

- macOS 13 이상, Xcode Command Line Tools 및 Swift 6.0 이상 (Apple Silicon 지원)
- Windows 10/11, [Windows용 .NET SDK 10](https://dotnet.microsoft.com/download) — 개발/소스 실행 시. 이후 self-contained EXE 배포 가능
- 두 컴퓨터가 같은 **신뢰할 수 있는 로컬 네트워크**에 연결되어 있어야 함
- Windows의 한 화면이 필립스 모니터인 구성 (Windows 다중 모니터 전환은 아직 미지원)
- Mac에서 Accessibility 및 Input Monitoring 권한

### 빌드 도구 없이 실행 파일 받기

GitHub 저장소의 **Actions → CrossMouse Build → 최신 성공 실행 → Artifacts**에 macOS 앱 ZIP과 Windows x64 EXE를 생성하도록 워크플로를 준비했습니다. **Actions가 실제로 성공했는지 확인한 뒤** 사용하세요. 서명/공증되지 않은 개인용 시험 빌드이므로 macOS Gatekeeper·Windows SmartScreen에서 경고할 수 있습니다. 이 경고를 무시하도록 시스템 보안을 끄지 말고, 먼저 직접 빌드하거나 소스와 빌드 결과를 검토하세요.

## 1. Windows PC에서 수신기 실행

**일반 사용자는 다운로드한 `CrossMouse-Windows-GUI`의 `CrossMouse.exe`를 실행하면 됩니다.** 실행과 동시에 연결을 기다리기 시작하며, 창에서 `연결 시작` / `연결 중지` / `앱 종료`를 누를 수 있습니다. 새로운 GUI를 사용할 때는 이전 버전의 콘솔 수신기 창을 먼저 닫아야 합니다.

아래 명령어는 **소스 개발 또는 콘솔 방식이 필요한 경우에만** 사용합니다.

저장소를 내려받은 뒤, Windows PowerShell에서:

```powershell
dotnet run --project windows/CrossMouse.Windows
```

처음 실행하면 보안 랜덤 **64자리 페어링 키**를 만듭니다. 콘솔 수신기는 이를 화면에 한 번 표시하고, 새 GUI에는 **페어링 키 복사** 버튼이 있습니다. 키 파일은 `%LOCALAPPDATA%\CrossMouse\key`에 보관되며, 두 방식 모두 같은 키를 재사용합니다. 키는 GitHub, 채팅, 공개 파일에 올리지 마세요.

Windows 방화벽 팝업이 표시되면 **개인 네트워크에서만** TCP 49431 접근을 허용합니다. PowerShell에서 `ipconfig`로 Windows PC의 IPv4 주소(예: `192.168.0.42`)를 확인합니다.

## 2. Mac에서 페어링 설정

Mac 터미널에서 (아래 IP와 키는 **실제 Windows 값**으로 바꾸세요):

```bash
mkdir -p ~/.config/crossmouse
chmod 700 ~/.config/crossmouse
printf '%s\n' '192.168.0.42' > ~/.config/crossmouse/host
```

Windows에서 출력한 페어링 키는 터미널에 직접 명령 인수로 넣지 말고 다음 명령으로 안전하게 붙여 넣습니다. 아래 명령을 실행한 다음 키를 붙여 넣고 **Enter**를 누릅니다.

```bash
read -r -s "key?64자리 페어링 키: " ; echo
printf '%s\n' "$key" > ~/.config/crossmouse/key
unset key
chmod 600 ~/.config/crossmouse/key
```

> `read -s`는 기본 macOS zsh 문법입니다. 입력 내용이 화면에 표시되지 않습니다. 키가 유출되면 두 컴퓨터에서 새 키를 생성해 다시 페어링하세요.

## 3. Mac 앱 빌드 및 실행

저장소에서:

```bash
chmod +x scripts/build-mac-app.sh
./scripts/build-mac-app.sh
open dist/CrossMouseMac.app
```

앱이 **일반 창·Dock·메뉴 막대 ⇆**로 나타납니다. 첫 실행 시 macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용(Accessibility)** 및 **입력 모니터링(Input Monitoring)** 권한을 CrossMouse에 허용하고 앱을 완전히 종료했다가 다시 실행하세요. 권한이 없으면 입력 이벤트 탭이 생성되지 않아 마우스/키보드 공유가 동작하지 않을 수 있습니다. 창을 닫거나 앱의 **앱 종료** 버튼을 누르면 공유가 종료됩니다.

macOS 15 이상에서는 **로컬 네트워크** 접근도 허용해야 합니다. 시스템이 CrossMouse의 로컬 네트워크 접근을 묻는다면 허용하세요. 팝업을 놓쳤다면 **시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크**에서 CrossMouse를 확인합니다. 또한 원격 도구·IDE가 실행하는 `ping`이나 `nc`가 macOS의 *그 도구에 대한* 로컬 네트워크 권한 때문에 `No route to host`를 반환할 수 있습니다. 이런 경우 실제 Mac의 **Terminal.app**에서 `nc -G 3 -vz <windows-ip> 49431`를 별도로 확인하세요. 이를 이유로 Windows 방화벽이나 공유기 보안을 무조건 해제하지 마세요.

**앱을 새로 빌드한 직후 권한이 풀린 경우:** 이 로컬 앱은 개발용 ad-hoc 서명으로 빌드되며 바이너리 갱신 시 macOS가 다시 손쉬운 사용 권한 승인을 요구할 수 있습니다. 메뉴의 `Input capture unavailable: Accessibility not granted` 또는 `Input Monitoring not granted`를 보면 **시스템 설정 → 개인정보 보호 및 보안 → 기기 제어 및 데이터 접근**(macOS 버전에 따라 손쉬운 사용/입력 모니터링)에서 CrossMouseMac의 권한을 다시 확인하고, 메뉴의 **Retry input capture**를 선택하세요. 단순히 `Connected to Windows`인 것만으로 마우스 입력 감지가 동작한다는 뜻은 아닙니다.

Mac에 개인용 Apple Development 코드 서명 인증서가 이미 설치돼 있다면 `CROSSMOUSE_CODESIGN_IDENTITY=<인증서 SHA-1> ./scripts/build-mac-app.sh`로 로컬 빌드에만 지속적인 인증서 서명을 사용할 수 있습니다. 이 경우 재빌드마다 다른 ad-hoc 식별자가 생성되는 문제를 피할 수 있습니다. 인증서/서명키를 저장소에 넣거나 공유하지 마세요. 기존에 ad-hoc 서명으로 부여한 손쉬운 사용 권한은 서명 방식을 바꾼 뒤 새로 승인해야 할 수 있습니다.

CrossMouse 메뉴의 **Input capture installed**와 **Entered Windows (attempt N)** 항목으로 입력 감지와 화면 경계 인식을 각각 확인할 수 있습니다. 진단에는 키 입력 내용이 저장되지 않습니다.

터미널에서 직접 실행할 수도 있습니다:

```bash
swift run CrossMouseMac --host 192.168.0.42
```

모니터가 잘못 선택된 경우 `system_profiler SPDisplaysDataType` 등으로 Mac의 화면 배치를 확인하고, 실행 시 `--display-id N`으로 특정 CGDirectDisplayID를 선택할 수 있습니다. 기본은 'Samsung' 이름을 찾고, 없으면 macOS 주 디스플레이를 선택합니다.

## 사용 방법

| 상황 | 조작 |
| --- | --- |
| 평소 Mac 듀얼 모니터 | 필립스 DVI 선택 → Mac 앱 **Mac 듀얼 모니터 (DVI)** |
| Windows 사용할 때 | 필립스 HDMI 선택 → Mac 앱 **Windows 사용 (HDMI)** |
| Mac → Windows | 삼성 화면 오른쪽 끝으로 마우스 이동 |
| Windows → Mac | Windows 화면 왼쪽 끝으로 마우스 이동 |
| 입력 공유 일시 중단 | Mac 앱 **연결 중지** 또는 Windows 앱 **연결 중지** |
| 완전히 종료 | 각 컴퓨터에서 **앱 종료** (또는 일반 창 닫기) |
| 강제로 Mac으로 복귀 | Mac 키보드에서 **Ctrl+Option+Shift+Esc** |
| Windows-ready 모드 켜기/끄기 | Mac에서 **Ctrl+Option+Shift+F12** |

Mac **Command**는 Windows **Ctrl**로, Mac **Control**은 Windows **Win** 키로, Option은 Alt로 매핑합니다. Cmd+C/V 같은 일반적인 단축키를 Windows에서 그대로 쓸 수 있습니다. 한글은 Windows에 한국어 키보드/IME가 설치되어 있어야 하며, 한국어 IME 전환 키와 특정 특수키는 아직 실제 장치 검증이 필요합니다.

## 보안과 동작 구조

- Windows는 TCP 49431에서 수신 대기하고, Mac이 Windows IP로 접속합니다.
- 최초 연결 시 양쪽에 저장된 **256비트 공유 페어링 키**로 HMAC-SHA256 상호 인증합니다.
- 연결마다 양쪽의 128비트 랜덤 nonce로 키를 파생하고, 마우스/키보드 이벤트는 **AES-256-GCM**으로 암호화하고 무결성을 검증합니다. 통신 자체는 로컬 LAN에서만 작동하며 클라우드 서버가 없습니다.
- Windows는 인증에 성공한 연결이 `enter` 메시지를 전달했을 때만 OS에 입력을 실행합니다.
- Mac에서는 수신 버퍼에서 인증 응답을 소비한 직후 들어오는 복귀 메시지로 앱이 종료되던 바이트 인덱스 문제를 수정했고, 핸드셰이크+암호화 프레임 병합 및 모든 분할 경계 검사를 추가했습니다.
- Windows 수신기는 연결이 끊기거나 Mac으로 복귀하면 눌린 키와 마우스 버튼을 해제합니다. Mac도 연결이 끊기면 로컬 입력 모드로 돌아옵니다.
- 공개 Wi-Fi에 수신 포트를 열지 마세요. 페어링 키를 다른 사람에게 전달하지 마세요. macOS 권한은 사용자가 직접 허용해야 합니다.
- Windows UAC 보안 데스크톱이나 관리자 권한 앱으로의 입력, macOS 보안 입력(Secure Input), OS/키보드 설정에 따른 미지원 키는 별도로 제한됩니다.

## 빌드와 자동 테스트

```bash
swift test
swift build -c release
dotnet build windows/CrossMouse.Windows -c Release
dotnet run --project windows/CrossMouse.Windows -- --self-test
dotnet build windows/CrossMouse.Windows.App -c Release -p:EnableWindowsTargeting=true
```

윈도우 GUI 실행 파일을 만들려면:

```powershell
dotnet publish windows/CrossMouse.Windows.App -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/windows-gui
```

기존 콘솔 수신기를 계속 빌드하려면:

```powershell
dotnet publish windows/CrossMouse.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/windows
```

GitHub Actions에서도 macOS와 Windows 각각 빌드 및 프로토콜 테스트를 수행하도록 설정했습니다. OS 간 프로토콜이 서로 일치하는지 확인하도록 고정된 HMAC/세션 키 테스트 벡터를 사용합니다.

## 현재 구현 범위 / 남은 작업

구현: Mac GUI/Dock/메뉴 막대의 Mac 듀얼/Windows 모드 선택 및 시작·중지·종료, Windows GUI/트레이의 시작·중지·종료, Samsung 화면의 오른쪽 경계 감지, Quartz 이벤트 전달·로컬 차단, Windows Win32 입력, 왼쪽 경계 복귀, 네트워크 재연결, 자동 키 해제, 256비트 페어링 키/HMAC/AES-GCM, 기본 키·버튼·스크롤 매핑, Mac 측 8ms 이동 이벤트 통합과 TCP 지연 해제.

미구현: 필립스의 DDC/CI HDMI↔DVI 자동 변경/입력 자동 감지, Mac 디스플레이 자동 비활성화, 클립보드, Mac 앱 내부에서 페어링 키 입력, 로그인 시 자동 시작, 다중 Windows 모니터, 정밀 트랙패드 스크롤, 키보드 레이아웃/한영 전환 호환성 완성, v0.2 실물 장치 장기 검증.

**개인 입력을 다루는 프로그램이므로 프로토타입을 외부에 공유하거나 자동 실행하도록 설정하기 전에 양쪽 실제 장치에서 권한/연결 끊김/키 stuck/복구를 검수해야 합니다.**
