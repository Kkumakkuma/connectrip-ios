import UIKit
import Capacitor

/// UIScene 수명 주기 (2026-10-27, Capacitor 8.5.3 공식 전환 + 이 앱 구조에 맞춤).
/// iOS 27 SDK(Xcode 27)로 빌드한 앱은 UIScene 이 없으면 아예 뜨지 않는다 — "UIScene life cycle is required for apps built
/// with this SDK"(xcode-27 러너 iOS 27.0 시뮬레이터 5/5 실측).
///
/// 창과 첫 화면은 UIKit 이 Info.plist 의 장면 설정(UISceneStoryboardFile = Main)으로 만든다 — Main.storyboard 의 시작 화면은
/// SafeAreaHostViewController(안전 영역 + AppBridgeViewController 의 앱 안 플러그인 등록)다. Capacitor 공식 템플릿처럼 여기서
/// UIWindow·CAPBridgeViewController 를 직접 만들면 그 둘을 건너뛰므로 만들지 않는다(codex 지적).
/// 여기서는 바깥에서 들어온 링크(connecttrip:// 앱 복귀·유니버설 링크)를 Capacitor 로 넘기기만 한다 — 앱이 꺼져 있다가 링크로
/// 켜진 경우(connectionOptions)는 SceneDelegateProxy 가 첫 화면이 뜬 뒤(플러그인 등록 뒤)에 넘긴다.
/// PASS 본인확인 창이 끝날 때의 복귀(AuthSessionPlugin.route)는 장면과 상관없이 ApplicationDelegateProxy 를 직접 부른다.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
