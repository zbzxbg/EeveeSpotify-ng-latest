import Foundation
import UIKit
import ObjectiveC.runtime

/// 「正在播放页预热卡」的定位探针（2026-09-26，二进制取证之后）。
///
/// ── 要回答的两个问题 ────────────────────────────────────────────────────────
///
/// 解密二进制（`C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa`）里已经
/// 拿到了这一族的明文类名（见 `LYRICS_MODULE_NEXT_STEPS.md` §45）：
///
///   · 卡本体   `Prerelease.UI.PrereleaseCardNowPlaying`（`Prerelease_ECMKit`）
///   · 数据源   `Prerelease_NowPlayingViewProviderImpl.PrereleaseNowPlayingScrollDataProvider`
///   · 服务     `Prerelease_NowPlayingViewProviderImpl.NowPlayingViewProviderServiceImpl`
///   · 数据字段 `releaseTime` / `albumUri` / `prereleaseUri`，以及组件自带的
///              "已发行"一档（`sCountdownReleasedText` / `countdownExpired`）
///
/// 但那几个类**不在 `__objc_classname`** 里（那一节只有孤零零一个 `Prerelease`），
/// 所以"能不能 hook"静态判断不了。`PrereleaseCardNowPlaying` 同时是
/// `Prerelease_ECMKit/PrereleaseCardNowPlayingUI.swift` 里的 UIKit 类型
/// （旁边还有 `…2UI7Private9MediaView` / `…13CountdownView` / `Components.UI.PrereleaseButtonPreSave`），
/// 所以**它多半在视图树里能被找到** —— 这一条不依赖 hook，先把它钉住。
///
/// ── 这个探针做什么 ─────────────────────────────────────────────────────────
///
/// 1. 启动时一次：把候选类名逐个 `NSClassFromString`（同时试 **点号形式**和
///    `_TtC…` **mangled 形式**），命中就顺手 dump 一份该类的 ObjC 方法表 ——
///    有方法表就说明能 hook（Orion 走的就是这条路），没有就说明是纯 Swift 类型；
/// 2. 进正在播放页后 10 秒内每 1s 扫一次视图树：找 class 名里含 `Prerelease`
///    的视图，命中就打一行它属于哪个宿主 + 它的可读文本前缀。
///    这一条是"**卡到底存不存在、是谁**"的直接证据，且**不依赖 hook 成功**。
///
/// ⚠️ 全程只读：不改视图、不注册手势、不修改任何数据。要摘卡是后面的事。
enum PrereleaseCardProbe {

    /// 模块名 + 类名，两种字符串形式都试 —— Swift 反射名与 mangled 名在不同
    /// Spotify 构建上不一定一致，多试一种几乎不花成本。
    /// `P33_…` 那种带私有消歧哈希的嵌套名**故意不写死**：它随构建变化，
    /// 硬编码等于给自己埋一个必然过期的条目。
    private static let classCandidates: [(label: String, names: [String])] = [
        ("card", [
            "Prerelease.UI.PrereleaseCardNowPlaying",
            "Prerelease_ECMKit.PrereleaseCardNowPlaying",
            "_TtCOOO17Prerelease_ECMKit24PrereleaseCardNowPlaying",
        ]),
        ("npv-provider", [
            "Prerelease_NowPlayingViewProviderImpl.PrereleaseNowPlayingScrollDataProvider",
            "_TtC37Prerelease_NowPlayingViewProviderImpl38PrereleaseNowPlayingScrollDataProvider",
        ]),
        ("npv-service", [
            "Prerelease_NowPlayingViewProviderImpl.NowPlayingViewProviderServiceImpl",
            "_TtC37Prerelease_NowPlayingViewProviderImpl33NowPlayingViewProviderServiceImpl",
        ]),
        ("data-loader", [
            "Prerelease_DataLoaderImpl.PrereleaseDataLoaderServiceImpl",
            "_TtC25Prerelease_DataLoaderImpl31PrereleaseDataLoaderServiceImpl",
        ]),
        ("presave-button", [
            "Components.UI.PrereleaseButtonPreSave",
        ]),
    ]

    private static var didRunStartupProbe = false
    private static var didReportCardSighting = false
    private static var sweepTimer: Timer?

    // MARK: - 1) 启动期：类到底在不在、有没有方法表

