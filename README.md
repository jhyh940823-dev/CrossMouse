# CrossMouse

## Mac v0.5.4 — 수정키 상태와 입력 대상

Mac에서 누른 수정키를 Windows 진입 뒤 놓았을 때 반대로 DOWN을 만들던
이벤트 토글을 실제 상태 기반으로 교체했습니다. 전환 대기 중 새로 시작한
Mac 단축키/클릭이 늦은 Windows 응답에 빼앗기지 않도록 입력 의도를 확인합니다.
공유 키보드의 기존 고정 매핑(Command→Ctrl, Control→Win, Option→Alt)은 유지하고
현재 입력 대상과 공유 키보드 붙여넣기(⌘V)를 창에 명시합니다.
Windows 재설치 없이 기존 v0.5.2 수신기를 사용합니다.
재현·검증 범위는 [MODIFIER-STATE-V054.md](docs/MODIFIER-STATE-V054.md)에 기록합니다.

## Mac v0.5.3 — IP가 바뀐 페어링 PC 자동 재연결

저장된 Windows 주소가 응답하지 않을 때 같은 로컬 IPv4 서브넷에서 기존
페어링 인증을 통과한 PC를 찾아 새 주소를 저장합니다. 정상 연결 중에는
검색하지 않으며, 검색 중/재연결 대기/실제 연결 주소를 Mac 창에 표시합니다.
**Windows v0.5.1/v0.5.2 재설치는 필요 없습니다.** F8, 마우스 속도, 화면
전환 및 클립보드 설정은 유지합니다. PC 전원·네트워크·수신 서비스는
동작해야 하며, 다른 네트워크/VPN까지 자동으로 찾는 기능은 아닙니다.
검색 범위와 검증 내용은 `docs/PEER-RECOVERY-V053.md`를 확인하세요.

## Mac / Windows v0.5.2 — Mac → Windows 텍스트 클립보드

Mac의 **Mac → Windows 텍스트 클립보드 공유**를 켜고, Mac에서 복사한 뒤
Windows로 커서를 넘겨 **Ctrl+V** 또는 붙여넣기 메뉴를 사용합니다. 한글·링크·코드·여러 줄 텍스트를
기존 페어링된 암호화 연결로 전달합니다. 양쪽 v0.5.2가 필요하며, 구버전과의 마우스 연결은 유지됩니다.

텍스트만 지원하며 이미지·파일·서식 및 반대 방향은 제외합니다. 최대 256KB(UTF-8)이고
로그인·잠금·UAC 화면에서는 공유하지 않습니다. 새로 복사하지 않았다면 Windows에서 복사한 내용을
덮어쓰지 않습니다. 공유 끄기는 Mac 창에서 가능하며, 이미 전달된 Windows 클립보드를 지우지는 않습니다.
복사 내용은 앱의 로그·임시 파일에 기록하지 않습니다. 자세한 동작과 검증 범위는
[TEXT-CLIPBOARD-V052](docs/TEXT-CLIPBOARD-V052.md)를 참고하세요.

## Windows v0.5.1 — 사용 중 새 창에 커서가 가려지는 경로 수정

**Mac v0.5.0은 그대로 사용합니다.** Windows 커서 창이 처음 보인 뒤 나중에 열린 다른 최상위 팝업에 가려져도 표시 성공으로 보고하던 경로를 수정했습니다. 색·속도·F8·모니터 전환 방식은 바꾸지 않습니다. 기존 검사처럼 커서를 매번 숨겼다가 다시 띄우지 않고, 같은 커서 표시를 유지한 채 새 팝업을 열고 반복해서 앞으로 올리는 검사에서 수정 전 실패를 확인했습니다.

화면 갱신 때 필요한 경우 커서 창 자체의 앞뒤 순서를 비활성화 상태로 복원합니다. 다른 앱의 포커스나 설정을 바꾸지 않으며, 진단에 `stack-repairs` 횟수를 표시합니다. 검증 범위와 실제 PC에서 아직 확인해야 하는 부분은 [조사 기록](docs/CURSOR-OCCLUSION-V051.md)에 구분합니다. 설치는 기존 서비스 설치 실행기를 사용하고, 기존 페어링과 Mac의 저장된 속도 설정은 유지합니다.

## v0.5.0 — 커서 표시 소유권, F8 복구, 로그인 전 서비스

평소 사용법은 유지합니다. **좌우 이동은 커서만 이동하고 HDMI 유지**, **F8/재생 키 한 번은 DVI 복귀**, **오른쪽 위 1.25초는 HDMI 진입**입니다. 저장된 속도·기존 페어링·Mac 로그인 항목은 유지합니다.

이번 수정은 색만 바꾸는 작업이 아닙니다. 원격 조작 동안 커서 표시를 CrossMouse가 계속 맡고, Windows의 표시 플래그만 보고 표시를 끄던 조건을 제거했습니다. 기본 생성자로 실제 Chrome의 손/텍스트/크기조절/숨김/텍스트 경계를 오가는 검사와 폴더 선택창의 그리기·클릭 통과를 확인합니다. 검사환경 결과를 사용자 PC에서의 최종 해결과 혼동하지 않습니다.

F8은 이전 키 뗌 누락으로 계속 막히지 않도록 복구하며, DDC 실행과 입력 감지 복구도 제한 시간 안에 처리합니다. 마우스는 전송 시각을 기준으로 보간하고 밀린 입력은 제한합니다. 네트워크가 끊기거나 인증된 완성 프레임이 5초간 없으면 입력을 풀어 다시 연결할 수 있게 합니다.

**Windows 설치:** 소스를 압축 해제한 뒤 `Install-CrossMouse-Service.cmd`를 실행합니다. 이미 설치한 .NET 10 SDK로 이 소스를 빌드하고, Y 확인과 관리자 승인을 받습니다. 처음 설치할 때는 키보드·마우스를 PC에 직접 연결해 승인하세요. 설치 위치는 `C:\Program Files\CrossMouse\CrossMouse.exe`이며 바탕화면에 바로가기를 만듭니다. 기존 키를 재사용하고 이전 실행 파일을 백업하며, 업그레이드 실패 시 복구합니다.

