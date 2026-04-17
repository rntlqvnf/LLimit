import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }
}

struct Account: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: Provider
    var configDir: String
}
