import SwiftUI

// MARK: - 今日：照「AI×MED 工作台」的首页
//
// 眉题（日期 · 句库总数）→ 大标题 → 四块数字 → 左：今日重现任务清单 + 最近动作 / 右：语法点掌握 + 常来源。
// 这一页只读 store 里已经缓存的东西（libraryStats / grammarIndex / dailyReview），
// 不做全库正则、不订阅 Speech，免得打开首页就卡。

struct TodayPane: View {
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var review = ReviewStore.shared
    @State private var shadowTarget: ShadowTarget?
    @State private var showRecall = false

    /// 今天的回忆题（到期 + 新句），body 里只算一次
    private var queue: [EchoSentence] { review.queue(from: store) }

    struct ShadowTarget: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                tiles
                HStack(alignment: .top, spacing: 16) {
                    reviewPanel.frame(maxWidth: .infinity)
                    VStack(spacing: 16) {
                        grammarPanel
                        sourcePanel
                    }
                    .frame(width: 320)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WorkbenchBackground())
        .sheet(item: $shadowTarget) { t in
            ShadowingView(target: t.text).environmentObject(store)
        }
        .sheet(isPresented: $showRecall) {
            RecallSessionView().environmentObject(store)
        }
    }

    // MARK: 头

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("\(Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))) · \(Date.now.formatted(.dateTime.weekday(.abbreviated))) · 句库 \(store.libraryStats.sentenceCount)")
            Text("今天读什么")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.callout).foregroundStyle(Theme.dim)
        }
    }

    private var subtitle: String {
        let n = queue.count
        return n == 0
            ? "今天的回忆做完了 · 在任何 App 里划一段英文（⌥⌘E），预览满意再收录"
            : "\(n) 句等你回忆 · 先想、再看、再自评——想出来一次，胜过重读十遍"
    }

    // MARK: 四块数字

    private var weekAdded: Int {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return store.topLevelSentences.filter { $0.dateAdded >= start }.count
    }

    private var weekAttempts: [ShadowAttempt] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return store.shadowAttempts.filter { $0.date >= start }
    }

    private var weekAverage: Int? {
        let a = weekAttempts
        guard !a.isEmpty else { return nil }
        return a.map(\.accuracy).reduce(0, +) / a.count
    }

    /// 指标看"记住了多少"，而不是"收了多少"——收藏不等于学会
    private var tiles: some View {
        let retention = review.retention7
        let q = queue.count
        return HStack(spacing: 16) {
            StatTile(label: "记住率 · 近 7 天",
                     value: retention.map { "\(Int(($0 * 100).rounded()))" } ?? "—",
                     unit: retention == nil ? "" : "%",
                     note: retention == nil ? "复习满 5 次旧句后显示" : "到期旧句里想起来的比例",
                     style: .hero, progress: retention)
                .frame(maxWidth: .infinity)
            StatTile(label: "待回忆", value: "\(q)", unit: "句",
                     note: "今天已做 \(review.reviewedToday) 题 · 约 \(max(1, q / 2)) min", style: .amber)
                .frame(maxWidth: .infinity)
            StatTile(label: "已掌握", value: "\(review.masteredCount)", unit: "句",
                     note: "间隔 3 周以上还想得起 · 在学 \(review.learningCount)")
                .frame(maxWidth: .infinity)
            StatTile(label: "跟读均分", value: weekAverage.map(String.init) ?? "—", unit: "",
                     note: "本周 \(weekAttempts.count) 次 · 收录 \(weekAdded) 条 · 连续 \(store.libraryStats.streak) 天")
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: 今日重现

    private var reviewPanel: some View {
        let q = queue
        return WorkbenchPanel {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("今日回忆").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("填空 → 听写 → 中译英，由浅入深").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Spacer()
                if !q.isEmpty {
                    Button {
                        showRecall = true
                    } label: {
                        Label("开始回忆 · \(q.count)", systemImage: "brain.head.profile")
                    }
                    .buttonStyle(WorkbenchButtonStyle(kind: .primary))
                    .keyboardShortcut("r", modifiers: [.command])
                }
            }
            if q.isEmpty {
                Text(review.reviewedToday > 0
                     ? "今天的回忆做完了。想起来的句子间隔会越拉越长，忘了的明天再见。"
                     : "句库里还没有可回忆的句子——去「资源」里找篇文章，划几段收进来。")
                    .font(.callout).foregroundStyle(Theme.dim)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(q.prefix(5).indices), id: \.self) { i in
                    reviewRow(index: i, q[i])
                }
                if q.count > 5 {
                    Text("还有 \(q.count - 5) 句 · 点「开始回忆」一题一题做")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 4)
            Text("最近动作").font(Theme.mono(11)).tracking(1).foregroundStyle(Theme.dim)
            ForEach(recentLog, id: \.id) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(entry.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                        .frame(width: 96, alignment: .leading)
                    Text(entry.text).font(.callout).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(1)
                }
            }
        }
    }

    /// 上次读得不好的句子标琥珀，排在最前的一句标青碧（"现在读这句"）
    private func reviewRow(index: Int, _ s: EchoSentence) -> some View {
        let best = store.bestAccuracy(for: s.text)
        let weak = (review.state(for: s.id)?.lapses ?? 0) > 0 || (best ?? 100) < 75
        let isNow = index == 0
        let tint: Color = weak ? Theme.verb : (isNow ? Theme.ice : Theme.dim)
        return HStack(alignment: .center, spacing: 14) {
            Text(String(format: "%02d", index + 1))
                .font(Theme.mono(20, .heavy))
                .foregroundStyle(weak || isNow ? tint : Color(white: 0.28))
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.text)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(rowMeta(s, best: best))
                    .font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Speech.shared.speak(s.text, rate: store.speechRate)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
            .help("听一遍")
            Button("跟读") { shadowTarget = ShadowTarget(text: s.text) }
                .buttonStyle(WorkbenchButtonStyle(kind: isNow ? .primary : .normal, small: true))
            Button {
                store.selectedID = s.id
            } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
            .help("打开这句")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(rowBackground(weak: weak, now: isNow), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(weak ? Theme.verb.opacity(0.28) : (isNow ? Theme.ice.opacity(0.35) : Theme.line), lineWidth: 1))
    }

    private func rowBackground(weak: Bool, now: Bool) -> Color {
        if weak { return Theme.verb.opacity(0.06) }
        if now { return Theme.ice.opacity(0.07) }
        return Theme.panel2
    }

    private func rowMeta(_ s: EchoSentence, best: Int?) -> String {
        var parts: [String] = []
        if let st = review.state(for: s.id), st.lastReviewed != nil {
            parts.append("\(review.mode(for: s).title)")
            if st.lapses > 0 { parts.append("忘过 \(st.lapses) 次") }
        } else {
            parts.append("新句 · 填空")
        }
        if let best { parts.append("跟读最好 \(best) 分") }
        if s.isParagraph { parts.append("段落") }
        if let t = s.analysis?.tense?.name, !t.isEmpty { parts.append(t) }
        if !s.source.isEmpty { parts.append("来自 \(s.source)") }
        return parts.joined(separator: " · ")
    }

    private struct LogEntry {
        let id: String
        let date: Date
        let text: String
    }

    /// 最近 5 件事：收录 + 跟读，按时间倒序
    private var recentLog: [LogEntry] {
        let added = store.topLevelSentences.prefix(8).map {
            LogEntry(id: "s" + $0.id.uuidString, date: $0.dateAdded,
                     text: "收录 · \($0.isParagraph ? "段落" : "句子")「\($0.text.prefix(40))…」\($0.source.isEmpty ? "" : " · \($0.source)")")
        }
        let practised = store.shadowAttempts.prefix(8).map {
            LogEntry(id: "a" + $0.id.uuidString, date: $0.date,
                     text: "跟读 · \($0.accuracy) 分「\($0.target.prefix(36))…」")
        }
        return Array((added + practised).sorted { $0.date > $1.date }.prefix(5))
    }

    // MARK: 右栏

    private var grammarPanel: some View {
        WorkbenchPanel {
            HStack {
                Text("语法点").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("统计 →") { store.openOverview() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.ice)
            }
            let buckets = Array(store.grammarIndex.prefix(5))
            let top = max(1, buckets.first?.count ?? 1)
            if buckets.isEmpty {
                Text("收下几句、跑过解读之后，这里按句数列出你攒得最多的语法点。")
                    .font(.caption).foregroundStyle(Theme.dim)
            }
            ForEach(buckets) { b in
                Button {
                    store.openGrammar(b.key)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(b.label).font(.callout).foregroundStyle(Theme.ink)
                            Spacer()
                            Text("\(b.count) 句").font(Theme.mono(11)).foregroundStyle(Theme.ice)
                        }
                        ProgressBar(value: Double(b.count) / Double(top))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var topSources: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: store.topLevelSentences.filter { !$0.source.isEmpty }, by: \.source)
            .mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.prefix(6).map { (name: $0.key, count: $0.value) }
    }

    private var sourcePanel: some View {
        WorkbenchPanel {
            Text("常来源").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
            if topSources.isEmpty {
                Text("还没有来源记录").font(.caption).foregroundStyle(Theme.dim)
            } else {
                FlowRow(spacing: 8) {
                    let sources = topSources
                    ForEach(sources.indices, id: \.self) { i in
                        Chip("\(sources[i].name) · \(sources[i].count)", tint: i == 0 ? Theme.ice : nil)
                    }
                }
            }
            Text("划词 ⌥⌘E 或松开鼠标点小图标 → 预览 → ⏎ 收录")
                .font(.caption).foregroundStyle(Theme.dim)
        }
    }
}

