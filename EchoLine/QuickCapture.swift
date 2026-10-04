import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 全局快捷键（⌥⌘E）

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotKey: (() -> Void)?

    func register() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onHotKey?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x45434C4E), id: 1)   // "ECLN"
        RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(optionKey | cmdKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - 读取其他应用中选中的文本

enum SelectionReader {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// 先走辅助功能 AX 接口，取不到再用模拟 ⌘C 兜底
    static func readSelection() -> String? {
        if let ax = axSelectedText(), !ax.trimmingCharacters(in: .whitespaces).isEmpty {
            return ax
        }
        return clipboardFallback()
    }

    private static func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        var textRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String else { return nil }
        return text
    }

    /// 模拟 ⌘C 读剪贴板，读完恢复原剪贴板内容
    private static func clipboardFallback() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let savedCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        usleep(180_000)   // 等目标应用完成复制

        guard pasteboard.changeCount != savedCount,
              let text = pasteboard.string(forType: .string) else { return nil }
        // 恢复原剪贴板
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return text
    }
}

// MARK: - 划词捕获流程

@MainActor
enum QuickCapture {

    static func trigger(store: EchoStore) {
        guard SelectionReader.isTrusted else {
            SelectionReader.requestTrust()
            QuickPanel.shared.show(message: "需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 EchoLine，然后重新按 ⌥⌘E", store: store)
            return
        }
        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "划词"
        guard let raw = SelectionReader.readSelection(),
              raw.rangeOfCharacter(from: .letters) != nil else {
            QuickPanel.shared.show(message: "没有检测到选中的英文文本，请先选中文字再按 ⌥⌘E", store: store)
            return
        }
        capture(text: raw, source: sourceApp, store: store)
    }

    /// 图标点击/快捷键共用。单词 → 释义卡；句子/段落 → 预览浮窗，**不自动入库**，
    /// 看完、听完、读完再点「收录」。已经在句库里的直接打开那一条。
    static func capture(text: String, source: String, store: EchoStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let word = WordSelection.singleWord(from: trimmed) {
            // 单词是即时查询，不混进句库；用户可在分析卡里决定是否收藏。
            QuickPanel.shared.show(word: word, source: source, store: store)
            return
        }

        // SentenceSplitter 会主动过滤过短片段。
        guard let draft = CaptureDraft.make(from: trimmed, source: source) else {
            QuickPanel.shared.show(message: "请选择一个英文单词，或至少 3 个词的完整句子", store: store)
            return
        }
        // 以前收过这一段：不必再问一遍收不收，直接打开它。
        if let existing = store.sentences.first(where: { $0.text == draft.text }) {
            store.selectedID = existing.id
            QuickPanel.shared.show(sentenceID: existing.id, store: store)
            return
        }
        QuickPanel.shared.show(draft: draft, store: store)
    }
}

// MARK: - 划词自动图标：松开鼠标检测选中英文 → 光标旁冒小图标

@MainActor
final class SelectionWatcher {
    static let shared = SelectionWatcher()

    private var monitors: [Any] = []
    private var iconPanel: NSPanel?
    private var pendingText: String?
    private var hideTimer: Timer?

    // 手势判定
    private var didDrag = false
    private var downLocation: NSPoint = .zero
    // 模拟 ⌘C 期间屏蔽"按键收起图标"，避免自己把自己关了
    private var suppressHideUntil = Date.distantPast

