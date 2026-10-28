# SODA DAILY 인계 노트 (2026-10-28)

회사 맥에서 Claude Code를 이 폴더에서 열고 "HANDOFF.md 읽고 이어서 하자"라고 하면 됩니다.

## 현재 상태
- macOS 메뉴바 앱 + 항상 위 플로팅 패널 (SwiftUI, 단일 파일 `SODADaily/SODADailyApp.swift`)
- Xcode 없이 `./build.sh`로 빌드 → `~/Applications/SODADaily.app` 설치 (swiftc + ad-hoc 서명)
- 집 맥에서 빌드·실행 확인 완료: 컴파일 오류 없음, 패널이 화면 우상단에 표시됨(355×364)

## 이미 고친 것
1. 설정 창이 다른 앱 뒤에 열리던 문제 → `OpenSettingsButton`(앱 활성화 후 `openSettings()`)
2. 패널 크기 460 고정 → 카드 내용 크기(`fittingSize`)에 맞추고 우상단 정렬

## 아직 확인 못 한 것 / 다음 할 일
- [ ] TMAP appKey 입력 후 실제 경로 조회 동작 확인 (SK open API 자동차 경로)
- [ ] 집/회사 위도·경도 입력 (설정에서)
- [ ] 캘린더 권한 허용 후 Google 일정(맥 인터넷 계정 동기화) 표시 확인
- [ ] 알림 권한·정체 알림·일정 10분 전 알림 확인
- [ ] 메뉴바 아이콘/라벨 표시 모양 육안 확인 (집 맥에서는 화면 캡처 권한이 없어 못 봄)
- [ ] 로그인 시 자동 실행(SMAppService) 동작 확인

## 회사 맥에서 시작
```bash
cd SODADaily && ./build.sh && open ~/Applications/SODADaily.app
```
- 필요: macOS 14+, Xcode Command Line Tools (`xcode-select --install`)
- API 키는 Keychain에, 좌표/옵션은 UserDefaults에 저장되므로 **회사 맥에서 다시 입력**해야 합니다.
- ad-hoc 서명이라 재빌드 시 Keychain 접근 허용을 다시 물을 수 있습니다.
