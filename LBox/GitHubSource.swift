//
//  GitHubSource.swift
//  LBox
//
//  GitHub release tracking for installed apps.
//
//  Flow:
//  1. resolver proposes a repository for an installed app
//     (exact download URL -> store download URL -> GitHub search)
//  2. the proposal stays "pending" until the user confirms it in the UI
//  3. only confirmed repositories are used to check for updates
//

import Foundation
import Combine

// MARK: - Models

struct GitHubSourceRef: Codable, Hashable, Sendable {
    let owner: String
    let repo: String

    var slug: String { "\(owner)/\(repo)" }

    var webURL: String { "https://github.com/\(owner)/\(repo)" }

    var releasesURL: URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=50")
    }
}

struct GitHubRelease: Codable, Sendable, Identifiable {
    struct Asset: Codable, Sendable {
        let name: String
        let browserDownloadURL: String
        let size: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let id: Int
    let tagName: String
    let name: String?
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case prerelease
        case draft
        case publishedAt = "published_at"
        case assets
    }

    var version: String { VersionText.normalize(tagName) }

    /// Best .ipa asset of this release, preferring one whose file name matches the app.
    func ipaAsset(matching appName: String?) -> Asset? {
        let ipaAssets = assets.filter { $0.name.lowercased().hasSuffix(".ipa") }
        guard !ipaAssets.isEmpty else { return nil }
        if let appName, !appName.isEmpty {
            let needle = appName.lowercased().replacingOccurrences(of: " ", with: "")
            if let match = ipaAssets.first(where: {
                $0.name.lowercased().replacingOccurrences(of: " ", with: "").contains(needle)
            }) {
                return match
            }
        }
        return ipaAssets.first
    }
}

struct GitHubUpdateInfo: Equatable, Sendable {
    enum Kind: String, Sendable {
        case stable
        case prerelease
    }

    let kind: Kind
    let version: String
    let downloadURL: String
    let tag: String
}

/// How the repository was found, shown to the user before confirming.
enum SourceConfidence: String, Codable, Sendable {
    case download
    case store
    case search
    case manual

    var label: String {
        switch self {
        case .download: return "下载记录"
        case .store: return "源匹配"
        case .search: return "搜索匹配"
        case .manual: return "手动"
        }
    }

    var isExact: Bool {
        self != .search
    }
}

/// Result of looking a repository up before binding it by hand.
enum SourceLookupOutcome {
    case ok(SourcePreview)
    case noAsset
    case failed(String)
}

/// Preview of a repository before binding it by hand.
struct SourcePreview: Equatable {
    let version: String
    let isPrerelease: Bool
    let assetName: String?
}

enum SourceState: String, Codable, Sendable {
    case pending
    case confirmed
    case ignored
}

struct BoundSource: Codable, Sendable {
    var ref: GitHubSourceRef
    var state: SourceState
    var confidence: SourceConfidence
    var updatedAt: Date
}

/// Transfer payload for exporting/importing bindings between installs.
struct GitHubBindingsExport: Codable {
    var version: Int
    var bindings: [String: BoundSource]
}

/// A proposal waiting for the user's confirmation.
struct SourceCandidate: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let iconURL: URL?
    let ref: GitHubSourceRef
    let confidence: SourceConfidence
    let latestVersion: String?
    let latestAssetURL: String?
    let latestAssetName: String?
    let latestIsPrerelease: Bool
}

// MARK: - Version helpers

enum VersionText {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalize(candidate)
        let b = normalize(current)
        if a.isEmpty { return false }
        if b.isEmpty { return true }
        // An installed version like "nightly" or "build-42" cannot be ordered against "3.8.0":
        // comparing the strings would report "nightly" as newer and hide every real update.
        if let first = b.first, !first.isNumber { return true }
        if a == b { return false }
        return a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Fallback only: used when the GitHub API flag is not available.
    static func looksPrerelease(_ raw: String) -> Bool {
        let s = raw.lowercased()
        let markers = ["alpha", "beta", "rc", "preview", "pre", "dev", "nightly", "canary"]
        for marker in markers {
            if s.contains(marker) { return true }
        }
        return false
    }
}

