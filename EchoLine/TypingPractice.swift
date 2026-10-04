import SwiftUI
import AppKit

// MARK: - 临摹：一个词一个词打出来
//
// 为什么打字有用：抄写要求你把每个词的拼写、标点、语序都"生成"一遍（generation effect），
// 比眼睛扫过去深得多。三档由浅入深：
//   看着打 —— 原文就在眼前，练拼写和手感；
//   凭记忆打 —— 原文遮住，只留词长（和首字母），逼自己回忆；
//   听着打 —— 只听不看，一句一句听写，把声音和拼写连起来。
// 每打完一个词（按空格）立刻判对错：对了变绿、弹一下、冒一圈小光点；错了变红、抖一下，下面划掉你打的。

enum TypingMode: String, Codable, CaseIterable, Identifiable {
    case copy, recall, dictation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "看着打"
        case .recall: return "凭记忆打"
        case .dictation: return "听着打"
        }
    }

    var short: String {
        switch self {
        case .copy: return "看"
        case .recall: return "记"
        case .dictation: return "听"
        }
    }

    var icon: String {
        switch self {
        case .copy: return "eye"
        case .recall: return "brain.head.profile"
        case .dictation: return "ear"
        }
    }

    var hint: String {
        switch self {
        case .copy: return "原文在上面，照着一个词一个词打，空格提交。"
        case .recall: return "原文遮住了，只剩词长和标点。想不起来可以偷看，但会记次数。"
        case .dictation: return "只听不看：每句自动播一遍，打完一句自动播下一句。"
        }
    }

    var next: TypingMode {
        switch self {
        case .copy: return .recall
        case .recall: return .dictation
        case .dictation: return .recall
        }
    }
}

struct TypingRequest: Identifiable {
    let id = UUID()
    let sentenceID: UUID
    var mode: TypingMode
}

// MARK: - 记录

struct TypingEntry: Codable {
    var best: [String: Int] = [:]          // mode -> 最佳正确率
    var attempts = 0
    var last: Date? = nil
    var misses: [String: Int] = [:]        // 打错过的词 -> 次数
}

struct TypingBook: Codable {
    var entries: [String: TypingEntry] = [:]
    var wordsPerDay: [String: Int] = [:]   // dayKey -> 当天打过的词数
    var recent: [Int] = []                 // 最近 30 次的正确率
}

struct WeakWord: Identifiable {
    let word: String
    let count: Int
    var id: String { word }
}

@MainActor
final class TypingStore: ObservableObject {
    static let shared = TypingStore()

    @Published private(set) var book = TypingBook()

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("typingBook.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(TypingBook.self, from: data) {
            book = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(book) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func best(_ id: UUID, _ mode: TypingMode) -> Int? {
        book.entries[id.uuidString]?.best[mode.rawValue]
    }

    func attempts(_ id: UUID) -> Int { book.entries[id.uuidString]?.attempts ?? 0 }

    /// 记一次；返回是否刷新了这一档的最佳成绩
    @discardableResult
    func record(_ id: UUID, mode: TypingMode, accuracy: Int, misses: [String], words: Int, dayKey: String) -> Bool {
        var entry = book.entries[id.uuidString] ?? TypingEntry()
        let old = entry.best[mode.rawValue]
        let isBest = old == nil || accuracy > (old ?? 0)
        if isBest { entry.best[mode.rawValue] = accuracy }
        entry.attempts += 1
        entry.last = .now
        for w in misses { entry.misses[w, default: 0] += 1 }
        book.entries[id.uuidString] = entry
        book.wordsPerDay[dayKey, default: 0] += words
        book.recent.append(accuracy)
        if book.recent.count > 30 { book.recent.removeFirst(book.recent.count - 30) }
        persist()
        return isBest
    }

    var practicedCount: Int { book.entries.count }

    func wordsTyped(on dayKey: String) -> Int { book.wordsPerDay[dayKey] ?? 0 }

    var recentAccuracy: Int? {
        guard !book.recent.isEmpty else { return nil }
        return book.recent.reduce(0, +) / book.recent.count
    }

    /// 全库最常打错的词
    func weakWords(limit: Int = 24) -> [WeakWord] {
        var total: [String: Int] = [:]
        for entry in book.entries.values {
            for (w, n) in entry.misses { total[w, default: 0] += n }
        }
        return total.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { WeakWord(word: $0.key, count: $0.value) }
    }
}

// MARK: - 切词与比对

struct TypingToken: Identifiable {
    let id: Int
    let raw: String          // 原文里这一截（带标点）
    let loose: String        // 宽松比对用：小写、去标点
    let sentence: Int        // 属于第几句（听写按句播放）
    let endsSentence: Bool
    /// 纯标点 / 破折号这类不用打，直接跳过
    var skippable: Bool { loose.isEmpty }
}

enum TypingMatch {
    static func tokenize(_ text: String) -> [TypingToken] {
        var result: [TypingToken] = []
        var sentence = 0
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            let raw = String(piece)
            let end = endsSentence(raw)
            result.append(TypingToken(id: result.count, raw: raw, loose: loose(raw),
                                      sentence: sentence, endsSentence: end))
            if end { sentence += 1 }
        }
        return result
    }

