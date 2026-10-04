import Foundation

// MARK: - 句子

struct EchoSentence: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var dateAdded: Date = .now
    var source: String = ""             // 来源（应用名/网页标题/粘贴）
    var starred: Bool = false
    var tags: [String] = []
    var analysis: SentenceAnalysis? = nil
    // 段落模式
    var kind: String = "sentence"       // "sentence" / "paragraph"
    var parentID: UUID? = nil           // 段落子句指向段落
    var paraGist: String = ""           // 段落大意（仅段落）
    var paraLogic: String = ""          // 句间逻辑（仅段落）
    var paraZH: String = ""             // 整段中译（仅段落）

    var isParagraph: Bool { kind == "paragraph" }

    static func == (l: EchoSentence, r: EchoSentence) -> Bool { l.id == r.id }

    init(text: String, source: String = "", kind: String = "sentence", parentID: UUID? = nil) {
        self.text = text
        self.source = source
        self.kind = kind
        self.parentID = parentID
    }

    // 字段兼容解码
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? .now
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        analysis = try c.decodeIfPresent(SentenceAnalysis.self, forKey: .analysis)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "sentence"
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        paraGist = try c.decodeIfPresent(String.self, forKey: .paraGist) ?? ""
        paraLogic = try c.decodeIfPresent(String.self, forKey: .paraLogic) ?? ""
        paraZH = try c.decodeIfPresent(String.self, forKey: .paraZH) ?? ""
    }
}

// MARK: - 生词本

struct CollectedWord: Codable, Identifiable {
    var id = UUID()
    var word: String
    var note: String                // 语境释义（iOS 端叫 contextMeaning，解码时互相兼容）
    var sentence: String            // 出处句
    var dateAdded: Date = .now
    // AI 整理结果（可选字段，旧数据自动兼容）
    var topic: String? = nil        // 主题分组，如 医学、学术
    var priority: String? = nil     // core 高频核心 / useful 常用 / rare 低频
    var group: String? = nil        // 词族/近义组名，如「crease 家族」
    // iOS 端字段（Mac 不使用，为跨端同步无损往返而携带）
    var sentenceZH: String = ""
    var memoryAid: String? = nil
    var intervalDays: Double = 0
    var due: Date = .now
    var reps: Int = 0

    init(word: String, note: String, sentence: String) {
        self.word = word
        self.note = note
        self.sentence = sentence
    }

    // iOS 端把语境释义存在 contextMeaning 字段
    private enum AltKeys: String, CodingKey { case contextMeaning }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        word = try c.decode(String.self, forKey: .word)
        if let n = try c.decodeIfPresent(String.self, forKey: .note) {
            note = n
        } else {
            note = try decoder.container(keyedBy: AltKeys.self)
                .decodeIfPresent(String.self, forKey: .contextMeaning) ?? ""
        }
        sentence = try c.decodeIfPresent(String.self, forKey: .sentence) ?? ""
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? .now
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        priority = try c.decodeIfPresent(String.self, forKey: .priority)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        sentenceZH = try c.decodeIfPresent(String.self, forKey: .sentenceZH) ?? ""
        memoryAid = try c.decodeIfPresent(String.self, forKey: .memoryAid)
        intervalDays = try c.decodeIfPresent(Double.self, forKey: .intervalDays) ?? 0
        due = try c.decodeIfPresent(Date.self, forKey: .due) ?? .now
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
    }
}

/// 生词串文（AI 把生词编成短文复习）
struct WeaveDigest: Codable {
    var en: String
    var zh: String
    var words: [String]
    var date: Date = .now
}

// MARK: - 单词分析

/// 单词的某一种形态（屈折变化或常见变体）。
struct WordForm: Codable, Hashable {
    var label: String
    var form: String

    init(label: String = "", form: String = "") {
        self.label = label
        self.form = form
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        form = try c.decodeIfPresent(String.self, forKey: .form) ?? ""
    }
}

/// 与目标词同根的常见词。
struct WordFamilyEntry: Codable, Hashable {
    var word: String
    var partOfSpeech: String
    var meaning: String

    private enum CodingKeys: String, CodingKey {
        case word
        case partOfSpeech = "pos"
        case meaning
    }

    private enum AlternateCodingKeys: String, CodingKey {
        case partOfSpeech
    }

    init(word: String = "", partOfSpeech: String = "", meaning: String = "") {
        self.word = word
        self.partOfSpeech = partOfSpeech
        self.meaning = meaning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decodeIfPresent(String.self, forKey: .word) ?? ""
        if let pos = try c.decodeIfPresent(String.self, forKey: .partOfSpeech) {
            partOfSpeech = pos
        } else {
            partOfSpeech = try decoder.container(keyedBy: AlternateCodingKeys.self)
                .decodeIfPresent(String.self, forKey: .partOfSpeech) ?? ""
        }
        meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
    }
}

