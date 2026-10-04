import Foundation
import CryptoKit

/// 云端神经 TTS，带本地音频缓存。
/// 默认走阿里云百炼 qwen3-tts-flash，和解读共用同一把 Key；SiliconFlow 保留为备选通道。
enum CloudTTS {

    enum Provider: String {
        case qwen
        case siliconflow
        /// 明确只用 macOS 自带声音：不去合成，也不算"已配置"。
        case system
    }

    /// 元组不能用 key path，ForEach(_:id:) 拿不到 \.id；音色得是个真正的类型。
    struct VoiceOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct Config {
        var key: String
        var provider: Provider
        var model: String
        var voice: String       // qwen：Jennifer；SiliconFlow：短名 benjamin

        var isConfigured: Bool { provider != .system && !key.isEmpty && !model.isEmpty && !voice.isEmpty }
        /// SiliconFlow 的 voice 参数要带模型前缀。
        var voiceParam: String { "\(model):\(voice)" }
    }

    static var config: Config {
        let d = UserDefaults.standard
        let provider = Provider(rawValue: d.string(forKey: "ttsProvider") ?? "qwen") ?? .qwen
        if provider == .system {
            return Config(key: "", provider: .system, model: "", voice: "")
        }
        let storedModel = trimmed(d.string(forKey: "ttsModel"))
        let storedVoice = trimmed(d.string(forKey: "ttsVoice"))
        switch provider {
        case .qwen:
            return Config(key: qwenKey(d), provider: .qwen,
                          model: normalizedQwenModel(storedModel),
                          voice: normalizedQwenVoice(storedVoice))
        default:
            return Config(key: trimmed(d.string(forKey: "ttsKey")), provider: .siliconflow,
                          model: storedModel.isEmpty || storedModel.hasPrefix("qwen")
                              ? "FunAudioLLM/CosyVoice2-0.5B" : storedModel,
                          voice: siliconFlowVoices.contains(where: { $0.id == storedVoice })
                              ? storedVoice : "benjamin")
        }
    }

    private static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 百炼一把 Key 通吃：解读、查词、发音全用它，发音这一栏不再单独要 Key。
    /// 按"长得像不像百炼 Key"来挑而不是按填写顺序——ttsKey 里可能还留着 SiliconFlow 的旧 Key，
    /// 照填写顺序会把它发去百炼，换回一个 401。
    /// sk- 不是百炼独有的（DeepSeek、Kimi、SiliconFlow 都长这样），所以先看解读那栏是不是百炼：
    /// 是才让 aiKey 打头阵，否则 ttsKey 优先。
    static func qwenKey(_ d: UserDefaults = .standard) -> String {
        // sk- 不是百炼独有的（DeepSeek、Kimi、SiliconFlow 都长这样），按前缀猜迟早把别家 Key 发去百炼。
        // 规则只看服务商：解读是百炼 → 就是那一把；解读是别家 → 用发音栏单独填的百炼 Key。
        (d.string(forKey: "aiProvider") ?? "qwen") == "qwen"
            ? trimmed(d.string(forKey: "aiKey"))
            : trimmed(d.string(forKey: "ttsKey"))
    }

    /// 从 SiliconFlow 档位切过来时音色/模型可能还留着对方的值，发过去必然失败；用之前归一化。
    static func normalizedQwenVoice(_ raw: String) -> String {
        qwenVoices.contains(where: { $0.id == raw }) ? raw : "Jennifer"
    }

    static func normalizedQwenModel(_ raw: String) -> String {
        raw.hasPrefix("qwen") ? raw : "qwen3-tts-flash"
    }

    /// 通义千问 qwen3-tts-flash 的音色，前三个是母语级英语发音。
    static let qwenVoices: [VoiceOption] = [
        VoiceOption(id: "Jennifer", name: "Jennifer · 美音女声（推荐）"),
        VoiceOption(id: "Ryan", name: "Ryan · 美音男声"),
        VoiceOption(id: "Aiden", name: "Aiden · 美音男声"),
        VoiceOption(id: "Serena", name: "Serena · 温柔女声"),
        VoiceOption(id: "Cherry", name: "Cherry · 多语女声"),
    ]

    /// SiliconFlow CosyVoice2 内置音色。
    static let siliconFlowVoices: [VoiceOption] = [
        VoiceOption(id: "benjamin", name: "Benjamin · 沉稳男声"),
        VoiceOption(id: "charles", name: "Charles · 磁性男声"),
        VoiceOption(id: "alex", name: "Alex · 阳光男声"),
        VoiceOption(id: "david", name: "David · 欢快男声"),
        VoiceOption(id: "anna", name: "Anna · 沉稳女声"),
        VoiceOption(id: "claire", name: "Claire · 温柔女声"),
        VoiceOption(id: "bella", name: "Bella · 激情女声"),
        VoiceOption(id: "diana", name: "Diana · 欢快女声"),
    ]

    /// 当前服务商能选的音色（设置页用）。
    static var voices: [VoiceOption] {
        switch config.provider {
        case .qwen: return qwenVoices
        case .siliconflow: return siliconFlowVoices
        case .system: return []
        }
    }

    /// qwen3-tts-flash 的非流式接口没有语速参数，慢速改在播放器上变速实现；
    /// SiliconFlow 把语速发给了服务端，播放器不再动。
    static func clientPlaybackRate(for rate: Double) -> Float {
        guard config.provider == .qwen else { return 1 }
        return Float(min(1.5, max(0.5, rate / 0.5)))
    }

