import UIKit
import Orion

class LyricsOnlyViewControllerHook: ClassHook<UIViewController> {
    // `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 在 9.1.x 上不存在
    // （真机日志 targetNotFound）→ 隔离组，永不激活。
    // 该 hook 目前是空实现（已移除回退原因/罗马音标记的附加代码），隔离没有功能损失。
    typealias Group = V91UnavailableLyricsGroup

    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.LyricsOnlyViewController"
        default: return "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"
        }
    }

    func viewDidLoad() {
        orig.viewDidLoad()
        // 已移除回退原因和罗马音标记的附加代码
        // 现在只保留原始歌词显示，无任何修改
    }
}