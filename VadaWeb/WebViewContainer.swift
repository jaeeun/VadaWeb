import SwiftUI
import UIKit
import GameController
import QuartzCore
import ObjectiveC

// MARK: - WebKit 런타임 로더
enum WebKitLoader {
    private static var handle: UnsafeMutableRawPointer?
    private static var didLoad = false
    static func load() {
        guard !didLoad else { return }
        didLoad = true
        handle = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
    }
}

@objc private protocol JSEvaluator {
    func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)?)
}

extension Notification.Name {
    static let vadaReassertFocus = Notification.Name("VadaReassertFocus")
}

// MARK: - 편집/클릭 결과
struct EditRequest: Identifiable {
    let id = UUID()
    let isSecure: Bool
    let initialText: String
}

private struct ClickResult: Codable {
    var editable: Bool
    var secure: Bool
    var value: String
    var newTab: String?
    var fs: Int?
}

private struct PumpResult: Codable {
    var newTab: String?
    var fs: Int?
    var vfs: Bool?
}

// MARK: - 상단 UI 식별 키 (커서 히트테스트용, 안정적이어야 함)
enum ChromeKey: Hashable {
    case back, forward, address, reload, bookmarkToggle, bookmarks, fullscreen, newTab, exitFullscreen
    case tab(UUID)
    case closeTab(UUID)
}

struct ChromeItem: Identifiable {
    let key: ChromeKey
    let label: String
    let isTab: Bool
    let active: Bool
    let action: () -> Void
    var id: ChromeKey { key }
    init(_ key: ChromeKey, _ label: String, isTab: Bool = false, active: Bool = false, action: @escaping () -> Void) {
        self.key = key; self.label = label; self.isTab = isTab; self.active = active; self.action = action
    }
}

// MARK: - 리모컨 입력 (GameController microGamepad)
//
// 입력 철학(마우스처럼):
//  - 터치 표면 가운데를 문지르면 → 커서 이동(포커스와 100% 무관, GameController 콜백).
//  - 가운데를 짧게 톡 치면 → 그 자리에서 클릭(탭=클릭, 역시 포커스 무관).
//  - 바깥 링(상하)을 문지르면 → 페이지 세로 스크롤.
//  - 물리 클릭(상하좌우 버튼/가운데)·뒤로(<)는 UIPress 로 처리(InputOverlayView).
//    → buttonA 좌표 분류는 손 뗌 시 좌표가 0 으로 리셋되어 오클릭을 유발하므로 사용하지 않는다.
final class RemoteInput {
    static let shared = RemoteInput()
    var onScroll: ((CGFloat) -> Void)?                   // 세로 스크롤 델타(+면 콘텐츠 아래로)
    var onActive: (() -> Void)?
    var onCenterClick: (() -> Void)?                     // 가운데 탭 = 클릭
    var onCursorDelta: ((CGFloat, CGFloat) -> Void)?     // 정규화 델타(포커스 무관 커서 이동)
    var onBack: (() -> Void)?                            // 리모컨 '<' (Menu) → 앱 내 뒤로가기

