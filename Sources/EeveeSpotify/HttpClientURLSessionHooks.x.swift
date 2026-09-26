import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            let token = String(auth.dropFirst(7))
            setSpotifyAccessToken(token)
            // TEMP DEBUG: log token shape + source URL, never the token itself.
            let dotCount = token.filter { $0 == "." }.count
            let shape = "len=\(token.count) dots=\(dotCount) prefix=\(token.prefix(6))"
            writeDebugLog("[TokenCapture] \(shape) from \(task.currentRequest?.url?.absoluteString ?? "<no url>")")
        }

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponsePatcher.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponsePatcher.blockedResponseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // marked for modify but no body bytes (0-byte/early-completion/redirect).
            // Always forward completion or Spotify hangs and gets watchdog-killed.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // We previously forwarded completion only, which can crash callers that
                // assume at least one didReceiveData before completion.
                writeDebugLog("[HCUS] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)

                // 「禁用歌词功能」：**主动挡掉 Spotify 自带的那份歌词**。
                //
                // 选项说明原话就是"还会阻止 Spotify 返回其自带的歌词"，而这里以前走的是
                // 下面的 `lyricsPayload = buffer`（取词抛 `.invalidSource` → 放行原始响应），
                // 于是开关打开后官方歌词照旧显示 —— 观感即"选项不生效"。
                if SpotifyResponsePatcher.isLyricsFeatureDisabled {
                    let blocked = SpotifyResponsePatcher.disabledLyricsPayload(original: originalLyrics)
                    writeDebugLog("[HCUS] lyrics feature disabled — blocking Spotify's own lyrics")
                    orig.URLSession(session, dataTask: task, didReceiveData: blocked)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                    return
                }

                let semaphore = DispatchSemaphore(value: 0)
                var customLyricsData: Data?
                DispatchQueue.global(qos: .userInitiated).async {
                    customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                    semaphore.signal()
                }
                let waitResult = semaphore.wait(timeout: .now() + .milliseconds(18000))
                // 同 SPTDataLoaderService：预算内没拿到词也要给一份可解析的占位，
                // 否则这次歌词请求等于"没有响应"，NPV 不会创建歌词卡片。
                // 见 `unavailableLyricsBytes`（CustomLyrics.x.swift 文件作用域函数）。
                let lyricsPayload: Data
                if let customLyricsData {
                    lyricsPayload = customLyricsData
                } else if waitResult == .timedOut {
                    writeDebugLog("[HCUS] lyrics fetch exceeded the 18s budget — serving fallback payload")
                    lyricsPayload = unavailableLyricsBytes(original: originalLyrics) ?? buffer
                } else {
                    lyricsPayload = buffer
                }
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        // 诊断：记录歌词响应的原始状态与响应头（**200 与 404 两种都记**）。
        // 见 `SpotifyResponsePatcher.probeLyricsResponseHeaders` 的说明。
        if let probeURL = task.currentRequest?.url {
            SpotifyResponsePatcher.probeLyricsResponseHeaders(url: probeURL, response: response)
            // 正在播放页的「旁路模块」（预热卡嫌疑来源）：状态 + Content-Type。
            SpotifyResponsePatcher.probeNPVModuleHeaders(url: probeURL, response: response)
            // 全量请求清单：每一条响应一行（预热卡排查的"某条请求到底发生过没有"）。
            SpotifyResponsePatcher.probeTrafficHeaders(url: probeURL, response: response)
        }

        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // 「禁用歌词功能」：这条路以前会**无条件**合成 200 + 我们的占位（"未找到歌词"），
        // 于是开关打开后我们那份照样出现。禁用时直接放行原始 404（等于"这首歌没有歌词"），
        // 既不取词、也不合成 —— 真正的"什么都不做"。
        if SpotifyResponsePatcher.isLyricsFeatureDisabled {
            writeDebugLog("[HCUS] lyrics feature disabled — passing the \(response.statusCode) through")
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Fetch on a background queue while holding the completion handler open.
        // Calling getLyricsDataForCurrentTrack synchronously here would block the
        // delegate queue and prevent subsequent delegate callbacks from firing.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let data = try? getLyricsDataForCurrentTrack(url.path)
            // 同 SPTDataLoaderService：404 也要给出 200 + 占位，
            // 否则 Spotify 不会为这首歌创建歌词卡片。见 `unavailableLyricsBytes`。
            let payload = data ?? unavailableLyricsBytes(original: nil)

            guard let lyricsData = payload,
                  let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                handler(.allow)
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                return
            }

            orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }
        if SpotifyResponsePatcher.shouldBlock(url) { return }
        // 排障：扫一下这块数据里有没有 `has_lyrics`，定位它的线上来源（只读、不改字节）。
        SpotifyResponsePatcher.probeHasLyricsKey(url: url, taskID: task.taskIdentifier, data: data)
        // 排障：正在播放页的「旁路模块」响应体（预热卡的嫌疑来源）。只读、不改字节。
        SpotifyResponsePatcher.probeNPVModuleBody(url: url, taskID: task.taskIdentifier, data: data)
        // 排障：全响应扫「预热 / 预发行」关键字（坏卡的数据来源）。只读、不改字节。
        SpotifyResponsePatcher.probePreReleaseNeedles(url: url, taskID: task.taskIdentifier, data: data)
        // 排障：全量请求清单 + ISO 日期串（找到"那张卡拿到的日期"到底搭哪条响应来）。只读、不改字节。
        SpotifyResponsePatcher.probeTrafficBody(url: url, taskID: task.taskIdentifier, data: data)
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
