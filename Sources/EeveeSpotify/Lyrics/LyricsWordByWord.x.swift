import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 逐字歌词渲染模块（MVP）
//
// 结构：
//   WordByWordPositionResolver — 安全多策略定位播放进度（运行时探测，responds/ivar 检查后再读，绝不裸调）
//   WordByWordPlaybackClock   — CADisplayLink 时钟，把进度喂给叠加视图
//   LyricsWordByWordOverlayView — UIKit 叠加视图：逐行 UILabel + 当前词 NSAttributedString 高亮 + 自动滚动
//   WordByWordHost            — 挂载/卸载 overlay（挂在 Spotify 全屏歌词 VC 上）
//
// 前提（来自 Spotify 二进制逆向）：
//   进度候选：playbackPosition(Double)、currentPlaybackTime(Double)、currentTrackTimeSecs(Int64 秒)
//   挂载点：Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController（新版）/ Lyrics_CoreImpl.LyricsOnlyViewController（iOS14）
//   开关：复用 ngzhwm_wordByWordLyrics

var currentLyricsDto: LyricsDto?
var currentLyricsVersion: Int = 0
/// 最终生效的歌词背景色（ARGB），CustomLyrics 算完 colors 后写入，供 overlay 与原生模块同色。
var currentLyricsBackgroundColorARGB: UInt32 = 0
/// 歌词提供者文本（如 "PetitLyrics (EeveeSpotify)"），用于 overlay 底部展示。
var currentLyricsProvider: String = ""

// MARK: - 位置解析

@objc protocol WordByWordPositionDoubleGetter { func playbackPosition() -> Double }
@objc protocol WordByWordCurrentPlaybackTimeDoubleGetter { func currentPlaybackTime() -> Double }
@objc protocol WordByWordCurrentTrackTimeSecsGetter { func currentTrackTimeSecs() -> Int64 }
@objc protocol WordByWordPlayerPositionGetter { func position() -> Double }
@objc protocol WordByWordSeekProtocol { func seekTo(_ seconds: Double) }

final class WordByWordPositionResolver {
    static let shared = WordByWordPositionResolver()

    private var getter: (() -> Double)?
    private(set) var sourceLabel: String = "unresolved"
    private var sampleCount = 0
    private var didLogUnresolved = false

    /// 逐策略探测：先试方法（responds 检查后 Dynamic.convert 调用），再试 ivar（class_getInstanceVariable 检查后读取）。
    /// 任一环节检查不通过就跳过，保证永不因猜错签名崩溃。
    func resolve() {
        // 首选：statefulPlayer.position() —— 已由 runtime dump 确认（d16@0:8 = double 无参，秒）
        if let p = statefulPlayer as? NSObject, p.responds(to: Selector("position")) {
            let g = Dynamic.convert(p, to: WordByWordPlayerPositionGetter.self)
            getter = { g.position() }
            sourceLabel = "statefulPlayer.position() -> Double"
            writeDebugLog("[WordByWord] position source: \(sourceLabel)")
            return
        }

        var candidates: [(String, NSObject)] = []
        if let p = statefulPlayer as? NSObject { candidates.append(("statefulPlayer", p)) }
        if let vc = nowPlayingScrollViewController as? NSObject {
            candidates.append(("scrollVC", vc))
            let vm = Ivars<NSObject>(vc).scrollViewModel
            candidates.append(("scrollViewModel", vm))
        }
        if let npv = npvScrollViewController as? NSObject { candidates.append(("npvVC", npv)) }

        for (label, obj) in candidates {
            if obj.responds(to: Selector("playbackPosition")) {
                let g = Dynamic.convert(obj, to: WordByWordPositionDoubleGetter.self)
                getter = { g.playbackPosition() }
                sourceLabel = "\(label).playbackPosition() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if obj.responds(to: Selector("currentPlaybackTime")) {
                let g = Dynamic.convert(obj, to: WordByWordCurrentPlaybackTimeDoubleGetter.self)
                getter = { g.currentPlaybackTime() }
                sourceLabel = "\(label).currentPlaybackTime() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if let value = ivarInt64(obj, "currentTrackTimeSecs") {
                getter = { Double(value) }
                sourceLabel = "\(label).currentTrackTimeSecs -> Int64(秒)"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
            if let value = ivarDouble(obj, "playbackPosition") {
                getter = { value }
                sourceLabel = "\(label).playbackPosition ivar -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        if !didLogUnresolved {
            didLogUnresolved = true
            writeDebugLog("[WordByWord] no position source resolved — will retry on next tick")
        }
    }

    /// 返回秒（双精度）。源不可用返回 nil。
    /// 启动时候选对象（statefulPlayer/scrollViewModel 等）可能还没就绪，
    /// 未解析成功时每次调用都重试一次，直到命中某个策略。
    func currentPositionSeconds() -> Double? {
        if getter == nil { resolve() }
        guard let getter else { return nil }
        let raw = getter()
        if sampleCount < 5 {
            sampleCount += 1
            writeDebugLog("[WordByWord] pos sample \(sampleCount): \(raw)")
        }
        return raw
    }

    private func ivarInt64(_ obj: NSObject, _ name: String) -> Int64? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Int64.self)
        }
        return nil
    }

    private func ivarDouble(_ obj: NSObject, _ name: String) -> Double? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Double.self)
        }
        return nil
    }
}

// MARK: - 点行跳转

final class WordByWordSeeker {
    static func seek(toMs ms: Int) {
        guard let player = statefulPlayer as? NSObject, player.responds(to: Selector("seekTo:")) else {
            writeDebugLog("[WordByWord] seekTo: unavailable on statefulPlayer")
            return
        }
        let g = Dynamic.convert(player, to: WordByWordSeekProtocol.self)
        g.seekTo(Double(ms) / 1000)
        writeDebugLog("[WordByWord] seek to \(ms)ms")
    }
}

// MARK: - 播放时钟

final class WordByWordPlaybackClock {
    static let shared = WordByWordPlaybackClock()

    private var displayLink: CADisplayLink?
    private(set) var currentMs: Double = 0
    var onChange: ((Double) -> Void)?

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 供 Apple Music 渲染层使用的每帧回调。
    /// 与 `onChange` 互斥：挂载时只会设置其中一个。
    var tickHandler: ((Double) -> Void)?

    @objc private func tick() {
        let ms: Double
        if let seconds = WordByWordPositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        onChange?(ms)
        tickHandler?(ms)
    }
}

// MARK: - 叠加视图

/// 逐字数据是否可用：至少一半的行有「多词」级时间轴（words.count >= 2）。
/// 整行一个词 / 全退化 / 词级时间轴错位 等坏数据会低于阈值，回退原生行级。
///
/// 抽成文件级函数是因为它有**两个**消费者：旧的 UIKit overlay（`setCurrentTime`）
/// 和 Apple Music 渲染层（挂载前判定）。判定口径必须一致。
func hasUsableWordLevelData(_ dto: LyricsDto?) -> Bool {
    guard let dto, dto.timeSynced else { return false }
    let lines = dto.lines
    guard !lines.isEmpty else { return false }
    let wordLevelLines = lines.filter { ($0.words?.count ?? 0) >= 2 }.count
    return wordLevelLines * 10 >= lines.count * 5  // >= 50%
}

/// 逐**行**数据是否可用：时间同步 + 至少一半的行带 `offsetMs`。
///
/// 这是**降级档**的判据：有行级时间轴、但没有逐字时间轴时，我们不再整层撤走，
/// 而是自己按行渲染（当前行整行点亮）。
///
/// ── 为什么必须补这一档（真机日志 11 实证）───────────────────────────────
/// 网易云对一部分歌**根本没有 yrc**（逐字格式），日志里是：
///     `[NetEase] eapi /api/song/lyric/v1 → yrc absent, ytlrc absent`
///     `[NetEase] yrc unavailable — falling back to line-synced (lrc)`
/// 这时只有 `hasUsableWordLevelData` 一道判据，于是：
///     `[WordByWord] overlay detached`  ← 摘掉，之后再没挂上
/// 我们的层一撤，Spotify 就把它**自己那一页**露出来 —— 日区是官方供应商
/// 「プチリリ」，不带 (EeveeSpotify)。用户看到的就是"歌词源选 NE，
/// 结果返回了 Spotify 自带的 petit 歌词"，而且我们自绘的壳、罗马化、
/// 上下淡入淡出**全都一起消失**。
///
/// 所以撤层的真正条件应该是"**行级**都用不了"（无时间轴 / 静态歌词 / 还没拿到 dto），
/// 而不是"没有逐字"。逐字只是高亮精度的一档，不该决定整层在不在。
///
/// 阈值与 `hasUsableWordLevelData` 一样取 50%：低于一半行有时间轴的数据
/// （坏 lrc、只有零星几行带时间）按行渲染也是错位的，那种情况仍然交还原生。
func hasUsableLineLevelData(_ dto: LyricsDto?) -> Bool {
    guard let dto, dto.timeSynced else { return false }
    let lines = dto.lines
    guard !lines.isEmpty else { return false }
    let timedLines = lines.filter { $0.offsetMs != nil }.count
    return timedLines * 10 >= lines.count * 5  // >= 50%
}

/// 逐词歌词层的**纯色底色**（"只开逐词歌词、没开更好的逐词歌词"那条路用作背景）。
///
/// 优先级与旧 overlay 原来的取色完全一致：
///   1. `CustomLyrics` 最终写回的原生歌词底色（与模块头同色，保证两者一致）；
///   2. 「定制」里的显示原始颜色 → 正在播放背景色；
///   3. 「定制」里的静态色；
///   4. 专辑提取色（按归一化因子调整）；
///   5. 兜底灰。
///
/// 抽成文件级函数是因为它有**两个**消费者：旧 UIKit 层（iOS 26 以下）与
/// 共用页面那条路的纯色背景 —— 取色逻辑必须只有一份。
func wordByWordSolidBackgroundColor() -> UIColor {
    if currentLyricsBackgroundColorARGB != 0 {
        let argb = currentLyricsBackgroundColorARGB
        let alphaByte = (argb >> 24) & 0xFF
        return UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: alphaByte == 0 ? 1 : CGFloat(alphaByte) / 255
        )
    }

    let settings = UserDefaults.lyricsColors

    if settings.displayOriginalColors,
       let original = backgroundViewModel?.color() {
        return original.withAlphaComponent(1)
    }

    if settings.useStaticColor, !settings.staticColor.isEmpty {
        return UIColor(Color(hex: settings.staticColor))
    }

    let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    let extractedHex: String? = {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return track?.extractedColorHex()
        default: return track?.metadata()["extracted_color"]
        }
    }()
    if let hex = extractedHex {
        return UIColor(Color(hex: hex).normalized(settings.normalizationFactor))
    }

    if let background = backgroundViewModel?.color() {
        return UIColor(Color(background).normalized(settings.normalizationFactor))
            .withAlphaComponent(1)
    }

    return .gray
}

private final class LineLabel: UILabel {
    var lineIndex = -1
}

// 这里曾经有一个自绘的 UIKit 进度条 `WordByWordProgressBar`。
// 已删除：进度条现在与「更好的逐词歌词」共用**同一份** SwiftUI 实现
// （`AppleMusicLyricsProgressBar`，见 `AppleMusicLyricsPlaybackControl.swift`）——
// 两份实现必然会在尺寸、圆点大小、拖动手感上慢慢跑偏。

final class LyricsWordByWordOverlayView: UIView, UIScrollViewDelegate {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var lineLabels: [UILabel] = []
    private var displayTexts: [String] = []
    private var wordRanges: [[Range<String.Index>]] = []
    private var wordIndices: [[Int]] = []
    private var providerLabel: UILabel?
    /// 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    var showsProviderFooter = false
    /// 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    var showsTranslation = true
    /// 是否显示**全屏壳**：曲名 + 歌手、进度条 + 时间、三键、右上角收起键。
    ///
    /// 为什么必须有：这一层在全屏时用的是**不透明**底色（见 `configureBackdropIfNeeded`），
    /// 而它挂在 `vc.view` 的最前面 —— 原生那一页的标题栏、进度条、播放键、
    /// 右上角收起键全被压在下面。不出自己的壳，用户在全屏里就是
    /// "一个按键都没有"，而且是一屏没有任何元信息的纯歌词（真机截图实证：很难看）。
    ///
    /// ⚠️ 壳的内容**不是这里画的**：用的是与「更好的逐词歌词」**同一份** SwiftUI 组件
    /// （`LyricsShellViews.swift`）。自己再手写一套 UIKit 壳的结果，真机对比下来
    /// 处处对不上（标题偏高、三键太散、上下淡出难看）—— 用户的原话是"直接照抄不好吗"。
    /// 这里只管：把它挂上、给它数据、按同样的常数给歌词让位。
    /// 歌词本身的高亮/闪烁与背景仍保持旧层原样。
    var showsPlaybackControls = false {
        didSet {
            guard showsPlaybackControls != oldValue else { return }
            applyControlsVisibility(showsPlaybackControls)
        }
    }
    /// 行级译文标签（每行原文下面一行小字），用于 rebuild 清理。
    private var translationLabels: [UILabel] = []

    // MARK: 全屏壳（与「更好的逐词歌词」共用同一份组件）

