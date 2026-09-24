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
                        useInstrumentalPlaceholder: source != .genius
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

        // 「AMLL 优先」：先向 AMLL 要逐词歌词，**只接受逐词歌词**，
        // 拿不到就回退到用户在来源选择器里设置的那个源（连同它的相关设置）。
        //
        // 回退目标刻意不是硬编码的：哪个源适合兜底完全取决于地区与语言 ——
        // 日本用户设 PetitLyrics、大陆用户设网易云、其它地区设 SpicyLyrics，
        // 各自回退到自己最合适的地方，不需要我们再维护一份地区判断。
        // 该选项依赖逐词歌词，未开启时视为未勾选。
        let amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred
            && NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            && source != .amllTtml

        if amllPreferred {
            writeDebugLog("[Lyrics] AMLL preferred — trying AMLL first, fallback target: \(source.description)")

            // 走同一套单源错误处理：记录 fallbackError、弹 MxM 相关弹窗。
            //
            // ⚠️ 结果里带的是**实际**给词的那个源：AMLL 请求失败而 Genius 兜底成功时，
            // 拿回来的 dto 是 Genius 的。以前这里只回传 dto、源名沿用调用方传的那个，
            // 于是"来源标签写 AMLL、内容其实是 Genius"。
            let amllResult = try? requestSingleSource(
                .amllTtml,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: true
            )

            // ⚠️ 判据是**逐词可用**，不是「有行」。
            //
            // AMLL 的 TTML 里两种数据都可能出现：
            //   · 有 `<span>` 逐词时间轴 → 逐词歌词（要的）
            //   · 只有 `<p begin=...>` 行级时间轴 → 就是一行一句的普通同步歌词
            // 以前这里只判 `!lines.isEmpty`，于是第二种也被当成"AMLL 成功"直接采用：
            // 用户明明开了「AMLL 优先」（只想要逐词），结果拿到一份逐行歌词，
            // 而且它的排版/来源和用户自己设的那个源完全不同 —— 看起来就像"设置没生效"。
            //
            // 现在把判定口径与渲染层对齐（同一个 `hasUsableWordLevelData`）：
            // 行级数据在这里就被判为"不合格"，交给下面用户设置的源去处理。
            // 无时间轴的数据同样过不了这一关（`timeSynced == false`），一并回退。
            if let result = amllResult, hasUsableWordLevelData(result.dto) {
                writeDebugLog("[Lyrics] AMLL succeeded — using it (\(result.dto.lines.count) line(s))")
                return makeLyrics(from: result.dto, source: result.source)
            }

            // 分开报两种失败原因：日志里能立刻分清是"请求失败"还是"拿到了但不够逐词"。
            if let dto = amllResult?.dto {
                let timeline = dto.timeSynced ? "line-or-word timeline" : "no timeline"
                writeDebugLog(
                    "[Lyrics] AMLL returned \(dto.lines.count) line(s) but not word-by-word"
                        + " (\(timeline)) — falling back to \(source.description)"
                )
            } else {
                writeDebugLog(
                    "[Lyrics] AMLL unavailable — falling back to \(source.description) with its own settings"
                )
            }
            // 用户设置的就是 Genius 时不必再走下面的 geniusFallback，否则会重复请求一次。
            let result = try requestSingleSource(
                source,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: false,
                allowGeniusFallback: source != .genius
            )
            return makeLyrics(from: result.dto, source: result.source)
        }

        let result = try requestSingleSource(
            source,
            searchQuery: searchQuery,
            options: options,
            recordFallbackError: true
        )

        return makeLyrics(from: result.dto, source: result.source)
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
    /// - Parameter allowGeniusFallback: 为 false 时跳过 Genius 兜底。用于
    ///   「AMLL 优先」模式下用户设置本身就是 Genius 的场景，避免重复请求同一个源。
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

            // 注意顺序：Genius 失败不再兜底为空歌词（与既有行为一致）——
            // allowGeniusFallback 在用户设置本身就是 Genius 时为 false。
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

        return Lyrics.with {
            $0.data = LyricsData.with {
                $0.timeSynchronized = false
                $0.restriction = .unrestricted
                // 署名是我们自己：界面上那一行来源不会再写成别人的品牌。
                $0.providedBy = "EeveeSpotify"
                $0.lines = [
                    LyricsLine.with { $0.content = "ngzhwm_lyrics_unavailable".localized },
                    LyricsLine.with { $0.content = "" },
                    LyricsLine.with {
                        $0.content = "ngzhwm_lyrics_unavailable_hint".localized
                    },
                ]
            }
            // 颜色沿用 Spotify 原来那份：背景色 / 歌名配色保持原样，看不出被替换过。
            if let original = original {
                $0.colors = original.colors
            }
        }
    }

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

    /// 把逐词层的全局状态清空，并把已经挂上的层摘掉。
    ///
    /// 用于"这一首没有我们的歌词"（取词失败 / 用户选了 `notReplaced`）：
    /// 旧层的 `setCurrentTime` 与新层的 `update()` 都以"有没有可用数据"为准，
    /// 数据一清：
    ///   · 旧层整块透明 + 触摸穿透 → 原生歌词与控件原样可用；
    ///   · 新层因为没有行模型而 `detach()` → 同上。
    private func resetWordByWordLyrics() {
        writeDebugLog("[Lyrics] no custom lyrics for this track — clearing word-by-word layer")
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
    private func makeLyrics(from dto: LyricsDto, source: LyricsSource) -> Lyrics {
        lyricsState.isEmpty = dto.lines.isEmpty
        lyricsState.wasRomanized = dto.romanization == .romanized
            || dto.romanization == .canBeRomanized
        lyricsState.loadedSuccessfully = true

        storeLyricsDto(dto, source: source)

        return Lyrics.with {
            $0.data = dto.toSpotifyLyricsData(
                source: source.description,
                useInstrumentalPlaceholder: source != .genius
            )
        }
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

    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        throw LyricsError.trackMismatch
    }

    var lyrics: Lyrics
    do {
        lyrics = try loadCustomLyricsForCurrentTrack()
    } catch let error {
        // 这一首没能用上我们的歌词（界面本来会退回 Spotify 自己的官方歌词）→
        //   1. 先把逐词层的状态清干净：不清的话上一个 overlay 会继续盖着原生歌词
        //      显示**上一首**的内容，连底部的来源注解也是上一首的；
        //   2. 再按「隐藏 Spotify 官方歌词」开关决定要不要用我们自己的占位 payload
        //      把官方歌词顶掉（见 `unavailableLyricsPayload`）。
        //
        // ⚠️ 三种错误不动：`.trackMismatch` / `.noCurrentTrack` 表示"这次请求不是
        // 针对当前这首歌"（Spotify 会预取别的歌、或启动时序还没对齐）；
        // `.invalidSource` 是"用户选了禁用歌词替换"（明确要看官方歌词）。
        // 这三种都跟"屏幕上这首歌没词"无关，动了等于把好好的歌词一起清掉。
        switch error as? LyricsError {
        case .some(.trackMismatch), .some(.noCurrentTrack):
            break
        case .some(.invalidSource):
            break
        default:
            resetWordByWordLyrics()
            // 别让 Spotify 把它自己的官方歌词顶上来 —— 用我们自己的占位替换掉。
            if let placeholder = unavailableLyricsPayload(original: originalLyrics) {
                writeDebugLog("[Lyrics] official lyrics hidden — serving our placeholder")
                return try placeholder.serializedBytes()
            }
        }
        throw error
    }

    let lyricsColorsSettings = UserDefaults.lyricsColors

    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        writeDebugLog("[Lyrics] Using original colors")
        lyrics.colors = originalLyrics.colors
    } else {
        let extractedColor = switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            track.extractedColorHex()
        default:
            track.metadata()["extracted_color"]
        }

        var color: Color
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        } else if let extractedColor = extractedColor {
            color = Color(hex: extractedColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        } else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        } else {
            color = Color.gray
        }

        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
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
    if transparentBackground != injected {
        lyrics.colors.backgroundColor = transparentBackground
        writeDebugLog(
            String(
                format: "[Lyrics] injected background %08X -> %08X (transparent)",
                injected, transparentBackground
            )
        )
    }

    // 歌词提供者**不在这里写**：它已经由 `storeLyricsDto(_:source:)` 与 dto 同时写好了
    // （`currentLyricsProvider`）。在这个函数末尾再写一次的话，写的是 `lyrics.data.providedBy`，
    // 而那份 protobuf 是**先前**构造的 —— 与 dto 分属两个时刻，正是"注解慢一拍"的老毛病。
    // 需要提供者时读 `currentLyricsProvider` / `currentLyricsDto?.providerName`。

    return try lyrics.serializedBytes()
}
