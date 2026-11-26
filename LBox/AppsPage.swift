import SwiftUI
import Combine

/// Two-word bilingual helper.
///
/// The app ships a single `zh-Hans` strings file whose keys are English, and it lets the user
/// force a language with `kAppLanguage`. Rather than adding a whole new localization bundle for
/// the 2.0 screen, the new strings are written as explicit zh/en pairs here.
enum L10n {
    static var prefersChinese: Bool {
        switch UserDefaults.standard.string(forKey: "kAppLanguage") ?? "system" {
        case "zh-Hans":
            return true
        case "en":
            return false
        default:
            return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }

    static func t(_ zh: String, _ en: String) -> String {
        prefersChinese ? zh : en
    }
}

/// Latest GitHub release date per app, used by the "release date" sort.
///
/// A release date only exists after asking GitHub, so the values are cached for six hours and
/// kept across launches. Apps without a binding (or without a usable release) have no entry and
/// sort to the end.
@MainActor
final class ReleaseDateCache: ObservableObject {
    static let shared = ReleaseDateCache()

    @Published private(set) var dates: [String: Date] = [:]

    private let storageKey = "kReleaseDatesV2"
    private let lifetime: TimeInterval = 6 * 3600
    private var lastFetch: [String: Date] = [:]
    private var inFlight = false

    private init() { load() }

    func date(for bundleID: String) -> Date? { dates[bundleID] }

    func refreshIfNeeded(_ apps: [LocalApp]) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let token = (UserDefaults.standard.string(forKey: "kGitHubToken") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false

        for app in apps {
            guard let ref = GitHubProvenanceStore.shared.confirmedSource(for: app.bundleID) else { continue }
            if let fetched = lastFetch[app.bundleID], Date().timeIntervalSince(fetched) < lifetime { continue }
            do {
                let releases = try await GitHubAPI.fetchReleases(ref, token: token.isEmpty ? nil : token)
                let usable = releases.filter { !$0.draft && $0.ipaAsset(matching: app.name) != nil }
                if let latest = usable.max(by: { VersionText.isNewer($1.version, than: $0.version) }),
                   let raw = latest.publishedAt,
                   let date = Self.parse(raw) {
                    dates[app.bundleID] = date
                    changed = true
                }
            } catch {
                // Offline or rate limited: keep whatever we had and try again later.
            }
            lastFetch[app.bundleID] = Date()
        }

        if changed { save() }
    }

    private static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private func load() {
        guard let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] else { return }
        dates = stored.compactMapValues { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        UserDefaults.standard.set(dates.mapValues { $0.timeIntervalSince1970 }, forKey: storageKey)
    }
}

/// Which slice of the installed apps the page is showing.
/// `.all` keeps the grid; the two filtered modes use App Store style rows so the
/// download / install / bind control has room on the right.
enum AppsFilter {
    case all
    case bound
    case unbound
}

struct InstalledAppsView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    @Binding var selectedTab: Int
    @ObservedObject var viewModel: AppStoreViewModel
    @ObservedObject var github = GitHubSourceCenter.shared
    @ObservedObject private var releaseDates = ReleaseDateCache.shared

    @State private var filter: AppsFilter = .all
    @State private var searchText = ""
    @State private var showAllSources = false
    @State private var bindTarget: LocalApp? = nil
    @State private var pendingInstall: PendingInstall? = nil
    @State private var manualTarget: LocalApp? = nil
    @State private var shareURL: URL? = nil
    @State private var showSwitcher = false
    @State private var isScanning = false
    @AppStorage("kInstalledSort") private var sortRaw: String = "name"

