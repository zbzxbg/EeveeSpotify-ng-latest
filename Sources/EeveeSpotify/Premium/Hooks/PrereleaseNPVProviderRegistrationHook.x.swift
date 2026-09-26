import Foundation
import Orion

/// 把「正在播放页的预热卡 provider」**拦在注册那一步**（2026-09-26，日志 13 之后）。
///
/// ── 为什么落到这个方法 ───────────────────────────────────────────────────────
///
/// 日志 13 的探针（`PrereleaseCardProbe`）给了两条硬结果：
///
///   1. **卡是真的**，而且在视图树里被当场抓到：
///      `_TtCOOO17Prerelease_ECMKit24PrereleaseCardNowPlaying2UI7Private9MediaView`
///      挂在 `Element_List.CollectionViewCell` 里，文本 = `即将发布 / 发布时间：2025年4月3日`；
///   2. **那一族类在 ObjC runtime 里**（有方法表），其中：
///      ```
///      …NowPlayingViewProviderServiceImpl          objcMethods=3
///        · registerScrollProviderIn:               ← ★ 这个方法就是入口
///      …PrereleaseDataLoaderServiceImpl            objcMethods=6
///      ```
///
/// 而此前所有"绕"的路都失败了，理由都很具体：
///
///   · **剥元素 `12`** —— 日志 13 的 `Detour` 恰恰**有** `12`，所以这一支只杀正版、杀不掉
///     用户实际看到的那张（§40 之后又反过来一次，别再来回改）；
///   · **flag `ios-prerelease-nowplayingviewprovider-impl.is_enabled`** —— 用户开关
///     **开着**（`[INIT] npv prerelease provider: FORCED OFF`）却照样出卡 ⇒ 这条 flag
///     不是闸。它现在只是"我们试过并否掉"的记录，替换本身已从 `propertyReplacements` 移除；
///   · **旁路三接口 / 网络层** —— 十一份日志零命中；
///   · **事后摘视图** —— 能做但丑，而且卡会在屏幕上闪一下。
///
/// 所以改在**注册这一步**拒绝：provider 不注册 ⇒ 这一格元素永远没有内容 ⇒ 卡不存在。
/// 这比摘视图干净，也比改 flag 有依据（方法名是从类元数据里读出来的）。
///
/// ── 安全边界 ───────────────────────────────────────────────────────────────
///
/// · 只有设置里打开「屏蔽过期的『即将发布』卡」时才 `return`（不调 `orig`）；
///   默认关闭时**逐字节保持原行为** —— 每次都原样调用 `orig.registerScrollProviderIn:`；
/// · 只挂这一个类，不做通配；`registerScrollProviderIn:` 在二进制里确认存在；
/// · 每一对 `(feature, provider 类名)` 只打一行日志，方便确认"这一族到底叫什么"。
///
/// ── 日志怎么读（一次复现就能定性）─────────────────────────────────────────────
///
/// ```
/// [PrerelHook] hook fired — first call                  ← 钩子挂上了
/// [PrerelHook] register feature=… provider=… — switch=ON(decline)
/// [PrerelHook] DECLINED registration (switch ON) feature=…
/// ```
///
/// · **只有 `hook fired` 没有 `register`** ⇒ 这条路不是 NPV 预热卡的入口，
///   要去 `PrereleaseDataLoaderServiceImpl` 那几个方法上再找（探针已经列过它们的名字）；
/// · **有 `DECLINED` 而卡还在** ⇒ 说明卡不是这个 provider 注册出来的，同上换下一个落点；
/// · **有 `DECLINED` 且卡没了** ⇒ 收工，这条就是修复。
class PrereleaseNPVProviderRegistrationHook: ClassHook<NSObject> {
    // 与歌词那批同一个组：9.1.x 分支下确定会被激活（`BaseLyricsGroup`）。
    // 这张卡和歌词没有语义关系，但组的激活时机是我们唯一能保证"9.1.x 上真的挂上"的锚点。
    typealias Group = BaseLyricsGroup
    static let targetName = "Prerelease_NowPlayingViewProviderImpl.NowPlayingViewProviderServiceImpl"

    /// 钩子有没有真的被调用过（用来区分"没挂上"与"没这条注册"）。
    private static var didFire = false
    /// 已经报过的 `(feature|provider)` 与 `(declined|feature)` 组合（同一 feature 会被注册多次）。
    private static var reportedKeys = Set<String>()
    /// 注册可能在任意线程发生（DI 容器），静态状态一律加锁 —— 与
    /// `NowPlayingPlatformSwiftServiceImplementationHook` 里那个计数器的处理方式一致。
    private static let reportLock = NSLock()

    private static func shouldReport(_ key: String) -> Bool {
        reportLock.lock()
        defer { reportLock.unlock() }
        return reportedKeys.insert(key).inserted
    }

    private static func markFired() -> Bool {
        reportLock.lock()
        defer { reportLock.unlock() }
        guard !didFire else { return false }
        didFire = true
        return true
    }

    func registerScrollProviderIn(_ feature: NSString) {
        let featureName = feature as String

        if Self.markFired() {
            writeDebugLog("[PrerelHook] hook fired — first call")
        }

        let providerName = NSStringFromClass(type(of: target))
        let switchOn = NgzhwmSettingsViewModel.isNowPlayingPrereleaseProviderDisabled

        if Self.shouldReport("\(featureName)|\(providerName)") {
            writeDebugLog(
                "[PrerelHook] register feature=\(featureName) provider=\(providerName)"
                    + " — switch=\(switchOn ? "ON(decline)" : "off(pass)")"
            )
        }

        if switchOn {
            // ⚠️ 不调 `orig` —— 这一条注册被吞掉，provider 不会进入正在播放页那一排。
            if Self.shouldReport("declined|\(featureName)") {
                writeDebugLog("[PrerelHook] DECLINED registration (switch ON) feature=\(featureName)")
            }
            return
        }

        orig.registerScrollProviderIn(feature)
    }
}
