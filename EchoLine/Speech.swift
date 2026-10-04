import Foundation
import AVFoundation
import SwiftUI
import AppKit
import Accessibility

/// macOS 朗读服务：整句朗读 + 逐词区间发布（卡拉 OK 高亮）
@MainActor
final class Speech: NSObject, ObservableObject {
    static let shared = Speech()

    @Published var isSpeaking = false
    @Published var spokenText: String? = nil
    @Published var speakingCharRange: Range<Int>? = nil

    private let synthesizer = AVSpeechSynthesizer()

    private var voice: AVSpeechSynthesisVoice? {
        let us = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
            .sorted { quality($0) > quality($1) }
        return us.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func quality(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    var voiceInfo: String {
        guard let v = voice else { return "系统默认" }
        let q = ["", "标准", "Enhanced", "Premium"][quality(v)]
        return "\(v.name) · \(q)"
    }

    private var audioPlayer: AVAudioPlayer?
    private var cloudTask: Task<Void, Never>?

    // 单句循环
    @Published private(set) var isLooping = false
    private(set) var loopText: String? = nil
    private var loopRate: Double = 0.5

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 路由：配置了云端 TTS → 一律真人级云端合成（含单词，带缓存；失败回退系统）
    func speak(_ text: String, rate: Double = 0.5, loop: Bool = false) {
        stop()
        isLooping = loop
        loopText = loop ? text : nil
        loopRate = rate
        routeSpeak(text, rate: rate)
    }

    /// 切换某句的循环播放
    func toggleLoop(_ text: String, rate: Double = 0.5) {
        if isLooping && loopText == text {
            stop()
        } else {
            speak(text, rate: rate, loop: true)
        }
    }

    private func routeSpeak(_ text: String, rate: Double) {
        if CloudTTS.config.isConfigured {
            isSpeaking = true
            spokenText = text          // 云端无逐词回调，仅标记在播
            cloudTask = Task { [weak self] in
                do {
                    let data = try await CloudTTS.fetchAudio(text: text, rate: rate)
                    guard !Task.isCancelled else { return }
                    self?.playData(data, rate: CloudTTS.clientPlaybackRate(for: rate))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.speakSystem(text, rate: rate)   // 自动回退系统声音
                }
            }
        } else {
            speakSystem(text, rate: rate)
        }
    }

    /// 播放结束后的循环调度（0.7 秒停顿后重播，缓存命中几乎无延迟）
    fileprivate func handleFinish() {
        if isLooping, let t = loopText {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.isLooping, self.loopText == t else { return }
                self.routeSpeak(t, rate: self.loopRate)
            }
        } else {
            isSpeaking = false
            spokenText = nil
            speakingCharRange = nil
        }
    }

    private func speakSystem(_ text: String, rate: Double) {
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = Float(rate)
        isSpeaking = true
        synthesizer.speak(u)
    }

    private func playData(_ data: Data, rate: Float = 1) {
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        // 服务端不支持语速时在播放器上变速；enableRate 必须在 play 之前打开。
        // 一律打开：这样播放中拖语速也能立刻生效。
        audioPlayer?.enableRate = true
        audioPlayer?.rate = rate
        if audioPlayer?.play() == true {
            isSpeaking = true
        } else {
            isSpeaking = false
            spokenText = nil
        }
    }

    /// 设置页的"测试发音"：音频已经在外面合成好了，这里只负责放。
    /// 不走 routeSpeak，是因为那条路失败会静默回退系统音，正好把要测的错误吞掉。
    func playCloudSample(_ data: Data, rate: Double) {
        stop()
        isSpeaking = true
        playData(data, rate: CloudTTS.clientPlaybackRate(for: rate))
    }

    /// 播放途中改语速：云端音频在播放器上立刻变速；循环播放的下一遍也用新语速。
    /// 系统声音（AVSpeechSynthesizer）一句话念到一半改不了，下一次朗读生效。
    func applyLiveRate(_ rate: Double) {
        loopRate = rate
        if let player = audioPlayer, player.isPlaying {
            player.rate = CloudTTS.clientPlaybackRate(for: rate)
        }
    }

    /// 试听（设置页用）
    func preview(_ text: String, rate: Double) {
        speak(text, rate: rate)
    }

    func stop() {
        isLooping = false
        loopText = nil
        cloudTask?.cancel()
        cloudTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        spokenText = nil
        speakingCharRange = nil
    }
}

extension Speech: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.handleFinish()
        }
    }
}

extension Speech: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.handleFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        let lower = characterRange.location
        let upper = characterRange.location + characterRange.length
        Task { @MainActor in
            self.spokenText = text
            self.speakingCharRange = lower..<upper
        }
    }
}

