import Orion
import SwiftUI

struct BaseLyricsGroup: HookGroup { }
struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }

var lyricsState = LyricsLoadingState()
var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()
private let amllTtmlLyricsRepository = AmllTtmlLyricsRepository.shared

// 已移除：`forcedGoodLines` / `forcedGoodDto()`（配合 `forcedLyricsPayload` 排障开关）。
//
// 保留结论、不留代码：那次实验证明了 **卡片（与「关于艺人」并列那块）是被我们注入的
// payload 驱动的** —— 卡片底部显示的 provider 是 `EeveeForce…`，即我们自己写死的名字。
// 且 `timeSynchronized = false` 会建卡片，`true` 则 Spotify 走单行表现而不建卡片。
// 加入它之后出现稳定复现的启动崩溃，故整体回退；详见
// `UserDefaults+Extension.swift` 末尾的说明。

private func lyricsRepository(for source: LyricsSource) -> LyricsRepository {
    switch source {
    case .genius: return geniusLyricsRepository
    case .lrclib: return LrclibLyricsRepository.shared
    case .musixmatch: return MusixmatchLyricsRepository.shared
    case .petit: return petitLyricsRepository
    case .spicy: return SpicyLyricsRepository.shared
    case .netease:
        return NeteaseLyricsRepository.shared
    case .amllTtml:
        return amllTtmlLyricsRepository
    case .notReplaced, .multiLevel:
        // Never actually reached — callers filter these out beforehand.
        return geniusLyricsRepository
    }
}

