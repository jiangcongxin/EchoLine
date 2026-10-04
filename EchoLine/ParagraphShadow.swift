import SwiftUI
import AppKit

// MARK: - 整段跟读：录一整段 → 本机比对 + AI 真正去听 → 分项打分和逐句反馈
//
// 本机（苹果离线识别）告诉你"读全了没有、哪些词没被认出来"；
// AI（通义千问 Omni，同一把百炼 Key）直接听录音，给发音 / 流利 / 语调 / 完整四项分，
// 逐句点评，指出具体哪一截读得不对、怎么改。Omni 不可用时退回文字版点评（按识别文本推断）。

struct ParagraphShadowReport: Codable, Equatable {
    struct Problem: Codable, Equatable, Hashable {
        var text: String        // 原文里读得有问题的那一截
        var issue: String       // 问题是什么
        var fix: String         // 怎么改
    }
    struct SentenceNote: Codable, Equatable, Hashable {
        var index: Int
        var score: Int
        var comment: String
    }
    var overall: Int
    var pronunciation: Int?
    var fluency: Int?
    var intonation: Int?
    var completeness: Int?
    var summary: String
    var strengths: [String]
    var problems: [Problem]
    var sentences: [SentenceNote]
    var troubleWords: [String]
    var advice: String
    var source: String          // 例：通义千问 Omni · qwen3.8-omni-flash / 文字点评
    var listened: Bool          // true = AI 真的听了录音
}

// MARK: 报告存档（按跟读记录 id）