    private var gcCursor: CGPoint?
    private var scrollAnchor: CGPoint?
    private var touching = false
    private var dragging = false                         // 슬롭을 넘겨 '확실한 드래그'가 됐는지
    private var touchedRing = false                      // 이번 터치가 바깥(스크롤) 영역을 거쳤는지
    private var touchStart: CFTimeInterval = 0
    private var touchPath: CGFloat = 0                   // 터치 누적 이동량(탭/문지름 구분)
    // 한 프레임 지연 적용: 직전 델타를 보관했다가 다음 프레임에 적용.
    // 손 뗌 순간엔 아직 적용 안 한 마지막 델타(=튀는 프레임)를 그냥 버린다.
    private var pendingDX: CGFloat = 0
    private var pendingDY: CGFloat = 0
    private var hasPending = false
    private(set) var lastDpadTime: CFTimeInterval = 0     // UIKit 팬 폴백 억제용
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(connected(_:)),
                                               name: .GCControllerDidConnect, object: nil)
        GCController.controllers().forEach(attach)
    }

    @objc private func connected(_ note: Notification) {
        if let c = note.object as? GCController { attach(c) }
    }

    private func attach(_ controller: GCController) {
        guard let mg = controller.microGamepad else { return }
        mg.reportsAbsoluteDpadValues = true
        mg.dpad.valueChangedHandler = { [weak self] _, x, y in
            self?.handle(x: CGFloat(x), y: CGFloat(y))
        }
        // 리모컨 '<'(뒤로) 버튼 — GameController 가 활성일 때 UIPress 가 안 올 수 있어 직접 캡처.
        mg.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onBack?() }
        }
        // buttonA(물리 클릭)는 의도적으로 사용하지 않는다(오클릭 방지). 클릭은 탭/UIPress 가 담당.
    }

    private func handle(x: CGFloat, y: CGFloat) {
        let now = CACurrentMediaTime()
        lastDpadTime = now
        let r = (x * x + y * y).squareRoot()

        // 손 뗌(중앙 데드존) → 가운데에서 드래그 없이 짧게 친 터치만 탭=클릭(커서는 그대로, 튀지 않음).
        // 가장자리(상하좌우)를 친 터치는 클릭이 아니다 — 그 영역은 스크롤 전용.
        if r < 0.06 {
            if touching {
                touching = false
                if !dragging, !touchedRing, now - touchStart < 0.30 { onCenterClick?() }
            }
            // 아직 적용 안 한 마지막 델타(손 뗌 직전의 튀는 프레임)는 버린다 → 손 뗄 때 안 튐.
            hasPending = false
            gcCursor = nil; scrollAnchor = nil
            return
        }

        if !touching { touching = true; dragging = false; touchedRing = false; touchStart = now; touchPath = 0; gcCursor = nil; scrollAnchor = nil; hasPending = false }

        if r >= 0.5 {
            // 바깥 링: 세로로 문지르면 스크롤(콘텐츠를 손가락 따라 끌기 = iOS 방식)
            onActive?()
            touchedRing = true
            hasPending = false
            if let a = scrollAnchor {
                let dy = y - a.y
                touchPath += abs(dy) + abs(x - a.x)
                if abs(dy) > 0.0005 { onScroll?(dy * 1600) }   // 손가락 위로 → 콘텐츠 위로(아래쪽 표시)
            }
            scrollAnchor = CGPoint(x: x, y: y)
            gcCursor = nil
        } else {
            // 가운데: 커서 이동(절대 좌표의 델타) — 포커스와 무관하게 항상 동작
            if let last = gcCursor {
                let ddx = x - last.x, ddy = y - last.y
                let step = (ddx * ddx + ddy * ddy).squareRoot()
                touchPath += step
                // 슬롭을 넘기 전(=탭 가능성)에는 커서를 움직이지 않는다 → 탭으로 클릭할 때 안 튐.
                // 누르는 순간 손가락이 약간 밀리는 양까지 흡수하도록 넉넉히 잡는다.
                if !dragging, touchPath > 0.10 { dragging = true }
                if dragging {
                    // 직전 프레임 델타를 지금 적용(한 프레임 지연). 손 뗌 직전 마지막 델타는
                    // 위 데드존 분기에서 버려지므로, 손 뗄 때 생기는 점프가 화면에 반영되지 않는다.
                    let pStep = (pendingDX * pendingDX + pendingDY * pendingDY).squareRoot()
                    if hasPending, pStep < 0.14 { onCursorDelta?(pendingDX, pendingDY) }
                    pendingDX = ddx; pendingDY = ddy; hasPending = true
                }
            }
            gcCursor = CGPoint(x: x, y: y)   // 점프를 버려도 기준점은 갱신(누적 점프 방지)
            scrollAnchor = nil
        }
    }
}

// MARK: - 커서
final class CursorView: UIView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        isUserInteractionEnabled = false
        backgroundColor = UIColor.white.withAlphaComponent(0.92)
        layer.cornerRadius = 17
        layer.borderWidth = 2
        layer.borderColor = UIColor(red: 0.31, green: 0.82, blue: 0.92, alpha: 1).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        let dot = CALayer()
        dot.frame = CGRect(x: 12, y: 12, width: 10, height: 10)
        dot.cornerRadius = 5
        dot.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 0.74, alpha: 1).cgColor
        layer.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - WKWebView 호스트 (커서/입력 없음 — 입력은 InputOverlay 가 담당)
final class WebContainerView: UIView {
    let webView: UIView

    var onEditRequest: ((EditRequest) -> Void)?
    var onNewTab: ((URL) -> Void)?
    var onFullscreen: ((Bool) -> Void)?
    var onVideoFullscreenChanged: ((Bool) -> Void)?

