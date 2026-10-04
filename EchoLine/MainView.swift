import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主窗口：双栏 = 句库 + 解读
struct MainView: View {
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var review = ReviewStore.shared
    @ObservedObject private var typing = TypingStore.shared
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var showImport = false

    enum Filter: Hashable {
        case all, starred, tag(String)
    }

    @State private var hits: [EchoStore.SearchHit] = []      // 防抖后的搜索结果
    @State private var hitsQuery = ""                        // hits 对应的查询词

    private var searching: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 结果还没跟上输入时不显示"没找到"，免得每打一个字闪一下
    private var resultsReady: Bool { hitsQuery == search }

    // MARK: 过滤后的句子（不搜索时用）

    private var filtered: [EchoSentence] {
        var list = store.topLevelSentences
        switch filter {
        case .all: break
        case .starred: list = list.filter(\.starred)
        case .tag(let t): list = list.filter { $0.tags.contains(t) }
        }
        return list
    }

    private var grouped: [(key: String, items: [EchoSentence])] {
        // 用 store 的共享 formatter：原先每次分组都新建一个，而这行挂在 body 上
        let dict = Dictionary(grouping: filtered) { store.dayKey($0.dateAdded) }
        return dict.sorted { $0.key > $1.key }.map { (key: $0.key, items: $0.value) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
        } detail: {
            if store.todayOpen {
                TodayPane()
            } else if store.resourcesOpen {
                ResourcesPane()
            } else if store.typingOpen {
                TypingPane()
            } else if store.practiceOpen {
                PracticePane()
            } else if store.wordbookOpen {
                WordbookPane()
            } else if store.overviewOpen {
                OverviewPane()
            } else if let key = store.selectedGrammarKey {
                GrammarSentencesPane(bucketKey: key)
            } else if let id = store.selectedID,
               let s = store.sentences.first(where: { $0.id == id }) {
                if s.isParagraph {
                    ParagraphPane(paragraphID: s.id)
                } else {
                    DetailPane(sentenceID: s.id)
                }
            } else {
                emptyDetail
            }
        }
        .onChange(of: store.selectedID) {
            if store.selectedID != nil {
                store.wordbookOpen = false
                store.overviewOpen = false
                store.selectedGrammarKey = nil
                store.todayOpen = false
                store.practiceOpen = false
                store.resourcesOpen = false
                store.typingOpen = false
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $showImport) { ImportSheet() }
        .sheet(item: $store.typingRequest) { request in
            TypingSessionView(sentenceID: request.sentenceID, mode: request.mode)
                .environmentObject(store)
        }
        .dropDestination(for: String.self) { items, _ in
            for t in items { store.importText(t, source: "拖拽") }
            return true
        }
    }

    // MARK: 左栏

    private var sidebar: some View {
        List(selection: $store.selectedID) {
            if searching {
                searchSection
            } else {
                browseSections
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.side)
        .searchable(text: $search, placement: .sidebar,
                    prompt: "搜原句 / 中译 / 解读 / 标签")
        .task(id: search) {
            guard searching else { hits = []; hitsQuery = search; return }
            // 防抖 220ms：连打时不必每个字符都全库扫一遍
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            hits = store.search(search)
            hitsQuery = search
        }
        .navigationTitle("EchoLine")
        .toolbar {
            ToolbarItem {
                SpeedControl()
            }
            ToolbarItem {
                Menu {
                    Button("全部句子") { filter = .all }
                    Button("★ 星标精选") { filter = .starred }
                    if !store.allTags.isEmpty {
                        Divider()
                        ForEach(store.allTags, id: \.self) { t in
                            Button("# \(t)") { filter = .tag(t) }
                        }
                    }
                } label: {
                    Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem {
                Button {
                    showImport = true
                } label: {
                    Label("导入句子", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    // MARK: 侧栏两态：浏览 / 搜索

    @ViewBuilder
    private var browseSections: some View {
        // 工作区入口（照「AI×MED 工作台」的侧栏：READ / PRACTICE 两组）
        Section {
            navRow("今日", icon: "calendar", active: store.todayOpen,
                   badge: dueBadge) {
                store.openToday()
            }
            navRow("生词本", icon: "bookmark", active: store.wordbookOpen,
                   badge: "\(store.collectedWords.count)") {
                store.openWordbook()
            }
            navRow("资源", icon: "safari", active: store.resourcesOpen,
                   badge: "\(LearningResources.groups.map(\.items.count).reduce(0, +))") {
                store.openResources()
            }
        } header: {
            sectionHeader("READ")
        }
        Section {
            navRow("跟读", icon: "mic", active: store.practiceOpen,
                   badge: store.shadowAttempts.isEmpty ? nil : "\(store.shadowAttempts.count)") {
                store.openPractice()
            }
            navRow("临摹", icon: "keyboard", active: store.typingOpen,
                   badge: typing.practicedCount == 0 ? nil : "\(typing.practicedCount)") {
                store.openTyping()
            }
            navRow("统计", icon: "chart.bar", active: store.overviewOpen, badge: overviewSubtitle) {
                store.openOverview()
            }
        } header: {
            sectionHeader("PRACTICE")
        }

        // 今日重现挪到「今日」面板里当任务清单，侧栏只放句库本身
        ForEach(grouped, id: \.key) { group in
            Section {
                ForEach(group.items) { s in
                    row(s)
                }
            } header: {
                // 档案式日期头：小号灰字 + 句数，不做通栏大标题
                sectionHeader("\(dayTitle(group.key)) · \(group.items.count) 句")
            }
        }

        if store.sentences.isEmpty {
            Section {
                Text("点右上角 + 或直接拖一段英文进来")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// 今日待回忆的题数（到期 + 今天可引入的新句）
    private var dueBadge: String? {
        let n = review.queue(from: store).count
        return n == 0 ? nil : "\(n)"
    }

    /// 侧栏入口一行：图标 + 名字 + 右侧计数；选中时青碧图标 + 发光小点（工作台的样子）
    private func navRow(_ title: String, icon: String, active: Bool, badge: String?,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(active ? Theme.ice : Theme.dim)
                Text(title)
                    .fontWeight(active ? .medium : .regular)
                    .foregroundStyle(active ? Theme.ink : Theme.ink.opacity(0.72))
                Spacer()
                if active {
                    Circle().fill(Theme.ice).frame(width: 6, height: 6)
                        .shadow(color: Theme.ice, radius: 4)
                } else if let badge {
                    Text(badge).font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(10, .medium))
            .tracking(1.4)
            .foregroundStyle(Theme.dim)
            .textCase(nil)
    }

    /// 只做纯计数，不碰 grammarIndex——这行挂在侧栏上，不能触发全库正则
    private var overviewSubtitle: String {
        let n = store.sentences.filter { !$0.isParagraph }.count
        return "\(n) 句"
    }

    @ViewBuilder
    private var searchSection: some View {
        if hits.isEmpty && !resultsReady {
            Section {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("搜索中…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } else if hits.isEmpty {
            Section {
                Text("没找到「\(search)」\n原句、中译、AI 解读、标签都会搜")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        } else {
            Section("\(hits.count) 条结果") {
                ForEach(hits) { hit in
                    searchRow(hit)
                }
            }
        }
    }

    private func searchRow(_ hit: EchoStore.SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.sentence.text)
                .font(.system(.callout, design: .serif))
                .lineLimit(2)
            HStack(spacing: 5) {
                if hit.sentence.isParagraph {
                    BracketTag("段落")
                } else if hit.sentence.parentID != nil {
                    BracketTag("段中句")
                }
                ForEach(hit.fields, id: \.rawValue) { f in
                    BracketTag(f.rawValue)
                }
                Spacer()
            }
            if !hit.snippet.isEmpty {
                Text(hit.snippet)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .tag(hit.sentence.id)
    }

    private var filterTitle: String {
        switch filter {
        case .all: return "全部"
        case .starred: return "星标"
        case .tag(let t): return "#\(t)"
        }
    }

    private func row(_ s: EchoSentence, showDate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if s.starred {
                    // 星标是用户打的状态，用墨色而不是彩色
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.ink)
                }
                Text(s.text)
                    .font(.system(.callout, design: .serif))
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if s.isParagraph {
                    BracketTag("段落 · \(store.children(of: s).count) 句")
                }
                if s.analysis != nil || !s.paraGist.isEmpty {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.tertiary)
                }
                if !s.source.isEmpty {
                    Text(s.source).font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(s.tags.prefix(2), id: \.self) { t in
                    BracketTag(t)
                }
                if showDate {
                    Text(s.dateAdded.formatted(.dateTime.month().day()))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .tag(s.id)
        .contextMenu {
            Button(s.starred ? "取消星标" : "加星标") { store.toggleStar(s) }
            Button("朗读") { Speech.shared.speak(s.text, rate: store.speechRate) }
            Button("临摹（打字）") { store.startTyping(s) }
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.text, forType: .string)
            }
            Divider()
            Button("删除", role: .destructive) { store.delete(s) }
        }
    }

    private func dayTitle(_ key: String) -> String {
        if key == store.dayKey() { return "今天" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now),
           key == store.dayKey(yesterday) { return "昨天" }
        return key
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.opening")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("选一个句子，或收下第一句").font(.title3)
            Text("⌘N 导入 · 也可以直接把英文拖进窗口")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

// MARK: - 导入弹窗

struct ImportSheet: View {
    @EnvironmentObject var store: EchoStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var preview: [String] { SentenceSplitter.split(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导入句子").font(.headline)
            Text("粘贴英文句子或整段文字，自动拆句去重")
                .font(.callout).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .serif))
                .frame(minHeight: 160)
                .padding(6)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))

            if !preview.isEmpty {
                Text("将导入 \(preview.count) 句").font(.caption).foregroundStyle(Theme.ice)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入") {
                    store.importText(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