서비스는 로그인 전부터 실행하는 별도 권한 기능입니다. **페어링된 Mac이 Windows 로그인·보안 화면에 입력을 보낼 수 있도록 허용**하는 것이므로, 신뢰하는 개인 기기에서만 설치하세요. Windows 암호·UAC·보안 프로그램을 끄거나 자동 로그인하지 않습니다. Mac은 먼저 로그인되어 있어야 하고 양쪽 네트워크가 연결되어야 합니다. 실제 사용자 PC의 부팅 후 PIN 로그인/UAC 확인은 별도로 남아 있습니다. BIOS/BitLocker 같은 Windows 실행 전 화면은 지원하지 않습니다.

서비스 제거는 관리자 PowerShell에서 `scripts/Install-Windows.ps1 -UninstallService`입니다. 키·백업 파일은 보존됩니다. 자세한 수정 근거와 검사 한계는 [재개 검증 기록](docs/RELIABILITY-RESUME.md)에 있습니다.

## Windows v0.4.4 — 커서 계산·표시 주기 통합

**Mac v0.4.3은 그대로 사용합니다.** F8/재생키, HDMI 유지 좌우 왕복, DVI 전환, 페어링, 저장된 37% 등의 속도 설정과 이동 보정 수식은 바꾸지 않습니다.

Windows v0.4.0은 좌표를 `PeriodicTimer(8ms)`로 갱신하면서, 기본 커서가 없는 경우의 보조 표시 창은 별도의 `System.Windows.Forms.Timer(8ms)`로 갱신했습니다. 둘은 같은 시계가 아니며 `WM_TIMER`에 8ms를 적어도 실제 8ms 표시를 보장하지 않습니다. Windows 11에서는 숨긴 앱의 `timeBeginPeriod` 요청 역시 높은 해상도를 보장하지 않습니다. 이는 코드에서 확인한 표시 간격의 결함이며, 사용자 기기에서 모든 끊김의 유일한 원인으로 확인한 것은 아닙니다.

이제 대기 가능한 고해상도 타이머가 계산을 진행하고 **계산 직후 동일 주기로 보조 표시를 요청**합니다. 표시 스레드가 늦어져도 최신 좌표를 읽는 요청 하나만 대기하며, 이미 지난 프레임을 줄 세워 재생하지 않습니다. 입력 수신/UI/암호화는 그대로 분리되고 그리기가 끝나기를 입력 스레드가 기다리지 않습니다. 커널 타이머 대기 중에는 스레드가 잠들며 바쁜 대기나 Windows 시스템 설정 변경은 없습니다. 변화 없는 보조 커서를 계속 다시 칠하지 않습니다. 연결 종료는 타이머 대기를 깨우고 표시/입력을 해제합니다.

`--pointer-cadence-test`는 Windows 검사환경에서 이전 Forms 타이머와 새 시계로 구동한 실제 표시 창의 간격을 각각 측정합니다. 측정값은 가상 Windows의 관찰값이고 사용자 모니터의 FPS가 아닙니다. 별도로 느린 표시 스레드에 1,000회 요청해도 하나만 대기하는지, 입력 해제 시 표시가 사라지는지, 대기 중 취소를 확인합니다. 실제 네트워크 지연/패킷 몰림은 별도 원인이 될 수 있으므로 이 수정이 네트워크 끊김까지 없애지는 않습니다.

근거: [SetTimer 최소 주기](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-settimer), [timeBeginPeriod와 숨긴 Windows 앱](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod), [고해상도 대기 타이머](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw).

## Mac v0.4.3 — F8의 기능키/미디어 입력 경로 구분

v0.4.2는 `keyDown/keyUp`의 표준 F8만 받았습니다. macOS의 재생·일시정지 신호는 별도의 `systemDefined` 이벤트라 기존 이벤트 마스크에 포함되지 않았습니다. v0.4.3은 이 입력도 복귀 키로 처리합니다. HDMI/전환 진행 중에만 적용하고, DVI 상태의 재생 동작과 다른 미디어 키(볼륨·밝기·이전/다음)는 그대로 통과시킵니다. 입력 장치를 식별하는 기능은 아니므로, 같은 재생·일시정지 신호를 보내는 별도 버튼도 HDMI 상태에서는 DVI 복귀로 동작합니다.

기능키와 미디어키는 눌림/반복/뗌 상태를 따로 관리합니다. 전환 후 뗌을 누락하지 않고, 수정키를 조합한 입력이나 다른 미디어 이벤트를 삼키지 않습니다. macOS 기능키 모드·키 매핑·Windows 앱·로그인 설정·저장된 커서 속도는 바꾸지 않습니다.

검증 구분: 사용자에게 요청한 30초 수동 진단에서는 키 이벤트를 확보하지 못했습니다. 따라서 실제 사용자가 누른 키의 종류는 확정하지 않았습니다. 별도의 태그된 합성 신호로 실행 중인 v0.4.2를 검사했을 때 표준 F8은 DVI 복귀를 처리했지만 재생·일시정지 신호는 누름/뗌 모두 통과시켜 HDMI 상태가 유지됐습니다. 통과한 시험 신호는 임시 후단 탭에서 차단해 미디어 앱을 조작하지 않았습니다. 새 코드는 실제 `CGEvent/NSEvent` 디코더와 마스크를 포함해 검사하며, 합성 신호 결과를 실제 키보드 성공 확인으로 표현하지 않습니다.

## Mac v0.4.2 — DVI 복귀를 F8 하나로

필립스가 HDMI인 동안 **F8 한 번**으로 Mac 화면(DVI)으로 복귀합니다. 커서가 삼성 Mac에 있든 필립스 Windows에 있든 동일하며, 모서리 이동이나 조합키는 필요하지 않습니다. 누르고 있는 동안 반복 전환하지 않고, 해당 F8의 누름/뗌을 앱에 전달하지 않습니다. 이미 Mac 듀얼(DVI) 상태이면 F8은 원래 앱으로 전달합니다. Ctrl/Alt/Shift/Command를 조합한 F8은 가로채지 않습니다. 이전 Ctrl+Alt+Shift+D 지정은 제거했습니다.

