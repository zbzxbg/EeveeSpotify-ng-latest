import Orion
import UIKit

var statefulPlayer: StatefulPlayerImplementation?
var backgroundViewModel: SPTNowPlayingBackgroundViewModel?
var scrollDataSource: NowPlayingScrollDataSourceImplementation?

var nowPlayingScrollViewController: NowPlayingScrollViewController?
var npvScrollViewController: NPVScrollViewController?

// `provideStatefulPlayerWithFeatureIdentifier:` 是 Spotify DI 的工厂方法：
// **每个消费者各自解析一次**，一次打开全屏歌词页会构造几十个组件（ElementFactory /
// ViewBinder / EffectHandler…），于是同一 feature 会在一瞬间刷出二三十条相同日志。
// 这里按 feature 记数：每个 id 只记前 3 条，第 4 条提示一次后静音。
// 加锁是因为该 hook 可能在任意线程被调用。
private var statefulPlayerLogCounts: [String: Int] = [:]
private let statefulPlayerLogLock = NSLock()

private func logStatefulPlayerResolution(_ identifier: NSString) {
    let key = identifier as String
    statefulPlayerLogLock.lock()
    let count = (statefulPlayerLogCounts[key] ?? 0) + 1
    statefulPlayerLogCounts[key] = count
    statefulPlayerLogLock.unlock()

    if count <= 3 {
        writeDebugLog("[Lyrics] statefulPlayer resolved (feature: \(key)) [#\(count)]")
    } else if count == 4 {
        writeDebugLog("[Lyrics] statefulPlayer resolved (feature: \(key)) — 同一 feature 后续不再记录")
    }
}

class LegacyNowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    // 原来挂在 IOS14PremiumPatchingGroup 上，而 9.1.x 分支只激活 PremiumBootstrapGroup，
    // 结果 `statefulPlayer` 在 9.1.x 上永远抓不到（真机日志里没有
    // "[Lyrics] statefulPlayer resolved"）。逐词歌词的播放进度、以及歌词需要的曲目元数据
    // 都依赖它，所以改挂到歌词启用时必定激活的 BaseLyricsGroup。
    // 目标类/方法在 9.1.x 上均存在（已核对二进制）。
    typealias Group = BaseLyricsGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayer() -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayer()
        logStatefulPlayerResolution("legacy" as NSString)
        return statefulPlayer!
    }
}

class NowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    // 同上：改挂 BaseLyricsGroup，保证 9.1.x 上也能拿到 statefulPlayer。
    typealias Group = BaseLyricsGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayerWithFeatureIdentifier(_ identifier: NSString) -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayerWithFeatureIdentifier(identifier)
        logStatefulPlayerResolution(identifier)
        return statefulPlayer!
    }
}

class NowPlayingScrollPrivateServiceImplementationHook: ClassHook<NSObject> {
    // 类还在，但 `provideScrollViewControllerWithDependencies:` 已被 9.1.x 移除
    // （真机日志：Failed to hook method）→ 隔离组，永不激活。
    // 9.1.x 上 `nowPlayingScrollViewController` / `scrollDataSource` 因此恒为 nil，
    // 依赖它们的路径都已有 nil 兜底。
    typealias Group = V91UnavailableLyricsGroup
    static let targetName = "NowPlaying_ScrollImpl.NowPlayingScrollPrivateServiceImplementation"
    
    func provideScrollViewControllerWithDependencies(_ dependencies: NSObject) -> UIViewController {
        let scrollViewController = orig.provideScrollViewControllerWithDependencies(dependencies)
        
        if NSStringFromClass(type(of: scrollViewController)) ~= "NowPlayingScrollViewController" {
            nowPlayingScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NowPlayingScrollViewController.self
            )
            writeDebugLog("[Lyrics] Captured NowPlayingScrollViewController")
        }
        else {
            scrollDataSource = Ivars<NowPlayingScrollDataSourceImplementation>(target)
                .$__lazy_storage_$_scrollDataSource
            npvScrollViewController = Dynamic.convert(
                scrollViewController,
                to: NPVScrollViewController.self
            )
            writeDebugLog("[Lyrics] Captured NPVScrollViewController + scrollDataSource")
        }
        
        backgroundViewModel = Ivars<SPTNowPlayingBackgroundViewModel>(dependencies)
            .backgroundViewModel
        
        return scrollViewController
    }
}
