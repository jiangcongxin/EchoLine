import SwiftUI
import AppKit

/// 仿写练习面板：看范本句 → 照句式写自己的句子 → AI 批改（分数 + 词级 diff + 错误分类 + 总评）
/// 红线：批改结果绝不自动入句库，只有用户点「收进句库」才静默插入 AI 修改后的版本
struct PracticeView: View {
    let model: String                       // 范本句

    @EnvironmentObject var store: EchoStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var speech = Speech.shared

    @State private var draft = ""
    @State private var submitting = false
    @State private var submittedText: String? = nil      // diff 要钉住提交时的快照，不能跟输入框联动
    @State private var result: WritingCorrection? = nil
    @State private var collected = false
    @State private var errorMessage: String? = nil

    private var aiReady: Bool { !store.aiKey.isEmpty }

    private var canSubmit: Bool {
        aiReady && !submitting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（同跟读面板风格）
            HStack {
                Label("仿写练习", systemImage: "pencil.line")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Esc 关闭
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modelCard
                    if aiReady {
                        inputCard
                    } else {
                        noKeyCard
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let r = result {
                        resultCard(r)
                        if !r.errors.isEmpty { errorsCard(r) }
                        collectCard(r)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 560, idealHeight: 660)
        .onDisappear { speech.stop() }
    }

    // MARK: 范本句

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model)
                .font(.system(.title3, design: .serif))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                Button {
                    speech.speak(model, rate: store.speechRate)
                } label: {
                    Label("听原声", systemImage: "play.circle.fill")
                }
                .foregroundStyle(Theme.ice)
                Button {
                    speech.speak(model, rate: store.slowRate)
                } label: {
                    Label("慢速", systemImage: "tortoise")
                }
                .foregroundStyle(.secondary)
                Spacer()
                Text("照着这个句式，写一句你自己的")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 输入区

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 15, design: .serif))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                if draft.isEmpty {
                    Text("在这里写你的句子…")
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("⌘↩ 提交")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if submitting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(store.aiConfig.providerName) 批改中…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Label(result == nil ? "提交批改" : "重新提交",
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.ice)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    private var noKeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要 AI 才能批改", systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(Theme.verb)
            Text("打开 设置（⌘,）→ AI 解读，选择服务商并填入 API Key，再回来仿写。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 结果：分数 + 总评 + 词级 diff + 修改后句子

    private func scoreColor(_ score: Int) -> Color {
        if score >= 90 { return Theme.ice }
        if score >= 70 { return Theme.verb }
        return Theme.wrong
    }

    private func resultCard(_ r: WritingCorrection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(r.score)")
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundStyle(scoreColor(r.score))
                Text("/ 100").foregroundStyle(.secondary)
                Spacer()
                if !r.source.isEmpty {
                    Text("\(r.source) 批改").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if !r.comment.isEmpty {
                Text(r.comment).font(.callout).lineSpacing(4)
            }

            if let submitted = submittedText, r.corrected != submitted {
                VStack(alignment: .leading, spacing: 4) {
                    Text("逐词对比（红删绿增）").font(.caption2).foregroundStyle(.tertiary)
                    DiffText(ops: WordDiff.align(source: submitted, target: r.corrected))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("修改后").font(.caption2).foregroundStyle(.tertiary)
                Text(r.corrected)
                    .font(.system(size: 16, design: .serif))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ice.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 错误分类列表

    private func errorsCard(_ r: WritingCorrection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("错在哪", systemImage: "list.bullet.rectangle")
                .font(.footnote).foregroundStyle(Theme.ice)
            ForEach(r.errors, id: \.self) { e in
                HStack(alignment: .top, spacing: 8) {
                    Text(e.type)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.ice.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.ice)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.wrong)
                                .strikethrough()
                                .foregroundStyle(Theme.wrong)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(e.fix)
                                .foregroundStyle(Theme.right)
                        }
                        .font(.callout.weight(.medium))
                        if !e.note.isEmpty {
                            Text(e.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 手动收库（唯一入口，绝不自动）

    private func collectCard(_ r: WritingCorrection) -> some View {
        HStack {
            Button {
                store.insertQuietly(r.corrected, source: "仿写练习")
                withAnimation { collected = true }
            } label: {
                Label(collected ? "已收进句库 ✓" : "收进句库",
                      systemImage: collected ? "checkmark.circle.fill" : "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(collected ? Color.secondary : Theme.ice)
            .disabled(collected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: 逻辑

    private func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submitting = true
        errorMessage = nil
        do {
            let r = try await AIService.correct(writing: text, model: model, config: store.aiConfig)
            submittedText = text
            result = r
            collected = false          // 新一轮结果，收库状态归零
        } catch {
            errorMessage = error.localizedDescription
        }
        submitting = false
    }
}

// MARK: - 词级 diff 渲染（WrapLayout 流式排列）

private struct DiffText: View {
    let ops: [WordDiff.Op]

    private let red = Theme.wrong
    private let green = Theme.right

    var body: some View {
        WrapLayout(spacing: 5) {
            ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                switch op {
                case .keep(let w):
                    Text(w).foregroundStyle(.primary)
                case .delete(let w):
                    Text(w).strikethrough().foregroundStyle(red)
                case .insert(let w):
                    Text(w).foregroundStyle(green)
                case .substitute(let wrong, let fix):
                    HStack(spacing: 4) {
                        Text(wrong).strikethrough().foregroundStyle(red)
                        Text(fix).foregroundStyle(green)
                    }
                }
            }
        }
        .font(.system(size: 15, design: .serif))
    }
}
