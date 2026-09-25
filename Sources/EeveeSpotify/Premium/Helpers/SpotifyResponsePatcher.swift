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

    // MARK: `scrollsita` 专用：服务器下发的"正在播放页元素列表"

    /// 要验证的推论：**"歌词卡片"这个元素，是不是服务器决定放不放的。**
    ///
    /// `scrollsita/v1/scroll/spotify:track:<id>` 是按曲目返回**正在播放页元素**的接口。
    /// 若推论成立，SECRET（Spotify 有词）的响应里会出现歌词相关元素，
    /// 而最後の希望（Spotify 没词）的不会 —— 一发就能把判据钉在服务器侧，
    /// 也就能给"本地无解、只剩自绘"下最终结论。
    ///
    /// 实现要点：
    ///   · **累积整条响应体**（chunk 会切碎，只看单块必然漏），512KB 封顶兜底；
    ///   · 关键字用 `yric`，一次覆盖 Lyric / lyric / Lyrics / lyrics（线上用哪种大小写未知）；
    ///   · 同一 path 每发现一个**新**关键字才报一次，不刷屏；
    ///   · 一个关键字都没命中也把**可打印字符串**前 25 条打出来 —— 否则"没命中"和
    ///     "这个接口根本不含字符串"分不清，又是一次白跑（日志 10 的教训）。
    private static var _probeScrollBody: [Int: Data] = [:]
    private static var _probeScrollSeen: [String: Set<String>] = [:]

    /// hex 报告。**用来修正上面那条推论的证据等级**：`no needle`（扫不到 "yric"）
    /// **不能**当成"服务器没下发歌词元素"——
    ///   · scrollsita 是 protobuf，元素类型极可能是**枚举整数**，字符串永远不会出现；
    ///   · 实测 3 条 scrollsita（含 Spotify 有词的 SECRET 与没词的 最後の希望）都是
    ///     `no needle`，body 里只有 artist/track/section/concert URI。
    /// 所以额外把响应体前 512 字节按 hex 打出来（每 path 最多 3 次、只在体积变大时），
    /// 让"两条响应到底差在哪个字段"可以离线比对，而不是只能比可打印字符串。
    private static var _probeScrollHex: [String: (size: Int, reports: Int)] = [:]

    private static func printableRuns(_ d: Data, limit: Int) -> [String] {
        var runs: [String] = []
        var current = ""
        for byte in d {
            if byte >= 0x20 && byte < 0x7F {
                current.append(Character(UnicodeScalar(byte)))
            } else {
                if current.count >= 5 {
                    runs.append(current)
                    if runs.count >= limit { return runs }
                }
                current = ""
            }
        }
        if current.count >= 5 && runs.count < limit { runs.append(current) }
        return runs
    }

    static func probeHasLyricsKey(url: URL, taskID: Int, data: Data) {
        guard !data.isEmpty else { return }

        // 两种拼法都扫：字典里的键是 `has_lyrics`，但**线上**未必是蛇形 ——
        // 服务端 JSON / protobuf 都可能用 `hasLyrics`。
        let needles = ["has_lyrics", "hasLyrics"].compactMap { $0.data(using: .ascii) }
        guard !needles.isEmpty else { return }

        let isScrollsita = url.path.contains("/scrollsita/")
        let scrollNeedles = isScrollsita ? ["yric", "lement", "ard"] : []

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

        // ── scrollsita：累积整条响应体，报告新出现的关键字 ──
        var newlyMatched: [String] = []
        var printable: [String] = []
        var hexDump: String?
        var bodySize = 0
        if isScrollsita {
            var body = _probeScrollBody[taskID] ?? Data()
            body.append(data)
            if body.count > 512 * 1024 { body = Data(body.suffix(512 * 1024)) }
            _probeScrollBody[taskID] = body
            if _probeScrollBody.count > 32 {
                _probeScrollBody.removeAll()
                _probeScrollHex.removeAll()
            }
            bodySize = body.count

            // hex：同一 path 只在"体积变大"时报，最多 3 次（首块往往不完整）。
            let previous = _probeScrollHex[url.path]
            if previous?.size != body.count, (previous?.reports ?? 0) < 3 {
                _probeScrollHex[url.path] = (body.count, (previous?.reports ?? 0) + 1)
                hexDump = body.prefix(512).map { String(format: "%02x", $0) }.joined()
            }

            for name in scrollNeedles where body.range(of: Data(name.utf8)) != nil {
                if _probeScrollSeen[url.path, default: []].insert(name).inserted {
                    newlyMatched.append(name)
                }
            }
            // 一条关键字都没有时，先把可打印字符串亮出来，避免"看不到就等于没有"。
            if newlyMatched.isEmpty, _probeScrollSeen[url.path] == nil {
                printable = printableRuns(body, limit: 25)
                if !printable.isEmpty { _probeScrollSeen[url.path] = ["<no-needle>"] }
            }
        }
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
        if !newlyMatched.isEmpty {
            writeDebugLog(
                "[ScrollProbe] path=\(url.path) body=\(bodySize)B"
                    + " matched=\(newlyMatched.joined(separator: ","))"
            )
        }
        if !printable.isEmpty {
            writeDebugLog(
                "[ScrollProbe] path=\(url.path) body=\(bodySize)B no needle —"
                    + " printable=\(printable.joined(separator: " | "))"
            )
        }
        if let hexDump = hexDump {
            writeDebugLog(
                "[ScrollProbe] path=\(url.path) body=\(bodySize)B"
                    + " hex\(hexDump.count / 2)B=\(hexDump)"
            )
        }
        if scanned % 500 == 0 {
            writeDebugLog("[HasLyricsProbe] scanned=\(scanned) chunks, hits=\(hitCount)")
        }
    }

    // MARK: 歌词响应的**原始**状态码与响应头

    /// 诊断：记录 `color-lyrics` 响应的原始状态与响应头。
    ///
    /// 为什么盯这个 —— 它是**最后一个没查过的本地变量**：
    ///
    ///   · 我们的 `didReceiveResponse` 钩子对**非 200**（404）会**合成**一个 200 交付，
    ///     而且 `headerFields: [:]` —— **响应头是空的**；
    ///   · 对**200** 则是**原样放行**原始响应，**带真实响应头**，只在后面替换 body。
    ///
    /// 于是"200 + 空歌词"的歌，客户端看到的是**原始的**头；而 SECRET（有词）看到的是
    /// "200 + 真实体 + 真实头"。**如果客户端是看响应头（或体长）决定建不建卡片，这份
    /// 日志就能看出来 —— 而且我们能改成"合成一份有歌词的响应头"交付，那就是原生修复。**
    ///
    /// 反过来，如果两者头一样，头部就不是判据，那这篇排查就该收尾去做自绘兜底了。
    ///
    /// 只读、只打日志；同一 path 只报一次。
    private static var _probeHeaderReported = Set<String>()

    static func probeLyricsResponseHeaders(url: URL, response: HTTPURLResponse) {
        guard url.isLyrics else { return }

        lock.lock()
        let isNew = _probeHeaderReported.insert(url.path).inserted
        lock.unlock()
        guard isNew else { return }

        let headers = response.allHeaderFields
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " | ")
        let length = response.value(forHTTPHeaderField: "Content-Length") ?? "-"
        writeDebugLog(
            "[LyricsHeader] status=\(response.statusCode) len=\(length)"
                + " path=\(url.path) headers=[\(headers)]"
        )
    }

    // MARK: - 「禁用歌词功能」

    /// 「禁用歌词功能」是否生效。
    ///
    /// 选项说明原话（`ngzhwm_disable_lyrics_feature_description`）："禁用有关于自定义歌词的
    /// 所有功能，**还会阻止 Spotify 返回其自带的歌词**"。也就是说这个开关必须**主动拦掉**两份数据：
    ///
    ///   1. 我们自己那份 —— `getLyricsDataForCurrentTrack` 已经在抛 `.invalidSource` ✔；
    ///   2. **Spotify 自带那份** —— 以前两条路都漏了：
    ///      · 200 那条：取词抛错后走 `lyricsPayload = buffer`，把官方歌词**原样放行**；
    ///      · 404 那条：`didReceiveResponse` **无条件**合成 200 + 我们的占位。
    ///      结果就是"开关打开后歌词照旧显示"，观感即"选项不生效"。
    static var isLyricsFeatureDisabled: Bool {
        NgzhwmSettingsViewModel.isLyricsFeatureDisabled
    }

    /// 禁用时交给 Spotify 的「没有歌词」payload —— 用它挡住 Spotify 自带的那份。
    ///
    /// 用既有的占位（"未找到歌词" + 提示行）而不是空 payload：它是本模块唯一一条
    /// "必须给出可解析响应"的既有路径，文案与其它失败路径一致，也不会让客户端拿到空数据。
    static func disabledLyricsPayload(original: Lyrics?) -> Data {
        unavailableLyricsBytes(original: original) ?? Data()
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
            // 正在播放页元素列表：补卡片（实验开关）或**摘掉**卡片（「禁用歌词功能」）。
            // 关着且没禁用时零开销，连缓冲都不做。见 `ScrollsitaLyricsElementInjector`。
            || ((NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled
                 || isLyricsFeatureDisabled)
                && ScrollsitaLyricsElementInjector.shouldHandle(url))
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
        case lyricsCardElement = "LyricsCardElement"
        case lyricsCardElementStripped = "LyricsCardElementStripped"
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
        // 「禁用歌词功能」时把服务端下发的「歌词卡片」元素**摘掉** —— 否则卡片照样在
        // （只是内容换成我们那份"未找到歌词"），用户会觉得开关没生效。
        if let stripped = ScrollsitaLyricsElementInjector.strippingLyricsElementIfNeeded(
            url: url,
            body: buffer
        ) {
            return PatchResult(data: stripped, tag: .lyricsCardElementStripped)
        }
        if NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled,
           !isLyricsFeatureDisabled,
           ScrollsitaLyricsElementInjector.shouldHandle(url),
           let injected = ScrollsitaLyricsElementInjector.injectIfNeeded(url: url, body: buffer) {
            return PatchResult(data: injected, tag: .lyricsCardElement)
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