**Windows v0.4.0은 그대로 사용합니다.** HDMI 유지 상태의 좌우 커서 왕복, 오른쪽 위 1.25초 HDMI 진입, 저장된 커서 속도, 로그인 자동 실행, 비상 복귀는 변경하지 않습니다. F8을 미디어 키로 보내는 키보드는 표준 기능키 모드가 필요할 수 있으며, 앱은 키보드 시스템 설정을 임의로 바꾸지 않습니다.

## Mac v0.4.1 — HDMI 화면 유지 + 커서만 왕복 + Windows 속도 조절

**Windows v0.4.0 그대로 사용합니다. Windows 재설치나 페어링/자동 실행 재등록이 필요하지 않습니다.** 이번 변경은 Mac 입력 제어와 UI에만 적용하며, 기존 `handoff-2` 준비/표시 확인 프로토콜을 재사용합니다.

- **Mac 듀얼(DVI):** 필립스 오른쪽 위에서 기존 1.25초 카운트다운 → HDMI로 전환하고 Windows 커서를 받습니다.
- **삼성 Mac + 필립스 Windows(HDMI):** Windows 왼쪽 끝에서는 **커서만** 삼성 Mac으로 넘어갑니다. 필립스는 Windows 화면을 유지합니다. 삼성 오른쪽 끝으로 다시 움직이면 새 입력 세션을 준비/확인한 뒤 Windows로 넘어가며, 모니터 명령이나 카운트다운은 반복하지 않습니다. X 버튼도 창과 커서 제어만 반환하며 HDMI는 유지합니다.
- **DVI는 명시적으로:** `Ctrl + Alt(Option) + Shift + D` 또는 Mac 앱의 **필립스를 Mac 화면(DVI)으로** 버튼을 사용합니다. 커서가 Windows에 있어도 단축키를 Mac 입력 감지 단계에서 처리합니다. `Ctrl + Alt(Option) + Shift + Esc`는 기존처럼 비상 입력 복귀만 하고 모니터 입력은 바꾸지 않습니다.
- **속도:** Mac 앱의 **Windows 커서 속도** 슬라이더(25–150%)로 전송 이동량을 조절합니다. 기본은 종전의 **50%**, 100%는 v0.4.0의 이동량입니다. 작은 HID 이동은 정수 나머지를 누적해서 사라지지 않게 하며, 제어권/속도가 바뀌면 이전 나머지는 버립니다. Mac 자체 속도나 Windows 시스템 설정은 변경하지 않습니다. 설정은 Mac에 저장됩니다.

화면 선택과 입력 소유 상태를 `AutomaticHandoff` 안에서 분리했습니다. `left-edge/window-close` 응답은 로컬 입력 상태로만 전환하고, DVI 명령 상태는 사용자의 별도 요청으로만 진입합니다. 재진입은 매번 새 전환 ID를 사용해 이전 입력/복귀 응답이 섞이지 않습니다. 취소나 연결 장애를 모니터가 DVI로 바뀐 것으로 취급하지 않습니다.

검사: HDMI 유지 상태의 20회 왕복, 재진입 시 DDC 상태 생략, X의 화면 유지, 양쪽 입력 상태에서 명시적 DVI 복귀, 재진입/복귀 취소 및 오래된 응답 무시, 25% 단일-count 누적, 37% 장기 반올림 오차, 방향 반전, 제어권 경계의 잔여 이동 초기화. 이는 자동 검사의 범위이며 사용자 환경의 속도 취향과 실제 모니터 확인을 대신하지 않습니다.

## 0.4.0 candidate — correlated monitor/input ownership

개발 브랜치 `fix/handoff-ownership`에서 자동 전환 구조를 교체했습니다. 고정 대기시간이 지나면 입력을 넘기던 코드는 제거했고, **Windows 준비 확인 → HDMI 명령 → 대상 화면/커서 표시 확인 → 같은 전환 ID의 입력 제어 승인** 순서로 처리합니다. 모든 자동 입력과 복귀 응답은 전환 ID를 포함하며, 오래된 응답은 새 전환을 되돌릴 수 없습니다. 수동 공유와 기존 원격 X/로그인 실행 경로는 유지합니다.

확인된 코드 결함과 실제 장치에서 아직 확인하지 못한 사항은 [조사 기록](docs/HANDOFF-INVESTIGATION.md)에 구분했습니다. **사용자 PC에 적용 완료된 안정 버전이라는 뜻이 아닙니다.** 모니터 입력 읽기를 지원하지 않는 경우에도 HDMI가 확인됐다고 표시하지 않습니다. 개발 중 키·방화벽·로그인 보안 설정을 변경하지 않습니다.

## v0.3.7 — 자동 HDMI 진입 시 정지 커서 오복귀 수정

사용자 보고: HDMI/DVI 시험 버튼은 작동하지만 핫코너로 전환하면 Windows 커서가 보이지 않고, 바로 움직이지 않으면 Mac으로 돌아옴.

**수정 전 재현:** `f77158c`의 Windows CI `38052566633`에서 실제 주입기를 진입시킨 뒤, 디스플레이 변경 때 일어날 수 있는 커서 재배치를 왼쪽 경계로 모의했습니다. 원격 이동을 한 번도 보내지 않았는데 `Stationary cursor bounced to Mac (smooth=False, 0ms)`로 실패했습니다. 실제 필립스의 HDMI 신호 타이밍을 측정한 결과는 아닙니다.

