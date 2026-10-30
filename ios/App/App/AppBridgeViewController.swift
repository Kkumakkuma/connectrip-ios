import UIKit
import WebKit
import Capacitor

/// 앱 안에만 있는 플러그인을 등록하는 브리지 화면 (2026-10-14).
/// npm 플러그인은 Capacitor 가 자동으로 싣지만, 앱 타깃 안의 플러그인(AuthSessionPlugin — iOS 본인확인 창, CtPrintPlugin — 인쇄)은 여기서 직접 등록해야 한다.
/// capacitorDidLoad 는 웹 화면을 처음 불러오기 전에 불리므로 첫 이동부터 가로채기가 적용된다.
/// SafeAreaHostViewController 가 이 화면을 자식으로 둔다.
class AppBridgeViewController: CAPBridgeViewController {
    // webView.uiDelegate 는 weak 라서 바꿔 끼운 처리기를 여기서 붙잡아 둔다.
    private var koreanDialogs: KoreanDialogUIDelegate?
    // Capacitor 설정의 CapacitorCookies·CapacitorHttp 사용 여부(아래 시작 prompt 우회가 같은 답을 내도록)
    private var launchPromptAnswers = (cookies: false, http: false)

    // ── 시작 화면 멈춤 우회(Capacitor #8664, 2026-10-27) ──
    // Capacitor 의 native-bridge.js 는 문서 시작에서 CapacitorCookies·CapacitorHttp 사용 여부를 동기 prompt() 두 번으로 묻는다.
    // iOS 27 시뮬레이터에서 첫 실행 때 가끔 그 응답이 영영 안 와서 웹 화면이 하얀 채 멈췄다(xcode-27 러너 30번 중 2번 —
    // WebContent 가 LocalDOMWindow::prompt → waitForSyncReply 에서 대기, 이슈 #8664 와 같은 표본·확률). 답은 정적 설정이라
    // 앱이 미리 안다 — native-bridge.js 보다 먼저 도는 문서 시작 스크립트가 그 두 질문만 바로 답하고, 나머지 prompt 는 원래대로 넘긴다.
    // Capacitor 가 웹 화면을 만들기 직전에 스크립트 목록(userContentController)을 자기 것으로 바꿔 끼우므로 webViewConfiguration(for:)
    // 이 아니라 webView(with:configuration:) 에서 넣는다(그 뒤에 Capacitor 가 native-bridge.js 를 넣으니 이 스크립트가 먼저 돈다).
    // src/lib/iosLaunchPromptShim.test.js 가 Capacitor 의 두 질문 모양과 이 스크립트를 대조한다(Capacitor 를 올릴 때 확인).
    static let launchPromptShimTemplate = """
    (function () {
      var answers = { 'CapacitorCookies.isEnabled': '__COOKIES__', 'CapacitorHttp': '__HTTP__' };
      var original = window.prompt;
      window.prompt = function (message) {
        if (typeof message === 'string' && message.charAt(0) === '{') {
          try {
            var type = JSON.parse(message).type;
            if (Object.prototype.hasOwnProperty.call(answers, type)) { return answers[type]; }
          } catch (e) {}
        }
        return original.apply(window, arguments);
      };
    })();
    """

    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        // WebViewDelegationHandler 가 같은 질문에 답할 때 쓰는 값과 같다(getPluginConfig(...).getBoolean("enabled", false))
        launchPromptAnswers = (
            cookies: instanceConfiguration.getPluginConfig("CapacitorCookies").getBoolean("enabled", false),
            http: instanceConfiguration.getPluginConfig("CapacitorHttp").getBoolean("enabled", false)
        )
        return super.webViewConfiguration(for: instanceConfiguration)
    }

    override func webView(with frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        let source = Self.launchPromptShimTemplate
            .replacingOccurrences(of: "__COOKIES__", with: launchPromptAnswers.cookies ? "true" : "false")
            .replacingOccurrences(of: "__HTTP__", with: launchPromptAnswers.http ? "true" : "false")
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return super.webView(with: frame, configuration: configuration)
    }

    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(AuthSessionPlugin())
        bridge?.registerPluginInstance(CtPrintPlugin())
        bridge?.registerPluginInstance(CtNavPlugin())
        guard let webView = webView else { return }
        // 화면 왼쪽 끝에서 오른쪽으로 밀면 이전 화면으로(2026-10-18 쿠마님 11989 "아이폰은 뒤로가기 버튼이 없어 불편").
        // 앱 안 이동(history.pushState)도 뒤로 목록에 쌓이므로 웹의 '뒤로'와 같다. 첫 화면에서는 아무 일도 없다.
        // 글쓰기 창처럼 안드로이드 뒤로가기를 먼저 받는 창이 떠 있는 동안은 웹이 끈다(CtNavPlugin, src/lib/backStack.js).
        webView.allowsBackForwardNavigationGestures = true
        // 웹 화면의 alert·confirm·prompt 단추를 한국어로(2026-10-18 — Capacitor 기본은 영어 'Ok'·'Cancel' 로 박혀 있다).
        let dialogs = KoreanDialogUIDelegate(base: webView.uiDelegate, host: self)
        koreanDialogs = dialogs
        webView.uiDelegate = dialogs
    }
}