    private let columns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 20, alignment: .top)]

    // MARK: - Data

    private var boundApps: [LocalApp] {
        downloadManager.installedApps.filter { github.confirmedSlug(for: $0.bundleID) != nil }
    }

    private var unboundApps: [LocalApp] {
        downloadManager.installedApps.filter { github.confirmedSlug(for: $0.bundleID) == nil }
    }

    private var shownApps: [LocalApp] {
        let base: [LocalApp]
        switch filter {
        case .all: base = downloadManager.installedApps
        case .bound: base = boundApps
        case .unbound: base = unboundApps
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? base : base.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        return sorted(filtered)
    }

    private func sorted(_ apps: [LocalApp]) -> [LocalApp] {
        switch sortRaw {
        case "nameReverse":
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case "version":
            return apps.sorted {
                ($0.version ?? "").compare($1.version ?? "", options: .numeric) == .orderedDescending
            }
        case "releaseDate":
            return apps.sorted { lhs, rhs in
                let left = releaseDates.date(for: lhs.bundleID)
                let right = releaseDates.date(for: rhs.bundleID)
                switch (left, right) {
                case let (x?, y?):
                    if x != y { return x > y }
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    break
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        default:
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Newest .ipa we can download for this app: GitHub binding first, then the store entry.
    private func updateURL(for app: LocalApp) -> URL? {
        if let info = github.updates[app.bundleID] {
            return URL(string: info.downloadURL)
        }
        // Store fallback: only when the store actually has something newer, otherwise the row
        // would offer "Download" forever instead of settling on "Latest".
        if let item = viewModel.bestStoreItem(for: app.bundleID),
           VersionText.isNewer(item.version, than: app.version ?? "") {
            return URL(string: item.downloadURL)
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                segmented
                searchRow
                content
            }
            .navigationTitle(Text(L10n.t("我的 app", "My Apps")))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            restartIntoLiveContainer()
                        } label: {
                            Label(L10n.t("重启到 LiveContainer", "Restart into LiveContainer"),
                                  systemImage: "arrow.clockwise")
                        }
                        Button {
                            showSwitcher = true
                        } label: {
                            Label(L10n.t("切换到其他 App…", "Switch to another app…"),
                                  systemImage: "arrow.left.arrow.right")
                        }
                    } label: {
                        LiveContainerPill()
                    }
                    .accessibilityLabel(Text(L10n.t("切换 LiveContainer / 其他 App", "Switch app")))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if filter == .all {
                        Menu {
                            Picker((L10n.t("排序", "Sort By")), selection: $sortRaw) {
                                Text(L10n.t("名称", "Name")).tag("name")
                                Text(L10n.t("名称（倒序）", "Name (Z-A)")).tag("nameReverse")
                                Text(L10n.t("版本", "Version")).tag("version")
                                Text(L10n.t("更新日期", "Release date")).tag("releaseDate")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    } else if filter == .unbound {
                        Button((L10n.t("检查来源", "Check Sources"))) {
                            Task { await scanSources() }
                        }
                        .disabled(isScanning)
                    } else {
                        Button((L10n.t("检查更新", "Check Updates"))) {
                            Task { await checkUpdates() }
                        }
                        .disabled(isScanning)
                    }
                }
            }
            .alert(Text(L10n.t("打开 LiveContainer 完成更新", "Open LiveContainer to finish updating")),
                   isPresented: installAlertBinding) {
                Button((L10n.t("继续", "Continue"))) {
                    let request = pendingInstall
                    pendingInstall = nil
                    if let request {
                        // Keep a copy for the backup folder, then hand over a throwaway file:
                        // LiveContainer deletes whatever .ipa it installs from.
                        downloadManager.archiveIPABeforeInstall(request.file, app: request.app)
                        shareURL = stageForSharing(request.file)
                    }
                }
                Button((L10n.t("取消", "Cancel")), role: .cancel) {
                    pendingInstall = nil
                }
            } message: {
                Text(L10n.t("下一步在分享面板里选择 LiveContainer，由它打补丁并完成安装；装好后切回这里可以继续下一个。",
                            "Pick LiveContainer in the share sheet so it can patch and install the app. Come back here for the next one."))
            }
            .sheet(isPresented: $showSwitcher) {
                AppSwitcherSheet(apps: downloadManager.installedApps)
            }
            .sheet(isPresented: Binding(get: { shareURL != nil },
                                        set: { if !$0 { shareURL = nil; downloadManager.markWaitingForExternalInstall() } })) {
                if let url = shareURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .sheet(isPresented: $showAllSources) {
                SourceConfirmationSheet(bundleIDFilter: nil)
            }
            .sheet(item: $bindTarget) { app in
                SourceConfirmationSheet(bundleIDFilter: app.bundleID)
            }
            .sheet(item: $manualTarget) { app in
                ManualSourceSheet(app: app)
            }
            .task {
                await github.refresh(installedApps: downloadManager.installedApps,
                                     storeApps: viewModel.displayApps)
                await BoundSourceFeed.sync(viewModel: viewModel, installedApps: downloadManager.installedApps)
                if sortRaw == "releaseDate" {
                    await releaseDates.refreshIfNeeded(downloadManager.installedApps)
                }
            }
            .onChange(of: sortRaw) { value in
                guard value == "releaseDate" else { return }
                Task { await releaseDates.refreshIfNeeded(downloadManager.installedApps) }
            }
        }
    }

    private var installAlertBinding: Binding<Bool> {
        Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } })
    }

    // MARK: - Top bars

    private var segmented: some View {
        HStack(spacing: 8) {
            segmentButton(.bound)
            segmentButton(.unbound)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func segmentButton(_ target: AppsFilter) -> some View {
        let active = filter == target
        let label = target == .bound
            ? L10n.t("已绑定", "Bound")
            : L10n.t("未绑定", "Unbound")
        return Button {
            // Tapping the active segment again goes back to the full grid.
            filter = active ? .all : target
        } label: {
            Text(label)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(active ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                .foregroundColor(active ? Color.accentColor : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField((L10n.t("搜索应用", "Search apps")), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if filter != .all {
                Button {
                    primaryAction()
                } label: {
                    Text(primaryActionTitle)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .disabled(isScanning)
                .frame(width: 96)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if shownApps.isEmpty {
            emptyState
            Spacer()
        } else if filter == .all {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(shownApps) { app in
                        InstalledAppItem(app: app, selectedTab: $selectedTab, viewModel: viewModel)
                    }
                }
                .padding()
            }
        } else {
            List {
                ForEach(shownApps) { app in
                    InstalledAppRow(
                        app: app,
                        filter: filter,
                        updateURL: updateURL(for: app),
                        candidate: github.candidate(for: app.bundleID),
                        onDownload: { downloadManager.startDownload(url: $0) },
                        onInstall: { file in
                            if let problem = IPAValidation.problem(with: file) {
                                NotificationManager.shared.show(
                                    title: L10n.t("这个 ipa 装不了", "This .ipa cannot be installed"),
                                    message: problem,
                                    type: .error)
                                return
                            }
                            // Same path 2.0.4 used: hand the file straight to LiveContainer with
                            // `livecontainer://install?url=`, no share sheet in the way.
                            Task {
                                let handedOff = await downloadManager.handOffToLiveContainer(file, app: app)
                                if !handedOff {
                                    pendingInstall = PendingInstall(file: file, app: app)
                                }
                            }
                        },
                        onBind: { bindTarget = $0 },
                        onManualBind: { manualTarget = $0 }
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Text(L10n.t("没有应用", "No Apps"))
        } description: {
            Text(filter == .unbound
                 ? L10n.t("未绑定的应用还没有更新源，点「检查来源」扫描。",
                          "No update source yet. Tap Check Sources to scan.")
                 : L10n.t("解压到应用目录的 App 会显示在这里。",
                          "Apps installed into the applications folder show up here."))
        }
        .padding(.top, 40)
    }

    // MARK: - Actions

    /// Bound -> bulk download, unbound -> bind everything.
    private var primaryActionTitle: String {
        filter == .bound ? L10n.t("全部更新", "Update All") : L10n.t("全部绑定", "Bind All")
    }

    private func primaryAction() {
        switch filter {
        case .bound:
            downloadAll()
        case .unbound:
            // Open the candidate list straight away when we already have one.
            if github.candidates.isEmpty {
                Task { await scanSources() }
            } else {
                showAllSources = true
            }
        case .all:
            break
        }
    }

    private func downloadAll() {
        for app in boundApps {
            guard let url = updateURL(for: app) else { continue }
            if downloadManager.getLocalFile(for: url) != nil { continue }
            if downloadManager.downloadStates[url] != nil { continue }
            downloadManager.startDownload(url: url)
        }
    }

    private func checkUpdates() async {
        isScanning = true
        viewModel.checkForUpdates(installedApps: downloadManager.installedApps)
        await github.refresh(installedApps: downloadManager.installedApps,
                             storeApps: viewModel.displayApps)
                await BoundSourceFeed.sync(viewModel: viewModel, installedApps: downloadManager.installedApps)
        isScanning = false
    }

    private func scanSources() async {
        isScanning = true
        await github.refresh(installedApps: downloadManager.installedApps,
                             storeApps: viewModel.displayApps)
                await BoundSourceFeed.sync(viewModel: viewModel, installedApps: downloadManager.installedApps)
        isScanning = false
        if github.candidates.isEmpty {
            NotificationManager.shared.show(
                title: L10n.t("检查来源", "Check Sources"),
                message: L10n.t("没有找到可绑定的源", "No bindable source found"),
                type: .error
            )
        } else {
            showAllSources = true
        }
    }

    /// Guest apps run inside LiveContainer's own process, so there is no separate "home" to
    /// switch to: the launch route (same one the app icons use) is the only reliable entry.
    /// The store flow reaches LiveContainer through `livecontainer://install?url=…`, which makes
    /// LC bring its own UI up. Without a payload we use the same hosts (install / source /
    /// certificate) and only fall back to terminating the process.
    private func restartIntoLiveContainer() {
        let hosts = ["install", "source", "certificate"]
        openHost(hosts)
    }

    private func openHost(_ hosts: [String]) {
        guard let host = hosts.first, let url = URL(string: "livecontainer://\(host)") else {
            exit(0)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                openHost(Array(hosts.dropFirst()))
            }
        }
    }

    /// Copies the .ipa into tmp so the shared file can be consumed without losing the download.
    private func stageForSharing(_ file: URL) -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ShareStage", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: file, to: dest)
            return dest
        } catch {
            Logger.shared.log("ShareStage: copy failed \(error)")
            return file
        }
    }

    private func openLiveContainer() {
        let candidates = ["livecontainer://livecontainer-launch", "livecontainer://"]
        openFirst(candidates.map { URL(string: $0) }.compactMap { $0 })
    }

    private func openFirst(_ urls: [URL]) {
        guard let url = urls.first else {
            NotificationManager.shared.show(
                title: L10n.t("无法切换到 LiveContainer", "Cannot switch to LiveContainer"),
                message: L10n.t("请从后台多任务里切过去。", "Switch to it from the app switcher."),
                type: .info)
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { openFirst(Array(urls.dropFirst())) }
        }
    }
}

private struct PendingInstall {
    let file: URL
    let app: LocalApp
}

// MARK: - Row

struct InstalledAppRow: View {
    let app: LocalApp
    let filter: AppsFilter
    let updateURL: URL?
    let candidate: SourceCandidate?
    let onDownload: (URL) -> Void
    let onInstall: (URL) -> Void
    let onBind: (LocalApp) -> Void
    let onManualBind: (LocalApp) -> Void

    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body).lineLimit(1)
                Text(app.bundleID).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                if let version = app.version {
                    Text(version).font(.caption2).foregroundColor(.secondary)
                }
                if filter == .bound, updateURL == nil,
                   let diagnostic = GitHubSourceCenter.shared.debugState[app.bundleID] {
                    Text(diagnostic)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var icon: some View {
        if let url = app.iconURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().frame(width: 46, height: 46).cornerRadius(10)
        } else {
            Image(systemName: "app.fill").resizable().frame(width: 46, height: 46)
                .foregroundColor(.gray).cornerRadius(10)
        }
    }

    @ViewBuilder private var trailing: some View {
        if filter == .unbound {
            unboundTrailing
        } else {
            boundTrailing
        }
    }

    /// Unbound: one candidate -> Bind, none -> Unknown (opens the manual binding form).
    @ViewBuilder private var unboundTrailing: some View {
        if candidate != nil {
            Button((L10n.t("绑定", "Bind"))) { onBind(app) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        } else {
            Button((L10n.t("未知", "Unknown"))) { onManualBind(app) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// Bound: downloading / downloaded / update available / already up to date.
    @ViewBuilder private var boundTrailing: some View {
        if let url = updateURL {
            if let status = downloadManager.downloadStates[url] {
                switch status {
                case .downloading(let progress, _, _):
                    ProgressView(value: progress).frame(width: 56)
                case .paused, .waitingForConnection:
                    Button((L10n.t("继续", "Continue"))) { downloadManager.resumeDownload(url: url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                case .none:
                    EmptyView()
                }
            } else if let local = downloadManager.getLocalFile(for: url) {
                Button((L10n.t("安装", "Install"))) { onInstall(local) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button((L10n.t("下载", "Download"))) { onDownload(url) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            Button((L10n.t("最新", "Latest"))) { }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        }
    }
}

/// The little "switch to LiveContainer" pill: a plus and the gradient app tile, mirroring the
/// LiveContainer quick action.
struct LiveContainerPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.72, blue: 0.98),
                                              Color(red: 0.72, green: 0.24, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - App switcher

/// Launches another app the same way the grid icons do, without leaving My Apps first.
struct AppSwitcherSheet: View {
    let apps: [LocalApp]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var query = ""

    private var shown: [LocalApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Text(L10n.t("没有应用", "No Apps"))
                    } description: {
                        Text(L10n.t("还没有已安装的应用。", "No installed apps yet."))
                    }
                }
                ForEach(shown) { app in
                    Button {
                        launch(app)
                    } label: {
                        HStack(spacing: 12) {
                            if let url = app.iconURL,
                               let data = try? Data(contentsOf: url),
                               let image = UIImage(data: data) {
                                Image(uiImage: image).resizable()
                                    .frame(width: 34, height: 34).cornerRadius(8)
                            } else {
                                Image(systemName: "app.fill").resizable()
                                    .frame(width: 34, height: 34).foregroundColor(.gray)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).foregroundColor(.primary)
                                Text(app.version ?? app.bundleID)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(Text(L10n.t("切换到 App", "Switch App")))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(L10n.t("搜索应用", "Search apps")))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private func launch(_ app: LocalApp) {
        let name = app.url.lastPathComponent
        if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(name)") {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
}
