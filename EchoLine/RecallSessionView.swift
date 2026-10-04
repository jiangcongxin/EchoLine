import SwiftUI

// MARK: - 回忆练习：一句一题 → 揭晓对照 → 自评 → 下一题
//
// 顺序固定成"先想、再看"：在看到答案前先努力回忆，是检索练习起作用的关键。
// 自评只有三档（1 忘了 / 2 模糊 / 3 想起来了），系统给出建议档，你可以改。

struct RecallSessionView: View {
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var review = ReviewStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var items: [EchoSentence] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var revealed = false
    @State private var zh: String?
    @State private var loadingZH = false
    @State private var results: [RecallRating] = []
    @State private var requeued: Set<UUID> = []
    @State private var started = false
    @FocusState private var answerFocused: Bool

    private var current: EchoSentence? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                if let s = current {
                    card(s)
                } else if started {
                    summary
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 640, height: 560)
        .background(Theme.bg)
        .onAppear {
            guard !started else { return }
            items = review.queue(from: store)
            started = true
            prepare()
        }
        .onDisappear { Speech.shared.stop() }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("回忆练习").font(.headline).foregroundStyle(Theme.ink)
            if !items.isEmpty {
                Text("\(min(index + 1, items.count)) / \(items.count)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.dim)
                ProgressBar(value: Double(index) / Double(max(1, items.count)))
                    .frame(width: 180)
            }
            Spacer()
            SpeedControl()
            Button("结束") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: 题卡

    @ViewBuilder
    private func card(_ s: EchoSentence) -> some View {
        let mode = effectiveMode(for: s)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Chip(mode.title, tint: Theme.ice)
                if review.state(for: s.id)?.lastReviewed == nil { Chip("新句", tint: Theme.verb) }
                if let st = review.state(for: s.id), st.lapses > 0 { Chip("忘过 \(st.lapses) 次") }
                Spacer()
                if !s.source.isEmpty {
                    Text(s.source).font(.caption).foregroundStyle(Theme.dim)
                }
            }

            prompt(s, mode: mode)

            TextField(mode == .cloze ? "填空缺的词块" : "写下英文原句", text: $answer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16, design: .serif))
                .lineLimit(1...4)
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(answerFocused ? Theme.ice.opacity(0.5) : Theme.line))
                .focused($answerFocused)
                .disabled(revealed)
                .onSubmit { reveal() }

            if revealed {
                revealBlock(s, mode: mode)
            } else {
                HStack {
                    Text(mode.hint).font(.caption).foregroundStyle(Theme.dim)
                    Spacer()
                    Button("揭晓 ⏎") { reveal() }
                        .buttonStyle(WorkbenchButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 题面：填空显示挖空句 / 听写只给播放键 / 中→英显示中文
    @ViewBuilder
    private func prompt(_ s: EchoSentence, mode: RecallMode) -> some View {
        switch mode {
        case .cloze:
            Text(RecallTask.masked(s.text, target: RecallTask.clozeTarget(for: s)))
                .font(.system(size: 20, design: .serif)).lineSpacing(6)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            if let zh = zhText(s) {
                Text(zh).font(.callout).foregroundStyle(Theme.dim)
            }
        case .dictation:
            HStack(spacing: 12) {
                Button {
                    Speech.shared.speak(s.text, rate: store.speechRate)
                } label: {
                    Label("再听一遍", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .normal))
                Button {
                    Speech.shared.speak(s.text, rate: store.slowRate)
                } label: {
                    Label("慢速", systemImage: "tortoise")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .ghost))
            }
            Text("\(s.text.split(separator: " ").count) 个词")
                .font(Theme.mono(11)).foregroundStyle(Theme.dim)
        case .zhToEn:
            if let zh = zhText(s) {
                Text(zh).font(.system(size: 20)).lineSpacing(6).foregroundStyle(Theme.ink)
            } else if loadingZH {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("准备中文…").foregroundStyle(Theme.dim) }
            }
        }
    }

    // MARK: 揭晓 + 自评

    private func revealBlock(_ s: EchoSentence, mode: RecallMode) -> some View {
        let target = mode == .cloze ? RecallTask.clozeTarget(for: s) : s.text
        let suggested = RecallTask.suggestedRating(answer: answer, target: target)
        let missed = answer.isEmpty ? [] : TextDiff.matchedWords(target: target, spoken: answer)
            .filter { !$0.matched }.map { $0.word }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Overline("原句")
                TapText(text: s.text, fontSize: 18, badTerms: missed) { token in
                    if let w = WordSelection.singleWord(from: token) {
                        Speech.shared.speak(w, rate: store.speechRate)
                    }
                }
                if mode == .cloze {
                    Text("空缺：\(target)").font(.callout).foregroundStyle(Theme.ice)
                }
                if !missed.isEmpty {
                    Text("红色＝你没写出来的词").font(.caption2).foregroundStyle(Theme.dim)
                }
                if let zh = zhText(s), mode != .zhToEn {
                    Text(zh).font(.callout).foregroundStyle(Theme.dim)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                ForEach(RecallRating.allCases, id: \.rawValue) { r in
                    Button {
                        rate(r, for: s)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(r.rawValue)").font(Theme.mono(11)).opacity(0.6)
                            Text(r.label)
                            if r == suggested { Image(systemName: "sparkle").font(.caption2) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WorkbenchButtonStyle(kind: r == suggested ? .primary : .normal))
                    .keyboardShortcut(KeyEquivalent(Character("\(r.rawValue)")), modifiers: [])
                    .help(nextIntervalHint(r, for: s))
                }
            }
            HStack {
                Text(suggested.map { "按你写的，建议选「\($0.label)」——不写也可以，凭感觉自评" }
                     ?? "凭刚才回忆的感觉自评：1 忘了 · 2 模糊 · 3 想起来了")
                    .font(.caption).foregroundStyle(Theme.dim)
                Spacer()
                Button("移出复习") {
                    review.suspend(s)
                    advance()
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.dim)
                .help("划错的、不值得记的句子，以后不再出现")
            }
        }
    }

    private var summary: some View {
        let good = results.filter { $0 == .good }.count
        return VStack(alignment: .leading, spacing: 16) {
            Eyebrow("今天的回忆做完了")
            Text(results.isEmpty ? "今天没有到期的句子" : "\(results.count) 题 · 想起来 \(good) 题")
                .font(.system(size: 28, weight: .black)).foregroundStyle(Theme.ink)
            if !results.isEmpty {
                Text("忘了的句子明天会再出现；想起来的间隔会越拉越长——这就是间隔重复。")
                    .font(.callout).foregroundStyle(Theme.dim)
            } else {
                Text("去划几段英文收进来，新句每天最多引入 \(ReviewStore.newPerDayLimit) 句。")
                    .font(.callout).foregroundStyle(Theme.dim)
            }
            Button("完成") { dismiss() }
                .buttonStyle(WorkbenchButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 逻辑

    /// 没有中文又拿不到时，中→英退回听写
    private func effectiveMode(for s: EchoSentence) -> RecallMode {
        let m = review.mode(for: s)
        if m == .zhToEn, zhText(s) == nil, !loadingZH, store.aiKey.isEmpty { return .dictation }
        return m
    }

    private func zhText(_ s: EchoSentence) -> String? {
        if let z = zh, !z.isEmpty { return z }
        if let z = s.analysis?.zh, !z.isEmpty { return z }
        if let z = review.state(for: s.id)?.zh, !z.isEmpty { return z }
        return nil
    }

    private func prepare() {
        answer = ""
        revealed = false
        zh = nil
        guard let s = current else { return }
        let mode = effectiveMode(for: s)
        answerFocused = true
        if mode == .dictation {
            Speech.shared.speak(s.text, rate: store.speechRate)
        }
        if zhText(s) == nil, !store.aiKey.isEmpty {
            loadingZH = true
            let id = s.id
            Task {
                if let r = try? await AIService.quickTranslate([s.text], config: store.aiConfig), let z = r.first {
                    review.cacheZH(z, for: s)
                    if current?.id == id { zh = z }
                }
                loadingZH = false
            }
        }
    }

    private func reveal() {
        guard !revealed, let s = current else { return }
        revealed = true
        answerFocused = false
        Speech.shared.speak(s.text, rate: store.speechRate)
    }

    private func rate(_ r: RecallRating, for s: EchoSentence) {
        review.record(r, for: s, dayKey: store.dayKey())
        results.append(r)
        // 忘了的在这一轮末尾再出现一次（同一轮只回一次，免得卡死）
        if r == .again, !requeued.contains(s.id) {
            requeued.insert(s.id)
            items.append(s)
        }
        advance()
    }

    private func advance() {
        Speech.shared.stop()
        index += 1
        prepare()
    }

    private func nextIntervalHint(_ r: RecallRating, for s: EchoSentence) -> String {
        let st = review.state(for: s.id)
        let reps = st?.lastReviewed == nil ? 0 : (st?.reps ?? 0)
        let interval = st?.interval ?? 0
        let ease = st?.ease ?? 2.5
        let days: Double
        switch r {
        case .again: days = 1
        case .hard: days = reps == 0 ? 1 : max(interval + 1, interval * 1.2)
        case .good: days = reps == 0 ? 3 : (reps == 1 ? 7 : interval * ease)
        }
        return "下次出现：约 \(Int(days.rounded())) 天后"
    }
}
