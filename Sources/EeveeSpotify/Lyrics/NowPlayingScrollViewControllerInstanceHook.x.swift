import Orion
import UIKit

var statefulPlayer: StatefulPlayerImplementation?
var backgroundViewModel: SPTNowPlayingBackgroundViewModel?
var scrollDataSource: NowPlayingScrollDataSourceImplementation?

var nowPlayingScrollViewController: NowPlayingScrollViewController?
var npvScrollViewController: NPVScrollViewController?

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
        writeDebugLog("[Lyrics] statefulPlayer resolved (legacy)")
        return statefulPlayer!
    }
}

class NowPlayingPlatformSwiftServiceImplementationHook: ClassHook<NSObject> {
    // 同上：改挂 BaseLyricsGroup，保证 9.1.x 上也能拿到 statefulPlayer。
    typealias Group = BaseLyricsGroup
    static let targetName = "NowPlaying_PlatformImpl.NowPlayingPlatformSwiftServiceImplementation"
    
    func provideStatefulPlayerWithFeatureIdentifier(_ identifier: NSString) -> StatefulPlayerImplementation {
        statefulPlayer = orig.provideStatefulPlayerWithFeatureIdentifier(identifier)
        writeDebugLog("[Lyrics] statefulPlayer resolved (feature: \(identifier))")
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
