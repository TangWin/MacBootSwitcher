import Foundation

/// 只有真实阶段事件推进状态；时间用于解释等待，不推算百分比。
struct OperationProgress: Identifiable {
    enum Status { case waiting, running, completed, failed, unknown, cancelled }
    let id: String
    let title: String
    var status: Status = .waiting
    var startedAt: TimeInterval?
    var elapsed: TimeInterval = 0
}

struct OperationEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
}