// MARK: - 工作台部件（今日 / 跟读 / 设置共用）

/// 主区背景：近黑底 + 左上角一抹青碧 + 点阵，和工作台一致
struct WorkbenchBackground: View {
    var body: some View {
        ZStack {
            Theme.paper
            RadialGradient(colors: [Theme.ice.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.18, y: 0), startRadius: 0, endRadius: 520)
            Canvas { ctx, size in
                let step: CGFloat = 28
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                                 with: .color(Color.white.opacity(0.05)))
                        x += step
                    }
                    y += step
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// 眉题：一道青碧短线 + 等宽小字
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.ice).frame(width: 18, height: 2)
            Text(text).font(Theme.mono(12)).tracking(1.4).foregroundStyle(Theme.ice)
        }
    }
}

struct WorkbenchPanel<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(.horizontal, 22).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint.map { $0.opacity(0.06) } ?? Theme.panel), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(tint.map { $0.opacity(0.3) } ?? Theme.line, lineWidth: 1))
    }
}

struct StatTile: View {
    enum Style { case normal, hero, amber }
    let label: String
    let value: String
    let unit: String
    let note: String
    var style: Style = .normal
    var progress: Double? = nil

    private var accent: Color {
        switch style {
        case .hero: return Theme.ice
        case .amber: return Theme.verb
        case .normal: return Theme.dim
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(Theme.mono(11)).tracking(1.2).foregroundStyle(accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(Theme.mono(style == .hero ? 46 : 36, .heavy))
                    .foregroundStyle(style == .amber ? Theme.verb : Theme.ink)
                if !unit.isEmpty {
                    Text(unit).font(.callout).foregroundStyle(Theme.dim)
                }
            }
            if let progress { ProgressBar(value: progress) }
            Text(note).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(border, lineWidth: 1))
    }

