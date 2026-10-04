import SwiftUI
import AppKit

// MARK: - 划段预览：先看、先听、先读，再决定收不收

/// 划到一句或一段英文之后先看到的东西——它还不在句库里。
/// 以前是划完立刻入库，结果句库里堆满了随手划到的东西；现在收不收由你点。
struct CaptureDraft: Identifiable, Equatable {
    let id = UUID()
    /// 已经按 importText 的规则归一化（单句就是那一句，多句用空格连成一段），
    /// 这样跟读记录的 target 和收录后的句子文本完全一致，收录后历史直接接上。
    let text: String
    let source: String
    let sentences: [String]

    static func == (l: CaptureDraft, r: CaptureDraft) -> Bool { l.text == r.text }

    /// 划到的原文 → 预览草稿；切不出一个像样的句子就返回 nil，由调用方提示。
    static func make(from raw: String, source: String) -> CaptureDraft? {
        let parts = SentenceSplitter.split(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parts.isEmpty else { return nil }
        let text = parts.count == 1 ? parts[0] : parts.joined(separator: " ")
        return CaptureDraft(text: text, source: source, sentences: parts)
    }
}

struct CaptureDraftView: View {
    let draft: CaptureDraft

    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared
    @ObservedObject private var panelCtrl = QuickPanel.shared

    // 中译预览
    @State private var zh: [String] = []
    @State private var translating = false
    @State private var translateError: String?
    @State private var zhRevealed = false

    // 点词
    @State private var wordLookup: WordLookupRequest?

    // 跟读（录音本体在 InlineShadowRecorder 里；这里只要知道"在录"和"读错了哪些词"）
    @State private var recording = false
    @State private var lastAttempt: ShadowAttempt?

    private var isParagraph: Bool { draft.sentences.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TapText(text: draft.text, fontSize: 16,
                            badTerms: ShadowBadWords.of(lastAttempt)) { token in
                        tapWord(token)
                    }
                    translationBlock
                    controls

                    if let lookup = wordLookup {
                        WordAnalysisCard(request: lookup, compact: true)
                            .id(lookup.id)
                    }

                    InlineShadowRecorder(target: draft.text, isRecording: $recording, sentences: draft.sentences) { attempt in
                        lastAttempt = attempt
                    }

                    if !draft.source.isEmpty {
                        Text("来自 \(draft.source) · \(isParagraph ? "\(draft.sentences.count) 句" : "1 句")")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Hairline()
            footer
        }
        .padding(14)
        .frame(width: 480, height: 470, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 0.5))
        .onExitCommand { dismissDraft() }
        .task(id: draft.id) { await loadTranslation() }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack {
            Label("EchoLine", systemImage: "quote.opening")
                .font(.caption.weight(.medium)).foregroundStyle(Theme.ice)
            Text("还没收录")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.fill, in: Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                panelCtrl.isPinned.toggle()
            } label: {
                Image(systemName: panelCtrl.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(panelCtrl.isPinned ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.tertiary))
                    .rotationEffect(.degrees(45))
            }
            .buttonStyle(.plain)
            .help(panelCtrl.isPinned ? "取消固定（点空白处将自动关闭）" : "固定浮窗（不固定时点空白处自动关闭）")
            Button {
                dismissDraft()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("不收录，关闭（Esc）")
        }
    }

    // MARK: 中译（默认模糊，悬停/点击显示——和主窗口一个习惯）