- **의도적인 복귀:** 좌표만 주기적으로 보던 판정을 바꿔, 원격 마우스의 실제 왼쪽 이동이 경계까지 적용된 경우에만 Mac 복귀를 요청합니다. 정지, 위아래 이동, 디스플레이에 의한 커서 재배치는 복귀 사유가 아닙니다. 남은 보정 이동/복귀 표시는 재진입 때 초기화합니다. 비상 복귀·연결 끊김·X 버튼의 안전 복귀는 그대로입니다.
- **보이는 위치로 진입:** 핫코너 입력의 윗부분 좌표를 그대로 쓰지 않고, 자동 HDMI 전환에서는 Windows 화면 중앙으로 진입합니다. 위치 설정 후 실제 절대좌표 마우스 이동 이벤트를 한 번 보내 커서 표시 갱신을 요청합니다. 클릭·포커스 변경·전역 커서 숨김 카운터 조작은 하지 않습니다. 수동 삼성→Windows 경계 진입은 기존 왼쪽 진입 방식을 유지합니다.
- **영상 전환 대기:** DDC 명령 종료 직후 입력을 넘기지 않습니다. Mac에서 최소 1.5초, 마지막 디스플레이 변경 알림 후 최소 0.4초 기다린 뒤 진입합니다(최대 5초). 이는 화면 신호 완료를 확인하는 기능이 아니라 제한된 안정 대기입니다. 그 사이 모드 변경·연결 중지·비상 복귀가 있으면 오래된 DDC 완료 콜백이 입력을 다시 넘기지 못합니다.
- **불필요한 Mac 회수 방지:** 필립스 화면 변경 알림만으로 원격 입력을 중단하지 않습니다. 커서를 고정하는 삼성 모니터의 실제 ID/좌표가 바뀌거나 사라지는 경우에만 회수합니다.

Mac/Windows 양쪽 v0.3.7 적용이 필요합니다. 페어링 키·방화벽·로그인 설정 정책은 변경하지 않습니다. Windows를 새 폴더에 빌드했다면 새 앱에서 로그인 자동 실행 경로를 확인하세요. 기존 HDMI/DVI 시험 확인값은 유지하며 사용자의 실제 모니터 전환 검증은 별도입니다.

추가 검사: Windows `--automatic-entry-test`(정지 3초, 커서 외부 재배치, 수직 이동, 의도적인 왼쪽 복귀, 재진입, 가운데 위치/커서 표시), Swift `MonitorHandoffGateTests`(대기·취소·오래된 완료·화면 변경·중앙 진입 메시지). Windows 실제 원격 X·로그인 자동 실행 회귀도 유지합니다. 참고: [Microsoft MOUSEINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-mouseinput), [GetCursorInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getcursorinfo), [Apple display change notification](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification).

## v0.3.6 — Mac/Windows 로그인 자동 실행

각 앱에 **Mac 로그인 시 자동 실행 / Windows 로그인 시 자동 실행** 체크박스를 추가했습니다. 기본값은 꺼짐이고, 사용자가 켤 때만 해당 컴퓨터의 현재 사용자 계정에 등록합니다. 앱 실행이나 업데이트만으로 자동 등록하지 않습니다. 등록 후에는 **다음 로그인 때 창 없이 시작**하고, 기존 키/IP로 연결을 시도합니다. 로그인 시점에 상대 컴퓨터가 꺼져 있거나 네트워크가 늦게 준비돼도 기존 재연결 처리를 사용합니다.

