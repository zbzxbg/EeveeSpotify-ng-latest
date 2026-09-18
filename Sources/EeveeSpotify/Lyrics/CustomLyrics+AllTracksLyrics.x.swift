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
///
/// ⚠️ 查找**不是一次性的**：宿主在 `viewWillAppear` 那一刻往往还不存在（卡片要等歌词），
/// 而且它是自适应表格 cell、会被复用重建。所以这里配了一个 1.5s 的看门狗
/// （见 `startWatchdog`），只要"内嵌层没挂上/挂了但不在窗口里"就再查一次 ——
/// 这是让预览里的逐词歌词"总能挂上、掉了还能自己回来"的关键。
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
        Watchdog.shared.root = root
        // 让布局先跑一拍，VC 层级与视图都在位了再找。
        DispatchQueue.main.async { lookup(from: root) }
        startWatchdog()
    }

    /// NPV 页面消失时调用：停掉看门狗（页面都不在了，再查也没有意义）。
    static func stopLookup() {
        Watchdog.shared.timer?.cancel()
        Watchdog.shared.timer = nil
        Watchdog.shared.root = nil
    }

    /// 让看门狗**立刻**再查一次。
    ///
    /// 两个调用点：逐词歌词刚到达（`WordByWordHost.refreshForCurrentLyrics`），
    /// 以及关闭全屏回到内嵌时（`WordByWordHost.reattachToInline` 找不到宿主）。
    /// 这两刻正是"卡片刚刚出现/重建"的时刻，等下一个 1.5s 心跳就慢了。
    static func retryLookupIfNeeded() {
        tick()
    }

    // MARK: 看门狗

    /// 看门狗状态。
    ///
    /// 放在一个小类里而不是文件级 `weak var`：类型属性不能标 `weak`，
    /// 而强引用会把正在播放页的 VC 一直留住。
    private final class Watchdog {
        static let shared = Watchdog()
        weak var root: UIViewController?
        var timer: DispatchSourceTimer?
    }

    /// 为什么要**定时重查**而不是只查一次：
    ///   1. 卡片是歌词到了才建的 —— `NPVScrollViewController.viewWillAppear`
    ///      那一拍它还不存在（这正是"预览逐词几乎不挂载"的第一成因）；
    ///   2. 卡片里的歌词是**自适应高度的表格 cell**（`Lyrics_TextElementImpl.LyricsCell`
    ///      + `SelfSizingTableView`），换行、滚动、换歌都会把它复用重建，
    ///      我们挂在它上面的层跟着一起消失（第二成因）；
    ///   3. 逐词数据、开关状态都可能晚于宿主出现。
    /// 三条在真机上都表现为"预览里的逐词歌词时有时无"，只有持续盯着才能自愈。
    private static func startWatchdog() {
        guard Watchdog.shared.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(1500),
            repeating: .milliseconds(1500),
            leeway: .milliseconds(300)
        )
        timer.setEventHandler { tick() }
        Watchdog.shared.timer = timer
        timer.resume()
        writeDebugLog("[WordByWord] inline host watchdog started")
    }

    private static func tick() {
        onMainThreadSync {
            // 先做便宜的判据，最后才去找宿主（找宿主可能要遍历整棵视图树）。
            guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
            // 没有**可用的词级数据**时查了也挂不上（`attach` 会直接返回）——
            // 这条判据与 `attach` 用的是同一个函数，省掉一次白遍历。
            guard hasUsableWordLevelData(currentLyricsDto) else { return }
            // ⚠️ 全屏层正挂在屏上时**绝不**重挂预览层 —— 那会把全屏的层拽回卡片。
            guard !WordByWordHost.shared.fullscreenOverlayIsAttached else { return }
            // 已经挂上、而且还在窗口里 → 什么都不用做（这是常态，开销只有几次判空）。
            guard !WordByWordHost.shared.inlineOverlayIsLive else { return }
            // 页面不在窗口里（正在播放页被关掉 / 还没上来）→ 这一轮什么都不做。
            // 没有这道闸门时，宿主查找会在离屏的视图树上"成功地"挂上一层，
            // 然后每 1.5s 重挂一次 —— 白耗电，而且会污染 `lastPreviewContentView`。
            guard let root = resolvedRoot(), root.isViewLoaded, root.view.window != nil else {
                return
            }
            lookup(from: root)
        }
    }

    /// 正在播放页的 VC。
    ///
    /// 正常情况下由 `NPVScrollViewControllerHook.viewWillAppear` 记进来；
    /// 这里补一条**按类名在窗口里找**的兜底，覆盖"hook 没赶上"的场景：
    /// 例如功能是在已经进入正在播放页之后才打开的、或那一次 `viewWillAppear`
    /// 发生在 tweak 初始化之前。找不到就返回 nil（什么都不做，不崩）。
    private static func resolvedRoot() -> UIViewController? {
        if let root = Watchdog.shared.root { return root }
        guard let rootViewController = keyWindow?.rootViewController else { return nil }

        var queue: [UIViewController] = [rootViewController]
        var visited = 0
        while !queue.isEmpty && visited < 128 {
            let vc = queue.removeFirst()
            visited += 1
            if nowPlayingPageClassNames.contains(NSStringFromClass(type(of: vc))) {
                Watchdog.shared.root = vc
                writeDebugLog("[WordByWord] NPV page located by class name (hook missed it)")
                return vc
            }
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    /// 正在播放页 VC 的类名（与 `NPVScrollViewControllerHook.targetName` 同一个）。
    private static let nowPlayingPageClassNames: Set<String> = [
        "NowPlaying_ScrollImpl.NPVScrollViewController",
    ]

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func lookup(from root: UIViewController) {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
        guard let match = findHost(from: root) else {
            logThrottled("[WordByWord] inline host not found (9.1.x candidates absent)")
            return
        }

        logThrottled(
            "[WordByWord] inline host found: \(NSStringFromClass(type(of: match.contentView)))"
            + " in \(NSStringFromClass(type(of: match.controller)))"
        )
        // 挂上了就把看门狗起来：卡片的 cell 一旦被复用重建，我们那层会跟着消失，
        // 只有持续盯着才能自己挂回来。这里也顺手覆盖"hook 没赶上"的场景
        // （那种情况下 `scheduleLookup` 没被调用过，还没有看门狗）。
        startWatchdog()
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

    /// 宿主查找的日志节流。
    ///
    /// 看门狗每 1.5s 走一次这条路，不节流的话「没找到」会一直往日志文件里写
    /// （`writeDebugLog` 是真的写文件，还会走统一日志）—— 查不到宿主时反而把电池吃光。
    /// 同一条消息 5s 内只记一次；消息变了立刻记（状态变化要看得见）。
    private static var lastLookupLogMessage: String?
    private static var lastLookupLogTime: Date = .distantPast

    private static func logThrottled(_ message: String) {
        let now = Date()
        if lastLookupLogMessage == message, now.timeIntervalSince(lastLookupLogTime) < 5 {
            return
        }
        lastLookupLogMessage = message
        lastLookupLogTime = now
        writeDebugLog(message)
    }

    private struct HostMatch {
        let controller: UIViewController
        let contentView: UIView
    }

    /// 先找 VC 候选（含子 VC 与 present 链）；视图候选命中时返回**该视图本身**
    /// 作为挂载内容视图，而不是它上溯到的 VC 根视图。
    ///
    /// ⚠️ 命中多个时**优先取在窗口里的那个**：视图树里往往同时存在离屏的
    /// 复用 cell 和当前显示的那一份，取错了就会"挂上了一层看不见的层"——
    /// 表现和"根本没挂载"一模一样。
    private static func findHost(from root: UIViewController) -> HostMatch? {
        var queue: [UIViewController] = [root]
        var visited = 0
        var fallback: HostMatch?
        while !queue.isEmpty && visited < 64 {
            let vc = queue.removeFirst()
            visited += 1
            if viewControllerCandidates.contains(NSStringFromClass(type(of: vc))) {
                if vc.view.window != nil { return HostMatch(controller: vc, contentView: vc.view) }
                if fallback == nil { fallback = HostMatch(controller: vc, contentView: vc.view) }
            }
            if let match = viewHost(in: vc.view) { return match }
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return fallback
    }

    private static func viewHost(in root: UIView?) -> HostMatch? {
        guard let root else { return nil }
        var queue: [UIView] = [root]
        var visited = 0
        var fallback: HostMatch?
        while !queue.isEmpty && visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if viewCandidates.contains(NSStringFromClass(type(of: view))) {
                var responder: UIResponder? = view
                while let current = responder {
                    if let vc = current as? UIViewController {
                        let match = HostMatch(controller: vc, contentView: view)
                        // 在窗口里的才算"真的看得见"，离屏的只作为兜底。
                        if view.window != nil { return match }
                        if fallback == nil { fallback = match }
                        break
                    }
                    responder = current.next
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return fallback
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
        // 页面要走了：停掉内嵌宿主看门狗（否则它会对着一个已经离开屏幕的页面一直查）。
        InlineLyricsHostLocator.stopLookup()
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