// MARK: - 主题（工作台深色：近黑底 · 青碧强调 · 等宽数字）
//
// 借「AI×MED 工作台」的形式：
// 1. 中性骨架 bg / panel / raised / line，全 App 不即兴发明灰色。
// 2. ice（青碧 #2DD4BF）只在"有状态 / 可操作"时出现：播放、选中、进行中、主按钮。
// 3. 语义色：verb 琥珀（谓语 / 待重读）· wrong 红（没读准）· right 绿（通过）· ai 紫（模型点评）。

enum Theme {
    // 骨架
    static let paper  = Color(red: 0.043, green: 0.059, blue: 0.078)   // #0B0F14 主底
    static let side   = Color(red: 0.039, green: 0.055, blue: 0.075)   // #0A0E13 侧栏
    static let panel  = Color(red: 0.055, green: 0.078, blue: 0.106)   // #0E141B 面板
    static let panel2 = Color(red: 0.071, green: 0.102, blue: 0.137)   // #121A23 行
    static let raised = Color(red: 0.086, green: 0.118, blue: 0.157)   // #161E28 浮起
    static let ink    = Color(red: 0.902, green: 0.929, blue: 0.953)   // #E6EDF3 正文
    static let dim    = Color(red: 0.435, green: 0.490, blue: 0.549)   // #6F7D8C 说明
    static let line   = Color(red: 0.110, green: 0.145, blue: 0.196)   // #1C2532 发丝线

    // 强调色
    static let ice    = Color(red: 0.176, green: 0.831, blue: 0.749)   // #2DD4BF
    static let iceDim = ice.opacity(0.14)

    // 语义色
    static let verb  = Color(red: 0.984, green: 0.749, blue: 0.141)    // #FBBF24
    static let wrong = Color(red: 0.973, green: 0.443, blue: 0.443)    // #F87171
    static let right = Color(red: 0.204, green: 0.827, blue: 0.600)    // #34D399
    static let ai    = Color(red: 0.655, green: 0.545, blue: 0.980)    // #A78BFA

    // 兼容别名（旧代码继续可用）
    static let bg     = paper
    static let card   = panel
    static let stroke = line
    static let fill   = Color.white.opacity(0.05)

    /// 数字、日期、快捷键用等宽——工作台的识别度大半来自它
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// 白卡柔影：只给"浮起的那一层"用（句子本体、点词释义卡、浮窗）。
/// 静态内容区不要用——那里用 Overline + Hairline 分区。
struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func paperCard() -> some View { modifier(PaperCard()) }
}

// MARK: - 扁平分区的三个小件

/// overline 分区小标题：纯文字、小号、半粗、灰——代替"图标 + 彩色标题"
struct Overline: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// 发丝分隔线：代替卡片边缘
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }
}

/// 括弧标签：[定语从句]——代替彩色胶囊徽章；active 时才上青碧
struct BracketTag: View {
    let text: String
    var active = false
    init(_ text: String, active: Bool = false) {
        self.text = text
        self.active = active
    }
    var body: some View {
        Text("[\(text)]")
            .font(.caption2)
            .foregroundStyle(active ? Theme.ice : .secondary)
    }
}

// MARK: - 可划选文本（原生选区 + 点词 + 朗读高亮）

/// 所有单词入口共用同一套清洗规则，避免 `word,`、`doctor's`、`well-being`
/// 在全局划词和正文点词之间被分成不同结果。
enum WordSelection {
    private static let wordPattern = #"[A-Za-z0-9À-ÖØ-öø-ÿ]+(?:['’\-‐‑][A-Za-z0-9À-ÖØ-öø-ÿ]+)*"#
    private static let fullWordRegex = try! NSRegularExpression(pattern: "^(?:\(wordPattern))$")
    fileprivate static let wordRegex = try! NSRegularExpression(pattern: wordPattern)

    static func singleWord(from raw: String) -> String? {
        let clean = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !clean.isEmpty, clean.rangeOfCharacter(from: .letters) != nil else { return nil }
        let range = NSRange(location: 0, length: (clean as NSString).length)
        guard fullWordRegex.firstMatch(in: clean, range: range)?.range == range else { return nil }
        return clean
    }

    static func comparisonKey(_ raw: String) -> String {
        (singleWord(from: raw) ?? raw.trimmingCharacters(in: .punctuationCharacters))
            .lowercased()
    }

    fileprivate static func word(atUTF16Index index: Int, in text: String) -> String? {
        let nsText = text as NSString
        guard index >= 0, index < nsText.length else { return nil }
        var result: String?
        wordRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, stop in
            guard let range = match?.range, NSLocationInRange(index, range) else { return }
            result = nsText.substring(with: range)
            stop.pointee = true
        }
        return result
    }
}

