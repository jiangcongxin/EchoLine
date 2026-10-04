import Foundation
import SwiftUI

/// iCloud 同步引擎（Mac 端）：直接读写 iCloud Drive 用户可见目录
/// ~/Library/Mobile Documents/com~apple~CloudDocs/EchoSync，
/// 与 iPhone 端 IELTSMate 交换 JSON。EchoLine 未开沙盒，无需任何 entitlement。
///
/// 同步内容：句库 sentences.json、生词 collectedWords.json、跟读成绩 attempts.json
/// （本地叫 shadowAttempts.json）、串文 digest.json、删除墓碑 tombstones.json。
/// 录音音频与缓存类数据（glossCache/tts）不同步。
///
/// 收敛方式：每轮「拉取云端 → 与本地按 id 并集合并 → 回写云端」，两端最终一致。
@MainActor
final class SyncEngine: ObservableObject {

    static let shared = SyncEngine()

    @Published private(set) var syncing = false
    @Published private(set) var status = "未开启"
    @Published private(set) var lastSync: Date?
    @AppStorage("icloudSyncOn") var syncOn = false

    static let cloudRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static let folderName = "EchoSync"

    /// 参与同步的云文件
    private static let dataFiles = ["sentences.json", "collectedWords.json", "attempts.json", "digest.json"]
    private static let tombFile = "tombstones.json"

    enum Kind { case sentences, words, attempts }

    /// 删除墓碑：id 字符串 -> 删除时间。防止「一端删除、另一端同步时又复活」
    struct TombstoneSet: Codable {
        var sentences: [String: Date] = [:]
        var words: [String: Date] = [:]
        var attempts: [String: Date] = [:]
    }

    var iCloudAvailable: Bool { FileManager.default.fileExists(atPath: Self.cloudRoot.path) }
    var enabled: Bool { syncOn && iCloudAvailable }
    var cloudDir: URL { Self.cloudRoot.appendingPathComponent(Self.folderName, isDirectory: true) }
    var cloudPathDisplay: String { "iCloud 云盘 / \(Self.folderName)" }

    private var tombstones = TombstoneSet()
    private var signatures: [String: String] = [:]     // 云文件签名（mtime+size），察觉远端变动用
    private var pushTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var dirty = false

    private let localTombURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EchoLine", isDirectory: true)
        .appendingPathComponent("syncTombstones.json")

    // MARK: - 生命周期

    /// App 启动时调用：载墓碑；若已开启则建文件夹、起轮询、做首轮同步
    func start() {
        loadLocalTombstones()
        guard syncOn else { status = "未开启"; return }
        guard prepareFolder() else { return }
        startPolling()
        Task { await syncNow() }
    }

    /// 回到前台：做一轮完整同步（文件都不大，成本可忽略）
    func appBecameActive() {
        guard enabled else { return }
        Task { await syncNow() }
    }

    /// 设置页开关
    func setOn(_ on: Bool) {
        if on {
            guard iCloudAvailable else {
                status = "未检测到 iCloud 云盘，请在系统设置登录 Apple 账户并开启 iCloud 云盘"
                return
            }
            guard prepareFolder() else { return }
            syncOn = true
            status = "已开启"
            startPolling()
            Task { await syncNow() }
        } else {
            syncOn = false
            pollTimer?.invalidate()
            pushTask?.cancel()
            status = "未开启"
        }
    }

