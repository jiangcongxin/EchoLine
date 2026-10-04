import Foundation
import SwiftUI

// MARK: - 回忆练习 + 间隔排期
//
// 学习科学里最稳的两条结论：
// 1. 检索练习（testing effect）：自己"想出来"一次，比再读几遍记得牢得多。
// 2. 间隔重复（spacing）：快忘的时候再想一次，间隔逐步拉长。
// 所以「今日」不再随机抽旧句重读，而是按到期时间出题，让你回忆，然后自评一下。
//
// 数据单独放 reviewBook.json：不进 iCloud 同步、不改句库格式，删掉这个文件就回到从前。

/// 一句话的复习状态（SM-2 的简化版：只有三个自评档，负担最小）
struct ReviewState: Codable, Equatable {
    var interval: Double = 0          // 当前间隔（天）
    var ease: Double = 2.5            // 间隔放大系数
    var due: Date = .now
    var reps: Int = 0                 // 连续想起来的次数（忘了会清零）
    var lapses: Int = 0               // 累计忘记次数
    var lastReviewed: Date? = nil
    var zh: String? = nil             // 中译缓存（中→英回忆要用）
    var suspended = false             // 移出复习（划错的、没价值的）
}

struct ReviewEvent: Codable {
    var id: String                    // 句子 id
    var date: Date
    var rating: Int                   // 1 忘了 / 2 模糊 / 3 想起来了
    var wasNew: Bool
}

struct ReviewBook: Codable {
    var states: [String: ReviewState] = [:]
    var log: [ReviewEvent] = []
    var newPerDay: [String: Int] = [:]   // dayKey -> 当天引入的新句数
}

enum RecallRating: Int, CaseIterable {
    case again = 1, hard = 2, good = 3

    var label: String {
        switch self {
        case .again: return "忘了"
        case .hard: return "模糊"
        case .good: return "想起来了"
        }
    }
}

/// 出题方式：由浅入深轮换，同一句不总用同一种
enum RecallMode: String {
    case cloze        // 挖空关键语块，看上下文填回去
    case dictation    // 只听不看，写下来
    case zhToEn       // 看中文，说 / 写出英文

    var title: String {
        switch self {
        case .cloze: return "填回关键语块"
        case .dictation: return "听写"
        case .zhToEn: return "看中文，想英文"
        }
    }