    override init(frame: CGRect) {
        WebKitLoader.load()
        if let cls = NSClassFromString("WKWebView") as? NSObject.Type,
           let wv = cls.init() as? UIView {
            webView = wv
        } else {
            let label = UILabel()
            label.text = "이 기기에서는 WKWebView를 생성할 수 없습니다."
            label.textAlignment = .center
            webView = label
        }
        super.init(frame: frame)
        addSubview(webView)
        // 모든 프레임(iframe 포함)에 후킹/폴리필을 document-start 에 주입 → iframe 플레이어의
        // requestFullscreen 도 그 프레임 안에서 영상만 네이티브 전체화면이 되게 한다.
        installAllFramesUserScript()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { false }

    private func installAllFramesUserScript() {
        guard let config = (webView.value(forKey: "configuration") as? NSObject),
              let ucc = config.value(forKey: "userContentController") as? NSObject,
              let scriptClass: AnyClass = NSClassFromString("WKUserScript"),
              let allocated = (scriptClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue(),
              let initMethod = class_getInstanceMethod(scriptClass, NSSelectorFromString("initWithSource:injectionTime:forMainFrameOnly:"))
        else { return }
        typealias InitFn = @convention(c) (AnyObject, Selector, NSString, Int, ObjCBool) -> Unmanaged<AnyObject>
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFn.self)
        let source = "(function(){\(Self.installHooksJS)})();" as NSString
        // injectionTime 0 = AtDocumentStart, forMainFrameOnly = false
        let script = initFn(allocated, NSSelectorFromString("initWithSource:injectionTime:forMainFrameOnly:"),
                            source, 0, ObjCBool(false)).takeUnretainedValue()
        _ = ucc.perform(NSSelectorFromString("addUserScript:"), with: script)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
    }

    func scrollBy(_ dy: CGFloat) {
        guard let sv = scrollView else { return }
        var off = sv.contentOffset
        let maxY = max(0, sv.contentSize.height - sv.bounds.height)
        off.y = min(max(0, off.y + dy), maxY)
        sv.setContentOffset(off, animated: false)
    }

    private var scrollView: UIScrollView? { webView.value(forKey: "scrollView") as? UIScrollView }

    // MARK: 점(컨테이너 좌표)에서 클릭 + 편집/새탭/전체화면 감지
    func clickAt(_ point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let fx = Double(point.x / bounds.width)
        let fy = Double(point.y / bounds.height)
        evaluateJS(clickJS(fx: fx, fy: fy)) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let info = try? JSONDecoder().decode(ClickResult.self, from: data) else { return }
            if let nt = info.newTab, !nt.isEmpty, let url = URL(string: nt) { self.onNewTab?(url) }
            if let fs = info.fs, fs != 0 { self.onFullscreen?(fs == 1) }
            if info.editable { self.onEditRequest?(EditRequest(isSecure: info.secure, initialText: info.value)) }
        }
    }

    // MARK: 후킹 스크립트 (문서마다 1회) — _blank / window.open / Fullscreen 폴리필
    private static let installHooksJS = """
      if(!window.__vadaHooked){
        window.__vadaHooked=true; window.__vadaNewTab=''; window.__vadaFS=0;
        document.addEventListener('click',function(e){
          var a=e.target&&e.target.closest&&e.target.closest('a[target="_blank"]');
          if(a&&a.href){ e.preventDefault(); window.__vadaNewTab=a.href; }
        },true);
        window.open=function(u){ try{ if(u) window.__vadaNewTab=new URL(u,location.href).href; }catch(e){ if(u) window.__vadaNewTab=''+u; } return null; };
        try{ Object.defineProperty(document,'fullscreenEnabled',{configurable:true,get:function(){return true;}}); }catch(e){}
        try{ Object.defineProperty(document,'webkitFullscreenEnabled',{configurable:true,get:function(){return true;}}); }catch(e){}
        // requestFullscreen 폴리필: 비디오면 네이티브 비디오 전체화면(영상만 커짐),
        // 비디오가 없으면 앱 전체화면으로 분기.
        var findVideo=function(root){
          try{
            var v=root.querySelector&&root.querySelector('video'); if(v) return v;
            var fr=root.querySelectorAll?root.querySelectorAll('iframe'):[];
            for(var i=0;i<fr.length;i++){ try{ var d=fr[i].contentDocument; if(d){ var vv=findVideo(d); if(vv) return vv; } }catch(e){} }
          }catch(e){}
          return null;
        };
        var reqFS=function(){
          var v=(this&&this.tagName==='VIDEO')?this:((this&&findVideo(this))||findVideo(document));
          if(v&&v.webkitEnterFullscreen){
            try{ if(v.paused) v.play(); }catch(e){}
            var go=function(){ try{ if(!v.webkitDisplayingFullscreen) v.webkitEnterFullscreen(); }catch(e){} };
            go();
            if(v.readyState<1){ v.addEventListener('loadedmetadata',go,{once:true}); }
            return Promise.resolve();
          }
          window.__vadaFS=1;            // 비디오 없음 → 앱 전체화면
          return Promise.resolve();
        };
        Element.prototype.requestFullscreen=reqFS;
        Element.prototype.webkitRequestFullscreen=reqFS;
        if(window.HTMLVideoElement){ HTMLVideoElement.prototype.requestFullscreen=reqFS; HTMLVideoElement.prototype.webkitRequestFullscreen=reqFS; }
        document.exitFullscreen=function(){ var v=document.querySelector('video'); if(v&&v.webkitExitFullscreen){try{v.webkitExitFullscreen();}catch(e){}} window.__vadaFS=2; return Promise.resolve(); };
        document.webkitExitFullscreen=document.exitFullscreen;
      }
    """

    private var wasVideoFullscreen = false

    func pump() {
        let js = "(function(){\(Self.installHooksJS) var n=window.__vadaNewTab||'';window.__vadaNewTab='';var f=window.__vadaFS||0;window.__vadaFS=0;"
            + "var vfs=false;try{var vs=document.querySelectorAll('video');for(var i=0;i<vs.length;i++){if(vs[i].webkitDisplayingFullscreen){vfs=true;break;}}}catch(e){}"
            + "return JSON.stringify({newTab:n,fs:f,vfs:vfs});})();"
        evaluateJS(js) { [weak self] result, _ in
            guard let self, let s = result as? String, let data = s.data(using: .utf8),
                  let r = try? JSONDecoder().decode(PumpResult.self, from: data) else { return }
            if let nt = r.newTab, !nt.isEmpty, let url = URL(string: nt) { self.onNewTab?(url) }
            if let fs = r.fs, fs != 0 { self.onFullscreen?(fs == 1) }
            // 네이티브 영상 전체화면이 켜졌다가 꺼지면(true→false) 포커스 복구(커서 멈춤 방지).
            let nowVFS = r.vfs ?? false
            if nowVFS != self.wasVideoFullscreen {
                self.onVideoFullscreenChanged?(nowVFS)
                if !nowVFS {
                    NotificationCenter.default.post(name: .vadaReassertFocus, object: nil)
                }
            }
            self.wasVideoFullscreen = nowVFS
        }
    }

