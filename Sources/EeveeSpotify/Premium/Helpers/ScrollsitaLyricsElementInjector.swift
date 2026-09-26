import Foundation

/// 往 `scrollsita/v1/scroll/spotify:track:<id>` 的响应里补一个「歌词卡片」元素。
///
/// ── 为什么怀疑卡片位置出自这里（2026-09-25 真机取证，日志 18）────────────────
///
/// 该接口按曲目返回**正在播放页的元素列表**（`关于艺人`、`探索 <artist>`、canvas …）。
/// 同一批样本按 wire format 解出来的元素（括号里是元素的内层字段号）：
///
/// | 曲目 | color-lyrics | 元素 |
/// |---|---|---|
/// | `7dUKNjRiLxS2OXRldCIjH4`（SECRET） | **200**（Spotify 有官方词） | **5**, 2, 3, 4 |
/// | `5utfun3R35e5AsBalPSxBe`（最後の希望） | 404 | 2, 3, 4 |
/// | `1MbA2hu0f2NCnO114X1BP6` | 404 | 2, 3, 4 |
///
/// 那个多出来的 `5` **只引用曲目 URI**（不引用艺人），且只在"Spotify 有官方歌词"的曲目上
/// 出现。而唯一一次肉眼确认看到歌词卡片（卡片上显示的 provider 是我们自己写死的
/// `EeveeForce…`）正是 SECRET —— 也就是说：**卡片的内容**来自我们替换的 color-lyrics
/// 响应，**卡片的位置/存在性**来自这份元素列表。
///
/// 这与"开关关掉后 404 曲目什么都不显示"也吻合：没有 `5` → 没有卡片；
/// payload 无时间轴 → 连封面下那行（面 A）也没有。
///
/// → 假设：`5` = 歌词卡片元素，服务端只对自己库里有词的曲目下发。
///   那就把缺的这一项**补进响应里** —— 这是唯一能改到它的位置。
///
/// 若要验证这个假设，见 `EeveeSpotifySettingsView` 里那个实验开关（默认关）。
///
/// ── 安全边界（重要）────────────────────────────────────────────────────────
/// · 只在 `shouldHandle` 命中的 path 上动手，且**只在缺少 `5` 时**追加；
/// · 全程按 protobuf wire format 解析，任何一步不符合预期 → 返回 nil（**原样放行**，
///   绝不"猜着改"）—— 坏掉的响应会让整个正在播放页出问题，宁可什么都不做；
/// · 组装完再重新解析一遍自检，过不了就返回 nil。
enum ScrollsitaLyricsElementInjector {

    /// SECRET 那条响应里 `5` 元素用的 section。
    ///
    /// 各元素类型的 section 是**跨曲目固定**的，同一份响应里就能看到重复：
    /// `…Gq1L` = 关于艺人、`…DABRtFWApcy61XJEwt` = 探索、`…Gq1O` = canvas，
    /// 而这一项用的是 `…Gq21`（在另外两首没有歌词的曲目里都不出现）。
    private static let lyricsSectionURI = "spotify:section:0JQ5DB6s3cssW5Bo6cGq21"

    static func shouldHandle(_ url: URL) -> Bool {
        url.path.contains("/scrollsita/v1/scroll/spotify:track:")
    }

    // MARK: - 诊断：**每一条**响应的元素清单

