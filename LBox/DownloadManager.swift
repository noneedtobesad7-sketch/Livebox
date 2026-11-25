import Foundation
import SwiftUI
import Combine
import UserNotifications
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// Make Equatable for UI comparisons
enum DownloadStatus: Equatable {
    case downloading(progress: Double, written: Int64, total: Int64)
    case paused
    case waitingForConnection
    case none
}

enum InstallAction {
    case installSeparate
    case updateExisting
    case cancel
}

/// One entry of the download history shown in the Downloads tab.
struct DownloadRecord: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case finished
        case failed
        case cancelled
    }

    let id: String
    var url: String
    var fileName: String
    var state: State
    var date: Date
    var bytes: Int64
    var message: String?
}

struct PendingInstallation: Identifiable {
    let id = UUID()
    let appName: String
    let bundleID: String
    let tempPayloadURL: URL 
    let extractedAppURL: URL 
    let sourceArchiveURL: URL 
    let existingApp: LocalApp? 
}

struct AppBackup: Codable, Identifiable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let version: String?
    let backupPath: String 
    let originalInstallPath: String 
    let date: Date
    let hadLCAppInfo: Bool 
}

/// One entry of a batch update run.
struct BatchUpdateTarget: Identifiable, Hashable {
    var id: String { bundleID + "|" + downloadURL }
    let name: String
    let bundleID: String
    let downloadURL: String
    let isPrerelease: Bool
}

