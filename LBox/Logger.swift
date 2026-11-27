import Foundation
import SwiftUI
import Combine

/// Lightweight file logger. Compiled in for Release too, and switched on/off from
/// Settings -> Logs (`kLoggingEnabled`).
final class Logger: ObservableObject {
    static let shared = Logger()

    @Published private(set) var logs: String = ""

    private let queue = DispatchQueue(label: "livebox.log", qos: .utility)
    private let maxBytes = 1_000_000
    private let keepFiles = 3
    private let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "kLoggingEnabled") as? Bool ?? true
    }

    var directoryURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Livebox/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var logFileURL: URL { directoryURL.appendingPathComponent("app.log") }

    var currentSize: Int {
        ((try? FileManager.default.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int) ?? 0
    }

    private init() { loadTail() }

    func log(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERR", message) }

    func exportURL() -> URL { logFileURL }

    func clear() {
        logs = ""
        queue.async { try? FileManager.default.removeItem(at: self.logFileURL) }
    }

    private func write(_ level: String, _ message: String) {
        guard isEnabled else { return }
        let line = "\(stampFormatter.string(from: Date())) [\(level)] \(Self.redact(message))\n"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logs += line
            if self.logs.count > 40_000 { self.logs = String(self.logs.suffix(20_000)) }
        }
        queue.async { [weak self] in self?.append(line) }
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int, size > maxBytes {
            rotate()
        }
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }

    private func rotate() {
        let fm = FileManager.default
        for index in stride(from: keepFiles - 1, through: 1, by: -1) {
            let src = directoryURL.appendingPathComponent("app.\(index).log")
            let dst = directoryURL.appendingPathComponent("app.\(index + 1).log")
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }
        try? fm.removeItem(at: directoryURL.appendingPathComponent("app.1.log"))
        if fm.fileExists(atPath: logFileURL.path) {
            try? fm.moveItem(at: logFileURL, to: directoryURL.appendingPathComponent("app.1.log"))
        }
    }

    private func loadTail() {
        guard let text = try? String(contentsOf: logFileURL, encoding: .utf8) else { return }
        logs = String(text.suffix(20_000))
    }

    /// Home directory -> `~`, tokens masked. Nothing secret is written on purpose.
    private static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        value = value.replacingOccurrences(of: "(github_pat_)[A-Za-z0-9_]+", with: "$1***", options: .regularExpression)
        value = value.replacingOccurrences(of: "(token=)[^&\\s]+", with: "$1***", options: .regularExpression)
        return value
    }
}

/// Settings -> Logs -> Recent log.
struct DebugLogView: View {
    @ObservedObject var logger = Logger.shared

    var body: some View {
        List {
            Text(logger.logs.isEmpty ? L10n.t("暂无日志", "No logs yet") : logger.logs)
                .font(.system(.caption, design: .monospaced))
        }
        .navigationTitle(L10n.t("最近日志", "Recent log"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = logger.logs
                } label: { Image(systemName: "doc.on.doc") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    logger.clear()
                } label: { Image(systemName: "trash") }
            }
        }
    }
}
