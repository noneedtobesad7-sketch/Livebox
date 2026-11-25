import Foundation

/// Controls how often the store re-downloads its repository JSON.
///
/// Before this, every launch ran `fetchAllRepos()` through the 15-minute auto-check, so opening
/// the store always pulled every source again. The interval is now a user setting (1–3 days).
enum SourceRefresh {
    static let daysKey = "kSourceRefreshDays"
    static let lastFetchKey = "kSourceLastFetchDate"

    /// 1…3 days, defaulting to 1.
    static var days: Int {
        let stored = UserDefaults.standard.integer(forKey: daysKey)
        return (1...3).contains(stored) ? stored : 1
    }

    static var lastFetch: Date? {
        UserDefaults.standard.object(forKey: lastFetchKey) as? Date
    }

    static func shouldRefresh(now: Date = Date()) -> Bool {
        guard let last = lastFetch else { return true }
        return now.timeIntervalSince(last) >= Double(days) * 24 * 3600
    }

    static func markFetched(_ date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: lastFetchKey)
    }
}
