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

    // MARK: 正在播放页的「旁路模块」接口

    /// 除 `scrollsita` 的元素列表之外，正在播放页还会**单独请求**几个"模块"接口。
    ///
    /// 起因（2026-09-26 真机，日志 5 的 `Fade Away`）：用户看到的那张**过期**的
    /// 「即将发布 / 已预收藏」卡，**不来自元素列表** —— 那份响应只有 `2/3/4`（没有 `12`），
    /// 而下面这三个请求**恰好在"卡在场"的那一次出现、"卡消失"的重进那一次全都没有**：
    ///
    ///   · `/cultural-moments-entrypoints/v1/entrypoint?entityUri=…`  ← 按时间点出卡，最像
    ///   · `/spotify.liveeventdistribution.v1.EventCardInfoService/EventCardInfo`
    ///   · `/merch-npv-service/v1/merch/track/<id>`
    ///
    /// 对照组（日志 6 `MONTAGEM KOKORO`）：那张**正常**的预热卡（"在 6 天内发布" +
    /// "预收藏 +"）来自元素列表里的类型 `12`，而那一整段**没有任何旁路请求**。
    /// 另外把 `12` 那个元素拆开看，它里面只有 album URI + section URI，**没有日期字段** ——
    /// 所以日期与"已收藏"状态都是客户端从别处取来的，元素列表这条路解释不了坏卡。
    ///
    /// 本探针只做一件事：把这三个接口的响应原样亮出来（状态 + 可打印串 + hex）。
    /// **只读、只打日志、不修改任何字节**，也不参与 `shouldModify`。
    static func isNPVModuleEndpoint(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/cultural-moments-entrypoints/")
            || path.contains("eventcardinfoservice")
            || path.contains("/merch-npv-service/")
    }

    private static var _moduleProbeBody: [Int: Data] = [:]
    private static var _moduleProbeDumps: [String: Int] = [:]
    private static var _moduleProbeStatus: [String: Int] = [:]

    /// 由 `didReceiveResponse` 调用：记下状态码与 Content-Type（同一 path 只报一次）。
    static func probeNPVModuleHeaders(url: URL, response: HTTPURLResponse) {
        guard isNPVModuleEndpoint(url) else { return }

        lock.lock()
        let isNew = _moduleProbeStatus[url.path] == nil
        _moduleProbeStatus[url.path] = response.statusCode
        lock.unlock()

        guard isNew else { return }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let length = response.value(forHTTPHeaderField: "Content-Length") ?? "-"
        writeDebugLog(
            "[NPVModule] status=\(response.statusCode) len=\(length) type=\(type) path=\(url.path)"
        )
    }

    /// 由 `didReceiveData` 调用：累积整条响应体，**体积变大时最多 dump 3 次**。
    ///
    /// 为什么累积而不是只看第一块：这几个接口的体可能是分块到达的，
    /// 而"过期日期 / 错误状态"这种字符串完全可能跨块（日志 10 的 `has_lyrics` 探针就栽在这上面）。
    static func probeNPVModuleBody(url: URL, taskID: Int, data: Data) {
        guard isNPVModuleEndpoint(url), !data.isEmpty else { return }

        lock.lock()
        var body = _moduleProbeBody[taskID] ?? Data()
        body.append(data)
        if body.count > 256 * 1024 { body = Data(body.suffix(256 * 1024)) }
        _moduleProbeBody[taskID] = body
        if _moduleProbeBody.count > 64 { _moduleProbeBody.removeAll() }

        let dumps = _moduleProbeDumps[url.path] ?? 0
        var printable: [String] = []
        var hexDump: String?
        if dumps < 3 {
            _moduleProbeDumps[url.path] = dumps + 1
            printable = printableRuns(body, limit: 30)
            hexDump = body.prefix(256).map { String(format: "%02x", $0) }.joined()
        }
        let size = body.count
        lock.unlock()

        guard dumps < 3 else { return }
        writeDebugLog(
            "[NPVModule] body path=\(url.path) \(size)B"
                + " printable=\(printable.joined(separator: " | "))"
        )
        if let hexDump {
            writeDebugLog("[NPVModule] hex path=\(url.path) \(hexDump.count / 2)B=\(hexDump)")
        }
    }

    // MARK: 「预热 / 预发行」关键字探针

    /// 扫**所有**响应字节，找"这张专辑还没发行 / 可以预收藏"这类字样的来源。
    ///
    /// 为什么需要（2026-09-26，日志 5/6/7）：坏卡的两条路已经排除掉了 ——
    ///   · **元素列表**：坏卡出现在元素列表里**没有 `12`** 的曲目上（Fade Away 只有 2/3/4、
    ///     Notes of Color 只有 5/2/3/4），而且 `12` 那个元素里**只有 album URI + section URI**，
    ///     没有任何日期字段；
    ///   · **三个旁路模块接口**：日志 7 里它们分别返回 **503 / 404 / 404**，体里只有
    ///     "No entrypoint is defined…" 和 "No artists with merch…"。
    ///
    /// 而同一首歌两次加载的 HTTP 数据**完全一样**（日志 7：两行 manifest 逐字节同形），
    /// 卡却只在第一次出现 ⇒ 数据要么在本次会话**更早的某个响应**里（比如启动时的
    /// `casita/v1/home` 或播放列表页），要么在客户端本地。本探针负责前者。
    ///
    /// 命中就打一行（同一 `path + needle` 只报一次），并带命中处前后各 80 字节的可打印上下文。
    /// **只读、只打日志、不改任何字节。**
    private static let preReleaseNeedles: [[UInt8]] = [
        "prerelease", "pre_release", "pre-release",
        "presave", "pre_save", "pre-save",
        "preorder", "pre-order",
        "upcoming",
        "release_date", "releasedate",
    ].map { Array($0.lowercased().utf8) }

    /// 首字节分派表：只有 b ∈ {p, r, u} 的位置才需要逐个 needle 比较。
    private static let preReleaseNeedlesByFirstByte: [UInt8: [[UInt8]]] = {
        var map: [UInt8: [[UInt8]]] = [:]
        for needle in preReleaseNeedles { map[needle[0], default: []].append(needle) }
        return map
    }()

    private static var _preReleaseCarry: [Int: Data] = [:]
    private static var _preReleaseHits = Set<String>()
    /// 单块超过这个大小就不扫（图片/音频之类的大 blob）。
    private static let preReleaseScanLimit = 256 * 1024
    /// 每个 task 保留的尾巴长度：刚好够拼上下一块开头的那几个字节。
    private static let preReleaseCarryLength = 16

    static func probePreReleaseNeedles(url: URL, taskID: Int, data: Data) {
        guard !data.isEmpty, data.count <= preReleaseScanLimit else { return }

        lock.lock()
        let carry = _preReleaseCarry[taskID] ?? Data()
        var window = Data()
        window.reserveCapacity(carry.count + data.count)
        window.append(carry)
        window.append(data)
        _preReleaseCarry[taskID] = Data(data.suffix(preReleaseCarryLength))
        if _preReleaseCarry.count > 128 { _preReleaseCarry.removeAll() }
        lock.unlock()

        let bytes = [UInt8](window)
        guard !bytes.isEmpty else { return }

        var hits: [(needle: String, context: String)] = []
        var index = 0

        while index < bytes.count {
            guard let candidates = preReleaseNeedlesByFirstByte[asciiLowerByte(bytes[index])] else {
                index += 1
                continue
            }

            for needle in candidates where index + needle.count <= bytes.count {
                guard matchesASCIIInsensitive(bytes, at: index, needle: needle) else { continue }
                let needleText = String(decoding: needle, as: UTF8.self)

                lock.lock()
                let isNew = _preReleaseHits.insert("\(url.path)|\(needleText)").inserted
                lock.unlock()

                if isNew {
                    hits.append((needleText, printableContext(bytes, around: index)))
                }
                break   // 同一块里同一种 needle 只报一次
            }

            index += 1
        }

        for hit in hits {
            writeDebugLog(
                "[PreRelease] HIT path=\(url.path) needle=\(hit.needle) ctx=\(hit.context)"
            )
        }
    }

    private static func asciiLowerByte(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    /// 大小写不敏感的 ASCII 比较（needle 已经全部小写）。
    private static func matchesASCIIInsensitive(_ bytes: [UInt8], at index: Int, needle: [UInt8]) -> Bool {
        for k in 0..<needle.count where asciiLowerByte(bytes[index + k]) != needle[k] {
            return false
        }
        return true
    }

    /// 命中处前后各 `radius` 字节的可打印上下文（不可打印字符换成 `·`）。
    /// 默认 80 —— `[PreRelease]` 探针原本就是这个半径，行为不变；
    /// 新增的日期串扫描用 60（日期上下文通常更短，短一点一行才放得下）。
    private static func printableContext(_ bytes: [UInt8], around index: Int, radius: Int = 80) -> String {
        let start = max(0, index - radius)
        let end = min(bytes.count, index + radius)
        var out = ""
        out.reserveCapacity(end - start)
        for byte in bytes[start..<end] {
            if byte >= 0x20, byte < 0x7F {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("·")
            }
        }
        return out
    }

    // MARK: - 全量请求清单 + ISO 日期串扫描（预热卡最后一条未封的路）

    /// 前面三支探针把能排除的都排除了（见 `LYRICS_MODULE_NEXT_STEPS.md` §37 与 §38）：
    ///
    ///   · **元素列表**：假卡出现在元素列表**连 `12` 都没有**的曲目上（一场 79 条 manifest 全是
    ///     `2/3/4` 或 `5/2/3/4`）；
    ///   · **三个旁路模块**：`cultural-moments` / `merch-npv` 恒为 404；`EventCardInfoService`
    ///     只在有演唱会的曲目上 200，体里是 `spotify:concert:` + `2027-01-23T16:30:00+0900`；
    ///   · **关键字探针**：整场会话里 11 个"预热 / 预发行"关键字在业务响应上**零命中**，
    ///     唯一命中是 `bootstrap` / `customize` 的 **flag 名字**。
    ///
    /// 而假卡的日期是**绝对日期**（`发布时间：2021年5月27日` / `2023年8月10日`），
    /// 与正版卡的相对文案（`在 6 天内发布`）是两种渲染 —— 说明它拿到的是一份**带日期的数据**，
    /// 只是那份数据以 protobuf 字段到达，没有明文关键字。
    ///
    /// 所以这一支只做两件事：
    ///
    ///   1. **全量请求清单**：每一条响应一行 `[Traffic] resp … host path status type size`
    ///      —— 这是"某条请求到底发生过没有"的唯一直接判据。哪条路径在"卡在场"的那一次
    ///      出现、在"重进"的那一次不出现，谁就是嫌疑人（§37 已用人工对照证明
    ///      `Fade Away` 第一次进有旁路请求、重进没有）；
    ///   2. **ISO 日期串扫描**：在**所有**响应字节里找 `NNNN-NN-NN`。
    ///      `EventCardInfoService` 的日期就是明文（`2027-01-23T16:30:00+0900`），
    ///      所以"预热卡那份数据"如果来自网络，它的日期**大概率也是明文**，
    ///      命中处打前后各 60 字节上下文 —— 一眼能看出这是发行日、演出日还是别的。
    ///
    /// 顺带补两个**已知盲点**：
    ///   · `discovery-from-seed`（每首歌必发一次，是 §37 还没排除的一个端点）按路径 dump 前
    ///     2048 字节 hex；
    ///   · `[PreRelease]` 探针有个 `256KB` 上限、超了**完全静默** —— 这里把"跳过的大响应"
    ///     也记一行，免得再出现"没命中"与"没扫"分不清。
    ///
    /// **只读、只打日志、不改任何字节。**
    private static var _trafficRequestCount = 0
    private static var _trafficBodySize: [Int: Int] = [:]
    private static var _trafficDateHits = Set<String>()
    private static var _trafficDateHitCount = 0
    private static var _trafficDumped: [String: Int] = [:]
    private static var _trafficSkippedLarge = 0
    private static var _trafficAnnounced = false
    /// 每条 path 最多 dump 几份 hex（同一 path 常常多次请求，只要前几份就够比对）。
    private static let trafficDumpLimit = 2
    /// 日期串命中最多打这么多行，防止某个大 JSON 刷爆日志。
    private static let trafficDateHitLimit = 80

    /// 由 `didReceiveResponse` 调用：记下每一条响应的**元信息**（状态 / 类型 / 大小）。
    ///
    /// 与 `probeLyricsResponseHeaders` / `probeNPVModuleHeaders` 的区别：那两个只看特定端点，
    /// 这个**看全部** —— 目的就是把"客户端到底请求了什么"变成一份完整清单。
    static func probeTrafficHeaders(url: URL, response: HTTPURLResponse) {
        lock.lock()
        _trafficRequestCount += 1
        let index = _trafficRequestCount
        let announce = !_trafficAnnounced
        if announce { _trafficAnnounced = true }
        lock.unlock()

        if announce {
            writeDebugLog("[Traffic] active — logging every response (host path status type size)")
        }

        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "-"
        let length = response.value(forHTTPHeaderField: "Content-Length") ?? "-"
        writeDebugLog(
            "[Traffic] resp #\(index) status=\(response.statusCode) type=\(type)"
                + " len=\(length) host=\(url.host ?? "?") path=\(url.path)"
        )
    }

    /// 由 `didReceiveData` 调用：报一次该 task 的首块体积，再扫 ISO 日期串、按需 dump hex。
    static func probeTrafficBody(url: URL, taskID: Int, data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        // ── 体积：该 task 第一次收到数据时报一次（分块到达时"首块"就是我们要的信号）──
        let isFirstChunk = _trafficBodySize[taskID] == nil
        _trafficBodySize[taskID] = (_trafficBodySize[taskID] ?? 0) + data.count
        if _trafficBodySize.count > 256 { _trafficBodySize.removeAll() }

        let path = url.path
        var dumpHex: String?
        if isTrafficDumpEndpoint(path), (_trafficDumped[path] ?? 0) < trafficDumpLimit {
            _trafficDumped[path] = (_trafficDumped[path] ?? 0) + 1
            dumpHex = data.prefix(2048).map { String(format: "%02x", $0) }.joined()
        }

        let tooLarge = data.count > 256 * 1024
        var skipped = 0
        if tooLarge {
            _trafficSkippedLarge += 1
            skipped = _trafficSkippedLarge
        }
        lock.unlock()

        if isFirstChunk {
            writeDebugLog(
                "[Traffic] body first chunk \(data.count)B"
                    + " host=\(url.host ?? "?") path=\(path)"
            )
        }

        if let dumpHex {
            writeDebugLog(
                "[Traffic] hex path=\(path) chunk=\(data.count)B"
                    + " hex\(dumpHex.count / 2)B=\(dumpHex)"
            )
        }

        if tooLarge {
            if skipped <= 8 {
                writeDebugLog(
                    "[Traffic] ⚠️ chunk > 256KB (\(data.count)B) — string/date scan skipped"
                        + " path=\(path) (skipped=\(skipped))"
                )
            }
            return
        }

        scanForISODates(url: url, data: data)
    }

    /// 值得 dump 前 2KB hex 的路径：目前是"每首歌必发、但还没被排除"的那一个。
    private static func isTrafficDumpEndpoint(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("discovery-from-seed")
            || lower.contains("eventcardinfoservice")
            || lower.contains("scrollsita/v1/scroll")
    }

    /// 在响应字节里找 `NNNN-NN-NN`（ISO 日期前缀）。命中处打前后各 60 字节可打印上下文。
    private static func scanForISODates(url: URL, data: Data) {
        let bytes = [UInt8](data)
        var found: [(date: String, context: String)] = []
        var index = 0

        while index + 10 <= bytes.count {
            guard bytes[index] >= 0x30, bytes[index] <= 0x39 else { index += 1; continue }
            if isISODatePrefix(bytes, at: index) {
                let date = String(decoding: bytes[index..<(index + 10)], as: UTF8.self)
                let context = printableContext(bytes, around: index, radius: 60)
                found.append((date, context))
                index += 10
            } else {
                index += 1
            }
        }

        guard !found.isEmpty else { return }

        var toReport: [(String, String)] = []
        lock.lock()
        for hit in found {
            guard _trafficDateHitCount < trafficDateHitLimit else { break }
            guard _trafficDateHits.insert("\(url.path)|\(hit.date)").inserted else { continue }
            _trafficDateHitCount += 1
            toReport.append((hit.date, hit.context))
        }
        lock.unlock()

        for hit in toReport {
            writeDebugLog(
                "[Traffic] date=\(hit.date) path=\(url.path) ctx=\(hit.context)"
            )
        }
    }

    /// `NNNN-NN-NN` 的形状判定（只查形状，不查合法性 —— 宁可多报一行也别漏）。
    private static func isISODatePrefix(_ bytes: [UInt8], at index: Int) -> Bool {
        for offset in 0..<10 {
            let byte = bytes[index + offset]
            switch offset {
            case 4, 7:
                if byte != 0x2D { return false }        // '-'
            default:
                if byte < 0x30 || byte > 0x39 { return false }   // 0-9
            }
        }
        return true
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
            // 正在播放页元素列表：补卡片，或「禁用歌词功能」时**摘掉**卡片。
            // ⚠️ 注意 `BrowsitaSectionStripper.shouldHandle` 本身就覆盖 `/scrollsita/`，
            // 所以上一行已经让这个 URL 进入改写流程 —— 这一条只决定 `patch()` 里
            // "要不要注入那个 5 元素"；把开关关掉**不会**影响去广告那一步。
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
        // 诊断：scrollsita 的**每一条**响应都打一份元素清单 —— 与开关无关，永远打。
        //
        // 这是排查"预热卡时有时无 / 第一次进页面和退出重进不一样"的唯一直接证据：
        // 同一首歌在不同时刻拿到的元素列表**可能不是同一份**，而"没有注入日志"本身
        // 分不出"服务端本来就带那个元素"和"客户端走了缓存、我们没看到响应"。
        // 见 `ScrollsitaLyricsElementInjector.logElementManifest`。
        if ScrollsitaLyricsElementInjector.shouldHandle(url) {
            ScrollsitaLyricsElementInjector.logElementManifest(url: url, body: buffer)
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