    private func clickJS(fx: Double, fy: Double) -> String {
        """
        (function(){
          \(Self.installHooksJS)
          var vw=window.innerWidth||document.documentElement.clientWidth;
          var vh=window.innerHeight||document.documentElement.clientHeight;
          var x=Math.round(\(fx)*vw), y=Math.round(\(fy)*vh);
          // 같은 출처 iframe 안까지 파고들어 실제 요소를 찾는다
          var doc=document, cx=x, cy=y, el=null, depth=0;
          while(depth<4){
            el=doc.elementFromPoint(cx,cy);
            if(el&&el.tagName==='IFRAME'){
              var d=null; try{ d=el.contentDocument; }catch(e){}
              if(d){ var r=el.getBoundingClientRect(); cx=cx-r.left; cy=cy-r.top; doc=d; depth++; continue; }
            }
            break;
          }
          if(!el){return JSON.stringify({editable:false,secure:false,value:'',newTab:'',fs:0});}
          var opts={bubbles:true,cancelable:true,view:(doc.defaultView||window),clientX:cx,clientY:cy};
          ['pointerover','mouseover','pointermove','mousemove','pointerdown','mousedown','focus','pointerup','mouseup','click'].forEach(function(t){
            try{ var E=(t.indexOf('pointer')===0&&window.PointerEvent)?PointerEvent:MouseEvent; el.dispatchEvent(new E(t,opts)); }catch(e){}
          });
          var clickable=el.closest&&el.closest('a,button,[role=button],[onclick],input[type=submit],input[type=button],label');
          if(clickable&&clickable.click){ try{clickable.click();}catch(e){} }
          // 영상 표면을 클릭하면 그 영상만 네이티브 전체화면으로 (네이티브 컨트롤의
          // 전체화면 버튼은 shadow DOM 이라 합성 클릭이 닿지 않으므로 직접 처리).
          var vid=(el.tagName==='VIDEO')?el:(el.closest&&el.closest('video'));
          if(vid&&vid.webkitEnterFullscreen){
            try{ if(vid.paused) vid.play(); }catch(e){}
            var gv=function(){ try{ if(!vid.webkitDisplayingFullscreen) vid.webkitEnterFullscreen(); }catch(e){} };
            gv();                                                        // 즉시 호출(WebKit이 준비될 때까지 내부 큐잉)
            if(vid.readyState<1){ vid.addEventListener('loadedmetadata',gv,{once:true}); }  // 백업
          }
          var t=(el.closest&&el.closest('input,textarea'))||(el.isContentEditable?el:null);
          var editable=false, secure=false, value='';
          if(t){
            var tag=t.tagName;
            if(tag==='INPUT'){
              var ty=(t.getAttribute('type')||'text').toLowerCase();
              if(['text','password','email','search','tel','url','number',''].indexOf(ty)>=0){ editable=true; secure=(ty==='password'); value=t.value||''; }
            } else if(tag==='TEXTAREA'){ editable=true; value=t.value||''; }
            else if(t.isContentEditable){ editable=true; value=t.textContent||''; }
            if(editable){ t.focus(); window.__vadaTarget=t; }
          }
          var nt=window.__vadaNewTab||''; window.__vadaNewTab='';
          var f=window.__vadaFS||0; window.__vadaFS=0;
          return JSON.stringify({editable:editable,secure:secure,value:value,newTab:nt,fs:f});
        })();
        """
    }

    func injectText(_ text: String) {
        let value = Self.jsStringLiteral(text)
        let js = """
        (function(){
          var t=window.__vadaTarget; if(!t){return;}
          t.focus();
          if(t.isContentEditable){ t.textContent=\(value); }
          else {
            var proto=(t.tagName==='TEXTAREA')?window.HTMLTextAreaElement.prototype:window.HTMLInputElement.prototype;
            var d=Object.getOwnPropertyDescriptor(proto,'value');
            if(d&&d.set){ d.set.call(t,\(value)); } else { t.value=\(value); }
          }
          ['input','change','keydown','keyup'].forEach(function(ev){ t.dispatchEvent(new Event(ev,{bubbles:true})); });
        })();
        """
        evaluateJS(js)
    }

    static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
        return out
    }

    func evaluateJS(_ js: String, completion: ((Any?, Error?) -> Void)? = nil) {
        let sel = NSSelectorFromString("evaluateJavaScript:completionHandler:")
        guard webView.responds(to: sel) else { return }
        let evaluator = unsafeBitCast(webView, to: JSEvaluator.self)
        evaluator.evaluateJavaScript(js, completionHandler: completion)
    }
}