- **Mac:** macOS 13 이상 `SMAppService.mainApp`의 로그인 항목을 사용합니다. 앱 안에서 등록 상태와 승인 대기를 구분하며, 시스템 설정에서 승인이 필요하면 **로그인 항목 설정**을 엽니다. 자동 실행 여부는 실제 OS 등록 상태를 읽습니다. 로그인 실행은 Apple Event의 로그인 표시로 구분하고, 수동 실행은 창을 표시합니다. `--background`도 지원합니다.
- **Windows:** 현재 사용자 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`의 `CrossMouse` 값 하나에 `"실제 CrossMouse.exe 경로" --background`를 등록합니다. 다른 시작 항목·방화벽·로그인 암호·자동 로그인 설정은 건드리지 않습니다. **등록한 EXE는 이동/삭제하지 마세요.** 새 버전 폴더로 바꾸면 새 앱에서 체크해 등록 경로를 바꿉니다. 작업 관리자에서 시작 앱을 별도로 사용 안 함으로 지정했다면 그 설정도 확인해야 합니다.
- **창/종료:** 로그인 실행은 Mac 메뉴 막대와 Windows 트레이에서 시작합니다. 수동으로 앱을 다시 열면 설정창이 열립니다. Windows는 같은 계정/세션에서 수신기를 중복 실행하지 않고 기존 창을 다시 엽니다. X는 여전히 창만 숨기며, **완전 종료는 이번 실행만 끝냅니다. 다음 로그인에도 실행되지 않게 하려면 자동 실행 체크를 해제**하세요.
- **입력 전환:** Mac은 재시작 후 안전한 **Mac 듀얼 모니터 모드**로 시작합니다. 모니터 입력을 임의로 바꾸지 않습니다. 기존에 실제 HDMI/DVI 전환 시험을 모두 통과하고 켜둔 핫코너 설정은 그대로 보존합니다. 시험 미완료 상태에서는 자동 DDC 전환이 켜지지 않습니다. 기존 v0.3.5의 입력 수신/암호화/원격 X 수정은 그대로입니다.

**중요: 전원 켜기 직후가 아니라 사용자 로그인 후입니다.** Windows 로그인 화면의 비밀번호/PIN 입력을 이 기능이 대신하지 않습니다. Mac의 FileVault 부팅 잠금 해제도 마찬가지입니다. 보안을 낮추거나 자동 로그인을 켜지 않습니다. 로그인 전에도 같은 입력 장치가 꼭 필요하면 별도의 USB 전환 수단 또는 PC 입력 장치가 필요합니다.

검증 범위: Mac 로그인 실행 분류 테스트는 OS 등록을 변경하지 않습니다. Windows 자동 실행 검사는 실제 Run 키 대신 임시 비-Run 키에서 등록/해제·경로 인용·지속성을 확인하고, 실제 WinForms의 `--background` 방식으로 창 없이 수신/인증/재열기/X/종료를 검사합니다. 실제 사용자 로그아웃/재부팅 검증은 별도이며, 개발 도중 사용자 PC를 재부팅하지 않습니다.

근거: [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [Microsoft Run/RunOnce](https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys).

## Windows v0.3.5 — 원격 제목 표시줄 클릭과 입력 수신 스레드 분리

사용자가 확인한 차이는 **PC에 동글 직접 연결 → X 정상, Mac에서 공유한 입력 → X 클릭 후 공유 중단**입니다. v0.3.4를 바꾸기 전에 새 회귀 검사를 추가해 Windows CI에서 두 실패를 확인했습니다.

- UI 메시지 처리를 1.5초 보류하면 같은 프로세스의 암호화 `ping/pong`도 멈췄습니다.
- `Form.Close()`를 직접 호출하는 대신 실제 암호화 `move` / `button down` / `button up`을 수신기에 보내 Windows의 기본 X 버튼을 눌렀습니다. `WM_NCLBUTTONDOWN/HTCLOSE`가 관찰됐지만 `leave` 응답이 제한 시간 안에 오지 않았습니다.

재현용 커밋: `f66000f` (기존 v0.3.4 동작은 그대로 두고 테스트만 추가). Windows CI 실행: `38046424801`. 이 실패 실행은 진단용이며 배포본이 아닙니다.

코드에서 `ReceiverService.Start()`가 WinForms UI에서 직접 `RunAsync()`를 호출해 `WindowsFormsSynchronizationContext`를 유지하고 있었습니다. 따라서 입력 수신·마우스 버튼 해제·복귀 판정·생존 응답이 창의 UI 처리에 의존했습니다. v0.3.5는 이 루프를 `Task.Run`으로 시작하고, 수신 서비스와 암호화 채널의 비동기 I/O에 `ConfigureAwait(false)`를 적용합니다. UI 상태 표시는 기존 `BeginInvoke` 경로를 사용합니다. 프로토콜·페어링 키·포트·Mac 앱·모니터 설정은 바꾸지 않습니다.

검사 명령(Windows에서만 실행, 임시 키/포트 사용):

```powershell
dotnet run -c Release --project windows/CrossMouse.Windows.App -- --receiver-ui-independence-test
dotnet run -c Release --project windows/CrossMouse.Windows.App -- --remote-caption-test
```

두 번째 검사는 CI의 실제 커서를 잠깐 이동하고, 네이티브 X 클릭 → 숨김 → 동일 연결로 재진입 → 창 복원 → 두 번째 네이티브 X 클릭을 확인합니다. 단순 함수 호출 테스트와 구분하기 위해 네이티브 X 좌표가 확인되지 않거나 클릭이 관찰되지 않으면 실패합니다. 사용자 PC에서는 평소 실행 명령에 테스트 옵션을 붙이지 않습니다.

참고: Microsoft의 [ConfigureAwait FAQ](https://devblogs.microsoft.com/dotnet/configureawait-faq/)는 UI에서 시작한 비동기 작업이 UI 컨텍스트로 돌아오는 동작을 설명합니다. CI 재현과 실제 사용자 PC의 최종 체감 확인은 서로 다릅니다.

## Windows v0.3.4 — 원격 X 클릭 후 WinForms 정지 가능성 수정

**확인된 사실:** Windows에서 Mac 마우스로 CrossMouse 창의 X를 누르면 창이 숨겨지지 않고 커서가 멈추는 실기기 문제가 반복되었습니다. 기존 자동 테스트는 수신기가 연결되는지만 확인하거나, 입력 잠금 경쟁 없이 `Form.Close()`를 호출했기 때문에 이 상황을 검증하지 못했습니다.

**수정한 잠재 교착 경로:** 이전 Windows GUI의 `OnFormClosing` 콜백은 UI 스레드에서 `ReturnCursorToMacAsync()`를 직접 호출했고, 이 함수는 첫 비동기 중단 지점에 도달하기 전에 마우스 주입기의 `_sync` 잠금을 획득했습니다. 다른 스레드가 마우스 클릭을 주입하면서 잠금을 잡은 채 UI 메시지 처리를 기다리면 양쪽이 서로 기다릴 위험이 있습니다. 이번 버전은 **X를 누르면 UI 스레드에서 즉시 창만 숨기고, 마우스 복귀 및 암호화된 `leave` 전송은 별도 작업 스레드에서 실행**합니다. 입력 통계 타이머·마우스 보정 설정·종료 처리도 UI 스레드에서 마우스 잠금을 기다리지 않게 변경했습니다.

Windows CI에는 원격 `enter` 상태에서 **실제로 다른 스레드가 입력 잠금을 잡고 있는 동안 X를 누르고, GUI 응답이 650ms 안에 돌아오는지** 검사하는 회귀 테스트를 추가했습니다. 이후 암호화 `leave`, 숨긴 상태의 연결, 복귀, 완전 종료도 검사합니다. 이는 특정 교착 경로를 검증하는 테스트이며 사용자의 실제 장치에서 마우스가 부드럽게 동작한다고 보장하지는 않습니다.

**설치:** 기존 Windows `CrossMouse.exe`를 완전 종료한 다음, 저장소 최신 `main` 소스를 새로 받아 **Windows .NET 10 SDK에서 직접 다시 빌드**하세요. 이전 `CrossMouse-built`는 자동으로 갱신되지 않습니다. 창 제목에 `v0.3.4`가 보여야 새 버전입니다. Mac 앱은 현재 v0.3.3을 그대로 사용합니다. 실제 기기에서 X를 누르는 재시험은 기본 연결을 확인한 뒤 진행하며, 문제가 있으면 X 대신 창 최소화를 사용하고 Mac의 **Control+Option+Shift+Escape**로 비상 복귀하세요.

## v0.3.3 — Windows 수신기 응답 확인·Mac 커서 갇힘 방지

실제 사용 중 Windows 앱을 X로 숨긴 뒤 Mac 커서가 Windows로 넘어가지 못하거나, Mac이 커서를 오른쪽 끝에 고정했는데 Windows가 반응하지 않는 문제가 보고됐습니다. 원격 수신기 TCP가 연결됐다고 표시되는 것만으로 실제 입력 처리 가능 여부가 보장되지 않습니다.

**v0.3.3부터 Mac/Windows 양쪽 앱을 함께 업데이트해야 합니다.**

- Windows 수신기가 Mac의 암호화된 `ping`에 실제로 응답하는 `pong` 지원. Mac은 새 앱이 2.5초 내에 응답하지 않으면 Windows 모드를 해제하고 Mac 커서를 복구합니다. 응답이 없는 수신기에서는 처음부터 Mac 입력 가로채기를 시작하지 않습니다.
- 오른쪽 경계에서 Mac이 `enter`를 보낸 뒤 Windows 수신기가 실제로 `SetCursorPos`로 제어권을 받을 수 있을 때만 `entered` 확인을 보냅니다. 1.5초 내 확인이 없으면 Mac이 로컬 커서를 복구하고 자동 재진입을 중지합니다.
- Windows X 버튼을 누르면 창만 트레이로 숨기고, 현재 Windows를 조작 중이었다면 암호화된 `leave`로 Mac 커서를 먼저 돌려주는 안전 동작(v0.3.2)을 유지합니다. 숨겨진 상태에서도 `ping/pong`와 `enter/entered`가 계속 작동해야 합니다.
- Mac 상태는 이제 실제 수신기 상태를 구별해 **`Windows 수신기 정상 응답 · 연결됨`** 또는 **`TCP 연결됨 · Windows 수신기 응답 없음`**으로 표시합니다. 응답이 없을 때는 Windows가 여전히 켜졌더라도 Mac 마우스를 잡아두지 않습니다.

**교체 순서:** Mac 버전은 기존 권한이 유지되는 서명으로 빌드해 실행하고, Windows PC에서는 기존 CrossMouse를 작업 표시줄 숨겨진 아이콘에서 `완전 종료`한 뒤 GitHub의 최신 `CrossMouse-Windows-GUI` ZIP 압축을 풀고 새 `CrossMouse.exe`를 실행하세요. Windows GUI 상단에 `v0.3.3`이 표시돼야 합니다. Mac에서 정상 응답이 확인되면 `Windows 사용 (HDMI)` 모드를 선택하고 삼성 오른쪽 끝으로 이동해 실제 전환을 확인하세요.

Mac 비상 복귀: **Control+Option+Shift+Escape**. 기존 Windows v0.3.2나 그 이전 실행 파일은 ping/pong과 entered를 보내지 못하므로 v0.3.3 Mac이 안전하게 전환을 막습니다. **Windows 실제 기기에서 최종 작동 확인은 아직 필요합니다.**

## Windows v0.3.2 — X 버튼을 누르면 Mac 커서 안전 복귀

Windows GUI의 `X` 버튼을 Mac에서 전달한 마우스로 누를 때 커서가 Windows에 갇히는 실기기 문제가 보고되었습니다. 연결 유지만 시험했던 v0.3.1 테스트는 이 상황을 재현하지 못했습니다.

v0.3.2에서는 **X를 눌러 Windows 창을 숨길 때 Mac에서 제어 중이라면 암호화된 `leave` 메시지로 Mac 마우스 제어권을 즉시 돌려줍니다.** Windows 수신기와 연결 자체는 계속 살아 있고, Mac에서 다시 오른쪽 화면 끝으로 넘기면 Windows에 재진입할 수 있습니다. X를 눌렀을 때 커서가 Windows를 계속 조작하는 대신 Mac으로 잠깐 돌아오는 것은 **의도적인 안전 동작**입니다. 작업 표시줄 트레이에서 창을 다시 열 수 있습니다.

Windows CI의 GUI 테스트는 이제 *페어링된 Mac을 모의 구현하여 실제 암호화 `enter`를 Windows에 전달하고, 원격 조작 중 X → 암호화 `leave`로 복귀 → 창이 숨겨진 상태에서 `enter` 재진입 → 다시 X로 복귀 → 수신기 실행 및 종료*를 검증합니다. 실제 기기에서 연결 복귀가 성공했는지는 교체 후 확인이 필요합니다. 긴급한 경우 Mac에서 **Control+Option+Shift+Escape**로 Windows 조작을 강제로 해제할 수 있습니다.

## Windows v0.3.1 — X 버튼 종료 문제 확인용 수정

Windows의 `X` 버튼은 이제 앱의 모든 일반적인 창 닫기 요청에서 **무조건 창만 숨기고 수신기를 유지**합니다. 작업 표시줄 알림 영역에서 더블 클릭하면 다시 열리고, **`앱 종료` 또는 트레이의 `완전 종료`**로만 정상 종료합니다. 창 제목과 본문에 `CrossMouse v0.3.1`을 표시해 구버전 실행 파일을 구별할 수 있습니다.

Windows CI에는 **실제 WinForms 앱 창을 X로 닫은 뒤 폼/수신기 생존 확인 → 숨겨진 상태에서 실제 TCP 페어링 인증 → 트레이 복원 → X로 재숨김 → 앱 종료 후 수신기 정리**를 확인하는 `--gui-self-test`를 추가했습니다. 이 테스트는 임시 키와 임시 TCP 포트만 쓰며 기존 설정을 건드리지 않습니다. 만약 X를 눌렀을 때 여전히 끊긴다면 창 제목이 `v0.3.1`인지 먼저 확인하세요. 동일 버전에서도 발생하면 Windows 작업 표시줄의 숨겨진 아이콘에 CrossMouse가 남는지 함께 확인해 주세요.

## v0.3 — 창 닫아도 백그라운드 유지 + 필립스 입력 전환 안전 실험

**X 버튼은 이제 Mac/Windows 양쪽 모두 창만 숨깁니다.** Mac에서는 메뉴 막대의 `⇆ → CrossMouse 창 열기` 또는 Dock 아이콘으로 다시 열고, Windows에서는 작업 표시줄 알림 영역의 CrossMouse 아이콘을 더블 클릭해 다시 엽니다. 키보드와 마우스 공유는 계속 작동합니다. **프로그램을 완전히 종료하려면** 창의 `앱 종료` 버튼 또는 Mac 메뉴 막대/Windows 트레이의 `종료`를 사용하세요. 컴퓨터 부팅 시 자동 실행은 아직 지원하지 않습니다.

필립스 271E1D 계열은 DVI·HDMI와 DDC/CI 호환성을 공식 표기하지만, **DDC/CI 지원이 VCP 0x60 입력 전환 보장은 아닙니다.** Mac M5 Pro에 설치된 `m1ddc`(MIT, Apple silicon)에서 `PHL 271E1`을 인식했으나, 읽기 전용 `get input`은 `0`을 반환했습니다. 따라서 이 모델·어댑터로 **실제 영상 입력 명령이 작동하는지는 미확인**입니다.

안전하게 먼저 시험하는 방법:

1. Mac에 `m1ddc` 설치: `brew install m1ddc` (이미 설치했다면 생략).
2. 필립스 DVI로 Mac 듀얼 화면을 표시하고, Windows PC와 CrossMouse 수신기는 켜 둡니다.
3. **Mac CrossMouse 창은 삼성 스마트 모니터에 표시됩니다.** `HDMI 전환 시험`을 누르고, 안내에 동의합니다. 화면이 실제로 HDMI/Windows로 바뀌었을 때만 `전환됨`을 누릅니다.
4. 삼성 Mac 화면의 CrossMouse에서 `DVI 복귀 시험`을 누르고, 실제로 Mac 화면으로 복귀했을 때만 `전환됨`을 누릅니다. 실패한다면 필립스 물리 입력 버튼으로 DVI 복귀하세요.
5. **두 방향 모두 실제 성공을 확인했을 때만** `필립스 오른쪽 위 1.25초 머물면 Windows로 전환` 체크박스를 켤 수 있습니다.

자동 전환이 확인되면 평소에는 삼성·필립스를 Mac 듀얼 모니터로 사용하다가, **필립스 화면 오른쪽 위 가로 20px × 세로 120px 코너에 마우스를 1.25초 계속 두면** 작은 카운트다운 안내가 나오고 DDC HDMI 명령을 전송합니다. 그때만 Windows 모드로 전환해 커서를 넘깁니다. 코너에서 떨어지거나 Windows PC 연결이 없으면 카운트가 초기화되므로 **실수로 평범하게 오른쪽 끝을 지나는 것만으로는 전환되지 않습니다.** Windows 왼쪽 끝으로 돌아오면 DDC DVI 명령을 시도합니다.

**중요:** 모니터가 DDC 명령에 성공을 보고해도 실제로 화면을 바꾸지 않을 수 있으며, Mac 쪽 영상 연결이 비활성화되면 DVI 복귀 명령이 전달되지 않을 수도 있습니다. 성공한 테스트가 있어도 항상 필립스의 물리 입력 선택 버튼을 복구 수단으로 남겨두세요. 자동 전환은 기본 **꺼짐**이며 앱이 처음부터 모니터 입력을 임의로 변경하지 않습니다. 실패 시 자동 전환 설정은 꺼집니다. 기존 수동 Mac/Windows 모드도 계속 이용할 수 있습니다.

## v0.2.2 — Windows 커서 끊김 완화 (시험)

마우스 입력이 Wi-Fi/TCP에서 불규칙하게 도착하면 예전 수신기는 패킷마다 커서를 즉시 옮겨, 부드럽다가 갑자기 점프하는 현상이 생길 수 있었습니다. 새 **Windows GUI**에는 기본으로 켜지는 `부드러운 마우스 이동` 옵션이 있습니다.

- 수신한 이동 거리 전체를 보존하면서 Windows에서 약 **8ms 간격**으로 짧게 나눠 움직입니다. 클릭/휠/키보드 입력 시 남은 이동을 먼저 반영하며, Mac으로 돌아가거나 연결이 끊기면 남은 이동은 폐기합니다.
- Windows를 실제로 마우스로 조작하는 동안에만 고해상도 타이머를 요청하고, Mac으로 돌아가거나 연결을 종료하면 타이머 요청도 해제합니다.
- 화면에 **최근 2초 수신 횟수·25ms 초과 간격 횟수·최대 간격**을 표시합니다. 간격 수치는 대략적인 수신 패턴이며, 사용자가 잠깐 마우스를 멈춘 것도 간혹 포함될 수 있어서 네트워크 지연의 확정값은 아닙니다.
- 체감이 더 나쁘면 `부드러운 마우스 이동` 체크를 해제해서 기존 즉시 이동 방식과 비교할 수 있습니다. 선택은 현재 실행 중에만 유지됩니다.

**Windows GUI만 새 `CrossMouse-Windows-GUI` 아티팩트의 `CrossMouse.exe`로 교체하면 됩니다.** 기존 앱을 완전히 종료한 다음 새 EXE를 실행하세요. IP·페어링 키는 기존 설정을 그대로 사용하고, Mac 앱은 다시 빌드할 필요가 없습니다. 8ms는 입력을 처리하는 목표 간격이지 모니터 FPS나 네트워크 RTT를 보장하지 않습니다. 실제 Wi-Fi가 50~100ms씩 멈추는 경우 소프트웨어로 모든 끊김을 없앨 수는 없고 네트워크 상태도 살펴야 합니다.

## v0.2 — 실행/종료가 가능한 Mac·Windows 데스크톱 앱

기존 v0.1은 Windows에서 콘솔을 켜고, Mac에서는 메뉴 막대 토글을 이용해야 했습니다. **v0.2부터 두 운영체제 모두 창과 시작/중지/종료 제어 기능을 제공합니다.** 실행 파일은 GitHub **Actions**의 성공한 최신 빌드에서 다음 아티팩트를 받습니다.

| 플랫폼 | 다운로드할 아티팩트 | 실행 |
| --- | --- | --- |
| Mac | `CrossMouse-macOS` | `CrossMouseMac.app` (로컬 개발 빌드는 기존 `dist/CrossMouseMac.app`) |
| Windows 10/11 x64 | **`CrossMouse-Windows-GUI`** | `CrossMouse.exe` |

**Windows 기존 버전에서 업그레이드:** 실행 중인 검은 콘솔의 `CrossMouse.Windows.exe`를 `Ctrl+C`로 **먼저 종료**하세요. 그렇지 않으면 새 앱은 TCP 49431을 열 수 없어 '기존 수신기 종료' 오류를 표시합니다. 새 앱은 **기존 페어링 키 파일을 그대로 재사용**하며 IP·키를 다시 입력할 필요가 없습니다. Mac과 Windows GUI 모두 실행할 때는 명확한 상태창이 표시되고, X로 창을 닫거나 최소화해도 계속 실행됩니다. 완전히 종료할 때만 `앱 종료`를 누르세요.

**필립스를 Mac으로 다시 돌릴 때는 두 동작이 필요합니다.**

1. 필립스 모니터의 영상 입력을 DVI로 변경합니다.
2. **Mac CrossMouse 앱에서 'Mac 듀얼 모니터 (DVI)'**를 선택합니다. 그 순간 Windows로의 마우스 전달을 중지하고, 삼성 → 필립스를 평소의 Mac 확장 모니터처럼 쓸 수 있습니다.

Windows 화면으로 가려면 필립스 HDMI 입력으로 전환한 뒤 Mac 앱에서 **'Windows 사용 (HDMI)'**를 선택합니다. 앱에서 `연결 중지`를 누르면 페어링 통신을 끊고 모든 입력을 Mac으로 돌려주지만 **선택해 둔 Windows 모드는 유지**합니다. 다시 `연결 시작`을 누르면 모드를 재선택할 필요가 없습니다. 필립스를 DVI로 돌렸다면 앱의 **Mac 듀얼 모니터 (DVI)**로 직접 전환하세요. **DVI/HDMI 영상 입력 자체를 소프트웨어로 자동 변경하는 기능은 아직 없습니다.**

**재연결 수정(v0.2.1):** Windows 수신기를 교체·재실행한 뒤 Mac이 `Windows 연결 대기 중…`에 오래 머무는 문제를 줄이기 위해 TCP 연결 대기 상태와 인증 지연 시 새 연결로 자동 재시도하도록 했습니다. 약 7초 안에 인증이 완료되지 않으면 해당 시도를 끊고 2초 후 새 연결을 시도합니다. 먼저 Windows 앱에 `Mac 연결 대기 중` 또는 `연결됨`이 표시되는지 확인하세요. Windows에 `TCP 49431 사용 중`이 보이면 기존 검은 콘솔 수신기를 먼저 종료해야 합니다.

Windows 앱은 실행되지만 Mac에 계속 `연결 대기 중`이 보인다면 **Mac 앱에서 연결 중지 → 연결 시작**을 누르거나, Mac 터미널에서 `python3 scripts/diagnose-pairing.py`로 포트와 인증을 확인할 수 있습니다. 진단 스크립트는 Windows에 입력 이벤트를 보내지 않으며 페어링 키 값을 출력하지 않습니다. 진단 전에 Mac 앱 연결을 잠시 중지해 수신기를 비워두세요.

**마우스 이동의 반응성:** Mac은 TCP의 Nagle 지연을 끄고, 입력 이벤트를 약 **8ms 간격(최대 약 125Hz)**으로 묶어 전송합니다. Windows에서도 TCP 저지연 설정을 적용합니다. 이벤트 처리량이 높은 무선 마우스에서 패킷이 쌓이는 현상을 줄이기 위한 변경입니다. v0.2.2에서는 Windows의 수신 후 커서 움직임도 짧게 보간합니다. 화면 FPS나 네트워크 지연이 반드시 125fps/8ms가 된다는 뜻은 아닙니다. Wi-Fi 간섭·공유기 무선 구간(과거 왕복 지연이 크게 달랐던 기록)이나 Windows 디스플레이 설정도 실제 커서 부드러움에 영향을 줍니다. 연결이 더 느리면 같은 공유기의 유선 연결 또는 5/6GHz Wi-Fi 상태를 확인하세요.

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

앱이 **일반 창·Dock·메뉴 막대 ⇆**로 나타납니다. 첫 실행 시 macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용(Accessibility)** 및 **입력 모니터링(Input Monitoring)** 권한을 CrossMouse에 허용하고 앱을 완전히 종료했다가 다시 실행하세요. 권한이 없으면 입력 이벤트 탭이 생성되지 않아 마우스/키보드 공유가 동작하지 않을 수 있습니다. 창의 X는 창만 숨기며, **앱 종료**를 눌러야 공유도 종료됩니다.

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
| 창만 숨기기 | Mac/Windows의 **X 버튼** 또는 최소화 |
| 완전히 종료 | 각 컴퓨터에서 **앱 종료** 또는 메뉴 막대/트레이의 **종료** |
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

구현: Mac GUI/Dock/메뉴 막대의 Mac 듀얼/Windows 모드 선택 및 시작·중지·종료, Windows GUI/트레이의 시작·중지·종료, Samsung 화면의 오른쪽 경계 감지, Quartz 이벤트 전달·로컬 차단, Windows Win32 입력, 왼쪽 경계 복귀, 네트워크 재연결, 자동 키 해제, 256비트 페어링 키/HMAC/AES-GCM, 기본 키·버튼·스크롤 매핑, Mac 측 8ms 이동 이벤트 통합과 TCP 지연 해제, Windows GUI 측 선택 가능한 8ms 커서 보간 및 수신 간격 진단.

미구현/검증 필요: 필립스에서의 **실제 DDC 입력 명령 성공 여부**(시험 UI와 안전 핫코너 코드는 추가됨), 영상 입력 자동 감지, Mac 디스플레이 자동 비활성화, 클립보드, Mac 앱 내부에서 페어링 키 입력, 로그인 시 자동 시작, 다중 Windows 모니터, 정밀 트랙패드 스크롤, 키보드 레이아웃/한영 전환 호환성 완성, v0.3 실물 장치 장기 검증.

**개인 입력을 다루는 프로그램이므로 프로토타입을 외부에 공유하거나 자동 실행하도록 설정하기 전에 양쪽 실제 장치에서 권한/연결 끊김/키 stuck/복구를 검수해야 합니다.**
