# VadaWeb — Apple TV(tvOS) 실험용 브라우저

주소창 + 웹뷰만 있는 아주 단순한 tvOS 브라우저입니다.

## 핵심 원리 (왜 "실험용"인가)

tvOS SDK는 `WKWebView`를 `API_UNAVAILABLE(tvos)`로 막아두어 공식적으로는
웹뷰를 쓸 수 없습니다. 하지만 **WebKit 바이너리 자체에는 `WKWebView` 클래스가
그대로 들어 있습니다** (`_OBJC_CLASS_$_WKWebView` 심볼 확인됨).

그래서 이 앱은:

1. `dlopen("/System/Library/Frameworks/WebKit.framework/WebKit")` 로 WebKit을
   런타임에 강제 로드해 클래스를 등록시키고,
2. `NSClassFromString("WKWebView")` 로 클래스를 얻은 뒤,
3. Objective-C 런타임으로 인스턴스를 만들고 `loadRequest:` / `reload` 셀렉터를
   호출해 페이지를 띄웁니다.

컴파일 타임에 `WKWebView` 타입을 직접 참조하지 않으므로 tvOS에서도 빌드됩니다.

> ⚠️ **App Store 배포 불가**: 비공개/차단된 API를 사용하므로 심사를 통과할 수
> 없습니다. 본인 기기에 직접 설치(사이드로드)하는 개인 용도 전용입니다.

## 구성

- `VadaWeb/VadaWebApp.swift` — 앱 진입점
- `VadaWeb/ContentView.swift` — 주소 입력 UI + 이동/새로고침 버튼
- `VadaWeb/WebViewContainer.swift` — 런타임 WKWebView 래퍼 (핵심)
- `VadaWeb/Info.plist` — ATS(`NSAllowsArbitraryLoads`)로 http 사이트도 허용

## 빌드 / 실행

### 시뮬레이터
Xcode에서 `VadaWeb.xcodeproj`를 열고 Apple TV 시뮬레이터를 선택해 Run.
(검증 완료: tvOS 26.4 시뮬레이터에서 apple.com 정상 렌더링 확인)

### 실제 Apple TV에 사이드로드
1. Xcode > 타깃 `VadaWeb` > **Signing & Capabilities** 에서 본인 Team 선택
   (무료 Apple ID도 가능하지만 7일마다 재설치 필요).
2. Apple TV를 같은 네트워크에 두고 Xcode > Window > Devices and Simulators
   에서 페어링.
3. 실행 대상으로 Apple TV를 선택하고 Run.

## 기능

- 기본 페이지: **www.naver.com**
- 주소 입력 → 이동, 새로고침
- 뒤로 / 앞으로 (히스토리가 없으면 자동으로 비활성화 — `canGoBack`/`canGoForward`
  를 주기적으로 폴링)
- **상시 커서**: 별도 모드 전환 없이, 웹 영역에서 리모컨 터치패드로 커서를
  움직이고 클릭한다. 커서를 화면 위/아래 끝으로 가져가면 자동 스크롤.
- **입력칸 타이핑 + 모바일 입력**: 커서로 web input(아이디·비밀번호 등)을
  클릭하면, JS로 편집 가능 여부/타입을 판별해 네이티브 텍스트 입력 화면을 띄운다.
  - tvOS 네이티브 텍스트 필드라서, 같은 iCloud 계정의 **iPhone이 가까이 있으면
    알림에서 바로 타이핑**할 수 있다(Continuity 키보드). → ID/PW를 폰으로 입력.
  - 비밀번호는 `SecureField`라 TV 화면에는 ●●● 로만 보여 옆사람이 못 본다.
  - 입력값은 JS로 해당 input 에 주입(React 등도 인식하도록 native setter + input
    이벤트 디스패치).
- **로그인 세션 유지**: WKWebView 기본 영속 쿠키 저장소(`WKWebsiteDataStore.default()`)
  를 사용하므로 한 번 로그인하면 앱을 다시 켜도 세션이 남는다(모든 탭이 공유).
- **탭**: 탭마다 독립된 WKWebView 를 유지(스크롤/히스토리 보존). `＋`로 새 탭,
  `✕`로 닫기, 탭 칩을 선택해 전환.
- **즐겨찾기**: `☆`로 현재 페이지 저장(`★`는 이미 저장됨), `즐겨찾기` 패널에서
  열기/삭제. `UserDefaults`에 영속화.
