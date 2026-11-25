import Foundation

/// Turns the confirmed GitHub bindings into a normal AltStore style source, so bound apps also
/// show up in the store and can be reinstalled after being deleted.
///
/// The feed is a local JSON file registered as a regular repository, placed above the built-in
/// "Recommended" folder. Only *confirmed* bindings are included; when a binding disappears the
/// entry disappears on the next sync.
@MainActor
enum BoundSourceFeed {
    static let identifier = "livebox.bound"

    static var displayName: String {
        L10n.t("我的绑定", "My Bindings")
    }

    /// Cache of release lookups so a sync does not hit the API for every page visit.
    private static var releaseCache: [String: (date: Date, releases: [GitHubRelease])] = [:]
    private static let cacheLifetime: TimeInterval = 6 * 3600

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bound_feed.json")
    }

    private static func token() -> String? {
        let value = (UserDefaults.standard.string(forKey: "kGitHubToken") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func releases(for ref: GitHubSourceRef) async -> [GitHubRelease] {
        if let cached = releaseCache[ref.slug],
           Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.releases
        }
        do {
            let list = try await GitHubAPI.fetchReleases(ref, token: token())
            releaseCache[ref.slug] = (Date(), list)
            return list
        } catch {
            return releaseCache[ref.slug]?.releases ?? []
        }
    }

    /// Rebuilds `bound_feed.json` and refreshes the repository entry. Returns the app count.
    @discardableResult
    static func sync(viewModel: AppStoreViewModel, installedApps: [LocalApp]) async -> Int {
        let bindings = GitHubProvenanceStore.shared.sources.filter { $0.value.state == .confirmed }
        guard !bindings.isEmpty else { return 0 }

        var apps: [[String: Any]] = []
        for (bundleID, bound) in bindings {
            let appName = installedApps.first(where: { $0.bundleID == bundleID })?.name
            let list = await releases(for: bound.ref)
            let usable = list.filter { !$0.draft && $0.ipaAsset(matching: appName) != nil }
            guard let latest = usable.max(by: { VersionText.isNewer($1.version, than: $0.version) }),
                  let asset = latest.ipaAsset(matching: appName) else { continue }

            var entry: [String: Any] = [
                "name": appName ?? bundleID,
                "bundleIdentifier": bundleID,
                "version": latest.version,
                "downloadURL": asset.browserDownloadURL,
                "localizedDescription": L10n.t("来自绑定的 GitHub 源（\(bound.ref.slug)）",
                                               "From the bound GitHub source (\(bound.ref.slug))")
            ]
            if let date = latest.publishedAt { entry["versionDate"] = date }
            if let size = asset.size { entry["size"] = size }
            apps.append(entry)
        }

        let payload: [String: Any] = [
            "name": displayName,
            "identifier": identifier,
            "apps": apps
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return 0 }
        try? data.write(to: fileURL, options: .atomic)

        await ensureRepo(viewModel: viewModel, data: data)
        return apps.count
    }

    private static func ensureRepo(viewModel: AppStoreViewModel, data: Data) async {
        let target = fileURL.standardizedFileURL.absoluteString
        if let existing = viewModel.savedRepos.first(where: {
            $0.url?.standardizedFileURL.absoluteString == target
        }) {
            await viewModel.fetchRepo(id: existing.id)
            if viewModel.getRepo(existing.id)?.cachedApps?.isEmpty ?? true {
                applyLocally(viewModel: viewModel, repoID: existing.id, data: data)
            }
            return
        }

        let repo = SavedRepo(url: fileURL, name: displayName, isEnabled: true)
        viewModel.savedRepos.insert(repo, at: 0)
        viewModel.saveRepos()
        await viewModel.fetchRepo(id: repo.id)
        if viewModel.getRepo(repo.id)?.cachedApps?.isEmpty ?? true {
            applyLocally(viewModel: viewModel, repoID: repo.id, data: data)
        }
    }

    /// Fallback when URLSession refuses the file URL: decode ourselves and inject the result.
    private static func applyLocally(viewModel: AppStoreViewModel, repoID: String, data: Data) {
        guard var repo = viewModel.getRepo(repoID),
              let decoded = try? JSONDecoder().decode(RepoResponse.self, from: data) else { return }
        repo.name = displayName
        repo.cachedApps = decoded.apps.map { app in
            var copy = app
            copy.sourceRepoName = displayName
            return copy
        }
        repo.appCount = decoded.apps.count
        repo.fetchStatus = .success
        repo.isEnabled = true
        viewModel.updateNode(repo)
        viewModel.saveRepos()
        Task { await viewModel.refreshDisplayApps() }
    }
}
