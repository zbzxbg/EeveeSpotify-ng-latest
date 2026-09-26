import Foundation
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
/// （日志 13/14 里 `card: NOT resolvable`），所以改用 `objc_copyClassList` 把真实名字捞出来。
///
/// ── ⚠️ 上一版把 App 打崩了，这一版为什么安全 ────────────────────────────────
///
/// 崩溃报告 `Spotify-2026-09-27-014242.ips`（**启动即崩**，主线程）：
///
/// ```
/// EXC_BREAKPOINT / SIGTRAP
/// ___forwarding___.cold.4 → ___forwarding___ → _CF_forwarding_prep_0
///   → swift_getObjectType → tryCast(…)
/// 寄存器里：objc-selector "class" / "__NSGenericDeallocHandler"
/// ```
///
/// 原因：上一版写了 `let cls: AnyClass = classList[index]`。从 `objc_copyClassList`
/// 取出来的"类对象"里混着 `__NSGenericDeallocHandler` 这类**运行时内部垃圾**，
/// Swift 在把它当**元类型**用时会对它做 `swift_getObjectType` → 对该对象发 `class`
/// → 走 `___forwarding___` → 直接 `brk 1`。
///
/// ⇒ 这一版三条硬规矩：
///   1. **不把类对象当 Swift 类型用**：只用 `class_getName` / `class_copyMethodList` /
///      `method_getName` 这些 C 层 API，参数就是 `AnyClass?`；
///   2. **不用 `NSStringFromClass`**（它内部同样会碰元类型），类名一律 `class_getName` +
///      `String(cString:)`；
///   3. 整套枚举包在 `autoreleasepool` 里，并且**任何一个环节拿不到信息就跳过**（绝不强解包）。
///
/// ⚠️ 除此之外仍然是**只读**：只枚举、只打日志，不注册 hook、不改任何行为。
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

        writeDebugLog("[PrerelClasses] enumeration — start (objc-c only)")

        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else {
            writeDebugLog("[PrerelClasses] objc_copyClassList returned nil")
            return
        }
        defer { free(UnsafeMutableRawPointer(classList)) }

        let total = min(Int(count), classLimit)
        var reported = 0
        var truncated = 0

        for index in 0..<total {
            autoreleasepool {
                let cls: AnyClass? = classList[index]
                guard let name = className(of: cls) else { return }
                let lower = name.lowercased()
                guard needles.contains(where: { lower.contains($0) }) else { return }

                reported += 1
                let methods = methodNames(of: cls)
                writeDebugLog("[PrerelClasses] \(name) objcMethods=\(methods.count)")

                if methods.count > methodLimit {
                    truncated += 1
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
        }

        writeDebugLog(
            "[PrerelClasses] enumeration — done: scanned=\(total)/\(count)"
                + " reported=\(reported) truncatedMethodLists=\(truncated)"
        )
    }

    /// 类名 —— 只走 `class_getName`（C 层），不碰 `NSStringFromClass` / 元类型。
    private static func className(of cls: AnyClass?) -> String? {
        guard let cls, let raw = class_getName(cls) else { return nil }
        let name = String(cString: raw)
        return name.isEmpty ? nil : name
    }

    /// 实例方法 + 类方法（属性 getter/setter 也在实例方法表里）。
    private static func methodNames(of cls: AnyClass?) -> [String] {
        guard let cls else { return [] }
        var names: [String] = []

        var instanceCount: UInt32 = 0
        if let list = class_copyMethodList(cls, &instanceCount) {
            for index in 0..<Int(instanceCount) {
                let selector = method_getName(list[index])
                if let raw = sel_getName(selector) {
                    names.append(String(cString: raw))
                }
            }
            free(list)
        }

        // 类方法：元类同样只用 C 层 API 取（`object_getClass` 返回 `AnyClass?`）。
        if let meta = object_getClass(cls) {
            var classCount: UInt32 = 0
            if let metaList = class_copyMethodList(meta, &classCount) {
                for index in 0..<Int(classCount) {
                    let selector = method_getName(metaList[index])
                    if let raw = sel_getName(selector) {
                        names.append("class " + String(cString: raw))
                    }
                }
                free(metaList)
            }
        }

        return names.sorted()
    }
}
