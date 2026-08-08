import Foundation
import AppKit

@MainActor
class UsageHistoryService: ObservableObject {
    @Published var history = UsageHistory()

    private var terminationObserver: Any?
    let historyFileURL: URL

    private static let retentionInterval: TimeInterval = 30 * 86400 // 30 days

    // The canonical location is Application Support, which is accessible inside the
    // app sandbox and follows macOS data-storage conventions. The legacy location
    // (~/.config/claude-usage-bar/) is migrated on first use.
    private static var defaultHistoryFileURL: URL {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            // Fallback should never be reached on a standard macOS install.
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/claude-usage-bar/history.json")
        }
        let dir = appSupport.appendingPathComponent("claude-usage-bar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let destination = dir.appendingPathComponent("history.json")
        migrateLegacyHistoryFile(to: destination)
        return destination
    }

    private static func migrateLegacyHistoryFile(to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar/history.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        try? FileManager.default.moveItem(at: legacy, to: destination)
    }

    init(historyFileURL: URL? = nil) {
        self.historyFileURL = historyFileURL ?? Self.defaultHistoryFileURL
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushToDisk()
            }
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Load

    func loadHistory() {
        let url = historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            var loaded = try JSONDecoder.historyDecoder.decode(UsageHistory.self, from: data)
            loaded.dataPoints = pruned(loaded.dataPoints)
            history = loaded
        } catch {
            // Corrupt file — rename to .bak and start fresh
            let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            history = UsageHistory()
        }
    }

    // MARK: - Record

    func recordDataPoint(pct5h: Double, pct7d: Double) {
        let point = UsageDataPoint(pct5h: pct5h, pct7d: pct7d)
        history.dataPoints.append(point)
        flushToDisk()
    }

    // MARK: - Flush

    func flushToDisk() {
        history.dataPoints = pruned(history.dataPoints)

        guard let data = try? JSONEncoder.historyEncoder.encode(history) else { return }
        let url = historyFileURL
        let tempURL = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tempURL)
        guard FileManager.default.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            // replaceItemAt preserves the destination file's metadata by default, so an
            // existing file created by an older app version may still have world-readable
            // permissions. Enforce 0600 explicitly on every flush.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - Downsampling

    func downsampledPoints(for range: TimeRange) -> [UsageDataPoint] {
        let allPoints = history.dataPoints

        guard allPoints.count > range.targetPointCount else { return allPoints }

        let now = Date()
        let rangeStart = now.addingTimeInterval(-range.interval)
        let bucketCount = range.targetPointCount
        let bucketDuration = range.interval / Double(bucketCount)

        var buckets = [[UsageDataPoint]](repeating: [], count: bucketCount)

        for point in allPoints {
            let offset = point.timestamp.timeIntervalSince(rangeStart)
            var index = Int(offset / bucketDuration)
            if index < 0 { index = 0 }
            if index >= bucketCount { index = bucketCount - 1 }
            buckets[index].append(point)
        }

        return buckets.compactMap { bucket -> UsageDataPoint? in
            guard !bucket.isEmpty else { return nil }
            let avgPct5h = bucket.map(\.pct5h).reduce(0, +) / Double(bucket.count)
            let avgPct7d = bucket.map(\.pct7d).reduce(0, +) / Double(bucket.count)
            let avgTimestamp = bucket.map { $0.timestamp.timeIntervalSince1970 }.reduce(0, +) / Double(bucket.count)
            return UsageDataPoint(
                timestamp: Date(timeIntervalSince1970: avgTimestamp),
                pct5h: avgPct5h,
                pct7d: avgPct7d
            )
        }
    }

    // MARK: - Pruning

    private func pruned(_ points: [UsageDataPoint]) -> [UsageDataPoint] {
        let cutoff = Date().addingTimeInterval(-Self.retentionInterval)
        return points.filter { $0.timestamp >= cutoff }
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let historyDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let historyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