    func start() {
        guard monitors.isEmpty else { return }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.didDrag = false
                self.downLocation = NSEvent.mouseLocation
                self.hideIcon()
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = NSEvent.mouseLocation
                if abs(now.x - self.downLocation.x) > 4 || abs(now.y - self.downLocation.y) > 4 {
                    self.didDrag = true
                }
            }
        } as Any)

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            let clicks = event.clickCount
            Task { @MainActor in
                self?.handleMouseUp(clickCount: clicks)
            }
        } as Any)

        // 再点击/滚动/按键时收起图标（模拟 ⌘C 窗口期除外）
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .scrollWheel, .keyDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date() > self.suppressHideUntil else { return }
                self.hideIcon()
            }
        } as Any)
    }

    private func handleMouseUp(clickCount: Int) {
        let store = EchoStore.shared
        guard store.selectionIconEnabled, SelectionReader.isTrusted else { return }
        if NSApp.isActive { return }                      // 自己的窗口里不触发
        // 只有"拖拽选择"或"双击/三击选词"才算选择手势，普通单击不打扰
        guard didDrag || clickCount >= 2 else { return }
        didDrag = false

        let mouse = NSEvent.mouseLocation
        // 稍等目标应用完成选择，再读取（AX 优先，失败模拟 ⌘C 并恢复剪贴板）
        suppressHideUntil = Date().addingTimeInterval(0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let text = SelectionReader.readSelection() else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 仅英文内容触发：单词允许 a / I，其余文本至少 2 个字母；拉丁字母须占多数。
            let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let latin = trimmed.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }
            let isWord = WordSelection.singleWord(from: trimmed) != nil
            guard (letters.count >= 2 || isWord), latin.count * 2 > letters.count,
                  trimmed.count < 4000 else { return }
            self.pendingText = trimmed
            self.showIcon(at: mouse)
        }
    }

    private func showIcon(at point: NSPoint) {
        let p = iconPanel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 34, height: 34),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return panel
        }()
        iconPanel = p
        p.contentView = NSHostingView(rootView: SelectionIconView { [weak self] in
            self?.iconTapped()
        })
        p.setFrameOrigin(NSPoint(x: point.x + 10, y: point.y + 12))
        p.orderFrontRegardless()

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideIcon() }
        }
    }

    private func iconTapped() {
        guard let text = pendingText else { return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "划词"
        hideIcon()
        QuickCapture.capture(text: text, source: source, store: EchoStore.shared)
    }

    func hideIcon() {
        hideTimer?.invalidate()
        iconPanel?.orderOut(nil)
        pendingText = nil
    }
}

extension SelectionReader {
    /// 静默读取（仅 AX，不模拟 ⌘C，不碰剪贴板）——划词图标探测用
    static func readSelectionQuiet() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        var textRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String, !text.isEmpty else { return nil }
        return text
    }
}

/// 划词小图标
struct SelectionIconView: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "quote.opening")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 28, height: 28)
                .background(Theme.ice, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .padding(3)
    }
}

// MARK: - 浮窗（光标旁，可图钉固定；未固定时点空白处自动关闭）

@MainActor
final class QuickPanel: ObservableObject {
    static let shared = QuickPanel()

    @Published var isPinned = false

    /// 划段预览的中译缓存（文本 → 逐句中文）。同一段再划一次不重复请求；
    /// 只放内存，不进句库——预览不是收录。
    var draftTranslations: [String: [String]] = [:]

    private var panel: NSPanel?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?

    private func makePanel() -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    func show(sentenceID: UUID, store: EchoStore, keepPosition: Bool = false) {
        present(QuickPanelView(sentenceID: sentenceID, message: nil)
            .environmentObject(store),
                size: NSSize(width: 480, height: 470), keepPosition: keepPosition)
    }

    /// 划段预览：只看不存。
    func show(draft: CaptureDraft, store: EchoStore) {
        present(CaptureDraftView(draft: draft).environmentObject(store),
                size: NSSize(width: 480, height: 470))
    }

    /// 预览里点了「收录」：入库，然后原地换成已收录的那张浮窗（位置不跳，解读接着跑）。
    func collect(_ draft: CaptureDraft, store: EchoStore) {
        store.importText(draft.text, source: draft.source)
        guard let id = store.selectedID, store.sentences.contains(where: { $0.id == id }) else {
            show(message: "没有识别到可解读的英文内容", store: store)
            return
        }
        show(sentenceID: id, store: store, keepPosition: true)
    }

    func show(word: String, source: String, store: EchoStore) {
        present(QuickWordPanelView(word: word, source: source)
            .environmentObject(store))
    }

    func show(message: String, store: EchoStore) {
        present(QuickPanelView(sentenceID: nil, message: message)
            .environmentObject(store), size: NSSize(width: 480, height: 470))
    }