    /// 壳的宿主（顶部条 + 底部条两个 SwiftUI hosting controller）。
    private let shellHosts = LyricsShellHosts()
    /// 壳要的播放状态投影（当前时间 / 总时长 / 是否在播放）。
    ///
    /// 位置来源与歌词高亮**复用同一个** `WordByWordPositionResolver` ——
    /// 两处各读一次播放器很容易错拍（进度条和歌词差半秒那种）。
    private lazy var projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }
    /// 换歌时要跟着变的壳文本。
    private var shellTitle: String = ""
    private var shellArtist: String = ""
    /// 壳当前是否已按"可见"布置过（避免每帧重设约束常量）。
    private var controlsApplied: Bool?
    private var stackBottomConstraint: NSLayoutConstraint?
    private var stackTopConstraint: NSLayoutConstraint?

    private var dto: LyricsDto?
    private var dtoVersion = -1
    private var activeLineIndex = -1
    private var activeWordIndex = -1

    /// 行色随背景明暗切换，见 `resolveTextColors`。
    private var lineColor = UIColor.black
    private var activeLineColorValue = UIColor.white
    /// 行级译文字号（比歌词小）。
    private let translationFontSize: CGFloat = 16
    /// 行级译文颜色：与未唱歌词（其余行）一致。
    private var translationColor = UIColor.black
    /// 当前行内「未唱」词的透明度（已唱/正在唱为全白）。
    private let unsungWordOpacity: CGFloat = 0.45
    /// 背景色缓存：每次 rebuild（换歌/换数据）后按「定制」选项重新计算一次。
    private var resolvedBackgroundColor: UIColor?
    /// 模糊封面背景层（最底层）：封面拿不到 / 用户选了静态色时自动退回纯色。
    private let backdropView = LyricsBackdropView()
    /// 当前背景对应的「歌 + 设置」标识，变了才重新配置背景。
    private var resolvedBackdropKey: String?
    /// 顶部渐隐层（scrim）：背景色 → 透明，让上滚的歌词在顶部渐隐退出。
    private let topFadeView = UIView()
    private let topFadeLayer = CAGradientLayer()
    /// 底部渐隐层（scrim）：透明 → 背景色，让从底部进入的歌词渐隐进入。
    private let bottomFadeView = UIView()
    private let bottomFadeLayer = CAGradientLayer()

    /// 手动滚动时暂停自动跟随，直到该时间点
    private var autoScrollPauseUntil: Date = .distantPast
    /// 诊断：节流打印当前高亮状态
    private var lastDiagnosticLog: Date = .distantPast
    /// 当前行在视口中的目标位置（距顶部比例）：0.40 = 视口上方约 40% 处。
    private let activeLineViewportFraction: CGFloat = 0.40
    /// 自动滚动动画时长（秒），越小越「干脆」。
    private let scrollAnimationDuration: TimeInterval = 0.20
    /// 歌词行字号（对照 Spotify 原生歌词放大）。
    private let lyricsFontSize: CGFloat = 22
    /// 歌词行左右内边距（对照「歌词」标题的左缩进）；全屏歌词可单独调大。
    private var lyricsSideInset: CGFloat = 16
    /// 歌词块顶部留白（未滚动时第一行的起始高度）。
    private let lyricsTopPadding: CGFloat = 18
    // 左右/宽度约束的可更新引用（供 setSideInset 调整）
    private var stackLeadingConstraint: NSLayoutConstraint?
    private var stackTrailingConstraint: NSLayoutConstraint?
    private var stackWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // ⚠️ 自己的尺寸**始终**等于宿主的 bounds。
        //
        // `autoresizingMask` 只在"父视图 bounds 之后又变了"时按比例调整；而挂载那一刻
        // 宿主可能还没收敛到最终尺寸（真机实证：预览里的歌词被排成整页宽，
        // 右侧在卡片边缘被裁掉、滚动看着"跑偏"）。这里每个布局周期对齐一次。
        if let host = superview, bounds.size != host.bounds.size {
            frame = CGRect(origin: .zero, size: host.bounds.size)
        }

        // 上下淡出带（含"壳下面那两块铺底"）。
        //
        // 有壳时不再是"一小条淡出"就完事：
        //   · 上：从屏幕顶到**标题栏下沿**整块铺底色，只在最下面 `fadeBottomBand`
        //     范围内做淡入 —— 这样淡入正好落在"歌手下方"，标题/歌手背后是干净的底色；
        //   · 下：从**控件栏顶部**到底部整块铺底色，往上 `fadeBottomBand` 做淡出 ——
        //     进度条/时间/三键背后同样是干净的底色。
        //
        // 真机截图实证（修之前）：只铺一条 40pt 的淡出带，壳本身没有背景，
        // 于是歌词直接从标题、进度条和三键底下穿过去 —— 三键压在一行歌词上。
        // 安全区用 `resolvedSafeAreaInsets`（窗口的）：全屏页里我们挂在 `vc.view` 上，
        // 自己那份是 0，用它会得到"淡入贴屏幕最顶端、淡出压到进度条上"。
        updateFadeLayers()

        // 折行宽度**显式**告诉每个 label。
        //
        // 栈的宽度约束本来已经给了宽度，但 label 不设 `preferredMaxLayoutWidth` 时，
        // 在某些布局时序上（宿主刚挂上、宽度还没收敛）会先按**单行固有宽度**排一次，
        // 顺手把栈撑宽 —— 表现就是"歌词跑到卡片外面被裁掉、滚动看着跑偏"。
        let wrapWidth = currentWrapWidth
        if wrapWidth != lastWrapWidth {
            lastWrapWidth = wrapWidth
            for label in lineLabels { label.preferredMaxLayoutWidth = wrapWidth }
            for label in translationLabels { label.preferredMaxLayoutWidth = wrapWidth }
        }

        // 有壳时歌词的上下留白要跟着安全区 + 壳的高度走（旋转 / 换设备都要跟着变）。
        updateLyricsInsetsIfNeeded()

        // 几何诊断：歌词面板 + 淡出带的实际停靠点。
        //
        // ⚠️ 这一行是排查"淡入/淡出位置不对"的**唯一**依据 ——
        // 把上下淡出带、壳的实际占位、窗口安全区一次打全：
        //   `fade=` 那两段是**绝对 y**，直接和截图里"歌手下方 / 进度条上沿"对得上。
        let fadeSummary = "top[\(Int(topFadeView.frame.minY))..\(Int(topFadeView.frame.maxY))]"
            + " bottom[\(Int(bottomFadeView.frame.minY))..\(Int(bottomFadeView.frame.maxY))]"
        if fadeSummary != lastLoggedFadeSummary {
            lastLoggedFadeSummary = fadeSummary
            writeDebugLog(
                "[WordByWord] legacy fades \(fadeSummary)"
                    + " insets=(\(Int(resolvedSafeAreaInsets.top)),\(Int(resolvedSafeAreaInsets.bottom)))"
                    + " shell=\(showsPlaybackControls) hidden=(\(topFadeView.isHidden),\(bottomFadeView.isHidden))"
            )
        }

        // 尺寸变化时打一条（排查"挂上了但大小/换行不对"用；不随每帧刷屏）。
        if bounds.size != lastLoggedSize {
            lastLoggedSize = bounds.size
            writeDebugLog(
                "[WordByWord] legacy overlay \(Int(bounds.width))x\(Int(bounds.height))"
                    + " stack=\(Int(stackView.bounds.width))"
                    + " label=\(Int(lineLabels.first?.bounds.width ?? 0))"
                    + " shell=\(showsPlaybackControls)"
            )
        }
    }

    /// 安全区：**优先用窗口的**。
    ///
    /// ⚠️ 真机实证（日志 8）：全屏页里我们挂在 `vc.view` 上，自己算出来的
    /// `safeAreaInsets` 是 **0**（这一页的安全区由更上层处理），于是
    /// "上淡出带"从屏幕最顶端开始、"下淡出带"压到进度条上 ——
    /// 就是"淡入不在歌手下方、淡出不在进度条上方"。
    /// 窗口的安全区一定拿得到，用它就和 SwiftUI 那边（新层）对齐了。
    private var resolvedSafeAreaInsets: UIEdgeInsets {
        if let insets = window?.safeAreaInsets, insets != .zero { return insets }
        return safeAreaInsets
    }

    /// 有壳时歌词的上下留白 = 安全区 + 壳高度 + 呼吸。
    ///
    /// 数值全部取自 `LyricsShellLayout`（与新层同一份），所以第一行落在
    /// "标题栏下沿 + 8"、最后一行停在"控件栏上沿 − 46"，两边一致。
    private func updateLyricsInsetsIfNeeded() {
        let insets = resolvedSafeAreaInsets
        let top: CGFloat
        let bottom: CGFloat
        if showsPlaybackControls {
            top = insets.top + LyricsShellLayout.headerHeight + LyricsShellLayout.contentTopInset
            bottom = -(insets.bottom + LyricsShellLayout.footerHeight + LyricsShellLayout.contentBottomInset)
        } else {
            top = lyricsTopPadding
            bottom = -60
        }
        if let constraint = stackTopConstraint, constraint.constant != top {
            constraint.constant = top
        }
        if let constraint = stackBottomConstraint, constraint.constant != bottom {
            constraint.constant = bottom
        }
    }

    /// 上一次设置过的折行宽度 / 上一次打过日志的尺寸（都是"变了才动"的缓存）。
    private var lastWrapWidth: CGFloat = -1
    private var lastLoggedSize: CGSize = .zero
    private var lastLoggedFadeSummary: String = ""

    /// 当前应当使用的折行宽度（= 我们宽度 − 左右边距）。
    private var currentWrapWidth: CGFloat {
        max(bounds.width - 2 * lyricsSideInset, 1)
    }

    /// 把两条渐隐带的图层对齐到各自的视图。
    ///
    /// ⚠️⚠️ **这两行是"上下淡入淡出根本不出现"的唯一原因，别再删掉。**
    ///
    /// `CAGradientLayer` 是**手动** `addSublayer` 上去的，不参与 Auto Layout，
    /// 新建时 `frame` 是 `.zero` —— 而下面 `updateFadeLayers()` 从头到尾只改
    /// `topFadeView.frame` / `bottomFadeView.frame` 和渐变的 `colors`/`locations`，
    /// **从来没给过这两个图层尺寸**。一个 0x0 的渐变图层画不出任何像素，
    /// 于是那两条"铺底色 + 淡出"的带子等于不存在：
    ///   · 全屏（有壳）：标题栏、进度条、时间、三键背后是干净的透明，
    ///     歌词直接从它们**底下穿过去** —— 真机截图里"歌曲名压在第一行歌词上"、
    ///     "三键压在一行歌词上"就是这个；
    ///   · 预览（无壳）：卡片上下两端没有渐隐，进出视口的行是硬切。
    ///
    /// 对照：`LyricsBackdropArtworkView` 那个同类渐变层是在 `layoutSubviews()`
    /// 里 `gradientLayer.frame = bounds` 的，所以它的背景一直正常 ——
    /// 两处只有一处写了尺寸，这就是差别。
    ///
    /// 放在 `updateFadeLayers()` 里（而不是 `layoutSubviews`）是因为两个视图的
    /// `frame` 就是在那里设的，尺寸与位置必须成对更新，否则会差一帧。
    private func syncFadeLayerFrames() {
        topFadeLayer.frame = topFadeView.bounds
        bottomFadeLayer.frame = bottomFadeView.bounds
    }

    /// 淡出带（scrim）的几何 + 颜色 + 渐变停靠点。
    ///
    /// ⚠️ 颜色与 `locations` 必须**成对、在同一处**设置：`CAGradientLayer` 要求两者
    /// 数量一致，一处只设 colors、另一处只设 locations 会画出花屏甚至直接崩。
    /// 所以这里统一算，`configureBackdropIfNeeded` 只负责把底色算出来。
    /// 尺寸交给上面的 `syncFadeLayerFrames()`（`frame` 变了它必须跟着变）。
    private func updateFadeLayers() {
        let base = resolvedBackgroundColor ?? .black
        let clear = base.withAlphaComponent(0)

        guard showsPlaybackControls else {
            // 预览：卡片内部没有壳，上下各一小条渐隐就够了。
            let band: CGFloat = bounds.height < 420 ? 28 : 48
            let insets = safeAreaInsets
            topFadeView.frame = CGRect(x: 0, y: insets.top, width: bounds.width, height: band)
            topFadeLayer.colors = [base.cgColor, clear.cgColor]
            topFadeLayer.locations = [0, 1]
            bottomFadeView.frame = CGRect(
                x: 0,
                y: bounds.height - insets.bottom - band,
                width: bounds.width,
                height: band
            )
            bottomFadeLayer.colors = [clear.cgColor, base.cgColor]
            bottomFadeLayer.locations = [0, 1]
            syncFadeLayerFrames()
            return
        }

        let insets = resolvedSafeAreaInsets
        // 渐隐带的**过渡宽度**（不是整条带子的高度，见下面两段）。
        //
        // ⚠️ 这个值别改回 `contentTopInset`(8)：8pt 的过渡在 3x 屏上只有 24 个像素，
        // 观感是"一刀切"而不是淡入淡出 —— 真机反馈原话是"下方的淡出有点低"
        // （淡出挤在最后 8pt 里，看着就像贴在底部的一条硬边）。
        // 40 与「更好的逐词歌词」那条路的 `LyricsShellLayout.fadeBottomBand` 一致，
        // 两条路的淡出手感才对得上。
        let band = LyricsShellLayout.fadeBottomBand

        // ── 上：标题栏整块铺底色，在**紧贴第一行歌词**的上方 `band` 里做淡入 ──────
        //
        // 用户要的是"淡入淡出放在歌手名字下面、播放条上面，像卡拉OK那样"。
        // 歌词让位的起点 = `安全区 + 标题栏高(62) + 内容呼吸(8)`，也就是第一行歌词的 y：
        //   · 0 … (headerBottom − band)  完全不透明 → 状态栏、歌名、歌手背后是干净底色，
        //     歌手名字**不会被渐变蹭到**（这一点很难返工，必须在第一次就做对）；
        //   · (headerBottom − band) … headerBottom  逐渐变透明 → 歌词正好从"歌手下方"
        //     开始淡入，而不是凭空出现。
        //
        // ⚠️ `headerBottom` 不再夹一个 `min(..., 1)`：原来那写法在极短屏/异常状态下会让
        // `headerBottom < band`，`topStop` 被夹成 0，于是 locations 变成 [0,0,1]，
        // 最上面那一段从第一像素起就开始透明 —— 底色整块失效。
        let headerBottom = max(
            insets.top + LyricsShellLayout.headerHeight + LyricsShellLayout.contentTopInset,
            band + 1
        )
        topFadeView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerBottom)
        topFadeLayer.colors = [base.cgColor, base.cgColor, clear.cgColor]
        let topStop = min(max(Double(max(headerBottom - band, 0) / headerBottom), 0), 1)
        topFadeLayer.locations = [0, NSNumber(value: topStop), 1]

        // ── 下：从控件栏顶部**往上** `band` 做淡出，控件栏整块（进度条 + 时间 + 三键）铺底色 ──
        //
        // 停靠点用的是新层那套名义值 `height − (安全区 + 116)`：它正好落在**进度条上沿之上**
        // （控件实际内容在它下面约 16pt），所以"淡出停在进度条上方"。
        // 渐变向上铺满 `band`，于是淡出发生在"最后一行歌词下方到进度条之间"那段空白里，
        // 不会等到贴着屏幕底才开始 —— 这就是"淡出太低"的修法。
        let footerTop = min(
            bounds.height - (max(insets.bottom, 8) + LyricsShellLayout.footerHeight),
            bounds.height
        )
        let fadeStart = max(footerTop - band, 0)
        let span = max(bounds.height - fadeStart, 1)
        bottomFadeView.frame = CGRect(x: 0, y: fadeStart, width: bounds.width, height: span)
        bottomFadeLayer.colors = [clear.cgColor, base.cgColor, base.cgColor]
        let bottomStop = min(max(Double(band / span), 0), 1)
        bottomFadeLayer.locations = [0, NSNumber(value: bottomStop), 1]

        syncFadeLayerFrames()
    }

    /// 设置背景样式：全屏传 `.stage`（溢出铺满整屏、均匀暗化），
    /// 内嵌预览传 `.card`（只在卡片内、上下暗中间透）。
    func setBackdropStyle(_ style: LyricsBackdropView.Style) {
        backdropView.style = style
        // 样式变了要让 configureBackdropIfNeeded 重新算一次（它按 key 缓存）。
        resolvedBackdropKey = nil
    }

    /// 调整歌词行左右边距（全屏用到更大的左边距时调用）。
    func setSideInset(_ inset: CGFloat) {
        lyricsSideInset = inset
        stackLeadingConstraint?.constant = inset
        stackTrailingConstraint?.constant = -inset
        stackWidthConstraint?.constant = -(2 * inset)
    }

    private func setupView() {
        // 背景交给 backdropView（模糊封面），自身保持透明，否则会把它盖住。
        backgroundColor = .clear

        backdropView.frame = bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        topFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        topFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        topFadeView.layer.addSublayer(topFadeLayer)
        topFadeView.isUserInteractionEnabled = false
        topFadeView.isHidden = true

        bottomFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        bottomFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        bottomFadeView.layer.addSublayer(bottomFadeLayer)
        bottomFadeView.isUserInteractionEnabled = false
        bottomFadeView.isHidden = true

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 18
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        addSubview(topFadeView)
        addSubview(bottomFadeView)
        // 控制条与收起键**最后加**：它们要浮在渐隐层与歌词之上。
        setupPlaybackControls()

        let stackBottom = stackView.bottomAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.bottomAnchor,
            constant: -60
        )
        stackBottomConstraint = stackBottom
        let stackTop = stackView.topAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.topAnchor,
            constant: lyricsTopPadding
        )
        stackTopConstraint = stackTop

        NSLayoutConstraint.activate([
            // ⚠️ 滚动视图贴自己的四边，**不贴安全区**：安全区改由歌词的上下留白承担
            // （见 `updateLyricsInsetsIfNeeded`）。这样"第一行落在标题栏下沿"这件事
            // 只依赖一处计算，不会再出现"我们这层拿到的 safeAreaInsets 是 0"时整体上移。
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackTop,
            stackBottom,
        ])

        // 左右/宽度单独建，便于全屏时调整左边距。
        //
        // ⚠️ 宽度锚到**自己**（不是 `scrollView.frameLayoutGuide`）：日志 8 实证，
        // 某些时序下那条链会解出一个比我们宽得多的值（overlay=342 而 stack=486），
        // 歌词于是被排成 486pt 宽、在卡片右缘裁掉 —— 就是"预览歌词向左偏移"。
        // 锚到自己就只有一个来源：我们的宽度。
        let leading = stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: lyricsSideInset)
        let trailing = stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -lyricsSideInset)
        let width = stackView.widthAnchor.constraint(equalTo: widthAnchor, constant: -(2 * lyricsSideInset))
        NSLayoutConstraint.activate([leading, trailing, width])
        stackLeadingConstraint = leading
        stackTrailingConstraint = trailing
        stackWidthConstraint = width

        // 背景必须在最底层 —— 放在所有子视图添加完之后再插到 index 0，
        // 不依赖 addSubview 的调用顺序。
        insertSubview(backdropView, at: 0)

        applyControlsVisibility(showsPlaybackControls)
    }

    // MARK: 全屏壳（与「更好的逐词歌词」共用同一份组件）

    /// 把壳挂上（只挂一次；显隐与内容由 `applyControlsVisibility` /
    /// `refreshShellMetadata` 管）。
    ///
    /// 壳的每个部件都来自 `LyricsShellViews.swift` —— 与新层是**同一份代码**。
    /// （自己再手写一套 UIKit 壳的结果，真机对比处处对不上：标题偏高、三键太散、
    /// 上下淡出难看；而且那个自绘收起键的标签正好是 "close"，
    /// 被 `dismissFullscreen()` 当成原生控件点了回来 —— 无限递归直接爆栈崩掉。）
    private func setupPlaybackControls() {
        shellHosts.attach(
            to: self,
            projection: projection,
            primaryColor: .white,
            onSeek: { time in
                // 与点歌词行走同一条 seek 路径（+5ms 是为了稳稳落在行内部而不是边界）。
                WordByWordSeeker.seek(toMs: Int((time * 1000).rounded()) + 5)
            },
            onClose: {
                WordByWordPlaybackControl.dismissFullscreen()
            }
        )
        shellHosts.setHidden(true)
    }

    /// 如果自己不在宿主的最前面就抬一次（已经是最前时什么都不做）。
    ///
    /// 每帧都会被调用，所以不能真的每次都重排 subviews —— 那会让 UIKit 每帧都做一次
    /// 数组搬移与图层重排。
    private func ensureFrontmost() {
        guard let host = superview else { return }
        if host.subviews.last !== self {
            host.bringSubviewToFront(self)
        }
        // 壳的两个宿主也要一直压在最上面（原生内容重排 subviews 时会挤上来）。
        shellHosts.bringToFront()
    }

    /// 显示 / 隐藏整套壳，并让歌词上下留出同样的空。
    ///
    /// ⚠️ 带缓存：`setCurrentTime` 每帧都会调到这里，而改 `constant` 会让 UIKit
    /// 重新跑一轮布局 —— 每帧重设一次等于每帧无谓地失效一次布局。
    private func applyControlsVisibility(_ visible: Bool) {
        guard controlsApplied != visible else { return }
        controlsApplied = visible
        shellHosts.setHidden(!visible)
        // 歌词的上下留白由 `updateLyricsInsetsIfNeeded` 统一算（安全区 + 壳高度），
        // 否则第一行会钻到标题栏底下、最后几行会被进度条压住。
        updateLyricsInsetsIfNeeded()
        setNeedsLayout()
    }

    /// 每帧把播放状态喂给壳。
    ///
    /// 进度条的百分比、两个时间、播放/暂停图标**全在那份投影里算** ——
    /// 与新层走的是同一个 `AppleMusicLyricsPlaybackProjection`，所以两边的
    /// 手感/数值天然一致，不会各算各的。
    private func updateShellPlayback() {
        guard showsPlaybackControls else { return }
        projection.refresh()
    }

    /// 换歌时刷新壳上的曲名 / 歌手。
    ///
    /// 从 `SPTPlayerTrack` 取（与新层一致）：歌词里没有歌手名，
    /// 而曲名在歌词数据里可能是别的语言写法。
    private func refreshShellMetadata() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        shellTitle = track?.trackTitle() ?? ""
        shellArtist = (EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()) ?? ""
        shellHosts.update(title: shellTitle, artist: shellArtist)
        writeDebugLog("[Shell] legacy metadata \"\(shellTitle)\" — \"\(shellArtist)\"")
    }

    /// 打完一行几何诊断：**"歌词看起来偏不偏"全在这几个数里**。
    ///
    /// 面板宽度、它在窗口里的位置、滚动视图宽度、栈宽、第一行 label 的宽度 ——
    /// 之前"预览歌词偏左/被裁"这类问题只能靠猜，有了这一行一眼就能定位。
    /// 每次 rebuild（换歌 / 换数据）打一条，不随每帧刷屏。
    private func logLegacyGeometry() {
        guard !lineLabels.isEmpty else { return }
        let inWindow = convert(bounds, to: nil)
        let insets = showsPlaybackControls ? resolvedSafeAreaInsets : safeAreaInsets
        writeDebugLog(
            "[WordByWord] legacy geometry overlay=\(Int(bounds.width))x\(Int(bounds.height))"
                + " at(\(Int(inWindow.minX)),\(Int(inWindow.minY)))"
                + " scroll=\(Int(scrollView.frame.width))"
                + " content=\(Int(scrollView.contentSize.width))"
                + " stack=\(Int(stackView.frame.width))"
                + " label=\(Int(lineLabels[0].frame.width))"
                + " wrap=\(Int(currentWrapWidth))"
                + " sideInset=\(Int(lyricsSideInset))"
                + " insets=(\(Int(insets.top)),\(Int(insets.bottom)))"
                + " shell=\(showsPlaybackControls)"
        )
    }

    /// 每帧由时钟调用：惰性取 dto、词级高亮、自动滚动。
    func setCurrentTime(_ ms: Double) {
        updateShellPlayback()
        // 原生内容（卡片里的歌词视图 / Element 各层）会在重排 subviews 时把我们挤下去，
        // 那一下 "bringSubviewToFront" 就白做了 —— 表现是"预览里的逐词层时不时被盖住"。
        // 每帧补一次；已经是最前时只花一次指针比较。
        ensureFrontmost()

        if dtoVersion != currentLyricsVersion {
            dto = currentLyricsDto
            dtoVersion = currentLyricsVersion
            rebuild()
        }

        // 背景（模糊封面 + 暗化）与文字色必须先于下面的 guard 配置好：
        // 文字色取决于背景明暗，而 rebuild() 已经按旧色建过标签了。
        configureBackdropIfNeeded()

        // 撤层的条件只要求**行级**可用，不要求逐字可用。
        //
        // ⚠️ 这条以前是 `hasUsableWordLevelData` —— 于是"有逐行、没逐字"的歌
        // （网易云 `yrc absent` 那一批）会把整层撤走，露出 Spotify 官方供应商
        // 「プチリリ」，并且把自绘壳 / 罗马化 / 上下淡入淡出一起带走。
        // 现在降到行级：仍然由我们渲染，只是高亮精度退成"当前行整行点亮"
        // （`applyHighlight` 在 `indices` 为空时本来就是整行全白，不需要另写一条渲染路）。
        // 真正该撤的还是那三种：无时间轴 / 静态歌词 / 还没拿到 dto。
        guard let dto, hasUsableLineLevelData(dto) else {
            backgroundColor = .clear
            backdropView.isHidden = true
            stackView.isHidden = true
            topFadeView.isHidden = true
            bottomFadeView.isHidden = true
            isUserInteractionEnabled = false   // 回退原生时让触摸穿透，别挡住原生歌词滚动
            // 整层都交还给原生时，自绘控制条也必须一起交还 ——
            // 否则会留下两颗悬浮的按钮压在 Spotify 原生界面上。
            applyControlsVisibility(false)
            return
        }

        stackView.isHidden = false
        isUserInteractionEnabled = true
        applyControlsVisibility(showsPlaybackControls)
        updateFadeVisibility()

        var bestLine = -1
        var bestWord = -1
        for (i, line) in dto.lines.enumerated() {
            guard let offset = line.offsetMs, Double(offset) <= ms else { continue }
            bestLine = i
            if let words = line.words {
                for j in words.indices where Double(words[j].startMs) <= ms {
                    bestWord = j
                }
            }
        }

        // 诊断：节流打印当前高亮状态（每 1s 一次），用于对比数据时间轴与实际渲染
        if Date().timeIntervalSince(lastDiagnosticLog) > 1.0 {
            lastDiagnosticLog = Date()
            var wordInfo = "no-line"
            if bestLine >= 0, bestLine < dto.lines.count {
                if let words = dto.lines[bestLine].words, !words.isEmpty {
                    if bestWord >= 0, bestWord < words.count {
                        wordInfo = "w\(bestWord)=\"\(words[bestWord].text)\"@\(words[bestWord].startMs)ms"
                    } else {
                        wordInfo = "w=none-yet"
                    }
                } else {
                    wordInfo = "words=nil"
                }
            }
            writeDebugLog("[WordByWord] t=\(Int(ms))ms line=\(bestLine) \(wordInfo)")
        }

        if bestLine == activeLineIndex && bestWord == activeWordIndex { return }

        let lineChanged = bestLine != activeLineIndex

        if lineChanged {
            let oldIndex = activeLineIndex
            activeLineIndex = bestLine

            if bestLine == oldIndex + 1 {
                // 正常前进：只更新旧/新两行，crossfade 平滑黑白切换，消除闪烁
                if oldIndex >= 0, oldIndex < lineLabels.count {
                    crossfade(lineLabels[oldIndex]) { self.applyPlain(to: oldIndex) }
                }
            } else {
                // 跳转/回退：整列表重涂 —— 已唱过/当前行白、未到行黑
                repaintAllLines(upTo: bestLine)
            }

            // 只在行切换时滚动；词切换不重复滚动，避免动画被反复打断产生卡顿
            if bestLine >= 0 {
                scrollToLine(bestLine)
            } else {
                // 回到歌曲开头（当前时间早于第一行）时滚回顶部
                scrollToTop()
            }
        }

        activeWordIndex = bestWord
        if bestLine >= 0 {
            if lineChanged {
                crossfade(lineLabels[bestLine]) { self.applyHighlight(to: bestLine, wordIndex: bestWord) }
            } else {
                applyHighlight(to: bestLine, wordIndex: bestWord)
            }
        }
    }

    private func rebuild() {
        for label in lineLabels { label.removeFromSuperview() }
        lineLabels = []
        for label in translationLabels { label.removeFromSuperview() }
        translationLabels = []
        providerLabel?.removeFromSuperview()
        providerLabel = nil
        displayTexts = []
        wordRanges = []
        wordIndices = []
        activeLineIndex = -1
        activeWordIndex = -1
        resolvedBackgroundColor = nil
        // 换歌/换数据后强制重算背景（即使两首歌底色恰好相同也要换封面）。
        resolvedBackdropKey = nil
        // 壳上的曲名 / 歌手 / 总时长也跟着换（换歌时唯一可靠的地方就是这里）。
        refreshShellMetadata()
        // 文字色不在这里定：setCurrentTime 紧接着就会调用
        // configureBackdropIfNeeded()，由它按背景明暗统一决定并在需要时重涂。
        // 这里先回到改动前的默认值，保证纯色兜底时建出来的标签就是对的。

        guard let dto else { return }

        for (index, line) in dto.lines.enumerated() {
            let (text, ranges, indices) = buildDisplayText(for: line)
            let label = LineLabel()
            label.lineIndex = index
            label.numberOfLines = 0
            label.textAlignment = .left
            label.font = .systemFont(ofSize: lyricsFontSize, weight: .semibold)
            // 折行宽度**建的时候**就给死：别等下一轮布局（`layoutSubviews` 里那次）
            // 才设，否则第一帧会按单行固有宽度排、把栈撑宽 —— 真机上就是
            // "预览歌词向左偏移 / 右边被卡片裁掉"。
            label.preferredMaxLayoutWidth = currentWrapWidth
            label.text = text
            label.textColor = lineColor
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleLineTap(_:))))

            // 每行用竖排 stack 包住：原文行 + 可选译文行
            let lineStack = UIStackView()
            lineStack.axis = .vertical
            lineStack.spacing = 4
            lineStack.addArrangedSubview(label)

            if showsTranslation, let translation = dto.translation, index < translation.lines.count {
                let t = translation.lines[index]
                if !t.isEmpty {
                    let translationLabel = UILabel()
                    translationLabel.numberOfLines = 0
                    translationLabel.textAlignment = .left
                    translationLabel.font = .systemFont(ofSize: translationFontSize, weight: .regular)
                    translationLabel.preferredMaxLayoutWidth = currentWrapWidth
                    translationLabel.textColor = translationColor
                    translationLabel.text = t
                    translationLabel.isUserInteractionEnabled = false
                    lineStack.addArrangedSubview(translationLabel)
                    translationLabels.append(translationLabel)
                }
            }

            stackView.addArrangedSubview(lineStack)
            lineLabels.append(label)
            displayTexts.append(text)
            wordRanges.append(ranges)
            wordIndices.append(indices)
        }

        // 底部：歌词提供者（仅全屏显示；原生歌词表格 footer 里的信息，overlay 覆盖后补出来）
        if showsProviderFooter, !currentLyricsProvider.isEmpty {
            let footer = UILabel()
            footer.numberOfLines = 0
            footer.textAlignment = .left
            footer.font = .systemFont(ofSize: 14, weight: .regular)
            footer.textColor = lineColor
            footer.text = "word_by_word_lyrics_provider".localizeWithFormat(currentLyricsProvider)
            stackView.addArrangedSubview(footer)
            providerLabel = footer
        }

        // 标签建完了：这一步之后几何才有意义（见那一行日志的说明）。
        setNeedsLayout()
        layoutIfNeeded()
        logLegacyGeometry()
    }

    /// 由词文本拼出行显示文本，并记录每个词在文本中的范围（空格 token 保留，空文本词跳过）。
    private func buildDisplayText(for line: LyricsLineDto) -> (String, [Range<String.Index>], [Int]) {
        guard let words = line.words, !words.isEmpty else { return (line.content, [], []) }

        var text = ""
        var ranges: [Range<String.Index>] = []
        var indices: [Int] = []
        for (index, word) in words.enumerated() {
            guard !word.text.isEmpty else { continue }
            let start = text.endIndex
            text += word.text
            ranges.append(start..<text.endIndex)
            indices.append(index)
        }
        guard !text.isEmpty else { return (line.content, [], []) }
        return (text, ranges, indices)
    }

    /// 行切换时整列表重涂：已唱过/当前行白、未到行黑（Spotify 原生样式）。
    private func repaintAllLines(upTo activeIndex: Int) {
        for (index, label) in lineLabels.enumerated() {
            label.attributedText = nil
            label.text = displayTexts[index]
            label.textColor = index <= activeIndex ? activeLineColorValue : lineColor
        }
    }

    /// 把某一行重置为纯白（已唱状态）。
    private func applyPlain(to lineIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        label.attributedText = nil
        label.text = displayTexts[lineIndex]
        label.textColor = activeLineColorValue
    }

    /// 用 crossfade 平滑某个 label 的外观切换（消除行切换时的整行闪烁）。
    private func crossfade(_ label: UILabel, _ update: @escaping () -> Void) {
        UIView.transition(with: label, duration: 0.15, options: [.transitionCrossDissolve], animations: update)
    }

    /// 当前行内部按「已唱/正在唱/未唱」上色（Apple Music 式行内点亮）：
    /// 已唱全白（普通）、正在唱全白加粗、未唱降透明度。
    private func applyHighlight(to lineIndex: Int, wordIndex: Int) {
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        let label = lineLabels[lineIndex]
        let text = displayTexts[lineIndex]

        let regularFont = UIFont.systemFont(ofSize: lyricsFontSize, weight: .semibold)

        // 整行默认全白（没有词级数据的行也保持全白）
        let highlighted = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: activeLineColorValue,
            .font: regularFont,
        ])

        let ranges = wordRanges[lineIndex]
        let indices = wordIndices[lineIndex]
        let activePos = wordIndex >= 0 ? indices.firstIndex(of: wordIndex) : nil

        for (pos, _) in indices.enumerated() {
            guard pos < ranges.count else { continue }
            let nsRange = NSRange(ranges[pos], in: text)

            let isSung = activePos.map { pos < $0 } ?? false
            if pos == activePos {
                // 正在唱：全白 + 描边"加粗"（负 strokeWidth 叠在填充上，不改变字形宽度，
                // 避免日文逐字加粗导致换行重排的闪烁）
                highlighted.addAttributes([
                    .strokeWidth: -2.0,
                    .strokeColor: activeLineColorValue,
                ], range: nsRange)
            } else if activePos != nil, !isSung {
                // 未唱：仅当已有正在唱的词时才降透明度；
                // 一行还没唱到第一个词时整行保持全白，避免「整行突然变灰」的闪烁
                highlighted.addAttributes([
                    .foregroundColor: activeLineColorValue.withAlphaComponent(unsungWordOpacity),
                ], range: nsRange)
            }
            // 已唱（pos < activePos）：保持整行默认的全白
        }

        label.attributedText = highlighted
    }

    // MARK: 背景：模糊封面

    /// 是否使用「模糊封面 + 暗化渐变」背景。三条否决：
    ///   - 用户在「定制」里选了静态色 → 静态色优先，不做封面背景；
    ///   - 用户选了显示原生颜色 → 保持 Spotify 原始观感，不做封面背景；
    ///   - 开关本身关掉 → 退回改动前的纯色底。
    private var backdropEnabled: Bool {
        guard NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled else { return false }
        let settings = UserDefaults.lyricsColors
        if settings.useStaticColor, !settings.staticColor.isEmpty { return false }
        if settings.displayOriginalColors { return false }
        return true
    }

    /// 背景配置的缓存标识：换歌、改设置、或底色来源变化都会让它变化。
    /// 返回 nil 表示当前应使用纯色底。
    ///
    /// 把 `currentLyricsBackgroundColorARGB` 也编进去是必要的：CustomLyrics
    /// 是在歌词注入**之后**才写回这个值，只按歌名做 key 会一直用首次算出的底色。
    private func backdropKey() -> String? {
        guard backdropEnabled else { return nil }
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let trackKey = track?.trackIdentifier ?? "unknown"
        return "\(trackKey)|\(NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled)|\(currentLyricsBackgroundColorARGB)"
    }

    /// 按当前背景明暗决定文字色。
    ///
    /// `isDarkSurface` 为 nil 表示「当前是纯色兜底底」，此时沿用改动前的黑底约定；
    /// 非 nil 时表示模糊封面层正在生效（该层必然是深色，因为有暗化渐变），
    /// 而原来的行色是按 Spotify 浅色底定的黑字 —— 不切换未唱行与译文会直接看不见。
    ///
    /// ⚠️ 这里显式传参而不是读 `backdropView.isHidden`：后者会残留上一次的底色判断，
    /// 在「切歌后先走纯色、再切到模糊封面」这种过渡帧上会做出错误结论。
    ///
    /// 返回 true 表示文字色发生了变化（调用方据此决定要不要重涂标签）。
    @discardableResult
    private func resolveTextColors(isDarkSurface: Bool?) -> Bool {
        // 已唱/正在唱始终是最亮的一层，两种底色下都是白色。
        let newLineColor: UIColor
        let newTranslationColor: UIColor
        if let isDarkSurface {
            // 深底：未唱用白（靠 unsungWordOpacity 压暗，与已唱区分），译文白但略淡。
            // 浅底：维持改动前的黑字。
            newLineColor = isDarkSurface ? .white : .black
            newTranslationColor = isDarkSurface ? UIColor.white.withAlphaComponent(0.75) : .black
        } else {
            newLineColor = .black
            newTranslationColor = .black
        }

        let changed = newLineColor != lineColor || newTranslationColor != translationColor
        lineColor = newLineColor
        translationColor = newTranslationColor
        activeLineColorValue = .white
        return changed
    }

    /// 按需（重）配置背景：纯色底或模糊封面层，并同步文字色。
    ///
    /// 每帧调用，但只在「首次 / 换歌 / 改设置 / 底色来源变化」时真正干活。
    private func configureBackdropIfNeeded() {
        // ── 非卡拉 OK 状态：**整块透明，把屏幕交还给 Spotify 原生界面** ──────────
        //
        // 什么时候走到这里：逐词歌词关掉、或这一首歌**连行级时间轴都没有**可用。
        // 此时这一层不该画任何东西 —— 连背景也不该画。
        // （注意不是"没有逐字"：只有逐行的歌仍然由我们渲染，见下面的判据。）
        //
        // ⚠️ 这里以前会铺一块**不透明的底色**（`backgroundColor = targetBackground`）。
        // 那一块把 Spotify 原生那一页整个盖住了：标题栏、进度条、播放键全部被压掉，
        // 屏幕上只剩我们的歌词和一块专辑色 —— 也就是"关掉更好的逐词歌词之后
        // 界面全没了"的真正原因。
        //
        // 而这一层本来的设计意图就是"渲染不了就交还"（见下面 `setCurrentTime` 里
        // 那个 guard 的注释）。不透明底色把这个退路堵死了。现在补回来。
        // ⚠️ 判据与 `setCurrentTime` 必须一致，否则会出现"层被撤掉了但底色还在"
        // 或者反过来"层还在但底色没了"——两者是同一层的一体两面。
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled,
              hasUsableLineLevelData(currentLyricsDto) else {
            backgroundColor = .clear
            backdropView.isHidden = true
            // 同 `setCurrentTime`：整层交还原生时控制条也要一起交还。
            applyControlsVisibility(false)
            return
        }

        // resolvedBackgroundColor 是缓存，用户改「定制」里的颜色时它不会变，
        // 所以不能沿用旧的 `backgroundColor != targetBackground` 判断，
        // 要把影响外观的几项一起编进 key。
        let key = backdropKey()
        let changed = resolvedBackgroundColor == nil || resolvedBackdropKey != key
        let targetBackground = changed ? wordByWordSolidBackgroundColor() : (resolvedBackgroundColor ?? .black)

        if changed {
            resolvedBackgroundColor = targetBackground
            resolvedBackdropKey = key
        }

        // 纯色底（用户选了静态色 / 显示原生色 / 开关关闭）：整块退回改动前的行为。
        guard key != nil else {
            if changed {
                backdropView.isHidden = true
                backgroundColor = targetBackground
                // 渐隐层的颜色/停靠点由 `updateFadeLayers()` 统一设置
                // （颜色与 locations 必须成对，见那里）—— 这里只让它重算一次。
                setNeedsLayout()
            }
            // 纯色兜底：沿用改动前的黑字约定（传 nil）。
            if resolveTextColors(isDarkSurface: nil) {
                repaintAllLines(upTo: activeLineIndex)
            }
            return
        }

        // 文字色跟着背景明暗走 —— 模糊封面层必然是深色底，而默认行色是黑字。
        // 每帧都能安全调用：resolveTextColors 是恒等操作，除非颜色真的要变。
        if changed {
            backdropView.isHidden = false
            backdropView.configure(
                baseColor: targetBackground,
                showsArtwork: true,
                material: NgzhwmSettingsViewModel.isLyricsBackdropMaterialEnabled
            )
            // 渐隐层同样交给 `updateFadeLayers()`（底色变了要重算一次）。
            setNeedsLayout()
            // 自身保持透明，否则会把 backdropView 盖住。
            backgroundColor = .clear
        }

        if resolveTextColors(isDarkSurface: backdropView.baseColorBrightness < 0.55) {
            repaintAllLines(upTo: activeLineIndex)
        }
    }

    // MARK: 背景取色（跟随「定制」选项）

    // 取色逻辑已抽成文件级 `wordByWordSolidBackgroundColor()`：
    // 旧 UIKit 层（iOS 26 以下）与"只开逐词歌词"那条路的纯色背景共用同一份，
    // 两处各写一遍必然慢慢跑偏（这个文件里已经吃过好几次这种亏）。

    // MARK: 手动滚动打断自动跟随

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(3)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 歌词滚到顶部/底部时对应渐隐层才隐藏（保证首尾行不被遮挡）
        updateFadeVisibility()
    }

    /// 顶部/底部渐隐层的显隐。
    ///
    /// ⚠️ 有壳时**永远显示**：这两条现在不是"首尾行的装饰"，而是歌词与壳之间的过渡，
    /// 同时也是壳的底色（见 `updateFadeLayers`）。一藏起来，标题栏和控件栏就会直接
    /// 压在清晰的歌词上 —— 真机截图实证：三键压在一行歌词上、歌曲名和第一行重叠。
    ///
    /// 预览（无壳）保持原来的行为：歌词在顶部/底部时隐藏，保证首尾行不被遮挡。
    private func updateFadeVisibility() {
        guard !showsPlaybackControls else {
            topFadeView.isHidden = stackView.isHidden
            bottomFadeView.isHidden = stackView.isHidden
            return
        }

        let atTop = scrollView.contentOffset.y <= 1
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let atBottom = scrollView.contentOffset.y >= maxY - 1
        topFadeView.isHidden = stackView.isHidden || atTop
        bottomFadeView.isHidden = stackView.isHidden || atBottom
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        autoScrollPauseUntil = Date().addingTimeInterval(2)
    }

    private func scrollToLine(_ lineIndex: Int) {
        // 手动滚动暂停期内不自动拉回
        guard Date() >= autoScrollPauseUntil else { return }
        guard lineIndex >= 0, lineIndex < lineLabels.count else { return }
        // 强制刷新布局：初次挂载/rebuild 后 contentSize 与各行 frame 尚未更新，
        // 不刷新会按旧 contentSize 算出错误 target，导致全屏打开时不滚到当前行。
        scrollView.layoutIfNeeded()
        let label = lineLabels[lineIndex]
        let rect = label.convert(label.bounds, to: scrollView)
        // 当前行定位到视口上方约 1/3 处，而不是 scrollRectToVisible 那样贴到最底部。
        let targetY = rect.minY - scrollView.bounds.height * activeLineViewportFraction
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let target = CGPoint(x: 0, y: min(max(0, targetY), maxY))
        // 自定义更短的动画时长，让自动滚动更干脆（贴近 Spotify 手感）
        UIView.animate(
            withDuration: scrollAnimationDuration,
            delay: 0,
            options: [.curveEaseOut],
            animations: { [weak self] in
                self?.scrollView.setContentOffset(target, animated: false)
            }
        )
    }

    /// 滚回歌词顶部（含安全区内边距修正）。
    private func scrollToTop() {
        scrollView.setContentOffset(
            CGPoint(x: 0, y: -scrollView.adjustedContentInset.top),
            animated: true
        )
    }

    @objc private func handleLineTap(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? LineLabel,
              let dto = dto, label.lineIndex >= 0, label.lineIndex < dto.lines.count,
              let offset = dto.lines[label.lineIndex].offsetMs else { return }
        WordByWordSeeker.seek(toMs: offset)
    }
}

