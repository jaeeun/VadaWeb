# VadaWeb — Apple TV(tvOS) 브라우저

주소창 + 웹뷰 + 탭/즐겨찾기/전체화면을 갖춘, 리모컨으로 조작하는 단순한 tvOS 브라우저입니다.

## 핵심 원리

tvOS SDK는 `WKWebView`를 `API_UNAVAILABLE(tvos)`로 막아두어 공식적으로는
웹뷰를 쓸 수 없습니다. 하지만 **WebKit 바이너리 자체에는 `WKWebView` 클래스가
그대로 들어 있습니다** (`_OBJC_CLASS_$_WKWebView` 심볼 확인됨).

그래서 이 앱은:

1. `dlopen("/System/Library/Frameworks/WebKit.framework/WebKit")` 로 WebKit을
   런타임에 강제 로드해 클래스를 등록시키고 (`WebKitLoader`),
2. `NSClassFromString("WKWebView")` 로 클래스를 얻은 뒤,
3. Objective-C 런타임으로 인스턴스를 만들고 `loadRequest:` / `reload` /
   `evaluateJavaScript:completionHandler:` 등의 셀렉터를 `perform` 으로 호출해
   페이지를 띄우고 제어합니다.

컴파일 타임에 `WKWebView` 타입을 직접 참조하지 않으므로 tvOS에서도 빌드됩니다.

> ⚠️ **App Store 배포 불가**: 비공개/차단된 API를 사용하므로 심사를 통과할 수
> 없습니다. 본인 기기에 직접 설치(사이드로드)하는 개인 용도 전용입니다.

## 구성

- `VadaWeb/VadaWebApp.swift` — 앱 진입점 (`WindowGroup` → `ContentView`)
- `VadaWeb/ContentView.swift` — SwiftUI UI 계층
  - `ChromeBar` / `ChromeChip` — 상단 툴바·탭 줄 (포커스를 받지 않는 시각 요소,
    `.global` 프레임을 보고해 커서 히트테스트에 쓰임)
  - `TextEntryOverlay` / `AddressEntryOverlay` / `BookmarksPanel` — 모달
- `VadaWeb/WebViewContainer.swift` — 핵심 로직
  - `WebKitLoader` — WebKit 런타임 로드
  - `WebContainerView` — 런타임 `WKWebView` 래퍼 (JS 주입/클릭/스크롤)
  - `WebTab` / `BrowserModel` — 탭·브라우저 상태
  - `RemoteInput` — `GameController` microGamepad 입력 해석
  - `InputOverlayView` — 화면 전체를 덮는 단일 커서 + 입력 오버레이
- `VadaWeb/Info.plist` — ATS(`NSAllowsArbitraryLoads`)로 http 사이트도 허용
- `tools/` — 앱 아이콘/탑셸프 에셋 생성 스크립트 (Pillow)

## 빌드 / 실행

### 시뮬레이터
Xcode에서 `VadaWeb.xcodeproj`를 열고 Apple TV 시뮬레이터를 선택해 Run.
(검증 완료: tvOS 26.4 시뮬레이터에서 페이지 렌더링 확인)

> 시뮬레이터는 리모컨 터치패드 입력을 흉내 낼 수 없어, **실제 커서 이동/클릭/
> 스크롤은 기기에서만** 확인·튜닝할 수 있습니다. 페이지 로딩·UI 자체는
> 시뮬레이터로 검증됩니다.

### 실제 Apple TV에 사이드로드
1. Xcode > 타깃 `VadaWeb` > **Signing & Capabilities** 에서 본인 Team 선택
   (무료 Apple ID도 가능하지만 7일마다 재설치 필요).
2. Apple TV를 같은 네트워크에 두고 Xcode > Window > Devices and Simulators
   에서 페어링.
3. 실행 대상으로 Apple TV를 선택하고 Run.

## 기능

- **기본 페이지**: `https://www.naver.com` (새 탭도 동일).
- **주소 이동 / 새로고침 / 뒤로 / 앞으로**: `WKWebView` 셀렉터 직접 호출.
  뒤로·앞으로 가능 여부(`canGoBack` / `canGoForward`)와 제목·URL 은 0.4초마다
  폴링해 UI 에 반영.
- **상시 커서**: 모드 전환 없이, 화면 전체(상단 UI + 웹 영역)를 단일 커서로
  돌아다니며 클릭한다.
- **입력칸 타이핑 + 모바일 입력**: 커서로 web input/textarea/contentEditable 을
  클릭하면, JS 로 편집 가능 여부·타입을 판별해 네이티브 텍스트 입력 화면을 띄운다.
  - tvOS 네이티브 텍스트 필드라서, 같은 iCloud 계정의 **iPhone이 가까이 있으면
    알림에서 바로 타이핑**할 수 있다(Continuity 키보드). → ID/PW를 폰으로 입력.
  - 비밀번호 타입은 `SecureField`라 TV 화면에는 ●●● 로만 보인다.
  - 입력값은 JS 로 해당 input 에 주입한다(React 등도 인식하도록 native value
    setter + `input`/`change`/`keydown`/`keyup` 이벤트 디스패치).