/// Re-attaches the LiveContainer data pointer of a previous install to the freshly deployed bundle.
///
/// LiveContainer keeps an app's per-app data in `Data/Application/<folderName>` and records the
/// folder name in `LCAppInfo.plist` *inside the .app folder*. A plain bundle replacement drops
/// that plist, so the next launch makes LiveContainer believe it is a brand new app and create an
/// empty container - which is what looked like "the update wiped my data".
///
/// Only `LCContainers` / `LCDataUUID` are carried over. Every other key describes how the
/// *previous* binary was prepared (`LCPatchRevision`, `dontSign`, `is32bit` ...). Copying those
/// makes LiveContainer believe the new binary is already patched, so it skips the patch step and
/// tries to dlopen a raw MH_EXECUTE - which fails with "cannot dlopen a main executable".
/// `LCDataMigration` reconciles the data on disk if LiveContainer ignores this plist anyway.
func migrateLCAppInfo(from oldAppURL: URL, to newAppURL: URL) -> Bool {
    let fm = FileManager.default
    let oldInfoURL = oldAppURL.appendingPathComponent("LCAppInfo.plist")
    let newInfoURL = newAppURL.appendingPathComponent("LCAppInfo.plist")

    guard fm.fileExists(atPath: oldInfoURL.path),
          let oldData = try? Data(contentsOf: oldInfoURL),
          let oldPlist = try? PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any],
          let containers = oldPlist["LCContainers"] as? [[String: Any]],
          !containers.isEmpty else {
        return false
    }

    var payload: [String: Any] = ["LCContainers": containers]
    if let dataUUID = oldPlist["LCDataUUID"] {
        payload["LCDataUUID"] = dataUUID
    }

    guard let patched = try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0) else {
        return false
    }
    do {
        try patched.write(to: newInfoURL, options: .atomic)
        print("MigrateLCAppInfo: attached \(containers.count) container(s) to \(newAppURL.lastPathComponent)")
        return true
    } catch {
        print("MigrateLCAppInfo failed: \(error)")
        return false
    }
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
    @Published var activeDownloads: [URL: Double] = [:]
    @Published var pausedDownloads: Set<URL> = []
    
    // Files in the Download Folder
    @Published var fileList: [URL] = []
    
    // Installed Apps in the Apps Folder
    @Published var installedApps: [LocalApp] = []
    
    // Files currently being extracted
    @Published var extractingFiles: Set<URL> = []
    
    @Published var customDownloadFolder: URL? = nil
    @Published var customLiveContainerFolder: URL? = nil 
    /// Where archived .ipa files are kept. nil = <downloads>/IPA_Backups
    @Published var customBackupFolder: URL? = nil
    
    // Pending Installation (Collision)
    @Published var pendingInstallation: PendingInstallation? = nil
    
    // Backups waiting for the "launch once, then verify" flow
    @Published var pendingBackups: [AppBackup] = []
    // Backups kept after a successful update (no prompting, rollback only)
    @Published var retainedBackups: [AppBackup] = []
    
    /// Kept for source compatibility with the old update flow; the 2.0 install path always keeps
    /// the snapshot produced by UpdateBackup, when that switch is on.
    @Published var keepAppBackups: Bool = true
    
    // Changed to Published for reactive UI updates
    @Published var isAutoUnzipEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled")
        }
    }
    
    /// Hand downloaded .ipa files to LiveContainer's own installer instead of unzipping them
    /// into Applications/ ourselves.
    ///
    /// Only LiveContainer can patch a guest app so that dyld accepts it; a bundle that is just
    /// dropped into Applications/ is never patched and fails on launch with
    /// "cannot dlopen a main executable". LiveContainer accepts a file URL through
    /// `livecontainer://install?url=` (same thing its share extension does).
    @Published var installViaLiveContainer: Bool = true {
        didSet {
            UserDefaults.standard.set(installViaLiveContainer, forKey: "kInstallViaLiveContainer")
        }
    }
    
    /// True while LiveContainer is installing the .ipa we just handed over; the batch queue
    /// resumes when the user comes back to this app.
    @Published var isWaitingForExternalInstall: Bool = false
    
    /// Path of the .ipa currently parked in LiveContainer; removed once we are back.
    private var lastHandOffPath: String?
    
    // Keep a copy of the newest downloaded .ipa next to the downloads
    @Published var isAutoArchivingIPAs: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoArchivingIPAs, forKey: "kAutoArchivingIPAs")
        }
    }
    
    // Batch update state
    @Published var isBatchUpdating: Bool = false
    @Published var batchRemainingTargets: [BatchUpdateTarget] = []
    @Published var batchTotalCount: Int = 0
    @Published var batchCurrentName: String = ""
    
    /// Download URLs that belong to a pre-release asset, so the archive can label them.
    private var prereleaseDownloadURLs: Set<String> = []
    
    /// Local .ipa path -> the remote URL it was downloaded from in this session.
    /// Needed because `extractApp` only sees a file:// URL, which carries no repository info.
    private var remoteURLsByLocalPath: [String: String] = [:]
    
    @Published var downloadStates: [URL: DownloadStatus] = [:]

    /// Finished / failed / cancelled downloads, newest first (persisted, capped at 100).
    @Published var downloadHistory: [DownloadRecord] = []

    /// Total size of the files sitting in the download folder (shown in Settings).
    @Published var downloadsSizeBytes: Int64 = 0
    
    private var urlSession: URLSession!
    private var tasks: [URL: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [URL: Data] = [:]
    var backgroundCompletionHandler: (() -> Void)?
    
    private let kCustomDownloadFolderKey = "kCustomDownloadFolderBookmark"
    private let kCustomLiveContainerFolderKey = "kCustomLiveContainerFolderBookmark"
    private let kBackgroundSessionID = "com.lbox.downloadSession"
    private let kResumeDataMapKey = "kResumeDataMapKey"
    
    private let kPendingBackupsKey = "kPendingBackupsKey"
    private let kRetainedBackupsKey = "kRetainedBackupsKey"
    private let kCustomBackupFolderKey = "kCustomBackupFolderBookmark"
    
    // URL String -> Filename in Caches
    private var diskResumeDataPaths: [String: String] = [:]
    
    override init() {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        self.installViaLiveContainer = UserDefaults.standard.object(forKey: "kInstallViaLiveContainer") as? Bool ?? true
        self.isAutoArchivingIPAs = UserDefaults.standard.object(forKey: "kAutoArchivingIPAs") as? Bool ?? true
        super.init()
        self.keepAppBackups = UserDefaults.standard.object(forKey: "kKeepAppBackups") as? Bool ?? true
        let config = URLSessionConfiguration.background(withIdentifier: kBackgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 86400 
        config.timeoutIntervalForRequest = 600 
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        restoreFolders()
        restoreResumeDataMapping()
        loadPendingBackups()
        loadDownloadHistory()
        reconnectExistingTasks()
        refreshFileList()
        refreshInstalledApps()
    }
    
    func getStatus(for url: URL) -> DownloadStatus {
        return downloadStates[url] ?? .none
    }
    
    func getInstalledVersion(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.version
    }
    
    func getInstalledAppName(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.url.lastPathComponent
    }
    
    // MARK: - Notifications
    func sendNotification(title: String, body: String, type: InAppNotification.NotificationType = .success) {
        NotificationManager.shared.show(title: title, message: body, type: type)
    }
    
    // MARK: - Directories
    
    var currentDownloadFolder: URL {
        if let custom = customDownloadFolder { return custom }
        return DownloadManager.defaultFolder("ipa_downloads")
    }

    /// <App Documents>/Downloads/<name>, visible in the Files app and created on demand.
    /// A real "On My iPhone/Downloads" path needs the user to pick it once (security scoped).
    static func defaultFolder(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    var currentAppsFolder: URL {
        if let root = customLiveContainerFolder {
            let appsSub = root.appendingPathComponent("Applications")
            if FileManager.default.fileExists(atPath: appsSub.path) { return appsSub }
            return root
        }
        return currentDownloadFolder
    }
    
    var currentDataApplicationFolder: URL? {
        if let root = customLiveContainerFolder {
            return root.appendingPathComponent("Data").appendingPathComponent("Application")
        }
        return nil
    }
    
    var backupDirectory: URL {
        if let custom = customBackupFolder { return custom }
        return DownloadManager.defaultFolder("ipa_backups")
    }
    
    // MARK: - IPA Archive
    
    /// Folder that keeps one copy of the newest .ipa per app.
    var ipaArchiveDirectory: URL {
        let folder: URL
        if let custom = customBackupFolder {
            folder = custom.appendingPathComponent("IPA_Backups")
        } else {
            folder = currentDownloadFolder.appendingPathComponent("IPA_Backups")
        }
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
    
    func archiveIPA(at source: URL, appName: String, version: String?, isPrerelease: Bool) {
        guard isAutoArchivingIPAs else { return }
        guard source.pathExtension.lowercased() == "ipa" else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safeName = appName.components(separatedBy: invalid).joined(separator: "_")
        let rawVersion = (version?.isEmpty == false) ? version! : "unknown"
        let safeVersion = rawVersion.components(separatedBy: invalid).joined(separator: "_")
        let suffix = isPrerelease ? "_prerelease" : ""
        let fileName = "\(safeName)_\(safeVersion)\(suffix).ipa"
        let dest = ipaArchiveDirectory.appendingPathComponent(fileName)
        
        // Keep one newest build per channel: stable and pre-release are pruned separately.
        if let existingFiles = try? fm.contentsOfDirectory(at: ipaArchiveDirectory, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                let name = file.lastPathComponent
                guard name.hasPrefix(safeName + "_"), name.lowercased().hasSuffix(".ipa") else { continue }
                let fileIsPrerelease = name.lowercased().hasSuffix("_prerelease.ipa")
                if fileIsPrerelease == isPrerelease {
                    try? fm.removeItem(at: file)
                }
            }
        }
        
        do {
            try fm.copyItem(at: source, to: dest)
            print("Archived IPA: \(fileName)")
        } catch {
            print("Archive IPA failed: \(error)")
        }
    }
    
    // MARK: - Batch Update
    
    @discardableResult
    func startBatchUpdate(targets: [BatchUpdateTarget]) -> Bool {
        let valid = targets.filter { URL(string: $0.downloadURL) != nil }
        guard !valid.isEmpty else { return false }
        batchRemainingTargets = valid
        batchTotalCount = valid.count
        isBatchUpdating = true
        downloadNextBatchItem()
        return true
    }
    
    @discardableResult
    func startBatchUpdate(apps: [AppItem]) -> Bool {
        let targets = apps.map { item in
            BatchUpdateTarget(
                name: item.name,
                bundleID: item.bundleIdentifier,
                downloadURL: item.downloadURL,
                isPrerelease: VersionText.looksPrerelease(item.version)
            )
        }
        return startBatchUpdate(targets: targets)
    }
    
    func cancelBatchUpdate() {
        isBatchUpdating = false
        batchRemainingTargets = []
        batchTotalCount = 0
        batchCurrentName = ""
    }
    
    func downloadNextBatchItem() {
        guard isBatchUpdating else { return }
        guard !batchRemainingTargets.isEmpty else {
            isBatchUpdating = false
            batchCurrentName = ""
            batchTotalCount = 0
            sendNotification(title: L10n.t("更新完成", "Updates finished"), body: L10n.t("队列里的更新都处理完了。", "All queued updates have been processed."), type: .success)
            refreshInstalledApps()
            return
        }
        
        let target = batchRemainingTargets.removeFirst()
        batchCurrentName = target.name
        
        guard let url = URL(string: target.downloadURL) else {
            advanceBatchUpdate()
            return
        }
        
        if target.isPrerelease {
            prereleaseDownloadURLs.insert(url.absoluteString)
        }
        
        // Remove any stale local copy so the archive really holds the newest build.
        if let existing = getLocalFile(for: url) {
            try? FileManager.default.removeItem(at: existing)
            refreshFileList()
        }
        
        startDownload(url: url)
    }
    
    func advanceBatchUpdate() {
        guard isBatchUpdating else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.downloadNextBatchItem()
        }
    }
    
    /// Auto-resolves the "App Conflict" dialog while a batch update is running.
    @discardableResult
    func acceptPendingAutomatically() -> Bool {
        guard isBatchUpdating else { return false }
        guard let pending = pendingInstallation, pending.existingApp != nil else { return false }
        finalizeInstallation(action: .updateExisting)
        return true
    }
    
    /// Downloads and installs one specific store item (used by the Apps tab).
    func installFromStore(_ item: AppItem) {
        guard let url = URL(string: item.downloadURL) else { return }
        if let existing = getLocalFile(for: url) {
            convertToApp(file: existing)
        } else {
            startDownload(url: url)
        }
    }
    
    /// Downloads and installs an update resolved from a GitHub release.
    func installGitHubUpdate(_ info: GitHubUpdateInfo) {
        guard let url = URL(string: info.downloadURL) else { return }
        if info.kind == .prerelease {
            prereleaseDownloadURLs.insert(url.absoluteString)
        }
        if let existing = getLocalFile(for: url) {
            convertToApp(file: existing)
        } else {
            startDownload(url: url)
        }
    }
    
    /// Remote URL an .ipa came from: the recorded download URL for local files,
    /// or the URL itself when it is already remote.
    private func remoteURLString(for localURL: URL) -> String? {
        if localURL.isFileURL {
            return remoteURLsByLocalPath[localURL.path]
        }
        return localURL.absoluteString
    }
    
    func getLocalFile(for url: URL) -> URL? {
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty { name += ".ipa" }
        
        let dest = currentDownloadFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        
        let destOriginal = currentDownloadFolder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destOriginal.path) { return destOriginal }
        
        let zipName = dest.deletingPathExtension().appendingPathExtension("zip").lastPathComponent
        let zipDest = currentDownloadFolder.appendingPathComponent(zipName)
        if FileManager.default.fileExists(atPath: zipDest.path) { return zipDest }
        
        return nil
    }
    
    func isAppInstalled(bundleID: String) -> Bool {
        return installedApps.contains { $0.bundleID == bundleID }
    }
    
    // MARK: - Backup Logic
    
    func loadPendingBackups() {
        if let data = UserDefaults.standard.data(forKey: kPendingBackupsKey),
           let list = try? JSONDecoder().decode([AppBackup].self, from: data) {
            self.pendingBackups = list
        }
        if let data = UserDefaults.standard.data(forKey: kRetainedBackupsKey),
           let list = try? JSONDecoder().decode([AppBackup].self, from: data) {
            self.retainedBackups = list
        }
    }
    
    func savePendingBackups() {
        if let data = try? JSONEncoder().encode(pendingBackups) {
            UserDefaults.standard.set(data, forKey: kPendingBackupsKey)
        }
        if let data = try? JSONEncoder().encode(retainedBackups) {
            UserDefaults.standard.set(data, forKey: kRetainedBackupsKey)
        }
    }
    
    // MARK: - Retained backups (no prompts, rollback only)
    
    func retainedBackup(for bundleID: String) -> AppBackup? {
        retainedBackups.first(where: { $0.bundleID == bundleID })
    }
    
    /// Turns a backup folder into a silent, retained one and prunes older copies of the same app.
    func retainBackup(bundlePath: String, appName: String, bundleID: String, version: String?, installPath: String) {
        if bundleID.isEmpty || bundleID == "unknown" { return }
        let record = AppBackup(
            bundleID: bundleID,
            appName: appName,
            version: version,
            backupPath: bundlePath,
            originalInstallPath: installPath,
            date: Date(),
            hadLCAppInfo: true
        )
        // one retained copy per app
        if let index = retainedBackups.firstIndex(where: { $0.bundleID == bundleID }) {
            let old = retainedBackups.remove(at: index)
            if old.backupPath != bundlePath {
                try? FileManager.default.removeItem(at: backupDirectory.appendingPathComponent(old.backupPath))
            }
        }
        retainedBackups.append(record)
        savePendingBackups()
    }
    
    /// Keeps a backup that was waiting for verification, without ever asking again.
    func keepPendingBackup(_ backup: AppBackup) {
        if let index = pendingBackups.firstIndex(where: { $0.id == backup.id }) {
            pendingBackups.remove(at: index)
            savePendingBackups()
        }
        retainBackup(bundlePath: backup.backupPath,
                     appName: backup.appName,
                     bundleID: backup.bundleID,
                     version: backup.version,
                     installPath: backup.originalInstallPath)
    }
    
    func discardRetained(_ backup: AppBackup) {
        try? FileManager.default.removeItem(at: backupDirectory.appendingPathComponent(backup.backupPath))
        if let index = retainedBackups.firstIndex(where: { $0.id == backup.id }) {
            retainedBackups.remove(at: index)
            savePendingBackups()
        }
    }
    
    func clearRetainedBackups() {
        for backup in retainedBackups {
            try? FileManager.default.removeItem(at: backupDirectory.appendingPathComponent(backup.backupPath))
        }
        retainedBackups.removeAll()
        savePendingBackups()
    }
    
    var retainedBackupsSizeBytes: Int64 {
        var total: Int64 = 0
        for backup in retainedBackups {
            let folder = backupDirectory.appendingPathComponent(backup.backupPath)
            if let e = try? FileManager.default.attributesOfItem(atPath: folder.path),
               let s = e[.size] as? Int64 {
                total += s
            }
        }
        return total
    }
    
    /// Puts the retained version of an app back in place. Data containers are untouched.
    func restoreRetainedBackup(_ backup: AppBackup) {        let fm = FileManager.default
        let folder = backupDirectory.appendingPathComponent(backup.backupPath)
        guard let backedUpApp = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { return }
        let dest = currentAppsFolder.appendingPathComponent(backup.originalInstallPath)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: backedUpApp, to: dest)
            // Full snapshots also put the data container back; app-only snapshots skip this.
            if let dataRoot = currentDataApplicationFolder {
                UpdateBackup.restoreData(appURL: dest, snapshotFolder: folder, dataRoot: dataRoot)
            }
            discardRetained(backup)
            refreshInstalledApps()
            sendNotification(title: L10n.t("已回退", "Rolled back"), body: L10n.t("\(backup.appName) 已回到上一个版本。", "\(backup.appName) restored to the previous version."), type: .success)
        } catch {
            print("Restore retained backup failed: \(error)")
        }
    }
    
    func hasLCAppInfo(bundleID: String) -> Bool {
        guard let app = installedApps.first(where: { $0.bundleID == bundleID }) else { return false }
        let url = app.url.appendingPathComponent("LCAppInfo.plist")
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    func checkUpdateStatus(for backup: AppBackup) -> Bool {
        refreshInstalledApps()
        
        let bundleID = backup.bundleID
        guard isAppInstalled(bundleID: bundleID) else {
            Logger.shared.log("CheckUpdate: App \(bundleID) not installed.")
            return false
        }
        
        if hasLCAppInfo(bundleID: bundleID) {
            // Verify if the plist is actually new (created after backup)
            // This prevents using a plist that might have come with the IPA or wasn't removed correctly
            if let app = installedApps.first(where: { $0.bundleID == bundleID }) {
                let plistURL = app.url.appendingPathComponent("LCAppInfo.plist")
                
                // 1. Check Creation Date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path),
                   let date = attrs[.creationDate] as? Date {
                    // If plist is older than backup, it's not the new one generated by LiveContainer
                    // We add a small buffer (e.g. 1 second) to avoid precision issues
                    if date < backup.date.addingTimeInterval(1) {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist is older than backup. Plist: \(date), Backup: \(backup.date)")
                        return false
                    } else {
                        Logger.shared.log("CheckUpdate: New LCAppInfo found. Plist: \(date), Backup: \(backup.date)")
                    }
                } else {
                    // If we can't read attributes, assume it's invalid/old to be safe
                    Logger.shared.log("CheckUpdate: Could not read attributes of LCAppInfo.plist")
                    return false
                }
                
                // 2. Check Content (Must have at least one container)
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    
                    if let containers = plist["LCContainers"] as? [[String: Any]] {
                        if containers.isEmpty {
                            Logger.shared.log("CheckUpdate: LCAppInfo.plist has empty LCContainers. Waiting for LiveContainer to populate it.")
                            return false
                        }
                    } else {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist missing LCContainers key. Waiting...")
                        return false
                    }
                } else {
                    Logger.shared.log("CheckUpdate: Could not read LCAppInfo.plist content.")
                    return false
                }
            }
            
            if backup.hadLCAppInfo {
                Logger.shared.log("CheckUpdate: Finalizing update for \(backup.appName)")
                finalizeUpdate(backup)
            } else {
                Logger.shared.log("CheckUpdate: Discarding backup for \(backup.appName) (No previous LCAppInfo)")
                discardBackup(backup)
            }
            return true
        }
        Logger.shared.log("CheckUpdate: No LCAppInfo.plist found for \(bundleID)")
        return false
    }
    
    func finalizeUpdate(_ backup: AppBackup) {
        Logger.shared.log("FinalizeUpdate: Starting for \(backup.appName)")
        guard let app = installedApps.first(where: { $0.bundleID == backup.bundleID }) else {
            Logger.shared.log("FinalizeUpdate: App not found installed, discarding backup.")
            discardBackup(backup)
            return
        }
        
        let fileManager = FileManager.default
        let newInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        let backupAppURL = backupDirectory.appendingPathComponent(backup.backupPath).appendingPathComponent(backup.originalInstallPath)
        let oldInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
        
        if fileManager.fileExists(atPath: newInfoURL.path) && fileManager.fileExists(atPath: oldInfoURL.path) {
            do {
                let oldData = try Data(contentsOf: oldInfoURL)
                guard let oldPlist = try PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any] else {
                    Logger.shared.log("FinalizeUpdate: Failed to read old plist, discarding.")
                    discardBackup(backup)
                    return
                }
                
                let newData = try Data(contentsOf: newInfoURL)
                var newPlist = try PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any] ?? [:]
                
                // Containers used by the previous install: they hold the real data and must never
                // be deleted by the cleanup below.
                let oldFolderNames = Set((oldPlist["LCContainers"] as? [[String: Any]] ?? [])
                    .compactMap { $0["folderName"] as? String })
                let newFolderNames = Set((newPlist["LCContainers"] as? [[String: Any]] ?? [])
                    .compactMap { $0["folderName"] as? String })
                
                // Already pointing at the old containers => migrated when the update was installed.
                // Patching again would be a no-op, and cleaning up would delete live data.
                if !oldFolderNames.isEmpty && newFolderNames == oldFolderNames {
                    Logger.shared.log("FinalizeUpdate: data was already migrated at install time, dropping backup.")
                    sendNotification(title: "Update Completed", body: "\(backup.appName) has been successfully updated.", type: .success)
                    discardBackup(backup)
                    return
                }
                
                // NEW: Clean up newly created empty containers before restoring old ones
                if let newContainers = newPlist["LCContainers"] as? [[String: Any]],
                   let dataAppFolder = currentDataApplicationFolder {
                    for container in newContainers {
                        if let folderName = container["folderName"] as? String,
                           !oldFolderNames.contains(folderName) {
                            let folderURL = dataAppFolder.appendingPathComponent(folderName)
                            if fileManager.fileExists(atPath: folderURL.path) {
                                try? fileManager.removeItem(at: folderURL)
                                Logger.shared.log("FinalizeUpdate: Deleted temporary container: \(folderName)")
                            }
                        }
                    }
                }
                
                // Only carry the data pointer. Copying every old key would also copy the patch
                // state of the previous binary and make the new one fail to load.
                if let containers = oldPlist["LCContainers"] {
                    newPlist["LCContainers"] = containers
                }
                if let dataUUID = oldPlist["LCDataUUID"] {
                    newPlist["LCDataUUID"] = dataUUID
                }
                
                let patchedData = try PropertyListSerialization.data(fromPropertyList: newPlist, format: .xml, options: 0)
                try patchedData.write(to: newInfoURL)
                Logger.shared.log("FinalizeUpdate: Patched LCAppInfo for \(backup.bundleID) with old data.")
                
                // Only send notification and discard backup if we successfully patched
                sendNotification(title: "Update Completed", body: "\(backup.appName) has been successfully updated.", type: .success)
                discardBackup(backup)
                
            } catch {
                Logger.shared.log("FinalizeUpdate: Failed to patch LCAppInfo: \(error)")
                // If patching failed, we might want to keep the backup or alert the user?
                // For now, we'll assume if it failed, we can't recover easily, so we discard to avoid loops
                discardBackup(backup)
            }
        } else {
             Logger.shared.log("FinalizeUpdate: Missing plist files (New: \(fileManager.fileExists(atPath: newInfoURL.path)), Old: \(fileManager.fileExists(atPath: oldInfoURL.path)))")
             // If files are missing, we can't proceed
             discardBackup(backup)
        }
    }
    
    // ... [Remaining Backup, Restore, Task methods unchanged]
    func restoreBackup(_ backup: AppBackup) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
            guard let backedUpApp = contents.first(where: { $0.pathExtension == "app" }) else { return }
            
            let dest = currentAppsFolder.appendingPathComponent(backup.originalInstallPath)
            
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            
            try fileManager.moveItem(at: backedUpApp, to: dest)
            
            discardBackup(backup)
            refreshInstalledApps()
        } catch {
            print("Restore failed: \(error)")
        }
    }
    
    func discardBackup(_ backup: AppBackup, deleteContainers: Bool = false) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        if deleteContainers {
            let backupAppURL = backupFolder.appendingPathComponent(backup.originalInstallPath)
            let lcInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
            
            if fileManager.fileExists(atPath: lcInfoURL.path),
               let data = try? Data(contentsOf: lcInfoURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let containers = plist["LCContainers"] as? [[String: Any]],
               let dataAppFolder = currentDataApplicationFolder {
                
                for container in containers {
                    if let folderName = container["folderName"] as? String {
                        let folderURL = dataAppFolder.appendingPathComponent(folderName)
                        try? fileManager.removeItem(at: folderURL)
                        print("Deleted backup container: \(folderName)")
                    }
                }
            }
        }
        
        try? fileManager.removeItem(at: backupFolder)
        
        if let index = pendingBackups.firstIndex(where: { $0.id == backup.id }) {
            pendingBackups.remove(at: index)
            savePendingBackups()
        }
    }
    
    private func restoreFolders() {
        restoreFolder(key: kCustomDownloadFolderKey) { self.customDownloadFolder = $0 }
        restoreFolder(key: kCustomLiveContainerFolderKey) { self.customLiveContainerFolder = $0 }
        restoreFolder(key: kCustomBackupFolderKey) { self.customBackupFolder = $0 }
    }
    
    /// Directory used for .ipa archives, resolved to the bundled default when unset.
    var backupFolderDisplayName: String {
        if let custom = customBackupFolder { return custom.lastPathComponent }
        return "Downloads/IPA_Backups"
    }
    
    func setBackupFolder(_ url: URL) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: kCustomBackupFolderKey)
            self.customBackupFolder = url
        } catch {
            print("Failed to save backup folder bookmark: \(error)")
        }
    }
    
    func clearBackupFolder() {
        UserDefaults.standard.removeObject(forKey: kCustomBackupFolderKey)
        self.customBackupFolder = nil
    }
    
    private func restoreFolder(key: String, assign: (URL) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            if isStale {
               _ = url.startAccessingSecurityScopedResource()
               let newData = try url.bookmarkData()
               UserDefaults.standard.set(newData, forKey: key)
               url.stopAccessingSecurityScopedResource()
            }
            if url.startAccessingSecurityScopedResource() {
                assign(url)
            }
        } catch { }
    }
    
    private func reconnectExistingTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else { continue }
                    
                    self.tasks[url] = downloadTask
                    
                    if downloadTask.state == .running {
                        let written = downloadTask.countOfBytesReceived
                        let expected = downloadTask.countOfBytesExpectedToReceive
                        let p = expected > 0 ? Double(written) / Double(expected) : 0.0
                        self.downloadStates[url] = .downloading(progress: p, written: written, total: expected)
                    } else if downloadTask.state == .suspended {
                        self.downloadStates[url] = .paused
                    }
                }
                
                for (urlStr, _) in self.diskResumeDataPaths {
                    if let url = URL(string: urlStr), self.tasks[url] == nil {
                        self.downloadStates[url] = .paused
                    }
                }
            }
        }
    }
    
    private func restoreResumeDataMapping() {
        if let map = UserDefaults.standard.dictionary(forKey: kResumeDataMapKey) as? [String: String] {
            self.diskResumeDataPaths = map
        }
    }
    
    private func saveResumeDataMapping() {
        UserDefaults.standard.set(diskResumeDataPaths, forKey: kResumeDataMapKey)
    }
    
    private func storeResumeData(_ data: Data, for url: URL) {
        let filename = UUID().uuidString
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            diskResumeDataPaths[url.absoluteString] = filename
            saveResumeDataMapping()
            resumeDataMap[url] = data
        } catch {
            print("Failed to save resume data: \(error)")
        }
    }
    
    private func retrieveResumeData(for url: URL) -> Data? {
        if let data = resumeDataMap[url] { return data }
        if let filename = diskResumeDataPaths[url.absoluteString] {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let data = try? Data(contentsOf: fileURL) { return data }
        }
        return nil
    }
    
    private func clearResumeData(for url: URL) {
        resumeDataMap[url] = nil
        if let filename = diskResumeDataPaths.removeValue(forKey: url.absoluteString) {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
            saveResumeDataMapping()
        }
    }
    
    func setCustomFolder(_ url: URL, forApps: Bool) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
            UserDefaults.standard.set(bookmarkData, forKey: key)
            
            if forApps {
                self.customLiveContainerFolder = url
                self.isAutoUnzipEnabled = true // Auto-enable as requested
                refreshInstalledApps()
            } else {
                self.customDownloadFolder = url
                refreshFileList()
            }
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    func clearCustomFolder(forApps: Bool) {
        let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
        UserDefaults.standard.removeObject(forKey: key)
        if forApps {
            self.customLiveContainerFolder = nil
            refreshInstalledApps()
        } else {
            self.customDownloadFolder = nil
            refreshFileList()
        }
    }
    
    func startDownload(url: URL) {
        if getLocalFile(for: url) != nil { return }
        if case .paused = getStatus(for: url) {
            resumeDownload(url: url)
            return
        }
        
        if tasks[url] == nil {
            if let data = retrieveResumeData(for: url) {
                let task = urlSession.downloadTask(withResumeData: data)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            } else {
                let task = urlSession.downloadTask(with: url)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            }
        } else {
            tasks[url]?.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        }
    }
    
    func pauseDownload(url: URL) {
        guard let task = tasks[url] else { return }
        task.cancel { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                if let resumeData = data { self.storeResumeData(resumeData, for: url) }
                self.downloadStates[url] = .paused
                self.tasks[url] = nil
            }
        }
    }
    
    func resumeDownload(url: URL) {
        if let data = retrieveResumeData(for: url) {
            let task = urlSession.downloadTask(withResumeData: data)
            tasks[url] = task
            task.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        } else {
            startDownload(url: url)
        }
    }
    
    func cancelDownload(url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        clearResumeData(for: url)
        downloadStates[url] = nil
        recordDownload(url: url, fileName: url.lastPathComponent, state: .cancelled, bytes: 0)
    }

    // MARK: - Download history

    private func loadDownloadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "kDownloadHistory"),
              let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        downloadHistory = list
    }

    private func saveDownloadHistory() {
        guard let data = try? JSONEncoder().encode(Array(downloadHistory.prefix(100))) else { return }
        UserDefaults.standard.set(data, forKey: "kDownloadHistory")
    }

    func recordDownload(url: URL, fileName: String, state: DownloadRecord.State, bytes: Int64, message: String? = nil) {
        let record = DownloadRecord(
            id: url.absoluteString + "#" + UUID().uuidString,
            url: url.absoluteString,
            fileName: fileName,
            state: state,
            date: Date(),
            bytes: bytes,
            message: message
        )
        downloadHistory.insert(record, at: 0)
        saveDownloadHistory()
    }

    func recalcDownloadsSize() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        var total: Int64 = 0
        if let items = try? FileManager.default.contentsOfDirectory(at: currentDownloadFolder,
                                                                   includingPropertiesForKeys: Array(keys)) {
            for item in items where item.pathExtension.lowercased() != "app" {
                if let values = try? item.resourceValues(forKeys: keys),
                   let size = values.totalFileAllocatedSize ?? values.fileSize {
                    total += Int64(size)
                }
            }
        }
        downloadsSizeBytes = total
    }

    func removeDownloadRecord(_ record: DownloadRecord) {
        downloadHistory.removeAll { $0.id == record.id }
        saveDownloadHistory()
    }

    func clearDownloadHistory() {
        downloadHistory.removeAll()
        saveDownloadHistory()
    }
    
    func isDownloading(url: URL) -> Bool {
        if case .downloading = getStatus(for: url) { return true }
        return false
    }
    
    func isPaused(url: URL) -> Bool {
        if case .paused = getStatus(for: url) { return true }
        return false
    }
    
    func refreshFileList() {
        recalcDownloadsSize()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            let filtered = files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "app" }
            self.fileList = filtered
        } catch { self.fileList = [] }
    }
    
    func refreshInstalledApps() {
        cleanupStaleTempDirectories()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentAppsFolder, includingPropertiesForKeys: nil)
            var newApps: [LocalApp] = []
            for file in files where file.pathExtension == "app" {
                let plistURL = file.appendingPathComponent("Info.plist")
                var name = file.deletingPathExtension().lastPathComponent
                var bundleID = "unknown"
                var version: String? = nil
                var iconURL: URL? = nil
                
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let displayName = plist["CFBundleDisplayName"] as? String {
                        name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let bundleName = plist["CFBundleName"] as? String {
                        name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let ver = plist["CFBundleShortVersionString"] as? String {
                        version = ver
                    } else if let ver = plist["CFBundleVersion"] as? String {
                        version = ver
                    }
                    
                    var iconFiles: [String] = []
                    if let iconsDict = plist["CFBundleIcons"] as? [String: Any],
                       let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let ipadIconsDict = plist["CFBundleIcons~ipad"] as? [String: Any],
                       let primaryIcon = ipadIconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let legacyFiles = plist["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: legacyFiles)
                    }
                    
                    for iconName in iconFiles.reversed() {
                        if let found = findIconFile(in: file, name: iconName) { iconURL = found; break }
                    }
                    
                    if iconURL == nil {
                        iconURL = findIconFile(in: file, name: "AppIcon60x60") ?? findIconFile(in: file, name: "AppIcon")
                    }
                }
                newApps.append(LocalApp(name: name, bundleID: bundleID, version: version, url: file, iconURL: iconURL))
            }
            self.installedApps = newApps
        } catch { self.installedApps = [] }
    }
    
    private func findIconFile(in folder: URL, name: String) -> URL? {
        let extensions = ["png", "jpg"]
        let candidates = [name, "\(name)@2x", "\(name)@3x", "\(name)60x60@2x"]
        for c in candidates {
            for e in extensions {
                let f = folder.appendingPathComponent("\(c).\(e)")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }
    
    func renameFile(_ fileURL: URL, newName: String) {
        let folder = fileURL.deletingLastPathComponent()
        let newURL = folder.appendingPathComponent(newName)
        do {
            if startAccessing(fileURL) { defer { fileURL.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: newURL.path) {
                print("Error: File already exists")
                return
            }
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            refreshFileList()
        } catch {
            print("Rename failed: \(error)")
        }
    }
    
    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFileList()
    }
    
    func deleteApp(_ app: LocalApp) {
        let fileManager = FileManager.default
        let lcInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        if fileManager.fileExists(atPath: lcInfoURL.path),
           let data = try? Data(contentsOf: lcInfoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let containers = plist["LCContainers"] as? [[String: Any]],
           let dataAppFolder = currentDataApplicationFolder {
            for container in containers {
                if let folderName = container["folderName"] as? String {
                    try? fileManager.removeItem(at: dataAppFolder.appendingPathComponent(folderName))
                }
            }
        }
        try? fileManager.removeItem(at: app.url)
        refreshInstalledApps()
    }
    
    func clearAllFiles() {
        try? FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "app" }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        refreshFileList()
    }
    
    // MARK: - Hand off to LiveContainer
    
    /// Folder inside LiveContainer where we park an .ipa before asking it to install.
    var lcHandoffDirectory: URL? {
        guard let root = customLiveContainerFolder else { return nil }
        let dir = root.appendingPathComponent("LCBoxInstall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Opens LiveContainer's install flow for this .ipa.
    ///
    /// LiveContainer can read anything inside its own container, and this app is a guest inside
    /// it, so the normal download folder needs no copy at all. Only when the user pointed the
    /// download folder somewhere outside (iCloud, another app) do we park a copy it can read.
    @discardableResult
    func handOffToLiveContainer(_ ipa: URL, app: LocalApp? = nil) async -> Bool {
        guard ipa.pathExtension.lowercased() == "ipa" else { return false }

        // Snapshot the installed build before LiveContainer replaces it, so it can be rolled back.
        if let app,
           let snapshot = await UpdateBackup.snapshot(app: app,
                                                      backupRoot: backupDirectory,
                                                      dataRoot: currentDataApplicationFolder) {
            retainBackup(bundlePath: snapshot,
                         appName: app.name,
                         bundleID: app.bundleID,
                         version: app.version,
                         installPath: app.url.lastPathComponent)
        }
        guard let root = customLiveContainerFolder else {
            sendNotification(title: L10n.t("缺少 LiveContainer 目录", "LiveContainer folder missing"),
                             body: L10n.t("请先在设置里选择 LiveContainer 目录。", "Choose it in Settings so updates can be installed."),
                             type: .error)
            return false
        }

        let fm = FileManager.default
        var payload = ipa
        if !ipa.path.hasPrefix(root.deletingLastPathComponent().path) {
            guard let dir = lcHandoffDirectory else { return false }
            let dest = dir.appendingPathComponent(ipa.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: ipa, to: dest)
                payload = dest
                lastHandOffPath = dest.path
            } catch {
                Logger.shared.log("HandOff: copy failed \(error)")
                sendNotification(title: L10n.t("安装失败", "Install failed"), body: L10n.t("无法准备 \(ipa.lastPathComponent)。", "Could not prepare \(ipa.lastPathComponent)."), type: .error)
                return false
            }
        }

        var components = URLComponents(string: "livecontainer://install")
        components?.queryItems = [URLQueryItem(name: "url", value: payload.absoluteString)]
        guard let url = components?.url else { return false }
        isWaitingForExternalInstall = true
        Logger.shared.log("HandOff: opening LiveContainer for \(payload.lastPathComponent)")
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
    }

    /// Marks that the install hand-off is in flight, so coming back refreshes the app list.
    func markWaitingForExternalInstall() {
        isWaitingForExternalInstall = true
    }

    /// Called when the app becomes active again: LiveContainer has finished (or rejected) the
    /// install, so let a running batch continue with the next app.
    func resumeAfterExternalInstall() {
        guard isWaitingForExternalInstall else { return }
        isWaitingForExternalInstall = false
        // The .ipa is kept: if the install was cancelled the user can try again from the list.
        refreshInstalledApps()
        if isBatchUpdating { advanceBatchUpdate() }
    }
    
    func convertToApp(file: URL) {
        if installViaLiveContainer {
            Task { _ = await handOffToLiveContainer(file) }
            return
        }
        Task {
            _ = await MainActor.run { self.extractingFiles.insert(file) }
            
            do {
                var accessActive = false
                if file.startAccessingSecurityScopedResource() {
                    accessActive = true
                }
                
                try await extractApp(from: file)
                
                if accessActive {
                    file.stopAccessingSecurityScopedResource()
                    accessActive = false
                }
                
                if self.pendingInstallation == nil {
                    _ = await MainActor.run {
                        self.extractingFiles.remove(file)
                        self.refreshFileList()
                        self.refreshInstalledApps()
                    }
                } else {
                     _ = await MainActor.run { self.extractingFiles.remove(file) }
                }
            } catch {
                print("Convert error: \(error)")
                _ = await MainActor.run { self.extractingFiles.remove(file) }
            }
        }
    }
    
    func importFile(at source: URL) {
        let dest = currentDownloadFolder.appendingPathComponent(source.lastPathComponent)
        do {
            if source.startAccessingSecurityScopedResource() {
                let access = true
                
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: source, to: dest)
                refreshFileList()
                
                if access { source.stopAccessingSecurityScopedResource() }
            }
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func extractApp(from sourceURL: URL) async throws {
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        
        #if canImport(ZIPFoundation)
        let tempUnzipDir = folder.appendingPathComponent("Temp_" + UUID().uuidString)
        try fileManager.createDirectory(at: tempUnzipDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: sourceURL, to: tempUnzipDir)
        
        let payloadDir = tempUnzipDir.appendingPathComponent("Payload")
        if fileManager.fileExists(atPath: payloadDir.path) {
            let contents = try fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
            if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
                
                var targetName = appBundle.lastPathComponent
                var bundleID = "unknown"
                var displayName = appBundle.deletingPathExtension().lastPathComponent
                var shortVersion = ""
                
                let plistURL = appBundle.appendingPathComponent("Info.plist")
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetName = bundleID + ".app"
                    }
                    if let name = plist["CFBundleDisplayName"] as? String {
                        if !name.isEmpty { displayName = name }
                    } else if let name = plist["CFBundleName"] as? String {
                        if !name.isEmpty { displayName = name }
                    }
                    if let ver = plist["CFBundleShortVersionString"] as? String {
                        shortVersion = ver
                    }
                }
                
                // Keep a copy of the newest .ipa before the original gets moved or removed,
                // and remember which GitHub repository it came from.
                // NOTE: sourceURL is a local file:// path here, so the remote URL has to be
                // looked up - a file URL never parses as a github.com release link.
                let remoteURLString = self.remoteURLString(for: sourceURL)
                let downloadedFromPrerelease = remoteURLString.map { self.prereleaseDownloadURLs.contains($0) } ?? false
                let isPrereleaseDownload = downloadedFromPrerelease || VersionText.looksPrerelease(shortVersion)
                self.archiveIPA(at: sourceURL, appName: displayName, version: shortVersion, isPrerelease: isPrereleaseDownload)
                if let remoteURLString {
                    self.prereleaseDownloadURLs.remove(remoteURLString)
                    GitHubProvenanceStore.shared.proposeFromDownloadURL(remoteURLString, bundleID: bundleID)
                }
                
                if let existingApp = self.installedApps.first(where: { $0.bundleID == bundleID && bundleID != "unknown" }) {
                    _ = await MainActor.run {
                        self.pendingInstallation = PendingInstallation(
                            appName: existingApp.name, 
                            bundleID: bundleID,
                            tempPayloadURL: payloadDir, 
                            extractedAppURL: appBundle,
                            sourceArchiveURL: sourceURL,
                            existingApp: existingApp
                        )
                    }
                    return
                }
                
                var finalURL = folder.appendingPathComponent(targetName)
                if fileManager.fileExists(atPath: finalURL.path) {
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                }
                
                try fileManager.moveItem(at: appBundle, to: finalURL)
                
                if sourceURL.path.contains(currentDownloadFolder.path) { try? fileManager.removeItem(at: sourceURL) }
                try? fileManager.removeItem(at: tempUnzipDir)
                
            } else { try? fileManager.removeItem(at: tempUnzipDir) }
        } else { try? fileManager.removeItem(at: tempUnzipDir) }
        #else
        if sourceURL.pathExtension.lowercased() == "ipa" {
            let zipURL = sourceURL.deletingPathExtension().appendingPathExtension("zip")
            if fileManager.fileExists(atPath: zipURL.path) { try fileManager.removeItem(at: zipURL) }
            try fileManager.moveItem(at: sourceURL, to: zipURL)
        }
        #endif
    }
    
    func finalizeInstallation(action: InstallAction) {
        guard let pending = pendingInstallation else { return }
        
        // Park the data pointer of the previous install before its bundle moves away.
        // reconcileDataMigrations() uses it if LiveContainer rebuilds the container.
        if case .updateExisting = action, let existing = pending.existingApp {
            let oldInfo = existing.url.appendingPathComponent("LCAppInfo.plist")
            if FileManager.default.fileExists(atPath: oldInfo.path) {
                LCDataMigration.shared.remember(plistURL: oldInfo,
                                                bundleID: existing.bundleID,
                                                appName: existing.name,
                                                installPath: existing.url.lastPathComponent)
            }
        }
        
        // A backup recorded by an older build (before data was migrated at install time) still
        // holds the LCAppInfo.plist that points at the real data containers.
        let legacyBackup = pendingBackups.first(where: { $0.bundleID == pending.bundleID })
        let keepPreviousVersion = keepAppBackups
        
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        let downloadDir = self.currentDownloadFolder
        let backupDir = self.backupDirectory
        
        Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .installSeparate:
                    var targetName = pending.extractedAppURL.lastPathComponent
                    if !pending.bundleID.isEmpty && pending.bundleID != "unknown" {
                        targetName = pending.bundleID + ".app"
                    }
                    
                    var finalURL = folder.appendingPathComponent(targetName)
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                    
                    try fileManager.moveItem(at: pending.extractedAppURL, to: finalURL)
                    
                case .updateExisting:
                    guard let existing = pending.existingApp else { break }
                    
                    let existingPath = existing.url
                    let lcInfoURL = existingPath.appendingPathComponent("LCAppInfo.plist")
                    let hadInfo = fileManager.fileExists(atPath: lcInfoURL.path)
                    
                    // Somewhere we can find an LCAppInfo.plist that still points at real data.
                    let legacyAppURL = legacyBackup.map {
                        backupDir.appendingPathComponent($0.backupPath).appendingPathComponent($0.originalInstallPath)
                    }
                    let legacyHasInfo = legacyAppURL.map {
                        fileManager.fileExists(atPath: $0.appendingPathComponent("LCAppInfo.plist").path)
                    } ?? false
                    
                    let backupUUID = UUID().uuidString
                    let destFolder = backupDir.appendingPathComponent(backupUUID)
                    var oldBundleURL: URL? = nil
                    
                    if hadInfo || legacyHasInfo {
                        // Park the current bundle so its LCAppInfo.plist survives the swap.
                        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        if fileManager.fileExists(atPath: existingPath.path) {
                            let backupDest = destFolder.appendingPathComponent(existingPath.lastPathComponent)
                            try fileManager.moveItem(at: existingPath, to: backupDest)
                            oldBundleURL = backupDest
                        }
                    } else if fileManager.fileExists(atPath: existingPath.path) {
                        try fileManager.removeItem(at: existingPath)
                    }
                    
                    try fileManager.moveItem(at: pending.extractedAppURL, to: existingPath)
                    
                    // The legacy backup wins: the bundle we just replaced may already be a fresh
                    // install pointing at an empty container.
                    let migrationSource = (legacyHasInfo ? legacyAppURL : nil) ?? oldBundleURL
                    var migrated = false
                    if let source = migrationSource {
                        migrated = migrateLCAppInfo(from: source, to: existingPath)
                    }
                    
                    if migrated {
                        // Data is re-linked, so no post-launch verification is ever needed.
                        // Keep the previous build around silently for rollback instead of
                        // asking the user to deal with a "delete backup" prompt.
                        if keepPreviousVersion {
                            await MainActor.run {
                                self.retainBackup(bundlePath: backupUUID,
                                                  appName: existing.name,
                                                  bundleID: existing.bundleID,
                                                  version: existing.version,
                                                  installPath: existingPath.lastPathComponent)
                            }
                        } else {
                            try? fileManager.removeItem(at: destFolder)
                        }
                        if let legacy = legacyBackup {
                            await MainActor.run { self.discardBackup(legacy) }
                        }
                        await MainActor.run {
                            self.sendNotification(title: L10n.t("更新完成", "Update installed"),
                                                  body: L10n.t("\(existing.name) 已更新，原有数据保留。", "\(existing.name) updated, existing data kept."),
                                                  type: .success)
                        }
                    } else if hadInfo {
                        // Fallback: keep the old behaviour (launch once, then LBox verifies).
                        let backupRecord = AppBackup(
                            bundleID: existing.bundleID,
                            appName: existing.name,
                            version: existing.version,
                            backupPath: backupUUID,
                            originalInstallPath: existingPath.lastPathComponent,
                            date: Date(),
                            hadLCAppInfo: hadInfo
                        )
                        
                        await MainActor.run {
                            self.pendingBackups.append(backupRecord)
                            self.savePendingBackups()
                        }
                    } else {
                        try? fileManager.removeItem(at: destFolder)
                        if let legacy = legacyBackup {
                            await MainActor.run { self.discardBackup(legacy) }
                        }
                    }
                    
                case .cancel:
                    break
                }
            } catch {
                print("Finalize install error: \(error)")
            }
            
            let tempRoot = pending.tempPayloadURL.deletingLastPathComponent()
            try? fileManager.removeItem(at: tempRoot)
            
            if action != .cancel, pending.sourceArchiveURL.path.contains(downloadDir.path) {
                try? fileManager.removeItem(at: pending.sourceArchiveURL)
            }
            
            try? await Task.sleep(nanoseconds: 200_000_000)

            await MainActor.run {
                self.pendingInstallation = nil
                self.refreshFileList()
                self.refreshInstalledApps()
                self.reconcileDataMigrations()
                self.advanceBatchUpdate()
            }
        }
    }
    
    /// Extracting an .ipa into the Applications folder goes through Temp_<UUID>/Payload. If the
    /// install is interrupted (app killed, conflict dialog never answered) that folder survives
    /// with a full copy of the app inside it. Drop the ones that are clearly abandoned.
    func cleanupStaleTempDirectories(maxAge: TimeInterval = 600) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: currentAppsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for item in items where item.lastPathComponent.hasPrefix("Temp_") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            try? fm.removeItem(at: item)
            Logger.shared.log("Cleanup: removed stale temp directory \(item.lastPathComponent)")
        }
    }
    
    /// Called on foreground and right after an install: if LiveContainer has already (re)created
    /// the container of an app we updated, move the previous data into it.
    func reconcileDataMigrations() {
        guard let dataRoot = currentDataApplicationFolder else { return }
        let appsFolder = currentAppsFolder
        Task {
            let restored = await LCDataMigration.shared.reconcile(appsFolder: appsFolder, dataRoot: dataRoot)
            guard !restored.isEmpty else { return }
            for name in restored {
                sendNotification(title: L10n.t("数据已恢复", "Data restored"),
                                 body: L10n.t("\(name)：已把原有数据合并回来。", "\(name): existing data was carried over."),
                                 type: .success)
            }
            refreshInstalledApps()
        }
    }
    
    private func startAccessing(_ url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(sourceURL.pathExtension)
        
        do {
            if fileManager.fileExists(atPath: stagingURL.path) { try fileManager.removeItem(at: stagingURL) }
            try fileManager.moveItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in self.downloadStates[sourceURL] = nil }
            return
        }
        
        Task { @MainActor in
            do {
                let manager = FileManager.default
                let folder = self.currentDownloadFolder
                if !manager.fileExists(atPath: folder.path) {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                
                var finalName = sourceURL.lastPathComponent
                if sourceURL.pathExtension.isEmpty {
                    finalName += ".ipa"
                }
                
                let finalURL = folder.appendingPathComponent(finalName)
                if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
                try manager.moveItem(at: stagingURL, to: finalURL)
                let attributes = try? manager.attributesOfItem(atPath: finalURL.path)
                let finishedSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                self.recordDownload(url: sourceURL, fileName: finalName, state: .finished, bytes: finishedSize)
                // Remember where this file really came from; provenance/GitHub binding relies on it.
                self.remoteURLsByLocalPath[finalURL.path] = sourceURL.absoluteString
                
                self.sendNotification(title: L10n.t("下载完成", "Download complete"), body: L10n.t("\(finalName) 已下载。", "\(finalName) has been downloaded."), type: .success)
                
                if self.isBatchUpdating && finalURL.pathExtension.lowercased() == "ipa" {
                    // Downloads only: installing is an explicit action in the Apps list.
                    self.advanceBatchUpdate()
                } else if (self.isAutoUnzipEnabled || self.isBatchUpdating) && finalURL.pathExtension.lowercased() == "ipa" {
                    self.extractingFiles.insert(finalURL)
                    try await self.extractApp(from: finalURL)
                    if self.pendingInstallation == nil {
                        self.extractingFiles.remove(finalURL)
                        self.advanceBatchUpdate()
                    }
                } else if self.isBatchUpdating {
                    self.advanceBatchUpdate()
                }
                
                self.downloadStates[sourceURL] = nil
                self.tasks[sourceURL] = nil
                self.clearResumeData(for: sourceURL)
                self.refreshFileList()
                self.refreshInstalledApps()
            } catch {
                self.downloadStates[sourceURL] = nil
                self.refreshFileList()
                if let fname = sourceURL.lastPathComponent as String?, let furl = self.currentDownloadFolder.appendingPathComponent(fname) as URL? {
                    self.extractingFiles.remove(furl)
                }
                // Never leave a batch run stuck on a single failure.
                if self.isBatchUpdating {
                    self.sendNotification(title: L10n.t("更新失败", "Update failed"), body: L10n.t("跳过 \(self.batchCurrentName)。", "Skipping \(self.batchCurrentName)."), type: .error)
                    self.advanceBatchUpdate()
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        Task { @MainActor in 
            self.downloadStates[sourceURL] = .downloading(progress: progress, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sourceURL = task.originalRequest?.url else { return }
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    Task { @MainActor in
                        self.storeResumeData(resumeData, for: sourceURL)
                        self.downloadStates[sourceURL] = .paused
                    }
                } else {
                    Task { @MainActor in self.downloadStates[sourceURL] = nil }
                }
                return
            }
            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Task { @MainActor in
                    self.storeResumeData(resumeData, for: sourceURL)
                    self.downloadStates[sourceURL] = .paused
                }
            } else {
                Task { @MainActor in
                    self.downloadStates[sourceURL] = nil
                    self.recordDownload(url: sourceURL,
                                        fileName: sourceURL.lastPathComponent,
                                        state: .failed,
                                        bytes: 0,
                                        message: error.localizedDescription)
                    if self.isBatchUpdating {
                        self.sendNotification(title: L10n.t("更新失败", "Update failed"), body: L10n.t("跳过 \(self.batchCurrentName)。", "Skipping \(self.batchCurrentName)."), type: .error)
                        self.advanceBatchUpdate()
                    }
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        if let url = task.originalRequest?.url {
            Task { @MainActor in self.downloadStates[url] = .waitingForConnection }
        }
    }
    
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let handler = self.backgroundCompletionHandler {
                self.backgroundCompletionHandler = nil
                handler()
            }
        }
    }
}

