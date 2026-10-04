import SwiftUI
import AVFoundation
import AppKit

// MARK: - 单词发音：录一遍 → 打分 → 告诉你哪个音不对
//
// 两层评分：
//   本机 —— 苹果离线识别，看"听起来像不像这个词"（有候选和置信度），录完立刻出分；
//   AI   —— 把录音交给通义千问 Omni 真正"听"一遍，按音素、重音给分并指出问题（同一把百炼 Key）。
// 有 AI 结果时最终分 = 70% AI + 30% 本机；没有 Key 或请求失败就只用本机分。

struct WordPronunciationReport: Codable, Equatable {
    struct Issue: Codable, Equatable, Hashable {
        var part: String        // 哪个字母 / 音节 / 音素
        var problem: String     // 读成了什么
        var fix: String         // 怎么改
    }
    var score: Int
    var expected: String        // 标准音标
    var heard: String           // 听起来像什么（音标）
    var stress: String          // 重音判断
    var issues: [Issue]
    var verdict: String
    var tip: String
    var model: String = ""
}

enum WordScoring {
    static func key(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }
    }

    /// 本机分：最佳结果里有这个词 → 75 起，按置信度加；只在候选里 → 60 起；
    /// 都没有 → 按拼写相似度给个低分（识别成了别的词，多半是读偏了）。
    static func localScore(word: String, recognition r: RecordingService.WordRecognition) -> Int {
        let target = key(word)
        guard !target.isEmpty else { return 0 }
        let confidence = r.confidence > 0 ? r.confidence : 0.7
        let bestTokens = r.best.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }
        if bestTokens.contains(target) || key(r.best) == target {
            return min(100, Int(75 + 25 * confidence))
        }
        let altHit = r.alternatives.contains { alt in
            alt.split(whereSeparator: { $0.isWhitespace }).map { key(String($0)) }.contains(target)
                || key(alt) == target
        }
        if altHit { return Int(60 + 12 * confidence) }
        let closest = bestTokens.map { TextDiff.editDistance($0, target) }.min() ?? target.count
        let similarity = max(0, 1 - Double(closest) / Double(max(target.count, 1)))
        return Int(similarity * 58)
    }

    static func combined(local: Int, ai: Int?) -> Int {
        guard let ai else { return local }
        return Int((Double(ai) * 0.7 + Double(local) * 0.3).rounded())
    }

    static func color(_ score: Int) -> Color {
        if score >= 85 { return Theme.right }
        if score >= 65 { return Theme.verb }
        return Theme.wrong
    }

    static func verdict(_ score: Int) -> String {
        switch score {
        case 92...: return "很地道"
        case 80..<92: return "读得不错"
        case 65..<80: return "能听懂，有瑕疵"
        case 45..<65: return "有明显的音不对"
        default: return "再听几遍原声"
        }
    }
}

// MARK: - 录音转 WAV（Omni 不收 m4a 容器）

enum WavExport {
    static func wavData(from url: URL) throws -> Data {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("echoline-word-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings,
                                      commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let chunk: AVAudioFrameCount = 8192
            while source.framePosition < source.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                try source.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
            }
        }   // out 出作用域才会把文件头写完整
        return try Data(contentsOf: tmp)
    }

    /// 长录音（整段跟读）降到 16kHz 单声道：一分钟约 1.9MB，远低于接口 10MB 的 Base64 上限。
    static func compactWavData(from url: URL, sampleRate: Double = 16_000) throws -> Data {
        let source = try AVAudioFile(forReading: url)
        let inFormat = source.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            return try wavData(from: url)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("echoline-para-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let out = try AVAudioFile(forWriting: tmp, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            let inChunk: AVAudioFrameCount = 8192
            let outChunk = AVAudioFrameCount(Double(inChunk) * sampleRate / inFormat.sampleRate) + 256
            var finished = false
            while !finished {
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunk) else { break }
                var conversionError: NSError?
                let status = converter.convert(to: outBuffer, error: &conversionError) { _, inputStatus in
                    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inChunk),
                          (try? source.read(into: inBuffer, frameCount: inChunk)) != nil,
                          inBuffer.frameLength > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return inBuffer
                }
                if let conversionError { throw conversionError }
                if outBuffer.frameLength > 0 { try out.write(from: outBuffer) }
                if status == .endOfStream || status == .error { finished = true }
            }
        }
        return try Data(contentsOf: tmp)
    }
}

