import SwiftUI
import UIKit 

class EeveeSettingsViewController: SPTPageViewController {
    let settingsView: AnyView
    private var hasShownSpecialLicense = false
    
    init(_ frame: CGRect, settingsView: AnyView, navigationTitle: String) {
        self.settingsView = settingsView
        super.init(nibName: nil, bundle: nil)
        
        title = navigationTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        
        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Become first responder so we can receive motion events
        becomeFirstResponder()
    }
    
    override var canBecomeFirstResponder: Bool { true }
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        // （已移除：摇一摇触发的 "Special License Detected / Hysan" 彩蛋）
    }
    
    @objc func openRepositoryUrl(_ sender: UIButton) {
        // 设置页右上角那颗「小球」（bundle 里的 `github` 图）：
        // 指向**本仓库**，而不是上游 `jaydenjcpy/EeveeSpotifyReincarnated`。
        //
        // 这里刻意写死而不是用 `EeveeSpotify.repoSlug`：那颗球是"我是谁"的入口，
        // 不该随构建机的 git remote 漂移（改名/换 fork 时容易指到别人仓库）。
        UIApplication.shared.open(URL(string: "https://github.com/zbzxbg/EeveeSpotify-ng-latest")!)
    }
}
