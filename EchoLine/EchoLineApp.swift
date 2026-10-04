import SwiftUI
import AppKit

@main
struct EchoLineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = EchoStore.shared

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.ice)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandMenu("朗读") {
                Button("慢一点") { store.stepSpeed(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("快一点") { store.stepSpeed(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("正常语速 1.0×") { store.setSpeed(1) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                ForEach(EchoStore.speedPresets, id: \.self) { m in
                    Button((abs(m - store.speedMultiplier) < 0.001 ? "✓ " : "   ") + EchoStore.speedLabel(m)) {
                        store.setSpeed(m)
                    }
                }
                Divider()
                Button("停止朗读") { Speech.shared.stop() }
            }
        }

        // 菜单栏常驻小窗
        MenuBarExtra("EchoLine", systemImage: "quote.opening") {
            MenuBarPanel()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.ice)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPane()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.ice)
        }
    }
}

// MARK: - App 代理：注册全局划词快捷键

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyManager.shared.onHotKey = {
            Task { @MainActor in
                QuickCapture.trigger(store: EchoStore.shared)
            }
        }
        HotKeyManager.shared.register()
        Task { @MainActor in
            SelectionWatcher.shared.start()
            KeyNav.shared.install()          // 裸键导航：j/k/Space/L/S
            SyncEngine.shared.start()
        }
        // 回到前台时拉取 iPhone 端的最新改动
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in SyncEngine.shared.appBecameActive() }
        }
    }
}

// MARK: - 菜单栏小窗：快速收句 + 最近句子

struct MenuBarPanel: View {
    @EnvironmentObject var store: EchoStore
    @State private var quick = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EchoLine").font(.headline)