// MARK: - Link parsing

enum GitHubLink {
    /// Extracts owner/repo from any GitHub release, API or archive URL.
    static func sourceRef(from urlString: String) -> GitHubSourceRef? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map { String($0) }
        guard !parts.isEmpty else { return nil }

        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2 else { return nil }
            if parts.count == 2 {
                return makeRef(parts[0], parts[1])
            }
            let section = parts[2]
            if section == "releases" || section == "archive" || section == "raw" || section == "blob" {
                return makeRef(parts[0], parts[1])
            }
            return nil
        }

        if host == "api.github.com" {
            guard parts.count >= 3, parts[0] == "repos" else { return nil }
            return makeRef(parts[1], parts[2])
        }

        return nil
    }

    static func makeRef(_ owner: String, _ repo: String) -> GitHubSourceRef? {
        var name = repo
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        return GitHubSourceRef(owner: owner, repo: name)
    }

    /// Accepts a full GitHub URL, a releases URL, or a bare "owner/repo".
    static func parseLoose(_ text: String) -> GitHubSourceRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        if let ref = sourceRef(from: candidate) {
            return ref
        }

        let parts = trimmed.split(separator: "/")
        if parts.count == 2 {
            return makeRef(String(parts[0]), String(parts[1]))
        }
        return nil
    }
}

// MARK: - Network

enum GitHubAPIError: LocalizedError {
    case http(Int)
    case rateLimited
    case badPayload

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "GitHub API 限额已用尽（未填 token 时每小时 60 次）"
        case .http(let code):
            return "GitHub 返回 HTTP \(code)"
        case .badPayload:
            return "无法解析 GitHub 的返回内容"
        }
    }
}

enum GitHubAPI {
    static func fetchReleases(_ ref: GitHubSourceRef, token: String?) async throws -> [GitHubRelease] {
        guard let url = ref.releasesURL else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LBox", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw GitHubAPIError.rateLimited
            }
            throw GitHubAPIError.http(http.statusCode)
        }
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            throw GitHubAPIError.badPayload
        }
        return releases
    }

    static func searchRepositories(_ query: String, token: String?) async -> [GitHubSourceRef] {
        guard var comps = URLComponents(string: "https://api.github.com/search/repositories") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: "5")
        ]
        guard let url = comps.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LBox", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { return [] }

            var refs: [GitHubSourceRef] = []
            for item in items {
                guard let fullName = item["full_name"] as? String else { continue }
                let pieces = fullName.split(separator: "/")
                guard pieces.count == 2 else { continue }
                if let ref = GitHubLink.makeRef(String(pieces[0]), String(pieces[1])) {
                    refs.append(ref)
                }
            }
            return refs
        } catch {
            return []
        }
    }
}

// MARK: - Provenance store

@MainActor
final class GitHubProvenanceStore: ObservableObject {
    static let shared = GitHubProvenanceStore()

    @Published private(set) var sources: [String: BoundSource] = [:]

    private let storageURL: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageURL = folder.appendingPathComponent("github_sources.json")
        load()
    }

    func binding(for bundleID: String) -> BoundSource? {
        sources[bundleID]
    }

    func confirmedSource(for bundleID: String) -> GitHubSourceRef? {
        guard let bound = sources[bundleID], bound.state == .confirmed else { return nil }
        return bound.ref
    }

    func setRef(_ ref: GitHubSourceRef, state: SourceState, confidence: SourceConfidence, for bundleID: String) {
        guard !bundleID.isEmpty, bundleID != "unknown" else { return }
        sources[bundleID] = BoundSource(ref: ref, state: state, confidence: confidence, updatedAt: Date())
        save()
    }

    func setState(_ state: SourceState, for bundleID: String) {
        guard var bound = sources[bundleID] else { return }
        bound.state = state
        bound.updatedAt = Date()
        sources[bundleID] = bound
        save()
    }

    func removeBinding(for bundleID: String) {
        guard sources[bundleID] != nil else { return }
        sources.removeValue(forKey: bundleID)
        save()
    }

    /// Exact provenance: the .ipa was downloaded from this URL.
    /// A confirmed binding is permanent and is never downgraded automatically.
    func proposeFromDownloadURL(_ urlString: String, bundleID: String) {
        guard let ref = GitHubLink.sourceRef(from: urlString) else { return }
        if let existing = sources[bundleID] {
            if existing.state == .confirmed { return }
            if existing.state == .ignored, existing.ref == ref { return }
        }
        setRef(ref, state: .pending, confidence: .download, for: bundleID)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: BoundSource].self, from: data) {
            sources = decoded
        }
    }

    private func save() {
        let folder = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}