/// 완료 처리기를 꼭 한 번만 부른다(단추를 눌렀을 때 · 창을 못 띄웠을 때 중 먼저 온 쪽).
private final class Once<T> {
    private var fn: ((T) -> Void)?
    init(_ fn: @escaping (T) -> Void) { self.fn = fn }
    func callAsFunction(_ value: T) {
        guard let f = fn else { return }
        fn = nil
        f(value)
    }
}

/// 웹 화면의 alert·confirm·prompt 를 한국어 단추('확인'·'취소')로 띄우는 WKUIDelegate (2026-10-18).
/// 이 세 가지만 직접 처리하고, 나머지 WKUIDelegate 동작(새 창, 카메라 권한 등)과 Capacitor 가 쿠키·HTTP 동기 호출에 쓰는
/// 내부 prompt 는 Capacitor 원래 처리기(WebViewDelegationHandler, bridge 가 붙잡고 있다)에 그대로 넘긴다.
final class KoreanDialogUIDelegate: NSObject, WKUIDelegate {
    private weak var base: WKUIDelegate?   // WKUIDelegate 는 NSObjectProtocol 을 이어받아 responds(to:) 를 쓸 수 있다
    private weak var host: UIViewController?

    init(base: WKUIDelegate?, host: UIViewController) {
        self.base = base
        self.host = host
        super.init()
    }

    // 여기서 구현하지 않은 선택 메서드는 원래 처리기가 있으면 그쪽으로 보낸다.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return base?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let base = base, base.responds(to: aSelector) { return base }
        return super.forwardingTarget(for: aSelector)
    }

    /// 맨 위 화면에서 창을 띄운다(본인확인 창·인쇄 창이 떠 있을 수 있다). 다른 화면이 열리거나 닫히는 중이면 그 전환이 끝난 뒤 다시 해 보고,
    /// UIKit 이 표시를 거절하면(전환 중·창에 안 붙음 등) fail 로 바로 끝낸다 — 완료 처리기를 안 부르면 웹 화면 전체가 멈춘다(codex·agy).
    private func show(_ alert: UIAlertController, attempt: Int = 0, fail: @escaping () -> Void) {
        guard let host = host, host.viewIfLoaded?.window != nil else { fail(); return }
        var top: UIViewController = host
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        // 닫히는 중인 화면(top 위) 또는 막 열리는 중인 화면(top 자신)이 있으면 그 전환이 끝난 뒤 다시(세 번까지)
        let moving: UIViewController? = top.presentedViewController ?? (top.isBeingPresented ? top : nil)
        if let moving = moving, attempt < 3 {
            // 전환이 끝나면 다시 해 본다. 전환 정보가 없거나 등록을 못 하면(false — 완료 콜백이 안 올 수도 있다) 다음 차례에
            // 다시 해 보고, 늦게 오는 완료 콜백은 또 띄우지 않게 막는다(codex·agy 2차).
            var handled = false
            let retry: (UIViewControllerTransitionCoordinatorContext) -> Void = { _ in
                if handled { return }
                handled = true
                self.show(alert, attempt: attempt + 1, fail: fail)
            }
            if let coordinator = moving.transitionCoordinator,
               coordinator.animate(alongsideTransition: nil, completion: retry) { return }
            handled = true
            DispatchQueue.main.async { self.show(alert, attempt: attempt + 1, fail: fail) }
            return
        }
        top.present(alert, animated: true, completion: nil)
        // UIKit 이 거절하면(전환 중·창에 안 붙음 등) 창이 뜨지 않는다 — 한 차례 뒤에 확인해 그때도 안 떠 있으면 끝낸다
        // (바로 확인하면 표시 상태가 늦게 반영되는 경우 떠 있는 창을 실패로 볼 수 있다, agy 2차)
        DispatchQueue.main.async {
            if alert.presentingViewController == nil { fail() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let done = Once<Void> { _ in completionHandler() }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in done(()) })
        show(alert) { done(()) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        // 띄우지 못하면 '취소'로 끝낸다(탈퇴처럼 되돌릴 수 없는 일이 확인 없이 진행되지 않게)
        let done = Once<Bool>(completionHandler)
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in done(true) })
        show(alert) { done(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        // Capacitor 는 쿠키·HTTP 설정을 동기로 묻는 데 prompt 를 쓴다({"type":"CapacitorCookies.get"} 등) — 그건 원래 처리기로 보낸다.
        if Self.isCapacitorInternal(prompt) {
            if base?.webView?(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText,
                              initiatedByFrame: frame, completionHandler: completionHandler) == nil {
                completionHandler(nil)
            }
            return
        }
        let done = Once<String?>(completionHandler)
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel) { _ in done(nil) })
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak alert] _ in
            done(alert?.textFields?.first?.text ?? "")
        })
        show(alert) { done(nil) }
    }

    /// Capacitor 내부 prompt 인가 — 본문이 {"type":"Capacitor…"} JSON 이면(WebViewDelegationHandler 와 같은 판별).
    private static func isCapacitorInternal(_ prompt: String) -> Bool {
        guard let data = prompt.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return type.hasPrefix("Capacitor")
    }
}