@MainActor
final class ParagraphReportStore {
    static let shared = ParagraphReportStore()
    private var reports: [String: ParagraphShadowReport] = [:]

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("shadowReports.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ParagraphShadowReport].self, from: data) {
            reports = decoded
        }
    }

    func report(for id: UUID) -> ParagraphShadowReport? { reports[id.uuidString] }

    func save(_ report: ParagraphShadowReport, for id: UUID) {
        reports[id.uuidString] = report
        if let data = try? JSONEncoder().encode(reports) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: AI

@MainActor
enum ParagraphShadowAI {
    /// 先让 Omni 听录音；不行（没开通 / 超时）再用识别文本做文字点评
    static func assess(text: String, sentences: [String], fileName: String, transcript: String,
                       localAccuracy: Int, duration: Double, config: AIService.Config) async throws -> ParagraphShadowReport {
        var omniError: Error?
        if duration <= 240 {
            do {
                let wav = try WavExport.compactWavData(from: RecordingService.url(for: fileName))
                return try await listen(text: text, sentences: sentences, audio: wav, duration: duration)
            } catch {
                omniError = error
            }
        }
        // 退路：文字版点评（按识别文本推断），分数用本机准确度
        guard !config.apiKey.isEmpty else { throw omniError ?? PronunciationAI.PronError.noKey }
        let review = try await AIService.scoreShadowing(target: text, transcript: transcript, accuracy: localAccuracy,
                                                        duration: duration, isWord: false, config: config)
        var problems: [ParagraphShadowReport.Problem] = []
        if !review.pronunciation.isEmpty {
            problems.append(.init(text: "发音", issue: review.pronunciation, fix: ""))
        }
        if !review.vocabulary.isEmpty {
            problems.append(.init(text: "连读弱读", issue: review.vocabulary, fix: ""))
        }
        return ParagraphShadowReport(
            overall: localAccuracy, pronunciation: nil, fluency: nil, intonation: nil, completeness: localAccuracy,
            summary: [review.fluency, review.grammar].filter { !$0.isEmpty }.joined(separator: " "),
            strengths: [], problems: problems, sentences: [], troubleWords: review.troubleWords,
            advice: review.advice,
            source: "\(review.source) 文字点评" + (omniError.map { "（AI 听音不可用：\($0.localizedDescription)）" } ?? ""),
            listened: false)
    }

    private static func listen(text: String, sentences: [String], audio: Data, duration: Double) async throws -> ParagraphShadowReport {
        let numbered = sentences.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        你是耐心但标准严格的美式英语口语教练，学生是准备雅思口语的中国医生。
        录音是他跟读下面这段英文（录音时长 \(String(format: "%.0f", duration)) 秒）。请真正去听录音，与原文逐句比对。
        原文：
        \(text)
        分句：
        \(numbered)

        打分 0-100：pronunciation 发音准确（音素、重音）；fluency 流利（停顿、语速、有无卡顿重读）；
        intonation 语调与节奏（意群、句重音、升降调）；completeness 完整度（漏读、多读、读错词）；overall 综合。
        只输出一个 JSON 对象，不要 Markdown：
        {"overall":整数,"pronunciation":整数,"fluency":整数,"intonation":整数,"completeness":整数,\
        "summary":"两三句中文总评，先肯定再指出主要问题",\
        "strengths":["读得好的地方，中文短句，1-3 条"],\
        "problems":[{"text":"逐字取自原文的片段","issue":"听到的问题（如 /θ/ 读成 /s/、漏读 -ed、该连读没连、重音放错）","fix":"具体练法"}],\
        "sentences":[{"index":1,"score":整数,"comment":"这一句的一句话点评"}],\
        "troubleWords":["没读准的原文单词，0-8 个"],\
        "advice":"下一遍最该改的一件事，一句话"}
        problems 最多 5 条，按影响大小排序；sentences 每句都要有；全部说明用简体中文。
        没声音或基本没读就给低分并如实说明。
        """
        let (answer, model) = try await PronunciationAI.ask(prompt: prompt, audio: audio)
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PronunciationAI.PronError.failed("结果解析失败") }

        func int(_ any: Any?) -> Int? {
            if let n = any as? Int { return max(0, min(100, n)) }
            if let d = any as? Double { return max(0, min(100, Int(d))) }
            if let s = any as? String, let n = Int(s) { return max(0, min(100, n)) }
            return nil
        }
        func str(_ any: Any?) -> String { (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

        let problems = (obj["problems"] as? [[String: Any]] ?? []).compactMap { p -> ParagraphShadowReport.Problem? in
            let t = str(p["text"]), issue = str(p["issue"])
            guard !t.isEmpty || !issue.isEmpty else { return nil }
            return .init(text: t, issue: issue, fix: str(p["fix"]))
        }
        let notes = (obj["sentences"] as? [[String: Any]] ?? []).compactMap { n -> ParagraphShadowReport.SentenceNote? in
            guard let index = int(n["index"]) else { return nil }
            return .init(index: index, score: int(n["score"]) ?? 0, comment: str(n["comment"]))
        }
        return ParagraphShadowReport(
            overall: int(obj["overall"]) ?? 0,
            pronunciation: int(obj["pronunciation"]), fluency: int(obj["fluency"]),
            intonation: int(obj["intonation"]), completeness: int(obj["completeness"]),
            summary: str(obj["summary"]),
            strengths: (obj["strengths"] as? [String] ?? []).filter { !$0.isEmpty },
            problems: Array(problems.prefix(5)),
            sentences: notes.sorted { $0.index < $1.index },
            troubleWords: (obj["troubleWords"] as? [String] ?? []).filter { !$0.isEmpty },
            advice: str(obj["advice"]),
            source: "通义千问 Omni · \(model)",
            listened: true)
    }

    /// 最终分：AI 听过就以 AI 为主（70%），再掺 30% 本机识别准确度
    static func finalScore(local: Int, report: ParagraphShadowReport?) -> Int {
        guard let report, report.listened else { return local }
        return Int((Double(report.overall) * 0.7 + Double(local) * 0.3).rounded())
    }
}

// MARK: - 反馈视图（弹窗和划词浮窗共用）

struct ParagraphFeedbackView: View {
    let report: ParagraphShadowReport
    let sentences: [String]
    var compact = false
    var onShadowSentence: ((String) -> Void)? = nil

    @EnvironmentObject private var store: EchoStore

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if report.pronunciation != nil || report.fluency != nil || report.intonation != nil {
                HStack(spacing: 12) {
                    subScore("发音", report.pronunciation)
                    subScore("流利", report.fluency)
                    subScore("语调节奏", report.intonation)
                    subScore("完整", report.completeness)
                }
            }
            if !report.summary.isEmpty {
                Text(report.summary)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            if !report.strengths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.strengths, id: \.self) { s in
                        Label(s, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(Theme.right)
                    }
                }
            }
            if !report.problems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Overline("要改的地方")
                    ForEach(report.problems, id: \.self) { p in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                Speech.shared.speak(p.text, rate: store.slowRate)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "speaker.wave.2").font(.caption2)
                                    Text(p.text).font(.system(size: compact ? 12 : 13, design: .serif)).italic()
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(Theme.wrong)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Theme.wrong.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: compact ? 150 : 230, alignment: .leading)
                            .help("听这一截的标准读法")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.issue).font(.caption).foregroundStyle(Theme.ink)
                                if !p.fix.isEmpty {
                                    Text(p.fix).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            if !report.sentences.isEmpty && !compact {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("逐句")
                    ForEach(report.sentences, id: \.self) { note in
                        sentenceRow(note)
                    }
                }
            }
            if !report.advice.isEmpty {
                Label(report.advice, systemImage: "target")
                    .font(compact ? .caption : .callout.weight(.medium))
                    .foregroundStyle(Theme.verb)
            }
            Text(report.listened ? "\(report.source) · 听了你的录音" : report.source)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func subScore(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(Theme.dim)
                Spacer()
                Text(value.map { "\($0)" } ?? "—").font(Theme.mono(11, .bold))
                    .foregroundStyle(value.map { WordScoring.color($0) } ?? Theme.dim)
            }
            ProgressBar(value: Double(value ?? 0) / 100, color: value.map { WordScoring.color($0) } ?? Theme.line)
        }
        .frame(maxWidth: .infinity)
    }

    private func sentenceRow(_ note: ParagraphShadowReport.SentenceNote) -> some View {
        let text = sentences.indices.contains(note.index - 1) ? sentences[note.index - 1] : ""
        return HStack(alignment: .top, spacing: 10) {
            Text("\(note.score)")
                .font(Theme.mono(12, .bold))
                .foregroundStyle(WordScoring.color(note.score))
                .frame(width: 34, height: 22)
                .background(WordScoring.color(note.score).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                if !text.isEmpty {
                    Text(text).font(.system(size: 12, design: .serif)).foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(2)
                }
                Text(note.comment).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !text.isEmpty {
                Button {
                    Speech.shared.speak(text, rate: store.speechRate)
                } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.plain).foregroundStyle(Theme.ice)
                .help("听这句原声")
                if let onShadowSentence {
                    Button {
                        onShadowSentence(text)
                    } label: { Image(systemName: "mic") }
                    .buttonStyle(.plain).foregroundStyle(Theme.ice)
                    .help("单独跟读这一句")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 整段跟读弹窗

struct ParagraphShadowSheet: View {
    let text: String
    let sentences: [String]

    @EnvironmentObject private var store: EchoStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var rec = RecordingService.shared
    @ObservedObject private var speech = Speech.shared

    enum Phase { case idle, recording, recognizing }

    @State private var phase: Phase = .idle
    @State private var recordingFile: String?
    @State private var attempt: ShadowAttempt?
    @State private var localAccuracy: Int?
    @State private var report: ParagraphShadowReport?
    @State private var aiLoading = false
    @State private var aiError: String?
    @State private var errorMessage: String?
    @State private var permissionDenied = false
    @State private var reveal = false
    @State private var sentenceTarget: SentenceShadowTarget?

    struct SentenceShadowTarget: Identifiable {
        let id = UUID()
        let text: String
    }

    private var history: [ShadowAttempt] { store.attempts(for: text) }
    private var wordCount: Int { TextDiff.words(text).count }

    private var badWords: [String] {
        var words = ShadowBadWords.of(attempt)
        for w in report?.troubleWords ?? [] {
            for piece in TextDiff.words(w) where !words.contains(piece) { words.append(piece) }
        }
        return words
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        TapText(text: text, fontSize: 16, badTerms: badWords) { token in
                            if let w = WordSelection.singleWord(from: token) {
                                speech.speak(w, rate: store.speechRate)
                            }
                        }
                        if !badWords.isEmpty {
                            Text("红色＝本机没认出或 AI 听出没读准的词，点一下听发音")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .paperCard()

                    controls

                    if permissionDenied {
                        Label("需要麦克风和语音识别权限：系统设置 → 隐私与安全性", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Theme.verb)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                    }

                    if let localAccuracy, phase == .idle {
                        resultHeader(localAccuracy)
                        if aiLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("AI 正在听你的整段录音，逐句比对（十几秒）…")
                                    .font(.caption).foregroundStyle(Theme.ai)
                            }
                        } else if let report {
                            ParagraphFeedbackView(report: report, sentences: sentences) { s in
                                sentenceTarget = SentenceShadowTarget(text: s)
                            }
                        } else if let aiError {
                            HStack {
                                Text(aiError).font(.caption).foregroundStyle(.secondary)
                                Button("重试 AI 点评") { Task { await runAI() } }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }

                    if history.count > 1 {
                        historyRow
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 820, height: 700)
        .background(Theme.bg)
        .onAppear(perform: loadLatest)
        .onDisappear {
            if rec.isRecording { rec.cancel() }
            rec.stopPlayback()
            speech.stop()
        }
        .sheet(item: $sentenceTarget) { t in
            ShadowingView(target: t.text).environmentObject(store)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(Theme.ice)
            Text("整段跟读").font(.headline).foregroundStyle(Theme.ink)
            Text("\(sentences.count) 句 · \(wordCount) 词").font(Theme.mono(11)).foregroundStyle(Theme.dim)
            if let best = history.map(\.accuracy).max() {
                Chip("最好 \(best)", tint: WordScoring.color(best))
            }
            Spacer()
            SpeedControl()
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: 控制区

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .recording:
            HStack(spacing: 14) {
                LevelWave(level: rec.level, active: true).frame(maxWidth: 260)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.1f 秒", rec.elapsed))
                        .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.ice)
                    Text("读完按 ⏎ 或点「读完了」").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    rec.cancel()
                    phase = .idle
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
                Button {
                    Task { await finish() }
                } label: {
                    Label("读完了", systemImage: "stop.circle.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .danger, small: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        case .recognizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("本机识别你读的内容…").font(.caption).foregroundStyle(.secondary)
            }
        case .idle:
            HStack(spacing: 10) {
                Button {
                    rec.stopPlayback()
                    if speech.isSpeaking { speech.stop() } else { speech.speak(text, rate: store.speechRate) }
                } label: {
                    Label(speech.isSpeaking ? "停止" : "听原声", systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
                Button {
                    rec.stopPlayback()
                    speech.speak(text, rate: store.slowRate)
                } label: {
                    Label("慢速", systemImage: "tortoise")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
                if let file = attempt?.fileName {
                    Button {
                        speech.stop()
                        if rec.isPlayingMine { rec.stopPlayback() } else { rec.playMine(file) }
                    } label: {
                        Label(rec.isPlayingMine ? "停止" : "听自己", systemImage: "person.wave.2.fill")
                    }
                    .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
                }
                Spacer()
                Button {
                    Task { await start() }
                } label: {
                    Label(attempt == nil ? "开始录音" : "再读一遍", systemImage: "mic.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .primary, small: true))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resultHeader(_ local: Int) -> some View {
        let final = ParagraphShadowAI.finalScore(local: local, report: report)
        let minutes = max((attempt?.duration ?? 0) / 60, 0.01)
        let wpm = Int(Double(wordCount) / minutes)
        return HStack(spacing: 18) {
            ScoreRing(score: final, reveal: reveal).frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(report?.listened == true ? "综合得分" : "本机得分")
                    .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Text(WordScoring.verdict(final)).font(.title3.weight(.semibold))
                    .foregroundStyle(WordScoring.color(final))
                HStack(spacing: 10) {
                    Text("本机识别 \(local)").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    if let r = report, r.listened {
                        Text("AI \(r.overall)").font(Theme.mono(11)).foregroundStyle(Theme.ai)
                    }
                    Text(String(format: "%.0f 秒 · %d 词/分", attempt?.duration ?? 0, wpm))
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                        .help("雅思口语自然语速大约 120–160 词/分")
                }
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var historyRow: some View {
        HStack(spacing: 6) {
            Text("历次").font(.caption2).foregroundStyle(.tertiary)
            ForEach(Array(history.prefix(10).reversed())) { a in
                Button {
                    show(a)
                } label: {
                    Text("\(a.accuracy)")
                        .font(Theme.mono(10, .bold))
                        .foregroundStyle(WordScoring.color(a.accuracy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(WordScoring.color(a.accuracy).opacity(a.id == attempt?.id ? 0.3 : 0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(a.date.formatted(.dateTime.month().day().hour().minute()))
            }
        }
    }

    // MARK: 流程

    private func loadLatest() {
        if let latest = history.first { show(latest) }
    }

    private func show(_ a: ShadowAttempt) {
        attempt = a
        report = ParagraphReportStore.shared.report(for: a.id)
        localAccuracy = TextDiff.score(target: text, spoken: a.transcript)
        aiError = nil
        reveal = true
    }

    private func start() async {
        errorMessage = nil
        guard await rec.requestPermissions() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        speech.stop()
        rec.stopPlayback()
        guard let file = rec.start() else {
            errorMessage = "启动录音失败，请重试"
            return
        }
        recordingFile = file
        phase = .recording
    }

    private func finish() async {
        guard phase == .recording else { return }
        let duration = rec.stop()
        phase = .recognizing
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let fileName = recordingFile else {
            errorMessage = "录音文件丢失，请重试"
            phase = .idle
            return
        }
        guard duration >= 1 else {
            rec.deleteFile(fileName)
            errorMessage = "录得太短了——完整读一遍这一段"
            phase = .idle
            return
        }
        let transcript = (try? await rec.transcribe(fileName)) ?? ""
        let local = TextDiff.score(target: text, spoken: transcript)
        let a = ShadowAttempt(target: text, kind: "sentence", fileName: fileName,
                              transcript: transcript, accuracy: local, duration: duration)
        store.addAttempt(a)
        attempt = a
        localAccuracy = local
        report = nil
        aiError = nil
        phase = .idle
        reveal = false
        withAnimation(.easeOut(duration: 0.8)) { reveal = true }
        await runAI()
    }

    private func runAI() async {
        guard var a = attempt, let local = localAccuracy else { return }
        aiLoading = true
        aiError = nil
        do {
            let r = try await ParagraphShadowAI.assess(text: text, sentences: sentences, fileName: a.fileName,
                                                       transcript: a.transcript, localAccuracy: local,
                                                       duration: a.duration, config: store.aiConfig)
            report = r
            ParagraphReportStore.shared.save(r, for: a.id)
            a.accuracy = ParagraphShadowAI.finalScore(local: local, report: r)
            a.review = ShadowReview(pronunciation: r.summary,
                                    fluency: r.fluency.map { "流利 \($0)" } ?? "",
                                    grammar: r.completeness.map { "完整 \($0)" } ?? "",
                                    vocabulary: r.problems.map { "\($0.text)：\($0.issue)" }.joined(separator: "；"),
                                    advice: r.advice, troubleWords: r.troubleWords, source: r.source)
            store.updateAttempt(a)
            attempt = a
            reveal = false
            withAnimation(.easeOut(duration: 0.8)) { reveal = true }
            let final = a.accuracy
            let sound = NSSound(named: final >= 85 ? "Glass" : (final >= 65 ? "Pop" : "Funk"))
            sound?.volume = 0.3
            sound?.play()
        } catch {
            aiError = error.localizedDescription
        }
        aiLoading = false
    }
}

// MARK: - 划词浮窗里的「AI 点评」（录完之后按需请求）

struct InlineAIFeedback: View {
    let attempt: ShadowAttempt
    let sentences: [String]

    @EnvironmentObject private var store: EchoStore
    @State private var report: ParagraphShadowReport?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report {
                ParagraphFeedbackView(report: report, sentences: sentences, compact: true)
            } else if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("AI 在听你的录音…").font(.caption).foregroundStyle(Theme.ai)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await run() }
                    } label: {
                        Label("AI 听一遍并点评", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.ai)
                    if let error {
                        Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .onAppear {
            report = ParagraphReportStore.shared.report(for: attempt.id)
        }
        .onChange(of: attempt.id) {
            report = ParagraphReportStore.shared.report(for: attempt.id)
            error = nil
        }
    }

    private func run() async {
        loading = true
        error = nil
        do {
            let r = try await ParagraphShadowAI.assess(text: attempt.target, sentences: sentences,
                                                       fileName: attempt.fileName, transcript: attempt.transcript,
                                                       localAccuracy: attempt.accuracy, duration: attempt.duration,
                                                       config: store.aiConfig)
            report = r
            ParagraphReportStore.shared.save(r, for: attempt.id)
            var a = attempt
            a.accuracy = ParagraphShadowAI.finalScore(local: attempt.accuracy, report: r)
            a.review = ShadowReview(pronunciation: r.summary, fluency: "", grammar: "",
                                    vocabulary: r.problems.map { "\($0.text)：\($0.issue)" }.joined(separator: "；"),
                                    advice: r.advice, troubleWords: r.troubleWords, source: r.source)
            store.updateAttempt(a)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
