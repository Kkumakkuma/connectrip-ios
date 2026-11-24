import UIKit
import Capacitor

/// 웹 화면(WKWebView)을 상태바·다이내믹 아일랜드·홈 인디케이터를 뺀 안전 영역 안에만 놓는다 (2026-10-08).
///
/// 안드로이드 MainActivity.applyBars(시스템 바 높이만큼 패딩)와 같은 방식이다. 웹 CSS 는 안전 영역을 거의 모르고
/// (상단 고정 흰 헤더가 top:0), ios.contentInset 은 스크롤 내용에만 먹고 position:fixed 헤더에는 먹지 않아
/// 헤더가 상태바·다이내믹 아일랜드 밑으로 들어갔다(iPhone 17 Pro 시뮬레이터 실측).
/// CAPBridgeViewController.loadView 는 final 이고 웹뷰가 곧 루트 뷰라 웹뷰 크기를 줄일 수 없어서,
/// 브리지 화면을 이 화면의 자식으로 넣고 안전 영역에 붙인다. 바깥 여백은 흰색(헤더·상태바 글자색과 맞춤).
/// Main.storyboard 의 시작 화면이 이 클래스다.
class SafeAreaHostViewController: UIViewController {

    // AppBridgeViewController = CAPBridgeViewController + 앱 안 플러그인 등록(AuthSessionPlugin, 2026-10-14)
    private let bridgeViewController = AppBridgeViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        addChild(bridgeViewController)
        guard let webArea = bridgeViewController.view else { return }
        webArea.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webArea)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webArea.topAnchor.constraint(equalTo: safe.topAnchor),
            webArea.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            webArea.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webArea.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        ])
        bridgeViewController.didMove(toParent: self)
    }

    // 상태바 모양·숨김·화면 방향은 브리지 화면(capacitor.config 설정)을 따른다
    override var childForStatusBarStyle: UIViewController? {
        return bridgeViewController
    }

    override var childForStatusBarHidden: UIViewController? {
        return bridgeViewController
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return bridgeViewController.supportedInterfaceOrientations
    }
}
