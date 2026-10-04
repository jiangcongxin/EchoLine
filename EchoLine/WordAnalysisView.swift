import SwiftUI
import AppKit
import Accessibility

/// 一次点词或划词请求。上下文参与缓存键，也让同一个词在不同句子中得到不同的语境义。
struct WordLookupRequest: Identifiable, Equatable {
    var id: String { word.lowercased() + "|" + context }
    let word: String
    let context: String
    let fallbackMeaning: String?
}

/// 单词分析卡：发音永远可用，已有语境义先显示，AI 再渐进补齐词形与用法。
struct WordAnalysisCard: View {
    let request: WordLookupRequest
    var compact = false

    @EnvironmentObject private var store: EchoStore
    @AppStorage("aiKey") private var observedAIKey = ""
    @State private var analysis: WordAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var reloadToken = 0
    @State private var showMore = false
    @State private var collected = false
    @State private var showPronunciation = false

    private var displayedWord: String {
        nonEmpty(analysis?.surface) ?? request.word
    }

    private var collectionWord: String {
        nonEmpty(analysis?.headword) ?? request.word
    }

    private var primaryMeaning: String? {
        nonEmpty(analysis?.contextMeaning)
            ?? nonEmpty(request.fallbackMeaning)
            ?? nonEmpty(storedWord?.note)
            ?? nonEmpty(analysis?.meaning)
    }

    private var storedWord: CollectedWord? {
        let keys = [request.word, analysis?.surface, analysis?.headword]
            .compactMap { $0 }
            .map { WordSelection.comparisonKey($0) }
        return store.collectedWords.first { keys.contains(WordSelection.comparisonKey($0.word)) }
    }

    private var canCollect: Bool {
        let waitingForLemma = analysis == nil && !store.aiKey.isEmpty && errorMessage == nil
        return primaryMeaning != nil && !waitingForLemma
            && !store.knownWord(collectionWord) && !collected
    }

    private var displayForms: [WordForm] {
        analysis?.forms.filter { nonEmpty($0.form) != nil } ?? []
    }

