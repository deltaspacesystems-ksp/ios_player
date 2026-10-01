import Foundation
import SwiftUI
import UIKit

enum LogLevel: Int, Codable, CaseIterable, Identifiable, Comparable {
    case debug = 0, info, warning, error
    var id: Int { rawValue }
    var label: String { ["DEBUG", "INFO", "WARN", "ERROR"][rawValue] }
    var title: String { ["Debug", "Info", "Warning", "Error"][rawValue] }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// App-wide logger: in-memory ring buffer + rotating file, exportable via the share sheet.
final class Log: @unchecked Sendable {
    static let shared = Log()

    var minLevel: LogLevel = .info
    var toFile = true

    private let q = DispatchQueue(label: "lumen.log", qos: .utility)
    private var lines: [String] = []
    private let dir: URL
    private let file: URL
    private let rotated: URL
    private let marker: URL
    private let df: DateFormatter

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("lumen-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("lumen.log")
        rotated = dir.appendingPathComponent("lumen.1.log")
        marker = dir.appendingPathComponent("running.marker")
        df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        // restore the tail of the previous log so the viewer isn't empty after relaunch
        if let d = try? String(contentsOf: file, encoding: .utf8) {
            lines = Array(d.split(separator: "\n", omittingEmptySubsequences: true).suffix(1500).map(String.init))
        }
    }

    static func d(_ cat: String, _ msg: @autoclosure () -> String) { shared.log(.debug, cat, msg()) }
    static func i(_ cat: String, _ msg: @autoclosure () -> String) { shared.log(.info, cat, msg()) }
    static func w(_ cat: String, _ msg: @autoclosure () -> String) { shared.log(.warning, cat, msg()) }
    static func e(_ cat: String, _ msg: @autoclosure () -> String) { shared.log(.error, cat, msg()) }

    func log(_ level: LogLevel, _ cat: String, _ msg: String) {
        guard level >= minLevel else { return }
        let now = Date()
        q.async {
            let line = "\(self.df.string(from: now)) [\(level.label)] \(cat): \(msg)"
            self.append(line)
        }
    }

    /// Synchronous write for crash handlers.
    func logSync(_ level: LogLevel, _ cat: String, _ msg: String) {
        q.sync {
            let line = "\(self.df.string(from: Date())) [\(level.label)] \(cat): \(msg)"
            self.append(line)
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 3000 { lines.removeFirst(500) }
        guard toFile, let data = (line + "\n").data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: file.path) {
            try? data.write(to: file)
            return
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_500_000 {
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: file, to: rotated)
            try? data.write(to: file)
            return
        }
        if let h = try? FileHandle(forWritingTo: file) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        }
    }

    func snapshot() -> [String] { q.sync { lines } }

    func clear() {
        q.sync {
            lines.removeAll()
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: rotated)
        }
    }

    /// Builds a single text file (device info + older + current log) ready for the share sheet.
    func exportFile() -> URL {
        let info = Log.deviceInfo()
        var body = info + "\n----- log -----\n"
        q.sync {
            if let old = try? String(contentsOf: rotated, encoding: .utf8) { body += old }
            if let cur = try? String(contentsOf: file, encoding: .utf8) { body += cur }
            else { body += lines.joined(separator: "\n") }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumen-log-\(f.string(from: Date())).txt")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func deviceInfo() -> String {
        let b = Bundle.main
        let v = b.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let n = b.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let d = UIDevice.current
        return """
        Lumen \(v) (\(n))
        Device: \(d.model), iOS \(d.systemVersion)
        Memory: \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB
        Low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)
        Locale: \(Locale.current.identifier)
        """
    }

    // MARK: Session / crash tracking

    func startSession() {
        if FileManager.default.fileExists(atPath: marker.path) {
            Log.w("session", "Previous session ended abnormally (crash, or app killed while active)")
        }
        Log.i("session", "Launch — " + Log.deviceInfo().replacingOccurrences(of: "\n", with: " | "))
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [marker] _ in
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [marker] _ in
                try? FileManager.default.removeItem(at: marker)
            }
        }
        NSSetUncaughtExceptionHandler { e in
            Log.shared.logSync(.error, "crash", "Uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                Log.shared.logSync(.error, "crash", "Fatal signal \(s)")
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}

// MARK: - Viewer (Settings → Logs)

struct LogViewer: View {
    @EnvironmentObject var player: Player
    @State private var lines: [String] = []
    @State private var query = ""
    @State private var minShown: LogLevel = .debug
    @State private var exportURL: URL?

    private var shown: [String] {
        lines.filter { l in
            guard minShown == .debug || levelOf(l) >= minShown else { return false }
            return query.isEmpty || l.localizedCaseInsensitiveContains(query)
        }
    }

    private func levelOf(_ l: String) -> LogLevel {
        if l.contains("[ERROR]") { return .error }
        if l.contains("[WARN]") { return .warning }
        if l.contains("[INFO]") { return .info }
        return .debug
    }

    private func color(_ l: String) -> Color {
        switch levelOf(l) {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        case .debug: return .secondary
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Record level", selection: $player.cfg.logLevel) {
                    ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Save log to file", isOn: $player.cfg.logToFile)
            } footer: {
                Text("Debug level is very verbose. Use it only while reproducing a problem.")
            }
            Section {
                Button("Prepare log for sending", systemImage: "paperplane") { exportURL = Log.shared.exportFile() }
                if let url = exportURL {
                    ShareLink(item: url, subject: Text("Lumen log"), message: Text("Lumen log attached")) {
                        Label("Share / send \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Clear log", systemImage: "trash", role: .destructive) {
                    Log.shared.clear()
                    lines = []
                    exportURL = nil
                }
            }
            Section("Entries (\(shown.count))") {
                Picker("Show", selection: $minShown) {
                    ForEach(LogLevel.allCases) { Text($0.title + "+").tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(Array(shown.suffix(400).enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 10, design: .monospaced)).foregroundStyle(color(l)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .task {
            while !Task.isCancelled {
                lines = Log.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
