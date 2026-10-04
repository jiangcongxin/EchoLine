import Foundation

// MARK: - 文本对比（跟读打分 / 错词定位）
// 纯算法，与 iOS 版 IELTSMate SpeechService.swift 中的 TextDiff 完全一致

enum TextDiff {
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func score(target: String, spoken: String) -> Int {
        let a = words(target), b = words(spoken)
        guard !a.isEmpty else { return 0 }
        return Int((Double(lcsLength(a, b)) / Double(a.count) * 100).rounded())
    }

    static func matchedWords(target: String, spoken: String) -> [(word: String, matched: Bool)] {
        let a = words(target), b = words(spoken)
        guard !a.isEmpty else { return [] }
        guard !b.isEmpty else { return a.map { ($0, false) } }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
            }
        }
        var matched = Array(repeating: false, count: a.count)
        var i = a.count, j = b.count
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] { matched[i-1] = true; i -= 1; j -= 1 }
            else if dp[i-1][j] >= dp[i][j-1] { i -= 1 }
            else { j -= 1 }
        }
        return zip(a, matched).map { ($0, $1) }
    }

    /// 说出的内容是否包含目标词（容错 1 个编辑距离）
    static func spokenContains(target: String, transcript: String) -> Bool {
        let t = target.lowercased()
        for w in words(transcript) {
            if w == t || editDistance(w, t) <= 1 { return true }
        }
        return false
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { dp[i][0] = i }
        for j in 0...y.count { dp[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                dp[i][j] = x[i-1] == y[j-1] ? dp[i-1][j-1] : min(dp[i-1][j-1], dp[i-1][j], dp[i][j-1]) + 1
            }
        }
        return dp[x.count][y.count]
    }

    private static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1])
            }
        }
        return dp[a.count][b.count]
    }
}

// MARK: - 词级对齐（仿写批改 diff 用）

/// 把「用户原文 → 修改后」对齐成操作序列：保留 / 删除 / 新增 / 替换
enum WordDiff {
    enum Op: Equatable {
        case keep(String)
        case delete(String)
        case insert(String)
        case substitute(String, String)   // 原文词 → 改后词
    }

    /// LCS 后缀 DP + 正向回溯；相邻的「删除 + 新增」合并为「替换」
    static func align(source: String, target: String) -> [Op] {
        let a = tokens(source), b = tokens(target)
        let n = a.count, m = b.count
        guard n > 0 else { return b.map { .insert($0) } }
        guard m > 0 else { return a.map { .delete($0) } }

        // dp[i][j] = a[i...] 与 b[j...] 的 LCS 长度
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = norm(a[i]) == norm(b[j]) ? dp[i+1][j+1] + 1 : max(dp[i+1][j], dp[i][j+1])
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && norm(a[i]) == norm(b[j]) {
                ops.append(.keep(a[i])); i += 1; j += 1
            } else if i < n && (j == m || dp[i+1][j] >= dp[i][j+1]) {
                ops.append(.delete(a[i])); i += 1      // 平手时先删，保证「删+增」相邻
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }

        // 合并：delete 紧跟 insert → substitute
        var merged: [Op] = []
        var k = 0
        while k < ops.count {
            if k + 1 < ops.count,
               case .delete(let d) = ops[k],
               case .insert(let ins) = ops[k+1] {
                merged.append(.substitute(d, ins))
                k += 2
            } else {
                merged.append(ops[k])
                k += 1
            }
        }
        return merged
    }

    /// 展示用 token：按空格切，保留原始大小写和标点
    private static func tokens(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init)
    }

    /// 对齐比较用的归一化：小写 + 去首尾标点（"Doctor's" 与 "doctor's" 算同词）
    private static func norm(_ t: String) -> String {
        t.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