    @ViewBuilder
    private var translationBlock: some View {
        if !zh.isEmpty {
            let joined = zh.joined(separator: isParagraph ? "\n" : "")
            let visible = store.zhAlwaysVisible || zhRevealed
            Text(joined)
                .font(.callout).lineSpacing(4)
                .foregroundStyle(.secondary)
                .blur(radius: visible ? 0 : 4)
                .animation(.easeOut(duration: 0.15), value: visible)
                .onHover { zhRevealed = $0 }
                .onTapGesture { zhRevealed.toggle() }
                .accessibilityLabel(joined)
        } else if translating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("中译…").font(.caption).foregroundStyle(.tertiary)
            }
        } else if let translateError {
            Text(translateError).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: 朗读

    private var controls: some View {
        let playingThis = speech.isSpeaking && speech.spokenText == draft.text
        return HStack(spacing: 12) {
            Button {
                if playingThis {
                    speech.stop()
                } else {
                    RecordingService.shared.stopPlayback()
                    speech.speak(draft.text, rate: store.speechRate)
                }
            } label: {
                Label(playingThis ? "停止" : (isParagraph ? "朗读整段" : "朗读"),
                      systemImage: playingThis ? "stop.circle.fill" : "play.circle.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button {
                RecordingService.shared.stopPlayback()
                speech.speak(draft.text, rate: store.slowRate)
            } label: {
                Label("慢速", systemImage: "tortoise")
            }
            Button {
                speech.toggleLoop(draft.text, rate: store.speechRate)
            } label: {
                Label("循环", systemImage: "repeat")
            }
            .foregroundStyle(speech.isLooping && speech.loopText == draft.text ? Theme.ice : Color.secondary)
            Spacer()
            SpeedControl(compact: true)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Theme.ice)
        .disabled(recording)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack {
            Button("不收录") { dismissDraft() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            Text("Esc").font(.caption2).foregroundStyle(.quaternary)
            Spacer()
            Button {
                collect()
            } label: {
                HStack(spacing: 6) {
                    Text(isParagraph ? "收录这段" : "收录这句")
                    Text("⏎").font(.caption2).opacity(0.7)
                }
                .padding(.horizontal, 4)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(Theme.ice)
            .disabled(recording)
            .help("存进句库并开始 AI 解读（⏎）")
        }
        .padding(.top, 2)
    }

    // MARK: 动作

    private func tapWord(_ token: String) {
        guard let clean = WordSelection.singleWord(from: token) else { return }
        RecordingService.shared.stopPlayback()
        Speech.shared.speak(clean, rate: store.speechRate)
        wordLookup = WordLookupRequest(word: clean, context: draft.text, fallbackMeaning: nil)
    }

    /// 帮你决定"值不值得收"的那一眼中译。同一段文字再划一次不重复请求。
    private func loadTranslation() async {
        if let cached = QuickPanel.shared.draftTranslations[draft.text] {
            zh = cached
            return
        }
        guard !store.aiKey.isEmpty else {
            translateError = "填入百炼 Key 后这里会显示中译（⌘, 打开设置）"
            return
        }
        translating = true
        do {
            let result = try await AIService.quickTranslate(draft.sentences, config: store.aiConfig)
            zh = result
            QuickPanel.shared.draftTranslations[draft.text] = result
        } catch {
            translateError = "中译暂时没拿到：\(error.localizedDescription)"
        }
        translating = false
    }

    private func collect() {
        guard !recording else { return }
        speech.stop()
        RecordingService.shared.stopPlayback()
        QuickPanel.shared.collect(draft, store: store)
    }

    private func dismissDraft() {
        QuickPanel.shared.close()
    }
}

// MARK: - 内嵌跟读：录一遍 → 离线识别 → 分数 + 听原声 / 听自己

/// 录完之后识别不出的词，交给正文的 TapText 标红——不用另开一张卡。
enum ShadowBadWords {
    static func of(_ attempt: ShadowAttempt?) -> [String] {
        guard let attempt else { return [] }
        var seen = Set<String>()
        return TextDiff.matchedWords(target: attempt.target, spoken: attempt.transcript)
            .filter { !$0.matched && seen.insert($0.word).inserted }
            .map { $0.word }
    }
}

/// 浮窗里用的紧凑版跟读（主窗口的 ShadowingView 是完整版，带 AI 点评和历史）。
/// 只做三件事：录、比、回放。录完的记录照常写进 shadowAttempts，主窗口里能看到。
struct InlineShadowRecorder: View {
    let target: String
    @Binding var isRecording: Bool
    /// 分句（整段划进来时用于 AI 逐句点评）；空就当一句
    var sentences: [String] = []
    var onAttempt: (ShadowAttempt?) -> Void = { _ in }

    @EnvironmentObject var store: EchoStore
    @ObservedObject private var rec = RecordingService.shared
    /// 只在按钮里用；Speech 逐词 publish，订阅它会让浮窗按音节重绘。
    private let speech = Speech.shared

    @State private var phase: Phase = .idle
    @State private var recordingFile: String?
    @State private var attempt: ShadowAttempt?
    @State private var errorMessage: String?
    @State private var permissionDenied = false

    enum Phase { case idle, recording, processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .idle:
                idleRow
                if permissionDenied {
                    permissionRow
                } else if let attempt {
                    resultCard(attempt)
                } else if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.wrong)
                }
            case .recording:
                recordingCard
            case .processing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("识别你刚才读的内容…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: phase) {
            isRecording = phase == .recording
        }
        .onDisappear {
            if rec.isRecording { rec.cancel() }
            rec.stopPlayback()
        }
    }

    private var idleRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await startRecording() }
            } label: {
                Label(attempt == nil ? "录一遍，对比自己的发音" : "再录一遍", systemImage: "mic.circle.fill")
            }
            .keyboardShortcut("r", modifiers: [])
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.ice)
            .help("跟着读一遍，录下来和原声对比（R）")
            Spacer()
            let history = store.attempts(for: target)
            if attempt == nil, let best = store.bestAccuracy(for: target) {
                Text("练过 \(history.count) 次 · 最好 \(best) 分")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var recordingCard: some View {
        VStack(spacing: 8) {
            LevelWave(level: rec.level, active: true)
            Text(String(format: "%.1f 秒", rec.elapsed))
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(Theme.ice)
            HStack(spacing: 10) {
                Button("取消") {
                    rec.cancel()
                    recordingFile = nil
                    phase = .idle
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await finishRecording() }
                } label: {
                    Label("读完了", systemImage: "stop.circle.fill")
                }
                .keyboardShortcut("r", modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .paperCard()
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("需要麦克风和语音识别权限", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(Theme.verb)
            HStack(spacing: 10) {
                Button("去设置：麦克风") { openPrivacyPane("Privacy_Microphone") }
                Button("去设置：语音识别") { openPrivacyPane("Privacy_SpeechRecognition") }
            }
            .font(.caption).buttonStyle(.bordered)
        }
    }

    /// 录完一遍后紧凑的一行：分数 + 一句话判断 + 听原声 / 听自己；错词已经在正文里标红。
    private func resultCard(_ a: ShadowAttempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(a.accuracy)")
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(scoreColor(a.accuracy))
                Text(verdict(a.accuracy))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(scoreColor(a.accuracy))
                Text(String(format: "%.1f 秒", a.duration))
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    rec.stopPlayback()
                    speech.speak(target, rate: store.speechRate)
                } label: {
                    Label("听原声", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .tint(Theme.ice)
                Button {
                    if rec.isPlayingMine {
                        rec.stopPlayback()
                    } else {
                        speech.stop()
                        rec.playMine(a.fileName)
                    }
                } label: {
                    Label(rec.isPlayingMine ? "停止" : "听自己", systemImage: "person.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .tint(rec.isPlayingMine ? Color.red : Color.secondary)
            }
            .font(.caption)
            .controlSize(.small)

            Text(a.transcript.isEmpty ? "（没听清）" : "识别到：\(a.transcript)")
                .font(.caption2).italic().foregroundStyle(.tertiary)
                .lineLimit(2)
            if !ShadowBadWords.of(a).isEmpty {
                Text("正文里红色的词识别不出来，多半没读准——点它听单词发音")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            InlineAIFeedback(attempt: a, sentences: sentences.isEmpty ? [target] : sentences)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func scoreColor(_ score: Int) -> Color {
        if score >= 90 { return Theme.ice }
        if score >= 70 { return Theme.verb }
        return Theme.wrong
    }

    private func verdict(_ score: Int) -> String {
        switch score {
        case 95...: return "几乎完美"
        case 85..<95: return "读得不错"
        case 70..<85: return "基本听得出"
        case 50..<70: return "有几个词没读准"
        default: return "多听几遍原声再试"
        }
    }

    // MARK: 录音流程（和 ShadowingView 同一套，去掉了 AI 点评）

    private func startRecording() async {
        errorMessage = nil
        guard await rec.requestPermissions() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        speech.stop()
        guard let file = rec.start() else {
            errorMessage = "启动录音失败，请重试"
            return
        }
        recordingFile = file
        phase = .recording
    }

    private func finishRecording() async {
        let duration = rec.stop()
        phase = .processing
        errorMessage = nil
        // 刚 stop 的文件需要一点点时间落盘
        try? await Task.sleep(nanoseconds: 250_000_000)

        guard let fileName = recordingFile else {
            errorMessage = "录音文件丢失，请重试"
            phase = .idle
            return
        }
        guard duration >= 0.4 else {
            rec.deleteFile(fileName)
            errorMessage = "录得太短了——听完原声后完整读一遍"
            phase = .idle
            return
        }
        do {
            let transcript = try await rec.transcribe(fileName)
            let accuracy = TextDiff.score(target: target, spoken: transcript)
            let a = ShadowAttempt(target: target, kind: "sentence", fileName: fileName,
                                  transcript: transcript, accuracy: accuracy, duration: duration)
            // 先存：就算最后没收录这段，跟读记录也留着——练过就是练过。
            store.addAttempt(a)
            attempt = a
            onAttempt(a)
        } catch {
            rec.deleteFile(fileName)
            errorMessage = error.localizedDescription
        }
        phase = .idle
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