    var hint: String {
        switch self {
        case .cloze: return "根据上下文把空缺的词块写出来，⏎ 揭晓"
        case .dictation: return "听完把整句写下来（可以多听几遍），⏎ 揭晓"
        case .zhToEn: return "先在心里或嘴上说出英文原句，写下来更好，⏎ 揭晓"
        }
    }
}

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    @Published private(set) var book = ReviewBook()

    /// 每天最多引入的新句数：太多会把复习负担越滚越大
    static let newPerDayLimit = 8
    /// 一次练习的上限，15 分钟左右能做完
    static let sessionLimit = 20

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("reviewBook.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ReviewBook.self, from: data) {
            book = decoded
        }
    }

    private func persist() {
        if book.log.count > 5000 { book.log.removeFirst(book.log.count - 5000) }
        if let data = try? JSONEncoder().encode(book) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func state(for id: UUID) -> ReviewState? { book.states[id.uuidString] }

    // MARK: 出题范围

    /// 值得回忆的句子：不是段落本体，至少 4 个英文词，字母为主。
    /// 划错收进来的代码、哈希、按钮文字在这里就被挡掉。
    static func isReviewable(_ s: EchoSentence) -> Bool {
        guard !s.isParagraph else { return false }
        let words = s.text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter && $0.isASCII }) }
        guard words.count >= 4, s.text.count <= 400 else { return false }
        let letters = s.text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        return Double(letters) / Double(max(1, s.text.count)) > 0.6
    }

    /// 今天要做的：先到期的（越过期越靠前），再补新句（最近收的优先，趁印象还在）
    func queue(from store: EchoStore, now: Date = .now) -> [EchoSentence] {
        let pool = store.sentences.filter(Self.isReviewable)
        var due: [(EchoSentence, Date)] = []
        var fresh: [EchoSentence] = []
        for s in pool {
            let st = book.states[s.id.uuidString]
            if st?.suspended == true { continue }
            if let st, st.lastReviewed != nil {
                if st.due <= now { due.append((s, st.due)) }
            } else {
                fresh.append(s)          // 从没回忆过（可能只缓存过中译）
            }
        }
        due.sort { $0.1 < $1.1 }
        let usedToday = book.newPerDay[store.dayKey(now)] ?? 0
        let newSlots = max(0, Self.newPerDayLimit - usedToday)
        let newOnes = fresh.sorted { $0.dateAdded > $1.dateAdded }.prefix(newSlots)
        return Array((due.map { $0.0 } + newOnes).prefix(Self.sessionLimit))
    }

    func mode(for s: EchoSentence) -> RecallMode {
        let reps = book.states[s.id.uuidString]?.reps ?? 0
        // 新句先填空（有上下文、难度低），熟了再听写，最后中→英（最难、最接近真实输出）
        switch reps {
        case 0: return .cloze
        case 1: return .dictation
        default: return reps % 2 == 0 ? .zhToEn : .dictation
        }
    }

    // MARK: 排期

    func record(_ rating: RecallRating, for s: EchoSentence, dayKey: String, now: Date = .now) {
        let key = s.id.uuidString
        let isNew = book.states[key]?.lastReviewed == nil
        var st = book.states[key] ?? ReviewState()
        switch rating {
        case .again:
            st.lapses += 1
            st.reps = 0
            st.ease = max(1.3, st.ease - 0.2)
            st.interval = 1
        case .hard:
            st.ease = max(1.3, st.ease - 0.15)
            st.interval = st.reps == 0 ? 1 : max(st.interval + 1, st.interval * 1.2)
            st.reps += 1
        case .good:
            if st.reps == 0 { st.interval = 3 }
            else if st.reps == 1 { st.interval = 7 }
            else { st.interval = st.interval * st.ease }
            st.reps += 1
        }
        st.interval = min(st.interval, 365)
        st.lastReviewed = now
        st.due = now.addingTimeInterval(st.interval * 86_400)
        book.states[key] = st
        book.log.append(ReviewEvent(id: key, date: now, rating: rating.rawValue, wasNew: isNew))
        if isNew { book.newPerDay[dayKey, default: 0] += 1 }
        persist()
    }

    func suspend(_ s: EchoSentence) {
        var st = book.states[s.id.uuidString] ?? ReviewState()
        st.suspended = true
        book.states[s.id.uuidString] = st
        persist()
    }

    func cacheZH(_ zh: String, for s: EchoSentence) {
        var st = book.states[s.id.uuidString] ?? ReviewState()
        st.zh = zh
        // 只为缓存中译建出来的状态不能算"复习过"，保持到期 = 现在
        book.states[s.id.uuidString] = st
        persist()
    }

    // MARK: 指标（用"记住了多少"替代"收了多少"）

    /// 近 7 天复习旧句时想起来的比例；样本太少时不给数，免得误导
    var retention7: Double? {
        let since = Date.now.addingTimeInterval(-7 * 86_400)
        let old = book.log.filter { $0.date >= since && !$0.wasNew }
        guard old.count >= 5 else { return nil }
        return Double(old.filter { $0.rating == RecallRating.good.rawValue }.count) / Double(old.count)
    }

    var reviewedToday: Int {
        let start = Calendar.current.startOfDay(for: .now)
        return book.log.filter { $0.date >= start }.count
    }

    /// 已掌握：间隔拉到 3 周以上还想得起来
    var masteredCount: Int {
        book.states.values.filter { !$0.suspended && $0.interval >= 21 }.count
    }

    var learningCount: Int {
        book.states.values.filter { !$0.suspended && $0.lastReviewed != nil }.count
    }
}

// MARK: - 出题辅助

enum RecallTask {
    /// 挖空的目标语块：优先 AI 标的亮点表达，其次谓语动词，最后挑句里最长的实词
    static func clozeTarget(for s: EchoSentence) -> String {
        let text = s.text
        let lower = text.lowercased()
        if let h = s.analysis?.highlights.map(\.term).first(where: {
            $0.split(separator: " ").count <= 4 && lower.contains($0.lowercased())
        }) { return h }
        if let v = s.analysis?.verbs.first(where: { $0.count >= 3 && lower.contains($0.lowercased()) }) {
            return v
        }
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        let stop: Set<String> = ["which", "their", "there", "these", "those", "would", "could", "should", "about"]
        return words.filter { !stop.contains($0.lowercased()) }.max(by: { $0.count < $1.count }) ?? (words.first ?? "")
    }

    /// 句子里把目标换成下划线，保留首字母当提示
    static func masked(_ text: String, target: String) -> String {
        guard !target.isEmpty, let r = text.range(of: target, options: .caseInsensitive) else { return text }
        let hint = target.split(separator: " ").map { word -> String in
            guard let first = word.first else { return "" }
            return String(first) + String(repeating: "_", count: max(2, word.count - 1))
        }.joined(separator: " ")
        return text.replacingCharacters(in: r, with: hint)
    }

    /// 答得怎么样 → 建议的自评档（用户可以改）
    static func suggestedRating(answer: String, target: String) -> RecallRating? {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        let score = TextDiff.score(target: target, spoken: a)
        if score >= 90 { return .good }
        if score >= 60 { return .hard }
        return .again
    }
}