// 两种回退模式共用：处理 Musixmatch 相关错误弹窗
//
// ⚠️ 每条分支的**两个方向都要记日志**：因为这两个弹窗各只有一次机会
// （`hasShownXxxPopUp` 一旦置位就再也不会弹）。排查"用户说没看到弹窗"时，
// 只记"弹了"是不够的 —— 必须能区分"这次被抑制了"和"这次压根没走到这里"。
private func handleLyricsErrorPopUp(_ error: LyricsError?) {
    switch error {
    case .invalidMusixmatchToken:
        if !hasShownUnauthorizedPopUp {
            writeDebugLog("[Lyrics] popup: Musixmatch unauthorized (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "musixmatch_unauthorized_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownUnauthorizedPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: Musixmatch unauthorized (already shown once — suppressed)")
        }
    case .musixmatchRestricted:
        if !hasShownRestrictedPopUp {
            writeDebugLog("[Lyrics] popup: Musixmatch restricted (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "musixmatch_restricted_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownRestrictedPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: Musixmatch restricted (already shown once — suppressed)")
        }
    default:
        break
    }
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    guard let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack else {
        throw LyricsError.noCurrentTrack
    }

    let searchQuery = LyricsSearchQuery(
        title: track.trackTitle(),
        primaryArtist: EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName(),
        spotifyTrackId: track.trackIdentifier,
        durationMs: track.trackDurationMilliseconds
    )

    let options = UserDefaults.lyricsOptions
    lyricsState = LyricsLoadingState()
    writeDebugLog("[Lyrics] Track \"\(searchQuery.title)\" - \(searchQuery.primaryArtist) (id \(searchQuery.spotifyTrackId))")
    if let durationMs = searchQuery.durationMs {
        writeDebugLog("[Lyrics] Track duration \(durationMs)ms (from metadata)")
    } else {
        writeDebugLog("[Lyrics] Track duration unavailable — NetEase duration gate skipped")
    }

    // 已移除：`forcedLyricsPayload` 排障短路（连同它用的 `forcedGoodLines`）。
    // 加入之后出现稳定复现的启动崩溃，见 `UserDefaults+Extension.swift` 末尾的说明。

    // lyricsSource == .multiLevel -> 固定顺序多级回退（并发 + 超时）
    // 其它来源 -> 用户选择的单一源 + 可选 Genius 回退
    var source = UserDefaults.lyricsSource
    if source == .multiLevel {

        writeDebugLog("[Lyrics] Multi-level fallback enabled")
        let attempts: [LyricsSource] = [.musixmatch, .petit, .lrclib, .genius]
        for (index, source) in attempts.enumerated() {
            writeDebugLog("[Lyrics] Attempt \(index + 1)/\(attempts.count): \(source.description)")
            let isLastAttempt = index == attempts.count - 1
            let requestTimeout: TimeInterval =
                source == .musixmatch || source == .petit ? 5.0 : 3.0

            let semaphore = DispatchSemaphore(value: 0)
            var resultDto: LyricsDto?
            var requestError: Error?

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    resultDto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options)
                } catch {
                    requestError = error
                }
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + requestTimeout)

            if waitResult == .timedOut {
                writeDebugLog("[Lyrics] \(source.description) timed out after \(requestTimeout)s")
                // Genius 失败（含超时）不再兜底为空歌词，统一走下面的抛错逻辑
                if index == 0 { lyricsState.fallbackError = .unknownError }
                if isLastAttempt { throw LyricsError.unknownError } else { continue }
            }

            if let dto = resultDto {
                writeDebugLog("[Lyrics] \(source.description) returned \(dto.lines.count) line(s)")
                storeLyricsDto(dto, source: source)
                lyricsState.isEmpty = dto.lines.isEmpty
                lyricsState.wasRomanized = dto.romanization == .romanized
                    || dto.romanization == .canBeRomanized
                lyricsState.loadedSuccessfully = true

                return Lyrics.with {
                    $0.data = dto.toSpotifyLyricsData(
                        source: source.description,
                        useInstrumentalPlaceholder: source != .genius,
                        // 无时间轴的源（Genius 等）靠它把行铺到曲目时长上，
                        // 否则 9.1.x 会判为"不可用"→ 歌词模块不出现。
                        durationMs: searchQuery.durationMs
                    )
                }
            } else if let error = requestError {
                writeDebugLog("[Lyrics] \(source.description) failed: \(error)")
                let lyricsError = error as? LyricsError
                if source != .genius {
                    if index == 0 { lyricsState.fallbackError = lyricsError ?? .unknownError }
                    handleLyricsErrorPopUp(lyricsError)
                }

                // Genius 失败（含查无此曲）直接抛出，不再兜底为空歌词
                if isLastAttempt {
                    throw error
                } else {
                    continue
                }
            } else {
                if isLastAttempt {
                    throw LyricsError.unknownError
                } else {
                    continue
                }
            }
        }

        throw LyricsError.unknownError

    } else {

        writeDebugLog("[Lyrics] Single source: \(source.description)")

        if source == .notReplaced {
            throw LyricsError.invalidSource
        }

        // 已删除「AMLL 优先」（2026-09-25，用户反馈"感觉没什么用"）。
        //
        // 它原本是"先向 AMLL 要逐词歌词、判定为逐词可用才采用、否则回退到用户选的源"。
        // 现在 AMLL 就只是来源选择器里的一个普通来源：选它 → 只查它（加上可选的 Genius 兜底），
        // 与其它来源完全同一条路。这样少一层"看起来像设置没生效"的分支。

        let result = try requestSingleSource(
            source,
            searchQuery: searchQuery,
            options: options,
            recordFallbackError: true
        )

        return makeLyrics(
            from: result.dto,
            source: result.source,
            durationMs: searchQuery.durationMs
        )
    }
    }

    // MARK: - 单源请求

    /// 一次单源请求的产物：歌词数据 + **实际**产出它的源。
    ///
    /// 为什么要显式带着"实际源"：这个方法在失败时会用 Genius 兜底重试，此时
    /// 返回的是 Genius 的歌词，而调用方传进来的 `source` 是用户设的那个源。
    /// 只回传 dto 的话，来源标签就会写成用户设的那个（真机上表现为
    /// 「明明拿的是 Genius 的歌词，底部却写着 PetitLyrics」）。
    private struct SourceLyricsResult {
        let dto: LyricsDto
        let source: LyricsSource
    }

    /// 按用户设置请求单一来源。保持既有行为不变：
    /// - 该源的错误会写入 `lyricsState.fallbackError`（`recordFallbackError`）并弹 MxM 相关弹窗；
    /// - 非 Genius 源失败且 `options.geniusFallback` 开启时，再用 Genius 重试一次。
    ///
    /// - Parameter allowGeniusFallback: 为 false 时跳过 Genius 兜底。
    ///   ⚠️ 目前**没有调用方传 false** —— 原先唯一那个是已删除的「AMLL 优先」回退链。
    ///   所以它现在等价于恒为 true；参数保留是因为语义仍然成立（"这条链要不要 Genius 兜底"）。
    private func requestSingleSource(
        _ source: LyricsSource,
        searchQuery: LyricsSearchQuery,
        options: LyricsOptions,
        recordFallbackError: Bool,
        allowGeniusFallback: Bool = true
    ) throws -> SourceLyricsResult {
        let repository = source == .genius
            ? geniusLyricsRepository
            : lyricsRepository(for: source)

        do {
            return SourceLyricsResult(
                dto: try repository.getLyrics(searchQuery, options: options),
                source: source
            )
        } catch let error {
            // 单源模式以前只打一句「failed — falling back to Genius」，具体错误被丢掉，
            // 日志里看不出是网络失败、授权失败还是解析失败。
            writeDebugLog("[Lyrics] \(source.description) failed: \(error)")

            if recordFallbackError {
                if let error = error as? LyricsError {
                    lyricsState.fallbackError = error
                    handleLyricsErrorPopUp(error)
                } else {
                    lyricsState.fallbackError = .unknownError
                }
            }

            // 注意顺序：Genius 失败不再兜底为空歌词（与既有行为一致）。
            if !allowGeniusFallback || !options.geniusFallback {
                throw error
            }

            writeDebugLog("[Lyrics] \(source.description) failed — falling back to Genius")
            // Genius 兜底源同样直接抛错，不再兜底为空歌词。
            // ⚠️ 回传的 `source` 必须是 `.genius`：这份 dto 是 Genius 给的，
            // 来源标签也得写 Genius（写用户设的那个源就是"注解显示 PetitLyrics"）。
            return SourceLyricsResult(
                dto: try geniusLyricsRepository.getLyrics(searchQuery, options: options),
                source: .genius
            )
        }
    }

    // MARK: - DTO → Lyrics

    /// 自造一套可读的歌词配色（拿不到 Spotify 原始颜色时用）。
    ///
    /// **两条路径共用**：真实歌词（`makeLyrics` 里那段）与占位 payload
    /// （`makeUnavailableLyrics`）。必须共用 —— 2026-09-25 日志 21 / 照片 09:09 的教训：
    /// 占位那一支原本"`originalColors` 为 nil 就什么都不设"，于是 404 曲目
    /// （Spotify 自己没词，必然没有 `originalColors`）的卡片与全屏页在**颜色字段全空**时
    /// 被渲染成纯黑；而能取到词的曲目因为走了另一支，已经修好了。
    ///
    /// 产出**中明度不透明面板 + "未唱黑 / 已唱白"** —— 与 Spotify、以及我们自己的逐词
    /// overlay 同一套语义（`lineColor` 管未唱、`activeLineColor` 管已唱/当前行）。
    /// ⚠️ 这两个字段不能一起改：都设黑 = 整片全黑，都设白 = 整片全白（真机都踩过）。
    func synthesizedLyricsColors() -> LyricsColors {
        let settings = UserDefaults.lyricsColors
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack

        let extractedColor: String? = switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            track?.extractedColorHex()
        default:
            track?.metadata()["extracted_color"]
        }

        // 这里只算出"这首歌的底色"本身；归一化放到下面**一处**做（不要两处，
        // 否则读的人无法判断最终明度到底由谁决定）。
        var color: Color
        if settings.useStaticColor {
            color = Color(hex: settings.staticColor)
        } else if let extractedColor {
            color = Color(hex: extractedColor)
        } else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
        } else {
            color = Color.gray
        }

        // 面板：album 主色归一化到中明度，**保持不透明**。
        // 不能像原来那样把 alpha 清掉（那会露出卡片默认黑底）；也不该压得很暗 ——
        // 因为下面的字色是"未唱黑 / 已唱白"，黑字需要中明度以上的底才看得见。
        let panel = color.normalized(settings.normalizationFactor)

        // 字色沿用**最初那套约定**（也就是我们自己 overlay 的约定，见 `LyricsWordByWord`：
        // `index <= activeIndex ? activeLineColor : lineColor`）：
        //   · 未唱到的行   = `lineColor`       = 黑
        //   · 已唱 / 正在唱 = `activeLineColor` = 白
        //
        // 真机教训（2026-09-25）：这两个字段一个管"未唱"、一个管"已唱"，**不能一起改** ——
        // 两个都设黑 → 卡片与全屏页整片全黑；两个都设白 → 整片全白
        // （反馈原话："正常来讲是未唱到的行才黑色，其他的白色"）。
        let palette = LyricsColors.with {
            $0.backgroundColor = panel.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
        // 两条路径共用这个函数，所以这条日志同时覆盖"真实歌词"与"占位 payload"
        // （后者以前完全没有颜色、也没有日志，占位曲目的黑块就是那么来的）。
        writeDebugLog(
            String(
                format: "[Lyrics] synthesized card colors — panel=%08X line=%08X active=%08X",
                palette.backgroundColor, palette.lineColor, palette.activeLineColor
            )
        )
        return palette
    }

    /// 「取不到我们的歌词」时交给 Spotify 的替身 payload —— 目的是**不让 Spotify 把
    /// 它自己的官方歌词显示出来**。
    ///
    /// 背景：取词失败时钩子原本走 `customLyricsData ?? buffer`，也就是把 Spotify 的原始
    /// 响应原样放行。于是界面（歌词卡片 / 全屏页）显示的是 **Spotify 自己的歌词**：
    /// 日区那一批的来源写着「プチリリ」——Spotify 的日文歌词供应商，**不带 (EeveeSpotify)
    /// 后缀**（这就是"看着像 PetitLyrics 又不是"的原因），而且它是官方歌词，
    /// 不会跟着我们的罗马化设置走。
    ///
    /// 返回 nil 表示**不替换**（继续用 Spotify 自己的歌词）。此时是三种情况之一：
    ///   · 用户在来源里选了「禁用歌词替换」（`notReplaced`）—— 那就是明确要看官方歌词；
    ///   · 「隐藏 Spotify 官方歌词」开关关着；
    ///   · 歌词功能整体被禁用。
    private func unavailableLyricsPayload(original: Lyrics?) -> Lyrics? {
        guard !NgzhwmSettingsViewModel.isLyricsFeatureDisabled,
              UserDefaults.lyricsSource != .notReplaced,
              NgzhwmSettingsViewModel.isOfficialLyricsHidden else {
            return nil
        }

        return makeUnavailableLyrics(originalColors: original?.colors, note: nil)
    }

    /// 构造「没有歌词」的替身 payload —— 与 `unavailableLyricsPayload` 同一份内容，
    /// 但不带任何用户开关判断：**调用方已经决定"必须给出一个响应"**。
    ///
    /// 抽出来的原因：现在有两个调用方，一个是下面这个"要不要替换官方歌词"的策略判断，
    /// 另一个是 URLSession 侧的"响应兜底"（见 `unavailableLyricsBytes`）。
    /// 两处必须长得一模一样，否则用户会在不同失败路径上看到不同文案。
    ///
    /// - Parameter note: 有值时**追加一行**说明（例如"这首歌正在切换"）。
    ///   传 nil 时只有一行"未找到歌词"（历史上是三行：通知 + 空行 + 提示行；
    ///   提示行 `ngzhwm_lyrics_unavailable_hint` 已于 2026-09-25 连同中文本地化一起删除）。
    func makeUnavailableLyrics(originalColors: LyricsColors?, note: String?) -> Lyrics {
        // 占位文案也要有行级时间轴。
        //
        // 理由与 `toSpotifyLyricsData` 相同：这个版本把"无时间轴"判为不可用，
        // 而占位恰恰是"取不到词"那条路上唯一交出去的东西 —— 没有时间轴就等于
        // 连"未找到歌词"都显示不出来，用户看到的是**彻底没有歌词模块**。
        // ⚠️ 2026-09-25：`ngzhwm_lyrics_unavailable_hint`（"可以在设置里换一个歌词来源…"）
        // 已随中文本地化一起删除 —— 占位现在只有"未找到歌词"一行（`note` 有值时追加一行）。
        // 只删文案、留代码的话，两个 locale 都拿不到这个 key，界面会直接把 key 名当文案显示。
        // 要把提示加回来：恢复下面那行 `LyricsLineDto(content: "…_hint".localized)`，
        // 并在 en / zh-CN 两个 `Localizable.strings` 里补回该 key。
        var placeholderLines = [
            LyricsLineDto(content: "ngzhwm_lyrics_unavailable".localized)
        ]
        if let note, !note.isEmpty {
            placeholderLines.append(LyricsLineDto(content: note))
        }

        if NgzhwmSettingsViewModel.isSyntheticLineTimingEnabled {
            placeholderLines = SyntheticLyricTiming.applying(
                to: placeholderLines,
                durationMs: currentTrackDurationMs
            )
        }

        return Lyrics.with {
            $0.data = LyricsData.with {
                // 合成过时间轴 → 如实声明；否则保持旧的"无时间轴"语义。
                $0.timeSynchronized = placeholderLines.contains { ($0.offsetMs ?? 0) > 0 }
                $0.restriction = .unrestricted
                // 署名是我们自己：界面上那一行来源不会再写成别人的品牌。
                $0.providedBy = "EeveeSpotify"
                $0.lines = placeholderLines.map { line in
                    LyricsLine.with {
                        $0.content = line.content
                        $0.offsetMs = Int32(line.offsetMs ?? 0)
                    }
                }
            }
            // 颜色：有 Spotify 原来那份就沿用（背景色 / 歌名配色保持原样，看不出被替换过）；
            // **没有的时候必须自己造一套** —— 404 曲目（Spotify 自己没词）必然没有
            // `originalColors`，而 `colors` 空着会让卡片与全屏页渲染成**纯黑**：
            // 真机 2026-09-25 09:09（NIGHT VIBE）+ 日志 21 正是这个组合（那一批曲目全都
            // 是 `[NetEase] No usable lyrics` → `serving our placeholder`），
            // 而同一份日志里能取到词的曲目已经有 `keeping synthesized background opaque` 生效。
            $0.colors = originalColors ?? synthesizedLyricsColors()
        }
    }

    // MARK: - 「绝不空手而归」的响应兜底
    //
    // `unavailableLyricsBytes` 是文件作用域函数（见本文件 `getLyricsDataForCurrentTrack` 上方）：
    // 调用方是 URLSession 的两个钩子，属"这次响应交什么字节"的纯数据问题。

    /// 把 dto 落到全局状态上（**唯一**写入口）。
    ///
    /// 两件事必须一起做，而且是同一个顺序：
    ///   1. 提供者写进 dto 本身（`providerName`）并同步 `currentLyricsProvider`；
    ///   2. `currentLyricsVersion` 自增并通知逐词 overlay 重挂。
    ///
    /// 以前第 1 步散在 `getLyricsDataForCurrentTrack` 的**末尾**（在 dto 写完之后），
    /// 所以"旧 overlay 在 rebuild 时读到上一首的提供者"这种慢一拍是必然会发生的；
    /// 现在提供者与 dto 是同一时刻写下的，不可能错配。
    private func storeLyricsDto(_ dto: LyricsDto, source: LyricsSource) {
        var dto = dto
        dto.providerName = "\(source.description) (EeveeSpotify)"

        let overlayDto = dto.romanizedForWordByWordIfEnabled()
        currentLyricsDto = overlayDto
        // ⚠️ 提供者要在**版本号自增之前**写好：观察者（两个 overlay 层）都是
        // 盯着版本号决定要不要重建的，版本一变它们就会立刻读 `currentLyricsProvider`。
        currentLyricsProvider = overlayDto.providerName
        currentLyricsVersion += 1
        writeDebugLog("[Lyrics] provider: \(overlayDto.providerName)")

        // 数据到达即刷新逐词 overlay：9.1.x 上内嵌宿主是 NPV，
        // 它只在进入正在播放页时出现一次，不会因为这首歌词到了再来一次。
        // `WordByWordHost` 是 @MainActor 隔离的，必须经 `onMainThreadSync` 这个
        // 本模块既有的桥进入（ng 的 hook 里也都是这么写的）。
        onMainThreadSync {
            WordByWordHost.shared.refreshForCurrentLyrics()
        }
    }

    /// 上一次**已经装上/清空**的逐词层对应的曲目 id（切歌信号，见调用点）。
    ///
    /// 用途：把"切歌"这件事从"新歌词到达"里解耦出来。理由与 `AppleMusicLyricsOverlay`
    /// 里 `currentModelTrackId` 的说明相同 —— 那边负责**渲染前**兜底，这边负责**尽早**清掉。
    var lyricsLayerTrackId: String?

    /// 把逐词层的全局状态清空，并把已经挂上的层摘掉。
    ///
    /// 用于"这一首没有我们的歌词"（取词失败 / 用户选了 `notReplaced`）：
    /// 旧层的 `setCurrentTime` 与新层的 `update()` 都以"有没有可用数据"为准，
    /// 数据一清：
    ///   · 旧层整块透明 + 触摸穿透 → 原生歌词与控件原样可用；
    ///   · 新层因为没有行模型而 `detach()` → 同上。
    ///
    /// - Parameter reason: 日志里那句原因。默认保持历史文案（取词失败那条路）；
    ///   切歌时传 "track changed…"，这样日志一眼能分清是"没词"还是"换歌"。
    private func resetWordByWordLyrics(reason: String = "no custom lyrics for this track") {
        writeDebugLog("[Lyrics] \(reason) — clearing word-by-word layer")
        currentLyricsDto = nil
        currentLyricsProvider = ""
        currentLyricsVersion += 1
        onMainThreadSync {
            WordByWordHost.shared.clearForUnavailableLyrics()
        }
    }

    /// 把来源返回的 DTO 转成注入 Spotify 的 `Lyrics`，并同步全局状态
    /// （`currentLyricsDto` / `currentLyricsVersion` / `currentLyricsProvider` / `lyricsState`）。
    ///
    /// - Parameter source: **实际**产出这份 dto 的源（Genius 兜底时是 `.genius`，
    ///   不是用户设的那个）。来源标签与注入给 Spotify 的 `providedBy` 都用它。
    /// - Parameter durationMs: 曲目时长，用于给无时间轴的源合成行级时间轴（见
    ///   `SyntheticLyricTiming`）。为 nil 时按每行估时兜底。
    private func makeLyrics(
        from dto: LyricsDto,
        source: LyricsSource,
        durationMs: Int? = nil
    ) -> Lyrics {
        lyricsState.isEmpty = dto.lines.isEmpty
        lyricsState.wasRomanized = dto.romanization == .romanized
            || dto.romanization == .canBeRomanized
        lyricsState.loadedSuccessfully = true

        storeLyricsDto(dto, source: source)

        return Lyrics.with {
            $0.data = dto.toSpotifyLyricsData(
                source: source.description,
                useInstrumentalPlaceholder: source != .genius,
                durationMs: durationMs
            )
        }
    }

