import Foundation

// MARK: - Fuzzy matching (subsequence with bonuses, shared by history search)

/// Returns a score (higher = better) or nil if no match.
func fuzzyScore(query: String, target: String) -> Int? {
    let q = query.lowercased()
    let t = target.lowercased()
    if q.isEmpty { return 0 }
    if t.contains(q) {
        // Exact substring gets a big bonus; prefix even bigger.
        var s = 100 + q.count * 10
        if t.hasPrefix(q) { s += 80 }
        // Word-boundary bonus
        if t.contains(" " + q) { s += 40 }
        return s
    }
    // Subsequence match
    var qi = q.startIndex
    var score = 0
    var consecutive = 0
    var lastMatch = -2
    let tChars = Array(t)
    for (i, ch) in tChars.enumerated() {
        if qi < q.endIndex && ch == q[qi] {
            // bonus for start / after space / consecutive
            if i == 0 { score += 30 }
            else if tChars[i - 1] == " " || tChars[i - 1] == "-" || tChars[i - 1] == "/" { score += 20 }
            if i == lastMatch + 1 { consecutive += 1; score += 10 + consecutive * 5 }
            else { consecutive = 0; score += 8 }
            lastMatch = i
            qi = q.index(after: qi)
        }
    }
    guard qi == q.endIndex else { return nil }
    return score
}
