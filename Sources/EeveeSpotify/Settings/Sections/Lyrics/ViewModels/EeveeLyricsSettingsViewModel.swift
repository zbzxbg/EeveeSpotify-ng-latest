import SwiftUI
import Combine

class EeveeLyricsSettingsViewModel: ObservableObject {
    @Published var lyricsSource = UserDefaults.lyricsSource
    
    @Published var lyricsOptions = UserDefaults.lyricsOptions {
        didSet { UserDefaults.lyricsOptions = lyricsOptions }
    }
    
    @Published var chineseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") {
        didSet { UserDefaults.standard.set(chineseRomanization, forKey: "ngzhwm_chineseRomanization") }
    }
    @Published var japaneseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
        didSet { UserDefaults.standard.set(japaneseRomanization, forKey: "ngzhwm_japaneseRomanization") }
    }
    @Published var koreanRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") {
        didSet { UserDefaults.standard.set(koreanRomanization, forKey: "ngzhwm_koreanRomanization") }
    }
    
    @Published var wordByWordLyrics = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                wordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.wordByWordLyricsKey
            )
        }
    }
    
    @Published var betterWordByWordLyrics = NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                betterWordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.betterWordByWordLyricsKey
            )
        }
    }
    
    @Published var amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred {
        didSet {
            UserDefaults.standard.set(
                amllPreferred,
                forKey: NgzhwmSettingsViewModel.amllPreferredKey
            )
        }
    }
    
    @Published var hideOfficialLyrics = NgzhwmSettingsViewModel.isOfficialLyricsHidden {
        didSet {
            UserDefaults.standard.set(
                hideOfficialLyrics,
                forKey: NgzhwmSettingsViewModel.hideOfficialLyricsKey
            )
        }
    }
    
    // 注：背景相关（模糊封面 / 系统材质）**没有** Published 属性 ——
    // 它们不是用户可选项，而是跟随「更好的逐词歌词」自动启用。
    // 见 NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled。
    
    @Published var disableLyricsFeature = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
    ) {
        didSet {
            UserDefaults.standard.set(
                disableLyricsFeature,
                forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
            )
        }
    }
    
    @Published var removeMxmInterludeSymbol = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
    ) {
        didSet {
            UserDefaults.standard.set(
                removeMxmInterludeSymbol,
                forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
            )
        }
    }
    
    @Published var neteaseRomajiLocal = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
    ) {
        didSet {
            UserDefaults.standard.set(
                neteaseRomajiLocal,
                forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
            )
        }
    }
    
    @Published var neteaseHideTranslation = NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled {
        didSet {
            UserDefaults.standard.set(
                neteaseHideTranslation,
                forKey: NgzhwmSettingsViewModel.neteaseHideTranslationKey
            )
        }
    }
    
    /// Musixmatch 用户令牌。
    ///
    /// ⚠️ 这里**只剩手动填写**一条路。
    ///
    /// 以前还有一条"匿名令牌"路径：`isRequestingMusixmatchToken` +
    /// `musixmatchTokenInputAlertPublisher` + `requestAnonymousMusixmatchToken()`，
    /// 走 `apic.musixmatch.com/ws/1.1/token.get` 不授权换一个令牌。
    /// 已整体移除（设置项按钮、来源弹窗里的同名选项、失败提示弹窗一起删）。
    ///
    /// 连带删掉的状态说明：
    ///   · `isRequestingMusixmatchToken` 只用来给那个按钮画转圈、以及把整个设置页
    ///     `.disabled` 掉。没有按钮之后它永远是 false，留着就是死状态；
    ///   · `musixmatchTokenInputAlertPublisher` 从来没有任何地方 `send` 过
    ///     （`EeveeLyricsSettingsView` 的 `.onReceive` 是收不到东西的），
    ///     属于同一批残留，一起删。
    @Published var musixmatchToken = UserDefaults.musixmatchToken
    var isMusixmatchTokenValid: Bool { getMusixmatchToken(musixmatchToken) != nil }
    
    @Published var showMusixmatchInvalidLanguageWarning = false
    @Published var lrclibURLState = LrclibURLState.default
    
    var animationValues: [AnyHashable] {
        [
            lyricsSource,
            lyricsOptions,
            betterWordByWordLyrics,
            wordByWordLyrics,
            amllPreferred,
            hideOfficialLyrics,
            disableLyricsFeature,
            removeMxmInterludeSymbol,
            neteaseRomajiLocal,
            neteaseHideTranslation,
            isMusixmatchTokenValid,
            lrclibURLState,
            showMusixmatchInvalidLanguageWarning
        ]
    }
    
    var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }
    
    func getMusixmatchTokenFromDebugInfo(_ debugInfo: String) -> String? {
        if let match = debugInfo.firstMatch("\\[UserToken\\]: ([a-f0-9]+)"),
            let tokenRange = Range(match.range(at: 1), in: debugInfo) {
            return String(debugInfo[tokenRange])
        }
        
        return nil
    }
    
    func getMusixmatchToken(_ input: String) -> String? {
        if input ~= "^[a-f0-9]{54}$" {
            return input
        }
        
        return nil
    }
}