    @discardableResult
    private func prepareFolder() -> Bool {
        do {
            try FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
            return true
        } catch {
            status = "无法创建同步文件夹：\(error.localizedDescription)"
            return false
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pullIfRemoteChanged() }
        }
    }

    // MARK: - 本地改动入口（EchoStore 调用）

    /// 本地保存了参与同步的文件：防抖后推一轮
    func noteLocalChange() {
        guard enabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// 本地删除：记墓碑（并防抖推送）。同步未开启时不记——
    /// 关闭期间删除的条目不会传播到另一端，重新开启后按两端现存数据合并
    func recordDeletion(_ kind: Kind, ids: [UUID]) {
        guard enabled else { return }
        for id in ids {
            switch kind {
            case .sentences: tombstones.sentences[id.uuidString] = .now
            case .words: tombstones.words[id.uuidString] = .now
            case .attempts: tombstones.attempts[id.uuidString] = .now
            }
        }
        saveLocalTombstones()
        noteLocalChange()
    }

    // MARK: - 主同步流程

    func syncNow() async {
        guard enabled else { return }
        guard !syncing else { dirty = true; return }
        syncing = true
        status = "同步中…"
        defer { syncing = false }

        let store = EchoStore.shared
        let dir = cloudDir

        // 1. 拉取云端
        async let cSent = readCloud("sentences.json", as: [EchoSentence].self, in: dir)
        async let cWords = readCloud("collectedWords.json", as: [CollectedWord].self, in: dir)
        async let cAtt = readCloud("attempts.json", as: [ShadowAttempt].self, in: dir)
        async let cDigest = readCloud("digest.json", as: WeaveDigest.self, in: dir)
        async let cTomb = readCloud(Self.tombFile, as: TombstoneSet.self, in: dir)
        let (cloudSent, cloudWords, cloudAtt, cloudDigest, cloudTomb) = await (cSent, cWords, cAtt, cDigest, cTomb)

        // 2. 合并（墓碑先并集，再过滤数据）
        let tomb = mergeTombstones(tombstones, cloudTomb ?? TombstoneSet())
        let tombS = Set(tomb.sentences.keys.compactMap { UUID(uuidString: $0) })
        let tombW = Set(tomb.words.keys.compactMap { UUID(uuidString: $0) })
        let tombA = Set(tomb.attempts.keys.compactMap { UUID(uuidString: $0) })

        let mergedSent = mergeSentences(store.sentences, cloudSent ?? [], tomb: tombS)
        let mergedWords = mergeWords(store.collectedWords, cloudWords ?? [], tomb: tombW)
        let mergedAtt = mergeAttempts(store.shadowAttempts, cloudAtt ?? [], tomb: tombA)
        let mergedDigest = pickDigest(store.digest, cloudDigest)

        // 3. 回写本地（不再触发推送）
        store.applySync(sentences: mergedSent, words: mergedWords, attempts: mergedAtt, digest: mergedDigest)
        tombstones = tomb
        saveLocalTombstones()

        // 4. 合并结果推回云端，让两端文件收敛
        writeCloud(mergedSent, "sentences.json", in: dir)
        writeCloud(mergedWords, "collectedWords.json", in: dir)
        writeCloud(mergedAtt, "attempts.json", in: dir)
        writeCloud(mergedDigest, "digest.json", in: dir)
        writeCloud(tomb, Self.tombFile, in: dir)

        lastSync = .now
        status = "已同步（句 \(mergedSent.count) · 词 \(mergedWords.count)）"
        updateSignatures(in: dir)

        if dirty {   // 同步期间又有本地改动，补一轮
            dirty = false
            await syncNow()
        }
    }

    /// 定时轮询：签名变了说明远端（iPhone 端）写入了新版本
    private func pullIfRemoteChanged() {
        guard enabled, !syncing else { return }
        for f in Self.dataFiles + [Self.tombFile] {
            if signature(of: cloudDir.appendingPathComponent(f)) != signatures[f] {
                Task { await syncNow() }
                return
            }
        }
    }

    // MARK: - 合并规则（与 iOS 端语义一致，保证收敛）

    private func mergeSentences(_ local: [EchoSentence], _ cloud: [EchoSentence], tomb: Set<UUID>) -> [EchoSentence] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in cloud {
            byID[c.id] = byID[c.id].map { pickSentence($0, c) } ?? c
        }
        return byID.values.filter { !tomb.contains($0.id) }.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// 同一句两端都有：有解读的优先，都没有/都有则新的优先，平手取本地（防抖）；
    /// 星标取或、标签取并集——这三类编辑永不互相覆盖
    private func pickSentence(_ l: EchoSentence, _ c: EchoSentence) -> EchoSentence {
        var base: EchoSentence
        switch (l.analysis != nil, c.analysis != nil) {
        case (true, false): base = l
        case (false, true): base = c
        default: base = c.dateAdded > l.dateAdded ? c : l
        }
        base.starred = l.starred || c.starred
        var tags: [String] = []
        for t in l.tags + c.tags where !tags.contains(t) { tags.append(t) }
        base.tags = tags
        if base.source.isEmpty { base.source = l.source.isEmpty ? c.source : l.source }
        return base
    }

    private func mergeWords(_ local: [CollectedWord], _ cloud: [CollectedWord], tomb: Set<UUID>) -> [CollectedWord] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in cloud {
            byID[c.id] = byID[c.id].map { pickWord($0, c) } ?? c
        }
        return byID.values.filter { !tomb.contains($0.id) }.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// 同一词：复习进度（reps，iOS 端维护）走远的优先，平手新的优先；可选字段取长补短
    private func pickWord(_ l: CollectedWord, _ c: CollectedWord) -> CollectedWord {
        var base: CollectedWord
        let other: CollectedWord
        if (l.reps, l.dateAdded) >= (c.reps, c.dateAdded) { base = l; other = c } else { base = c; other = l }
        if base.topic == nil { base.topic = other.topic }
        if base.priority == nil { base.priority = other.priority }
        if base.group == nil { base.group = other.group }
        if base.memoryAid == nil { base.memoryAid = other.memoryAid }
        if base.sentenceZH.isEmpty { base.sentenceZH = l.sentenceZH.isEmpty ? c.sentenceZH : l.sentenceZH }
        return base
    }

    private func mergeAttempts(_ local: [ShadowAttempt], _ cloud: [ShadowAttempt], tomb: Set<UUID>) -> [ShadowAttempt] {
        var byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in cloud {
            byID[c.id] = byID[c.id].map { pickAttempt($0, c) } ?? c
        }
        return byID.values.filter { !tomb.contains($0.id) }.sorted { $0.date > $1.date }
    }

    /// 同一次跟读：有 AI 点评的优先，否则新的优先
    private func pickAttempt(_ l: ShadowAttempt, _ c: ShadowAttempt) -> ShadowAttempt {
        switch (l.review != nil, c.review != nil) {
        case (true, false): return l
        case (false, true): return c
        default: return c.date > l.date ? c : l
        }
    }

    private func pickDigest(_ l: WeaveDigest?, _ c: WeaveDigest?) -> WeaveDigest? {
        switch (l, c) {
        case let (l?, c?): return c.date > l.date ? c : l
        case let (l?, nil): return l
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    private func mergeTombstones(_ a: TombstoneSet, _ b: TombstoneSet) -> TombstoneSet {
        func m(_ x: [String: Date], _ y: [String: Date]) -> [String: Date] {
            var r = x
            for (k, v) in y { r[k] = r[k].map { max($0, v) } ?? v }
            if r.count > 2000 {   // 封顶防膨胀：留最新的 2000 条
                r = Dictionary(uniqueKeysWithValues: r.sorted { $0.value > $1.value }.prefix(2000).map { ($0.key, $0.value) })
            }
            return r
        }
        return TombstoneSet(sentences: m(a.sentences, b.sentences),
                            words: m(a.words, b.words),
                            attempts: m(a.attempts, b.attempts))
    }

    // MARK: - 云端读写

    /// 读云文件；文件被 iCloud 优化掉（未下载）时触发下载并重试
    private func readCloud<T: Decodable>(_ file: String, as type: T.Type, in dir: URL) async -> T? {
        let url = dir.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var data = try? Data(contentsOf: url)
        if data == nil {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            for _ in 0..<5 where data == nil {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                data = try? Data(contentsOf: url)
            }
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 写云文件：先写临时文件再替换，避免半写状态被另一端读到
    private func writeCloud<T: Encodable>(_ value: T, _ file: String, in dir: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = dir.appendingPathComponent(file)
        let tmp = dir.appendingPathComponent(".\(file).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            status = "写入 iCloud 失败：\(error.localizedDescription)"
        }
    }

    private func signature(of url: URL) -> String {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let m = v.contentModificationDate else { return "absent" }
        return "\(m.timeIntervalSince1970)-\(v.fileSize ?? -1)"
    }

    private func updateSignatures(in dir: URL) {
        for f in Self.dataFiles + [Self.tombFile] {
            signatures[f] = signature(of: dir.appendingPathComponent(f))
        }
    }

    // MARK: - 墓碑本地持久化

    private func saveLocalTombstones() {
        if let data = try? JSONEncoder().encode(tombstones) {
            try? data.write(to: localTombURL, options: .atomic)
        }
    }

    private func loadLocalTombstones() {
        guard let data = try? Data(contentsOf: localTombURL) else { return }
        tombstones = (try? JSONDecoder().decode(TombstoneSet.self, from: data)) ?? TombstoneSet()
    }
}