// MARK: - 挂载管理

/// `@MainActor`：整个挂载链路只碰 UIKit（往 VC 的视图上挂 overlay），而调用点
/// （VC 的 viewDidAppear / SwiftUI 手势）本来都在主线程。标出来是为了让
/// `AppleMusicLyricsOverlayHost` 这个同样 main-actor 隔离的单例能被合法调用 ——
/// 否则就是"在非隔离同步上下文调用 MainActor 隔离的方法"。
@MainActor
final class WordByWordHost {
    static let shared = WordByWordHost()

    private var overlay: LyricsWordByWordOverlayView?
    private weak var hostView: UIView?
    private var isAttached = false
    /// 已经渲染进 overlay 的歌词版本号。
    /// 切歌时 `currentLyricsVersion` 会递增，用它区分「宿主没变但内容换了」——
    /// 否则会被下面的提前返回挡住，画面停在上一次的歌词（真机症状：第二首显示第一首）。
    private var renderedLyricsVersion: Int = -1
    /// 当前这次挂载是不是"全屏页"（showsProviderFooter == true）。
    /// `refreshForCurrentLyrics()` 据此避免在全屏时抢走宿主。
    private var attachedShowsProviderFooter = false
    /// 记住内嵌预览的宿主（VC + 命中的歌词视图），供歌词到达后重挂。
    private weak var lastPreviewController: UIViewController?
    private weak var lastPreviewContentView: UIView?
    /// 最近出现的内嵌歌词 VC（弱引用），全屏关闭后据此重新挂载。
    private weak var lastInlineController: UIViewController?
    /// 最近一次"全屏页"挂载用的 VC 与左边距（弱引用 + 参数）。
    ///
    /// 全屏页在整段停留期间宿主不会重建，所以这个引用一直有效。它的用途是补一种
    /// 罕见的断档：新层会因为"当前这首歌没有逐词数据"而把自己摘掉
    /// （`AppleMusicLyricsOverlayHost.update` 在行模型为空时 `detach()`），
    /// 而全屏页的 appear 回调**不会再来第二次** —— 没有这个锚点，下一首有逐词数据时
    /// 就没人能把层挂回去，页面会一直停在 Spotify 原生歌词上。
    private weak var fullscreenController: UIViewController?
    private var fullscreenSideInset: CGFloat = 24
    /// 关闭全屏时留在原宿主上的静态替身（见 `handOffToInlineKeepingStandIn`）。
    private var transitionStandInView: UIView?

