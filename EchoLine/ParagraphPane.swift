import SwiftUI
import AppKit

/// 段落解读面板：整段中译 + 大意 + 句间逻辑 + 逐句精读入口
struct ParagraphPane: View {
    let paragraphID: UUID
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared

    @State private var isAnalysing = false
    @State private var errorMessage: String?
    @State private var zhRevealed = false
    @State private var wordLookup: WordLookupRequest?
    @State private var shadowingParagraph = false

    private var paragraph: EchoSentence? {
        store.sentences.first { $0.id == paragraphID }
    }

    var body: some View {
        ScrollView {
            if let p = paragraph {
                VStack(alignment: .leading, spacing: 16) {

                    // ---- 整段 ----
                    VStack(alignment: .leading, spacing: 12) {
                        Overline("段落 · \(store.children(of: p).count) 句")

                        TapText(text: p.text, fontSize: 16) { word in
                            openWord(word, in: p)
                        }
                        Text("单击或划选一个词 · 查释义、发音与词形")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 14) {
                            Button {
                                if speech.isSpeaking { speech.stop() }
                                else { speech.speak(p.text, rate: store.speechRate) }
                            } label: {
                                Label(speech.isSpeaking && speech.spokenText == p.text ? "停止" : "朗读整段",
                                      systemImage: speech.isSpeaking && speech.spokenText == p.text ? "stop.circle.fill" : "play.circle.fill")
                            }
                            .foregroundStyle(Theme.ice)
                            Button {
                                speech.stop()
                                shadowingParagraph = true
                            } label: {
                                Label("跟读整段", systemImage: "mic")
                            }
                            .foregroundStyle(Theme.ice)
                            .help("录下整段朗读：本机比对 + AI 听录音，分项打分并逐句点评（⌘↩）")
                            .keyboardShortcut(.return, modifiers: .command)
                            Button {
                                store.startTyping(p)
                            } label: {
                                Label("临摹", systemImage: "keyboard")
                            }
                            .foregroundStyle(Theme.ice)
                            .help("打字临摹整段：看着打 / 凭记忆打 / 听着打（⇧⌘T）")
                            .keyboardShortcut("t", modifiers: [.command, .shift])
                            Spacer()
                            Button(role: .destructive) {
                                store.delete(p)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .font(.callout)

                        // 整段中译（悬停显示）
                        if !p.paraZH.isEmpty {
                            let visible = store.zhAlwaysVisible || zhRevealed
                            Text(p.paraZH)
                                .font(.callout).foregroundStyle(.secondary)
                                .blur(radius: visible ? 0 : 5)
                                .animation(.easeInOut(duration: 0.15), value: visible)
                                .onHover { inside in
                                    if !store.zhAlwaysVisible { zhRevealed = inside }
                                }
                        }
                    }
                    .paperCard()

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

                    // ---- 大意 + 逻辑（扁平分区：overline + 发丝线）----
                    if !p.paraGist.isEmpty || !p.paraLogic.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            if !p.paraGist.isEmpty {
                                Overline("段落大意")
                                Hairline().padding(.top, 6)
                                Text(p.paraGist).font(.callout).padding(.top, 10)
                            }
                            if !p.paraLogic.isEmpty {
                                Overline("句间逻辑")
                                    .padding(.top, p.paraGist.isEmpty ? 0 : 16)
                                Hairline().padding(.top, 6)
                                Text(p.paraLogic).font(.callout).lineSpacing(5).padding(.top, 10)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isAnalysing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(store.aiConfig.providerName) 解读段落中…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        Button {
                            Task { await analyse(p) }
                        } label: {
                            Label("解读整段（大意 + 逻辑 + 中译）", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                    }

                    // ---- 逐句精读 ----
                    VStack(alignment: .leading, spacing: 0) {
                        Overline("逐句精读")
                        Hairline().padding(.top, 6)
                        ForEach(Array(store.children(of: p).enumerated()), id: \.element.id) { i, child in
                            ParagraphChildRow(index: i, child: child)
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !p.source.isEmpty {
                        Text("来源：\(p.source) · \(p.dateAdded.formatted(.dateTime.year().month().day()))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)   // 与详情页同款阅读行宽
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $shadowingParagraph) {
            if let p = paragraph {
                ParagraphShadowSheet(text: p.text, sentences: store.children(of: p).map(\.text))
                    .environmentObject(store)
            }
        }
        .background(Theme.bg)
        .onAppear { autoAnalyse() }
        .onChange(of: paragraphID) {
            errorMessage = nil
            wordLookup = nil
            autoAnalyse()
        }
    }

    private func openWord(_ raw: String, in paragraph: EchoSentence) {
        guard let word = WordSelection.singleWord(from: raw) else { return }
        Speech.shared.speak(word, rate: store.speechRate)
        // 语境给到「这个词所在的那一句」而不是整段：释义和句中作用都要按这一句来讲
        let key = WordSelection.comparisonKey(word)
        let sentence = store.children(of: paragraph).first { child in
            child.text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
                .contains { WordSelection.comparisonKey(String($0)) == key }
        }?.text ?? paragraph.text
        withAnimation {
            wordLookup = WordLookupRequest(word: word, context: sentence, fallbackMeaning: nil)
        }
    }

    private func autoAnalyse() {
        if let p = paragraph, p.paraGist.isEmpty, !isAnalysing, !store.aiKey.isEmpty {
            Task { await analyse(p) }
        }
    }

    private func analyse(_ p: EchoSentence) async {
        isAnalysing = true
        errorMessage = nil
        do {
            let r = try await AIService.analyseParagraph(p.text, config: store.aiConfig)
            var copy = p
            copy.paraZH = r.zh
            copy.paraGist = r.gist
            copy.paraLogic = r.logic
            store.update(copy)
        } catch {
            errorMessage = error.localizedDescription
        }
        isAnalysing = false
    }
}

// MARK: - 逐句精读行（拆分子视图，避免编译器类型推断超时）

private struct ParagraphChildRow: View {
    let index: Int
    let child: EchoSentence
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared

    private var isLoopingThis: Bool {
        speech.isLooping && speech.loopText == child.text
    }

    var body: some View {
        Button {
            store.selectedID = child.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // 序号：安静的等宽数字，不用彩色圆底
                Text("\(index + 1)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if child.analysis != nil {
                        BracketTag("已精读", active: true)
                    }
                }
                Spacer()
                // 单句播放 + 循环
                Button {
                    speech.speak(child.text, rate: store.speechRate)
                } label: {
                    Image(systemName: "play.circle")
                        .foregroundStyle(Theme.ice)
                }
                .buttonStyle(.plain)
                Button {
                    speech.toggleLoop(child.text, rate: store.speechRate)
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(isLoopingThis ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help("循环朗读这一句")
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 生词本面板（AI 整理 + 生词串文）

struct WordbookPane: View {
    @EnvironmentObject var store: EchoStore
    @State private var search = ""
    @State private var viewMode = "time"          // time / topic / group
    @State private var organising = false
    @State private var weaving = false
    @State private var errorMessage: String?
    @State private var cleanup: [AIService.CleanupItem] = []
    @State private var showCleanup = false
    @State private var showDigestZH = false
    @State private var pronWordID: UUID?
    @State private var showDrill = false

    private var filtered: [CollectedWord] {
        search.isEmpty ? store.collectedWords :
            store.collectedWords.filter {
                $0.word.localizedCaseInsensitiveContains(search) || $0.note.contains(search)
                    || ($0.topic ?? "").contains(search)
            }
    }

    /// 按当前视图分组
    private var grouped: [(key: String, items: [CollectedWord])] {
        switch viewMode {
        case "topic":
            let dict = Dictionary(grouping: filtered) { $0.topic ?? "未整理" }
            return dict.sorted { $0.value.count > $1.value.count }.map { (key: $0.key, items: $0.value) }
        case "group":
            let dict = Dictionary(grouping: filtered) { $0.group ?? "独立词" }
            // 有词族的组排前面
            return dict.sorted {
                if ($0.key == "独立词") != ($1.key == "独立词") { return $1.key == "独立词" }
                return $0.value.count > $1.value.count
            }.map { (key: $0.key, items: $0.value) }
        default:
            return [(key: "", items: filtered)]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("生词本", systemImage: "bookmark.fill")
                        .font(.title3.weight(.medium)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(store.collectedWords.count) 个")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // 工具行
                HStack(spacing: 10) {
                    Button {
                        Task { await organise() }
                    } label: {
                        if organising {
                            HStack(spacing: 5) { ProgressView().controlSize(.small); Text("整理中…") }
                        } else {
                            Label("AI 整理", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(organising || store.collectedWords.isEmpty || store.aiKey.isEmpty)

                    Button {
                        Task { await weave() }
                    } label: {
                        if weaving {
                            HStack(spacing: 5) { ProgressView().controlSize(.small); Text("编写中…") }
                        } else {
                            Label("生词串文", systemImage: "text.badge.star")
                        }
                    }
                    .disabled(weaving || store.collectedWords.count < 3 || store.aiKey.isEmpty)

                    Button {
                        showDrill = true
                    } label: {
                        Label("逐个练发音", systemImage: "waveform.badge.mic")
                    }
                    .disabled(store.collectedWords.isEmpty)
                    .help("按「没练过 → 分数最低」的顺序，一个个读、打分")

                    Picker("", selection: $viewMode) {
                        Text("时间").tag("time")
                        Text("主题").tag("topic")
                        Text("词族").tag("group")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    Spacer()
                }

                TextField("搜索生词 / 主题", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                }

                // 生词串文卡
                if let d = store.digest {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Overline("生词串文 · \(d.words.count) 词 · \(d.date.formatted(.dateTime.month().day()))")
                            Spacer()
                            Button {
                                Speech.shared.speak(d.en, rate: store.speechRate)
                            } label: {
                                Image(systemName: "play.circle.fill").foregroundStyle(Theme.ice)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(d.en)
                            .font(.system(.callout, design: .serif))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                        Button {
                            withAnimation { showDigestZH.toggle() }
                        } label: {
                            Label("中译", systemImage: showDigestZH ? "chevron.up" : "chevron.down")
                                .font(.caption2).foregroundStyle(Theme.ice)
                        }
                        .buttonStyle(.plain)
                        if showDigestZH {
                            Text(d.zh).font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                        }
                    }
                    .paperCard()
                }

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark").font(.title2).foregroundStyle(.tertiary)
                        Text(search.isEmpty ? "点句子里的单词 → 释义卡上「收藏」，生词就攒在这里" : "没有匹配的生词")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(grouped, id: \.key) { g in
                        if !g.key.isEmpty {
                            HStack(spacing: 6) {
                                Text(g.key).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                                Text("\(g.items.count)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.top, 4)
                        }
                        ForEach(g.items) { w in
                            wordCard(w)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .onAppear { store.loadDigest() }
        .sheet(isPresented: $showCleanup) { cleanupSheet }
        .sheet(isPresented: $showDrill) {
            WordDrillSheet(words: drillOrder).environmentObject(store)
        }
    }

    // MARK: 词行（发丝线分隔的扁平行，不用一卡一词）

    private func wordCard(_ w: CollectedWord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(w.word).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                Button {
                    Speech.shared.speak(w.word, rate: store.speechRate)
                } label: {
                    Image(systemName: "speaker.wave.2").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ice)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) { pronWordID = pronWordID == w.id ? nil : w.id }
                } label: {
                    Image(systemName: pronWordID == w.id ? "mic.fill" : "mic").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ice)
                .help("录音评分")
                if let best = store.bestAccuracy(for: w.word.lowercased()) {
                    Text("\(best)")
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(WordScoring.color(best))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(WordScoring.color(best).opacity(0.12), in: Capsule())
                        .help("发音最好成绩")
                }

                if let p = w.priority {
                    priorityBadge(p)
                }
                if viewMode != "topic", let t = w.topic {
                    BracketTag(t)
                }
                Spacer()
                Text(w.dateAdded.formatted(.dateTime.month().day()))
                    .font(.caption2).foregroundStyle(.tertiary)
                Button {
                    store.deleteCollected(w)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            Text(w.note).font(.callout)
            if pronWordID == w.id {
                WordPronunciationPanel(word: w.word, compact: true)
                    .transition(.opacity)
            }
            if !w.sentence.isEmpty {
                HStack(alignment: .top) {
                    Text(w.sentence)
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(.secondary)
                        .italic()
                    Spacer()
                    Button {
                        Speech.shared.speak(w.sentence, rate: store.speechRate)
                    } label: {
                        Image(systemName: "play.circle").font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.ice)
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// 逐个练的顺序：没练过的在前，其次是最好成绩最低的
    private var drillOrder: [CollectedWord] {
        let list = filtered
        return list.sorted { a, b in
            let sa = store.bestAccuracy(for: a.word.lowercased()) ?? -1
            let sb = store.bestAccuracy(for: b.word.lowercased()) ?? -1
            return sa < sb
        }
    }

    /// 重要度：括弧标签——只有"高频"是值得跳出来的状态，上青碧
    private func priorityBadge(_ p: String) -> some View {
        switch p {
        case "core": BracketTag("高频", active: true)
        case "rare": BracketTag("低频")
        default: BracketTag("常用")
        }
    }

    // MARK: 清理建议

    private var cleanupSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI 清理建议", systemImage: "trash.slash")
                .font(.headline).foregroundStyle(Theme.ink)
            if cleanup.isEmpty {
                Text("没有需要清理的词，生词本很干净。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(cleanup) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.word).font(.callout.bold())
                            Text(c.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("删除") {
                            store.deleteCollected(word: c.word)
                            cleanup.removeAll { $0.id == c.id }
                        }
                        .foregroundStyle(Theme.wrong)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Hairline() }
                }
            }
            HStack {
                Spacer()
                Button("完成") { showCleanup = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    // MARK: 逻辑

    private func organise() async {
        organising = true
        errorMessage = nil
        do {
            // 分批（每批 60 词）
            var allItems: [AIService.OrgItem] = []
            var allCleanup: [AIService.CleanupItem] = []
            let words = store.collectedWords.map { (word: $0.word, note: $0.note) }
            for chunk in stride(from: 0, to: words.count, by: 60).map({ Array(words[$0..<min($0+60, words.count)]) }) {
                let r = try await AIService.organiseWordbook(chunk, config: store.aiConfig)
                allItems += r.items
                allCleanup += r.cleanup
            }
            store.applyOrganisation(allItems)
            cleanup = allCleanup
            showCleanup = true
            viewMode = "topic"
        } catch {
            errorMessage = error.localizedDescription
        }
        organising = false
    }

    private func weave() async {
        weaving = true
        errorMessage = nil
        do {
            let words = Array(store.collectedWords.prefix(12)).map(\.word)
            let r = try await AIService.weaveStory(words, config: store.aiConfig)
            store.saveDigest(WeaveDigest(en: r.en, zh: r.zh, words: words))
            showDigestZH = false
        } catch {
            errorMessage = error.localizedDescription
        }
        weaving = false
    }
}
