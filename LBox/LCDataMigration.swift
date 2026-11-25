import Foundation

/// 记录「更新前的数据容器」，并在 LiveContainer 重建容器之后把旧数据补进去。
///
/// 为什么不继续用「把旧 plist 整份塞进新包」：
/// 1. `LCAppInfo.plist` 里既存「数据指向」（`LCContainers` / `LCDataUUID`），也存
///    「二进制准备状态」（`LCPatchRevision`、`dontSign` …）。整份搬过去会让
///    LiveContainer 以为新二进制已经打过补丁，于是直接 `dlopen` 一个 `MH_EXECUTE`，
///    报 `cannot dlopen a main executable`。
/// 2. 就算只搬数据键，LC 也可能因为内部结构变化而忽略 / 重置这份 plist，静默新建
///    一个空容器 —— 这就是「更新后数据没了」。
///
/// 所以改成数据层兜底：先记下旧容器的 `folderName`，等 LC 自己把新容器建好，
/// 再把旧容器里的 `Documents` / `Library` 合并进新容器。全程不伪造 LC 的内部状态，
/// 因此不管 LC 认不认我们写的 plist，数据最终都能回到 App 手里。
@MainActor
final class LCDataMigration {
    static let shared = LCDataMigration()

    struct Record: Codable, Sendable {
        var bundleID: String
        var appName: String
        /// App 在 Applications 目录里的名字（xxx.app）
        var installPath: String
        /// 旧数据容器的目录名（Data/Application/<folderName>）
        var folderNames: [String]
        var created: Date
    }

    private var records: [String: Record] = [:]
    private var loaded = false

    private var ledgerURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("LCDataMigration.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: ledgerURL),
              let list = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in list {
            // 超过 7 天的记录没有任何补救价值，直接丢掉，免得无限重试。
            guard Date().timeIntervalSince(record.created) < 7 * 24 * 3600 else { continue }
            records[Self.key(record)] = record
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(records.values)) else { return }
        try? data.write(to: ledgerURL, options: .atomic)
    }

    private static func key(_ record: Record) -> String {
        record.bundleID + "|" + record.installPath
    }

    // MARK: - 更新前：登记旧容器

    /// 在替换安装包之前调用。plist 不存在 / 没有容器时返回 false。
    @discardableResult
    func remember(plistURL: URL, bundleID: String, appName: String, installPath: String) -> Bool {
        loadIfNeeded()
        guard let names = Self.containerNames(inPlistAt: plistURL), !names.isEmpty else { return false }
        let record = Record(
            bundleID: bundleID,
            appName: appName,
            installPath: installPath,
            folderNames: names,
            created: Date()
        )
        records[Self.key(record)] = record
        save()
        return true
    }

    // MARK: - 更新后：把旧数据补进新容器

    /// 回到前台 / 安装完成后调用。返回这次真正把数据补回去的 App 名。
    func reconcile(appsFolder: URL, dataRoot: URL) async -> [String] {
        loadIfNeeded()
        guard !records.isEmpty else { return [] }

        let snapshot = Array(records.values)
        let appsPath = appsFolder.path
        let rootPath = dataRoot.path

        let finished: [String] = await Task.detached(priority: .utility) { () -> [String] in
            var done: [String] = []
            for record in snapshot {
                let appURL = URL(fileURLWithPath: appsPath).appendingPathComponent(record.installPath)
                let plistURL = appURL.appendingPathComponent("LCAppInfo.plist")
                guard let newEntries = Self.containerEntries(inPlistAt: plistURL), !newEntries.isEmpty else {
                    // LC 还没跑过这个 App（没有 plist）——留在记录里，下次前台再试。
                    continue
                }
                // 已经是同一批容器：LC 接受了我们写入的数据指向，不需要搬。
                let newNames = newEntries.compactMap { $0["folderName"] as? String }
                if !Set(newNames).isDisjoint(with: Set(record.folderNames)) {
                    done.append(record.appName)
                    continue
                }

                var copied = false
                var oldFolderExists = false
                for (index, oldFolder) in record.folderNames.enumerated() {
                    guard index < newNames.count else { break }
                    let from = URL(fileURLWithPath: rootPath).appendingPathComponent(oldFolder)
                    let to = URL(fileURLWithPath: rootPath).appendingPathComponent(newNames[index])
                    guard FileManager.default.fileExists(atPath: from.path),
                          FileManager.default.fileExists(atPath: to.path) else { continue }
                    oldFolderExists = true
                    if Self.mergeContents(from: from, to: to) { copied = true }
                }
                // 旧容器已经不在了 = 没什么可恢复的，删掉记录别再重试。
                if copied || !oldFolderExists { done.append(record.appName) }
            }
            return done
        }.value

        guard !finished.isEmpty else { return [] }
        for name in finished {
            records = records.filter { $0.value.appName != name }
        }
        save()
        return finished
    }

    /// 便于排查：还有多少个 App 在等 LC 建容器。
    var pendingAppNames: [String] {
        loadIfNeeded()
        return records.values.map(\.appName)
    }

    // MARK: - plist 读取（不进入任何 actor）

    nonisolated private static func containerNames(inPlistAt url: URL) -> [String]? {
        guard let entries = containerEntries(inPlistAt: url) else { return nil }
        let names = entries.compactMap { $0["folderName"] as? String }
        return names.isEmpty ? nil : names
    }

    nonisolated private static func containerEntries(inPlistAt url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entries = plist["LCContainers"] as? [[String: Any]] else { return nil }
        return entries
    }

    // MARK: - 合并复制

    /// 递归合并：目标已存在的文件不覆盖（避免冲掉新版本写入的配置），
    /// 只补旧版本有、新容器没有的内容。
    nonisolated private static func mergeContents(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        let skipped: Set<String> = ["Caches", "tmp", ".Trash"]
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return false
        }
        var ok = false
        for item in items {
            if skipped.contains(item.lastPathComponent) { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var sourceIsDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &sourceIsDir)
            var targetIsDir: ObjCBool = false
            let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)

            if sourceIsDir.boolValue && targetExists && targetIsDir.boolValue {
                if mergeContents(from: item, to: target) { ok = true }
            } else if sourceIsDir.boolValue && !targetExists {
                if (try? fm.copyItem(at: item, to: target)) != nil { ok = true }
            } else if !sourceIsDir.boolValue && !targetExists {
                if (try? fm.copyItem(at: item, to: target)) != nil { ok = true }
            }
            // 目标已存在同名文件：保留新版本自己的，跳过。
        }
        return ok
    }
}