// MARK: - Update center

@MainActor
final class GitHubSourceCenter: ObservableObject {
    static let shared = GitHubSourceCenter()

    /// Bundle ID -> update that comes from the app's confirmed GitHub repository.
    @Published private(set) var updates: [String: GitHubUpdateInfo] = [:]
    /// Bundle ID -> newest release of its bound repository, newer or not. Lets the app list offer
    /// a download even when the installed build is already the latest one.
    @Published private(set) var latest: [String: GitHubUpdateInfo] = [:]
    /// Last request failure, so the UI can tell "rate limited" apart from "no .ipa in the repo".
    @Published private(set) var lastError: String? = nil
    /// Per-app explanation shown under a bound app: what was compared and what came back.
    @Published private(set) var debugState: [String: String] = [:]
    /// Proposals waiting for confirmation.
    @Published private(set) var candidates: [SourceCandidate] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var statusText: String = ""

    private var releaseCache: [String: (date: Date, releases: [GitHubRelease])] = [:]
    private var discoveryDates: [String: Date] = [:]
    private var lastInstalledApps: [LocalApp] = []
    private var lastStoreApps: [AppItem] = []

    private let cacheLifetime: TimeInterval = 600
    private let discoveryCooldown: TimeInterval = 3600

    private var token: String {
        (UserDefaults.standard.string(forKey: "kGitHubToken") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var includePrereleases: Bool {
        UserDefaults.standard.object(forKey: "kIncludePrereleaseUpdates") as? Bool ?? true
    }

    func update(for bundleID: String) -> GitHubUpdateInfo? {
        updates[bundleID]
    }

    func candidate(for bundleID: String) -> SourceCandidate? {
        candidates.first(where: { $0.bundleID == bundleID })
    }

    func confirmedSlug(for bundleID: String) -> String? {
        GitHubProvenanceStore.shared.confirmedSource(for: bundleID)?.slug
    }

    func clearCache() {
        releaseCache.removeAll()
        discoveryDates.removeAll()
    }

    // MARK: Refresh

    func refresh(installedApps: [LocalApp], storeApps: [AppItem]) async {
        guard !isRefreshing, !installedApps.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        lastInstalledApps = installedApps
        lastStoreApps = storeApps

        // Fallback provenance: the store entry LBox already matched by bundle ID.
        var hintURLs: [String: String] = [:]
        for item in storeApps {
            if hintURLs[item.bundleIdentifier] == nil {
                hintURLs[item.bundleIdentifier] = item.downloadURL
            }
        }

        var newUpdates: [String: GitHubUpdateInfo] = [:]
        var pending: [SourceCandidate] = []
        var debug: [String: String] = [:]
        var linked = 0

        for app in installedApps {
            let bundleID = app.bundleID
            guard !bundleID.isEmpty, bundleID != "unknown" else { continue }

            // 1. Resolve a repository if we do not have one yet.
            var binding = GitHubProvenanceStore.shared.binding(for: bundleID)
            if binding == nil, let hint = hintURLs[bundleID], let parsed = GitHubLink.sourceRef(from: hint) {
                GitHubProvenanceStore.shared.setRef(parsed, state: .pending, confidence: .store, for: bundleID)
                binding = GitHubProvenanceStore.shared.binding(for: bundleID)
            }
            if binding == nil {
                if let found = await discoverSource(for: app) {
                    GitHubProvenanceStore.shared.setRef(found, state: .pending, confidence: .search, for: bundleID)
                    binding = GitHubProvenanceStore.shared.binding(for: bundleID)
                }
            }

            guard let bound = binding, bound.state != .ignored else { continue }

            // 2. Pending: describe the proposal so the user can confirm it.
            if bound.state == .pending {
                let list = await releases(for: bound.ref)
                let usable = list.filter { !$0.draft && $0.ipaAsset(matching: app.name) != nil }
                let latest = usable.max(by: { VersionText.isNewer($1.version, than: $0.version) })
                let asset = latest?.ipaAsset(matching: app.name)
                pending.append(SourceCandidate(
                    bundleID: bundleID,
                    appName: app.name,
                    iconURL: app.iconURL,
                    ref: bound.ref,
                    confidence: bound.confidence,
                    latestVersion: latest?.version,
                    latestAssetURL: asset?.browserDownloadURL,
                    latestAssetName: asset?.name,
                    latestIsPrerelease: latest?.prerelease ?? false
                ))
                continue
            }

            // 3. Confirmed: check updates.
            linked += 1
            let list = await releases(for: bound.ref)
            let usable = list.filter { !$0.draft && $0.ipaAsset(matching: app.name) != nil }

            if let newest = usable.max(by: { VersionText.isNewer($1.version, than: $0.version) }),
               let newestAsset = newest.ipaAsset(matching: app.name) {
                latest[bundleID] = GitHubUpdateInfo(
                    kind: newest.prerelease ? .prerelease : .stable,
                    version: newest.version,
                    downloadURL: newestAsset.browserDownloadURL,
                    tag: newest.tagName
                )
            } else {
                latest.removeValue(forKey: bundleID)
            }

            let stable = usable.filter { !$0.prerelease }
                .max(by: { VersionText.isNewer($1.version, than: $0.version) })
            let pre = usable.filter { $0.prerelease }
                .max(by: { VersionText.isNewer($1.version, than: $0.version) })

            let current = app.version ?? ""
            var chosen: GitHubRelease? = nil
            var chosenKind: GitHubUpdateInfo.Kind = .stable

            if includePrereleases, let preRelease = pre {
                if current.isEmpty || VersionText.isNewer(preRelease.version, than: current) {
                    chosen = preRelease
                    chosenKind = .prerelease
                }
            }
            if chosen == nil, let stableRelease = stable {
                if current.isEmpty || VersionText.isNewer(stableRelease.version, than: current) {
                    chosen = stableRelease
                    chosenKind = .stable
                }
            }

            let installed = app.version ?? ""
            let stableText = stable.map { VersionText.normalize($0.version) } ?? "-"
            let preText = pre.map { VersionText.normalize($0.version) } ?? "-"
            if let release = chosen {
                debug[bundleID] = "installed \(installed.isEmpty ? "?" : installed) · stable \(stableText) · pre \(preText) · newer: \(release.version)"
            } else if let error = lastError {
                debug[bundleID] = "installed \(installed.isEmpty ? "?" : installed) · request failed: \(error)"
            } else {
                debug[bundleID] = "installed \(installed.isEmpty ? "?" : installed) · stable \(stableText) · pre \(preText) · up to date"
            }

            if let release = chosen, let asset = release.ipaAsset(matching: app.name) {
                newUpdates[bundleID] = GitHubUpdateInfo(
                    kind: chosenKind,
                    version: release.version,
                    downloadURL: asset.browserDownloadURL,
                    tag: release.tagName
                )
            }
        }

        pending.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        updates = newUpdates
        candidates = pending
        debugState = debug
        if let error = lastError {
            statusText = "GitHub: \(linked) confirmed, \(pending.count) pending · \(error)"
        } else {
            statusText = "GitHub: \(linked) confirmed, \(pending.count) pending"
        }
    }

    // MARK: Confirmation

    func confirm(_ bundleID: String) async {
        GitHubProvenanceStore.shared.setState(.confirmed, for: bundleID)
        if let index = candidates.firstIndex(where: { $0.bundleID == bundleID }) {
            candidates.remove(at: index)
        }
        await refresh(installedApps: lastInstalledApps, storeApps: lastStoreApps)
    }

    func ignore(_ bundleID: String) {
        GitHubProvenanceStore.shared.setState(.ignored, for: bundleID)
        if let index = candidates.firstIndex(where: { $0.bundleID == bundleID }) {
            candidates.remove(at: index)
        }
    }

    /// Puts the app back into the "needs confirmation" state.
    func recheckSource(for bundleID: String) async {
        guard let bound = GitHubProvenanceStore.shared.binding(for: bundleID) else { return }
        GitHubProvenanceStore.shared.setRef(bound.ref, state: .pending, confidence: bound.confidence, for: bundleID)
        await refresh(installedApps: lastInstalledApps, storeApps: lastStoreApps)
    }

    /// Used by the manual binding screen to show what a link actually points at.
    func previewSource(_ ref: GitHubSourceRef, appName: String) async -> SourceLookupOutcome {
        let list = await releases(for: ref)
        if list.isEmpty, let error = lastError {
            return .failed(error)
        }
        let usable = list.filter { !$0.draft && $0.ipaAsset(matching: appName) != nil }
        guard let latest = usable.max(by: { VersionText.isNewer($1.version, than: $0.version) }) else {
            return .noAsset
        }
        let asset = latest.ipaAsset(matching: appName)
        return .ok(SourcePreview(
            version: latest.version,
            isPrerelease: latest.prerelease,
            assetName: asset?.name
        ))
    }

    /// Binds a repository typed in by the user. Confirmed immediately.
    func bindManually(bundleID: String, ref: GitHubSourceRef) async {
        releaseCache.removeValue(forKey: ref.slug)
        GitHubProvenanceStore.shared.setRef(ref, state: .confirmed, confidence: .manual, for: bundleID)
        candidates.removeAll { $0.bundleID == bundleID }
        await refresh(installedApps: lastInstalledApps, storeApps: lastStoreApps)
    }

    // MARK: Transfer

    /// Serialises every binding so it can be carried over to a new install or a new bundle ID.
    func exportBindingsJSON() -> String {
        let payload = GitHubBindingsExport(version: 1, bindings: GitHubProvenanceStore.shared.sources)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Merges bindings from a previously exported payload. Returns how many were applied.
    @discardableResult
    func importBindingsJSON(_ text: String) -> Int {
        guard let data = text.data(using: .utf8) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(GitHubBindingsExport.self, from: data) else { return 0 }
        var applied = 0
        for (bundleID, bound) in payload.bindings where !bundleID.isEmpty {
            GitHubProvenanceStore.shared.setRef(bound.ref,
                                                state: bound.state,
                                                confidence: bound.confidence,
                                                for: bundleID)
            applied += 1
        }
        if applied > 0 {
            Task { await refresh(installedApps: lastInstalledApps, storeApps: lastStoreApps) }
        }
        return applied
    }

    // MARK: Helpers

    private func releases(for ref: GitHubSourceRef) async -> [GitHubRelease] {
        let key = ref.slug
        if let cached = releaseCache[key], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.releases
        }
        do {
            let list = try await GitHubAPI.fetchReleases(ref, token: token)
            releaseCache[key] = (Date(), list)
            if lastError != nil { lastError = nil }
            return list
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if lastError != message { lastError = message }
            return releaseCache[key]?.releases ?? []
        }
    }

    /// Best-effort reverse lookup for apps whose source is unknown.
    /// Requires strong evidence: a release asset that actually contains the app name.
    private func discoverSource(for app: LocalApp) async -> GitHubSourceRef? {
        let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return nil }

        if let last = discoveryDates[name], Date().timeIntervalSince(last) < discoveryCooldown {
            return nil
        }
        discoveryDates[name] = Date()

        let found = await GitHubAPI.searchRepositories("\(name) ipa", token: token)
        let needle = name.lowercased().replacingOccurrences(of: " ", with: "")

        for ref in found.prefix(3) {
            let list = await releases(for: ref)
            for release in list where !release.draft {
                guard let asset = release.ipaAsset(matching: name) else { continue }
                let assetName = asset.name.lowercased().replacingOccurrences(of: " ", with: "")
                if assetName.contains(needle) {
                    return ref
                }
            }
        }
        return nil
    }
}