    func rememberInlineController(_ controller: UIViewController) {
        lastInlineController = controller
    }

    /// 内嵌（预览）层是否**已经挂上、而且还在窗口里**。
    ///
    /// 给 `InlineLyricsHostLocator` 的看门狗用：预览歌词卡片是自适应表格 cell
    /// （`Lyrics_TextElementImpl.LyricsCell` + `SelfSizingTableView`），滚动、换行、
    /// 换歌时都会被复用重建 —— 我们的层挂在卡片上，卡片一被销毁层就跟着没了。
    /// 这是"预览里的逐词歌词时有时无"的第二个成因，看门狗据此重新查找宿主。
    var inlineOverlayIsLive: Bool {
        guard isAttached, !attachedShowsProviderFooter else { return false }
        if #available(iOS 26.0, *), let view = AppleMusicLyricsOverlayHost.shared.overlayView {
            return view.superview != nil && view.window != nil
        }
        guard let overlay else { return false }
        return overlay.superview != nil && overlay.window != nil
    }

    /// 全屏层是否正挂在屏上。
    ///
    /// 同上看门狗：全屏页是盖在内嵌页之上的 sheet，内嵌页的 `viewWillAppear`
    /// 不会重来，看门狗一直在跑；**没有这道闸门它会把全屏的层拽回卡片**。
    var fullscreenOverlayIsAttached: Bool {
        isAttached && attachedShowsProviderFooter
    }

    /// 这一首**没有**我们的歌词了（取词失败 / 用户选了原生歌词）时调用：
    /// 把已经挂上的层摘掉，并把"宿主已经渲染到哪个版本"也一并作废。
    ///
    /// 为什么不只是 `detach()`：`renderedLyricsVersion` 留着的话，下次
    /// `attach` 会以为"这个宿主上已经是当前版本了"而提前返回 —— 而实际上
    /// 层已经被摘掉，屏幕上是空的（原生歌词）。作废之后重新挂就一定成立。
    func clearForUnavailableLyrics() {
        detach()
        renderedLyricsVersion = -1
    }

    /// 关闭全屏后把 overlay 交还内嵌（预览）。
    func reattachToInline() {
        // ⚠️ 必须用**上次预览的挂载点**（卡片里的歌词视图），不能用
        // `lastInlineController.view` —— 那是正在播放页的根视图：`cardContainer(for:)`
        // 在它身上找不到卡片，于是退回"整页"，我们的卡片背景铺满整个正在播放页。
        // 这就是"退出全屏后预览变全屏"。
        if let controller = lastPreviewController,
           let contentView = lastPreviewContentView,
           attach(to: controller, contentView: contentView, showsTranslation: false) {
            return
        }
        if let controller = lastInlineController,
           attach(to: controller, showsTranslation: false) {
            return
        }
        // 两个宿主都没挂上（记的是整页大小 / 卡片还没建 / 已经被重建）→
        // 让看门狗重新查找宿主（它会避开整页、只认卡片）。
        InlineLyricsHostLocator.retryLookupIfNeeded()
    }

    /// 歌词数据到达后调用一次：把 overlay 重挂到**当前这首歌**的数据上。
    ///
    /// 为什么需要它：`attach` 只由宿主出现触发（`viewWillAppear` 等），而 9.1.x 上
    /// 内嵌宿主改成了 NPV —— **NPV 只在"进入正在播放页"时出现一次，切歌不会再来**，
    /// 所以"挂载早于数据到达"和"切歌后不刷新"这两件事都没有第二次机会。
    /// ng 原来的触发点（歌词卡片自己的 VC）天然每首歌都会再来一次，不需要这个通知。
    ///
    /// 全屏页不抢它的宿主：只在**同一个**全屏 VC 上刷新行模型（必要时补挂一次），
    /// 绝不把全屏的层挪回卡片。
    func refreshForCurrentLyrics() {
        guard renderEnabled else { return }

        // 全屏层自己会跟着版本号刷新（Apple Music 层是"就地更新行模型"，
        // 见 `AppleMusicLyricsOverlayHost.update`），但**必须有人去叫它** ——
        // 切歌时它挂在同一个宿主上、`attach` 的提前返回不会放行，
        // 不主动刷就会一直显示上一首的歌词。
        if isAttached && attachedShowsProviderFooter {
            if #available(iOS 26.0, *) {
                // 新层可能已经因为"当前这首歌没有逐词数据"而自己摘掉了
                // （`AppleMusicLyricsOverlayHost.update` 在行模型为空时 `detach()`）。
                // 那时 `refreshLinesIfNeeded()` 的 guard 会直接返回，而全屏页的
                // appear 回调不会再来 —— 新歌词就永远推不进去。所以这里要能补挂一次。
                if NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled,
                   hasUsableWordLevelData(currentLyricsDto),
                   AppleMusicLyricsOverlayHost.shared.overlayView == nil,
                   let controller = fullscreenController {
                    writeDebugLog("[WordByWord] fullscreen layer was dropped — reattaching")
                    attach(
                        to: controller,
                        sideInset: fullscreenSideInset,
                        showsProviderFooter: true
                    )
                    return
                }
                AppleMusicLyricsOverlayHost.shared.refreshLinesIfNeeded()
            }
            return
        }

        // 预览层：歌词比卡片先到是常态（卡片要等数据才建），所以这里**不能**
        // 因为"还没记住宿主"就放弃 —— 那正是"预览逐词几乎不挂载"的原因。
        if let controller = lastPreviewController,
           let contentView = lastPreviewContentView {
            writeDebugLog("[WordByWord] refresh for current lyrics (version \(currentLyricsVersion))")
            if attach(to: controller, contentView: contentView, showsTranslation: false) {
                return
            }
        }

        // 没挂上（没记住宿主 / 记的宿主被拒 —— 例如它落在封面容器里）→
        // 让看门狗立刻重新查找宿主，别等下一个 1.5s 心跳。
        InlineLyricsHostLocator.retryLookupIfNeeded()
    }

    private var renderEnabled: Bool {
        NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
    }

    /// contentView: overlay 挂到哪个视图（默认 VC 的 view）。
    /// sideInset: 覆盖层歌词行的左右边距（全屏可用更大值，默认用 overlay 自己的）。
    /// showsProviderFooter: 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    /// showsTranslation: 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    ///
    /// 这里曾经还有一个 `keepAboveView`（把原生 header 抬到 overlay 之上）。
    /// 已删除：它依赖"原生控件是本视图的直接子视图"这个**不成立**的假设，
    /// 而且取 header 用的 `Ivars` 在 Modern 全屏页上会命中不存在的 ivar（崩）。
    /// 旧 overlay 的显隐现在完全由"有没有逐词数据"决定，不需要它。
    ///
    /// - Returns: 这一层现在是不是**挂着的**。调用方（`refreshForCurrentLyrics` /
    ///   `reattachToInline`）据此决定要不要让看门狗立刻重找宿主 ——
    ///   预览场景里有几条"宁可不挂"的判据（没有卡片证据 / 整页大小），
    ///   那几种情况下"再挂一次"是白费力气，必须换宿主。
    @discardableResult
    func attach(
        to controller: UIViewController,
        contentView: UIView? = nil,
        sideInset: CGFloat? = nil,
        showsProviderFooter: Bool = false,
        showsTranslation: Bool = true
    ) -> Bool {
        guard renderEnabled else { return false }
        let view = contentView ?? controller.view
        guard let view else { return false }

        // ── 先把「内嵌预览的宿主」记下来，**早于任何数据判据** ────────────────────
        //
        // 这一步是"预览逐词几乎不挂载"的关键。9.1.x 上内嵌宿主只在进入正在播放页时
        // 出现一次（NPV 的 `viewWillAppear`），而那一刻歌词往往还在路上 ——
        // 于是 `usable == false`，函数直接返回。这两条记忆以前写在函数末尾的
        // AppleMusic 分支里，结果就是"数据没到 → 什么都没记住"，
        // 等歌词到达时 `refreshForCurrentLyrics()` 找不到宿主，只能放弃。
        //
        // 现在无论数据到没到、走新层还是旧层，宿主都先记下来。
        // ⚠️ 只记"不是整页大小"的内容视图：整页根本不是卡片里的歌词视图，
        // 记下来只会在下次 `attach` 时把层铺满整页（预览变全屏）。
        if !showsProviderFooter {
            lastInlineController = controller
            if !Self.isPageSized(view) {
                lastPreviewController = controller
                lastPreviewContentView = view
            }
        } else {
            // 全屏页：记住锚点与参数，供"层被摘掉之后的下一次刷新"重新挂载。
            fullscreenController = controller
            fullscreenSideInset = sideInset ?? 24
        }

        // 已挂在同一视图上、**且渲染的就是当前这首的歌词**时才算完成；
        // 宿主没变但歌词换了（切歌）也要重新走一遍 —— 下面紧接着就是 detach + 重挂。
        //
        // 这条版本判据是补 ng 原有逻辑的一个隐含前提：ng 的内嵌触发点是歌词卡片自己的
        // VC（每首歌/每次卡片重建都会 viewDidAppear，所以"再挂一次"是自然发生的），
        // 而那个类在 9.1.x 上已不存在，我们改用 NPV 宿主触发 —— NPV 只在进入页面时
        // 出现一次，切歌不会再来，于是必须靠这里显式判断版本。
        if isAttached, hostView === view, renderedLyricsVersion == currentLyricsVersion { return true }
        detach()

        let sideInset = sideInset ?? 16
        // 逐字可用 → 走逐字高亮；只有逐行 → 仍然由我们渲染（降级档）。
        //
        // ⚠️ 这两个值**必须分开**：`usable`（逐字）只用来决定"走不走 Apple Music 新层"
        // 以及"高亮精度"；能不能挂上这一层要看 `lineLevelUsable`。
        // 合成一个的话，"有逐行没逐字"那批歌就会掉回原生（见 `hasUsableLineLevelData` 的说明）。
        let usable = hasUsableWordLevelData(currentLyricsDto)
        let lineLevelUsable = hasUsableLineLevelData(currentLyricsDto)

        // 系统版本够、开关打开、数据可用 → 走 Apple Music 渲染层。
        //
        // ⚠️ 这里**必须**保留「更好的逐词歌词」这一条判据：
        // 两条路是**两套歌词渲染**（高亮/闪烁/译文处理都不同），
        // 用户要的只是"壳的观感一致"，不是"把歌词也换掉"——
        // 曾经试过让旧层也走新页面（连歌词一起换），被退回来了。
        if #available(iOS 26.0, *),
           usable,
           NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
            // ⚠️ 这里**不碰任何原生视图**：不隐藏、不清底色、不动 z 序。
            //
            // 全屏页曾经被这么"接管"过，结果是整页空白（真机 + dump 双证）：
            //   · 隐藏 `Lyrics_FullscreenElementPageImpl.LyricsView` →
            //     全屏页根视图里**一个子视图都没有**（dump 实测），
            //     Spotify 那一页的 header / 歌词 / 控件栏都不在根视图这一层，
            //     所以"藏歌词容器"等于把整页内容一起藏了；
            //   · 清根视图的 `backgroundColor` / layer → 摘掉的是这一页唯一的背景层
            //     （dump: `stripped 1 background layer(s): CALayer`），页面连底都没了。
            //
            // 现在的策略：原生 UI 全部原样保留，我们只负责把自己那块背景做够暗，
            // 让它盖住底下的东西（`LyricsBackdropView.solidStageScrimAlpha`）。
            // 这个判据用的是 showsProviderFooter —— 它只在全屏页为 true。
            // ── 挂载点：预览挂到**卡片容器**上，自己出壳 ─────────────────────
            //
            // 预览卡片的"壳"（顶部 `歌词` + 分享/展开那一行、四周留白）是 Spotify 的
            // Element 框架画的，而我们的层原来是挂在**歌词视图**（卡片里的一块内容）上。
            // 子视图盖不住父视图自己的背景，所以那一行 39pt 永远是专辑纯色 ——
            // 试过五种"盖住它"的办法（塞背景层 / 清容器底色 / 每帧重清 /
            // 画出 bounds 之外 / 改注入的背景色）全部无效，原因就在这。
            //
            // 现在换思路：把我们的层挂到**卡片容器**上、铺满整张卡片。
            // 壳这一层从此由我们画（`previewHeader` 就是那一行），粉杠问题不复存在。
            //
            // 全屏不受影响：它本来就挂 vc.view，并且自己画了整套壳。
            //
            // ── 预览的宿主判据（严格） ────────────────────────────────────────
            // 必须**先找到卡片容器**（见 `cardContainer` 的四条证据）。找不到卡片时，
            // 只有当内容视图本身是"已知的卡片歌词视图类"、或者是个**不自称歌词**的
            // 普通视图（老版本的 `LyricsOnlyViewController.view` 就是这种）才允许退化挂载。
            //
            // 被拒的正是日志 4 里那一种：`Lyrics_TextComponentImpl.LyricsView`
            // （366x120，实际待在**歌曲封面容器** 366x432 里）—— 名字里带 Lyrics、
            // 却不在"卡片歌词视图"名单里，卡片那一刻也还没建出来。退化挂载的后果是
            // 整层跑到封面上（`[PreviewShell] card container=UIView 366x432`）。
            // 拒绝之后什么都不挂，看门狗会在卡片建好时自己挂上来。
            let className = NSStringFromClass(type(of: view))
            let isKnownLyricsContent = inlineLyricsContentClassNames.contains(className)
            let claimsToBeLyrics = className.contains("Lyrics")
            let card: UIView? = showsProviderFooter ? nil : Self.cardContainer(for: view)
            if !showsProviderFooter,
               card == nil,
               claimsToBeLyrics,
               !isKnownLyricsContent {
                Self.logRejectionThrottled(
                    "[WordByWord] ⚠️ preview host rejected — no card and foreign lyrics view"
                        + " (\(className)) — will retry"
                )
                return false
            }
            // 预览宿主还必须**真的显示在屏幕上**。
            //
            // 日志 8 实证：歌词视图有可能是**离屏的复用视图** ——
            // `legacy overlay attached — host=Lyrics_TextElementImpl.LyricsTextView 671x256`，
            // 而它在窗口里的位置是 `at(-293,887)`（屏幕外）。挂上去就是"歌词挂错地方"：
            // 我们那一层跑到别的界面上去了。看不见就不挂，交给看门狗下一轮再找。
            if !showsProviderFooter, !Self.isVisibleOnScreen(view) {
                Self.logRejectionThrottled(
                    "[WordByWord] ⚠️ preview host off-screen (\(className)) — will retry"
                )
                return false
            }
            var mountView = showsProviderFooter ? view : (card ?? view)
            if !showsProviderFooter, Self.isPageSized(mountView) {
                // 卡片判据把"整页"当成了卡片（`cardContainer` 的尺寸启发式在
                // 宿主根视图上必然如此）。照挂就是"预览变全屏"：一块卡片背景
                // 铺满整个正在播放页，把原生界面全盖住。
                guard !Self.isPageSized(view) else {
                    writeDebugLog(
                        "[WordByWord] ⚠️ no safe preview mount point"
                            + " (\(NSStringFromClass(type(of: mountView))) is page-sized) — skipped"
                    )
                    return false
                }
                writeDebugLog(
                    "[WordByWord] preview mount view is page-sized"
                        + " (\(NSStringFromClass(type(of: mountView)))) — falling back to lyrics view"
                )
                mountView = view
            }
            // 卡片比歌词视图高出来的那段（实测 39～64pt）= 我们自绘标题栏要占的高度。
            // 全屏传 62（曲名 + 歌手两行，与页面默认值一致）。
            //
            // ⚠️ 预览要做范围检查：量出来的差值可能是**错的**（内容视图与卡片不等高，
            // 或者某一方还没布局完）。离谱的值会让标题栏占掉半张卡片、把歌词推下去 ——
            // 这时宁可传 0，让页面退回实测默认值（预览标题栏一行 ≈ 39pt）。
            let measuredInset = mountView.bounds.height - view.bounds.height
            let headerInset: CGFloat
            if showsProviderFooter {
                headerInset = 62
            } else if measuredInset >= Self.previewMinCardExtraHeight,
                      measuredInset <= Self.previewCardMaxExtraHeight {
                headerInset = measuredInset
            } else {
                headerInset = 0
            }
            AppleMusicLyricsOverlayHost.shared.update(
                in: mountView,
                sideInset: sideInset,
                showsProviderFooter: showsProviderFooter,
                solidBackdrop: showsProviderFooter,
                previewHeaderInset: headerInset
            )
            // 预览：把"展开 / 分享"的全部候选控件（标签 + frame）打一次日志。
            //
            // 为什么要这个：真机上出现过"点我们画的小方框没反应、点 `歌词` 两个字
            // 反而能进全屏"。那说明 `expandToFullscreenLyrics()` 找到的控件**不是**
            // 卡片上那一颗（很可能是页面别处的同名按钮，位置完全不同）。
            // 有了候选清单，就能按"在卡片范围内"来挑，不必再猜。
            if !showsProviderFooter {
                WordByWordPlaybackControl.dumpPreviewActionCandidates()
            }
            // 新层由主时钟驱动，旧 overlay 的回调必须清掉，否则两边同时渲染。
            WordByWordPlaybackClock.shared.onChange = nil
            WordByWordPlaybackClock.shared.tickHandler = { @MainActor ms in
                AppleMusicLyricsOverlayHost.shared.tick(ms: ms)
            }
            WordByWordPlaybackClock.shared.start()
            attachedShowsProviderFooter = showsProviderFooter
            // 预览挂载点在函数开头就记好了（那时还没有数据判据）；
            // 这里**不要**再记一次 `view` —— 它可能是整页大小的宿主根视图，
            // 覆盖掉正确的记录就又把"预览变全屏"放回来了。
            hostView = view
            isAttached = true
            renderedLyricsVersion = currentLyricsVersion
            return true
        }

        // 用不上新层就把它摘掉（例如从有逐字的歌切到纯 LRC 的歌）。
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }

        // 数据不可用时保持原生歌词，不做任何覆盖：
        // 铺一层空白背景比直接放行原生渲染更糟。
        //
        // ⚠️ 判据是**行级**：有逐行时间轴（哪怕没有逐字）也要挂上 —— 否则
        // "网易云这首歌没有 yrc"就会让我们整层消失、露出 Spotify 官方供应商。
        // 高亮精度退化成"当前行整行点亮"，见 `applyHighlight` 在无词数据时的行为。
        guard lineLevelUsable else { return false }

        // ⚠️ 旧层同样不许挂到"整页大小"的视图上。
        //
        // 旧实现没有"卡片容器"这个概念，挂哪儿就铺满哪儿，而且底色是**不透明**的 ——
        // 一旦挂到正在播放页的根视图上，整页原生界面（含那两颗按钮）会被盖光，
        // 表现与"预览变全屏"完全一样。触发路径就是 `reattachToInline()` 的兜底分支
        // （只记住了整页 VC、没记住卡片里的歌词视图时）。宁可不出层，交还原生。
        if !showsProviderFooter, Self.isPageSized(view) {
            writeDebugLog(
                "[WordByWord] ⚠️ preview host is page-sized"
                    + " (\(NSStringFromClass(type(of: view)))) — skipped"
            )
            return false
        }

        let overlayView = LyricsWordByWordOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.showsProviderFooter = showsProviderFooter
        overlayView.showsTranslation = showsTranslation
        // 全屏时这一层会把整页盖住（旧实现用的是**不透明**底色），原生的标题栏、
        // 进度条、播放键、收起键全在它下面 —— 不自己出按键就等于"全屏一个按键都没有"。
        // 预览不进这条路：卡片上那颗原生的展开/分享键就在我们层之上，够用。
        overlayView.showsPlaybackControls = showsProviderFooter
        // 全屏时背景改成"舞台式"：溢出到容器之外铺满整屏、均匀暗化。
        // 目的是让 Spotify 原有的 header / 控件栏和歌词落在同一块背景上，
        // 消除"品红壳 / 暗色肉"的割裂。内嵌预览保持卡片式。
        overlayView.setBackdropStyle(showsProviderFooter ? .stage : .card)
        overlayView.setSideInset(sideInset)
        view.addSubview(overlayView)
        // 挂到最前。
        //
        // ⚠️ 这个 `bringSubviewToFront` 与"会不会盖住 Spotify 原生界面"**无关** ——
        // 原生那一页（`ElementView`）不在这条视图链上，抬谁的层级都影响不到它。
        // 会不会盖住，只取决于这一层自己画不画东西：
        //   · 有逐词数据 → 画歌词 + 背景，此时理应盖住原生歌词（我们替换了它）；
        //   · 没有 → `configureBackdropIfNeeded` 与 `setCurrentTime` 的 guard 会把
        //     整层变透明并让触摸穿透，原生界面与控件原样可用。
        view.bringSubviewToFront(overlayView)

        overlay = overlayView
        hostView = view
        isAttached = true
        // ⚠️ 这两条以前只在 Apple Music 分支里写。旧层漏掉之后有两个后果：
        //   · `attachedShowsProviderFooter` 残留上一次的值 → 全屏时
        //     `refreshForCurrentLyrics()` 以为"现在是预览"，于是把全屏的层拽掉重挂；
        //   · `renderedLyricsVersion` 不更新 → 每次歌词版本变化都重挂一次（闪一下），
        //     而旧层本来就会在 `setCurrentTime` 里自己按版本号 rebuild。
        attachedShowsProviderFooter = showsProviderFooter
        renderedLyricsVersion = currentLyricsVersion

        // 旧 overlay 的时间回调（新层走 `tickHandler`，两者互斥）。
        //
        // ⚠️ 两个闭包都显式标 `@MainActor`：它们的目标
        // （`AppleMusicLyricsOverlayHost.tick`、`LyricsWordByWordOverlayView.setCurrentTime`）
        // 都是 main-actor 隔离的，而在 `attach`（已隔离）里创建的闭包**不会自动继承**
        // 隔离 —— 不标就是"在非隔离同步上下文调用 MainActor 隔离方法"。
        // 运行时无变化：时钟是 `CADisplayLink` 挂在 `.main` run loop 上的，本来就在主线程。
        WordByWordPlaybackClock.shared.onChange = { @MainActor [weak overlayView] ms in
            overlayView?.setCurrentTime(ms)
        }
        WordByWordPlaybackClock.shared.tickHandler = nil
        WordByWordPlaybackClock.shared.start()
        writeDebugLog(
            "[WordByWord] legacy overlay attached — host=\(NSStringFromClass(type(of: view)))"
                + " \(Int(view.bounds.width))x\(Int(view.bounds.height))"
                + " shell=\(showsProviderFooter)"
                + " sideInset=\(Int(sideInset))"
                // 这一档要看得见：`word` = 逐字高亮，`line` = 这首歌没有逐字时间轴、
                // 降级成"当前行整行点亮"（网易云 `yrc absent` 那一批就是它）。
                + " level=\(usable ? "word" : "line")"
        )
        return true
    }

    func detach() {
        guard isAttached else { return }
        WordByWordPlaybackClock.shared.stop()
        WordByWordPlaybackClock.shared.onChange = nil
        WordByWordPlaybackClock.shared.tickHandler = nil
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }
        overlay?.removeFromSuperview()
        overlay = nil
        hostView = nil
        isAttached = false
        writeDebugLog("[WordByWord] overlay detached")
    }

    // MARK: 关闭全屏的「静态替身」交接（C2）

    /// 关闭全屏时用：先给当前层拍一张**静态替身**留在原宿主（全屏页）上，
    /// 再把真正的 overlay 搬回内嵌卡片。
    ///
    /// 为什么必须这样：一个 overlay 视图没法同时挂在两个宿主上。直接在
    /// `viewWillDisappear` 里 `detach()` 的话，整段下滑动画期间全屏页露出的都是
    /// **Spotify 原生歌词 + 纯专辑色背景** —— 这就是"关闭时一闪"的成因。
    /// 留一张 `snapshotView` 顶替它在原位置的画面之后：
    ///   · 全屏页在整段关闭动画里仍是"我们的样子"（静态，但页面本来就在往下滑，看不出来）；
    ///   · 真正的层已经挂回内嵌卡片，卡片被露出来时也已经是我们的渲染。
    func handOffToInlineKeepingStandIn() {
        installStandIn()
        detach()
        reattachToInline()
    }

    /// 全屏页彻底消失后清掉替身。
    func removeStandIn() {
        guard let standIn = transitionStandInView else { return }
        standIn.removeFromSuperview()
        transitionStandInView = nil
        writeDebugLog("[Shell] stand-in removed")
    }

    /// 当前正在显示的那一层（Apple Music 层优先）。
    private var currentOverlayView: UIView? {
        if #available(iOS 26.0, *),
           let view = AppleMusicLyricsOverlayHost.shared.overlayView {
            return view
        }
        return overlay
    }

    // MARK: 预览卡片容器

    /// 预览卡片的容器。
    ///
    /// 历史：最初按"从歌词视图往上找第一个**比它高**的祖先"来判（因为实测
    /// `Lyrics_NPVCommunicatorImpl.CardView(374x300)` ← 歌词视图 `(374x261)`，
    /// 差 39pt 正好是卡片标题栏那一行，而"更高"比写死类名稳）。
    ///
    /// ⚠️ 这条判据太松，已经**出过真机事故**（日志 4）：
    /// `[PreviewShell] card container=UIView 366x432 lyrics=366x120` —— 它把
    /// **歌曲封面容器**当成了卡片（差 312pt），于是预览逐词层被挂到封面上，
    /// 而真正的卡片是 `Lyrics_CardElementImpl.CardView 374x320` ← `342x256`（差 64）。
    ///
    /// 所以现在按**证据强弱**排四条判据（见下），全不成立就返回 nil：
    /// 调用方据此**宁可不挂**，由看门狗在卡片建好之后再挂一次。
    ///
    /// 四条的顺序（每次都是被真机日志打回来才定下来的）：
    ///   ① `…CardView` 类名 —— 最硬；② 含标题栏按钮、且**尺寸仍像卡片**的最外层祖先
    ///   （日志 5：只取最近一层会挂到卡片内部的内容列上，比卡片小一圈）；
    ///   ③ 收紧的尺寸判据；④ 容器白名单。②③④ 都是"Spotify 改了名字"时的退路。
    static func cardContainer(for view: UIView) -> UIView? {
        // ① 类名：卡片本体。这是最硬的证据（名字就叫 CardView），而且它正是"整张卡片"
        //    那一层 —— 我们要盖住的就是它（含它自己的标题栏与四周留白）。
        //
        //    ⚠️ 必须排在"含标题栏按钮"那条**前面**：日志 5 实证，那条判据最近的命中是
        //    卡片内部的**内容列**（`UIStackView 342x304` = 标题行 + 歌词两行），
        //    挂上去比真卡片小一圈（真卡片 374x320）—— 表现就是"挂是挂上了，大小不对"：
        //    左右各留 16pt 粉边、上方还露出 Spotify 自己的「歌词」标题栏。
        if let card = ancestor(in: view, matching: Self.preferredCardClassNames) {
            return logAndReturnCardContainer(card, lyrics: view, label: "card")
        }

        // ② 语义：含歌词标题栏按钮、且尺寸仍然"像卡片"的**最外层**祖先。
        //    只在类名认不出来（Spotify 改名）时才会走到这里。
        if let card = ancestorCardSizedWithLyricsHeaderButtons(of: view) {
            return logAndReturnCardContainer(card, lyrics: view, label: "header buttons")
        }

        // ③ 尺寸（**收紧**）：卡片只比歌词内容高出一个标题栏的量级。
        //    只往上找 4 层：再往上就是滚动容器（cell / collection view），挂那儿就出界了。
        var current: UIView? = view.superview
        var depth = 0
        while let node = current, depth < 4 {
            let extra = node.bounds.height - view.bounds.height
            if extra >= Self.previewMinCardExtraHeight,
               extra <= Self.previewCardMaxExtraHeight,
               node.bounds.width >= view.bounds.width - 0.5 {
                return logAndReturnCardContainer(node, lyrics: view, label: "by size")
            }
            current = node.superview
            depth += 1
        }

        // ④ 既有白名单兜底：找不到卡片本体时退到通用容器，并且**取最外层**那一个
        //    （最接近整张卡片），而不是自下往上第一个命中的。同样要过高度上限 ——
        //    否则会把整页容器抓进来（那就是"预览变全屏"）。
        var outermost: UIView?
        var fallback: UIView? = view.superview
        var fallbackDepth = 0
        while let node = fallback, fallbackDepth < 12 {
            if Self.knownCardContainerClassNames.contains(NSStringFromClass(type(of: node))),
               node.bounds.height <= Self.previewCardMaxHeight {
                outermost = node
            }
            fallback = node.superview
            fallbackDepth += 1
        }
        if let outermost {
            return logAndReturnCardContainer(outermost, lyrics: view, label: "by class")
        }

        writeDebugLog(
            "[PreviewShell] ⚠️ no card container found — caller falls back to the content view"
        )
        dumpAncestorChain(from: view)
        return nil
    }

    /// 卡片相对歌词内容允许高出的范围：只比内容高一点（标题栏），不能是一个大容器。
    private static let previewMinCardExtraHeight: CGFloat = 4
    private static let previewCardMaxExtraHeight: CGFloat = 140
    /// 卡片相对歌词内容允许宽出的范围（左右各一点内边距，实测 16pt/侧）。
    private static let previewCardMaxExtraWidth: CGFloat = 60
    /// 卡片本体的合理高度上限：超过它就不是卡片，而是整页 / 滚动容器。
    private static let previewCardMaxHeight: CGFloat = 500

    /// 从 `view` 往上，取"含歌词标题栏按钮、且尺寸仍然像卡片"的**最外层**祖先。
    ///
    /// 为什么强调"最外层"：日志 5 实证，这类容器是**一层套一层**的 ——
    /// 最近的那层是卡片内部的"内容列"（`UIStackView 342x304` = 标题行 48 + 歌词 256），
    /// 外面才是真正的卡片（`Lyrics_CardElementImpl.CardView 374x320`）。
    /// 只取最近一层，挂出来的层就比卡片小一圈（左右各留 16pt、上方露出原生「歌词」标题栏）。
    ///
    /// 两个闸门都是"相对歌词内容"的（宽度 + 高度），一超就**停**：祖先只会越来越大，
    /// 一旦某一层超了（包住卡片的 cell / 滚动容器 / 整页），再往上没有意义。
    /// 高度另有一个绝对值上限（`previewCardMaxHeight`）兜底。
    private static func ancestorCardSizedWithLyricsHeaderButtons(of view: UIView) -> UIView? {
        var node: UIView? = view.superview
        var depth = 0
        var result: UIView?
        while let current = node, depth < 12 {
            let extraHeight = current.bounds.height - view.bounds.height
            let extraWidth = current.bounds.width - view.bounds.width
            guard current.bounds.height <= Self.previewCardMaxHeight,
                  extraHeight <= Self.previewCardMaxExtraHeight,
                  extraWidth <= Self.previewCardMaxExtraWidth else {
                break
            }
            // 等高/等宽的包装层不算候选，但要继续往上找（真卡片在它们外面）。
            if extraHeight >= Self.previewMinCardExtraHeight,
               containsLyricsHeaderButton(current) {
                result = current
            }
            node = current.superview
            depth += 1
        }
        return result
    }

    /// 子树里有没有歌词标题栏那一行（展开 / 分享）的按钮。
    ///
    /// 按**无障碍 id** 找：那是 Spotify 为 VoiceOver 维护的稳定标识，真机 dump 已确认
    /// （`lyrics-expand-button`「将歌词界面扩展至全屏」、`lyrics-share-button`「分享歌词」）。
    /// 不按标签找 —— 标签会随语言变。
    private static func containsLyricsHeaderButton(_ root: UIView) -> Bool {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if let control = view as? UIControl,
               let identifier = control.accessibilityIdentifier,
               Self.lyricsHeaderButtonIdentifiers.contains(identifier) {
                return true
            }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }

    private static let lyricsHeaderButtonIdentifiers: Set<String> = [
        "lyrics-expand-button",
        "lyrics-share-button",
    ]

    /// 兜底诊断：把从歌词视图往上 12 层的「类名 + 尺寸」全部打出来。
    ///
    /// 只要这条链出现在日志里，就能**一次性看出**真正的卡片容器是哪个类（以及它离
    /// 歌词视图有几层），不必再去翻 IPA 猜类名 —— 上一轮 `Lyrics_CardElementImpl.CardView`
    /// 就是这么找出来的。正常命中白名单时不会打这条，所以它出现即代表白名单仍需扩充。
    ///
    /// ⚠️ 带节流：宿主看门狗每 1.5s 就会重走一次这条路，而"卡片还没建出来"期间
    /// 这条 dump 会**一模一样地反复出现**（一次 13 行，`writeDebugLog` 是写文件的）。
    /// 同一条链 10s 内只记一次；链变了立刻记（那才是有用的信息）。
    private static func dumpAncestorChain(from view: UIView) {
        var lines: [String] = []
        var node: UIView? = view
        var depth = 0
        while let current = node, depth <= 12 {
            let frame = current.frame
            lines.append(
                "[PreviewShell] chain[\(depth)] "
                    + "\(NSStringFromClass(type(of: current))) "
                    + "\(Int(frame.width))x\(Int(frame.height))"
                    + (current === view ? "   ← lyrics view" : "")
            )
            node = current.superview
            depth += 1
        }

        let signature = lines.joined(separator: "|")
        let now = Date()
        if signature == lastChainDumpSignature,
           now.timeIntervalSince(lastChainDumpTime) < 10 {
            return   // 同一条链刚打过（看门狗每 1.5s 走一次这条路）—— 静默跳过
        }
        lastChainDumpSignature = signature
        lastChainDumpTime = now
        for line in lines { writeDebugLog(line) }
    }

    private static var lastChainDumpSignature: String = ""
    private static var lastChainDumpTime: Date = .distantPast

    /// 单槽诊断节流：同一条消息 `interval` 秒内只记一次。
    ///
    /// 与链 dump 各用一套槽位，互不干扰：两者会被同一段重试循环交替触发，
    /// 共用一个槽位等于谁都没被节流。
    private static var lastRejectionMessage: String = ""
    private static var lastRejectionTime: Date = .distantPast

    private static func logRejectionThrottled(_ message: String, interval: TimeInterval = 10) {
        let now = Date()
        if message == lastRejectionMessage,
           now.timeIntervalSince(lastRejectionTime) < interval {
            return
        }
        lastRejectionMessage = message
        lastRejectionTime = now
        writeDebugLog(message)
    }

    /// **卡片本体**：优先级高于其它所有容器。9.1.76 上是
    /// `Lyrics_CardElementImpl.CardView`（含标题栏 `CardHeaderView` + 内容区
    /// `CardContentView`）。我们必须挂在这一层，才能让自绘的壳盖住 Spotify 的标题栏。
    private static let preferredCardClassNames: Set<String> = [
        "Lyrics_CardElementImpl.CardView",
        "Lyrics_NPVCommunicatorImpl.CardView",
    ]

    /// 这个视图是不是"整页大小"（正在播放页 / 全屏页的根视图）。
    ///
    /// 预览层只允许挂在**卡片**上。一旦挂到整页，表现就是"预览变成了全屏"：
    /// 一块卡片背景铺满整个正在播放页，把原生界面（含卡片上那两颗按钮）全盖住 ——
    /// 这正是"退出全屏后预览变全屏"的机制（`reattachToInline` 旧实现拿
    /// `lastInlineController.view` 去当内容视图，那是整页的根视图）。
    ///
    /// 判据要求宽和高**同时**接近窗口：iPhone 上卡片约 374x300，
    /// iPad 上卡片只占一列 —— 两个方向都不会贴满窗口。
    /// 尺寸还来不及布局（bounds 为 0）或拿不到窗口时返回 false（不判断，保持旧行为）。
    static func isPageSized(_ view: UIView) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        guard let reference = referenceWindowSize(for: view) else { return false }
        return bounds.width >= reference.width * 0.75
            && bounds.height >= reference.height * 0.75
    }

    /// 这个视图现在**真的显示在屏幕上**吗。
    ///
    /// 用来否掉两类宿主：
    ///   · 离屏的复用视图（自适应表格 cell 回收后再没上屏，日志实证 `at(-293,887)`）；
    ///   · 尺寸还没收敛 / 被折叠的容器。
    ///
    /// 判据：在窗口里、没被隐藏、尺寸像个歌词区（宽 > 120、高 > 60）、
    /// 中心点在窗口内、且至少一半面积可见。
    static func isVisibleOnScreen(_ view: UIView) -> Bool {
        guard let window = view.window,
              window.bounds.width > 1,
              window.bounds.height > 1 else { return false }
        guard !view.isHidden, view.alpha > 0.01 else { return false }

        let frame = view.convert(view.bounds, to: window)
        guard frame.width > 120, frame.height > 60 else { return false }
        guard window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }

        let visible = frame.intersection(window.bounds)
        guard !visible.isNull, !visible.isEmpty else { return false }
        return visible.width * visible.height >= frame.width * frame.height * 0.5
    }

    /// 判断尺寸用的参照（优先该视图自己所在的窗口，其次当前 key window）。
    private static func referenceWindowSize(for view: UIView) -> CGSize? {
        if let size = view.window?.bounds.size, size.width > 1, size.height > 1 {
            return size
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        guard let size = window?.bounds.size, size.width > 1, size.height > 1 else { return nil }
        return size
    }

    /// 从 `view` 往上找第一个（也是最近的）匹配 `names` 的祖先。
    private static func ancestor(in view: UIView, matching names: Set<String>) -> UIView? {
        var node: UIView? = view.superview
        var depth = 0
        while let current = node, depth < 12 {
            if names.contains(NSStringFromClass(type(of: current))) { return current }
            node = current.superview
            depth += 1
        }
        return nil
    }

    private static func logAndReturnCardContainer(
        _ container: UIView,
        lyrics: UIView,
        label: String
    ) -> UIView {
        writeDebugLog(
            "[PreviewShell] card container (\(label))="
                + "\(NSStringFromClass(type(of: container)))"
                + " \(Int(container.bounds.width))x\(Int(container.bounds.height))"
                + " lyrics=\(Int(lyrics.bounds.width))x\(Int(lyrics.bounds.height))"
        )
        return container
    }

    /// 通用容器兜底（只在找不到卡片本体时使用；调用方取**最外层**命中者）。
    ///
    /// ⚠️ 只列歌词自己的容器；**不要**把滚动容器、`NPVScrollViewController` 一类加进来，
    /// 那会重新变成铺满整页。
    private static let knownCardContainerClassNames: Set<String> = [
        // 元素框架的包装层
        "Lyrics_NPVElementsKitImpl.LyricsElementContainerView",
        "Lyrics_NPVElementsKitImpl.LyricsElementWrapperView",
        "Lyrics_NPVContainerKit.LyricsContainerView",
        // 自适应表格 cell（预览歌词所在的 cell）
        "Lyrics_TextElementImpl.LyricsCell",
        "Lyrics_TextComponentImpl.LyricsCell",
        "Lyrics_TextElementSingalongImpl.LyricsCell",
        // 卡片内容区：比卡片本体小（不含标题栏），仅作最后备选
        "Lyrics_CardElementImpl.CardContentView",
    ]

    private func installStandIn() {
        removeStandIn()

        guard let host = hostView,
              let current = currentOverlayView,
              let snapshot = current.snapshotView(afterScreenUpdates: false) else {
            writeDebugLog("[Shell] ⚠️ stand-in unavailable (no host / view / snapshot)")
            return
        }

        // 与原层同位置、同层级：插在它上面，就等于接替了它原来占的那一层
        // （原生控件在我们之上，替身也在我们之上，层级关系不变）。
        snapshot.frame = current.frame
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        host.insertSubview(snapshot, aboveSubview: current)
        transitionStandInView = snapshot
        writeDebugLog("[Shell] stand-in installed for dismissal")
    }
}