    /// 统一弯引号、长破折号：键盘上打不出来的东西不能算错
    static func straighten(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    /// 宽松：不管大小写和标点，只看字母、数字，以及词内的 ' 和 -
    static func loose(_ s: String) -> String {
        let chars = straighten(s).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
        return String(chars).trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    static func matches(_ typed: String, _ token: TypingToken, strict: Bool) -> Bool {
        if strict { return straighten(typed) == straighten(token.raw) }
        return loose(typed) == token.loose
    }

    private static func endsSentence(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    /// 遮住字母数字、保留标点；hint 时留首字母
    static func mask(_ raw: String, hint: Bool) -> String {
        var out = ""
        var first = true
        for ch in raw {
            if ch.isLetter || ch.isNumber {
                out.append(hint && first ? ch : "_")
                first = false
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - 临摹面板（弹窗）

struct TypingSessionView: View {
    let sentenceID: UUID
    @State var mode: TypingMode

    @EnvironmentObject var store: EchoStore
    @ObservedObject private var typing = TypingStore.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage("typingStrict") private var strict = false
    @AppStorage("typingHint") private var firstLetterHint = true
    @AppStorage("typingSound") private var soundOn = true
    @AppStorage("typingSpeakWord") private var speakWord = false

    @State private var tokens: [TypingToken] = []
    @State private var typed: [Int: String] = [:]
    @State private var firstTry: [Int: Bool] = [:]
    @State private var pulse: [Int: Int] = [:]
    @State private var cursor = 0
    @State private var input = ""
    @State private var startedAt: Date?
    @State private var finishedAt: Date?
    @State private var streak = 0
    @State private var bestStreak = 0
    @State private var peeks = 0
    @State private var peeking = false
    @State private var fieldFlash: Color = .clear
    @State private var newBest = false
    @State private var streakBump = false
    @State private var keyMonitor: Any?
    @FocusState private var focused: Bool

    private var sentence: EchoSentence? { store.sentences.first { $0.id == sentenceID } }
    private var typable: [TypingToken] { tokens.filter { !$0.skippable } }
    private var doneCount: Int { typable.filter { typed[$0.id] != nil }.count }
    private var finished: Bool { finishedAt != nil }

    private var accuracy: Int {
        let tried = firstTry.values
        guard !tried.isEmpty else { return 100 }
        return Int((Double(tried.filter { $0 }.count) / Double(tried.count) * 100).rounded())
    }

    private var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? .now).timeIntervalSince(startedAt)
    }

    /// 每分钟词数：按打完的原文字符数 / 5 算，国际通用口径
    private var wpm: Int {
        let chars = typable.filter { typed[$0.id] != nil }.reduce(0) { $0 + $1.raw.count + 1 }
        guard elapsed > 3 else { return 0 }
        return Int(Double(chars) / 5 / (elapsed / 60))
    }

    private var missedTokens: [TypingToken] {
        typable.filter { firstTry[$0.id] == false }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            if finished {
                resultView
            } else {
                practiceView
            }
        }
        .frame(width: 900, height: 640)
        .background(WorkbenchBackground())
        .onAppear {
            restart()
            // 输入框空着按退格：回到上一个词改。文本框自己会吞掉退格，只能在事件层面拦。
            // 首次对错已经记下，改对了也不会把错误抹掉。
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 输入框会吞掉 Esc，「结束」按钮的快捷键收不到，这里补上
                if event.keyCode == 53 {
                    dismiss()
                    return nil
                }
                if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                   input.isEmpty, !finished, stepBack() {
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            Speech.shared.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard").foregroundStyle(Theme.ice)
            Text("临摹").font(.headline).foregroundStyle(Theme.ink)
            Picker("方式", selection: $mode) {
                ForEach(TypingMode.allCases) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .onChange(of: mode) { restart() }
            Spacer()
            SpeedControl()
            Menu {
                Toggle("严格比对（大小写、标点都算）", isOn: $strict)
                Toggle("凭记忆时显示首字母", isOn: $firstLetterHint)
                Toggle("音效", isOn: $soundOn)
                Toggle("打对一个词就读出来", isOn: $speakWord)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("比对规则与反馈")
            Button("结束") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: 练习

    private var practiceView: some View {
        VStack(alignment: .leading, spacing: 14) {
            statsRow
            Text(mode.hint).font(.caption).foregroundStyle(Theme.dim)

            ScrollViewReader { proxy in
                ScrollView {
                    TypingFlow(spacing: 9, lineSpacing: 16) {
                        ForEach(tokens) { token in
                            TypingWordView(token: token,
                                           status: status(of: token),
                                           typed: typed[token.id],
                                           current: token.id == cursor ? input : nil,
                                           reveal: mode == .copy || peeking,
                                           hint: firstLetterHint && mode == .recall,
                                           pulse: pulse[token.id] ?? 0)
                                .id(token.id)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
                .onChange(of: cursor) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(cursor, anchor: .center) }
                }
            }

            modeControls

            HStack(spacing: 12) {
                TextField(mode == .dictation ? "听到什么打什么，空格提交" : "在这里打字，空格提交一个词", text: $input)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(20))
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(fieldFlash == .clear ? Theme.ice.opacity(focused ? 0.45 : 0.15) : fieldFlash,
                                lineWidth: fieldFlash == .clear ? 1 : 2))
                    .shadow(color: fieldFlash.opacity(0.5), radius: fieldFlash == .clear ? 0 : 10)
                    .onChange(of: input) { handleInput() }
                    .onSubmit { commitInput() }
                Button {
                    _ = stepBack()
                } label: {
                    Label("改上一个词", systemImage: "delete.left")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
                .keyboardShortcut(.delete, modifiers: .command)
                .help("回到上一个词重打（⌘⌫）")
            }
            Text("空格或 ⏎ 提交一个词 · 空着按 ⌫ 回到上一个词 · \(strict ? "严格比对：大小写和标点都要一致" : "宽松比对：不计大小写和标点")")
                .font(.caption2).foregroundStyle(Theme.dim)
        }
        .padding(20)
    }

    private var statsRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(doneCount) / \(typable.count) 词").font(Theme.mono(12)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                ProgressBar(value: typable.isEmpty ? 0 : Double(doneCount) / Double(typable.count))
            }
            .frame(width: 260)
            metric("正确率", "\(accuracy)%", color: accuracy >= 90 ? Theme.right : (accuracy >= 70 ? Theme.verb : Theme.wrong))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                metric("速度", "\(wpm) wpm", color: Theme.ink)
            }
            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(streak >= 5 ? Theme.verb : Theme.dim)
                    .scaleEffect(streakBump ? 1.5 : 1)
                Text("连对 \(streak)").font(Theme.mono(13, .bold))
                    .foregroundStyle(streak >= 5 ? Theme.verb : Theme.ink)
            }
            if mode == .recall && peeks > 0 {
                Chip("偷看 \(peeks) 次", tint: Theme.verb)
            }
            Spacer()
        }
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.dim)
            Text(value).font(Theme.mono(15, .bold)).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .copy:
            EmptyView()
        case .recall:
            HStack(spacing: 10) {
                Button {
                    peek()
                } label: {
                    Label(peeking ? "看着呢…" : "偷看 2 秒", systemImage: "eye")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
                .keyboardShortcut("e", modifiers: .command)
                .disabled(peeking)
                .help("临时显示原文（⌘E），会记次数")
                Text("遮住的是字母，标点和词长照常显示").font(.caption2).foregroundStyle(Theme.dim)
            }
        case .dictation:
            HStack(spacing: 10) {
                Button {
                    playCurrentSentence(slow: false)
                } label: {
                    Label("重听这句", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
                .keyboardShortcut("j", modifiers: .command)
                Button {
                    playCurrentSentence(slow: true)
                } label: {
                    Label("慢速", systemImage: "tortoise")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
                .keyboardShortcut("j", modifiers: [.command, .shift])
                Text("⌘J 重听 · ⇧⌘J 慢速").font(.caption2).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: 结果

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Eyebrow("\(mode.title) · 完成")
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(accuracy)%")
                        .font(Theme.mono(56, .heavy))
                        .foregroundStyle(accuracy >= 90 ? Theme.right : (accuracy >= 70 ? Theme.verb : Theme.wrong))
                    Text("一次打对的比例").font(.callout).foregroundStyle(Theme.dim)
                    if newBest {
                        Chip("新纪录", tint: Theme.verb)
                    }
                }
                HStack(spacing: 12) {
                    StatTile(label: "速度", value: "\(wpm)", unit: "wpm", note: "按每 5 个字符算一个词")
                    StatTile(label: "用时", value: timeText(elapsed), unit: "", note: "\(typable.count) 个词")
                    StatTile(label: "最长连对", value: "\(bestStreak)", unit: "词", note: mode == .recall ? "偷看 \(peeks) 次" : "保持节奏比求快重要")
                }

                if missedTokens.isEmpty {
                    WorkbenchPanel(tint: Theme.right) {
                        Text("一个没错。").font(.headline).foregroundStyle(Theme.ink)
                        Text(mode == .copy ? "下一步：遮住原文，凭记忆再打一遍。" : "明天再来一遍，看看还记不记得。")
                            .font(.callout).foregroundStyle(Theme.dim)
                    }
                } else {
                    WorkbenchPanel {
                        Text("这些词第一次没打对（点一下听发音）").font(.headline).foregroundStyle(Theme.ink)
                        FlowRow(spacing: 8) {
                            ForEach(missedTokens) { token in
                                Button {
                                    Speech.shared.speak(token.loose, rate: store.speechRate)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(token.raw).font(.system(size: 15, weight: .semibold, design: .serif))
                                            .foregroundStyle(Theme.ink)
                                        Text(firstTypedText(token))
                                            .font(Theme.mono(11)).strikethrough()
                                            .foregroundStyle(Theme.wrong)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Theme.wrong.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.wrong.opacity(0.25)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text("打错的词会记进「临摹」页的易错词里，下次重点看。")
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                }

                HStack(spacing: 10) {
                    Button("再来一次") { restart() }
                        .buttonStyle(WorkbenchButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                    Button("换成「\(mode.next.title)」") { mode = mode.next }
                        .buttonStyle(WorkbenchButtonStyle(kind: .normal))
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(WorkbenchButtonStyle(kind: .ghost))
                }
            }
            .padding(28)
        }
    }

    // MARK: 状态

    private func status(of token: TypingToken) -> TypingWordView.Status {
        if token.skippable { return .skipped }
        if let t = typed[token.id] {
            return TypingMatch.matches(t, token, strict: strict) ? .correct : .wrong
        }
        return token.id == cursor ? .current : .pending
    }

    /// 结果页里要显示第一次打的是什么；改过之后 typed 里是改后的，第一次的单独存
    @State private var firstTyped: [Int: String] = [:]

    private func firstTypedText(_ token: TypingToken) -> String {
        let t = firstTyped[token.id] ?? typed[token.id] ?? ""
        return t.isEmpty ? "（空）" : t
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? "\(s / 60):" + String(format: "%02d", s % 60) : "\(s)s"
    }

    // MARK: 动作

    private func restart() {
        Speech.shared.stop()
        tokens = TypingMatch.tokenize(sentence?.text ?? "")
        typed = [:]
        firstTry = [:]
        firstTyped = [:]
        pulse = [:]
        input = ""
        startedAt = nil
        finishedAt = nil
        streak = 0
        bestStreak = 0
        peeks = 0
        peeking = false
        newBest = false
        cursor = nextIndex(from: 0)
        focused = true
        if mode == .dictation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { playCurrentSentence(slow: false) }
        }
        DispatchQueue.main.async { focused = true }
    }

    /// 从 i 开始第一个需要打的词
    private func nextIndex(from i: Int) -> Int {
        var j = i
        while j < tokens.count, tokens[j].skippable { j += 1 }
        return j
    }

    private func handleInput() {
        guard !finished else { return }
        if startedAt == nil, !input.isEmpty { startedAt = .now }
        if input.contains(where: { $0.isWhitespace }) {
            let endsWithSpace = input.last?.isWhitespace == true
            var parts = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var rest = ""
            if !endsWithSpace, let last = parts.popLast() { rest = last }
            input = rest
            for word in parts { commit(word) }
            return
        }
        // 最后一个词打对了就直接收尾，不用再按空格
        if cursor < tokens.count, nextIndex(from: cursor + 1) >= tokens.count,
           !input.isEmpty, TypingMatch.matches(input, tokens[cursor], strict: strict) {
            let word = input
            input = ""
            commit(word)
        }
    }

    private func commitInput() {
        let word = input.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        input = ""
        commit(word)
    }

    private func commit(_ word: String) {
        guard cursor < tokens.count, !finished else { return }
        let token = tokens[cursor]
        typed[token.id] = word
        let ok = TypingMatch.matches(word, token, strict: strict)
        if firstTry[token.id] == nil {
            firstTry[token.id] = ok
            firstTyped[token.id] = word
        }
        streak = ok ? streak + 1 : 0
        bestStreak = max(bestStreak, streak)
        pulse[token.id, default: 0] += 1
        feedback(ok, token: token)

        let next = nextIndex(from: cursor + 1)
        cursor = next
        if next >= tokens.count {
            finish()
        } else if mode == .dictation, token.endsSentence {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { playCurrentSentence(slow: false) }
        }
    }

    /// 回到上一个打过的词重打
    private func stepBack() -> Bool {
        guard !finished else { return false }
        var j = cursor - 1
        while j >= 0, tokens[j].skippable { j -= 1 }
        guard j >= 0, let previous = typed[j] else { return false }
        typed[j] = nil
        cursor = j
        input = previous
        return true
    }

    private func feedback(_ ok: Bool, token: TypingToken) {
        withAnimation(.easeOut(duration: 0.08)) { fieldFlash = ok ? Theme.right : Theme.wrong }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeOut(duration: 0.3)) { fieldFlash = .clear }
        }
        if ok, streak > 0, streak % 5 == 0 {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { streakBump = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { streakBump = false }
            }
        }
        if soundOn {
            let sound = NSSound(named: ok ? (streak > 0 && streak % 10 == 0 ? "Glass" : "Pop") : "Funk")
            sound?.volume = ok ? 0.25 : 0.4
            sound?.play()
        }
        if ok, speakWord, mode != .dictation {
            Speech.shared.speak(token.loose, rate: store.speechRate)
        }
    }

    private func peek() {
        peeks += 1
        withAnimation(.easeOut(duration: 0.15)) { peeking = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.25)) { peeking = false }
        }
    }

    private func playCurrentSentence(slow: Bool) {
        guard !tokens.isEmpty else { return }
        let index = tokens[min(cursor, tokens.count - 1)].sentence
        let text = tokens.filter { $0.sentence == index }.map(\.raw).joined(separator: " ")
        let rate = slow ? store.slowRate : store.speechRate
        Speech.shared.speak(text, rate: rate)
        focused = true
    }

    private func finish() {
        finishedAt = .now
        Speech.shared.stop()
        let misses = missedTokens.map(\.loose)
        newBest = typing.record(sentenceID, mode: mode, accuracy: accuracy, misses: misses,
                                words: typable.count, dayKey: store.dayKey())
        if soundOn, accuracy >= 90 { NSSound(named: "Hero")?.play() }
    }
}

// MARK: - 单个词的显示与特效

struct TypingWordView: View {
    enum Status { case pending, current, correct, wrong, skipped }

    let token: TypingToken
    let status: Status
    let typed: String?
    let current: String?
    let reveal: Bool
    let hint: Bool
    let pulse: Int

    @State private var pop = false
    @State private var shake: CGFloat = 0
    @State private var burst = 0      // 0 静止 1 起点 2 飞散
    @State private var glow = false

    private let font = Font.system(size: 22, design: .serif)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            main
            // 第二行：打错时划掉你打的；其他时候留空，保证每个词一样高
            Text(status == .wrong ? (typed ?? "") : " ")
                .font(Theme.mono(11))
                .strikethrough(status == .wrong, color: Theme.wrong)
                .foregroundStyle(Theme.wrong.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
        )
        .scaleEffect(pop ? 1.2 : 1, anchor: .bottom)
        .shadow(color: glow ? Theme.right.opacity(0.8) : .clear, radius: glow ? 10 : 0)
        .modifier(TypingShake(animatableData: shake))
        .overlay(alignment: .center) { burstView.allowsHitTesting(false) }
        .onChange(of: pulse) { animate() }
    }

    @ViewBuilder
    private var main: some View {
        switch status {
        case .skipped:
            Text(token.raw).font(font).foregroundStyle(Theme.dim)
        case .correct:
            Text(token.raw).font(font).foregroundStyle(Theme.right)
        case .wrong:
            Text(token.raw).font(font).foregroundStyle(Theme.wrong)
                .underline(color: Theme.wrong.opacity(0.6))
        case .pending:
            Text(reveal ? token.raw : TypingMatch.mask(token.raw, hint: hint))
                .font(reveal ? font : Theme.mono(20))
                .foregroundStyle(reveal ? Theme.ink.opacity(0.42) : Theme.dim)
        case .current:
            currentView
                .overlay(alignment: .bottom) {
                    Capsule().fill(Theme.ice).frame(height: 2).offset(y: 3)
                        .shadow(color: Theme.ice, radius: 4)
                }
        }
    }

    /// 正在打的词：看着打时逐字母着色（对的青碧、错的红），凭记忆时只显示你打的 + 剩下的空格
    private var currentView: some View {
        let target = Array(TypingMatch.straighten(token.raw))
        let typedChars = Array(TypingMatch.straighten(current ?? ""))
        var text = Text("")
        if reveal {
            for (i, ch) in target.enumerated() {
                let piece = Text(String(ch)).font(font)
                if i < typedChars.count {
                    let same = String(typedChars[i]).lowercased() == String(ch).lowercased()
                    text = text + piece.foregroundColor(same ? Theme.ice : Theme.wrong)
                } else {
                    text = text + piece.foregroundColor(Theme.ink.opacity(0.75))
                }
            }
            if typedChars.count > target.count {
                text = text + Text(String(typedChars[target.count...])).font(font).foregroundColor(Theme.wrong)
            }
        } else {
            let prefixOK = TypingMatch.loose(token.raw).hasPrefix(TypingMatch.loose(current ?? ""))
            text = Text(current ?? "").font(font).foregroundColor(prefixOK ? Theme.ice : Theme.wrong)
            let remaining = max(0, token.loose.count - typedChars.count)
            text = text + Text(String(repeating: "_", count: remaining)).font(Theme.mono(20)).foregroundColor(Theme.dim)
        }
        return text
    }

    private var backgroundColor: Color {
        switch status {
        case .current: return Theme.ice.opacity(0.10)
        case .wrong: return Theme.wrong.opacity(0.10)
        default: return .clear
        }
    }

    /// 打对时冒出的一圈小光点
    private var burstView: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * Double.pi
                Circle()
                    .fill(i % 2 == 0 ? Theme.right : Theme.ice)
                    .frame(width: 4, height: 4)
                    .offset(x: burst == 2 ? CGFloat(cos(angle)) * 26 : 0,
                            y: burst == 2 ? CGFloat(sin(angle)) * 18 : 0)
                    .opacity(burst == 1 ? 1 : 0)
            }
        }
    }

    private func animate() {
        switch status {
        case .correct:
            withAnimation(.spring(response: 0.16, dampingFraction: 0.45)) { pop = true; glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { pop = false }
                withAnimation(.easeOut(duration: 0.6)) { glow = false }
            }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { burst = 1 }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.55)) { burst = 2 }
            }
        case .wrong:
            withAnimation(.linear(duration: 0.4)) { shake += 1 }
        default:
            break
        }
    }
}

