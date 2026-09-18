import Orion
import UIKit

class LyricsFullscreenViewControllerHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup
    
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        case .lastAvailableiOS15: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"
        }
    }

    func viewDidLoad() {
        orig.viewDidLoad()
        
        if UserDefaults.lyricsSource == .musixmatch
            && lyricsState.fallbackError == nil
            && !lyricsState.wasRomanized
            && !lyricsState.isEmpty {
            return
        }
        
        writeDebugLog("[Lyrics] Disabling lyrics report button")

        // 9.1.x 的视图结构与 9.1.0 不同：`target.view` 上没有 `headerView` 这个 ivar，
        // Orion 的 Ivars 取不到它时会直接触发 Swift 断言（SIGTRAP）。
        // Reincarnated 在 9.1.x 上已经发现这一点并跳过该段访问；
        // 本次合并把歌词模块整体换成 ng 版时丢掉了这个守卫 —— 表现就是「一打开全屏歌词就崩」。
        if EeveeSpotify.hookTarget == .v91 {
            return
        }

        if EeveeSpotify.hookTarget == .latest {
            guard let fullscreenView = WindowHelper.shared.findFirstSubview(
                "Lyrics_FullscreenElementPageImpl.FullscreenView",
                in: target.view
            ) else {
                return
            }
            
            let controlsView = Ivars<UIView>(fullscreenView).controlsView
            let contextMenuButtonContainer = Ivars<UIView>(controlsView).contextMenuButtonContainer
            
            if let contextButton = contextMenuButtonContainer.subviews(
                matching: "Encore6Button"
            ).first as? UIControl {
                contextButton.isEnabled = false
            }
            
            return
        }
        
        let headerView = Ivars<UIView>(target.view).headerView
        
        if let reportButton = headerView.subviews(matching: "EncoreButton")[1] as? UIButton {
            reportButton.isEnabled = false
        }
    }
}
