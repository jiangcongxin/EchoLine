import SwiftUI
import AppKit

/// 右栏：句子解读
struct DetailPane: View {
    let sentenceID: UUID
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared

    @State private var isAnalysing = false
    @State private var errorMessage: String?
    @State private var gloss: GlossPair?              // 多词亮点表达沿用轻量卡
    @State private var wordLookup: WordLookupRequest?
    @State private var zhRevealed = false
    @State private var tagEditor = false
    @State private var tagInput = ""
    @State private var shadowing = false
    @State private var practicing = false

    private var sentence: EchoSentence? {
        store.sentences.first { $0.id == sentenceID }
    }

    var body: some View {
        ScrollView {
            if let s = sentence {
                VStack(alignment: .leading, spacing: 16) {

                    // 段落子句：返回入口
                    if let pid = s.parentID {
                        Button {
                            store.selectedID = pid
                        } label: {
                            Label("返回段落", systemImage: "chevron.left")
                                .font(.callout).foregroundStyle(Theme.ice)
                        }
                        .buttonStyle(.plain)
                    }

                    // ---- 句子本体 ----
                    VStack(alignment: .leading, spacing: 12) {
                        // 标签：括弧式文字标签，不用胶囊徽章
                        if !s.tags.isEmpty {
                            HStack(spacing: 8) {
                                Spacer()
                                ForEach(s.tags, id: \.self) { t in
                                    Button {
                                        tagInput = s.tags.joined(separator: ", ")
                                        tagEditor = true
                                    } label: {
                                        BracketTag(t)
                                    }
                                    .buttonStyle(.plain)
                                    .help("编辑标签")
                                }
                            }
                        }

                        TapText(text: s.text, fontSize: 21,
                                iceTerms: (s.analysis?.highlights ?? []).map(\.term),
                                verbTerms: s.analysis?.verbs ?? []) { token in
                            tapWord(token, in: s)
                        }
                        Text("单击或划选一个词 · 查释义、发音与词形")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        controls(s)

                        // 中译：默认隐藏，悬停/点击显示
                        if let a = s.analysis, !a.zh.isEmpty {
                            zhView(a.zh)
                        }
                    }
                    .paperCard()

                    // ---- 划词 / 点词分析 ----
                    if let lookup = wordLookup {
                        ZStack(alignment: .topTrailing) {
                            WordAnalysisCard(request: lookup)
                                .id(lookup.id)
                            Button {
                                withAnimation { wordLookup = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭单词分析")
                            .padding(12)
                        }
                        .transition(.opacity)
                    }
                    if let g = gloss {
                        glossCard(g, in: s)
                    }

                    // ---- AI 解读 ----
                    if let a = s.analysis {
                        analysisView(a, s)
                    } else if isAnalysing {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("\(store.aiConfig.providerName) 解读中…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        Button {
                            Task { await analyse(s) }
                        } label: {
                            Label("开始 AI 解读", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                            .textSelection(.enabled)
                    }

                    // 来源
                    if !s.source.isEmpty {
                        Text("来源：\(s.source) · \(s.dateAdded.formatted(.dateTime.year().month().day()))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)   // ≈68ch 阅读行宽，外层 frame 居中
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bg)
        .onAppear { autoAnalyse() }
        .onChange(of: sentenceID) {
            gloss = nil
            wordLookup = nil
            zhRevealed = false
            errorMessage = nil
            autoAnalyse()
        }
        .sheet(isPresented: $shadowing) {
            if let s = sentence {
                ShadowingView(target: s.text)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $practicing) {
            if let s = sentence {
                PracticeView(model: s.text)
                    .environmentObject(store)
            }
        }
    }

    // MARK: 工具条

    private func controls(_ s: EchoSentence) -> some View {
        HStack(spacing: 14) {
            Button {
                if speech.isSpeaking { speech.stop() }
                else { speech.speak(s.text, rate: store.speechRate) }
            } label: {
                Label(speech.isSpeaking && speech.spokenText == s.text ? "停止" : "朗读",
                      systemImage: speech.isSpeaking && speech.spokenText == s.text ? "stop.circle.fill" : "play.circle.fill")
            }
            .foregroundStyle(Theme.ice)

            Button {
                speech.toggleLoop(s.text, rate: store.speechRate)
            } label: {
                Label("循环", systemImage: "repeat")
            }
            .foregroundStyle(speech.isLooping && speech.loopText == s.text ? Theme.ice : .secondary)
            .help("单句循环朗读，磨耳朵用；再点一次停止")

            Button {
                speech.stop()
                shadowing = true
            } label: {
                Label("跟读", systemImage: "mic")
            }
            .foregroundStyle(Theme.ice)
            .help("跟读练习：听原声后录下自己的朗读，离线识别打分（⌘↩）")
            .keyboardShortcut(.return, modifiers: .command)

            Button {
                speech.stop()
                practicing = true
            } label: {
                Label("仿写", systemImage: "pencil.line")
            }
            .foregroundStyle(Theme.ice)
            .help("仿写练习：照这句的句式写自己的句子，AI 批改纠错（⇧⌘↩）")
            .keyboardShortcut(.return, modifiers: [.command, .shift])

            Button {
                store.startTyping(s)
            } label: {
                Label("临摹", systemImage: "keyboard")
            }
            .foregroundStyle(Theme.ice)
            .help("打字临摹这一句：看着打 / 凭记忆打 / 听着打（⇧⌘T）")
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Spacer()

            // 次操作收纳：慢速 / 星标 / 标签 / 复制 / 删除
            Menu {
                Button {
                    speech.speak(s.text, rate: store.slowRate)
                } label: {
                    Label("慢速朗读", systemImage: "tortoise")
                }

                Button {
                    store.toggleStar(s)
                } label: {
                    Label(s.starred ? "取消星标" : "加星标",
                          systemImage: s.starred ? "star.fill" : "star")
                }

                Button {
                    tagInput = s.tags.joined(separator: ", ")
                    tagEditor = true
                } label: {
                    Label(s.tags.isEmpty ? "加标签…" : "编辑标签…", systemImage: "tag")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.text, forType: .string)
                } label: {
                    Label("复制原句", systemImage: "doc.on.doc")
                }

                Divider()

                Button(role: .destructive) {
                    store.delete(s)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("更多操作")
            .popover(isPresented: $tagEditor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("标签（逗号分隔）").font(.caption).foregroundStyle(.secondary)
                    TextField("医学, 文献", text: $tagInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit { saveTags(s) }
                    if let suggested = s.analysis?.suggestedTags, !suggested.isEmpty {
                        HStack {
                            Text("AI 建议：").font(.caption).foregroundStyle(.tertiary)
                            ForEach(suggested, id: \.self) { t in
                                Button("#\(t)") {
                                    var tags = parseTags()
                                    if !tags.contains(t) { tags.append(t) }
                                    tagInput = tags.joined(separator: ", ")
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                    Button("保存") { saveTags(s) }
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    private func parseTags() -> [String] {
        tagInput.split { $0 == "," || $0 == "，" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveTags(_ s: EchoSentence) {
        var copy = s
        copy.tags = parseTags()
        store.update(copy)
        tagEditor = false
    }

    // MARK: 中译（悬停显示）

    @ViewBuilder
    private func zhView(_ zh: String) -> some View {
        let visible = store.zhAlwaysVisible || zhRevealed
        Text(zh)
            .font(.callout)
            .foregroundStyle(.secondary)
            .blur(radius: visible ? 0 : 5)
            .overlay(alignment: .leading) {
                if !visible {
                    Text("悬停显示中译").font(.caption2).foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: visible)
            .onHover { inside in
                if !store.zhAlwaysVisible { zhRevealed = inside }
            }
            .onTapGesture { zhRevealed.toggle() }
    }

    // MARK: 点词

    private func tapWord(_ token: String, in s: EchoSentence) {
        guard let clean = WordSelection.singleWord(from: token) else { return }
        Speech.shared.speak(clean, rate: store.speechRate)

        // 已有整句解读或旧版释义缓存先立即展示；结构化词形分析在卡内渐进补齐。
        let hit = s.analysis?.words.first(where: { matches($0.term, clean) })
        let fallback = hit?.note ?? store.cachedGloss(word: clean, sentence: s.text)
        gloss = nil
        withAnimation {
            wordLookup = WordLookupRequest(word: clean, context: s.text, fallbackMeaning: fallback)
        }
    }

    private func matches(_ term: String, _ token: String) -> Bool {
        guard let termWord = WordSelection.singleWord(from: term) else { return false }
        return WordSelection.comparisonKey(termWord) == WordSelection.comparisonKey(token)
    }

    private func glossCard(_ g: GlossPair, in s: EchoSentence) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(g.term).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                    Button {
                        Speech.shared.speak(g.term, rate: store.speechRate)
                    } label: {
                        Image(systemName: "speaker.wave.2").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ice)
                }
                Text(g.note).font(.callout)
                Button {
                    store.collectWord(word: g.term, note: g.note, sentence: s.text)
                } label: {
                    Label(store.knownWord(g.term) ? "已在生词本" : "收藏进生词本",
                          systemImage: store.knownWord(g.term) ? "bookmark.fill" : "bookmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.knownWord(g.term) ? .secondary : Theme.ice)
                .disabled(store.knownWord(g.term))
            }
            Spacer()
            Button {
                withAnimation { gloss = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        // 点词释义卡是"浮起的一层"：白卡 + 发丝描边 + 柔影，不用彩色底
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 5)
        .transition(.opacity)
    }

    // MARK: 解读展示

    @ViewBuilder
    private func analysisView(_ a: SentenceAnalysis, _ s: EchoSentence) -> some View {
        // 时态专项
        if let t = a.tense {
            section("时态") {
                HStack(spacing: 8) {
                    Text(t.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    if !a.verbs.isEmpty {
                        Text("谓语：" + a.verbs.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(Theme.verb)
                    }
                }
                if !t.why.isEmpty {
                    Text(t.why).font(.callout).lineSpacing(4)
                }
                if !t.timeline.isEmpty {
                    // 时间线：左侧细尺 + 等宽字，代替灰底块
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Theme.line).frame(width: 2)
                        Text(t.timeline)
                            .font(.callout.monospaced())
                    }
                }
            }
        }

        // 结构 + 语法点逐条
        section("结构与语法") {
            Text(a.structure).font(.callout).lineSpacing(5)
            ForEach(a.grammarList, id: \.self) { g in
                HStack(alignment: .top, spacing: 8) {
                    BracketTag(g.term)
                        .fixedSize()
                    Text(g.note).font(.callout)
                }
            }
            if !a.bandNote.isEmpty {
                Text(a.bandNote).font(.caption).foregroundStyle(.secondary)
            }
        }

        if !a.highlights.isEmpty {
            section("值得学的表达") {
                // 发丝线分隔的可点行，代替一排灰底圆角块
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(a.highlights.enumerated()), id: \.element) { i, h in
                        if i > 0 { Hairline() }
                        Button {
                            withAnimation {
                                if let word = WordSelection.singleWord(from: h.term) {
                                    gloss = nil
                                    wordLookup = WordLookupRequest(
                                        word: word,
                                        context: s.text,
                                        fallbackMeaning: h.note
                                    )
                                } else {
                                    wordLookup = nil
                                    gloss = h
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.term).font(.callout.weight(.medium)).foregroundStyle(Theme.ice)
                                Text(h.note).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                    }
                }
            }
        }

        if !a.transfer.isEmpty {
            section("怎么用到自己的英语里") {
                Text(a.transfer).font(.callout).lineSpacing(5)
            }
        }

        HStack {
            Text("\(a.source) 解读").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await analyse(s, force: true) }
            } label: {
                Label("重新解读", systemImage: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// 扁平分区：overline 小标题 + 发丝线 + 留白，代替白卡
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Overline(title)
            Hairline().padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: 解读逻辑

    private func autoAnalyse() {
        if let s = sentence, s.analysis == nil, !isAnalysing, !store.aiKey.isEmpty {
            Task { await analyse(s) }
        }
    }

    private func analyse(_ s: EchoSentence, force: Bool = false) async {
        guard s.analysis == nil || force else { return }
        isAnalysing = true
        errorMessage = nil
        do {
            let result = try await AIService.analyse(s.text, config: store.aiConfig)
            var copy = s
            copy.analysis = result
            store.update(copy)
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalysing = false
    }
}