/// 划词后的结构化解读。所有字段都有缺省值，旧缓存或模型偶尔漏字段时仍可解码。
struct WordAnalysis: Codable, Equatable {
    var surface: String
    var headword: String
    var phonetic: String
    var partOfSpeech: String
    var meaning: String
    var contextMeaning: String
    var forms: [WordForm]
    var wordFamily: [WordFamilyEntry]
    var collocations: [String]
    var example: String
    var exampleZH: String
    var usage: String
    var source: String
    /// 这个词在这句话里干什么：句子成分、修饰 / 搭配的对象、起的作用
    var role: String

    init(surface: String = "", headword: String = "", phonetic: String = "",
         partOfSpeech: String = "", meaning: String = "", contextMeaning: String = "",
         forms: [WordForm] = [], wordFamily: [WordFamilyEntry] = [],
         collocations: [String] = [], example: String = "", exampleZH: String = "",
         usage: String = "", source: String = "", role: String = "") {
        self.surface = surface
        self.headword = headword
        self.phonetic = phonetic
        self.partOfSpeech = partOfSpeech
        self.meaning = meaning
        self.contextMeaning = contextMeaning
        self.forms = forms
        self.wordFamily = wordFamily
        self.collocations = collocations
        self.example = example
        self.exampleZH = exampleZH
        self.usage = usage
        self.source = source
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSurface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
        let decodedHeadword = try c.decodeIfPresent(String.self, forKey: .headword) ?? ""
        surface = decodedSurface.isEmpty ? decodedHeadword : decodedSurface
        headword = decodedHeadword.isEmpty ? surface : decodedHeadword
        phonetic = try c.decodeIfPresent(String.self, forKey: .phonetic) ?? ""
        partOfSpeech = try c.decodeIfPresent(String.self, forKey: .partOfSpeech) ?? ""
        let decodedMeaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        let decodedContextMeaning = try c.decodeIfPresent(String.self, forKey: .contextMeaning) ?? ""
        meaning = decodedMeaning.isEmpty ? decodedContextMeaning : decodedMeaning
        contextMeaning = decodedContextMeaning.isEmpty ? meaning : decodedContextMeaning
        forms = try c.decodeIfPresent([WordForm].self, forKey: .forms) ?? []
        wordFamily = try c.decodeIfPresent([WordFamilyEntry].self, forKey: .wordFamily) ?? []
        collocations = try c.decodeIfPresent([String].self, forKey: .collocations) ?? []
        example = try c.decodeIfPresent(String.self, forKey: .example) ?? ""
        exampleZH = try c.decodeIfPresent(String.self, forKey: .exampleZH) ?? ""
        usage = try c.decodeIfPresent(String.self, forKey: .usage) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
}

// MARK: - AI 解读（与 iOS 版格式一致）

struct SentenceAnalysis: Codable {
    var zh: String
    var bandNote: String
    var structure: String
    var highlights: [GlossPair]
    var transfer: String
    var words: [GlossPair]
    var source: String
    var suggestedTags: [String] = []
    // 语法加强
    var tense: TenseInfo? = nil         // 时态专项
    var grammarList: [GlossPair] = []   // 语法点逐条（从句/非谓语/语态…）
    var verbs: [String] = []            // 谓语动词（高亮用）

    init(zh: String, bandNote: String, structure: String, highlights: [GlossPair],
         transfer: String, words: [GlossPair], source: String, suggestedTags: [String] = [],
         tense: TenseInfo? = nil, grammarList: [GlossPair] = [], verbs: [String] = []) {
        self.zh = zh
        self.bandNote = bandNote
        self.structure = structure
        self.highlights = highlights
        self.transfer = transfer
        self.words = words
        self.source = source
        self.suggestedTags = suggestedTags
        self.tense = tense
        self.grammarList = grammarList
        self.verbs = verbs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zh = try c.decodeIfPresent(String.self, forKey: .zh) ?? ""
        bandNote = try c.decodeIfPresent(String.self, forKey: .bandNote) ?? ""
        structure = try c.decodeIfPresent(String.self, forKey: .structure) ?? ""
        highlights = try c.decodeIfPresent([GlossPair].self, forKey: .highlights) ?? []
        transfer = try c.decodeIfPresent(String.self, forKey: .transfer) ?? ""
        words = try c.decodeIfPresent([GlossPair].self, forKey: .words) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        suggestedTags = try c.decodeIfPresent([String].self, forKey: .suggestedTags) ?? []
        tense = try c.decodeIfPresent(TenseInfo.self, forKey: .tense)
        grammarList = try c.decodeIfPresent([GlossPair].self, forKey: .grammarList) ?? []
        verbs = try c.decodeIfPresent([String].self, forKey: .verbs) ?? []
    }
}

/// 时态专项
struct TenseInfo: Codable {
    var name: String        // 如「现在完成时」
    var why: String         // 为什么这句用它
    var timeline: String    // 时间线直觉，如「过去发生 ——▶ 影响延续到现在」
}

struct GlossPair: Codable, Hashable {
    var term: String
    var note: String
}

// MARK: - 语法结构离线探测（没被 AI 解读过的句子也能进索引）

enum GrammarDetector {
    /// 只出中文标签（Mac 版没有内置语法课，不需要 pointID）
    static func detect(_ text: String) -> [String] {
        if let hit = cache[text] { return hit }

        let t = " " + text.lowercased() + " "
        var tags: [String] = []
        func add(_ label: String) {
            if !tags.contains(label) { tags.append(label) }
        }

        if t.contains(" which") || t.contains(" who") || t.contains(" whose") {
            add("定语从句")
        }
        // 注意加前导空格：不然 "meanwhile" 会被当成 while、"behaving" 会被当成 having
        if t.contains(" although ") || t.contains(" though ") || t.contains(" while ")
            || t.contains(" despite ") || t.contains(" in spite of ") || t.contains(" whereas ") {
            add("让步与对比")
        }
        if matches(t, Regexes.passive) { add("被动语态") }
        if t.contains(" if ") || t.contains(" unless ") {
            add("条件句")
        }
        if matches(t, Regexes.perfect) || t.contains(" since ") || t.contains(" over the past ") {
            add("完成时态")
        }
        if matches(t, Regexes.comparison) { add("比较结构") }
        if matches(t, Regexes.participle) || t.contains(" compared with ") || t.contains(" having ") {
            add("分词结构")
        }

        let result = Array(tags.prefix(3))
        cache[text] = result
        return result
    }

