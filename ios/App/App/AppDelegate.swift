import UIKit
import Capacitor
import FirebaseCore
import FirebaseMessaging

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, MessagingDelegate {

    var window: UIWindow?

    // 앱 푸시(iOS, 2026-10-14): 우리 발송기(Supabase push-send)는 FCM HTTP v1 이라 기기 토큰도 FCM 토큰이어야 한다.
    // @capacitor/push-notifications 는 iOS 에서 APNs 기기 토큰(16진 문자열)을 주므로, 여기서 APNs 토큰을 Firebase 에 넘기고
    // 받은 FCM 토큰을 같은 알림(.capacitorDidRegisterForRemoteNotifications)에 문자열로 실어 플러그인에 넘긴다
    // (플러그인은 문자열이면 그대로 'registration' 이벤트로 보낸다 — PushNotificationsPlugin.swift 8.x).
    // 안드로이드와 같은 플러그인·같은 JS(src/lib/push.js)를 쓰고 알림 처리(탭·포그라운드)는 플러그인 하나만 맡는다 — 중복 알림 없음.
    //
    // GoogleService-Info.plist 는 저장소에 두지 않는다(공개 금지). CI 가 비밀값(FIREBASE_IOS_PLIST_B64)이 있을 때만 넣고,
    // 없으면 Firebase 를 아예 켜지 않는다 — 그 빌드는 JS 쪽 푸시도 꺼져(VITE_PUSH_ENABLED=false) 등록을 부르지 않는다.
    // 혹시 불러도 APNs 토큰을 FCM 토큰인 것처럼 넘기지 않고 실패 이벤트로 끝낸다(발송기가 잘못된 토큰을 붙잡지 않게).
    private var firebaseReady = false
    // 이번 실행에서 앱(JS)이 등록을 요청해 APNs 토큰을 Firebase 에 넘겼는가. 그 전에 Firebase 가 스스로 알려 주는 토큰은
    // 앱이 등록을 원하기 전(로그아웃 상태 등)이라 넘기지 않는다.
    private var apnsTokenSet = false
    private var lastForwardedToken: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
            firebaseReady = true
        }
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    // PushNotifications.register() → APNs 등록 성공. Firebase 메서드 스위즐링은 Info.plist 에서 껐으므로
    // (FirebaseAppDelegateProxyEnabled=false — 플러그인의 알림 처리와 섞이지 않게) APNs 토큰을 직접 넘긴다.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard firebaseReady else {
            postRegistrationFailure(PushSetupError.firebaseNotConfigured)
            return
        }
        Messaging.messaging().apnsToken = deviceToken
        apnsTokenSet = true
        Messaging.messaging().token { [weak self] token, error in
            guard let self = self else { return }
            if let token = token, !token.isEmpty {
                self.forward(token)
            } else {
                self.postRegistrationFailure(error ?? PushSetupError.noToken)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        postRegistrationFailure(error)
    }

    // FCM 토큰이 바뀌면(갱신) 같은 'registration' 이벤트로 알린다 — src/lib/push.js listenTokenRefresh 가 로그인 중에만 받아 서버에 올린다.
    // 앱이 등록을 요청하기 전이거나 방금 넘긴 토큰과 같으면 보내지 않는다(같은 토큰을 두 번 보내지 않게).
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard apnsTokenSet, let token = fcmToken, !token.isEmpty, token != lastForwardedToken else { return }
        forward(token)
    }

    private func forward(_ token: String) {
        DispatchQueue.main.async {
            self.lastForwardedToken = token
            NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: token)
        }
    }

    private func postRegistrationFailure(_ error: Error) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        }
    }

    // UIScene 전환(2026-10-27, Capacitor 8.5.3 공식 마이그레이션이 넣은 그대로). 이름이 Info.plist 장면 설정과 같아
    // 첫 화면은 그 설정의 스토리보드(Main)로 만들어진다 — SceneDelegate.swift 참고.
    // 장면 방식에서는 위 application(_:open:)·continue userActivity 를 UIKit 이 부르지 않는다(링크는 SceneDelegate 가 받는다).
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

enum PushSetupError: LocalizedError {
    case firebaseNotConfigured
    case noToken

    var errorDescription: String? {
        switch self {
        case .firebaseNotConfigured:
            return "push-not-configured"
        case .noToken:
            return "fcm-token-unavailable"
        }
    }
}
