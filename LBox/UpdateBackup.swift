import Foundation

/// Snapshots an installed app (and optionally its data container) before LiveContainer replaces it.
///
/// The `.app` only carries the program plus `LCAppInfo.plist`, which is a *pointer* to the data
/// container. Rolling back therefore restores the program, not the data — unless the full
/// snapshot option is on, in which case the container contents are copied too.
enum UpdateBackup {
    static var appBackupEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kBackupAppBeforeUpdate")
    }

    static var fullSnapshotEnabled: Bool {
        UserDefaults.standard.bool(forKey: "kBackupFullSnapshot")
    }

    /// Copies the bundle into `<backupRoot>/<uuid>/` and returns the uuid, or nil when disabled
    /// or the copy failed.
    ///
    /// The copy runs off the main actor: installed apps can be well over a gigabyte and blocking
    /// the main thread for that long gets the app watchdog-killed.
    static func snapshot(app: LocalApp, backupRoot: URL, dataRoot: URL?) async -> String? {
        guard appBackupEnabled else { return nil }
        let full = fullSnapshotEnabled
        let uuid = UUID().uuidString
        let appURL = app.url
        let folders = containerFolders(in: appURL)

        let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
            let fm = FileManager.default
            let folder = backupRoot.appendingPathComponent(uuid, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
                try fm.copyItem(at: appURL, to: destination)

                if full, let dataRoot {
                    let dataFolder = folder.appendingPathComponent("Data", isDirectory: true)
                    for name in folders {
                        let source = dataRoot.appendingPathComponent(name, isDirectory: true)
                        guard fm.fileExists(atPath: source.path) else { continue }
                        try? fm.createDirectory(at: dataFolder, withIntermediateDirectories: true)
                        let target = dataFolder.appendingPathComponent(name, isDirectory: true)
                        try? fm.copyItem(at: source, to: target)
                    }
                }
                return true
            } catch {
                try? fm.removeItem(at: folder)
                return false
            }
        }.value

        Logger.shared.log("Backup: \(app.name) \(full ? "(full)" : "(app only)") \(copied ? "ok" : "failed")")
        return copied ? uuid : nil
    }

    /// Puts the snapshot data back after a rollback. No-op when the snapshot is app-only.
    static func restoreData(appURL: URL, snapshotFolder: URL, dataRoot: URL) {
        let fm = FileManager.default
        let dataFolder = snapshotFolder.appendingPathComponent("Data", isDirectory: true)
        guard fm.fileExists(atPath: dataFolder.path) else { return }

        for name in containerFolders(in: appURL) {
            let source = dataFolder.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = dataRoot.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: source, to: destination)
            Logger.shared.log("Rollback: restored data container \(name)")
        }
    }

    /// Container folder names recorded in the bundle's LCAppInfo.plist.
    static func containerFolders(in appURL: URL) -> [String] {
        let plistURL = appURL.appendingPathComponent("LCAppInfo.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["LCContainers"] as? [[String: Any]] else { return [] }
        return containers.compactMap { $0["folderName"] as? String }
    }
}