- **로그인 세션 유지**: 기본(영속) 데이터 저장소를 쓰는 `WKWebView` 라, 한 번
  로그인하면 앱을 다시 켜도 세션이 남고 모든 탭이 쿠키를 공유한다.
- **탭**: 탭마다 독립된 `WKWebView` 를 유지(스크롤/히스토리 보존). `＋`로 새 탭,
  탭 옆 `✕`로 닫기, 탭 칩을 클릭해 전환. 마지막 탭을 닫으면 홈으로 새 탭이 열린다.
- **즐겨찾기**: `☆`로 현재 페이지 저장(이미 저장됐으면 `★`), `즐겨찾기` 패널에서
  열기/삭제. `UserDefaults`(`VadaWeb.bookmarks`)에 영속화.
- **전체화면**: 툴바/탭바를 숨기고 웹뷰만 표시. 좌상단 `✕ 전체화면 종료` 또는
  Menu 버튼으로 복귀.
- **유휴 자동 숨김**: 5초간 입력이 없으면 커서와 전체화면 종료 버튼이 사라지고,
  다시 움직이면 나타난다.

## 리모컨 조작 (실기기) — 화면 전체를 덮는 단일 커서

커서가 **상단 UI(툴바·탭)와 웹 영역 전체**를 자유롭게 다닌다. 클릭하면 커서 위치의
대상(툴바 버튼·탭·탭 닫기·웹 요소·입력칸)이 선택된다. 입력은 `GameController`
microGamepad 콜백으로 처리하므로 **포커스와 무관하게** 항상 동작한다.

| 입력 | 동작 |
|------|------|
| **터치패드 가운데 문지름** | 커서 이동 (가속: 천천히=정밀, 빠르게=원거리) |
| **터치패드 가장자리(바깥 링)를 위아래로 문지름** | 페이지 세로 스크롤 |
| **가운데를 짧게 톡(탭)** | 커서 위치 클릭 (딸깍 누르지 않아도 됨) |
| **선택(가운데 물리 클릭)** | 커서 위치 클릭 — 클릭 시 커서 펄스 애니메이션 |
| **방향키(상하좌우)** | 커서를 그 방향으로 16pt 미세 이동, 길게 누르면 가속 연속 이동 |
| **Menu(뒤로 `<`)** | 모달 닫기 → 전체화면 해제 → **브라우저 뒤로가기** 순. 더 갈 곳이 없으면 무시(앱은 종료되지 않음 — 종료는 리모컨의 TV/홈 버튼) |

영상 전체화면:
- 영상 표면이나 사이트의 전체화면 버튼을 클릭하면 **영상만** 네이티브
  전체화면으로 띄운다(`webkitEnterFullscreen`). 앱 전체화면(크롬 숨김)과는 별개.
- tvOS WKWebView 엔 Element Fullscreen API 가 없어, `requestFullscreen` /
  `webkitRequestFullscreen` 을 **폴리필**로 가로챈다. 비디오가 있으면 네이티브
  비디오 전체화면, 없으면 앱 전체화면으로 분기한다.
- 폴리필/후킹을 **모든 프레임(iframe 포함)**에 document-start 로 주입하고, 커서
  클릭이 **같은 출처 iframe 내부까지 침투**(최대 4단계)하도록 해서 iframe 플레이어의
  전체화면 버튼도 동작한다. (단, 교차 출처 iframe(예: 유튜브 임베드) 내부는
  접근 불가 — WKWebView 제약.)

동작 원리:
- 화면 전체를 덮는 **단일 입력 오버레이(`InputOverlayView`)**가 유일한 포커스
  대상이라, 문지름이 다른 곳으로 포커스를 옮기는 문제가 없다. 포커스를 잃으면
  워치독 타이머가 0.6초 안에 되찾아 커서 제어를 보장한다(모달/영상 전체화면 제외).
- 커서 클릭 시 위치를 히트테스트: 상단 UI 프레임(`.global`)에 들어오면 그 버튼
  동작, 웹 영역이면 그 지점을 뷰포트 비율 좌표로 환산해 JS 로 합성 클릭한다.
- `target="_blank"` / `window.open()` 은 후킹해 **새 탭**으로 연다.
- 입력 튐 방지: 손 뗌 직전의 마지막 델타를 버리고(한 프레임 지연), 짧은 탭과
  드래그를 슬롭으로 구분한다.

> - **시뮬레이터는 리모컨 터치패드를 흉내 낼 수 없어** 커서/클릭/스크롤/새탭/폴리필은
>   기기에서 확인·튜닝해야 한다.
> - 영상 내 전체화면은 user-activation 제약으로 네이티브 비디오 전체화면이 막힐 수
>   있어, 그럴 땐 앱 전체화면으로 전환된다.

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

- **비공개 API 의존**: OS 업데이트로 WebKit 내부 구조나 셀렉터/KVC 키가 바뀌면
  런타임 트릭이 깨질 수 있습니다.
- **교차 출처 iframe**: 보안 정책상 내부 클릭·전체화면 제어가 불가합니다.
- **시뮬레이터 제약**: 리모컨 터치패드 입력을 재현할 수 없습니다.
- **App Store 배포 불가**: 개인 사이드로드 전용입니다.