    private var collectAccessibilityHint: String {
        if store.knownWord(collectionWord) || collected { return "这个词已经在生词本中" }
        if primaryMeaning == nil { return "获得释义后可以收藏" }
        if analysis == nil && !store.aiKey.isEmpty && errorMessage == nil {
            return "正在确认词形原形，请稍候"
        }
        return "将 \(collectionWord) 和当前释义收藏进生词本"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            header
            speechControls
            if showPronunciation {
                WordPronunciationPanel(word: displayedWord, phonetic: nonEmpty(analysis?.phonetic), compact: compact)
                    .id(displayedWord)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let meaning = primaryMeaning {
                VStack(alignment: .leading, spacing: 4) {
                    Overline(request.context.isEmpty ? "释义" : "在这句话里")
                    Text(meaning)
                        .font(compact ? .callout : .body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                    if let core = nonEmpty(analysis?.meaning), core != meaning {
                        Text("核心义：\(core)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 点一个词最想知道的第二件事：它在这句里干什么
            if let role = nonEmpty(analysis?.role) {
                VStack(alignment: .leading, spacing: 4) {
                    Overline("在句中的作用")
                    Text(role)
                        .font(compact ? .callout : .body)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                }
            }

            if !displayForms.isEmpty {
                formsView(displayForms)
            }

            if isLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(primaryMeaning == nil ? "查询释义与词形…" : "正在补充词形、词族与用法…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(primaryMeaning == nil ? Theme.wrong : .secondary)
                    Spacer()
                    if store.aiKey.isEmpty {
                        SettingsLink {
                            Text("配置 AI")
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityLabel("打开设置并配置 AI Key")
                    } else {
                        Button("重试") { reloadToken += 1 }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            if let analysis, hasMore(analysis) {
                moreAnalysis(analysis)
            }

            if !request.context.isEmpty && !compact {
                Text(request.context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    guard let note = primaryMeaning else { return }
                    store.collectWord(word: collectionWord, note: note, sentence: request.context)
                    collected = true
                } label: {
                    Label(store.knownWord(collectionWord) || collected ? "已在生词本" : "收藏进生词本",
                          systemImage: store.knownWord(collectionWord) || collected ? "bookmark.fill" : "bookmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canCollect ? Theme.ice : .secondary)
                .disabled(!canCollect)
                .accessibilityLabel(store.knownWord(collectionWord) || collected
                                    ? "单词 \(collectionWord) 已在生词本"
                                    : "收藏单词 \(collectionWord)")
                .accessibilityHint(collectAccessibilityHint)

                Spacer()
                if let source = nonEmpty(analysis?.source) {
                    Text("\(source) 单词分析")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(compact ? 0.25 : 0.35), radius: compact ? 6 : 12, y: 4)
        .task(id: "\(request.id)|\(reloadToken)|\(observedAIKey.isEmpty)") {
            await load(force: reloadToken > 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayedWord)
                    .font(compact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let headword = nonEmpty(analysis?.headword),
                   WordSelection.comparisonKey(headword) != WordSelection.comparisonKey(displayedWord) {
                    Text("→ \(headword)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.ice)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 28)
            }
            HStack(spacing: 8) {
                if let phonetic = nonEmpty(analysis?.phonetic) {
                    Text(phonetic)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let partOfSpeech = nonEmpty(analysis?.partOfSpeech) {
                    BracketTag(partOfSpeech, active: true)
                }
            }
        }
    }

    private var speechControls: some View {
        HStack(spacing: 10) {
            Button {
                Speech.shared.speak(displayedWord, rate: store.speechRate)
            } label: {
                Label("发音", systemImage: "speaker.wave.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Theme.ice)
            .accessibilityLabel("朗读单词 \(displayedWord)")

            Button {
                Speech.shared.speak(displayedWord, rate: store.slowRate)
            } label: {
                Label("慢速", systemImage: "tortoise")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("慢速朗读单词 \(displayedWord)")

            Button {
                withAnimation(.easeOut(duration: 0.18)) { showPronunciation.toggle() }
            } label: {
                Label("录音评分", systemImage: showPronunciation ? "mic.fill" : "mic")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(showPronunciation ? Theme.ice : .secondary)
            .help("读一遍这个词，本机 + AI 打分，指出哪个音不对")
            .accessibilityLabel("录音并给 \(displayedWord) 的发音打分")

            // 听真人在真实语境里怎么说它、查权威词典——比 TTS 更接近真实语流
            Menu {
                if let u = WordLinks.youglish(collectionWord) {
                    Button("YouGlish · 听真人说") { NSWorkspace.shared.open(u) }
                }
                if let u = WordLinks.cambridge(collectionWord) {
                    Button("Cambridge 词典") { NSWorkspace.shared.open(u) }
                }
                if let u = WordLinks.ozdic(collectionWord) {
                    Button("Ozdic 搭配") { NSWorkspace.shared.open(u) }
                }
            } label: {
                Image(systemName: "safari")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("在 YouGlish / Cambridge / Ozdic 打开这个词")
        }
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .regular)
    }

    private func formsView(_ forms: [WordForm]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Overline("词形变化")
            WrapLayout(spacing: 6) {
                ForEach(Array(forms.enumerated()), id: \.offset) { _, item in
                    Button {
                        Speech.shared.speak(item.form, rate: store.speechRate)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(nonEmpty(item.label) ?? "词形")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(item.form).font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("朗读 \(item.form)")
                    .accessibilityLabel("\(nonEmpty(item.label) ?? "词形")，\(item.form)")
                    .accessibilityHint("朗读这个词形")
                }
            }
        }
    }

    private func hasMore(_ result: WordAnalysis) -> Bool {
        !result.wordFamily.isEmpty || !result.collocations.isEmpty
            || nonEmpty(result.usage) != nil || nonEmpty(result.example) != nil
    }

    private func moreAnalysis(_ result: WordAnalysis) -> some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 9) {
                if !result.wordFamily.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Overline("词族")
                        ForEach(Array(result.wordFamily.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Button(item.word) {
                                    Speech.shared.speak(item.word, rate: store.speechRate)
                                }
                                .buttonStyle(.link)
                                if let detail = wordFamilyDetail(item) {
                                    Text(detail)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !result.collocations.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Overline("常用搭配")
                        Text(result.collocations.joined(separator: " · "))
                            .font(.caption).lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
                if let usage = nonEmpty(result.usage) {
                    VStack(alignment: .leading, spacing: 3) {
                        Overline("用法提示")
                        Text(usage).font(.caption).lineSpacing(3)
                    }
                }
                if let example = nonEmpty(result.example) {
                    VStack(alignment: .leading, spacing: 3) {
                        Overline("例句")
                        Text(example).font(.system(.caption, design: .serif)).textSelection(.enabled)
                        if let zh = nonEmpty(result.exampleZH) {
                            Text(zh).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 7)
        } label: {
            Text("词族、搭配与例句")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.ice)
        }
    }

    @MainActor
    private func load(force: Bool) async {
        analysis = nil
        errorMessage = nil

        if !force,
           let cached = store.cachedWordAnalysis(word: request.word, context: request.context),
           nonEmpty(cached.meaning) != nil || nonEmpty(cached.contextMeaning) != nil {
            analysis = cached
            AccessibilityNotification.Announcement("已显示 \(request.word) 的单词分析").post()
            return
        }

        guard !store.aiKey.isEmpty else {
            errorMessage = primaryMeaning == nil
                ? "填入 AI Key 后可查看中文释义、音标、词形和词族；发音现在即可使用"
                : "填入 AI Key 后可继续补充音标、词形和词族"
            AccessibilityNotification.Announcement("需要配置 AI Key 才能查看完整单词分析").post()
            return
        }

        isLoading = true
        AccessibilityNotification.Announcement("正在查询 \(request.word) 的释义与词形").post()
        defer { isLoading = false }
        do {
            let result = try await AIService.analyseWord(
                word: request.word,
                context: request.context,
                config: store.aiConfig
            )
            guard !Task.isCancelled else { return }
            analysis = result
            store.cacheWordAnalysis(result, word: request.word, context: request.context)
            AccessibilityNotification.Announcement("已显示 \(request.word) 的单词分析").post()

            // 兼容旧版轻量释义入口；其他还没升级的视图也能立即命中语境义。
            if !request.context.isEmpty,
               let note = nonEmpty(result.contextMeaning) ?? nonEmpty(result.meaning) {
                store.cacheGloss(word: request.word, sentence: request.context, note: note)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            AccessibilityNotification.Announcement("单词分析失败：\(error.localizedDescription)").post()
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func wordFamilyDetail(_ item: WordFamilyEntry) -> String? {
        let part = nonEmpty(item.partOfSpeech).map { "[\($0)]" }
        let meaning = nonEmpty(item.meaning)
        let result = [part, meaning].compactMap { $0 }.joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}

/// 跨应用只划中一个单词时使用；不会把词误存成句子。
struct QuickWordPanelView: View {
    let word: String
    let source: String
    @EnvironmentObject private var store: EchoStore
    @ObservedObject private var panelCtrl = QuickPanel.shared

    private var request: WordLookupRequest {
        WordLookupRequest(word: word, context: "", fallbackMeaning: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("EchoLine · 单词", systemImage: "character.book.closed.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.ice)
                if !source.isEmpty {
                    Text("来自 \(source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button {
                    panelCtrl.isPinned.toggle()
                } label: {
                    Image(systemName: panelCtrl.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(panelCtrl.isPinned ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.tertiary))
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(panelCtrl.isPinned ? "取消固定单词浮窗" : "固定单词浮窗")
                .help(panelCtrl.isPinned ? "取消固定" : "固定浮窗")
                Button {
                    QuickPanel.shared.close()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭单词浮窗")
                .help("关闭（Esc）")
            }

            ScrollView {
                WordAnalysisCard(request: request, compact: true)
            }
        }
        .padding(14)
        .frame(width: 440, height: 380, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 0.5))
        .onExitCommand { QuickPanel.shared.close() }
    }
}
