import Foundation

// Shared by SPTDataLoaderServiceHook and HttpClientURLSessionHook. Lyrics is
// kept in each caller because its async fetch doesn't fit a sync transform.
enum SpotifyResponsePatcher {

    // Patched customize body, replayed for 304s and post-startup re-fetches
    // so ad flags can't re-enable mid-session. Touched from two hook classes on
    // URLSession's concurrent delegate queues — all access is lock-guarded.
    private static let lock = NSLock()
    private static var _cachedCustomizeData: Data?
    private static var _handledCustomizeTasks = Set<Int>()

    static var cachedCustomizeData: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _cachedCustomizeData }
        set { lock.lock(); defer { lock.unlock() }; _cachedCustomizeData = newValue }
    }

    static func markCustomizeTaskHandled(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        _handledCustomizeTasks.insert(id)
    }

    // Returns true exactly once per id (the task that synthesized the replay).
    static func consumeCustomizeTask(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _handledCustomizeTasks.remove(id) != nil
    }

    // MARK: - `has_lyrics` 线上来源探针（排障用）

    /// 找出 track 元数据里的 `has_lyrics` 到底搭**哪个 HTTP 响应**过来。
    ///
    /// 为什么要去线上找它：
    ///   · **面 B**（与「关于艺人」并列的「歌词」预览卡片）的门控**够不着** ——
    ///     `SPTPlayerTrackHook.metadata()` 那个覆写实测**每次都被调用**、也**确实返回了**
    ///     `has_lyrics = "true"`，可面 B 依然只有 SECRET 出现。说明门控读的是 Swift 内部
    ///     字段、走静态派发，ObjC 侧 getter 的改写到不了它那里（与取证报告证据 6 一致）。
    ///   · 而 `has_lyrics` 出现在一个 `[String: String]` 字典里，同字典里还有
    ///     `image_url` / `title` / `duration` / `popularity` —— 这些都是**服务端下发的**。
    ///     取证时在 IPA 的 `__cstring` 里搜不到 `has_lyrics`，也符合"键名来自服务端 JSON"。
    ///
    /// 所以：**如果它在线上，就能在响应里改** —— 那样 Swift 解析出来的字段一开始就是
    /// `true`，门控自然通过。这跟 hook getter 完全是两回事。
    ///
    /// 本函数**只读、只打日志、不修改任何字节**。
    private static var _probeReportedPaths = Set<String>()
    /// 每个 task 上一块数据的尾巴：关键字可能正好被 chunk 边界切断，
    /// 不带上这个尾巴就会漏报，进而把"在线上"误判成"不在线上"。
    private static var _probeCarry: [Int: Data] = [:]
    /// **存活信号**。没有它，"一条都没命中"和"探针压根没编进包里"分不出来 —— 日志 10 就
    /// 栽在这里：唯一的输出只在命中时打，于是空日志既可能是"不在线上"，也可能是"没构建"。
    private static var _probeAnnounced = false
    private static var _probeScanned = 0
    /// 见过哪些端点（最多 40 条）。没命中时靠它判断"覆盖面够不够" ——
    /// 如果连播放器状态类的端点都没扫到，就不能下"不在线上"的结论。
    private static var _probeSeenPaths = Set<String>()

    static func probeHasLyricsKey(url: URL, taskID: Int, data: Data) {
        guard !data.isEmpty else { return }

        // 两种拼法都扫：字典里的键是 `has_lyrics`，但**线上**未必是蛇形 ——
        // 服务端 JSON / protobuf 都可能用 `hasLyrics`。
        let needles = ["has_lyrics", "hasLyrics"].compactMap { $0.data(using: .ascii) }
        guard !needles.isEmpty else { return }

        lock.lock()
        let carry = _probeCarry[taskID] ?? Data()
        var window = Data()
        window.reserveCapacity(carry.count + data.count)
        window.append(carry)
        window.append(data)

        let hit = needles.contains { window.range(of: $0) != nil }

        // 只留够拼上下一块开头的那几个字节。
        _probeCarry[taskID] = Data(data.suffix(9))
        if _probeCarry.count > 128 { _probeCarry.removeAll() }   // 兜底：别让它无限长

        _probeScanned += 1
        let announce = !_probeAnnounced
        if announce { _probeAnnounced = true }

        var newPath: String?
        if _probeSeenPaths.count < 40, _probeSeenPaths.insert(url.path).inserted {
            newPath = url.path
        }

        let isNewHit = hit && _probeReportedPaths.insert(url.path).inserted
        let hitCount = _probeReportedPaths.count
        let scanned = _probeScanned
        lock.unlock()

        if announce {
            writeDebugLog("[HasLyricsProbe] active — scanning response chunks")
        }
        if let newPath {
            writeDebugLog("[HasLyricsProbe] seen path=\(newPath)")
        }
        if isNewHit {
            writeDebugLog(
                "[HasLyricsProbe] HIT — host=\(url.host ?? "?") path=\(url.path)"
                    + " chunk=\(data.count)B"
            )
        }
        if scanned % 500 == 0 {
            writeDebugLog("[HasLyricsProbe] scanned=\(scanned) chunks, hits=\(hitCount)")
        }
    }

    static func shouldBlock(_ url: URL) -> Bool {
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        let path = url.path.lowercased()

        if url.isDeleteToken || url.isSessionInvalidation
            || path.contains("session/purge") || path.contains("token/revoke")
            || url.isAdRelated {
            return true
        }
        if path.contains("/dac/view/v1/") { return true }
        if path.contains("/esperanto/") && (path.contains("ad") || path.contains("slot")) {
            return true
        }

        // 30s grace: signup/public is part of fresh-login; blocking pre-30s
        // breaks first-launch.
        if elapsed > 30 {
            return url.isAccountValidate || url.isOndemandSelector
                || url.isTrialsFacade || url.isPremiumMarketing || url.isPendragonFetchMessageList
                || url.isPushkaTokens
                || url.path.contains("signup/public") || url.path.contains("apresolve")
                || url.path.contains("pses/screenconfig")
                || url.path.contains("v1/customize")
        }
        return false
    }

    static func shouldModify(_ url: URL) -> Bool {
        let shouldPatchPremium = BasePremiumPatchingGroup.isActive || PremiumBootstrapGroup.isActive
        let shouldReplaceLyrics = BaseLyricsGroup.isActive
        let isDAC = url.path.lowercased().contains("/dac/view/v1/")

        return (shouldReplaceLyrics && url.isLyrics)
            || (shouldPatchPremium && (
                url.isBootstrap || url.isCustomize ||
                url.isPremiumPlanRow || url.isPremiumBadge || url.isPlanOverview ||
                isDAC
            ))
            || BrowsitaSectionStripper.shouldHandle(url)
    }

    static func blockedResponseData(for url: URL) -> Data {
        if url.isAccountValidate {
            return #"{"status":1,"country":"US","is_country_launched":true}"#.data(using: .utf8)!
        }
        if url.isTrialsFacade {
            return #"{"result":"NOT_ELIGIBLE"}"#.data(using: .utf8)!
        }
        if url.isPremiumMarketing {
            return #"{}"#.data(using: .utf8)!
        }
        if url.isSessionInvalidation
            || url.path.contains("session/purge")
            || url.path.contains("token/revoke")
            || url.path.contains("signup/public")
            || url.path.contains("apresolve") {
            // Logout daemons parse the body; synthetic OK keeps them off the
            // actual logout codepath.
            return #"{"status":"OK"}"#.data(using: .utf8)!
        }
        if url.path.contains("pses/screenconfig") {
            return #"{}"#.data(using: .utf8)!
        }
        if url.path.contains("v1/customize"), let cached = cachedCustomizeData {
            return cached
        }
        return Data()
    }

    enum PatchTag: String {
        case bootstrap   = "bootstrap"
        case customize   = "customize"
        case planRow     = "PremiumPlanRow"
        case planBadge   = "YourPremiumBadge"
        case planOverview = "PlanOverview"
        case dacEmpty    = "dac"
        case casitaStrip = "casitaStrip"
    }

    struct PatchResult {
        let data: Data
        let tag: PatchTag
    }

    static func patch(url: URL, buffer: Data) throws -> PatchResult? {
        if url.isPremiumPlanRow {
            return PatchResult(
                data: try getPremiumPlanRowData(
                    originalPremiumPlanRow: try PremiumPlanRow(serializedBytes: buffer)
                ),
                tag: .planRow
            )
        }
        if url.isPremiumBadge {
            return PatchResult(data: try getPremiumPlanBadge(), tag: .planBadge)
        }
        if url.isBootstrap {
            var msg = try BootstrapMessage(serializedBytes: buffer)
            UserDefaults.hasPatchedBootstrap = true
            if UserDefaults.patchType == .requests {
                modifyRemoteConfiguration(&msg.ucsResponse)
            }
            return PatchResult(data: try msg.serializedBytes(), tag: .bootstrap)
        }
        if url.isCustomize {
            var msg = try CustomizeMessage(serializedBytes: buffer)
            modifyRemoteConfiguration(&msg.response)
            let data = try msg.serializedData()
            cachedCustomizeData = data
            return PatchResult(data: data, tag: .customize)
        }
        if url.isPlanOverview {
            return PatchResult(data: try getPlanOverviewData(), tag: .planOverview)
        }
        if url.path.lowercased().contains("/dac/view/v1/") {
            // Empty body = "no ad to render" to the DAC consumer.
            return PatchResult(data: Data(), tag: .dacEmpty)
        }
        if BrowsitaSectionStripper.shouldHandle(url) {
            if let stripped = BrowsitaSectionStripper.strip(buffer, url: url) {
                return PatchResult(data: stripped, tag: .casitaStrip)
            }
            return nil
        }
        return nil
    }
}