    private func present<V: View>(_ view: V,
                                  size: NSSize = NSSize(width: 440, height: 380),
                                  keepPosition: Bool = false) {
        let alreadyVisible = panel?.isVisible ?? false
        let p = panel ?? makePanel()
        panel = p
        p.contentView = NSHostingView(rootView: AnyView(
            view.preferredColorScheme(.dark).tint(Theme.ice)
        ))

        if (isPinned || keepPosition) && alreadyVisible {
            // 已固定、或预览→收录的原地切换：留在原处，只按新内容调尺寸（左上角不动）。
            var frame = p.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            p.setFrame(frame, display: true)
        } else {
            let mouse = NSEvent.mouseLocation
            var origin = NSPoint(x: mouse.x - 40, y: mouse.y - size.height - 16)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                origin.x = min(max(screen.visibleFrame.minX + 8, origin.x),
                               screen.visibleFrame.maxX - size.width - 8)
                origin.y = min(max(screen.visibleFrame.minY + 8, origin.y),
                               screen.visibleFrame.maxY - size.height - 8)
            }
            p.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        p.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    /// 点浮窗外自动关闭；同时监听其他应用和 EchoLine 自己的窗口。
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // 正在录音时点到外面也别关：一关就把正在录的那一遍作废了。
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPinned, !RecordingService.shared.isRecording else { return }
                self.close()
            }
        }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isPinned, event.window !== self.panel,
                  !RecordingService.shared.isRecording else { return event }
            self.close()
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = globalOutsideClickMonitor {
            NSEvent.removeMonitor(m)
            globalOutsideClickMonitor = nil
        }
        if let m = localOutsideClickMonitor {
            NSEvent.removeMonitor(m)
            localOutsideClickMonitor = nil
        }
    }

    func close() {
        removeOutsideClickMonitor()
        isPinned = false
        panel?.orderOut(nil)
        Speech.shared.stop()
        RecordingService.shared.stopPlayback()
        if RecordingService.shared.isRecording { RecordingService.shared.cancel() }
    }
}

/// 无边框面板默认不能成为 key window，覆写以支持 Esc 和输入
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        QuickPanel.shared.close()
    }
}

// MARK: - 浮窗内容

struct QuickPanelView: View {
    let sentenceID: UUID?
    let message: String?
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var speech = Speech.shared
    @ObservedObject private var panelCtrl = QuickPanel.shared

    @State private var isAnalysing = false
    @State private var errorMessage: String?
    @State private var wordLookup: WordLookupRequest?
    @State private var recording = false
    @State private var lastAttempt: ShadowAttempt?