// MARK: - 通义千问 Omni 听音打分

enum PronunciationAI {
    enum PronError: LocalizedError {
        case noKey
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "没有百炼 Key，只给了本机分（设置里填 Key 后可让 AI 逐音点评）"
            case .failed(let m): return "AI 听音失败：\(m)"
            }
        }
    }

    /// 百炼的全模态模型会换代；按顺序试，试通的那个记下来，下次直接用。
    private static let candidates = ["qwen3.8-omni-flash", "qwen3.5-omni-flash", "qwen3-omni-flash", "qwen-omni-turbo"]
    private static let cacheKey = "pronunciationOmniModel"

    static func assess(word: String, phonetic: String?, audio: Data) async throws -> WordPronunciationReport {
        let reference = (phonetic?.isEmpty == false) ? "（参考音标 \(phonetic!)）" : ""
        let prompt = """
        你是严格但友善的美式英语发音考官。录音里是一位中国学习者在读单词 "\(word)"\(reference)。
        请真正去听录音，按美式标准音逐个音素比对，给出 0-100 分：
        90+ 地道；75-89 清楚但有小瑕疵；60-74 能听懂但有明显错音；40-59 多处错音或重音错；<40 基本不像这个词、没声音或读成了别的词。
        只输出一个 JSON 对象，不要 Markdown：
        {"score":整数,"expected":"标准美式音标，如 /ˈmɛdɪsən/","heard":"你实际听到的音标","stress":"重音位置是否正确，中文一句",\
        "issues":[{"part":"出问题的字母、音节或音素","problem":"读成了什么（中文）","fix":"具体怎么改：舌位、口型、长短（中文）"}],\
        "verdict":"一句中文总评","tip":"最该练的一点，一句中文"}
        issues 最多 3 条，读得好就给空数组。
        """
        let (text, model) = try await ask(prompt: prompt, audio: audio)
        var report = try parse(text)
        report.model = model
        return report
    }

    /// 通用：把一段录音 + 指令交给 Omni，返回它的文字回答和实际用的模型。
    static func ask(prompt: String, audio: Data) async throws -> (text: String, model: String) {
        let key = CloudTTS.qwenKey()
        guard !key.isEmpty else { throw PronError.noKey }
        var order = candidates
        if let cached = UserDefaults.standard.string(forKey: cacheKey), let i = order.firstIndex(of: cached) {
            order.remove(at: i)
            order.insert(cached, at: 0)
        }
        var lastError: Error = PronError.failed("没有可用的模型")
        for model in order {
            do {
                let text = try await stream(model: model, key: key, prompt: prompt, audio: audio)
                UserDefaults.standard.set(model, forKey: cacheKey)
                return (text, model)
            } catch let error as PronError {
                lastError = error
                // 只有"模型不存在 / 没开通"才换下一个；Key 错、网络错直接报
                if case .failed(let message) = error, isModelProblem(message) { continue }
                throw error
            }
        }
        throw lastError
    }

    private static func isModelProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("model") && (m.contains("not") || m.contains("exist") || m.contains("support")
                                       || m.contains("access") || m.contains("invalid"))
    }

    private static func stream(model: String, key: String, prompt: String, audio: Data) async throws -> String {
        guard let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            throw PronError.failed("地址错误")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "input_audio",
                     "input_audio": ["data": "data:;base64," + audio.base64EncodedString(), "format": "wav"]],
                    ["type": "text", "text": prompt],
                ],
            ]],
            "stream": true,
            "modalities": ["text"],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        var text = ""
        var raw = ""
        for try await line in bytes.lines {
            guard status == 200 else {
                raw += line
                if raw.count > 600 { break }
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw PronError.failed((err["message"] as? String) ?? "未知错误")
            }
            if let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let piece = delta["content"] as? String {
                text += piece
            }
        }
        guard status == 200 else { throw PronError.failed(String(raw.prefix(300))) }
        guard !text.isEmpty else { throw PronError.failed("没有返回内容") }
        return text
    }

    private static func parse(_ text: String) throws -> WordPronunciationReport {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PronError.failed("结果解析失败") }
        func str(_ k: String) -> String {
            (obj[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let score: Int = {
            if let n = obj["score"] as? Int { return n }
            if let d = obj["score"] as? Double { return Int(d) }
            if let s = obj["score"] as? String, let n = Int(s) { return n }
            return 0
        }()
        let issues = (obj["issues"] as? [[String: Any]] ?? []).compactMap { item -> WordPronunciationReport.Issue? in
            let part = (item["part"] as? String) ?? ""
            let problem = (item["problem"] as? String) ?? ""
            guard !part.isEmpty || !problem.isEmpty else { return nil }
            return .init(part: part, problem: problem, fix: (item["fix"] as? String) ?? "")
        }
        return WordPronunciationReport(score: max(0, min(100, score)), expected: str("expected"), heard: str("heard"),
                                       stress: str("stress"), issues: Array(issues.prefix(3)),
                                       verdict: str("verdict"), tip: str("tip"))
    }
}

// MARK: - 面板：听 → 录 → 分数 → 问题 → 对比

struct WordPronunciationPanel: View {
    let word: String
    var phonetic: String? = nil
    var compact = false

    @EnvironmentObject private var store: EchoStore
    @ObservedObject private var rec = RecordingService.shared
    private let speech = Speech.shared

    enum Phase { case idle, recording, recognizing }

    @State private var phase: Phase = .idle
    @State private var recordingFile: String?
    @State private var attempt: ShadowAttempt?
    @State private var localScore: Int?
    @State private var heardLocal = ""
    @State private var report: WordPronunciationReport?
    @State private var aiLoading = false
    @State private var aiNote: String?
    @State private var errorMessage: String?
    @State private var permissionDenied = false
    @State private var autoStop: DispatchWorkItem?
    @State private var reveal = false

    /// 同一个词在不同句子里点开，历史记在一起
    private var target: String { word.lowercased() }
    private var history: [ShadowAttempt] { store.attempts(for: target) }
    private var finalScore: Int? {
        guard let localScore else { return nil }
        return WordScoring.combined(local: localScore, ai: report?.score)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch phase {
            case .recording:
                recordingView
            case .recognizing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在听你读的…").font(.caption).foregroundStyle(.secondary)
                }
            case .idle:
                if permissionDenied {
                    permissionRow
                } else if let finalScore {
                    resultView(finalScore)
                } else if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                } else {
                    Text("先听标准音，再点「录音」读一遍；录完自动打分，AI 会逐个音告诉你哪里不对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.ice.opacity(0.22), lineWidth: 1))
        .onDisappear {
            autoStop?.cancel()
            if rec.isRecording { rec.cancel() }
            rec.stopPlayback()
        }
    }

    // MARK: 顶部：标准音 + 录音 + 历史

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.ice)
            Text("发音评分").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            if let best = history.map(\.accuracy).max() {
                Text("练过 \(history.count) 次 · 最好 \(best)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                rec.stopPlayback()
                speech.speak(word, rate: store.slowRate)
            } label: {
                Image(systemName: "tortoise")
            }
            .help("慢速听标准音")
            Button {
                rec.stopPlayback()
                speech.speak(word, rate: store.speechRate)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .help("听标准音")
            Button {
                if phase == .recording {
                    Task { await finish() }
                } else {
                    Task { await start() }
                }
            } label: {
                Label(phase == .recording ? "读完了" : (localScore == nil ? "录音" : "再录"),
                      systemImage: phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
            }
            .tint(phase == .recording ? .red : Theme.ice)
            .disabled(phase == .recognizing)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var recordingView: some View {
        HStack(spacing: 12) {
            LevelWave(level: rec.level, active: true)
                .frame(maxWidth: 220)
            Text(String(format: "%.1f 秒", rec.elapsed))
                .font(.callout.monospacedDigit()).foregroundStyle(Theme.ice)
            Spacer()
            Button("取消") {
                autoStop?.cancel()
                rec.cancel()
                phase = .idle
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("需要麦克风和语音识别权限", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.verb)
            HStack(spacing: 10) {
                Button("去设置：麦克风") { openPrivacy("Privacy_Microphone") }
                Button("去设置：语音识别") { openPrivacy("Privacy_SpeechRecognition") }
            }
            .font(.caption).buttonStyle(.bordered)
        }
    }

    // MARK: 结果

    private func resultView(_ score: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                ScoreRing(score: score, reveal: reveal)
                    .frame(width: compact ? 58 : 68, height: compact ? 58 : 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report?.verdict.isEmpty == false ? report!.verdict : WordScoring.verdict(score))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(WordScoring.color(score))
                    HStack(spacing: 8) {
                        if let localScore { Text("本机 \(localScore)").font(Theme.mono(10)).foregroundStyle(Theme.dim) }
                        if let ai = report?.score { Text("AI \(ai)").font(Theme.mono(10)).foregroundStyle(Theme.ai) }
                        if aiLoading {
                            ProgressView().controlSize(.mini)
                            Text("AI 在听…").font(.caption2).foregroundStyle(Theme.ai)
                        }
                    }
                    Text(heardLocal.isEmpty ? "本机没听清" : "本机听成：\(heardLocal)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Button {
                        guard let file = attempt?.fileName else { return }
                        if rec.isPlayingMine { rec.stopPlayback() } else { speech.stop(); rec.playMine(file) }
                    } label: {
                        Label(rec.isPlayingMine ? "停止" : "听自己", systemImage: "person.wave.2.fill")
                    }
                    Button {
                        compare()
                    } label: {
                        Label("原声→我", systemImage: "arrow.left.arrow.right")
                    }
                    .help("先放标准音，紧接着放你的录音，对比着听")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let r = report {
                if !r.expected.isEmpty || !r.heard.isEmpty {
                    HStack(spacing: 14) {
                        if !r.expected.isEmpty {
                            labeled("标准", r.expected, color: Theme.right)
                        }
                        if !r.heard.isEmpty {
                            labeled("你读的", r.heard, color: r.score >= 85 ? Theme.right : Theme.verb)
                        }
                    }
                }
                if !r.stress.isEmpty {
                    Label(r.stress, systemImage: "waveform.path")
                        .font(.caption).foregroundStyle(Theme.ink.opacity(0.85))
                }
                ForEach(r.issues, id: \.self) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Text(issue.part)
                            .font(Theme.mono(12, .bold))
                            .foregroundStyle(Theme.wrong)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.wrong.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.problem).font(.caption).foregroundStyle(Theme.ink)
                            if !issue.fix.isEmpty {
                                Text(issue.fix).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !r.tip.isEmpty {
                    Label(r.tip, systemImage: "lightbulb")
                        .font(.caption).foregroundStyle(Theme.verb)
                }
            } else if let aiNote {
                Text(aiNote).font(.caption2).foregroundStyle(.tertiary)
            }

            if history.count > 1 {
                HStack(spacing: 5) {
                    Text("最近").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(history.prefix(8).reversed())) { a in
                        Text("\(a.accuracy)")
                            .font(Theme.mono(10, .bold))
                            .foregroundStyle(WordScoring.color(a.accuracy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(WordScoring.color(a.accuracy).opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    private func labeled(_ title: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.system(.callout, design: .monospaced)).foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    // MARK: 流程

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
        // 单词很短：4 秒自动停，省得每次都要去点「读完了」
        let work = DispatchWorkItem { Task { @MainActor in
            if phase == .recording { await finish() }
        } }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func finish() async {
        autoStop?.cancel()
        guard phase == .recording else { return }
        let duration = rec.stop()
        phase = .recognizing
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard let fileName = recordingFile else {
            errorMessage = "录音文件丢失，请重试"
            phase = .idle
            return
        }
        guard duration >= 0.3 else {
            rec.deleteFile(fileName)
            errorMessage = "录得太短了——点录音后完整读一遍"
            phase = .idle
            return
        }

        // 1. 本机识别，立刻出分
        let recognition = try? await rec.transcribeWord(fileName)
        let local = recognition.map { WordScoring.localScore(word: word, recognition: $0) } ?? 0
        heardLocal = recognition?.best ?? ""
        localScore = local
        report = nil
        aiNote = nil
        reveal = false
        var a = ShadowAttempt(target: target, kind: "word", fileName: fileName,
                              transcript: heardLocal, accuracy: local, duration: duration)
        store.addAttempt(a)
        attempt = a
        phase = .idle
        withAnimation(.easeOut(duration: 0.8)) { reveal = true }
        playFeedbackSound(local)

        // 2. AI 真正听一遍，逐音点评
        aiLoading = true
        do {
            let wav = try WavExport.wavData(from: RecordingService.url(for: fileName))
            let r = try await PronunciationAI.assess(word: word, phonetic: phonetic, audio: wav)
            report = r
            let final = WordScoring.combined(local: local, ai: r.score)
            a.accuracy = final
            a.review = ShadowReview(
                pronunciation: ([r.verdict] + r.issues.map { "\($0.part)：\($0.problem)" }).joined(separator: "；"),
                fluency: r.heard.isEmpty ? "" : "听到 \(r.heard)",
                grammar: r.expected.isEmpty ? "" : "标准 \(r.expected)",
                vocabulary: r.stress,
                advice: r.tip,
                troubleWords: r.issues.map(\.part),
                source: "通义千问 Omni · \(r.model)")
            store.updateAttempt(a)
            attempt = a
            reveal = false
            withAnimation(.easeOut(duration: 0.8)) { reveal = true }
        } catch {
            aiNote = error.localizedDescription
        }
        aiLoading = false
    }

    private func compare() {
        guard let file = attempt?.fileName else { return }
        rec.stopPlayback()
        speech.speak(word, rate: store.speechRate)
        // 单词一般一秒内读完；等标准音放完再放自己的
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            speech.stop()
            rec.playMine(file)
        }
    }

    private func playFeedbackSound(_ score: Int) {
        let sound = NSSound(named: score >= 85 ? "Glass" : (score >= 65 ? "Pop" : "Funk"))
        sound?.volume = 0.3
        sound?.play()
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 分数圆环：出分时从 0 转到目标值
struct ScoreRing: View {
    let score: Int
    let reveal: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 6)
            Circle()
                .trim(from: 0, to: reveal ? CGFloat(score) / 100 : 0)
                .stroke(WordScoring.color(score), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: WordScoring.color(score).opacity(0.5), radius: 6)
            Text("\(score)")
                .font(Theme.mono(22, .heavy))
                .foregroundStyle(WordScoring.color(score))
                .contentTransition(.numericText())
        }
    }
}

// MARK: - 生词本：逐个练发音

struct WordDrillSheet: View {
    let words: [CollectedWord]
    @EnvironmentObject private var store: EchoStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var current: CollectedWord? { words.indices.contains(index) ? words[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.badge.mic").foregroundStyle(Theme.ice)
                Text("逐个练发音").font(.headline).foregroundStyle(Theme.ink)
                Text("\(min(index + 1, words.count)) / \(words.count)")
                    .font(Theme.mono(12)).foregroundStyle(Theme.dim)
                Spacer()
                SpeedControl()
                Button("结束") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ProgressBar(value: words.isEmpty ? 0 : Double(index) / Double(words.count))
            if let w = current {
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.word).font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    Text(w.note).font(.callout).foregroundStyle(.secondary)
                    if !w.sentence.isEmpty {
                        Text(w.sentence).font(.system(.footnote, design: .serif)).italic()
                            .foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                WordPronunciationPanel(word: w.word)
                    .id(w.id)
                Spacer(minLength: 0)
                HStack {
                    Button("上一个") { index = max(0, index - 1) }
                        .disabled(index == 0)
                    Spacer()
                    Button(index + 1 < words.count ? "下一个 →" : "完成") {
                        if index + 1 < words.count { index += 1 } else { dismiss() }
                    }
                    .buttonStyle(WorkbenchButtonStyle(kind: .primary, small: true))
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            } else {
                Text("生词本里还没有词。").foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
        .background(Theme.bg)
        .onAppear { Speech.shared.speak(current?.word ?? "", rate: store.speechRate) }
        .onChange(of: index) { Speech.shared.speak(current?.word ?? "", rate: store.speechRate) }
    }
}
