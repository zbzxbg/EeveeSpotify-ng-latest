import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = BaseLyricsGroup
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = NgzhwmSettingsViewModel.isLyricsFeatureDisabled ? "false" : "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()
        
        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {
            return uri
        }

        writeDebugLog("[Lyrics] Overriding local track URI → spotify:track:")
        return NSURL(string: "spotify:track:")!
    }
}

class LyricsScrollProviderHook: ClassHook<NSObject> {
    // 9.1.x 上 `Lyrics_NPVCommunicatorImpl.ScrollProvider` 已不存在（真机日志 targetNotFound），
    // 挪进永不激活的隔离组，避免注册期崩掉注入工具。
    typealias Group = V91UnavailableLyricsGroup
    static var targetName = HookTargetNameHelper.lyricsScrollProvider
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return !NgzhwmSettingsViewModel.isLyricsFeatureDisabled
    }
}

/// 内嵌（预览）歌词的逐词宿主查找器。
///
/// 背景：ng 原来靠 `LyricsWordByWordModernHostHook` 直接 hook
/// `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 拿内嵌歌词 VC；
/// 该类在 9.1.x 上已被移除（9.1.76 主二进制类名扫描：整个二进制里都不存在
/// `LyricsOnlyViewController`；真机日志 targetNotFound）。
///
/// 为什么不再「换个 targetName 重新 hook」：Orion 在**注册期**解析不到目标类/方法时
/// 会走错误路径 —— 在 App 里只是一条日志，但在注入工具进程里加载同一个 dylib 时
/// 会直接 SIGTRAP 把工具崩掉（已实测：官方 dylib 能注入、我们的一注入就闪退）。
/// 因此这里**不新增任何 hook**，改为在已经绑定成功的 NPV 宿主里用纯 UIKit 遍历查找；
/// 最坏情况只是「没找到、没效果」，不会引入新的注册期崩溃。
///
/// 候选类名来自 9.1.76 主二进制扫描（`Lyrics_TextElementImpl` /
/// `Lyrics_TextComponentImpl` / `Lyrics_NPVElementsKitImpl` 三个模块）；
/// 真机日志里 statefulPlayer 也会以 `LyricsTextElementService` 特征串被取出，
/// 与「内嵌歌词由这套组件渲染」一致。
enum InlineLyricsHostLocator {
    private static let viewControllerCandidates: [String] = [
        "Lyrics_TextComponentImpl.LyricsViewControllerImplementation",
    ]

    private static let viewCandidates: [String] = [
        "Lyrics_TextElementImpl.LyricsTextElementUI",
        "Lyrics_TextElementImpl.LyricsTextView",
        "Lyrics_TextElementImpl.LyricsLabelsView",
        "Lyrics_NPVElementsKitImpl.LyricsViewElementUI",
    ]

    static func scheduleLookup(from root: UIViewController?) {
        guard let root else { return }
        // 让布局先跑一拍，VC 层级与视图都在位了再找。
        DispatchQueue.main.async { lookup(from: root) }
    }

    private static func lookup(from root: UIViewController) {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
        guard let match = findHost(from: root) else {
            writeDebugLog("[WordByWord] inline host not found (9.1.x candidates absent)")
            return
        }

        writeDebugLog(
            "[WordByWord] inline host found: \(NSStringFromClass(type(of: match.contentView)))"
            + " in \(NSStringFromClass(type(of: match.controller)))"
        )
        onMainThreadSync {
            // 关键：把**命中的歌词视图**作为 contentView 传进去，而不是上溯到的 VC。
            //
            // WordByWordHost.attach 在预览场景（showsProviderFooter == false）会执行
            // `cardContainer(for: contentView)`，把 overlay 铺到「预览歌词卡片」上 ——
            // 那才是「只有歌词那一块逐词、页面其余部分保持原生」的正确挂载点。
            //
            // 之前传的是上溯得到的 NPVScrollViewController，contentView 变成整页根视图，
            // cardContainer 找不到卡片 → 退化成铺满整个正在播放页（就是之前那个现象）。
            WordByWordHost.shared.rememberInlineController(match.controller)
            WordByWordHost.shared.attach(
                to: match.controller,
                contentView: match.contentView,
                showsTranslation: false
            )
        }
    }

    private struct HostMatch {
        let controller: UIViewController
        let contentView: UIView
    }

    /// 先找 VC 候选（含子 VC 与 present 链）；视图候选命中时返回**该视图本身**
    /// 作为挂载内容视图，而不是它上溯到的 VC 根视图。
    private static func findHost(from root: UIViewController) -> HostMatch? {
        var queue: [UIViewController] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 64 {
            let vc = queue.removeFirst()
            visited += 1
            if viewControllerCandidates.contains(NSStringFromClass(type(of: vc))) {
                return HostMatch(controller: vc, contentView: vc.view)
            }
            if let match = viewHost(in: vc.view) { return match }
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    private static func viewHost(in root: UIView?) -> HostMatch? {
        guard let root else { return nil }
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if viewCandidates.contains(NSStringFromClass(type(of: view))) {
                var responder: UIResponder? = view
                while let current = responder {
                    if let vc = current as? UIViewController {
                        return HostMatch(controller: vc, contentView: view)
                    }
                    responder = current.next
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = ModernLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        writeDebugLog("[Lyrics] NPV scroll — enabling local track URI override")
        orig.viewWillAppear(animated)

        // 9.1.x 上内嵌歌词宿主已改名，改为运行时查找（不新增 hook，避免注册期崩溃）。
        InlineLyricsHostLocator.scheduleLookup(from: target as? UIViewController)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
