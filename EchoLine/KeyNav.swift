import AppKit

/// 裸键导航：j/k 上下选句、Space 播放/停止、L 循环、S 星标
///
/// 防吞焦点策略（红线：任何文本输入聚焦时裸键一律不得触发）：
/// - 只在「既是 key 又是 main」的窗口响应——sheet、菜单栏小窗、popover 打开时
///   event.window 必然不满足，天然排除
/// - firstResponder 是 NSTextView（TextField / TextEditor / search 的 field editor 都是它）
///   或 NSTextField → 一律放行
/// - Space 额外放行聚焦的控件（全键盘访问下 Space 激活按钮），但列表类视图除外——
///   句库 List 聚焦时 firstResponder 是 NSOutlineView/NSTableView，这是正常浏览状态
/// - ⌘⌥⌃ 按下时不触发（Shift 放行，L/S 大小写都认）
@MainActor
final class KeyNav {
    static let shared = KeyNav()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 本地 monitor 在主线程序列上回调；NSEvent 无 Sendable conformance，
            // 进出 MainActor 边界都用盒子显式接管（assumeIsolated 的返回值要求 Sendable）
            let box = UnsafeSendable(event)
            let out = MainActor.assumeIsolated { UnsafeSendable(Self.handle(box.value)) }
            return out.value
        }
    }

    private struct UnsafeSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window,
              window === NSApp.keyWindow, window === NSApp.mainWindow else { return event }

        let fr = window.firstResponder
        if fr is NSTextView || fr is NSTextField { return event }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.contains(.command), !mods.contains(.control), !mods.contains(.option) else { return event }

        let store = EchoStore.shared

        // Space：播放 / 停止当前句
        if event.keyCode == 49 {
            // 列表类视图聚焦是正常浏览状态（NSCollectionView 不是 NSControl，分开判）
            let isListLike = fr is NSOutlineView || fr is NSTableView || fr is NSCollectionView
            if fr is NSControl, !isListLike {
                return event     // 聚焦的按钮/控件对 Space 有激活语义，不抢
            }
            return togglePlay(store: store) ? nil : event
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return event }
        switch chars {
        case "j": return moveSelection(store: store, offset: 1) ? nil : event
        case "k": return moveSelection(store: store, offset: -1) ? nil : event
        case "l": return toggleLoop(store: store) ? nil : event
        case "s": return toggleStar(store: store) ? nil : event
        default: return event
        }
    }

    // MARK: - 动作（返回 false = 当前语境下没意义，按键放行）

    private static func currentSentence(store: EchoStore) -> EchoSentence? {
        guard let id = store.selectedID else { return nil }
        return store.sentences.first { $0.id == id }
    }

    private static func moveSelection(store: EchoStore, offset: Int) -> Bool {
        let list = store.topLevelSentences
        guard !list.isEmpty else { return false }
        guard let id = store.selectedID,
              let idx = list.firstIndex(where: { $0.id == id }) else {
            if offset > 0 { store.selectedID = list[0].id; return true }   // 没选中时 j 选第一句
            return false
        }
        let next = idx + offset
        guard list.indices.contains(next) else { return true }             // 到边界：不动但吞键，免得系统哔一声
        store.selectedID = list[next].id
        return true
    }

    private static func togglePlay(store: EchoStore) -> Bool {
        let speech = Speech.shared
        if speech.isSpeaking { speech.stop(); return true }
        guard let s = currentSentence(store: store) else { return false }
        speech.speak(s.text, rate: store.speechRate)
        return true
    }

    private static func toggleLoop(store: EchoStore) -> Bool {
        guard let s = currentSentence(store: store) else { return false }
        Speech.shared.toggleLoop(s.text, rate: store.speechRate)
        return true
    }

    private static func toggleStar(store: EchoStore) -> Bool {
        guard let s = currentSentence(store: store) else { return false }
        store.toggleStar(s)
        return true
    }
}