/// 左右抖三下
struct TypingShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(animatableData * .pi * 6), y: 0))
    }
}

/// 词距和行距分开的流式排版
struct TypingFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + lineSpacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 临摹页（侧栏入口）

struct TypingPane: View {
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var typing = TypingStore.shared
    @State private var scope: Scope = .paragraphs

    enum Scope: String, CaseIterable, Identifiable {
        case paragraphs = "段落", sentences = "句子", fresh = "还没练过"
        var id: String { rawValue }
    }

    private var items: [EchoSentence] {
        let all = store.topLevelSentences.sorted { $0.dateAdded > $1.dateAdded }
        let list: [EchoSentence]
        switch scope {
        case .paragraphs: list = all.filter(\.isParagraph)
        case .sentences: list = all.filter { !$0.isParagraph }
        case .fresh: list = all.filter { typing.attempts($0.id) == 0 }
        }
        return Array(list.prefix(80))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("临摹 · 打一遍记一遍")
                    Text("用手把句子记住")
                        .font(.system(size: 34, weight: .black)).foregroundStyle(Theme.ink)
                    Text("先看着打熟悉拼写，再遮住凭记忆打，最后只听不看。每个词打完立刻告诉你对错。")
                        .font(.callout).foregroundStyle(Theme.dim)
                }

