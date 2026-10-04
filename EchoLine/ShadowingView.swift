import SwiftUI
import AppKit

/// 跟读面板（macOS 版）：听原声 → 录自己 → 离线识别 → 本地准确度 + AI 逐项点评 → AB 对比 → 本句历史
struct ShadowingView: View {
    let target: String
    var isWord: Bool = false

    @EnvironmentObject var store: EchoStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var speech = Speech.shared
    @ObservedObject private var rec = RecordingService.shared

    @State private var phase: Phase = .idle
    @State private var attempt: ShadowAttempt?
    @State private var errorMessage: String?
    @State private var reviewing = false
    @State private var permissionDenied = false
    @State private var recordingFile: String?

    enum Phase { case idle, recording, processing, done }

    private var history: [ShadowAttempt] {
        store.attempts(for: target).filter { $0.id != attempt?.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（macOS 没有 NavigationStack，自绘）
            HStack {
                Label(isWord ? "跟读这个词" : "跟读这句", systemImage: "mic")
                    .font(.headline)
                Spacer()
                SpeedControl()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Esc 关闭
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetCard
                    if permissionDenied {
                        permissionCard
                    } else {
                        recordCard
                    }
                    if let a = attempt, phase == .done {
                        ShadowResultCard(attempt: a, isWord: isWord)
                        abCompareCard(a)
                        reviewCard(a)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !history.isEmpty && phase != .recording {
                        historyCard
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .task { refreshPermission() }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .active { refreshPermission() }   // 从系统设置授权回来立刻生效
        }
        .onDisappear {
            if rec.isRecording { rec.cancel() }
            speech.stop()
            rec.stopPlayback()
        }
    }

    // MARK: 目标 + 听原声

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target)
                .font(.system(isWord ? .title2 : .title3, design: .serif))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                Button {
                    speech.speak(target, rate: store.speechRate)
                } label: {
                    Label("听原声", systemImage: "play.circle.fill")
                }
                .foregroundStyle(Theme.ice)
                .disabled(phase == .recording)
                Button {
                    speech.speak(target, rate: store.slowRate)
                } label: {
                    Label("慢速", systemImage: "tortoise")
                }
                .foregroundStyle(.secondary)
                .disabled(phase == .recording)
                Spacer()
                if let best = store.bestAccuracy(for: target) {
                    Text("最好 \(best) 分")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 录音区

    private var recordCard: some View {
        VStack(spacing: 14) {
            switch phase {
            case .idle, .done:
                LevelWave(level: 0, active: false)
                Button {
                    Task { await startRecording() }
                } label: {
                    Label(phase == .done ? "再录一次" : "点一下开始录",
                          systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Theme.ice)
                Text("先听一遍原声，再点录音，跟着读一遍")
                    .font(.caption2).foregroundStyle(.tertiary)

            case .recording:
                LevelWave(level: rec.level, active: true)
                Text(String(format: "%.1f 秒", rec.elapsed))
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.ice)
                HStack(spacing: 12) {
                    Button {
                        rec.cancel()
                        recordingFile = nil
                        phase = .idle
                    } label: {
                        Text("取消").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await finishRecording() }
                    } label: {
                        Label("读完了", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

            case .processing:
                ProgressView()
                Text("识别你刚才读的内容…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .paperCard()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要麦克风和语音识别权限", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(Theme.verb)
            Text("打开 系统设置 → 隐私与安全性 → 麦克风 / 语音识别，把 EchoLine 打开，再回来录音。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("去设置：麦克风") {
                    openPrivacyPane("Privacy_Microphone")
                }
                Button("去设置：语音识别") {
                    openPrivacyPane("Privacy_SpeechRecognition")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: AB 对比

    private func abCompareCard(_ a: ShadowAttempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AB 对比", systemImage: "waveform")
                .font(.footnote).foregroundStyle(Theme.ice)
            HStack(spacing: 12) {
                Button {
                    rec.stopPlayback()
                    speech.speak(target, rate: store.speechRate)
                } label: {
                    Label("听原声", systemImage: "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(Theme.ice)
                Button {
                    if rec.isPlayingMine {
                        rec.stopPlayback()
                    } else {
                        rec.playMine(a.fileName)
                    }
                } label: {
                    Label(rec.isPlayingMine ? "停止" : "听自己", systemImage: "person.wave.2.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(rec.isPlayingMine ? Color.red : Color.secondary)
            }
            Text("来回切着听，差别最明显的地方就是最该练的地方")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: AI 点评

    @ViewBuilder
    private func reviewCard(_ a: ShadowAttempt) -> some View {
        if let r = a.review {
            ShadowReviewCard(review: r)
        } else if reviewing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("\(store.aiConfig.providerName) 逐项点评中…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
            Button {
                Task { await requestReview(a) }
            } label: {
                Label("让 AI 逐项点评", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.ice)
        }
    }

    // MARK: 本句历史

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这\(isWord ? "个词" : "句")练过 \(store.attempts(for: target).count) 次",
                  systemImage: "chart.line.uptrend.xyaxis")
                .font(.footnote).foregroundStyle(Theme.ice)
            ForEach(history.prefix(6)) { h in
                ShadowHistoryRow(attempt: h)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 逻辑

    private func refreshPermission() {
        permissionDenied = RecordingService.micState == .denied || RecordingService.speechState == .denied
    }

    private func startRecording() async {
        errorMessage = nil
        guard await rec.requestPermissions() else {
            permissionDenied = true
            return
        }
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
            let a = ShadowAttempt(target: target, kind: isWord ? "word" : "sentence",
                                  fileName: fileName, transcript: transcript,
                                  accuracy: accuracy, duration: duration)
            store.addAttempt(a)
            attempt = a
            phase = .done
            // 自动点评（配了 Key 才走；没配就只有本地分数）
            if !store.aiKey.isEmpty {
                await requestReview(a)
            }
        } catch {
            rec.deleteFile(fileName)
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    private func requestReview(_ a: ShadowAttempt) async {
        guard !store.aiKey.isEmpty else {
            errorMessage = "先在 设置（⌘,）填入 API Key，才能逐项点评"
            return
        }
        reviewing = true
        do {
            let r = try await AIService.scoreShadowing(target: a.target, transcript: a.transcript,
                                                       accuracy: a.accuracy, duration: a.duration,
                                                       isWord: isWord, config: store.aiConfig)
            var updated = a
            updated.review = r
            store.updateAttempt(updated)
            attempt = updated
        } catch {
            errorMessage = error.localizedDescription
        }
        reviewing = false
    }
}

// MARK: - 结果卡：分数 + 错词标红

struct ShadowResultCard: View {
    let attempt: ShadowAttempt
    var isWord: Bool = false

    @EnvironmentObject var store: EchoStore

    private var scoreColor: Color {
        if attempt.accuracy >= 90 { return Theme.ice }
        if attempt.accuracy >= 70 { return Theme.verb }
        return Theme.wrong
    }

    private var verdict: String {
        switch attempt.accuracy {
        case 95...: return "几乎完美"
        case 85..<95: return "读得不错"
        case 70..<85: return "基本听得出"
        case 50..<70: return "有几个词没读准"
        default: return "多听几遍原声再试"
        }
    }

    /// 识别对不上的目标词（已按 TextDiff 归一化，交给 TapText 标红）
    private var badWords: [String] {
        var seen = Set<String>()
        return TextDiff.matchedWords(target: attempt.target, spoken: attempt.transcript)
            .filter { !$0.matched && seen.insert($0.word).inserted }
            .map(\.word)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(attempt.accuracy)")
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundStyle(scoreColor)
                Text("/ 100").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verdict).font(.subheadline.weight(.medium)).foregroundStyle(scoreColor)
                    Text(String(format: "%.1f 秒", attempt.duration))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if !isWord {
                Text("原句（红色＝识别不出，多半没读准；点词可听发音）")
                    .font(.caption2).foregroundStyle(.tertiary)
                TapText(text: attempt.target, fontSize: 15, badTerms: badWords) { token in
                    Speech.shared.speak(token, rate: store.speechRate)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("识别到你读的是").font(.caption2).foregroundStyle(.tertiary)
                Text(attempt.transcript.isEmpty ? "（没听清）" : attempt.transcript)
                    .font(.footnote).italic().foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}

// MARK: - AI 点评卡

struct ShadowReviewCard: View {
    let review: ShadowReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("逐项点评", systemImage: "sparkles")
                .font(.footnote).foregroundStyle(Theme.ice)

            if !review.troubleWords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("没读准的词").font(.caption2).foregroundStyle(.tertiary)
                    WrapLayout(spacing: 6) {
                        ForEach(review.troubleWords, id: \.self) { w in
                            Text(w)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.wrong.opacity(0.1), in: Capsule())
                                .foregroundStyle(Theme.wrong)
                        }
                    }
                }
            }

            row("发音", "waveform", review.pronunciation)
            row("流利度", "metronome", review.fluency)
            row("完整度", "text.badge.checkmark", review.grammar)
            row("口语细节", "link", review.vocabulary)

            if !review.advice.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("下次这样练", systemImage: "target")
                        .font(.caption.weight(.medium)).foregroundStyle(Theme.ice)
                    Text(review.advice).font(.callout).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.ice.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if !review.source.isEmpty {
                Text("\(review.source) 点评").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String, _ content: String) -> some View {
        if !content.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(content).font(.footnote).lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 历史行

private struct ShadowHistoryRow: View {
    let attempt: ShadowAttempt
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var rec = RecordingService.shared

    private var color: Color {
        if attempt.accuracy >= 90 { return Theme.ice }
        if attempt.accuracy >= 70 { return Theme.verb }
        return Theme.wrong
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(attempt.accuracy)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 34, height: 24)
                .background(color.opacity(0.12), in: Capsule())
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(attempt.date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
                if let r = attempt.review, !r.advice.isEmpty {
                    Text(r.advice).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                if rec.isPlayingMine { rec.stopPlayback() } else { rec.playMine(attempt.fileName) }
            } label: {
                Image(systemName: "play.circle").font(.system(size: 18)).foregroundStyle(Theme.ice)
            }
            .buttonStyle(.plain)
            Button {
                store.deleteAttempt(attempt)
            } label: {
                Image(systemName: "trash").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 录音电平波形

struct LevelWave: View {
    let level: Double
    let active: Bool

    private let bars = 21

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(active ? Theme.ice : Theme.ice.opacity(0.18))
                    .frame(width: 4, height: height(i))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 46)
    }

    /// 中间高两边低，跟着电平起伏
    private func height(_ i: Int) -> CGFloat {
        let center = Double(bars - 1) / 2
        let dist = abs(Double(i) - center) / center
        let shape = 1 - dist * dist * 0.75
        let base = 5.0
        let amp = active ? level * 40 * shape : 3 * shape
        return CGFloat(base + amp)
    }
}
