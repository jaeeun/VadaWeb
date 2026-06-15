import SwiftUI

struct ContentView: View {
    @StateObject private var model = BrowserModel()

    var body: some View {
        // '<'(Menu) 는 항상 앱 내 뒤로가기로 소비한다 → 히스토리가 있으면 뒤로,
        // 모달/전체화면이면 닫기, 더 갈 곳이 없으면 무시(앱이 멋대로 종료되지 않음).
        content.onExitCommand { model.handleBackCommand() }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let tab = model.activeTab {
                VStack(spacing: 0) {
                    if !model.isFullscreen {
                        ChromeBar(model: model)
                    }
                    WebHost(tab: tab)
                        .id(tab.id)
                        .ignoresSafeArea(edges: model.isFullscreen ? .all : .bottom)
                }
            }

            // 전체화면일 때 복귀 버튼 (커서로 클릭) — 유휴 시 커서와 함께 숨김
            if model.isFullscreen && !model.controlsHidden {
                VStack {
                    HStack {
                        ChromeChip(model: model, key: .exitFullscreen, label: "✕ 전체화면 종료", isTab: false, active: false)
                            .padding(24)
                        Spacer()
                    }
                    Spacer()
                }
                .ignoresSafeArea()
            }

            // 커서 + 입력 (크롬/웹 위, 모달 아래)
            InputOverlay(model: model)
                .ignoresSafeArea()
                .allowsHitTesting(!model.modalActive)

            // 모달
            if let tab = model.activeTab, let req = tab.editRequest {
                TextEntryOverlay(tab: tab, request: req)
            }
            if model.addressEditing {
                AddressEntryOverlay(model: model)
            }
            if model.showBookmarks {
                BookmarksPanel(model: model)
            }
        }
        .onPreferenceChange(ChromeFramesKey.self) { model.chromeFrames = $0 }
    }
}

// MARK: - 상단 UI (커서로 클릭; 포커스 받지 않는 시각 요소)
struct ChromeBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(model.toolbarItems) { item in
                    ChromeChip(model: model, key: item.key, label: item.label, isTab: item.isTab, active: item.active)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.tabRowItems) { item in
                        ChromeChip(model: model, key: item.key, label: item.label, isTab: item.isTab, active: item.active)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

// 시각 요소 + .global 프레임 보고 (커서 히트테스트용)
struct ChromeChip: View {
    @ObservedObject var model: BrowserModel
    let key: ChromeKey
    let label: String
    let isTab: Bool
    let active: Bool

    var body: some View {
        let hovered = (model.hoveredKey == key)
        Text(label)
            .lineLimit(1)
            .frame(maxWidth: isTab ? 280 : nil)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(hovered ? Color.white.opacity(0.9)
                          : (active ? Color.white.opacity(0.22) : Color.white.opacity(0.07)))
            )
            .foregroundStyle(hovered ? Color.black : Color.white)
            .background(GeometryReader { g in
                Color.clear.preference(key: ChromeFramesKey.self, value: [key: g.frame(in: .global)])
            })
    }
}

// MARK: - 텍스트 입력 오버레이
struct TextEntryOverlay: View {
    @ObservedObject var tab: WebTab
    let request: EditRequest
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(request.isSecure ? "비밀번호 입력" : "텍스트 입력").font(.title2).bold()
                Text("iPhone이 가까이 있으면 알림에서 입력할 수 있습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                Group {
                    if request.isSecure { SecureField("비밀번호", text: $text) }
                    else { TextField("입력", text: $text) }
                }
                .textContentType(request.isSecure ? .password : .none)
                .autocorrectionDisabled(true)
                .focused($focused)
                HStack(spacing: 20) {
                    Button("입력") { tab.submitText(text) }
                    Button("취소") { tab.cancelEdit() }
                }
            }
            .padding(48).frame(width: 1000)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.12)))
        }
        .onAppear { text = request.initialText; focused = true }
        .onSubmit { tab.submitText(text) }
    }
}

// MARK: - 주소 입력 오버레이
struct AddressEntryOverlay: View {
    @ObservedObject var model: BrowserModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("주소 입력").font(.title2).bold()
                TextField("예: naver.com", text: $text)
                    .autocorrectionDisabled(true)
                    .focused($focused)
                HStack(spacing: 20) {
                    Button("이동") { model.loadAddress(text) }
                    Button("취소") { model.endAddressEdit() }
                }
            }
            .padding(48).frame(width: 1000)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.12)))
        }
        .onAppear { text = model.activeTab?.displayURL ?? ""; focused = true }
        .onSubmit { model.loadAddress(text) }
    }
}

// MARK: - 즐겨찾기 패널
struct BookmarksPanel: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("즐겨찾기").font(.title2).bold()
                    Spacer()
                    Button("닫기") { model.closeBookmarksPanel() }
                }
                if model.bookmarks.isEmpty {
                    Text("저장된 즐겨찾기가 없습니다.\n상단의 ☆ 로 현재 페이지를 추가하세요.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(model.bookmarks) { b in
                                HStack {
                                    Button(action: { model.openBookmark(b) }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(b.title).lineLimit(1)
                                            Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Button("삭제") { model.removeBookmark(b) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(40).frame(width: 1100, height: 720)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(white: 0.12)))
        }
    }
}

#Preview {
    ContentView()
}