// MARK: - 탭
final class WebTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = "새 탭"
    @Published var displayURL = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var editRequest: EditRequest?

    let container: WebContainerView
    private var timer: Timer?

    init(url: URL?) {
        container = WebContainerView(frame: .zero)
        container.onEditRequest = { [weak self] req in
            DispatchQueue.main.async { self?.editRequest = req }
        }
        startPolling()
        if let url { load(url) }
    }

    private var webView: UIView { container.webView }

    func load(_ url: URL) {
        displayURL = url.absoluteString
        let sel = NSSelectorFromString("loadRequest:")
        if webView.responds(to: sel) { _ = webView.perform(sel, with: URLRequest(url: url)) }
    }

    func goBack() { perform("goBack") }
    func goForward() { perform("goForward") }
    func reload() { perform("reload") }

    func submitText(_ text: String) { container.injectText(text); editRequest = nil }
    func cancelEdit() { editRequest = nil }

    private func perform(_ name: String) {
        let sel = NSSelectorFromString(name)
        if webView.responds(to: sel) { _ = webView.perform(sel) }
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        let back = (webView.value(forKey: "canGoBack") as? Bool) ?? false
        let forward = (webView.value(forKey: "canGoForward") as? Bool) ?? false
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
        if let t = webView.value(forKey: "title") as? String, !t.isEmpty, t != title { title = t }
        if let u = webView.value(forKey: "URL") as? URL, u.absoluteString != displayURL { displayURL = u.absoluteString }
        container.pump()
    }

    deinit { timer?.invalidate() }
}

// MARK: - 즐겨찾기
struct Bookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String
}

// MARK: - 브라우저 상태
final class BrowserModel: ObservableObject {
    @Published var tabs: [WebTab] = []
    @Published var activeID: UUID?
    @Published var bookmarks: [Bookmark] = []
    @Published var isFullscreen = false
    @Published var showBookmarks = false
    @Published var addressEditing = false
    @Published var hoveredKey: ChromeKey?
    // 일정 시간 커서를 안 움직이면 커서/전체화면 종료 UI 를 숨긴다(움직이면 다시 표시).
    @Published var controlsHidden = false

    // 커서 히트테스트용 상단 UI 프레임(.global 좌표)
    var chromeFrames: [ChromeKey: CGRect] = [:]
    // 네이티브 영상 전체화면 활성 여부(포커스 워치독이 이때는 개입하지 않음)
    var isVideoFullscreen = false

    private let bookmarksKey = "VadaWeb.bookmarks"
    let homeURL = URL(string: "https://www.naver.com")!

    init() {
        loadBookmarks()
        addTab(url: homeURL)
    }

    var activeTab: WebTab? { tabs.first { $0.id == activeID } }
    var modalActive: Bool { showBookmarks || addressEditing || (activeTab?.editRequest != nil) }

    private var addressLabel: String {
        let u = activeTab?.displayURL ?? ""
        return u.isEmpty ? "주소 입력" : u
    }

    var toolbarItems: [ChromeItem] {
        let t = activeTab
        return [
            ChromeItem(.back, "뒤로") { t?.goBack() },
            ChromeItem(.forward, "앞으로") { t?.goForward() },
            ChromeItem(.address, addressLabel) { [weak self] in self?.beginAddressEdit() },
            ChromeItem(.reload, "새로고침") { t?.reload() },
            ChromeItem(.bookmarkToggle, isCurrentBookmarked ? "★" : "☆") { [weak self] in self?.addCurrentBookmark() },
            ChromeItem(.bookmarks, "즐겨찾기") { [weak self] in self?.openBookmarksPanel() },
            ChromeItem(.fullscreen, "전체화면") { [weak self] in self?.isFullscreen = true },
        ]
    }

    var tabRowItems: [ChromeItem] {
        var items: [ChromeItem] = []
        for t in tabs {
            items.append(ChromeItem(.tab(t.id), t.title.isEmpty ? "새 탭" : t.title, isTab: true, active: t.id == activeID) { [weak self] in self?.select(t) })
            items.append(ChromeItem(.closeTab(t.id), "✕") { [weak self] in self?.closeTab(t) })
        }
        items.append(ChromeItem(.newTab, "＋") { [weak self] in self?.addTab(url: nil) })
        return items
    }

    var allChromeItems: [ChromeItem] {
        var all = toolbarItems + tabRowItems
        if isFullscreen { all.append(ChromeItem(.exitFullscreen, "✕ 전체화면 종료") { [weak self] in self?.isFullscreen = false }) }
        return all
    }

    func activate(_ key: ChromeKey) {
        if let item = allChromeItems.first(where: { $0.key == key }) { item.action() }
    }