    /// 预编译：建索引要跑全库，正则不能每次重新编译
    private enum Regexes {
        static let passive = try? NSRegularExpression(pattern: #"\b(is|are|was|were|been|being|be)\s+\w+(ed|en)\b"#)
        static let perfect = try? NSRegularExpression(pattern: #"\b(has|have|had)\s+\w+(ed|en)\b"#)
        static let comparison = try? NSRegularExpression(pattern: #"(more\s+\w+\s+than|as\s+\w+\s+as|twice as|the most \w+|-er than)"#)
        // 探测时文本首尾补了空格，所以句首形态是 "^ "，光写 ^ 永远匹配不到
        static let participle = try? NSRegularExpression(pattern: #"(^ |, )\w+ing\b"#)
    }

    private static func matches(_ text: String, _ regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static var cache: [String: [String]] = [:]
}

// MARK: - 跟读录音

/// 一次跟读尝试：录音文件 + 识别结果 + 分数 + AI 点评
struct ShadowAttempt: Codable, Identifiable {
    var id = UUID()
    var target: String              // 目标句/词
    var kind: String = "sentence"   // "sentence" / "word"
    var fileName: String            // recordings 目录下的 m4a
    var transcript: String          // 苹果离线识别到的文字
    var accuracy: Int               // 0-100 本地对比准确度
    var duration: Double = 0        // 录音秒数
    var date: Date = .now
    var review: ShadowReview? = nil // AI 逐项点评（可能还没生成）

    var isWord: Bool { kind == "word" }

    init(target: String, kind: String = "sentence", fileName: String,
         transcript: String, accuracy: Int, duration: Double) {
        self.target = target
        self.kind = kind
        self.fileName = fileName
        self.transcript = transcript
        self.accuracy = accuracy
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "sentence"
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        accuracy = try c.decodeIfPresent(Int.self, forKey: .accuracy) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .now
        review = try c.decodeIfPresent(ShadowReview.self, forKey: .review)
    }
}

/// AI 逐项点评（跟读四项 + 建议）
struct ShadowReview: Codable, Hashable {
    var pronunciation: String       // 发音点评
    var fluency: String             // 流利度/节奏点评
    var grammar: String             // 语法（识别文本 vs 原句差异）
    var vocabulary: String          // 词汇/连读吞音
    var advice: String              // 一条最该改的建议
    var troubleWords: [String]      // 没读准的词（界面标红）
    var source: String = ""
}

// MARK: - 仿写批改

/// AI 仿写批改结果：分数 + 修改后句子 + 逐条错误 + 一句话总评
struct WritingCorrection: Codable {
    var score: Int                  // 0-100
    var corrected: String           // 修改后的完整句子
    var errors: [WritingError]      // 0-6 条
    var comment: String             // 一句话中文总评
    var source: String = ""
}

struct WritingError: Codable, Hashable {
    var wrong: String               // 原文片段
    var fix: String                 // 改成
    var type: String                // 错误类型（时态/冠词/主谓一致/单复数/搭配/拼写/句式/其他，中文）
    var note: String                // 一句话中文解释
}

// MARK: - 拆句

enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        var cleaned = text.replacingOccurrences(of: "\n", with: " ")
        for abbr in ["Mr.", "Mrs.", "Dr.", "Ms.", "e.g.", "i.e.", "etc.", "vs.", "St.", "U.S.", "U.K."] {
            cleaned = cleaned.replacingOccurrences(of: abbr, with: abbr.replacingOccurrences(of: ".", with: "\u{2024}"))
        }
        var sentences: [String] = []
        var current = ""
        for ch in cleaned {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { sentences.append(last) }
        return sentences
            .map { $0.replacingOccurrences(of: "\u{2024}", with: ".") }
            .filter { $0.split(separator: " ").count >= 3 }
    }
}
