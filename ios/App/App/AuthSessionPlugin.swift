import AuthenticationServices
import Capacitor
import UIKit
import WebKit

/// iOS 본인확인 창 (2026-10-14) — 안드로이드 IntentUrlPlugin.java 의 iOS 짝.
///
/// 앱 WebView 가 사이트의 /app-identity(PASS 본인확인 화면)로 이동하려 하면 가로채(shouldOverrideLoad) Safari 앱 대신
/// ASWebAuthenticationSession 으로 연다. 다리 페이지(app-return.html)가 connecttrip://app-return… 으로 이동하면 그 주소는 시스템이
/// 다른 앱에 배달하지 않고 이 세션(시작한 앱)만 받는다 — 같은 스킴을 등록한 다른 앱이 결속 비밀값(ds)을 받아 가지 못하게(codex·agy 지적).
/// 받은 주소는 실제 딥링크와 똑같이 Capacitor App 플러그인의 appUrlOpen 으로 넘겨 AppReturnBridge.jsx 가 처리한다 — JS 는 바꾸지 않는다.
///
/// - ephemeral 세션: Safari 와 쿠키·저장소를 나누지 않는다(ds 가 세션 밖에 남지 않고, '…로그인하려고 합니다' 동의 창도 없다).
///   그래서 '인증 결과 가져오기'(resume=1)는 새 세션에서 찾을 수 없다 — 세션을 열지 않고 곧바로 '다시 진행' 실패 복귀를 넣는다.
/// - 취소·세션 오류·잘못된 콜백: 그 시도의 state 를 실은 실패 복귀(code·message)를 같은 경로로 넣는다 → identity.js parseIdentityReturn 이
///   같은 state 일 때만 진행 기록을 끝내고 안내한다(C2). 세션을 아예 시작하지 못하면(즉시·같은 시도) 안드로이드와 같은 창 이벤트를 보낸다.
/// - 막지 못하는 것: 공격자가 시작한 흐름(일반 Safari 에서 공격자 링크로 PASS, 또는 악성 앱이 자기 세션으로 /app-identity 를 여는 피싱).
///
/// 아래 상수는 JS·안드로이드와 같아야 한다 — src/lib/authSessionContract.test.js 가 원문을 대조한다.
@objc(AuthSessionPlugin)
public class AuthSessionPlugin: CAPPlugin, CAPBridgedPlugin, ASWebAuthenticationPresentationContextProviding {
    public let identifier = "AuthSessionPlugin"
    public let jsName = "CTAuthSession"
    public let pluginMethods: [CAPPluginMethod] = []

    static let siteHosts: Set<String> = ["www.connecttrip.co.kr", "connecttrip.co.kr"]
    static let appIdentityPath = "/app-identity"
    static let callbackScheme = "connecttrip"
    static let callbackHost = "app-return"
    static let identityFlow = "identity"
    static let openFailedEvent = "ct-app-identity-open-failed"
    /// identity.js IDENTITY_RETURN_PARAMS — 실패 복귀를 만들 때 원래 쿼리(q)에서 뺀다(appBridgeUrl 과 같은 모양)
    static let returnParams: Set<String> = [
        "flow", "state", "identityVerificationId", "identityVerificationTxId", "transactionType",
        "code", "message", "pgCode", "pgMessage", "resume", "ds"
    ]
    static let cancelledCode = "IDENTITY_SESSION_CANCELLED"
    static let cancelledMessage = "본인확인 창을 닫았어요. 다시 하려면 「PASS로 본인확인」을 눌러 주세요."
    static let notFoundCode = "IDENTITY_RESULT_NOT_FOUND"
    static let notFoundMessage = "인증 결과를 찾지 못했어요. 「PASS로 본인확인」으로 본인확인을 다시 진행해 주세요."
    static let failedCode = "IDENTITY_SESSION_FAILED"
    static let failedMessage = "본인확인 창을 열지 못했어요. 잠시 뒤 다시 시도해 주세요."
    static let invalidCode = "IDENTITY_CALLBACK_INVALID"
    static let invalidMessage = "본인확인 정보를 확인할 수 없어요. 본인확인을 다시 시작해 주세요."

    /// 한 번의 본인확인 시도 — 시작할 때 정한 값만 쓴다(완료가 늦게 와도 이 문맥으로 끝낸다)
    struct Attempt {
        let id: Int
        let state: String
        let to: String
        let query: [(String, String)]
    }

