import Foundation

extension UserDefaults {
    @UserDefault(
        key: "lyricsOptions",
        defaultValue: LyricsOptions(
            musixmatchLanguage: Locale.current.languageCode ?? "",
            lrclibUrl: LrclibLyricsRepository.originalApiUrl,
            geniusFallback: false,
            hideOnError: false
        )
    )
    static var lyricsOptions
}