    // MARK: 뒤로(<) 처리 — 모달 닫기 > 전체화면 해제 > 브라우저 뒤로가기. 더 갈 곳이 없으면 무시(앱 유지).
    // 여러 입력 경로(GameController buttonMenu / UIPress.menu / onExitCommand)에서 호출되므로 디바운스한다.
    private var lastBack: CFTimeInterval = 0
    func handleBackCommand() {
        let now = CACurrentMediaTime()
        guard now - lastBack > 0.30 else { return }
        lastBack = now
        if let tab = activeTab, tab.editRequest != nil { tab.cancelEdit(); return }
        if addressEditing { endAddressEdit(); return }
        if showBookmarks { closeBookmarksPanel(); return }
        if isFullscreen { isFullscreen = false; return }
        if let tab = activeTab, tab.canGoBack { tab.goBack() }
        // 그 외(첫 페이지)에서는 아무것도 하지 않는다. 앱 종료는 리모컨의 TV/홈 버튼으로.
    }

    // MARK: 입력 콜백 연결
    func attach(_ tab: WebTab) {
        tab.container.onNewTab = { [weak self] url in self?.addTab(url: url) }
        tab.container.onFullscreen = { [weak self] on in self?.isFullscreen = on }
        tab.container.onVideoFullscreenChanged = { [weak self] on in self?.isVideoFullscreen = on }
    }

    // MARK: 탭
    func addTab(url: URL?) {
        let tab = WebTab(url: url ?? homeURL)
        attach(tab)
        tabs.append(tab)
        activeID = tab.id
    }

    func closeTab(_ tab: WebTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty { addTab(url: homeURL) }
        else if activeID == tab.id { activeID = tabs[min(idx, tabs.count - 1)].id }
    }

    func select(_ tab: WebTab) { activeID = tab.id }

    // MARK: 즐겨찾기 / 주소
    func beginAddressEdit() { addressEditing = true }
    func endAddressEdit() { addressEditing = false }
    func openBookmarksPanel() { showBookmarks = true }
    func closeBookmarksPanel() { showBookmarks = false }

    func addCurrentBookmark() {
        guard let tab = activeTab, !tab.displayURL.isEmpty else { return }
        guard !bookmarks.contains(where: { $0.url == tab.displayURL }) else { return }
        bookmarks.append(Bookmark(title: tab.title.isEmpty ? tab.displayURL : tab.title, url: tab.displayURL))
        saveBookmarks()
    }
    func removeBookmark(_ b: Bookmark) { bookmarks.removeAll { $0.id == b.id }; saveBookmarks() }
    func openBookmark(_ b: Bookmark) {
        guard let url = URL(string: b.url) else { return }
        activeTab?.load(url); closeBookmarksPanel()
    }
    var isCurrentBookmarked: Bool {
        guard let tab = activeTab else { return false }
        return bookmarks.contains { $0.url == tab.displayURL }
    }
    func loadAddress(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { endAddressEdit(); return }
        if !text.contains("://") { text = "https://" + text }
        if let url = URL(string: text) { activeTab?.load(url) }
        endAddressEdit()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: bookmarksKey) }
    }
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let list = try? JSONDecoder().decode([Bookmark].self, from: data) { bookmarks = list }
    }
}