    private var session: ASWebAuthenticationSession?
    private var current: Attempt?
    private var lastAttemptId = 0
    private weak var anchorWindow: UIWindow?

    // MARK: - 가로채기

    override public func shouldOverrideLoad(_ navigationAction: WKNavigationAction) -> NSNumber? {
        guard let url = navigationAction.request.url, Self.isAppIdentityURL(url) else { return nil }
        let isMainFrame = navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true
        guard isMainFrame else { return nil }
        handleAppIdentity(url)
        return true
    }

    static func isAppIdentityURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), siteHosts.contains(host) else { return false }
        return url.path == appIdentityPath
    }

    private func handleAppIdentity(_ url: URL) {
        let params = Self.formDecode(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        let state = params.first { $0.0 == "state" }?.1 ?? ""
        let to = params.first { $0.0 == "to" }?.1 ?? ""
        let qRaw = params.first { $0.0 == "q" }?.1 ?? ""
        let resume = params.first { $0.0 == "resume" }?.1 == "1"

        guard Self.isState(state) else {
            // 앱이 만든 주소가 아니다(state 없음) — 결속할 시도가 없으니 기록을 끝내는 창 이벤트로만 알린다
            fireOpenFailed()
            return
        }
        let query = Self.formDecode(qRaw.hasPrefix("?") ? String(qRaw.dropFirst()) : qRaw)
        guard Self.isReturnPath(to) else {
            // 앱이 돌아올 수 없는 경로 — 실패 복귀를 넣어도 JS(appReturnTarget)가 버려 화면이 멈춘다. 즉시·같은 시도이므로 창 이벤트로 끝낸다.
            fireOpenFailed()
            return
        }
        let path = to

        if let active = current {
            if active.state == state { return }   // 같은 시도를 두 번 누름 — 열린 창을 그대로 둔다
            // 새 시도(JS 가 시작 기록을 이미 바꿨다) — 이전 창을 닫는다. 이전 완료는 번호가 달라 버려진다.
            current = nil
            session?.cancel()
            session = nil
        }
        lastAttemptId += 1
        let attempt = Attempt(id: lastAttemptId, state: state, to: path, query: query)

        if resume {
            // '인증 결과 가져오기' — ephemeral 이라 새 세션에는 이전 결과가 없다. 창을 열지 않고 바로 '다시 진행' 안내.
            route(Self.failureURL(attempt, code: Self.notFoundCode, message: Self.notFoundMessage))
            return
        }
        // 표시할 창은 시작할 때 정해 둔다(presentationAnchor 가 늦게 불려도 같은 창, 없으면 시작하지 않는다)
        guard let window = presentationWindow() else {
            fireOpenFailed()
            return
        }
        anchorWindow = window
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        guard let target = components?.url else {
            fireOpenFailed()
            return
        }
        let attemptId = attempt.id
        let authSession = ASWebAuthenticationSession(url: target, callbackURLScheme: Self.callbackScheme) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.complete(attemptId: attemptId, callbackURL: callbackURL, error: error)
            }
        }
        authSession.presentationContextProvider = self
        authSession.prefersEphemeralWebBrowserSession = true
        session = authSession
        current = attempt
        if !authSession.start() {
            session = nil
            current = nil
            fireOpenFailed()
        }
    }

    // MARK: - 완료

    private func complete(attemptId: Int, callbackURL: URL?, error: Error?) {
        guard let attempt = current, attempt.id == attemptId else { return }   // 지난 시도의 완료 — 버린다
        current = nil
        session = nil
        anchorWindow = nil
        if let url = callbackURL {
            if Self.isCallbackFor(attempt, url) {
                route(url)
            } else {
                route(Self.failureURL(attempt, code: Self.invalidCode, message: Self.invalidMessage))
            }
            return
        }
        if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
            route(Self.failureURL(attempt, code: Self.cancelledCode, message: Self.cancelledMessage))
        } else {
            route(Self.failureURL(attempt, code: Self.failedCode, message: Self.failedMessage))
        }
    }

    /// 다리 페이지가 이 시도에 대해 보낸 복귀인가 — connecttrip://app-return<이 시도의 경로>?…flow=identity&state=<이 시도>
    /// JS appReturnTarget 과 같은 기준: 스킴은 대소문자 무시(URL 이 소문자로 바꾼다), 호스트는 비특수 스킴이라 대소문자 그대로 비교,
    /// 경로는 이 시도의 허용 경로와 같아야 한다(아니면 JS 가 버려 화면이 멈추므로 여기서 실패 복귀로 바꾼다 — codex 구현 검토).
    static func isCallbackFor(_ attempt: Attempt, _ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callbackScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedHost == callbackHost,
              // 인코딩된 그대로 비교 — JS(new URL().pathname, 비특수 스킴)도 풀지 않고 허용 경로와 맞춘다('/%66ind-id' 는 둘 다 거절, codex 재확인)
              components.percentEncodedPath == attempt.to else { return false }
        let params = formDecode(components.percentEncodedQuery ?? url.query ?? "")
        let flow = params.first { $0.0 == "flow" }?.1
        let state = params.first { $0.0 == "state" }?.1
        return flow == identityFlow && state == attempt.state
    }

    /// 실제 딥링크와 같은 길(Capacitor App 플러그인 appUrlOpen → AppReturnBridge.jsx)로 넘긴다.
    /// 다음 실행 차례로 미룬다 — WebView 이동 결정(shouldOverrideLoad) 도중에 JS 이벤트를 끼워 넣지 않게(agy 구현 검토).
    private func route(_ url: URL?) {
        guard let url = url else { return }
        DispatchQueue.main.async {
            _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: url, options: [:])
        }
    }

    private func fireOpenFailed() {
        bridge?.triggerWindowJSEvent(eventName: Self.openFailedEvent, data: "{}")
    }

    // MARK: - 실패 복귀 주소 (identity.js appBridgeUrl → app-return.html 이 만드는 딥링크와 같은 모양)

    /// connecttrip://app-return<to>?<q 에서 복귀 파라미터를 뺀 것>&flow=identity&state=…&code=…&message=…
    static func failureURL(_ attempt: Attempt, code: String, message: String) -> URL? {
        var pairs = attempt.query.filter { !returnParams.contains($0.0) }
        pairs.append(("flow", identityFlow))
        pairs.append(("state", attempt.state))
        pairs.append(("code", code))
        pairs.append(("message", message))
        let path = formEncodePath(attempt.to)
        return URL(string: "\(callbackScheme)://\(callbackHost)\(path)?\(formEncode(pairs))")
    }

    // MARK: - application/x-www-form-urlencoded (JS URLSearchParams 와 같은 규칙)

    static func formDecode(_ query: String) -> [(String, String)] {
        guard !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (s: Substring) -> String in percentDecode(s.replacingOccurrences(of: "+", with: " ")) }
            return (decode(kv[0]), kv.count > 1 ? decode(kv[1]) : "")
        }
    }

    /// WHATWG percent-decode + UTF-8 decode(URLSearchParams 와 같음): 올바른 %HH 만 바이트로 풀고 깨진 % 는 그대로 두며,
    /// 잘못된 UTF-8 은 U+FFFD 로 바꾼다(codex 구현 검토 — removingPercentEncoding 은 하나라도 깨지면 통째로 실패한다).
    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x41...0x46: return c - 0x41 + 10
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }

    /// appReturn.js APP_RETURN_PATH_RE 와 같은 허용 경로(src/lib/authSessionContract.test.js 가 원문 대조)
    static let returnPathPattern = "^/(find-id|forgot-password|signup(/[a-z-]+)?|mypage|points)$"
    private static let returnPathRegex = try? NSRegularExpression(pattern: returnPathPattern)

    static func isReturnPath(_ path: String) -> Bool {
        guard let regex = returnPathRegex else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// 영숫자와 * - . _ 만 그대로, 공백은 %20(JS 는 + 와 %20 을 모두 공백으로 읽는다), 나머지는 UTF-8 퍼센트 인코딩
    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formComponent($0.0))=\(formComponent($0.1))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")

    static func formComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// 경로는 '/' 를 남기고 나머지는 같은 규칙으로 — JS 쪽 appReturnTarget 이 허용 경로만 받는다
    static func formEncodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { formComponent(String($0)) }.joined(separator: "/")
    }

    static func isState(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    // MARK: - 표시 위치

    private func presentationWindow() -> UIWindow? {
        if let window = bridge?.viewController?.view.window { return window }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    /// 시작할 때 정해 둔 창. 그 사이 사라졌으면 지금 창, 그것도 없으면 빈 앵커 — 이때 세션은 presentationContextInvalid 로
    /// 끝나고(Apple 문서의 오류 값) 실패 복귀로 이어진다. 시작 전에 창이 없으면 아예 시작하지 않으므로 사실상 닿지 않는 경로다.
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow ?? presentationWindow() ?? ASPresentationAnchor()
    }
}