struct TapText: View {
    let text: String
    var fontSize: CGFloat = 15
    var serif: Bool = true
    var iceTerms: [String] = []
    var verbTerms: [String] = []        // 谓语动词（橙色下划线）
    var badTerms: [String] = []         // 跟读没读准的词（标红，已按 TextDiff 归一化）
    var onSelect: ((String) -> Void)? = nil
    var onTap: (String) -> Void

    @ObservedObject private var speech = Speech.shared

    private var icePieces: Set<String> {
        Set(iceTerms.flatMap { phrase in
            phrase.split(whereSeparator: { $0.isWhitespace }).map { WordSelection.comparisonKey(String($0)) }
        })
    }

    private var verbPieces: Set<String> {
        Set(verbTerms.flatMap { phrase in
            phrase.split(whereSeparator: { $0.isWhitespace }).map { WordSelection.comparisonKey(String($0)) }
        })
    }

    private var badPieces: Set<String> { Set(badTerms.map { $0.lowercased() }) }

    var body: some View {
        SelectableWordTextView(
            attributed: attributedText,
            onTapWord: onTap,
            onSelectWord: onSelect ?? onTap
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(text)
        .accessibilityHint("选择一个英文单词后按 Return；VoiceOver 可使用“分析所选单词”操作")
    }

    private var attributedText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        let font = Self.textFont(size: fontSize, serif: serif)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let nsText = text as NSString
        WordSelection.wordRegex.enumerateMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) { match, _, _ in
            guard let range = match?.range else { return }
            let raw = nsText.substring(with: range)
            let clean = WordSelection.comparisonKey(raw)
            let isIce = icePieces.contains(clean)
            let isVerb = !isIce && verbPieces.contains(clean)
            let diffKey = TextDiff.words(clean).first ?? clean
            let isBad = badPieces.contains(diffKey)

            if isBad {
                result.addAttribute(.foregroundColor, value: NSColor(Theme.wrong), range: range)
            } else if isIce {
                result.addAttribute(.foregroundColor, value: NSColor(Theme.ice), range: range)
            } else if isVerb {
                result.addAttribute(.foregroundColor, value: NSColor(Theme.verb), range: range)
            }
            if isIce || isVerb {
                result.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor(isIce ? Theme.ice : Theme.verb),
                ], range: range)
            }
        }

        if speech.spokenText == text, let spoken = speech.speakingCharRange {
            let lower = max(0, min(spoken.lowerBound, nsText.length))
            let upper = max(lower, min(spoken.upperBound, nsText.length))
            if upper > lower {
                result.addAttribute(
                    .backgroundColor,
                    value: NSColor(Theme.ice.opacity(0.25)),
                    range: NSRange(location: lower, length: upper - lower)
                )
            }
        }
        return result
    }

    private static func textFont(size: CGFloat, serif: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard serif,
              let descriptor = base.fontDescriptor.withDesign(.serif),
              let designed = NSFont(descriptor: descriptor, size: size) else { return base }
        return designed
    }
}

/// SwiftUI 没有暴露 macOS 文本选区提交事件；这里用最小的 NSTextView 桥接。
/// SwiftUI 仍持有文本和回调，AppKit 只负责原生选择、命中测试与布局。
private struct SelectableWordTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let onTapWord: (String) -> Void
    let onSelectWord: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WordTextView {
        let view = WordTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // SwiftUI 在首次测量时 view.bounds 可能仍是旧宽度；由 sizeThatFits 的 proposal
        // 明确驱动容器宽度，避免正文被压窄后溢出到下方控件。
        // 显示用的容器永远跟着视图宽度；量高度另用临时排版对象（heightThatFits）
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.onTapWord = { context.coordinator.parent.onTapWord($0) }
        view.onSelectWord = { context.coordinator.parent.onSelectWord($0) }
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "分析所选单词") { [weak view] in
                view?.commitSelectedWord() ?? false
            }
        ])
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ nsView: WordTextView, context: Context) {
        context.coordinator.parent = self
        nsView.onTapWord = { context.coordinator.parent.onTapWord($0) }
        nsView.onSelectWord = { context.coordinator.parent.onSelectWord($0) }

        guard nsView.attributedString().isEqual(to: attributed) == false else { return }
        let sameText = nsView.string == attributed.string
        let selection = sameText ? nsView.selectedRange() : NSRange(location: 0, length: 0)
        nsView.textStorage?.setAttributedString(attributed)
        if NSMaxRange(selection) <= attributed.length {
            nsView.setSelectedRange(selection)
        }
        nsView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WordTextView, context: Context) -> CGSize? {
        guard let proposedWidth = proposal.width,
              proposedWidth.isFinite, proposedWidth > 1 else { return nil }
        return CGSize(width: proposedWidth, height: nsView.heightThatFits(width: proposedWidth))
    }

    final class Coordinator {
        var parent: SelectableWordTextView
        init(parent: SelectableWordTextView) { self.parent = parent }
    }
}