    private var sentence: EchoSentence? {
        guard let sentenceID else { return nil }
        return store.sentences.first { $0.id == sentenceID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("EchoLine", systemImage: "quote.opening")
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.ice)
                if sentence != nil {
                    Label("已存入句库", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(Theme.right)
                }
                Spacer()
                Button {
                    panelCtrl.isPinned.toggle()
                } label: {
                    Image(systemName: panelCtrl.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(panelCtrl.isPinned ? AnyShapeStyle(Theme.ice) : AnyShapeStyle(.tertiary))
                        .rotationEffect(.degrees(45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(panelCtrl.isPinned ? "取消固定句子浮窗" : "固定句子浮窗")
                .help(panelCtrl.isPinned ? "取消固定（点空白处将自动关闭）" : "固定浮窗（不固定时点空白处自动关闭）")

                Button {
                    QuickPanel.shared.close()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭句子浮窗")
                .help("关闭（Esc）")
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else if let s = sentence {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TapText(text: s.text, fontSize: 16,
                                iceTerms: (s.analysis?.highlights ?? []).map(\.term),
                                badTerms: ShadowBadWords.of(lastAttempt)) { token in
                            tapWord(token, in: s)
                        }

                        HStack(spacing: 12) {
                            Button {
                                speech.speak(s.text, rate: store.speechRate)
                            } label: {
                                Label("朗读", systemImage: "play.circle.fill")
                            }
                            Button {
                                speech.speak(s.text, rate: store.slowRate)
                            } label: {
                                Label("慢速", systemImage: "tortoise")
                            }
                            Button {
                                speech.toggleLoop(s.text, rate: store.speechRate)
                            } label: {
                                Label("循环", systemImage: "repeat")
                            }
                            .foregroundStyle(speech.isLooping && speech.loopText == s.text ? Theme.ice : Color.secondary)
                            Spacer()
                            Button {
                                openMainWindow()
                            } label: {
                                Label("主窗口", systemImage: "macwindow")
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.ice)
                        .disabled(recording)

                        if let lookup = wordLookup {
                            WordAnalysisCard(request: lookup, compact: true)
                                .id(lookup.id)
                        }

                        // 收录之后也能接着录：跟读记录挂在这一句上，主窗口里能看到完整历史。
                        InlineShadowRecorder(target: s.text, isRecording: $recording) { attempt in
                            lastAttempt = attempt
                        }

                        if s.isParagraph {
                            Divider()
                            if !s.paraZH.isEmpty || !s.paraGist.isEmpty {
                                // 整段中译
                                if !s.paraZH.isEmpty {
                                    Text(s.paraZH).font(.callout).lineSpacing(4)
                                }
                                // 段落大意
                                if !s.paraGist.isEmpty {
                                    Label(s.paraGist, systemImage: "text.alignleft")
                                        .font(.caption).foregroundStyle(Theme.ice)
                                }
                                // 句间逻辑（段落的"语法结构"）
                                if !s.paraLogic.isEmpty {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("句间逻辑").font(.caption2).foregroundStyle(.tertiary)
                                        Text(s.paraLogic).font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                                    }
                                }
                                Text("逐句语法精读（时态/结构/亮点）→ 点「主窗口」")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            } else if isAnalysing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("整段解读中…").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if let errorMessage {
                                Text(errorMessage).font(.caption).foregroundStyle(.red)
                            }
                        } else if let a = s.analysis {
                            Divider()
                            Text(a.zh).font(.callout)
                            if let t = a.tense {
                                Text("⏱ \(t.name)：\(t.why)")
                                    .font(.caption).foregroundStyle(Theme.ice)
                            }
                            if !a.structure.isEmpty {
                                Text(a.structure).font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                            }
                            ForEach(a.highlights.prefix(2), id: \.self) { h in
                                Text("✦ \(h.term) — \(h.note)")
                                    .font(.caption).foregroundStyle(Theme.ice)
                            }
                        } else if isAnalysing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("解读中…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 480, height: 470, alignment: .topLeading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 0.5))
        .onExitCommand { QuickPanel.shared.close() }
        .task(id: sentenceID) { await analyseIfNeeded() }
    }

    private func tapWord(_ token: String, in s: EchoSentence) {
        guard let clean = WordSelection.singleWord(from: token) else { return }
        Speech.shared.speak(clean, rate: store.speechRate)
        let hit = s.analysis?.words.first(where: { matches($0.term, clean) })
        wordLookup = WordLookupRequest(word: clean, context: s.text, fallbackMeaning: hit?.note)
    }

    private func matches(_ term: String, _ word: String) -> Bool {
        guard let termWord = WordSelection.singleWord(from: term) else { return false }
        return WordSelection.comparisonKey(termWord) == WordSelection.comparisonKey(word)
    }

    private func analyseIfNeeded() async {
        guard let s = sentence, !store.aiKey.isEmpty, !isAnalysing else { return }
        if s.isParagraph {
            // 段落：浮窗内直接跑整段解读（中译 + 大意 + 句间逻辑）
            guard s.paraGist.isEmpty else { return }
            isAnalysing = true
            do {
                let r = try await AIService.analyseParagraph(s.text, config: store.aiConfig)
                var copy = s
                copy.paraZH = r.zh
                copy.paraGist = r.gist
                copy.paraLogic = r.logic
                store.update(copy)
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalysing = false
        } else {
            guard s.analysis == nil else { return }
            isAnalysing = true
            do {
                let result = try await AIService.analyse(s.text, config: store.aiConfig)
                var copy = s
                copy.analysis = result
                store.update(copy)
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalysing = false
        }
    }

    private func openMainWindow() {
        QuickPanel.shared.close()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