// MARK: - 挂载 hook（全屏歌词 VC）
//
// ⚠️⚠️ **绝对不要在这些覆写方法（或 hook 类）上写 `@MainActor`。**
//
// Orion 的代码生成器是按**源码文本**拼接的：给覆写方法加 `@MainActor`，生成的
// `EeveeSpotify.xc.swift` 里会拼出 `@MainActoroverride` 这种非法属性，`override`
// 关键字也一起丢掉，整个文件报一串语法错误；而且它生成的 C 跳板是非隔离的，
// 同步调用被标成 `@MainActor` 的方法又构成隔离违规。
//
// 正确的写法：方法保持非隔离，**在方法体里**用 `onMainThreadSync { }`
// （定义在 `LyricsChromeVisibility.swift`）把"这是主线程"表达出来。
// 它已经是主线程时是同步执行的，不改变任何时序；`viewWillDisappear` 里的清理
// 因此仍然是同步的。
//
// 顺带：**内嵌（预览）**那两处沿用原有的 `DispatchQueue.main.async` 延后一拍再挂载，
// 写在 `onMainThreadSync` 里面；**全屏**那两处已改到 `viewWillAppear` 里直接挂 ——
// 多拖一拍会让转场动画期间露出 Spotify 自己的全屏歌词（"进入时一闪"）。