// MARK: - 「绝不空手而归」的响应兜底

/// URLSession 钩子侧的兜底 payload 计数器（只为了不在日志里刷屏）。
private var urlSessionFallbackCount = 0

/// 歌词请求的**响应兜底**：只要 URL 是 `color-lyrics/v2`，钩子就必须交给 Spotify
/// 一个可解析的 `Lyrics` —— 这是 910 时代 `InterceptionContext` 那条底线。
///
/// 为什么必须有它：9.1.x 的 NPV 歌词卡片是**等歌词数据到达才创建**的
/// （`CustomLyrics+AllTracksLyrics.x.swift` 里 `NPVScrollViewController.viewWillAppear`
/// 的说明）。如果某个失败路径让这次请求"什么都不返回"（`didCompleteWithError` 只报
/// completion、不投递数据），Spotify 就不会建卡片；而没有卡片，连全屏歌词页的入口
/// 也不存在 —— 用户看到的就是"这首歌没有歌词模块"，比"有模块但写着未找到歌词"严重得多。
///
/// 放在文件作用域（而不是 `CustomLyrics` 扩展里）：调用方是 URLSession 那两个钩子，
/// 它们拿到的是"这次响应到底交什么字节"这个纯数据问题，跟歌词仓库的加载逻辑无关。
/// 里面也不读任何用户开关 —— 「隐藏 Spotify 官方歌词」只决定**要不要顶掉官方歌词**，
/// 不决定"能不能一个字节都不给"。
///
/// - Parameter original: Spotify 原始响应解析出来的歌词（可能是 200 的官方歌词，
///   也可能因为 404 而没有）。它只用来**沿用配色**，内容一律用我们自己的占位。
/// - Parameter note: 追加说明行，见 `CustomLyrics.makeUnavailableLyrics`。
/// - Returns: 可直接投给 `didReceiveData` 的字节；只有序列化失败这种理论上不会发生的
///   情况才返回 nil（那时调用方退回原始响应）。
func unavailableLyricsBytes(original: Lyrics?, note: String? = nil) -> Data? {
    var lyrics = makeUnavailableLyrics(originalColors: original?.colors, note: note)
    // 404 场景下没有原始歌词可继承配色，给一套中性配色，
    // 避免客户端拿到全 0 颜色把整页刷成纯黑。
    if original == nil {
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = 0xFF12_1212
            $0.lineColor = 0xFF9E_9E9E
            $0.activeLineColor = 0xFFFF_FFFF
        }
    }

    guard let data = try? lyrics.serializedBytes() as Data else {
        writeErrorLog("[Lyrics] fallback payload failed to serialize — lyrics response will be dropped")
        return nil
    }

    urlSessionFallbackCount += 1
    if urlSessionFallbackCount <= 5 || urlSessionFallbackCount % 20 == 0 {
        writeDebugLog("[Lyrics] serving fallback payload for this response (#\(urlSessionFallbackCount))")
    }
    return data
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    writeDebugLog("[Lyrics] Request for \(originalPath)")
    guard !NgzhwmSettingsViewModel.isLyricsFeatureDisabled else {
        writeDebugLog("[Lyrics] Feature disabled — refusing")
        // 功能被关掉时同样要把逐词层清干净：否则它会继续盖着原生歌词显示旧内容。
        resetWordByWordLyrics()
        throw LyricsError.invalidSource
    }

    // 非阻塞状态同步机制（来自版本1，两种回退模式下均保留生效）
    // 解决启动/切歌时 track 状态尚未更新导致的 noCurrentTrack 与 trackMismatch 问题。
    var track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    var trackIdentifier = track?.trackIdentifier ?? ""
    let maxWaitTime: TimeInterval = 1.0
    let startTime = Date()

    while Date().timeIntervalSince(startTime) < maxWaitTime {
        let isReady = track != nil &&
            (trackIdentifier.isEmpty || originalPath.contains(trackIdentifier))
        if isReady {
            break
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        trackIdentifier = track?.trackIdentifier ?? ""
    }

    guard let track = track else {
        throw LyricsError.noCurrentTrack
    }

    // 记下这一首的时长：占位文案的合成时间轴要用（那几步拿不到 track 对象）。
    // 与 `currentLyricsDto` 同一时机写入，语义都是"这一次请求的曲目"。
    currentTrackDurationMs = track.trackDurationMilliseconds

    // ── 切歌信号：**立刻**作废上一首的逐词层，不等新歌词 ─────────────────────────
    //
    // 真机症状（PL / MXM / AMLL 三个源都能复现）：切歌后到新词到达之间，卡片与全屏的壳
    // 已经换成新歌，而我们的层还挂着**上一首的行模型** —— 就是"预览歌词显示上一首歌的
    // 逐词歌词"。根因是 `currentLyricsVersion` 随**歌词数据**自增，"歌换了"在那一层里不可见。
    //
    // 用请求里的曲目 id 当切歌信号最可靠：歌词请求是**每首歌都会来一次**的（客户端
    // 缓存命中时不一定，那条路由 `AppleMusicLyricsOverlayHost` 里的 `hasForeignLineModel`
    // 每帧兜住）。命中即清 —— `resetWordByWordLyrics` 会摘掉新旧两层并把 dto 清空，
    // 于是看门狗的 `hasUsableWordLevelData` 判据也为假，不会拿旧数据把层挂回来。
    let requestedTrackId = track.trackIdentifier ?? ""
    if !requestedTrackId.isEmpty, requestedTrackId != lyricsLayerTrackId {
        let isTrackSwitch = lyricsLayerTrackId != nil
        lyricsLayerTrackId = requestedTrackId
        if isTrackSwitch {
            resetWordByWordLyrics(reason: "track changed (\(requestedTrackId))")
        }
    }

    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        throw LyricsError.trackMismatch
    }

    var lyrics: Lyrics
    do {
        lyrics = try loadCustomLyricsForCurrentTrack()
    } catch let error {
        // 这一首没能用上我们的歌词 → 决定**这次 HTTP 响应交什么出去**。
        //
        // 两种错误必须原样放行（它们跟"屏幕上这首歌有没有词"无关）：
        //   · `.invalidSource` = 用户明确选了「禁用歌词替换」，要看官方歌词；
        //   · `.noSuchSong` 等真·取词失败：交给下面的占位逻辑（「隐藏 Spotify 官方歌词」
        //     开着就顶掉官方歌词，关着就放行官方歌词）。
        //
        // ⚠️ `.trackMismatch` / `.noCurrentTrack` 以前也是"原样放行"，结果是这次请求
        // **一个字节都不投递**：Spotify 侧等不到歌词数据 → 不创建 NPV 歌词卡片 →
        // 连全屏歌词入口都没有（这就是"有些歌完全没有歌词模块"最重的那条路径）。
        // 现在它们也和其它失败一样，一定给出一份可解析的占位，保证卡片建得起来。
        let lyricsError = error as? LyricsError
        let shouldDropResponse = lyricsError == .invalidSource
        // 切歌竞态单独加一句说明：用户看到"未找到歌词"时能立刻分清这不是词库的问题。
        let placeholderNote: String? = lyricsError == .trackMismatch ? "track_mismatch".localized : nil

        if !shouldDropResponse {
            resetWordByWordLyrics()
            // 别让 Spotify 把它自己的官方歌词顶上来 —— 用我们自己的占位替换掉。
            if let placeholder = unavailableLyricsPayload(original: originalLyrics) {
                writeDebugLog("[Lyrics] official lyrics hidden — serving our placeholder")
                return try placeholder.serializedBytes()
            }
            // 「隐藏官方歌词」关着 → 本来该放行官方歌词。但如果是 trackMismatch /
            // noCurrentTrack，连"官方歌词"都不能确定属于这一首，同样不能空手而归。
            if lyricsError == .trackMismatch || lyricsError == .noCurrentTrack {
                writeDebugLog("[Lyrics] \(lyricsError!) — serving fallback so the card is created")
                if let data = unavailableLyricsBytes(original: originalLyrics, note: placeholderNote) {
                    return data
                }
            }
        }
        throw error
    }

    let lyricsColorsSettings = UserDefaults.lyricsColors

    /// 这次用的是**我们自己算出来的颜色**（拿不到 Spotify 原始颜色：曲目 404、或用户关了
    /// 「显示原始颜色」）。它决定下面"清背景 alpha"那一步要不要跳过 —— 见那段注释。
    var usesSynthesizedColors = false

    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        writeDebugLog("[Lyrics] Using original colors")
        lyrics.colors = originalLyrics.colors
    } else {
        // 与占位 payload 走**同一个** `synthesizedLyricsColors()`：这两条路必须给出一致的配色，
        // 否则又会分叉成"取不到词的曲目是黑块、取得到词的不是" —— 那正是 2026-09-25 09:09
        // 照片与日志 21 里的现象（根因是两条路各写了一份、其中一份什么都不设）。
        lyrics.colors = synthesizedLyricsColors()
        usesSynthesizedColors = true
    }

    // 记录最终生效的歌词背景色（原始色或定制色），供逐字 overlay 复用，保证与原生模块同色。
    //
    // ⚠️ 必须在下面那个"清 alpha"之前读：overlay 要的是**原色**，
    // 拿去当自己的兜底底色 / 判断明暗，不能是透明值。
    currentLyricsBackgroundColorARGB = lyrics.colors.backgroundColor

    // ── 交给 Spotify 的那份背景色改成**全透明** ───────────────────────────────
    //
    // 为什么：Spotify 拿这个值去刷原生歌词界面的背景 —— 包括**卡片面板**自己那层。
    // 而我们的层是"歌词视图的子视图"，**子视图永远盖不住父视图自己的背景**
    // （绘制顺序是"父视图的 backgroundColor 先画、子视图后画"），
    // 所以预览卡片顶部那条 39pt（「歌词」+ 分享/展开按钮那一行）永远是专辑纯色。
    //
    // 之前试过四种"盖住它"的办法（往卡片塞背景层 / 清容器底色 / 每帧重清 /
    // 让我们的背景画到 bounds 之外），全都无效 —— 因为问题不在层级，在绘制顺序。
    // 这次改成**让它别画**：把注入值的 alpha 清掉，面板就是透明，
    // 露出来的正好是我们已经铺在歌词区上的模糊封面。
    //
    // 只动 alpha（高 8 位），RGB 原样保留：
    //   · 「歌词」标题与分享/展开按钮是**画在面板背景之上**的独立视图，
    //     颜色不受影响，位置和点击也不变；
    //   · 我们自己的 overlay 用的是上面那个 `currentLyricsBackgroundColorARGB`（原值）。
    let injected = lyrics.colors.backgroundColor
    let transparentBackground = injected & 0x00FF_FFFF
    // 只在**不是**"自造颜色 + 已开补卡片元素"这个组合时清 alpha。
    let keepsOpaqueBackground = usesSynthesizedColors
        && NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled
    if !keepsOpaqueBackground, transparentBackground != injected {
        lyrics.colors.backgroundColor = transparentBackground
        writeDebugLog(
            String(
                format: "[Lyrics] injected background %08X -> %08X (transparent)",
                injected, transparentBackground
            )
        )
    } else if keepsOpaqueBackground {
        // 为什么这里必须留着不透明：清 alpha 的**前提**是"我们的 overlay 会把模糊封面铺在
        // 卡片面板底下"（见上面那段）。而 9.1.86 上 overlay 根本挂不上 —— 日志里
        // `inline host found` 从未出现过，清完 alpha 只会露出卡片自己的默认黑底。
        // 2026-09-25 08:37 的两张真机照片正是这个组合：卡片整块黑、歌词字看不见。
        // 自造颜色这一支本来也没有"Spotify 的底"可以露，所以直接给不透明底色。
        writeDebugLog(
            String(
                format: "[Lyrics] keeping synthesized background opaque %08X (no overlay paints this card)",
                injected
            )
        )
    }

    // 歌词提供者**不在这里写**：它已经由 `storeLyricsDto(_:source:)` 与 dto 同时写好了
    // （`currentLyricsProvider`）。在这个函数末尾再写一次的话，写的是 `lyrics.data.providedBy`，
    // 而那份 protobuf 是**先前**构造的 —— 与 dto 分属两个时刻，正是"注解慢一拍"的老毛病。
    // 需要提供者时读 `currentLyricsProvider` / `currentLyricsDto?.providerName`。

    return try lyrics.serializedBytes()
}