    private var background: AnyShapeStyle {
        switch style {
        case .hero: return AnyShapeStyle(LinearGradient(colors: [Theme.ice.opacity(0.14), Theme.ice.opacity(0.02)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        case .amber: return AnyShapeStyle(Theme.verb.opacity(0.05))
        case .normal: return AnyShapeStyle(Theme.panel)
        }
    }

    private var border: Color {
        switch style {
        case .hero: return Theme.ice.opacity(0.35)
        case .amber: return Theme.verb.opacity(0.25)
        case .normal: return Theme.line
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.ice
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 6)
    }
}

struct Chip: View {
    let text: String
    var tint: Color? = nil
    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((tint?.opacity(0.14) ?? Theme.raised), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(tint ?? Theme.ink.opacity(0.7))
    }
}

/// 工作台按钮：primary 青碧实底 + 光晕 / normal 面板底描边 / ghost 透明
struct WorkbenchButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, ghost, danger }
    var kind: Kind = .normal
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: kind == .primary ? .bold : .regular))
            .padding(.horizontal, small ? 12 : 16)
            .frame(height: small ? 30 : 38)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(kind == .primary || kind == .danger ? Color.clear : Color(white: 0.2), lineWidth: 1))
            .shadow(color: kind == .primary ? Theme.ice.opacity(0.35) : .clear, radius: 12)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: return Theme.paper
        default: return Theme.ink
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? Theme.ice.opacity(0.8) : Theme.ice
        case .danger: return pressed ? Theme.wrong.opacity(0.8) : Theme.wrong
        case .normal: return pressed ? Theme.raised : Theme.panel
        case .ghost: return pressed ? Theme.raised : .clear
        }
    }
}

/// 简单的流式换行（标签、来源）
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
