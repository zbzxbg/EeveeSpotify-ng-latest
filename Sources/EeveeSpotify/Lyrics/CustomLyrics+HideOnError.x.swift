import Orion
import UIKit

/// 目标类在 Spotify 9.1.x 上已不存在的歌词 hook 的隔离组。
///
/// `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` / `.ScrollProvider` /
/// `.ErrorViewController`、以及 `provideScrollViewControllerWithDependencies:` 这些目标，
/// 已由 9.1.74 主二进制类名/选择器扫描 + 9.1.76 真机日志（`[ORION ERROR] … targetNotFound`）
/// 确认不存在。Orion 在激活组时会去解析目标类，解析失败会走错误路径：
/// 在 App 里表现为一条 `[ORION ERROR]`，但在**注入工具进程**里加载同一个 dylib 时
/// 会直接 SIGTRAP 崩掉工具本身。
///
/// 因此把这些 hook 单独放进来，并且**该组在任何版本上都不激活** ——
/// 组内 hook 的源码保留，等定位到 9.1.x 上的替代类后再逐个迁回可用组。
struct V91UnavailableLyricsGroup: HookGroup { }

class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = V91UnavailableLyricsGroup
    
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.ErrorViewController"
        default: return "Lyrics_NPVCommunicatorImpl.ErrorViewController"
        }
    }
    
    func loadView() {
        orig.loadView()
        
        guard UserDefaults.lyricsOptions.hideOnError else {
            return
        }

        writeDebugLog("[Lyrics] Hide on error — removing lyrics provider")

        if let controller = nowPlayingScrollViewController {
            controller.dataSource.activeProviders.removeAll {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            controller.collectionView().reloadData()
        }
        else if let controller = npvScrollViewController,
                let dataSource = scrollDataSource,
                // Spotify 9.1.74 起 NPVScrollViewController 实例不再向 ObjC 运行时
                // 暴露 collectionView()（实测会 unrecognized selector 崩溃）。
                // 这里先做存在性检查，缺失就整体跳过，绝不裸调。
                (controller as AnyObject).responds(to: Selector("collectionView")) {
            let lyricsProviderIndex = dataSource.activeProviders.firstIndex {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            guard let lyricsProviderIndex else { return }
            
            let collectionView = Dynamic.convert(
                controller as AnyObject,
                to: CollectionViewProviding.self
            ).collectionView()
            let dataSource = Ivars<__UIDiffableDataSource>(collectionView.dataSource!)._impl
            
            let itemIdentifiers = dataSource.itemIdentifiers()
            let lyricsProviderItemIdentifier = itemIdentifiers[lyricsProviderIndex]
            
            dataSource.deleteItemsWithIdentifiers([lyricsProviderItemIdentifier])
        }
    }
}

/// 只用于把 `collectionView()` 从动态对象上安全取出来：调用前必须先 `responds(to:)`。
@objc protocol CollectionViewProviding {
    func collectionView() -> UICollectionView
}