    private static var cacheDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoLine/tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 获取音频（优先缓存；系统语速 0.3-0.6 映射为云端 speed 0.6-1.2）。
    /// bypassCache：设置页的"测试发音"专用。缓存键里没有 Key，
    /// 不绕开的话换了一把错 Key 也会命中旧音频，测出来永远是"正常"。
    static func fetchAudio(text: String, rate: Double, bypassCache: Bool = false) async throws -> Data {
        let cfg = config
        guard cfg.isConfigured else { throw TTSError.notConfigured }
        let speed = min(1.5, max(0.5, rate / 0.5))

        // qwen 不把语速发给服务端（靠播放器变速），缓存键里也就不该带语速，
        // 否则同一句话每个语速档都会重新合成、重复计费。
        let speedKey = cfg.provider == .qwen ? "player" : String(format: "%.2f", speed)
        let keySource = "\(cfg.provider.rawValue)|\(cfg.model)|\(cfg.voice)|\(speedKey)|\(text)"
        let hash = SHA256.hash(data: Data(keySource.utf8)).map { String(format: "%02x", $0) }.joined()
        // qwen 回的是 WAV、SiliconFlow 是 mp3；AVAudioPlayer 按内容识别，扩展名只是个名字。
        // 沿用 .mp3 是为了让老用户已缓存的 SiliconFlow 音频继续命中，不用重新合成计费。
        let cacheFile = cacheDir.appendingPathComponent(hash + ".mp3")
        if !bypassCache, let cached = try? Data(contentsOf: cacheFile), !cached.isEmpty {
            return cached
        }

        let data: Data
        switch cfg.provider {
        case .system:
            throw TTSError.notConfigured
        case .qwen:
            data = try await fetchQwenAudio(text: text, voice: cfg.voice, model: cfg.model, apiKey: cfg.key)
        case .siliconflow:
            data = try await fetchSiliconFlowAudio(text: text, speed: speed, config: cfg)
        }
        try? data.write(to: cacheFile, options: .atomic)
        return data
    }

    // MARK: - 百炼 qwen3-tts-flash

    /// 百炼多模态生成接口：先拿到音频地址（WAV，24 小时有效），再下载回来缓存。
    private static func fetchQwenAudio(text: String, voice: String, model: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation") else {
            throw TTSError.notConfigured
        }
        let body: [String: Any] = [
            "model": model,
            "input": ["text": text, "voice": voice, "language_type": "English"],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let output = object["output"] as? [String: Any],
              let audio = output["audio"] as? [String: Any] else {
            throw TTSError.badResponse(qwenFailureReason(data: data, response: response))
        }
        if let encoded = audio["data"] as? String,
           let decoded = Data(base64Encoded: encoded), decoded.count > 200 {
            return decoded
        }
        guard let link = audio["url"] as? String, let audioURL = secureAudioURL(link) else {
            throw TTSError.badResponse("返回结构异常")
        }
        do {
            let (audioData, audioResponse) = try await URLSession.shared.data(from: audioURL)
            guard let audioHTTP = audioResponse as? HTTPURLResponse, audioHTTP.statusCode == 200,
                  audioData.count > 200 else {
                throw TTSError.badResponse("音频下载失败（HTTP \((audioResponse as? HTTPURLResponse)?.statusCode ?? 0)）")
            }
            return audioData
        } catch let error as TTSError {
            throw error
        } catch {
            // 合成是成功的，倒在下载这一步；说清楚是哪一步，不然只看到一句系统报错。
            throw TTSError.badResponse("音频下载失败：\(error.localizedDescription)")
        }
    }

    /// 百炼合成成功后回的是一个 OSS 地址，有时是 http:// 的明文链接，
    /// App Transport Security 会直接拒掉。OSS 本身支持 https，升一下协议就能下下来——比放宽 ATS 安全得多。
    private static func secureAudioURL(_ link: String) -> URL? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("http://") {
            text = "https://" + text.dropFirst("http://".count)
        }
        return URL(string: text)
    }

    /// 百炼把原因放在 code/message 里；带上它，设置页的测试才说得清是 Key 错了还是模型没开通。
    private static func qwenFailureReason(data: Data, response: URLResponse) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (object?["code"] as? String) ?? ""
        let message = (object?["message"] as? String) ?? ""
        if status == 401 || code.localizedCaseInsensitiveContains("apikey") {
            return "百炼 Key 无效（\(code.isEmpty ? String(status) : code)）。去 bailian.console.aliyun.com 确认 Key 有效。"
        }
        if code.localizedCaseInsensitiveContains("model") {
            return "百炼没开通这个语音模型（\(code)）。在百炼控制台的模型广场里开通 qwen3-tts-flash。"
        }
        if !code.isEmpty { return "百炼 \(status) \(code)：\(message.prefix(80))" }
        if !message.isEmpty { return "百炼 \(status)：\(message.prefix(120))" }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "百炼语音合成失败（HTTP \(status)）" : "百炼 \(status)：\(raw.prefix(120))"
    }

    // MARK: - SiliconFlow（备选）

    private static func fetchSiliconFlowAudio(text: String, speed: Double, config cfg: Config) async throws -> Data {
        guard let url = URL(string: "https://api.siliconflow.cn/v1/audio/speech") else {
            throw TTSError.notConfigured
        }
        let body: [String: Any] = [
            "model": cfg.model,
            "input": text,
            "voice": cfg.voiceParam,
            "response_format": "mp3",
            "speed": speed,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count > 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw TTSError.badResponse(String(msg.prefix(200)))
        }
        return data
    }

    enum TTSError: LocalizedError {
        case notConfigured
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "云端发音未配置"
            case .badResponse(let m): return "合成失败：\(m)"
            }
        }
    }
}
