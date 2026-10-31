/// Subsequence fuzzy matching for the quick switcher.
public enum Fuzzy {
    /// nil when `query` is not a subsequence of `candidate`; otherwise a score where
    /// higher is better: consecutive runs and word starts (after / - _ . space, or a
    /// lower→upper camel hump) count extra, gaps and long candidates cost a little.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let original = Array(candidate)
        let c = Array(candidate.lowercased())
        guard c.count == original.count else { return substringScore(query, candidate) }
        var qi = 0
        var score = 0
        var lastMatch = -2
        var gap = 0
        for (i, ch) in c.enumerated() where qi < q.count {
            if ch == q[qi] {
                score += 1
                if lastMatch == i - 1 { score += 5 }
                if i == 0 || "/-_. ".contains(c[i - 1]) || (original[i].isUppercase && original[i - 1].isLowercase) {
                    score += 8
                }
                score -= min(gap, 3)
                gap = 0
                lastMatch = i
                qi += 1
            } else if lastMatch >= 0 {
                gap += 1
            }
        }
        guard qi == q.count else { return nil }
        return score * 10 - c.count / 4
    }

    private static func substringScore(_ query: String, _ candidate: String) -> Int? {
        candidate.localizedCaseInsensitiveContains(query) ? 1 : nil
    }
}
