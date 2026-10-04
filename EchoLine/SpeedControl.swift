import SwiftUI

/// 语速调节：工具栏 / 练习窗口里的一个小按钮，点开是预设档 + 滑杆 + 试听。
/// 改动立刻作用在正在播放的云端音频上（播放器变速，音调不变）。
struct SpeedControl: View {
    var compact = false
    @EnvironmentObject private var store: EchoStore
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(store.speedLabel).monospacedDigit()
            }
            .font(compact ? .caption : .callout)
            .foregroundStyle(abs(store.speedMultiplier - 1) < 0.001 ? Theme.dim : Theme.ice)
        }
        .buttonStyle(.plain)
        .help("朗读语速 \(store.speedLabel)（⌘[ 慢一点 · ⌘] 快一点）")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SpeedPopover().environmentObject(store)
        }
    }
}

private struct SpeedPopover: View {
    @EnvironmentObject private var store: EchoStore

    private let sample = "Regular exercise improves both physical and mental health."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("朗读语速").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text(store.speedLabel)
                    .font(Theme.mono(22, .heavy))
                    .foregroundStyle(Theme.ice)
                    .contentTransition(.numericText())
            }

            FlowRow(spacing: 6) {
                ForEach(EchoStore.speedPresets, id: \.self) { m in
                    let selected = abs(m - store.speedMultiplier) < 0.001
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { store.setSpeed(m) }
                    } label: {
                        Text(EchoStore.speedLabel(m))
                            .font(Theme.mono(12, selected ? .bold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(selected ? Theme.ice : Theme.panel2, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(selected ? Theme.paper : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "tortoise").foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { store.speedMultiplier }, set: { store.setSpeed($0) }),
                       in: 0.5...1.5, step: 0.05)
                Image(systemName: "hare").foregroundStyle(Theme.dim)
            }

            HStack {
                Button {
                    Speech.shared.speak(sample, rate: store.speechRate)
                } label: {
                    Label("试听", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
                Button("恢复 1.0×") { store.setSpeed(1) }
                    .buttonStyle(WorkbenchButtonStyle(kind: .ghost, small: true))
                    .disabled(abs(store.speedMultiplier - 1) < 0.001)
                Spacer()
            }

            Text("精听、跟读难句用 0.7–0.8×；熟了回到 1.0×，再用 1.1–1.25× 练反应。「慢速」按钮 = 当前语速的 70%。⌘[ / ⌘] 随时调。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.bg)
    }
}
