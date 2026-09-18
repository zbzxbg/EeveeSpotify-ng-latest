import Foundation

/// Fills in words that the SpicyLyrics API's upstream provider censors
/// (rendered as a run of asterisks, e.g. "f***" or "****") by
/// cross-referencing the same track's lyrics from another, uncensored
/// source — rather than guessing a fixed word for every asterisk run,
/// which is unsound: different songs censor different words, and a
/// hardcoded substitution would corrupt lines that never contained the
/// guessed word at all.
///
/// Genius and Musixmatch's lyrics databases are licensed/community full
/// text, not run through a profanity filter the way chat moderation or
/// speech-to-text services are — they're very likely to carry the actual
/// word SpicyLyrics' specific upstream censors. LRCLIB is community-
/// submitted plain lyrics, also typically uncensored. We try sources in
/// that order and only ever substitute a token when we find a confident,
/// position-matched replacement — if no source has a matching line, or
/// the word counts don't line up, the asterisks are left as-is rather
/// than guessed at.
struct LyricsUncensorFill {
    /// A run of 3+ asterisks, optionally adjacent to punctuation —
    /// the form a fully-censored word takes (as opposed to a partial
    /// self-censor like "f**k" or "sh*t", which we deliberately leave
    /// alone — those are the original artist/source's own stylistic
    /// choice, not something to "fix").
    private static let fullCensorPattern = try! NSRegularExpression(pattern: #"\b\*{3,}\b"#)

    /// Returns a new array of line texts with censored tokens filled in
    /// where a confident match was found, otherwise unchanged. Operates
    /// on plain line strings (not the syllable model) since cross-source
    /// matching is done at the word level on flattened text — the syllable
    /// timing itself doesn't need to change, only the displayed text.
    static func fill(
        lines: [String],
        query: LyricsSearchQuery,
        options: LyricsOptions
    ) -> [String] {
        guard lines.contains(where: { containsFullCensor($0) }) else {
            return lines // nothing to do — avoid fallback network calls entirely
        }

        let fallbackSources: [LyricsRepository] = [
            LrclibLyricsRepository.shared,
            MusixmatchLyricsRepository.shared,
            GeniusLyricsRepository(),
        ]

        var result = lines
        for source in fallbackSources {
            guard let fallbackLines = try? source.getLyrics(query, options: options).lines.map(\.content),
                  !fallbackLines.isEmpty else { continue }

            result = attemptFill(censored: result, candidate: fallbackLines)

            if !result.contains(where: { containsFullCensor($0) }) {
                break // fully resolved, no need to try further sources
            }
        }
        return result
    }

    private static func containsFullCensor(_ line: String) -> Bool {
        fullCensorPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Matches censored lines to candidate lines by word count (a cheap,
    /// reasonably reliable signal — a censored line and its real
    /// counterpart have the same number of words, since only one word's
    /// *content* changes, not the line's structure) and, within a matched
    /// line, substitutes only the word at the same position as the
    /// asterisk run. Lines that don't have a clean 1:1 word-count match
    /// in the candidate source are left untouched rather than guessed at.
    private static func attemptFill(censored: [String], candidate: [String]) -> [String] {
        var output = censored

        for (index, line) in censored.enumerated() {
            guard containsFullCensor(line) else { continue }

            let censoredWords = line.split(separator: " ")
            guard let match = candidate.first(where: { candidateLine in
                let candidateWords = candidateLine.split(separator: " ")
                return candidateWords.count == censoredWords.count
                    && wordsMatchExceptCensored(censoredWords, candidateWords)
            }) else { continue }

            let candidateWords = match.split(separator: " ")
            var rebuilt = [String]()
            for (i, word) in censoredWords.enumerated() {
                if containsFullCensor(String(word)), i < candidateWords.count {
                    rebuilt.append(String(candidateWords[i]))
                } else {
                    rebuilt.append(String(word))
                }
            }
            output[index] = rebuilt.joined(separator: " ")
        }

        return output
    }

    /// True if every non-censored word matches exactly (case-insensitive)
    /// between the censored line and a candidate line — this is what
    /// gives us confidence the candidate is genuinely the same line and
    /// not a coincidentally-same-length different line elsewhere in the
    /// song (e.g. a repeated chorus structure with different words).
    private static func wordsMatchExceptCensored(
        _ censoredWords: [Substring],
        _ candidateWords: [Substring]
    ) -> Bool {
        guard censoredWords.count == candidateWords.count else { return false }
        for (a, b) in zip(censoredWords, candidateWords) {
            if containsFullCensor(String(a)) { continue }
            if a.lowercased() != b.lowercased() { return false }
        }
        return true
    }
}
