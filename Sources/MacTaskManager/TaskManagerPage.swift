import Foundation

enum TaskManagerPage: String, CaseIterable, Identifiable {
    case processes = "进程", performance = "性能", fans = "风扇控制", history = "应用历史记录"
    case startup = "启动应用", users = "用户", details = "详细信息", services = "服务", settings = "设置"
    var id: String { rawValue }
    static var navigationPages: [Self] { allCases.filter { $0 != .settings } }
    var searchable: Bool { ![.performance, .fans, .settings].contains(self) }
    var icon: String {
        switch self {
        case .processes: return "square.grid.2x2"
        case .performance: return "waveform.path.ecg"
        case .fans: return "fanblades"
        case .history: return "clock.arrow.circlepath"
        case .startup: return "speedometer"
        case .users: return "person.2"
        case .details: return "list.bullet"
        case .services: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }
}