// MARK: - 활성 탭 컨테이너 호스팅
struct WebHost: UIViewRepresentable {
    let tab: WebTab
    func makeUIView(context: Context) -> UIView { let w = UIView(); attach(to: w); return w }
    func updateUIView(_ wrap: UIView, context: Context) { attach(to: wrap) }
    private func attach(to wrap: UIView) {
        guard tab.container.superview !== wrap else { return }
        wrap.subviews.forEach { $0.removeFromSuperview() }
        let c = tab.container
        c.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(c)
        NSLayoutConstraint.activate([
            c.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            c.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            c.topAnchor.constraint(equalTo: wrap.topAnchor),
            c.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
    }
}

// MARK: - 전체화면 커서 + 입력 오버레이
final class InputOverlayView: UIView {
    weak var model: BrowserModel?
    private let cursor = CursorView()
    private var cursorPos = CGPoint.zero
    private let nudgeStep: CGFloat = 16   // 방향키: 디테일을 위해 작게
    private var cursorSuppressedUntil: CFTimeInterval = 0
    private var lastClick: CFTimeInterval = 0
    private var focusTimer: Timer?
    // 유휴 자동 숨김: 마지막 커서 이동 시각, 숨김 상태
    private var lastActivity: CFTimeInterval = CACurrentMediaTime()
    private var controlsIdle = false
    private let idleHideAfter: CFTimeInterval = 5.0
    // 방향키 길게 누름(hold) → 가속 연속 이동
    private var holdDX: CGFloat = 0, holdDY: CGFloat = 0
    private var holdStart: CFTimeInterval = 0
    private var holdLink: CADisplayLink?

    init(model: BrowserModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = .clear
        addSubview(cursor)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        addGestureRecognizer(pan)
        let click = UITapGestureRecognizer(target: self, action: #selector(onSelectTap))
        click.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        addGestureRecognizer(click)
        NotificationCenter.default.addObserver(self, selector: #selector(reassertFocus),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reassertFocus),
                                               name: .vadaReassertFocus, object: nil)
        // 포커스 워치독: 어떤 간섭으로 포커스를 잃어도(모달/영상 전체화면 제외) 즉시 되찾아
        // 커서 제어를 항상 보장한다.
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.focusWatchdog()
            self?.idleCheck()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { focusTimer?.invalidate() }

    private var focusLostSince: CFTimeInterval = 0
    private func focusWatchdog() {
        guard window != nil else { focusLostSince = 0; return }
        if isFocused { focusLostSince = 0; return }
        // 모달/영상 전체화면 중에는 오버레이가 포커스를 안 갖는 게 정상 → 개입 금지.
        guard let model, !model.modalActive, !model.isVideoFullscreen else { focusLostSince = 0; return }
        let now = CACurrentMediaTime()
        if focusLostSince == 0 { focusLostSince = now; return }   // 유예(영상 전체화면 감지 레이스 회피)
        if now - focusLostSince >= 0.6 {
            let env: UIFocusEnvironment = window ?? self
            env.setNeedsFocusUpdate()
            env.updateFocusIfNeeded()
            focusLostSince = 0
        }
    }

    override var canBecomeFocused: Bool { !(model?.modalActive ?? false) }

    func syncModalState() {
        refreshControlsVisibility()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // 5초 이상 움직임이 없으면 커서/전체화면 종료 UI 를 숨긴다.
    private func idleCheck() {
        guard !controlsIdle, !(model?.modalActive ?? false) else { return }
        if CACurrentMediaTime() - lastActivity >= idleHideAfter {
            controlsIdle = true
            refreshControlsVisibility()
        }
    }

    // 커서 이동/클릭 등 활동 발생 → 타이머 리셋 + 숨겨져 있었으면 다시 표시.
    private func markActivity() {
        lastActivity = CACurrentMediaTime()
        if controlsIdle {
            controlsIdle = false
            refreshControlsVisibility()
        }
    }

    private func refreshControlsVisibility() {
        let modal = model?.modalActive ?? false
        cursor.isHidden = modal || controlsIdle
        // 전체화면 종료 UI(SwiftUI) 토글
        if model?.controlsHidden != controlsIdle { model?.controlsHidden = controlsIdle }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if cursorPos == .zero { cursorPos = CGPoint(x: bounds.midX, y: bounds.midY) }
        cursor.center = cursorPos
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            RemoteInput.shared.start()
            RemoteInput.shared.onScroll = { [weak self] dy in self?.scrollContent(dy) }
            RemoteInput.shared.onActive = { [weak self] in self?.cursorSuppressedUntil = CACurrentMediaTime() + 0.25 }
            RemoteInput.shared.onCenterClick = { [weak self] in self?.performClick() }
            RemoteInput.shared.onCursorDelta = { [weak self] ndx, ndy in self?.gcCursorMove(ndx, ndy) }
            RemoteInput.shared.onBack = { [weak self] in self?.model?.handleBackCommand() }
            reassertFocus()
        }
    }

    // 네이티브 영상 전체화면 등에서 돌아왔을 때 포커스를 다시 가져온다(커서 멈춤 방지).
    @objc private func reassertFocus() {
        guard !(model?.modalActive ?? false) else { return }
        // 디스미스가 정착된 뒤 윈도우 기준으로 포커스 재평가 → 유일 포커스 대상인 오버레이로 복귀.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let env: UIFocusEnvironment = self.window ?? self
            env.setNeedsFocusUpdate()
            env.updateFocusIfNeeded()
        }
    }

    /// 활성 웹 컨테이너의 윈도우 좌표 프레임 (오버레이 로컬 == 윈도우).
    private func webRectInWindow() -> (rect: CGRect, container: WebContainerView)? {
        guard let c = model?.activeTab?.container, c.window != nil else { return nil }
        return (c.convert(c.bounds, to: nil), c)
    }

    // MARK: 입력
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .leftArrow:  startHold(-1, 0); handled = true
            case .rightArrow: startHold(1, 0); handled = true
            case .upArrow:    startHold(0, -1); handled = true
            case .downArrow:  startHold(0, 1); handled = true
            case .select:     performClick(); handled = true
            case .menu:       model?.handleBackCommand(); handled = true
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pressesContainArrow(presses) { stopHold() }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if pressesContainArrow(presses) { stopHold() }
        super.pressesCancelled(presses, with: event)
    }

    private func pressesContainArrow(_ presses: Set<UIPress>) -> Bool {
        presses.contains { [.leftArrow, .rightArrow, .upArrow, .downArrow].contains($0.type) }
    }

    // MARK: 방향버튼 = 작은 커서 이동(+길게 누르면 가속 연속 이동) — 절대 클릭하지 않는다
    private func startHold(_ dx: CGFloat, _ dy: CGFloat) {
        // 같은 방향 반복 began(키 리피트)은 무시해 연속 이동 상태를 유지
        if holdLink != nil, holdDX == dx, holdDY == dy { return }
        holdDX = dx; holdDY = dy
        moveCursor(dx: dx * nudgeStep, dy: dy * nudgeStep)   // 즉시 한 칸(짧게 눌렀을 때의 디테일)
        holdStart = CACurrentMediaTime()
        holdLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(holdTick))
        link.add(to: .main, forMode: .common)
        holdLink = link
    }

    @objc private func holdTick() {
        let elapsed = CACurrentMediaTime() - holdStart
        guard elapsed > 0.35 else { return }                 // 짧은 탭은 단발 이동만, 길게 눌러야 연속
        let speed = min(1500, 360 + (elapsed - 0.35) * 1400) // points/sec, 점점 가속
        let step = speed * CGFloat(holdLink?.duration ?? (1.0 / 60.0))
        moveCursor(dx: holdDX * step, dy: holdDY * step)
    }

    private func stopHold() {
        holdLink?.invalidate(); holdLink = nil
        holdDX = 0; holdDY = 0
    }

    @objc private func onSelectTap() { performClick() }

    // UIKit 팬은 GameController 가 입력을 주지 않을 때만 쓰는 폴백.
    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        if CACurrentMediaTime() - RemoteInput.shared.lastDpadTime < 0.25 { return }   // GC 활성 → 팬 무시
        if CACurrentMediaTime() < cursorSuppressedUntil { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let speed = (t.x * t.x + t.y * t.y).squareRoot()
        guard speed > 0.01 else { return }
        let gain = min(3.6, 0.9 + speed * 0.075)
        var dx = t.x * gain, dy = t.y * gain
        let mag = (dx * dx + dy * dy).squareRoot()
        let minMove: CGFloat = 2.5
        if mag < minMove { let s = minMove / max(mag, 0.0001); dx *= s; dy *= s }
        moveCursor(dx: dx, dy: dy)
    }

    // GameController 절대좌표 델타 → 커서 이동(포커스 무관). 가속 + 최소 이동 보장.
    private func gcCursorMove(_ ndx: CGFloat, _ ndy: CGFloat) {
        let speed = (ndx * ndx + ndy * ndy).squareRoot()
        guard speed > 0.0005 else { return }
        // 가속 상한을 낮춤: 손 뗌 직전 빠른 드리프트가 큰 점프로 증폭되는 걸 줄인다.
        let gain = 1500 * min(1.5, 0.8 + speed * 5)
        var dx = ndx * gain, dy = -ndy * gain          // GC y 위쪽(+) → 화면 위(-)
        let mag = (dx * dx + dy * dy).squareRoot()
        let minMove: CGFloat = 2.0
        if mag < minMove { let s = minMove / max(mag, 0.0001); dx *= s; dy *= s }
        moveCursor(dx: dx, dy: dy)
    }

    private func moveCursor(dx: CGFloat, dy: CGFloat) {
        markActivity()                       // 움직이면 숨김 해제 + 유휴 타이머 리셋
        cursorPos.x = min(max(0, cursorPos.x + dx), bounds.width)
        cursorPos.y = min(max(0, cursorPos.y + dy), bounds.height)
        cursor.center = cursorPos
        updateHover()
    }

    private func updateHover() {
        guard let model else { return }
        var hk: ChromeKey?
        for item in model.allChromeItems {
            if let r = model.chromeFrames[item.key], r.contains(cursorPos) { hk = item.key; break }
        }
        if hk != model.hoveredKey { model.hoveredKey = hk }
    }

    // MARK: 클릭 → 상단 UI 혹은 웹
    private func performClick() {
        markActivity()                       // 클릭도 활동으로 간주(숨김 해제, 타이머 리셋)
        let now = CACurrentMediaTime()
        guard now - lastClick > 0.25 else { return }
        lastClick = now
        guard let model, !model.modalActive else { return }
        pulseCursor()
        let p = cursorPos
        for item in model.allChromeItems {
            if let r = model.chromeFrames[item.key], r.contains(p) { item.action(); return }
        }
        if let web = webRectInWindow(), web.rect.contains(p) {
            web.container.clickAt(CGPoint(x: p.x - web.rect.minX, y: p.y - web.rect.minY))
        }
    }

    private func pulseCursor() {
        cursor.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.07, animations: {
            self.cursor.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.cursor.backgroundColor = UIColor(red: 0.20, green: 0.70, blue: 0.86, alpha: 1)
        }, completion: { _ in
            UIView.animate(withDuration: 0.13) {
                self.cursor.transform = .identity
                self.cursor.backgroundColor = UIColor.white.withAlphaComponent(0.92)
            }
        })
    }

    // MARK: 스크롤 (바깥 링을 세로로 문지를 때만 — 커서 이동으로는 스크롤하지 않음)
    private func scrollContent(_ dy: CGFloat) {
        guard let model, !model.modalActive else { return }
        model.activeTab?.container.scrollBy(dy)
    }
}

struct InputOverlay: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> InputOverlayView { InputOverlayView(model: model) }
    func updateUIView(_ view: InputOverlayView, context: Context) {
        view.model = model
        view.syncModalState()
    }
}

// MARK: - 상단 UI 프레임 수집 (.global)
struct ChromeFramesKey: PreferenceKey {
    static var defaultValue: [ChromeKey: CGRect] = [:]
    static func reduce(value: inout [ChromeKey: CGRect], nextValue: () -> [ChromeKey: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
