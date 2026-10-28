# SODA DAILY for macOS

macOS 14+, Xcode 16+ 권장. 메뉴바 앱 + 항상 위에 떠 있는 드래그 가능한 패널.

## 빌드 (Xcode 없이)
`./build.sh` 실행 → Command Line Tools의 swiftc로 컴파일, ad-hoc 서명 후 `~/Applications/SODADaily.app`에 설치합니다.
`open ~/Applications/SODADaily.app`으로 실행하세요.

## 실행
1. (Xcode가 있다면) `SODADaily.xcodeproj`를 Xcode로 엽니다.
2. Target > Signing & Capabilities에서 개인 Team을 선택합니다(필요한 경우).
3. Scheme `SODADaily` / My Mac을 선택하고 `Cmd+R`.
4. 메뉴바의 차량 아이콘에서 `설정...`을 엽니다.
5. [TMAP Open API](https://tmap-skopenapi.readme.io/reference/자동차-경로안내) 자동차 경로 API 사용 가능한 appKey 발급 후 입력·저장.
6. 집/회사 위도·경도 WGS84 입력. 좌표는 위도(lat) 37.xxx, 경도(lon) 126.xxx 순서입니다.
7. 날씨 위도/경도 변경(기본 서울 중심 예시).
8. 시스템 설정 > 인터넷 계정 > Google > 캘린더 활성화 후 macOS 캘린더 앱에서 일정 동기화 확인.
9. 최초 권한 요청에서 캘린더/알림 허용. 앱 설정에서 로그인 시 자동 실행 설정.

## 중요한 제한
- 실시간 TMAP 경로는 appKey와 유효한 위도/경도가 반드시 필요합니다. TMAP 내비와 경로 옵션이 달라 시간이 차이 날 수 있습니다.
- macOS EventKit을 통해 *맥에 동기화된* Google 일정을 읽습니다. Google Calendar 웹 API 직접 연결은 하지 않습니다.
- 앱이 실행되고 맥이 깨어 있을 때 5분 간격으로 조회하며, 절전 중에는 갱신되지 않습니다.
- 패널은 `NSPanel.level = .floating`으로 다른 창 위에도 뜹니다. 바탕화면에만 붙는 진정한 데스크톱 레벨 위젯이 아니라 화면 고정형 플로팅 패널입니다.
- 알림은 정체 기준시간 이상이거나 예정 일정 시작 전 10분 이내에 조회된 경우에 표시됩니다. 앱을 종료하면 알림 생성도 멈춥니다.
- 경로 API 과금/할당량은 현재 가입한 상품 조건에 따릅니다. 키 발급 페이지에서 확인하세요.
- Swift 코드 정적 검토 기반으로 구성했습니다. 이 작업 환경에 Xcode/macOS SDK가 없어 실제 macOS 빌드 검증은 수행하지 못했습니다.
- 개발 편의를 위해 앱 샌드박스가 해제되어 있습니다. 외부 배포 시 샌드박스/권한/코드서명을 다시 검토하세요.

## 파일
- `SODADaily/SODADailyApp.swift`: 화면, 상태, API, EventKit, 알림, Keychain, 시작 항목
- `SODADaily.xcodeproj`: Xcode 프로젝트
