import Foundation

struct UsageDataPoint: Codable, Identifiable {
    // id is derived from timestamp — deterministic, not stored on disk
    var id: Date { timestamp }
    let timestamp: Date
    let pct5h: Double
    let pct7d: Double

    init(timestamp: Date = Date(), pct5h: Double, pct7d: Double) {
        self.timestamp = timestamp
        self.pct5h = pct5h
        self.pct7d = pct7d
    }
}

struct UsageHistory: Codable {
    var dataPoints: [UsageDataPoint] = []
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hour6 = "6h"
    case day1 = "1d"
    case day7 = "7d"
    case day30 = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1:  return 60    // 1 point/min — matches polling cadence
        case .hour6:  return 120   // 1 point per 3 min
        case .day1:   return 144   // 1 point per 10 min
        case .day7:   return 336   // 1 point per 30 min
        case .day30:  return 360   // 1 point per 2 hours
        }
    }
}