    /// 打出这份元素列表里每个元素的**类型号**与它内部的 `spotify:` URI。只读、只打日志。
    ///
    /// 为什么必须"每条都打"：正在播放页的模块列表会在不同时刻被重新请求，而同一首歌
    /// 拿到的**内容并不总是同一份**（预取 / 重进 / 客户端缓存都会改变它）。真机观察到的
    /// 现象是"预热卡一会有一会没有、第一次进页面和退出重进还不一样"—— 那最可能就是
    /// 列表内容不同，而不是渲染问题。
    ///
    /// 改动前只有"注入成功"才打一行，于是三种完全不同的情况共用一片静默：
    ///   · 服务端本来就发了 `5`（没动手，正常）；
    ///   · 解析不过 / 不是元素列表（不敢动）；
    ///   · 客户端压根没走网络（我们连响应都没看到）。
    ///
    /// 解析刻意**不用严格 wire format**：元素类型取条目的第一个字段号（那是结构性的、
    /// 必须准），而元素内容用"扫 ASCII 里的 `spotify:` 串"来呈现 —— 这样即使某条响应
    /// 的结构变了，也还能看见它引用了哪首曲目 / 哪张专辑，而不是只剩一片空白。
    static func logElementManifest(url: URL, body: Data) {
        let track = trackURI(from: url) ?? "?"
        let bytes = [UInt8](body)
        var index = 0

        guard let firstKey = readVarint(bytes, &index),
              firstKey >> 3 == 1, firstKey & 7 == 2,
              let elementList = readLengthDelimited(bytes, &index) else {
            writeDebugLog(
                "[Scrollsita] manifest track=\(track) body=\(bytes.count)B"
                    + " — not an element list (left untouched)"
            )
            return
        }

        var cursor = 0
        var descriptions: [String] = []
        var has5 = false
        var truncated = false

        while cursor < elementList.count {
            guard let key = readVarint(elementList, &cursor),
                  key >> 3 == 1, key & 7 == 2,
                  let item = readLengthDelimited(elementList, &cursor) else {
                descriptions.append("<?>")
                break
            }

            var itemIndex = 0
            guard let innerKey = readVarint(item, &itemIndex) else {
                descriptions.append("<?>")
                continue
            }

            let type = innerKey >> 3
            if type == lyricsElementFieldNumber { has5 = true }

            // 上限：元素最多列 12 个（实测一条响应 2–6 个；5utfun 那种 33KB 的推广响应会更多）。
            if descriptions.count < 12 {
                let uris = spotifyURIs(in: item)
                descriptions.append(uris.isEmpty ? "\(type)" : "\(type){\(uris.joined(separator: ","))}")
            } else {
                truncated = true
            }
        }

        writeDebugLog(
            "[Scrollsita] manifest track=\(track) body=\(bytes.count)B has5=\(has5)"
                + " elements=[\(descriptions.joined(separator: " "))]"
                + (truncated ? " …(truncated)" : "")
        )
    }

    /// 从一段元素字节里捞出 `spotify:` 开头的可打印串（去重、最多 3 条）。
    ///
    /// `spotify:section:` 只留末尾 6 个字符 —— 它们前缀完全相同（`spotify:section:0JQ5DB6s3cssW5Bo6c`），
    /// 全长会把日志撑爆；而区分靠的正是尾部（`…cGq21` / `…cGq1L` / `…cGq1O` / `…1XJEwt`）。
    private static func spotifyURIs(in bytes: [UInt8]) -> [String] {
        let needle = Array("spotify:".utf8)
        var found: [String] = []
        var i = 0

        while i + needle.count <= bytes.count {
            var matched = true
            for k in 0..<needle.count where bytes[i + k] != needle[k] {
                matched = false
                break
            }
            guard matched else {
                i += 1
                continue
            }

            var j = i
            while j < bytes.count, isURIScalar(bytes[j]) { j += 1 }
            let raw = String(decoding: bytes[i..<j], as: UTF8.self)
            i = max(j, i + 1)

            let short: String
            if raw.hasPrefix("spotify:section:"), raw.count > 6 {
                short = "…" + String(raw.suffix(6))
            } else if raw.count > 40 {
                short = String(raw.prefix(40)) + "…"
            } else {
                short = raw
            }

            if !found.contains(short) {
                found.append(short)
                if found.count >= 3 { break }
            }
        }

        return found
    }

