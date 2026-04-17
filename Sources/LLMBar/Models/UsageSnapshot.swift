import Foundation

struct UsageWindow: Codable, Hashable {
    var label: String
    var usedPercent: Double?
    var tokens: Int?
    var resetsAt: Date?
}

struct UsageSnapshot: Codable, Hashable {
    var fetchedAt: Date
    var windows: [UsageWindow]
    var note: String?
}

enum UsageState {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case error(String)
}
