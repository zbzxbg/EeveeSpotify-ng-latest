import Orion
import UIKit

class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = BaseLyricsGroup
    
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
