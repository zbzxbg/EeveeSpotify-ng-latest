import Foundation
import NaturalLanguage

extension Array where Element == String {
    var canBeRomanized: Bool {
        // 含假名的行直接算日语：与 dominantCJKLanguageAbove / romanizationLanguageCode
        // 用同一套判定。否则逐行识别可能把日文判成非 CJK，使状态退化成 .original，
        // 而 .original 会让 toSpotifyLyricsData 的总闸 canRomanize = false ——
        // 三个罗马化开关会一起失效（日志里的 `romanization=original` 就是这个）。
        if contains(where: { $0.containsJapaneseKanaForRomanization }) {
            return true
        }

        var languageList: [NLLanguage] = []
        
        for line in self {
            if let language = NLLanguageRecognizer.dominantLanguage(for: line) {
                languageList.append(language)
            }
        }
        
        return languageList.contains {
            [.japanese, .korean, .simplifiedChinese, .traditionalChinese].contains($0)
        }
    }

    /// 整首歌语言占比检测：把所有行合并后交给 NLLanguageRecognizer，
    /// 返回占比最高且高于阈值的 CJK 语言（日语/韩语/中文）；否则返回 nil。
    func dominantCJKLanguageAbove(threshold: Double) -> NLLanguage? {
        // 只要出现假名就直接判定为日语。
        // 原因：NLLanguageRecognizer 对「汉字偏多 / 文本较短」的日文经常给出
        // simplifiedChinese，而 LyricsDto.romanizedIfEnabled 里 songLanguage 的
        // 优先级高于上游算出的 languageHint —— 一旦这里判成中文，就会盖掉
        // romanizationLanguageCode（它自带假名兜底）已经算对的 "ja"，
        // 于是「只开日语罗马化」时整首歌都不会被罗马化。
        if contains(where: { $0.containsJapaneseKanaForRomanization }) {
            return .japanese
        }

        let text = self.joined(separator: "\n")
        guard !text.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let cjk: [NLLanguage] = [.japanese, .korean, .simplifiedChinese, .traditionalChinese]
        // 先在 guard 外算出候选：guard/if 条件里不能使用尾随闭包，
        // 否则 { } 会被解析成新的语句（"consecutive statements..." 语法错）。
        let topCJK = hypotheses
            .filter { cjk.contains($0.key) }
            .max { $0.value < $1.value }
        guard let top = topCJK, top.value > threshold else { return nil }

        return top.key
    }

    /// 统计各语言行数，返回占比最高的 CJK 语言代码（ja/ko/zh）；无则返回 nil。
    /// SpicyLyrics 逐字解析结果用它作为罗马化语言提示。
    var romanizationLanguageCode: String? {
        var languageCounts: [NLLanguage: Int] = [:]

        for line in self {
            let language: NLLanguage?
            if line.containsJapaneseKanaForRomanization {
                language = .japanese
            } else {
                language = NLLanguageRecognizer.dominantLanguage(for: line)
            }

            guard let language,
                  [.japanese, .korean, .simplifiedChinese, .traditionalChinese]
                    .contains(language)
            else {
                continue
            }

            languageCounts[language, default: 0] += 1
        }

        guard let dominantLanguage = languageCounts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }

        switch dominantLanguage {
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .simplifiedChinese, .traditionalChinese:
            return "zh"
        default:
            return nil
        }
    }
}

private extension String {
    var containsJapaneseKanaForRomanization: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }
    }
}