    /// URI 里允许出现的字节（字母数字 + `:` `.` `_` `-` `+`）。
    private static func isURIScalar(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x3A, 0x2E, 0x5F, 0x2D, 0x2B:
            return true
        default:
            return false
        }
    }

    /// 把服务端下发的「歌词卡片」元素**摘掉**（「禁用歌词功能」时用）。
    ///
    /// 为什么需要：卡片的存在性来自这份元素列表（§7 的结论）。所以哪怕我们不再替换歌词，
    /// 只要服务端还下发这一项，卡片就照样在（只是内容变成我们那份"未找到歌词"）——
    /// 用户开了「禁用歌词功能」却仍看到歌词卡片，观感就是"选项不生效"。
    ///
    /// 与注入同一条安全边界：解析不过就返回 nil（原样放行），组装后再自检一遍。
    static func strippingLyricsElementIfNeeded(url: URL, body: Data) -> Data? {
        guard NgzhwmSettingsViewModel.isLyricsFeatureDisabled, shouldHandle(url) else { return nil }

        let bytes = [UInt8](body)
        var index = 0

        guard let firstKey = readVarint(bytes, &index),
              firstKey >> 3 == 1, firstKey & 7 == 2,
              let elementList = readLengthDelimited(bytes, &index) else {
            return nil
        }
        let trailing: [UInt8] = index < bytes.count ? Array(bytes[index...]) : []

        // 逐个 item 过一遍：内层第一个字段号就是"元素类型"，`5` 就是歌词卡片。
        var cursor = 0
        var kept: [UInt8] = []
        var removed = 0

        while cursor < elementList.count {
            let itemStart = cursor
            guard let key = readVarint(elementList, &cursor),
                  key >> 3 == 1, key & 7 == 2,
                  let item = readLengthDelimited(elementList, &cursor) else {
                return nil
            }

            var itemIndex = 0
            guard let innerKey = readVarint(item, &itemIndex), innerKey & 7 == 2 else {
                return nil
            }

            if innerKey >> 3 == lyricsElementFieldNumber {
                removed += 1
            } else {
                kept += Array(elementList[itemStart..<cursor])
            }
        }

        guard removed > 0 else { return nil }   // 本来就没有这一项 → 不动

        var result: [UInt8] = [0x0A]
        result += encodeVarint(kept.count)
        result += kept
        result += trailing

        // 自检：还能完整解析，且 `5` 确实没了。
        var check = 0
        guard let checkKey = readVarint(result, &check),
              checkKey >> 3 == 1, checkKey & 7 == 2,
              let checkedList = readLengthDelimited(result, &check),
              let checkedNumbers = elementFieldNumbers(checkedList),
              !checkedNumbers.contains(lyricsElementFieldNumber) else {
            writeDebugLog("[Scrollsita] ⚠️ strip self-check failed — leaving the body untouched")
            return nil
        }

        writeDebugLog(
            "[Scrollsita] stripped lyrics-card element ×\(removed)"
                + " (lyrics feature disabled) — body \(bytes.count)B -> \(result.count)B"
        )
        return Data(result)
    }

    /// 需要注入时返回**新的一份 body**；不需要/不敢动时返回 nil（调用方原样放行）。
    static func injectIfNeeded(url: URL, body: Data) -> Data? {
        guard NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled,
              !NgzhwmSettingsViewModel.isLyricsFeatureDisabled,
              shouldHandle(url),
              let trackURI = trackURI(from: url) else {
            return nil
        }

        let bytes = [UInt8](body)
        var index = 0

        // 顶层第一个字段就是元素列表（field 1, wire type 2）。
        guard let firstKey = readVarint(bytes, &index),
              firstKey >> 3 == 1, firstKey & 7 == 2,
              let elementList = readLengthDelimited(bytes, &index) else {
            return nil
        }
        // 其余字段（scroll id 等）原样接在后面。
        let trailing: [UInt8] = index < bytes.count ? Array(bytes[index...]) : []

        guard let present = elementFieldNumbers(elementList) else { return nil }
        // 已经有了 → 服务端认为这首歌有词，什么都不用做。
        guard !present.contains(Self.lyricsElementFieldNumber) else { return nil }

        // ── 组装一个与 SECRET 那条**完全同形**的元素 ──
        //
        //   item = 0a <len> { 2a <len> { 0a <len> "<track uri>" }
        //                     ba 01 <len> { 0a <len> "<section uri>" } }
        let trackURIBytes = Array(trackURI.utf8)
        let sectionURIBytes = Array(Self.lyricsSectionURI.utf8)

        var elementBody: [UInt8] = [0x0A] + encodeVarint(trackURIBytes.count) + trackURIBytes
        elementBody = [0x2A] + encodeVarint(elementBody.count) + elementBody

        var sectionBody: [UInt8] = [0x0A] + encodeVarint(sectionURIBytes.count) + sectionURIBytes
        sectionBody = [0xBA, 0x01] + encodeVarint(sectionBody.count) + sectionBody

        let inner = elementBody + sectionBody
        let item: [UInt8] = [0x0A] + encodeVarint(inner.count) + inner

        let newElementList = item + elementList

        var result: [UInt8] = [0x0A]
        result += encodeVarint(newElementList.count)
        result += newElementList
        result += trailing

        // ── 自检：能完整解析、且 `5` 已经在里面，才交出去 ──
        var check = 0
        guard let checkKey = readVarint(result, &check),
              checkKey >> 3 == 1, checkKey & 7 == 2,
              let checkedList = readLengthDelimited(result, &check),
              let checkedNumbers = elementFieldNumbers(checkedList),
              checkedNumbers.contains(Self.lyricsElementFieldNumber) else {
            writeDebugLog("[Scrollsita] ⚠️ self-check failed — leaving the body untouched")
            return nil
        }

        writeDebugLog(
            "[Scrollsita] injected lyrics-card element — track=\(trackURI)"
                + " body \(bytes.count)B -> \(result.count)B"
        )
        return Data(result)
    }

    // MARK: - wire format 小工具（只为这个文件服务）

    /// 歌词卡片元素的内层字段号（来自上面那张对照表）。
    private static let lyricsElementFieldNumber = 5

    /// 列出这份元素列表里每个元素的内层字段号。
    ///
    /// 「元素类型」在 wire format 里就是 item 自己的第一个字段号：`2` = 关于艺人、
    /// `3` = 探索、`4` = canvas、`5` = 待验证的那一项（假设是歌词卡片）。
    /// 任何一步不符合预期 → nil（调用方放弃注入）。
    private static func elementFieldNumbers(_ elementList: [UInt8]) -> Set<Int>? {
        var index = 0
        var numbers = Set<Int>()

        while index < elementList.count {
            guard let key = readVarint(elementList, &index),
                  key >> 3 == 1, key & 7 == 2,
                  let item = readLengthDelimited(elementList, &index) else {
                return nil
            }

            var itemIndex = 0
            guard let innerKey = readVarint(item, &itemIndex), innerKey & 7 == 2 else {
                return nil
            }
            numbers.insert(innerKey >> 3)
        }

        return numbers.isEmpty ? nil : numbers
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var value = 0
        var shift = 0

        while index < bytes.count {
            let byte = Int(bytes[index])
            index += 1
            value |= (byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 28 { return nil }
        }

        return nil
    }

    private static func readLengthDelimited(_ bytes: [UInt8], _ index: inout Int) -> [UInt8]? {
        guard let length = readVarint(bytes, &index),
              length >= 0, index + length <= bytes.count else {
            return nil
        }

        let payload = Array(bytes[index..<(index + length)])
        index += length
        return payload
    }

    private static func encodeVarint(_ value: Int) -> [UInt8] {
        var remaining = UInt64(max(value, 0))
        var out: [UInt8] = []

        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0

        return out
    }

    private static func trackURI(from url: URL) -> String? {
        let marker = "/scrollsita/v1/scroll/"
        guard let range = url.path.range(of: marker) else { return nil }

        let uri = String(url.path[range.upperBound...])
        guard uri.hasPrefix("spotify:track:") else { return nil }
        return uri
    }
}
