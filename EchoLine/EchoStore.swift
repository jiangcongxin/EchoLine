import Foundation
import SwiftUI
import CryptoKit

/// 全局状态：句库、词释义缓存、设置
@MainActor
final class EchoStore: ObservableObject {

    static let shared = EchoStore()

    @Published var sentences: [EchoSentence] = []
    @Published var glossCache: [String: String] = [:]       // "word|sentence前缀" -> 释义
    @Published var collectedWords: [CollectedWord] = []     // 生词本
    private var wordAnalysisCache: [String: WordAnalysis] = [:]
    @Published var selectedID: UUID?
    @Published var wordbookOpen = false                     // 右栏显示生词本
    @Published var overviewOpen = false                     // 右栏显示总览
    @Published var selectedGrammarKey: String?              // 右栏显示某语法点的所有句子
    @Published var todayOpen = true                         // 右栏显示「今日」（启动默认）
    @Published var practiceOpen = false                     // 右栏显示「跟读」总表
    @Published var resourcesOpen = false                    // 右栏显示「资源」网站
    @Published var typingOpen = false                       // 右栏显示「临摹」
    @Published var typingRequest: TypingRequest?            // 正在临摹的那一条（弹窗）

    /// 右栏同一时刻只显示一个面板：先全部关掉再打开要的那个
    private func closePanes() {
        selectedID = nil
        wordbookOpen = false
        overviewOpen = false
        selectedGrammarKey = nil
        todayOpen = false
        practiceOpen = false
        resourcesOpen = false
        typingOpen = false
    }

    func openOverview() { closePanes(); overviewOpen = true }
    func openGrammar(_ key: String) { closePanes(); selectedGrammarKey = key }
    func openToday() { closePanes(); todayOpen = true }
    func openPractice() { closePanes(); practiceOpen = true }
    func openWordbook() { closePanes(); wordbookOpen = true }
    func openResources() { closePanes(); resourcesOpen = true }
    func openTyping() { closePanes(); typingOpen = true }

    /// 打开临摹弹窗（段落 / 句子详情、临摹页、右键菜单都走这里）
    func startTyping(_ s: EchoSentence, mode: TypingMode = .copy) {
        Speech.shared.stop()
        typingRequest = TypingRequest(sentenceID: s.id, mode: mode)
    }

    @AppStorage("selectionIconEnabled") var selectionIconEnabled: Bool = true
    /// 发音通道：qwen（与解读共用百炼 Key）/ siliconflow / system
    @AppStorage("ttsProvider") var ttsProvider: String = "qwen"
    /// 只有 SiliconFlow 才用得到的独立 Key；qwen 复用 aiKey
    @AppStorage("ttsKey") var ttsKey: String = ""
    @AppStorage("ttsModel") var ttsModel: String = "qwen3-tts-flash"
    @AppStorage("ttsVoice") var ttsVoice: String = "Jennifer"

    // 设置
    @AppStorage("aiProvider") var aiProvider: String = "qwen"
    @AppStorage("aiKey") var aiKey: String = ""
    @AppStorage("aiModel") var aiModel: String = "qwen-flash"
    @AppStorage("aiBaseURL") var aiBaseURL: String = ""
    @AppStorage("aiThinkingEnabled") var aiThinkingEnabled: Bool = false
    @AppStorage("speechRate") var speechRate: Double = 0.5

    // MARK: 语速（界面上统一用倍速表示：speechRate 0.5 = 1.0×）

    static let speedPresets: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    var speedMultiplier: Double { speechRate / 0.5 }

    var speedLabel: String { Self.speedLabel(speedMultiplier) }

    static func speedLabel(_ m: Double) -> String {
        let tenths = (m * 10).rounded()
        return (abs(m * 10 - tenths) < 0.01 ? String(format: "%.1f", m) : String(format: "%.2f", m)) + "×"
    }

    /// 慢速按钮：当前语速的 70%，跟着总语速一起走
    var slowRate: Double { max(0.25, speechRate * 0.7) }

    func setSpeed(_ multiplier: Double) {
        speechRate = min(0.75, max(0.25, multiplier * 0.5))
        Speech.shared.applyLiveRate(speechRate)
    }

