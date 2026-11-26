import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Checks an .ipa before it is handed to LiveContainer.
///
/// LiveContainer throws "app bundle not found" / "unable to read LCAppInfo.plist" when the
/// archive has no `Payload/<name>.app/Info.plist`. Catching that here keeps broken downloads
/// from turning into confusing install failures.
enum IPAValidation {
    /// Reads CFBundleIdentifier out of `Payload/<name>.app/Info.plist` (nil when unreadable).
    static func bundleIdentifier(in url: URL) -> String? {
        #if canImport(ZIPFoundation)
        guard let archive = Archive(url: url, accessMode: .read) else { return nil }
        for entry in archive {
            let path = entry.path
            guard path.hasPrefix("Payload/"), path.hasSuffix(".app/Info.plist") else { continue }
            guard path.split(separator: "/").count == 3 else { continue }
            var data = Data()
            guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String,
                  !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return bundleID
        }
        return nil
        #else
        return nil
        #endif
    }
    static func problem(with url: URL) -> String? {
        guard url.pathExtension.lowercased() == "ipa" else {
            return L10n.t("这不是 ipa 文件", "Not an .ipa file")
        }
        #if canImport(ZIPFoundation)
        guard let archive = Archive(url: url, accessMode: .read) else {
            return L10n.t("ipa 打不开（可能没下载完或已损坏）", "Cannot open the .ipa (truncated or corrupt)")
        }
        for entry in archive {
            let path = entry.path
            guard path.hasPrefix("Payload/"), path.hasSuffix(".app/Info.plist") else { continue }
            let pieces = path.split(separator: "/")
            guard pieces.count == 3 else { continue }
            var data = Data()
            guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String,
                  !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return L10n.t("ipa 里的 Info.plist 读不出 Bundle ID", "The .ipa has an unreadable Info.plist")
            }
            return nil
        }
        return L10n.t("ipa 里没有 Payload/xxx.app/Info.plist，LiveContainer 装不了",
                      "No Payload/<app>.app/Info.plist inside the .ipa, LiveContainer cannot install it")
        #else
        return nil
        #endif
    }
}
