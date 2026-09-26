import SwiftUI
import Combine

extension EeveeLyricsSettingsViewModel {
    func setupBindings() {
        $lyricsOptions
            .map(\.musixmatchLanguage)
            .sink { [weak self] language in
                guard let self = self else { return }
                
                let isValidLanguage = language.isEmpty || language ~= "^[\\w\\d]{2}$"
                
                if isValidLanguage {
                    self.showMusixmatchInvalidLanguageWarning = false
                    MusixmatchLyricsRepository.shared.selectedLanguage = language
                    return
                }
                
                self.showMusixmatchInvalidLanguageWarning = true
            }
            .store(in: &cancellables)
        
        $lyricsOptions
            .map(\.lrclibUrl)
            .map { urlString -> AnyPublisher<LrclibURLState, Never> in
                guard let url = URL(string: urlString) else {
                    return Just(.invalidURL).eraseToAnyPublisher()
                }
                
                if url.host == "lrclib.net" {
                    return Just(.originalURL).eraseToAnyPublisher()
                }
                
                return URLSession.shared.dataTaskPublisher(for: url)
                    .map { _ in
                        LrclibLyricsRepository.shared.apiUrl = urlString
                        return LrclibURLState.ok
                    }
                    .catch { _ in Just(LrclibURLState.unreachableURL) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lrclibURLState)
        
        $musixmatchToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tokenString in
                guard let self = self else { return }
                
                if let token = self.getMusixmatchTokenFromDebugInfo(tokenString) {
                    self.musixmatchToken = token
                    return
                }
                
                if let token = self.getMusixmatchToken(tokenString) {
                    UserDefaults.musixmatchToken = token
                    writeDebugLog("[Musixmatch] token saved (length \(token.count))")
                } else if !tokenString.isEmpty {
                    // 以前这里是静默失败：输入框显示你粘的内容，UserDefaults 里却仍是旧值（可能是空的），
                    // 于是请求带着空 usertoken 出去，在 Musixmatch 边缘就被拒。
                    writeDebugLog(
                        "[Musixmatch] token rejected — 需要 54 位小写十六进制，实际长度 \(tokenString.count)"
                    )
                }
            }
            .store(in: &cancellables)
        
        $lyricsSource
            .dropFirst()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                
                if newSource == .lrclib {
                    self.lyricsOptions.lrclibUrl = LrclibLyricsRepository.originalApiUrl
                }
                
                UserDefaults.lyricsSource = newSource
            }
            .store(in: &cancellables)

        // ── 设置项变更日志 ───────────────────────────────────────────────────
        //
        // ⚠️ 起因：改任何开关过去只有**副作用**日志（比如"hide translation enabled"
        // 会出现在取词流程里），没有"用户在什么时候把哪个开关改成了什么"的时间线。
        // 排查"这个行为差异是不是设置造成的"时，只能靠猜当时是什么配置。
        //
        // 全部走 `.dropFirst()`：订阅时会先收到一次当前值，那是页面打开、不是用户改动，
        // 记下来会污染时间线。之后每次真实改动记一行。
        //
        // 写入量：只在用户真的拨开关时触发，不在任何每帧路径上。所以不用节流。
        logSettingChanges()
    }

    /// 订阅一批 `@Published` 设置项，值一变就记一行 `[Settings] 名称 -> ON/OFF`。
    ///
    /// ⚠️ 这里**只能记新值，不能记"原值"**：这些属性是 `didSet` 里写 UserDefaults，
    /// 而 `@Published` 的 `willSet` 就已经把 `self.xxx` 更新了 —— 所以 sink 里
    /// 再读 `self.xxx` 拿到的是**新值**，写"原值"会是假的。宁可不记。
    private func logBooleanSetting(_ publisher: Published<Bool>.Publisher, _ name: String) {
        publisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { newValue in
                writeDebugLog("[Settings] \(name) -> \(newValue ? "ON" : "OFF")")
            }
            .store(in: &cancellables)
    }

    /// 见 `logBooleanSetting` 的说明。这里单独铺开每个开关而不是泛型循环，
    /// 是为了让"到底记了哪些开关"在代码里一眼可数 —— 少记一个不容易被发现。
    private func logSettingChanges() {
        logBooleanSetting($wordByWordLyrics, "word-by-word lyrics")
        logBooleanSetting($betterWordByWordLyrics, "better word-by-word lyrics")
        // 已移除：`$amllPreferred`（「AMLL 优先」整条链已删除）。
        // 「隐藏官方歌词」已写死启用（见 NgzhwmSettingsViewModel），设置页不再有开关，
        // 因此这里也没有可记录的绑定。
        // 下面这两条都是 A/B 的分组标记：日志里能直接看出"这一场到底补没补时间轴、
        // 有没有往 scroll 元素列表里补卡片元素"。
        logBooleanSetting($syntheticLineTiming, "synthetic line timing")
        logBooleanSetting($injectLyricsCardElement, "inject lyrics card element")
        logBooleanSetting($disableLyricsFeature, "disable lyrics feature")
        logBooleanSetting($removeMxmInterludeSymbol, "remove interlude symbol")
        logBooleanSetting($neteaseRomajiLocal, "NetEase romaji display mode")
        logBooleanSetting($neteaseHideTranslation, "hide NetEase translation")
        logBooleanSetting($chineseRomanization, "Chinese romanization")
        logBooleanSetting($japaneseRomanization, "Japanese romanization")
        logBooleanSetting($koreanRomanization, "Korean romanization")

        // 来源选择器：不是 Bool，单独一条。
        // ⚠️ 值用 `UserDefaults.lyricsSource`（持久化的那份），不是 `self.lyricsSource` ——
        // 后者在 sink 里读会踩"闭包捕获可变 self"，而且如上所述已经是新值了。
        $lyricsSource
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                writeDebugLog("[Settings] lyrics source -> \(UserDefaults.lyricsSource.description)")
            }
            .store(in: &cancellables)
    }
}
