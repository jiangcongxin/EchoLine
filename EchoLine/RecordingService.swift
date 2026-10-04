import Foundation
import AVFoundation
import Speech

/// 跟读录音服务（macOS 版）：录自己的声音 → 存文件 → 苹果离线识别转文字 → 回放对比
/// 与 Speech 分工：这里只管「我说的」，Speech 管「机器读的」
/// 与 iOS 版差异：macOS 没有 AVAudioSession（无 category/中断概念），
/// 麦克风权限走 AVCaptureDevice；录音目录在 ~/Library/Application Support/EchoLine/recordings
@MainActor
final class RecordingService: NSObject, ObservableObject {
    static let shared = RecordingService()

    @Published private(set) var isRecording = false
    @Published private(set) var isPlayingMine = false
    /// 正在回放的是哪一个录音文件——列表里多行都有「听自己」时，只让在播的那一行显示"停止"
    @Published private(set) var playingFile: String?
    @Published private(set) var level: Double = 0        // 0-1 输入电平（画波形用）
    @Published private(set) var elapsed: Double = 0      // 已录秒数

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var currentURL: URL?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// 录音存放目录：Application Support/EchoLine/recordings（可回听历史）
    static let recordingsDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(for fileName: String) -> URL {
        recordingsDir.appendingPathComponent(fileName)
    }

    // MARK: - 权限

    enum PermissionState { case granted, denied, undetermined }

    static var micState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
    }

    static var speechState: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .undetermined
        }
    }

    /// 请求麦克风 + 语音识别权限，两个都拿到才返回 true
    func requestPermissions() async -> Bool {
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { c.resume(returning: $0) }
        }
        guard mic else { return false }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return speech
    }

    // MARK: - 录音

    /// 开始录音，返回文件名（失败返回 nil）
    @discardableResult
    func start() -> String? {
        Speech.shared.stop()            // 别和机器朗读打架
        stopPlayback()

        let fileName = "rec-\(UUID().uuidString).m4a"
        let url = Self.url(for: fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return nil }
            recorder = r
            currentURL = url
            isRecording = true
            elapsed = 0
            startMetering()
            return fileName
        } catch {
            return nil
        }
    }

    /// 停止录音，返回录音时长（秒）
    @discardableResult
    func stop() -> Double {
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        stopMetering()
        isRecording = false
        level = 0
        return duration
    }

    /// 放弃这次录音并删文件
    func cancel() {
        let url = currentURL
        _ = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        currentURL = nil
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                // -60dB…0dB 映射到 0…1，取平方根让小音量也看得见
                let db = Double(r.averagePower(forChannel: 0))
                let norm = max(0, (db + 60) / 60)
                self.level = norm.squareRoot()
                self.elapsed = r.currentTime
            }
        }
        // .common 模式：滚动时波形和秒表不冻结
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    // MARK: - 回放自己的录音（AB 对比的 B 面）

    func playMine(_ fileName: String) {
        guard !isRecording else { return }
        Speech.shared.stop()
        stopPlayback()
        let url = Self.url(for: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        if player?.play() == true {
            isPlayingMine = true
            playingFile = fileName
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlayingMine = false
        playingFile = nil
    }

    func deleteFile(_ fileName: String) {
        try? FileManager.default.removeItem(at: Self.url(for: fileName))
    }

    // MARK: - 离线识别：把录音转成文字

    enum RecogError: LocalizedError {
        case unavailable
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .unavailable: return "语音识别不可用（检查系统设置里的语音识别权限）"
            case .noSpeech: return "没听清你说的话——离麦克风近一点，音量大一些再试"
            }
        }
    }

    /// 单词识别结果：最佳结果 + 候选 + 置信度（单词太短，只看一个最佳结果太武断）
    struct WordRecognition {
        var best: String
        var alternatives: [String]
        var confidence: Double          // 0-1，识别器对最佳结果的把握
    }

    /// 单词版识别：要 n-best 候选和置信度，给单词打分用。不加 contextualStrings——
    /// 那会把识别结果往目标词上拽，读错了也"识别对"，分数就失真了。
    func transcribeWord(_ fileName: String) async throws -> WordRecognition {
        guard let recognizer, recognizer.isAvailable else { throw RecogError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: Self.url(for: fileName))
        request.shouldReportPartialResults = false
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let box = ResumeBox()
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WordRecognition, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if box.claim() { continuation.resume(throwing: error) }
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let best = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    let alternatives = result.transcriptions.map {
                        $0.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let segments = result.bestTranscription.segments
                    let confidence = segments.isEmpty ? 0
                        : Double(segments.map(\.confidence).reduce(0, +)) / Double(segments.count)
                    if box.claim() {
                        if best.isEmpty {
                            continuation.resume(throwing: RecogError.noSpeech)
                        } else {
                            continuation.resume(returning: WordRecognition(best: best, alternatives: alternatives,
                                                                           confidence: confidence))
                        }
                    }
                }
                taskBox.task = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    if box.claim() {
                        task.cancel()
                        continuation.resume(throwing: RecogError.noSpeech)
                    }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }

    /// 用苹果离线识别把录音转成文字（识别错的词往往就是发音不准的词）
    /// 15 秒超时兜底：识别器偶尔既不回 final 也不报错，不能让界面永远卡在"识别中"
    func transcribe(_ fileName: String) async throws -> String {
        guard let recognizer, recognizer.isAvailable else { throw RecogError.unavailable }
        let url = Self.url(for: fileName)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // 强制设备端识别：不上传录音，离线也能用
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let box = ResumeBox()
        let taskBox = TaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        if box.claim() { continuation.resume(throwing: error) }
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if box.claim() {
                        if text.isEmpty {
                            continuation.resume(throwing: RecogError.noSpeech)
                        } else {
                            continuation.resume(returning: text)
                        }
                    }
                }
                taskBox.task = task
                // 超时兜底
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    if box.claim() {
                        task.cancel()
                        continuation.resume(throwing: RecogError.noSpeech)
                    }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }
}

/// 跨并发域持有识别任务（Swift 6 下捕获可变 var 会报错，用引用盒规避）
private final class TaskBox: @unchecked Sendable {
    var task: SFSpeechRecognitionTask?
}

/// 保证 continuation 只 resume 一次（识别回调 + 超时可能同时到）
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension RecordingService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlayingMine = false
            self.playingFile = nil
        }
    }
}