            HStack {
                TextField("粘贴英文句子，回车收入句库", text: $quick)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addQuick() }
                Button("收下") { addQuick() }
                    .disabled(quick.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !store.sentences.isEmpty {
                Divider()
                Text("最近").font(.caption).foregroundStyle(.secondary)
                ForEach(store.sentences.prefix(5)) { s in
                    HStack(spacing: 8) {
                        Button {
                            Speech.shared.speak(s.text, rate: store.speechRate)
                        } label: {
                            Image(systemName: "play.circle").foregroundStyle(Theme.ice)
                        }
                        .buttonStyle(.plain)
                        Text(s.text).font(.callout).lineLimit(1)
                        Spacer()
                    }
                }
            }

            Divider()
            HStack {
                SettingsLink { Text("设置…") }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func addQuick() {
        let t = quick.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.importText(t, source: "菜单栏")
        quick = ""
    }
}

// MARK: - 设置

struct SettingsPane: View {
    @EnvironmentObject var store: EchoStore
    @StateObject private var sync = SyncEngine.shared
    @State private var aiResult: String?
    @State private var ttsResult: String?
    @State private var ttsOK = false
    @State private var testingAI = false
    @State private var testingTTS = false
    @State private var showAdvancedAI = false

    var body: some View {
        Form {
            keySection
            speechSection

            Section("阅读") {
                Toggle("中文翻译始终显示（默认悬停才显示）", isOn: store.$zhAlwaysVisible)
            }

            syncSection
            captureSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding(.vertical, 8)
    }

    // MARK: 一把 Key

    private var keySection: some View {
        Section {
            if store.aiProvider == "qwen" {
                SecureField("阿里云百炼 API Key（sk-…）", text: store.$aiKey)
                HStack(spacing: 10) {
                    Button {
                        Task { await testEverything() }
                    } label: {
                        if testingAI || testingTTS {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(store.aiKey.isEmpty || testingAI || testingTTS)
                    if let aiResult {
                        Text(aiResult).font(.caption).lineLimit(2)
                    }
                }
            } else {
                Picker("解读服务商", selection: store.$aiProvider) {
                    Text("通义千问（推荐）").tag("qwen")
                    Text("DeepSeek").tag("deepseek")
                    Text("Kimi (月之暗面)").tag("kimi")
                    Text("自定义").tag("custom")
                }
                .onChange(of: store.aiProvider) {
                    store.aiModel = AIService.Config.defaultModel(for: store.aiProvider)
                }
                SecureField("API Key", text: store.$aiKey)
                TextField("模型名", text: store.$aiModel)
                if store.aiProvider == "deepseek", store.aiModel.lowercased().contains("v4-flash") {
                    Toggle("开启思考模式", isOn: store.$aiThinkingEnabled)
                }
                if store.aiProvider == "custom" {
                    TextField("Base URL（https://…/v1）", text: store.$aiBaseURL)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await testAI() }
                    } label: {
                        if testingAI { ProgressView().controlSize(.small) } else { Text("测试连接") }
                    }
                    .disabled(store.aiKey.isEmpty || testingAI)
                    if let aiResult {
                        Text(aiResult).font(.caption).lineLimit(2)
                    }
                }
            }

            DisclosureGroup("高级", isExpanded: $showAdvancedAI) {
                if store.aiProvider == "qwen" {
                    TextField("解读模型", text: store.$aiModel)
                    Button("换用 DeepSeek / Kimi / 自定义接口") {
                        store.aiProvider = "deepseek"
                        store.aiModel = AIService.Config.defaultModel(for: "deepseek")
                        // 百炼 Key 挪到发音栏继续用；旧的 DeepSeek Key 有备份就还回来。
                        if store.ttsKey.isEmpty { store.ttsKey = store.aiKey }
                        store.aiKey = UserDefaults.standard.string(forKey: "legacyDeepSeekKey") ?? ""
                    }
                } else {
                    Button("换回通义千问（一把 Key 通吃）") {
                        if !store.aiKey.isEmpty {
                            UserDefaults.standard.set(store.aiKey, forKey: "legacyDeepSeekKey")
                        }
                        store.aiKey = store.ttsKey      // 发音栏里那把就是百炼 Key
                        store.ttsKey = ""
                        store.aiProvider = "qwen"
                        store.aiModel = "qwen-flash"
                    }
                }
            }
        } header: {
            Text(store.aiProvider == "qwen" ? "通义千问 · 一把 Key" : "AI 解读")
        } footer: {
            Text(store.aiProvider == "qwen"
                 ? "解读、查词、跟读点评走 qwen-flash，发音走 qwen3-tts-flash，都用这一把 Key。在 bailian.console.aliyun.com 创建 Key，并在模型广场开通这两个模型。"
                 : "接口需兼容 OpenAI 的 /chat/completions。用其他家解读时，百炼发音需要在下面单独填一把百炼 Key。")
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 发音

    private var speechSection: some View {
        Section("发音") {
            Picker("声音", selection: store.$ttsProvider) {
                Text("通义千问 TTS（推荐）").tag("qwen")
                Text("SiliconFlow CosyVoice").tag("siliconflow")
                Text("macOS 系统声音").tag("system")
            }
            .onChange(of: store.ttsProvider) {
                switch store.ttsProvider {
                case "qwen":
                    store.ttsModel = "qwen3-tts-flash"
                    store.ttsVoice = "Jennifer"
                case "siliconflow":
                    store.ttsModel = "FunAudioLLM/CosyVoice2-0.5B"
                    store.ttsVoice = "benjamin"
                default:
                    break
                }
                ttsResult = nil
            }

            if store.ttsProvider == "qwen" {
                if store.aiProvider == "qwen" {
                    LabeledContent("API Key") {
                        Text("与上面共用").foregroundStyle(.secondary)
                    }
                } else {
                    SecureField("阿里云百炼 API Key（发音用）", text: store.$ttsKey)
                }
            } else if store.ttsProvider == "siliconflow" {
                SecureField("SiliconFlow API Key", text: store.$ttsKey)
                TextField("模型", text: store.$ttsModel)
            }

            if store.ttsProvider != "system" {
                // 用 config.voice 而不是原始存值：换服务商后残留的旧音色在新清单里没有对应项，
                // Picker 会显示成一行空白，而合成其实已经回落到默认音色了。
                Picker("音色", selection: Binding(
                    get: { CloudTTS.config.voice },
                    set: { store.ttsVoice = $0 }
                )) {
                    ForEach(CloudTTS.voices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
            }

            Slider(value: Binding(get: { store.speedMultiplier }, set: { store.setSpeed($0) }),
                   in: 0.5...1.5, step: 0.05) {
                Text("语速 \(store.speedLabel)")
            } minimumValueLabel: {
                Text("0.5×").font(.caption2)
            } maximumValueLabel: {
                Text("1.5×").font(.caption2)
            }
            Text("主窗口工具栏和各练习窗口里也能随时调；⌘[ 慢一点、⌘] 快一点。慢速按钮 = 当前语速的 70%。")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    Task { await testTTS() }
                } label: {
                    if testingTTS {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(store.ttsProvider == "system" ? "试听系统声音" : "测试云端发音")
                    }
                }
                .disabled(testingTTS)
                if let ttsResult {
                    Label(ttsResult, systemImage: ttsOK ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(ttsOK ? Color.secondary : Theme.verb)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("系统声音（回退用）", value: Speech.shared.voiceInfo)
            Text(ttsFooter).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ttsFooter: String {
        switch store.ttsProvider {
        case "qwen":
            return "整句、单词、划段浮窗里的朗读全走 qwen3-tts-flash（Jennifer / Ryan / Aiden 是母语级美音）。每条只合成一次、本地缓存、离线可重播；无网或出错自动回退系统声音。"
        case "siliconflow":
            return "在 siliconflow.cn 创建 Key 后，朗读走 CosyVoice 云端音色。每条只合成一次并缓存到本机；无网或出错自动回退系统声音。"
        default:
            return "只用 macOS 自带声音。想改善：系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 英语，下载 Premium 声音。"
        }
    }

    // MARK: iCloud / 划词

    private var syncSection: some View {
        Section("iCloud 同步（与 iPhone 端 IELTSMate）") {
            if sync.iCloudAvailable {
                Toggle("开启同步", isOn: Binding(
                    get: { sync.syncOn },
                    set: { sync.setOn($0) }
                ))
                if sync.syncOn {
                    LabeledContent("状态", value: sync.syncing ? "同步中…" : sync.status)
                    if let t = sync.lastSync {
                        LabeledContent("上次同步", value: t.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("文件夹", value: sync.cloudPathDisplay)
                    Button("立即同步") { Task { await sync.syncNow() } }
                        .disabled(sync.syncing)
                }
            } else {
                Text("未检测到 iCloud 云盘。请在 系统设置 → Apple 账户 → iCloud → iCloud 云盘 中开启后再打开同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("同步文件夹为 \(sync.cloudPathDisplay)（iPhone 端在 IELTSMate 设置里授权同一文件夹）。句库、生词本、跟读成绩、生词串文自动保持一致：本地改动后自动推送，回前台和每分钟自动拉取。录音音频与释义缓存不同步；开启同步期间删除的条目两端同步删除。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var captureSection: some View {
        Section("全局划词（⌥⌘E）") {
            Toggle("划词后自动显示小图标（点图标打开预览）", isOn: store.$selectionIconEnabled)
            LabeledContent("辅助功能权限",
                           value: SelectionReader.isTrusted ? "已授权 ✓" : "未授权")
            if !SelectionReader.isTrusted {
                Button("去授权") {
                    SelectionReader.requestTrust()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("在任何应用里选中英文，按 ⌥⌘E 或点小图标：单个单词打开释义卡；句子或段落先打开预览浮窗——可以点词、整段朗读、录一遍对比自己的发音，看完再决定要不要「收录」进句库（⏎ 收录，Esc 关闭，不收录什么都不留）。首次使用需在 系统设置 → 隐私与安全性 → 辅助功能 中勾选 EchoLine（修改代码重装后需要重新勾选）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 测试

    /// 百炼一把 Key：解读和发音各测一次，分开报结果——一个通了另一个没通是常见情况（模型没开通）。
    private func testEverything() async {
        await testAI()
        if store.ttsProvider == "qwen" { await testTTS() }
    }

    private func testAI() async {
        testingAI = true
        aiResult = await AIService.test(config: store.aiConfig)
        testingAI = false
    }

    /// 真去合成一次，把失败原因原样显示出来。
    /// 平时朗读失败会静默回退系统声音，用户只会觉得"音色不对"，查不出是 Key 还是模型没开通。
    private func testTTS() async {
        let sample = "The results of the trial were quite encouraging."
        ttsResult = nil
        guard store.ttsProvider != "system" else {
            Speech.shared.preview(sample, rate: store.speechRate)
            ttsOK = true
            ttsResult = "系统声音：\(Speech.shared.voiceInfo)"
            return
        }
        testingTTS = true
        do {
            let data = try await CloudTTS.fetchAudio(text: sample, rate: store.speechRate, bypassCache: true)
            Speech.shared.playCloudSample(data, rate: store.speechRate)
            let cfg = CloudTTS.config
            ttsOK = true
            ttsResult = "发音正常：\(cfg.provider.rawValue) · \(cfg.voice)"
        } catch {
            ttsOK = false
            ttsResult = error.localizedDescription
        }
        testingTTS = false
    }
}