    /// 在预设档之间挪一格（⌘[ 慢一点 / ⌘] 快一点）
    func stepSpeed(_ direction: Int) {
        let presets = Self.speedPresets
        let current = speedMultiplier
        let next: Double?
        if direction > 0 {
            next = presets.first { $0 > current + 0.001 }
        } else {
            next = presets.last { $0 < current - 0.001 }
        }
        if let next { setSpeed(next) }
    }
    @AppStorage("zhAlwaysVisible") var zhAlwaysVisible: Bool = false

    var aiConfig: AIService.Config {
        AIService.Config(
            provider: aiProvider,
            apiKey: aiKey,
            model: aiModel,
            customBaseURL: aiBaseURL,
            thinkingEnabled: aiThinkingEnabled
        )
    }

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    init() {
        sentences = load("sentences.json") ?? []
        glossCache = load("glossCache.json") ?? [:]
        collectedWords = load("collectedWords.json") ?? []
        shadowAttempts = load("shadowAttempts.json") ?? []
        wordAnalysisCache = load("wordAnalysisCache.json") ?? [:]
        migrateToQwenIfNeeded()
    }

    /// 全面转到通义千问（2026-09）：一把百炼 Key 同时管解读和发音。
    /// 老用户的 DeepSeek / Kimi 配置是明确选过的，不动；只把从没改过服务商、
    /// 或者 Key 本来就是百炼的用户切过去。只跑一次。
    private func migrateToQwenIfNeeded() {
        let d = UserDefaults.standard
        let flag = "didMigrateToQwenV1"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)

        // 解读：@AppStorage 的默认值不落盘，object(forKey:) == nil 就是"从没改过"。
        // 这类用户过去看到的是 deepseek，现在默认变成 qwen；模型名也得跟着换，
        // 否则会拿着 deepseek-chat 去问百炼。
        if d.object(forKey: "aiProvider") == nil {
            // 旧版默认是 DeepSeek 且默认值不落盘：这里的 aiKey 只可能是 DeepSeek 的。
            // 备份起来（设置里「换用 DeepSeek」时可以找回），腾出位置给百炼 Key。
            let legacy = aiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty {
                d.set(legacy, forKey: "legacyDeepSeekKey")
                aiKey = ""
            }
            aiProvider = "qwen"
            aiModel = "qwen-flash"
        } else if aiProvider == "qwen", aiModel.isEmpty || aiModel.hasPrefix("deepseek") || aiModel.hasPrefix("kimi") {
            aiModel = "qwen-flash"
        }