class LyricsWordByWordModernHostHook: ClassHook<UIViewController> {
    // `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 在 9.1.x 上不存在
    // （真机日志 targetNotFound）→ 隔离组，永不激活。
    // 影响：内嵌（NPV）逐词歌词在 9.1.x 上不可用；9.1.x 可用的宿主是
    // LyricsWordByWordFullscreenModernHostHook 的 FullscreenElementViewController。
    typealias Group = V91UnavailableLyricsGroup
    static let targetName = "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

class LyricsWordByWordLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static let targetName = "Lyrics_CoreImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

// MARK: - 全屏歌词挂载 hook（点击歌词框架展开后铺满的页面）

class LyricsWordByWordFullscreenModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂载点：**整屏的 vc.view**，除此之外什么都不做。
        //
        // 这里曾经把 overlay 挂到「歌词内容」子模块
        // `Lyrics_FullscreenElementPageImpl.LyricsView`（frame=0,104 414x570），
        // 后果是背景只能铺在 570pt 的容器内、容器边界上留一道"壳 / 肉"接缝 ——
        // 这是要消除的东西，所以改成挂整屏。
        //
        // ⚠️ 但"挂整屏"必须配上"不碰原生视图"。中间我试过更激进的一版
        // （隐藏歌词容器 + 把整层插到最底 + 清宿主底色），真机结果是**整页空白、
        // Spotify 菜单全没了**。原因见 `attach` 里的说明：这一页的 header / 歌词 /
        // 控件栏都不是 vc.view 的直接子视图，藏一个就等于藏整页。
        // 所以现在：原生 UI 一个都不动，靠我们自己的背景够暗来盖住它。
        // 全屏左边距用 24（贴近 Spotify 原生歌词内容的 24pt 内缩）
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`：前者是**转场动画播完**
        // 才回调的，所以之前整段上滑动画期间露出的都是 Spotify 自己的全屏歌词
        // （纯专辑色背景 + 原生歌词），动画结束我们的层才贴上去 —— 就是"进入时一闪"。
        // 同时去掉 `DispatchQueue.main.async` 那一拍：它原本是"等布局"，而这一层的
        // 约束贴死 vc.view 四边，布局变化会自动跟随，不需要等。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底：万一 viewWillAppear 时逐词数据还没就绪（歌词仍在路上），这里再挂一次。
            // 已经挂在同一宿主上时 `attach` 会直接 return，不会闪。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 全屏以 sheet 形式盖在内嵌之上，关闭时内嵌 VC 不会重新 viewDidAppear；
            // 用记住的内嵌 VC 把 overlay 挂回去。
            //
            // C2：交接前先在全屏页上留一张静态替身 —— 否则整段下滑动画期间露出的
            // 是 Spotify 原生歌词 + 纯专辑色背景，也就是"关闭时一闪"。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            // 关闭动画结束，替身可以撤掉了。
            WordByWordHost.shared.removeStandIn()
        }
    }
}

class LyricsWordByWordFullscreenLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        }
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂到 vc.view（整屏）。
        //
        // ⚠️ 这里以前会取 `Ivars<UIView>(vc.view).headerView` 并当作
        // `keepAboveView` 传下去，想让原生 header 浮在我们的 overlay 之上。
        // 那个做法已被证伪，参数整个删掉了：
        //   · Modern 全屏页上根本没有这个 ivar（`Ivars` 访问不存在的 ivar 是会崩的，
        //     靠的只是"老版本上恰好存在"这种运气）；
        //   · 就算取到，原生控件也不在这条视图链上，抬层级影响不到它们。
        //
        // 现在旧 overlay 的显隐完全由"有没有逐词数据"决定：有就画（盖住原生歌词），
        // 没有就整层透明 + 触摸穿透（原生界面与控件原样可用）。
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`（同 modern hook）：
        // 避免转场动画期间露出 Spotify 自己的全屏歌词。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底重挂：已经挂在同一宿主上时 `attach` 会直接 return。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 同 modern hook：留静态替身 + 把 overlay 挂回内嵌歌词 VC。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.removeStandIn()
        }
    }
}