    static func runStartupProbeOnce() {
        guard !didRunStartupProbe else { return }
        didRunStartupProbe = true

        writeDebugLog("[PrerelProbe] class resolution — start")

        for candidate in classCandidates {
            var resolved: (name: String, cls: AnyClass)?
            for name in candidate.names where NSClassFromString(name) != nil {
                resolved = (name, NSClassFromString(name)!)
                break
            }

            guard let hit = resolved else {
                writeDebugLog("[PrerelProbe] \(candidate.label): NOT resolvable (\(candidate.names.joined(separator: " | ")))")
                continue
            }

            let methodNames = objcMethodNames(of: hit.cls)
            writeDebugLog(
                "[PrerelProbe] \(candidate.label): FOUND \(hit.name)"
                    + " objcMethods=\(methodNames.count)"
            )
            for name in methodNames.prefix(40) {
                writeDebugLog("[PrerelProbe]   · \(hit.name) :: \(name)")
            }
        }

        writeDebugLog("[PrerelProbe] class resolution — done")
    }

    /// 该类的 ObjC 方法表（含属性 getter/setter）。
    ///
    /// 为什么这就能回答"能不能 hook"：Orion 是走 ObjC runtime 解析 target 的，
    /// 一个类只要有 ObjC 方法表，它的方法就能被拦；反过来说，纯 Swift 类型
    /// （`objc_getClass` 找不到）我们碰不到。
    private static func objcMethodNames(of cls: AnyClass) -> [String] {
        var names: [String] = []

        var count: UInt32 = 0
        if let list = class_copyMethodList(cls, &count) {
            for index in 0..<Int(count) {
                let selector = method_getName(list[index])
                names.append(NSStringFromSelector(selector))
            }
            free(list)
        }

        // 静态方法（`class_getClassMethod` 侧）也一并看看，provider 常常是
        // `static func make…` 这种形状。
        if let meta = object_getClass(cls) {
            var metaCount: UInt32 = 0
            if let metaList = class_copyMethodList(meta, &metaCount) {
                for index in 0..<Int(metaCount) {
                    let selector = method_getName(metaList[index])
                    names.append("class " + NSStringFromSelector(selector))
                }
                free(metaList)
            }
        }

        return names.sorted()
    }

    // MARK: - 2) 页面级：卡在视图树里是谁

    /// 进正在播放页时起表：10 秒内每 1s 扫一次，**只报第一次**命中。
    ///
    /// 为什么是轮询而不是"进页面扫一次"：日志 11 已经踩过这个坑 —— 卡是页面起来之后
    /// 才渲染的，快照式 dump 两次都撞在空档/别的页面上。这里只扫 10 秒、只在命中时报一次，
    /// 不会刷屏。
    static func startCardSweep(from host: UIView?) {
        guard let host else { return }
        didReportCardSighting = false
        sweepTimer?.invalidate()

        var ticks = 0
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            ticks += 1
            if ticks > 10 || didReportCardSighting {
                timer.invalidate()
                sweepTimer = nil
                return
            }
            if let found = findPrereleaseView(in: host) {
                didReportCardSighting = true
                let hostChain = viewChain(of: found)
                let texts = visibleTexts(in: found)
                writeDebugLog(
                    "[PrerelProbe] CARD SIGHTED at tick \(ticks)"
                        + " class=\(NSStringFromClass(type(of: found)))"
                        + " frame=\(found.frame)"
                )
                writeDebugLog("[PrerelProbe]   chain=\(hostChain)")
                writeDebugLog("[PrerelProbe]   texts=\(texts.joined(separator: " / "))")
                timer.invalidate()
                sweepTimer = nil
            }
        }
        if let timer = sweepTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        writeDebugLog("[PrerelProbe] card sweep started (10s, 1s ticks)")
    }

    static func stopCardSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// 视图树里第一个"class 名提到 Prerelease/PreSave"的视图。
    private static func findPrereleaseView(in root: UIView) -> UIView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 3000 {
            let view = queue.removeFirst()
            visited += 1

            let name = NSStringFromClass(type(of: view))
            if name.localizedCaseInsensitiveContains("prerelease")
                || name.localizedCaseInsensitiveContains("presave") {
                if view.window != nil {
                    return view
                }
            }

            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func viewChain(of view: UIView) -> String {
        var chain: [String] = []
        var current: UIView? = view
        var depth = 0
        while let node = current, depth < 8 {
            chain.append(NSStringFromClass(type(of: node)))
            current = node.superview
            depth += 1
        }
        return chain.joined(separator: " < ")
    }

    private static func visibleTexts(in root: UIView) -> [String] {
        var out: [String] = []
        func walk(_ view: UIView, depth: Int) {
            guard depth < 6, out.count < 12 else { return }
            if let label = view as? UILabel, let text = label.text, !text.isEmpty {
                out.append(text)
            }
            if let button = view as? UIButton,
               let title = button.title(for: .normal), !title.isEmpty {
                out.append("[btn]\(title)")
            }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return out
    }
}