private final class WordTextView: NSTextView {
    var onTapWord: ((String) -> Void)?
    var onSelectWord: ((String) -> Void)?
    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false

    /// 用一套临时的排版对象量高度，绝不碰正在显示的那个文本容器。
    /// 以前直接改 textContainer.containerSize 来量：SwiftUI 会用好几个试探宽度来问，
    /// 最后一次试探（常是很窄的最小宽度）留在容器里，正文就按 70pt 一词一行地溢出。
    func heightThatFits(width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width),
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return max(1, ceil(layout.usedRect(for: container).height
                           + textContainerInset.height * 2))
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width
        guard width.isFinite, width > 1 else {
            let lineHeight = layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 15)) ?? 18
            return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lineHeight))
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: heightThatFits(width: width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        // 和容器宽度比，而不是和旧 frame 比：frame 没变时容器可能还停在某次试探宽度上
        let containerWidth = textContainer?.containerSize.width ?? 0
        let widthChanged = abs(containerWidth - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            textContainer?.containerSize = NSSize(width: max(1, newSize.width),
                                                   height: CGFloat.greatestFiniteMagnitude)
            invalidateIntrinsicContentSize()
        }
    }

    /// NSTextView 的 mouseDown 自己跑一整个鼠标跟踪循环，**mouseUp 永远到不了这个视图**。
    /// 以前点词逻辑写在 mouseUp 里，所以单击单词从来没触发过，只有拖选能用。
    /// 现在等 super.mouseDown 返回（此时鼠标已经松开、选区已经定了）再判断是点还是选。
    override func mouseDown(with event: NSEvent) {
        let downPoint = convert(event.locationInWindow, from: nil)
        mouseDownPoint = downPoint
        didDrag = false
        let clickCount = event.clickCount

        super.mouseDown(with: event)          // 阻塞到松开鼠标

        if let upEvent = NSApp.currentEvent, upEvent.type == .leftMouseUp {
            let upPoint = convert(upEvent.locationInWindow, from: nil)
            didDrag = abs(upPoint.x - downPoint.x) > 3 || abs(upPoint.y - downPoint.y) > 3
        }

        // 拖选或双击选中了一个词：按选区提交（双击的第一击已经单击提交过，第二击不重复）
        if selectedWord != nil {
            if didDrag || clickCount == 1 { _ = commitSelectedWord() }
            return
        }
        guard !didDrag, clickCount == 1 else { return }
        tapWord(at: downPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - mouseDownPoint.x) > 3 || abs(point.y - mouseDownPoint.y) > 3 {
            didDrag = true
        }
        super.mouseDragged(with: event)
    }

    /// 单击点到的那个词 → 发音 + 语境释义（由 onTapWord 的接收方处理）
    private func tapWord(at viewPoint: NSPoint) {
        guard let container = textContainer, let layout = layoutManager else { return }
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyph = layout.glyphIndex(for: containerPoint, in: container)
        guard glyph < layout.numberOfGlyphs else { return }
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return }
        let character = layout.characterIndexForGlyph(at: glyph)
        if let word = WordSelection.word(atUTF16Index: character, in: string) {
            onTapWord?(word)
        }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let hasCommandModifier = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
        if isReturn, !hasCommandModifier, commitSelectedWord() { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard selectedWord != nil else { return menu }
        let identifier = NSUserInterfaceItemIdentifier("EchoLine.AnalyseSelectedWord")
        let separatorIdentifier = NSUserInterfaceItemIdentifier("EchoLine.AnalyseSelectedWord.Separator")
        for existing in menu.items.filter({ $0.identifier == identifier || $0.identifier == separatorIdentifier }) {
            menu.removeItem(existing)
        }
        let item = NSMenuItem(title: "查看单词分析",
                              action: #selector(analyseSelectedWord(_:)),
                              keyEquivalent: "")
        item.target = self
        item.identifier = identifier
        menu.insertItem(item, at: 0)
        if menu.items.count > 1 {
            let separator = NSMenuItem.separator()
            separator.identifier = separatorIdentifier
            menu.insertItem(separator, at: 1)
        }
        return menu
    }

    fileprivate func commitSelectedWord() -> Bool {
        guard let word = selectedWord else {
            AccessibilityNotification.Announcement("请先选择一个英文单词").post()
            return false
        }
        AccessibilityNotification.Announcement("正在分析 \(word)").post()
        onSelectWord?(word)
        return true
    }

    private var selectedWord: String? {
        let selection = selectedRange()
        guard selection.length > 0,
              NSMaxRange(selection) <= (string as NSString).length else { return nil }
        return WordSelection.singleWord(from: (string as NSString).substring(with: selection))
    }

    @objc private func analyseSelectedWord(_ sender: Any?) {
        _ = commitSelectedWord()
    }
}

/// 自动换行布局
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
