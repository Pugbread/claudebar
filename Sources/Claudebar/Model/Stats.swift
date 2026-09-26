import Foundation

/// Totals for the current calendar day, persisted across launches.
struct DayStats: Codable, Equatable {
    var day: String
    var activeSeconds: Double = 0
    var turns = 0
    var added = 0
    var removed = 0
    var tools = 0

    private static let defaultsKey = "dayStats"

    static func key(for date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func load() -> DayStats {
        let today = key()
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stats = try? JSONDecoder().decode(DayStats.self, from: data),
           stats.day == today {
            return stats
        }
        return DayStats(day: today)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// A finished turn, kept briefly for the idle panel.
struct TurnSummary: Identifiable {
    let id = UUID()
    let project: String
    let hostBundleID: String?
    let outcome: Phase
    let duration: TimeInterval
    let delta: LineDelta
    let tools: Int
    let endedAt: Date
}