/// 아이폰 왼쪽 끝 밀어 뒤로 가기 켜고 끄기(2026-10-19). 글쓰기 창·시트·사진 크게 보기처럼 안드로이드 뒤로가기를 먼저 받는 창
/// (src/lib/backStack.js)이 떠 있는 동안 웹이 끈다 — 밀면 WebKit 이 바로 이전 화면으로 가 버려 쓰던 글이 '임시저장할까요?' 없이
/// 사라진다(agy). 창이 다 닫히면 다시 켠다. JS 쪽은 src/lib/iosBackGesture.js (jsName CtNav, 메서드 setBackGesture).
@objc(CtNavPlugin)
public class CtNavPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CtNavPlugin"
    public let jsName = "CtNav"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setBackGesture", returnType: CAPPluginReturnPromise)
    ]

    @objc func setBackGesture(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? true
        DispatchQueue.main.async {
            self.bridge?.webView?.allowsBackForwardNavigationGestures = enabled
            call.resolve()
        }
    }
}

/// 여행 플래너 '인쇄 · PDF 저장'의 iOS 경로 (2026-10-17) — 안드로이드 CtPrintPlugin.java 의 짝.
/// WKWebView 는 window.print() 로 인쇄 창을 열지 않는다 — 지금 웹 화면을 UIPrintInteractionController 로 넘긴다
/// (프린터로 인쇄하거나, 인쇄 미리보기에서 PDF 로 공유·저장할 수 있다). 종이 모양은 웹과 같은 인쇄용 CSS(@media print)를 따른다.
/// 새 파일로 두면 Xcode 프로젝트(project.pbxproj)에 따로 넣어야 해서 등록하는 이 파일에 함께 둔다.
/// JS 쪽은 src/planner/lib/printPage.js (jsName CtPrint, 메서드 printWebView).
@objc(CtPrintPlugin)
public class CtPrintPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CtPrintPlugin"
    public let jsName = "CtPrint"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "printWebView", returnType: CAPPluginReturnPromise)
    ]

    @objc func printWebView(_ call: CAPPluginCall) {
        let raw = call.getString("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let job = raw.isEmpty ? "커넥트립 여행 일정" : raw
        DispatchQueue.main.async {
            guard let webView = self.bridge?.webView else {
                call.reject("PRINT_UNAVAILABLE")
                return
            }
            let info = UIPrintInfo(dictionary: nil)
            info.outputType = .general
            info.jobName = job
            let controller = UIPrintInteractionController.shared
            controller.printInfo = info
            controller.printFormatter = webView.viewPrintFormatter()
            let done: UIPrintInteractionController.CompletionHandler = { _, _, error in
                if let error = error {
                    call.reject("PRINT_FAILED", nil, error)
                } else {
                    call.resolve()
                }
            }
            // 아이패드는 인쇄 창을 띄울 자리를 줘야 한다(아이폰은 아래에서 올라오는 시트).
            // 창을 못 띄우면(false — 다른 창이 떠 있는 등) 완료 콜백이 오지 않으니 바로 거절한다(agy)
            let shown: Bool
            if UIDevice.current.userInterfaceIdiom == .pad {
                let rect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
                shown = controller.present(from: rect, in: webView, animated: true, completionHandler: done)
            } else {
                shown = controller.present(animated: true, completionHandler: done)
            }
            if !shown {
                call.reject("PRINT_PRESENT_FAILED")
            }
        }
    }
}
