import SwiftUI

// MARK: - 跟读总表：练过的每一句一行，最近一次的分数、历史走势、A/B 回放、再练

struct PracticePane: View {
    @EnvironmentObject var store: EchoStore
    @ObservedObject private var rec = RecordingService.shared
    @State private var shadowTarget: TodayPane.ShadowTarget?
    @State private var filter: Filter = .weak

    enum Filter: String, CaseIterable, Identifiable {
        case weak = "没读好的"
        case recent = "最近练的"
        case all = "全部"
        var id: String { rawValue }
    }

    /// 同一个 target 的所有跟读，新的在前
    private struct Track: Identifiable {
        let target: String
        let attempts: [ShadowAttempt]
        var id: String { target }
        var latest: ShadowAttempt { attempts[0] }
        var best: Int { attempts.map(\.accuracy).max() ?? 0 }
        /// 最近一次比上一次涨了多少
        var delta: Int? { attempts.count > 1 ? attempts[0].accuracy - attempts[1].accuracy : nil }
    }

    private var tracks: [Track] {
        let groups = Dictionary(grouping: store.shadowAttempts, by: \.target)
        let all = groups.map { Track(target: $0.key, attempts: $0.value.sorted { $0.date > $1.date }) }
        switch filter {
        case .weak:
            return all.filter { $0.best < 85 }.sorted { $0.best < $1.best }
        case .recent:
            return all.sorted { $0.latest.date > $1.latest.date }.prefix(30).map { $0 }
        case .all:
            return all.sorted { $0.latest.date > $1.latest.date }
        }
    }

    private var weekAttempts: [ShadowAttempt] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return store.shadowAttempts.filter { $0.date >= start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("跟读 · 共 \(store.shadowAttempts.count) 次")
                    Text("听原声，听自己")
                        .font(.system(size: 34, weight: .black)).foregroundStyle(Theme.ink)
                    Text("红色的词是离线识别听不出的——多半就是没读准的地方。划段浮窗和句子页里录的都会出现在这里。")
                        .font(.callout).foregroundStyle(Theme.dim)
                }
                tiles
                WorkbenchPanel {
                    HStack {
                        Text("练过的句子").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Picker("", selection: $filter) {
                            ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    let list = tracks
                    if list.isEmpty {
                        Text(store.shadowAttempts.isEmpty
                             ? "还没录过。划一段英文，在预览浮窗里按 R 录一遍就会出现在这里。"
                             : "这一栏是空的——换个筛选看看。")
                            .font(.callout).foregroundStyle(Theme.dim).padding(.vertical, 8)
                    }
                    ForEach(list) { t in trackRow(t) }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WorkbenchBackground())
        .sheet(item: $shadowTarget) { t in
            ShadowingView(target: t.text).environmentObject(store)
        }
        .onDisappear { rec.stopPlayback() }
    }

    private var tiles: some View {
        let week = weekAttempts
        let avg = week.isEmpty ? nil : week.map(\.accuracy).reduce(0, +) / week.count
        let weak = Dictionary(grouping: store.shadowAttempts, by: \.target)
            .values.filter { ($0.map(\.accuracy).max() ?? 0) < 85 }.count
        return HStack(spacing: 16) {
            StatTile(label: "本周均分", value: avg.map(String.init) ?? "—", unit: "",
                     note: "本周 \(week.count) 次", style: .hero,
                     progress: avg.map { Double($0) / 100 })
            StatTile(label: "练过的句子", value: "\(Set(store.shadowAttempts.map(\.target)).count)", unit: "句",
                     note: "累计 \(store.shadowAttempts.count) 次")
            StatTile(label: "还没读好", value: "\(weak)", unit: "句", note: "最好成绩低于 85 分", style: .amber)
        }
    }

    private func scoreColor(_ s: Int) -> Color {
        s >= 90 ? Theme.ice : (s >= 70 ? Theme.verb : Theme.wrong)
    }

    private func trackRow(_ t: Track) -> some View {
        let latest = t.latest
        let bad = ShadowBadWords.of(latest)
        let playingMine = rec.isPlayingMine && rec.playingFile == latest.fileName
        return HStack(alignment: .center, spacing: 16) {
            Text("\(latest.accuracy)")
                .font(Theme.mono(24, .heavy))
                .foregroundStyle(scoreColor(latest.accuracy))
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(t.target)
                    .font(.system(size: 15, design: .serif)).foregroundStyle(Theme.ink)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text("\(t.attempts.count) 次 · 最好 \(t.best)")
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    if let d = t.delta {
                        Text(d >= 0 ? "▲ \(d)" : "▼ \(-d)")
                            .font(Theme.mono(11)).foregroundStyle(d >= 0 ? Theme.right : Theme.wrong)
                    }
                    Text(latest.date.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(Theme.dim)
                    if !bad.isEmpty {
                        Text("没读准：\(bad.prefix(4).joined(separator: " · "))")
                            .font(.caption).foregroundStyle(Theme.wrong).lineLimit(1)
                    }
                }
                Sparkline(values: t.attempts.reversed().map(\.accuracy))
                    .frame(width: 140, height: 18)
            }
            Spacer(minLength: 8)
            Button {
                rec.stopPlayback()
                Speech.shared.speak(t.target, rate: store.speechRate)
            } label: {
                Label("原声", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
            Button {
                if playingMine {
                    rec.stopPlayback()
                } else {
                    Speech.shared.stop()
                    rec.playMine(latest.fileName)
                }
            } label: {
                Label(playingMine ? "停止" : "自己", systemImage: "person.wave.2.fill")
            }
            .buttonStyle(WorkbenchButtonStyle(kind: .normal, small: true))
            Button("再练") { shadowTarget = TodayPane.ShadowTarget(text: t.target) }
                .buttonStyle(WorkbenchButtonStyle(kind: .primary, small: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

/// 分数走势小折线：0-100，旧 → 新
struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let step = geo.size.width / CGFloat(values.count - 1)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: CGFloat(i) * step,
                                         y: geo.size.height * (1 - CGFloat(v) / 100))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(Theme.ice, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Capsule().fill(Theme.line).frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