                HStack(spacing: 12) {
                    StatTile(label: "今天打了", value: "\(typing.wordsTyped(on: store.dayKey()))", unit: "词",
                             note: "每天 200 词就很好", style: .hero)
                    StatTile(label: "练过", value: "\(typing.practicedCount)", unit: "条", note: "段落和句子一起算")
                    StatTile(label: "近期正确率", value: typing.recentAccuracy.map { "\($0)" } ?? "—", unit: "%",
                             note: "最近 30 次的平均")
                }

                let weak = typing.weakWords()
                if !weak.isEmpty {
                    WorkbenchPanel(tint: Theme.wrong) {
                        HStack {
                            Text("易错词").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                            Text("临摹时第一次没打对的词，点一下听发音").font(.caption).foregroundStyle(Theme.dim)
                        }
                        FlowRow(spacing: 8) {
                            ForEach(weak) { w in
                                Button {
                                    Speech.shared.speak(w.word, rate: store.speechRate)
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(w.word).font(.system(size: 14, design: .serif))
                                        Text("×\(w.count)").font(Theme.mono(10)).foregroundStyle(Theme.wrong)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(Theme.ink)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                WorkbenchPanel {
                    HStack {
                        Text("选一条来临摹").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Picker("范围", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    if items.isEmpty {
                        Text(scope == .paragraphs ? "还没有收录段落：在任何 App 里划一段英文，⌥⌘E 收进来。" : "这里空空的。")
                            .font(.callout).foregroundStyle(Theme.dim)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(items) { s in
                                row(s)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WorkbenchBackground())
    }

    private func row(_ s: EchoSentence) -> some View {
        let words = TypingMatch.tokenize(s.text).filter { !$0.skippable }.count
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.text)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(s.isParagraph ? "段落 · \(words) 词" : "\(words) 词")
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    ForEach(TypingMode.allCases) { m in
                        let best = typing.best(s.id, m)
                        Text("\(m.short) \(best.map { "\($0)" } ?? "—")")
                            .font(Theme.mono(10))
                            .foregroundStyle(best == nil ? Theme.dim : (best ?? 0) >= 90 ? Theme.right : Theme.verb)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(TypingMode.allCases) { m in
                    Button {
                        store.startTyping(s, mode: m)
                    } label: {
                        Label(m.title, systemImage: m.icon)
                    }
                    .buttonStyle(WorkbenchButtonStyle(kind: m == suggestedMode(s) ? .primary : .normal, small: true))
                }
            }
        }
        .padding(12)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 建议的下一档：看着打过 90 分就该遮住了，凭记忆过 90 分就去听写
    private func suggestedMode(_ s: EchoSentence) -> TypingMode {
        if (typing.best(s.id, .recall) ?? 0) >= 90 { return .dictation }
        if (typing.best(s.id, .copy) ?? 0) >= 90 { return .recall }
        return .copy
    }
}
