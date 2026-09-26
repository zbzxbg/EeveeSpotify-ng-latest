import Foundation
import UIKit
import ObjectiveC.runtime

/// 运行时枚举 `Prerelease*` 这一族的**真实类名与方法**（2026-09-26，照片 13/14 之后）。
///
/// ── 为什么需要它 ───────────────────────────────────────────────────────────
///
/// 到这一步为止，已知的事实是：
///
///   · 假卡是真实存在的 prerel 卡视图
///     （`_TtCOOO17Prerelease_ECMKit24PrereleaseCardNowPlaying2UI7Private9MediaView`），
///     宿主是正在播放页那个 `Element_List` 列表里的一格；
///   · 用户口径：**假卡占的是「探索艺人」那一格的位**（照片 13 下面是"关于艺人"，
///     照片 14 重进后同一位置变回"探索 SWALLOW"）；
///   · 卡的内容 = **当前曲目自己的专辑**（封面、标题都对），但被判成"即将发布"，
///     日期还差 1～7 天；发行日其实早已过去；
///   · **拦 `…NowPlayingViewProviderServiceImpl.registerScrollProviderIn:` 能让它彻底不出现**
///     （日志 14 的 entry #1 是干净对照）—— 说明这条链是对的，但那是"全灭"。
///
/// 要变成"只挡假的"，就必须知道**这一格是在哪里被填进 prerel 内容的**。
/// 而 `PrereleaseCardNowPlaying` 这类名字**用点号/mangled 形式 `NSClassFromString` 都取不到**
/// （日志 13/14 里 `card: NOT resolvable`），所以这里改用
/// **`objc_getClassList` 枚举进程里所有类**，把含关键字的类连同方法表一起打出来。
///
/// 与 `PrereleaseCardProbe.runStartupProbeOnce()` 的区别：那个是"猜名字去 resolve"，
/// 这个是"把真实名字捞出来" —— 后者才能拿到私有嵌套类的真名。
///
/// ⚠️ 全程**只读**：只枚举、只打日志，不注册 hook、不改任何行为。
enum PrereleaseRuntimeClassDump {

    /// 类名里含任一片段就报出来（大小写不敏感）。
    private static let needles = [
        "prerelease",
        "presave",
        "explore",
        "npvcardprovider",
        "nowplayingviewprovider",
    ]

    /// 每个类最多打这么多条方法名（私有巨型类可能上百条）。
    private static let methodLimit = 60
    /// 全局最多枚举这么多类（防止某个异常构建下刷爆日志）。
    private static let classLimit = 60000

    private static var didRun = false

    static func runOnce() {
        guard !didRun else { return }
        didRun = true

        writeDebugLog("[PrerelClasses] enumeration — start")

        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else {
            writeDebugLog("[PrerelClasses] objc_copyClassList returned nil")
            return
        }
        // `objc_copyClassList` 返回的是 `UnsafeMutablePointer<AnyClass>?`（malloc 出来的），
        // 用 raw 指针释放，避免 AnyClass 在本 SDK 上不隐式转 `AnyObject` 的编译坑。
        defer { free(UnsafeMutableRawPointer(classList)) }

        let total = min(Int(count), classLimit)
        var reported = 0
        var suppressedMethodLists = 0

        for index in 0..<total {
            let cls: AnyClass = classList[index]
            let name = NSStringFromClass(cls)
            let lower = name.lowercased()
            guard needles.contains(where: { lower.contains($0) }) else { continue }

            reported += 1
            let methods = objcMethodNames(of: cls)
            writeDebugLog("[PrerelClasses] \(name) objcMethods=\(methods.count)")

            if methods.count > methodLimit {
                suppressedMethodLists += 1
                for method in methods.prefix(methodLimit) {
                    writeDebugLog("[PrerelClasses]   · \(name) :: \(method)")
                }
                writeDebugLog("[PrerelClasses]   · … (\(methods.count - methodLimit) more suppressed)")
            } else {
                for method in methods {
                    writeDebugLog("[PrerelClasses]   · \(name) :: \(method)")
                }
            }
        }

        writeDebugLog(
            "[PrerelClasses] enumeration — done: scanned=\(total)/\(count)"
                + " reported=\(reported) truncatedMethodLists=\(suppressedMethodLists)"
        )
    }

    /// 实例方法 + 类方法（属性 getter/setter 也在实例方法表里）。
    private static func objcMethodNames(of cls: AnyClass) -> [String] {
        var names: [String] = []

        var instanceCount: UInt32 = 0
        if let list = class_copyMethodList(cls, &instanceCount) {
            for index in 0..<Int(instanceCount) {
                names.append(NSStringFromSelector(method_getName(list[index])))
            }
            free(list)
        }

        if let meta = object_getClass(cls) {
            var classCount: UInt32 = 0
            if let metaList = class_copyMethodList(meta, &classCount) {
                for index in 0..<Int(classCount) {
                    names.append("class " + NSStringFromSelector(method_getName(metaList[index])))
                }
                free(metaList)
            }
        }

        return names.sorted()
    }
}
