import SwiftUI
import AppKit

/// 句库总览：累计数据 + 语法点分布 + 主题标签分布
/// 解决"句子越攒越多，旧的等于消失"——不靠翻列表，靠语法点这条线索横切整个句库
struct OverviewPane: View {
    @EnvironmentObject var store: EchoStore

    // 在 onAppear 算一次：建索引要跑全库，不能挂 computed 让 body 反复触发
    @State private var stats = EchoStore.LibraryStats()
    @State private var index: [EchoStore.GrammarBucket] = []
    @State private var tags: [EchoStore.GrammarBucket] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statsCard
                practiceCard
                if index.isEmpty {
                    emptyIndex
                } else {
                    grammarCard
                }
                if !tags.isEmpty {
                    tagCard
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .onAppear { reload() }
        .onChange(of: store.sentences.count) { reload() }
    }

    private func reload() {
        stats = store.libraryStats
        index = store.grammarIndex
        tags = store.tagIndex
    }

    // MARK: 累计数据

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Overline("累计")
            Hairline().padding(.top, 6)

            HStack(spacing: 0) {
                cell("\(stats.sentenceCount)", "句子")
                divider
                cell("\(stats.wordCount)", "生词")
                divider
                cell("\(stats.grammarPointCount)", "语法点")
                divider
                cell("\(stats.analysedCount)", "已解读")
            }
            .padding(.top, 12)

            HStack(spacing: 14) {
                if stats.streak > 0 {
                    badge("连续 \(stats.streak) 天", "flame.fill", accent: true)
                }
                badge("\(stats.activeDays) 天学习", "calendar")
                if stats.paragraphCount > 0 {
                    badge("\(stats.paragraphCount) 个段落", "text.justify.left")
                }
                if stats.starredCount > 0 {
                    badge("\(stats.starredCount) 星标", "star.fill")
                }
                Spacer()
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 练习统计（跟读 + 仿写）
    // 数据直接读 store：数组小、发布频率低，够便宜；
    // 刻意不订阅 Speech / RecordingService——它们的 @Published 每 0.05s 一跳

    private var practiceCard: some View {
        let attempts = store.shadowAttempts
        let imitations = store.sentences.filter { $0.source == "仿写练习" }.count
        let hasData = !attempts.isEmpty || imitations > 0

        return VStack(alignment: .leading, spacing: 0) {
            Overline("练习")
            Hairline().padding(.top, 6)

            if hasData {
                HStack(spacing: 0) {
                    cell("\(attempts.count)", "跟读次数")
                    divider
                    cell(attempts.isEmpty ? "–" : "\(attempts.map(\.accuracy).reduce(0, +) / attempts.count)", "平均分")
                    divider
                    cell(attempts.map(\.accuracy).max().map { "\($0)" } ?? "–", "最好分")
                    divider
                    cell("\(Set(attempts.map(\.target)).count)", "练过的句子")
                    divider
                    cell("\(imitations)", "仿写收库")
                }
                .padding(.top, 12)
            } else {
                Text("还没有练习记录——在详情页点「跟读」或「仿写」开始，分数会攒在这里")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 0.5, height: 34)
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 纯文字小标签：连续天数是"进行中的状态"才上青碧，其余安静灰
    private func badge(_ text: String, _ icon: String, accent: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(accent ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.secondary))
    }

    // MARK: 语法点分布

    private var grammarCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Overline("你的句子里有这些语法")
            Hairline().padding(.top, 6)
            Text("按碰到的句子数排序——排前面的就是你实际最常遇到的结构。点进去横向对比同一结构的所有句子。")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 8)
            ForEach(index) { bucket in
                BucketRow(bucket: bucket, maxCount: index.first?.count ?? 1)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 主题标签分布

    private var tagCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Overline("主题标签")
            Hairline().padding(.top, 6)
            ForEach(tags) { bucket in
                BucketRow(bucket: bucket, maxCount: tags.first?.count ?? 1)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyIndex: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("还没有语法索引").font(.headline)
            Text("导入句子后自动建立——AI 解读过的索引更准，没解读的也会用离线探测兜底")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 分布行（占比条 + 点进去看句子）

private struct BucketRow: View {
    let bucket: EchoStore.GrammarBucket
    let maxCount: Int
    @EnvironmentObject var store: EchoStore
    @State private var hovering = false

    var body: some View {
        Button {
            store.openGrammar(bucket.key)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(bucket.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(hovering ? Theme.ice : Color.primary)
                    Spacer()
                    Text("\(bucket.count) 句")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.fill)
                        Rectangle()
                            .fill(Theme.ice.opacity(0.55))
                            .frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private var ratio: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(bucket.count) / CGFloat(maxCount)
    }
}

// MARK: - 某语法点/标签下的所有句子

struct GrammarSentencesPane: View {
    let bucketKey: String
    @EnvironmentObject var store: EchoStore

    // 不观察 Speech：它每读一个词都会 publish，
    // 挂 @ObservedObject 会让整个面板逐词重绘、连带重算索引
    @State private var label = ""
    @State private var items: [EchoSentence] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        store.openOverview()
                    } label: {
                        Label("返回总览", systemImage: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ice)
                    Spacer()
                }

                Text(label.isEmpty ? bucketKey : label)
                    .font(.title2.weight(.semibold))
                Text("你的 \(items.count) 个句子 · 横向对比同一结构，比孤立看一句记得牢")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(items) { s in
                    SentenceMiniRow(sentence: s)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .onAppear { reload() }
        .onChange(of: bucketKey) { reload() }
    }

    /// 索引只在进入/切换时取一次，绝不挂在 body 上
    private func reload() {
        let bucket = store.grammarIndex.first { $0.key == bucketKey }
            ?? store.tagIndex.first { $0.key == bucketKey }
        label = bucket?.label ?? bucketKey
        items = bucket.map { store.sentences(withIDs: $0.sentenceIDs) } ?? []
    }
}

// MARK: - 句子小行（播放 + 循环 + 点进详情）

private struct SentenceMiniRow: View {
    let sentence: EchoSentence
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared
    @State private var hovering = false

    private var isLoopingThis: Bool {
        speech.isLooping && speech.loopText == sentence.text
    }

    var body: some View {
        Button {
            store.selectedID = sentence.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sentence.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(hovering ? Theme.ice : Color.primary)
                        .multilineTextAlignment(.leading)
                    if let a = sentence.analysis, !a.zh.isEmpty {
                        Text(a.zh).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text(sentence.dateAdded.formatted(.dateTime.year().month().day()))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Button {
                    speech.speak(sentence.text, rate: store.speechRate)
                } label: {
                    Image(systemName: "play.circle").foregroundStyle(Theme.ice)
                }
                .buttonStyle(.plain)
                Button {
                    speech.toggleLoop(sentence.text, rate: store.speechRate)
                } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(isLoopingThis ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            // 扁平行 + 底部发丝线，代替灰底圆角块
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
