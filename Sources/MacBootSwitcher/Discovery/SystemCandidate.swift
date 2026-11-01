import Foundation

/// macOS 系统候选的稳定身份与展示信息
struct SystemCandidate: Identifiable, Equatable, Sendable {
    /// 使用 APFS 卷组 UUID 作为稳定身份，不随挂载路径或设备编号变化
    let volumeGroupID: String
    /// 系统卷 UUID（APFS Volume UUID，Role=System）
    let systemVolumeUUID: String
    /// 显示名称（来自系统卷的 VolumeName）
    let name: String
    /// 可读版本号（如 "macOS 15.2"），可能为 nil（未挂载或读取失败）
    let version: String?
    /// 是否为内置磁盘
    let isInternal: Bool?
    /// 是否为当前正在运行的系统
    let isCurrent: Bool
    /// 就绪状态
    let readiness: Readiness

    var id: String { volumeGroupID }

    var storageDescription: String {
        switch isInternal {
        case true?: return "内置存储"
        case false?: return "外置存储"
        case nil: return "存储类型未知"
        }
    }

    var identity: BootTarget { BootTarget(volumeGroupID: volumeGroupID, systemVolumeUUID: systemVolumeUUID) }

    /// 候选系统的就绪状态
    enum Readiness: Equatable, Sendable {
        /// 可以作为切换目标
        case ready
        /// 不可用：当前正在运行的系统
        case currentSystem
        /// 不可用：系统卷未挂载
        case notMounted
        /// 不可用：系统卷已锁定（FileVault 加密且未解锁）
        case locked
        /// 不可用：无法确认就绪状态
        case unknown(reason: String)
    }

    /// 是否可以作为切换目标
    var canSwitch: Bool {
        readiness == .ready
    }

    /// 就绪状态的中文描述
    var readinessDescription: String {
        switch readiness {
        case .ready:
            return "就绪"
        case .currentSystem:
            return "当前系统"
        case .notMounted:
            return "未挂载（请在「磁盘工具」中挂载后刷新）"
        case .locked:
            return "已锁定（请在「磁盘工具」中解锁后刷新）"
        case .unknown(let reason):
            return "无法确认：\(reason)"
        }
    }
}