        // 发音：以前只有 SiliconFlow 一条云端通道。填过 SiliconFlow Key 的用户保留它，
        // 其余人默认走 qwen（Key 复用解读那把，不用再填）。
        if d.object(forKey: "ttsProvider") == nil {
            // 这个版本之前 ttsKey 只可能是 SiliconFlow 的：备份后清空，发音统一走 qwen。
            let legacy = ttsKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty {
                d.set(legacy, forKey: "legacySiliconFlowKey")
                ttsKey = ""
            }
            ttsProvider = "qwen"
            ttsModel = "qwen3-tts-flash"
            ttsVoice = "Jennifer"
        }
    }

    /// 侧栏显示的条目（段落的子句不单独出现）
    var topLevelSentences: [EchoSentence] {
        sentences.filter { $0.parentID == nil }
    }

    func children(of paragraph: EchoSentence) -> [EchoSentence] {
        sentences.filter { $0.parentID == paragraph.id }
    }

    // MARK: - 句库操作

    /// 导入文本：单句直接入库；多句作为「段落」整体入库 + 生成子句。返回新增数量
    @discardableResult
    func importText(_ text: String, source: String = "粘贴") -> Int {
        let parts = SentenceSplitter.split(text)
        guard !parts.isEmpty else { return 0 }
        let existing = Set(sentences.map(\.text))

        if parts.count == 1 {
            let p = parts[0]
            guard !existing.contains(p) else {
                if let hit = sentences.first(where: { $0.text == p }) { selectedID = hit.id }
                return 0
            }
            sentences.insert(EchoSentence(text: p, source: source), at: 0)
            persist()
            selectedID = sentences.first?.id
            wordbookOpen = false
            return 1
        }

        // 段落模式
        let joined = parts.joined(separator: " ")
        guard !existing.contains(joined) else {
            if let hit = sentences.first(where: { $0.text == joined }) { selectedID = hit.id }
            return 0
        }
        let para = EchoSentence(text: joined, source: source, kind: "paragraph")
        sentences.insert(para, at: 0)
        for p in parts {
            sentences.append(EchoSentence(text: p, source: source, kind: "sentence", parentID: para.id))
        }
        persist()
        selectedID = para.id
        wordbookOpen = false
        return parts.count
    }

    /// 静默插入一句（仿写练习手动收库用）：只插数据——
    /// 不改选中句、不打标、不触发任何后续自动操作；完全相同的句子已在库中则不重复收
    func insertQuietly(_ text: String, source: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sentences.contains(where: { $0.text == t }) else { return }
        sentences.insert(EchoSentence(text: t, source: source), at: 0)
        persist()
    }

    func update(_ s: EchoSentence) {
        if let i = sentences.firstIndex(where: { $0.id == s.id }) {
            sentences[i] = s
            persist()
        }
    }

    func delete(_ s: EchoSentence) {
        let ids = [s.id] + sentences.filter { $0.parentID == s.id }.map(\.id)
        sentences.removeAll { $0.id == s.id || $0.parentID == s.id }
        if selectedID == s.id { selectedID = topLevelSentences.first?.id }
        persist()
        SyncEngine.shared.recordDeletion(.sentences, ids: ids)
    }

    // MARK: - 生词本

    func collectWord(word: String, note: String, sentence: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !collectedWords.contains(where: { $0.word.lowercased() == w.lowercased() }) else { return }
        collectedWords.insert(CollectedWord(word: w, note: note, sentence: sentence), at: 0)
        save(collectedWords, "collectedWords.json")
    }

    func deleteCollected(_ c: CollectedWord) {
        collectedWords.removeAll { $0.id == c.id }
        save(collectedWords, "collectedWords.json")
        SyncEngine.shared.recordDeletion(.words, ids: [c.id])
    }

    func knownWord(_ term: String) -> Bool {
        collectedWords.contains { $0.word.lowercased() == term.lowercased() }
    }

    // MARK: - 生词本 AI 整理

    @Published var digest: WeaveDigest? = nil

    func loadDigest() {
        if digest == nil { digest = load("digest.json") }
    }

    func saveDigest(_ d: WeaveDigest) {
        digest = d
        save(d, "digest.json")
    }

    /// 应用 AI 整理结果（按词名匹配写回分组/分级/词族）
    func applyOrganisation(_ items: [AIService.OrgItem]) {
        for item in items {
            if let i = collectedWords.firstIndex(where: { $0.word.lowercased() == item.word.lowercased() }) {
                collectedWords[i].topic = item.topic
                collectedWords[i].priority = item.priority
                collectedWords[i].group = item.group.isEmpty ? nil : item.group
            }
        }
        save(collectedWords, "collectedWords.json")
    }

    func deleteCollected(word: String) {
        let ids = collectedWords.filter { $0.word.lowercased() == word.lowercased() }.map(\.id)
        collectedWords.removeAll { $0.word.lowercased() == word.lowercased() }
        save(collectedWords, "collectedWords.json")
        SyncEngine.shared.recordDeletion(.words, ids: ids)
    }

    func toggleStar(_ s: EchoSentence) {
        var copy = s
        copy.starred.toggle()
        update(copy)
    }

    var allTags: [String] {
        Array(Set(sentences.flatMap(\.tags))).sorted()
    }

    // MARK: - 今日重现（每天固定抽 3-5 条 3 天前的旧句）

    var dailyReview: [EchoSentence] {
        let old = topLevelSentences.filter { $0.dateAdded < Calendar.current.date(byAdding: .day, value: -2, to: .now)! }
        guard !old.isEmpty else { return [] }
        // 用日期做种子，保证同一天内固定
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        var rng = SeededGenerator(seed: UInt64(day))
        return Array(old.shuffled(using: &rng).prefix(min(5, max(3, old.count / 10 + 3))))
    }

    // MARK: - 语法索引（AI 解读的语法点 + 离线正则探测，两套合并）

    struct GrammarBucket: Identifiable {
        var id: String { key }
        let key: String
        let label: String
        var sentenceIDs: [UUID]
        var count: Int { sentenceIDs.count }
    }

    /// 单句的合并标签：AI 解读过就以 AI 的时态 + grammarList 为准，
    /// 没解读的用离线正则兜底，保证任何句子都进得了索引
    func grammarLabels(of s: EchoSentence) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        if let a = s.analysis {
            if let t = a.tense, !t.name.isEmpty, seen.insert(normalise(t.name)).inserted {
                result.append(t.name)
            }
            for g in a.grammarList where !g.term.isEmpty {
                guard seen.insert(normalise(g.term)).inserted else { continue }
                result.append(g.term)
            }
        }
        for label in GrammarDetector.detect(s.text) {
            guard seen.insert(normalise(label)).inserted else { continue }
            result.append(label)
        }
        return result
    }

    /// 归一化：「定语从句（which）」与「定语从句」视为同一个；截空则退回原标签
    private func normalise(_ label: String) -> String {
        var s = label
        for ch in ["（", "(", "·", "：", ":"] {
            if let r = s.range(of: ch) { s = String(s[s.startIndex..<r.lowerBound]) }
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? label.trimmingCharacters(in: .whitespaces) : trimmed
    }

    // 缓存：建索引要跑全库正则，不能每次 body 求值都重算
    private var grammarIndexCache: [GrammarBucket]?
    private var tagIndexCache: [GrammarBucket]?
    private var statsCache: LibraryStats?

    private func invalidateIndex() {
        grammarIndexCache = nil
        tagIndexCache = nil
        statsCache = nil
    }

    /// 全库语法点分布，按句子数降序
    var grammarIndex: [GrammarBucket] {
        if let c = grammarIndexCache { return c }
        let built = buildGrammarIndex()
        grammarIndexCache = built
        return built
    }

    private func buildGrammarIndex() -> [GrammarBucket] {
        var map: [String: GrammarBucket] = [:]
        for s in sentences where !s.isParagraph {
            for label in grammarLabels(of: s) {
                let key = normalise(label)
                guard !key.isEmpty else { continue }
                if var b = map[key] {
                    if !b.sentenceIDs.contains(s.id) { b.sentenceIDs.append(s.id) }
                    map[key] = b
                } else {
                    map[key] = GrammarBucket(key: key, label: key, sentenceIDs: [s.id])
                }
            }
        }
        return map.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label
        }
    }

    func sentences(withIDs ids: [UUID]) -> [EchoSentence] {
        let set = Set(ids)
        return sentences.filter { set.contains($0.id) }
    }

    /// 主题标签分布（EchoLine 特有：用户标签 + AI 建议标签）
    var tagIndex: [GrammarBucket] {
        if let c = tagIndexCache { return c }
        let built = buildTagIndex()
        tagIndexCache = built
        return built
    }

    private func buildTagIndex() -> [GrammarBucket] {
        var map: [String: GrammarBucket] = [:]
        for s in sentences where !s.isParagraph {
            for tag in s.tags where !tag.isEmpty {
                if var b = map[tag] {
                    if !b.sentenceIDs.contains(s.id) { b.sentenceIDs.append(s.id) }
                    map[tag] = b
                } else {
                    map[tag] = GrammarBucket(key: tag, label: tag, sentenceIDs: [s.id])
                }
            }
        }
        return map.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label
        }
    }

    // MARK: - 搜索（原句 / 中译 / AI 解读 / 标签与来源）

    enum SearchField: String {
        case english = "原句"
        case chinese = "中译"
        case analysis = "解读"
        case tag = "标签"
    }

    struct SearchHit: Identifiable {
        var id: UUID { sentence.id }
        let sentence: EchoSentence
        let fields: [SearchField]
        let snippet: String
    }

    func search(_ query: String) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for s in sentences {
            var fields: [SearchField] = []
            var snippet = ""

            if s.text.lowercased().contains(q) { fields.append(.english) }

            let zh = s.isParagraph ? s.paraZH : (s.analysis?.zh ?? "")
            if zh.lowercased().contains(q) {
                fields.append(.chinese)
                if snippet.isEmpty { snippet = zh }
            }
            if let a = s.analysis {
                let pool: [String] = [a.bandNote, a.structure, a.transfer]
                    + a.highlights.flatMap { [$0.term, $0.note] }
                    + a.grammarList.flatMap { [$0.term, $0.note] }
                    + a.words.flatMap { [$0.term, $0.note] }
                    + [a.tense?.name ?? "", a.tense?.why ?? ""]
                if let found = pool.first(where: { $0.lowercased().contains(q) }) {
                    fields.append(.analysis)
                    if snippet.isEmpty { snippet = found }
                }
            }
            if s.isParagraph, !fields.contains(.analysis) {
                if let found = [s.paraGist, s.paraLogic].first(where: { $0.lowercased().contains(q) }) {
                    fields.append(.analysis)
                    if snippet.isEmpty { snippet = found }
                }
            }
            // 标签 / 来源
            if let found = (s.tags + [s.source]).first(where: { !$0.isEmpty && $0.lowercased().contains(q) }) {
                fields.append(.tag)
                if snippet.isEmpty { snippet = found }
            }
            // 语法标签要跑正则，放最后且前面没命中才算
            if fields.isEmpty,
               let found = grammarLabels(of: s).first(where: { $0.lowercased().contains(q) }) {
                fields.append(.tag)
                if snippet.isEmpty { snippet = found }
            }

            if !fields.isEmpty {
                hits.append(SearchHit(sentence: s, fields: fields, snippet: snippet))
            }
        }

        // 段落父条目的 text 是全文，必然连子句一起命中；子句更精确，父段落就不单列了
        let hitParentIDs = Set(hits.compactMap { $0.sentence.parentID })
        hits.removeAll { $0.sentence.isParagraph && hitParentIDs.contains($0.sentence.id) }

        return hits.sorted {
            let a = $0.fields.contains(.english), b = $1.fields.contains(.english)
            if a != b { return a }
            return $0.sentence.dateAdded > $1.sentence.dateAdded
        }
    }

    // MARK: - 累计数据

    struct LibraryStats {
        var sentenceCount = 0
        var paragraphCount = 0
        var wordCount = 0
        var analysedCount = 0
        var starredCount = 0
        var grammarPointCount = 0
        var tagCount = 0
        var activeDays = 0
        var streak = 0
    }

    var libraryStats: LibraryStats {
        if let c = statsCache { return c }
        let built = buildStats()
        statsCache = built
        return built
    }

    private func buildStats() -> LibraryStats {
        var s = LibraryStats()
        s.sentenceCount = sentences.filter { !$0.isParagraph }.count
        s.paragraphCount = sentences.filter(\.isParagraph).count
        s.wordCount = collectedWords.count
        s.analysedCount = sentences.filter { $0.analysis != nil }.count
        s.starredCount = sentences.filter(\.starred).count
        s.grammarPointCount = grammarIndex.count
        s.tagCount = allTags.count

        var days = Set(sentences.map { dayKey($0.dateAdded) })
        days.formUnion(collectedWords.map { dayKey($0.dateAdded) })
        s.activeDays = days.count

        var streak = 0
        var cursor = Date()
        if !days.contains(dayKey(cursor)) {
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while days.contains(dayKey(cursor)) {
            streak += 1
            cursor = Calendar.current.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        s.streak = streak
        return s
    }

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func dayKey(_ date: Date = .now) -> String { Self.dayKeyFormatter.string(from: date) }

    // MARK: - 跟读记录

    @Published var shadowAttempts: [ShadowAttempt] = []

    /// 某句/词的跟读历史，新的在前
    func attempts(for target: String) -> [ShadowAttempt] {
        shadowAttempts.filter { $0.target == target }
    }

    func addAttempt(_ a: ShadowAttempt) {
        shadowAttempts.insert(a, at: 0)
        save(shadowAttempts, "shadowAttempts.json")
    }

    func updateAttempt(_ a: ShadowAttempt) {
        if let i = shadowAttempts.firstIndex(where: { $0.id == a.id }) {
            shadowAttempts[i] = a
            save(shadowAttempts, "shadowAttempts.json")
        }
    }

    func deleteAttempt(_ a: ShadowAttempt) {
        shadowAttempts.removeAll { $0.id == a.id }
        RecordingService.shared.deleteFile(a.fileName)
        save(shadowAttempts, "shadowAttempts.json")
        SyncEngine.shared.recordDeletion(.attempts, ids: [a.id])
    }

    func bestAccuracy(for target: String) -> Int? {
        attempts(for: target).map(\.accuracy).max()
    }

    // MARK: - 词释义缓存

    func cachedGloss(word: String, sentence: String) -> String? {
        glossCache[glossKey(word, sentence)]
    }

    func cacheGloss(word: String, sentence: String, note: String) {
        glossCache[glossKey(word, sentence)] = note
        persistGloss()
    }

    private func glossKey(_ w: String, _ s: String) -> String {
        w.lowercased() + "|" + String(s.prefix(40))
    }

    // MARK: - 单词结构化分析缓存

    func cachedWordAnalysis(word: String, context: String) -> WordAnalysis? {
        wordAnalysisCache[wordAnalysisKey(word, context)]
    }

    func cacheWordAnalysis(_ analysis: WordAnalysis, word: String, context: String) {
        wordAnalysisCache[wordAnalysisKey(word, context)] = analysis
        save(wordAnalysisCache, "wordAnalysisCache.json")
    }

    /// Swift 的 `hashValue` 每次启动都可能不同；这里用规范化后的完整上下文做稳定 SHA-256。
    /// 长度前缀让 word/context 的边界无歧义，且绝不再截取句子前 40 个字符。
    private func wordAnalysisKey(_ word: String, _ context: String) -> String {
        let normalisedWord = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let normalisedContext = context
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let wordData = Data(normalisedWord.utf8)
        let contextData = Data(normalisedContext.utf8)
        var payload = Data("word-analysis-v2\n\(wordData.count)\n".utf8)
        payload.append(wordData)
        payload.append(Data("\n\(contextData.count)\n".utf8))
        payload.append(contextData)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 持久化

    func persist() { save(sentences, "sentences.json") }
    private func persistGloss() { save(glossCache, "glossCache.json") }

    private func load<T: Decodable>(_ file: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 索引依赖 sentences / collectedWords，其他数据（词释义缓存、单词分析缓存、串文）落盘不必失效——
    /// 否则每点一个词就把全库索引冲掉，下次渲染又要重跑正则
    private static let indexAffectingFiles: Set<String> = ["sentences.json", "collectedWords.json"]

    private func save<T: Encodable>(_ value: T, _ file: String) {
        if Self.indexAffectingFiles.contains(file) { invalidateIndex() }
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: dir.appendingPathComponent(file), options: .atomic)
        }
        // 参与同步的数据落盘后通知同步引擎（防抖推送）
        if !isApplyingSync, Self.syncedFiles.contains(file) {
            SyncEngine.shared.noteLocalChange()
        }
    }

    // MARK: - iCloud 同步

    /// 参与与 iPhone 端 IELTSMate 同步的本地文件（云端 attempts.json 即本地 shadowAttempts.json）
    private static let syncedFiles: Set<String> = ["sentences.json", "collectedWords.json", "shadowAttempts.json", "digest.json"]
    private var isApplyingSync = false

    /// 同步引擎回写合并结果：更新界面 + 本地落盘，但不再触发推送
    func applySync(sentences s: [EchoSentence], words w: [CollectedWord],
                   attempts a: [ShadowAttempt], digest d: WeaveDigest?) {
        isApplyingSync = true
        defer { isApplyingSync = false }
        sentences = s
        save(s, "sentences.json")
        collectedWords = w
        save(w, "collectedWords.json")
        shadowAttempts = a
        save(a, "shadowAttempts.json")
        digest = d
        save(d, "digest.json")
    }
}

/// 可播种随机数（今日重现每天固定）
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