- **전체화면**: 툴바/탭바를 숨기고 웹뷰만 표시. Menu 버튼으로 복귀.

## 리모컨 조작 (실기기) — 화면 전체를 덮는 단일 커서

커서가 **상단 UI(툴바·탭)와 웹 영역 전체**를 자유롭게 다닌다. 클릭하면 커서 위치의
대상(툴바 버튼·탭·탭 닫기·웹 요소·입력칸)이 선택된다.

| 입력 | 동작 |
|------|------|
| **터치패드 스와이프** | 커서 이동(가속: 천천히=정밀, 빠르게=원거리) |
| **방향키 클릭(상하좌우)** | 커서를 그 방향으로 미세 이동(16pt) |
| **가볍게 터치(탭)** | 커서 위치 클릭 (딸깍 누르지 않아도 됨) |
| **선택(가운데 클릭)** | 커서 위치 클릭 — 클릭 시 커서 펄스 애니메이션 |
| **터치패드 회전(바깥 링을 문지름)** | 페이지 스크롤 (커서 이동으로는 스크롤되지 않음) |
| **Menu(Back)** | 입력창/즐겨찾기 닫기 → 전체화면 종료 → **브라우저 뒤로가기** (히스토리 없으면 앱 종료) |

영상 전체화면:
- 영상의 전체화면 버튼은 **영상만** 네이티브 전체화면으로 띄운다(`webkitEnterFullscreen`).
  앱 전체화면(크롬 숨김)과는 별개. tvOS엔 Element Fullscreen API 가 없어 폴리필로 처리.
- 후킹/폴리필을 **모든 프레임(iframe 포함)**에 주입하고, 커서 클릭이 **같은 출처
  iframe 내부까지 침투**하도록 해서 iframe 플레이어의 전체화면 버튼도 동작한다.
  (단, 교차 출처 iframe(예: 유튜브 임베드) 내부는 접근 불가 — WKWebView 제약.)

동작 원리:
- 화면 전체를 덮는 **단일 입력 오버레이(`InputOverlayView`)**가 유일한 포커스
  대상이라, 스와이프가 다른 곳으로 포커스를 옮기는 문제가 없다.
- 커서 클릭 시 위치를 히트테스트: 상단 UI 프레임(SwiftUI `.global`)에 들어오면 그
  버튼 동작, 웹 영역이면 그 지점을 JS 로 클릭(뷰포트 비율로 좌표 환산).
- 커서를 웹 영역 위/아래 끝으로 가져가도 자동 스크롤된다(회전 스크롤의 대체 수단).
- `target="_blank"`/`window.open()` 은 후킹해 **새 탭**으로 연다.
- tvOS WKWebView 엔 Element Fullscreen API 가 없어, 사이트의 전체화면 버튼은
  **폴리필**로 가로채 앱 전체화면(크롬 숨김)으로 전환하고, `<video>` 는
  `webkitEnterFullscreen` 도 시도한다.

> - **시뮬레이터는 리모컨 터치패드 입력을 흉내 낼 수 없어** 실제 커서/클릭/회전은
>   기기에서 확인·튜닝해야 한다. (좌표 정렬·히트테스트 프레임·JS 클릭/새탭/폴리필·
>   페이지 로딩은 시뮬레이터로 검증됨.)
> - 영상 내 전체화면은 user-activation 제약으로 네이티브 비디오 전체화면이 막힐 수
>   있어, 최소한 앱 전체화면으로 전환된다.

## 앱 아이콘

"Vada Web" 텍스트와 네트워크망 그래픽이 오른쪽에서 겹치는 디자인입니다.
`Assets.xcassets/App Icon & Top Shelf Image.brandassets/` 에 tvOS 브랜드 에셋
(홈 아이콘 2레이어 패럴랙스 + App Store 아이콘 + 탑셸프 배너)으로 포함되어 있습니다.

아이콘을 다시 만들고 싶으면:

```bash
cd tools && python3 build_assets.py   # Pillow 필요
```

`tools/gen_icon.py` 에서 색상·노드 배치·문구를 조정할 수 있습니다.

## 알려진 한계

- **Siri Remote 조작**: tvOS의 WKWebView는 리모컨 네비게이션을 위해 설계된 게
  아니라서, 페이지 내 스크롤/링크 클릭이 매끄럽지 않을 수 있습니다.
- OS 업데이트로 WebKit 내부 구조가 바뀌면 런타임 트릭이 깨질 수 있습니다.
