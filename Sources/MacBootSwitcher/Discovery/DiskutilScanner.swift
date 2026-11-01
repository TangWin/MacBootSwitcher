import Foundation

struct BootTarget: Codable, Equatable, Sendable {
    let volumeGroupID: String
    let systemVolumeUUID: String
    var isValid: Bool { UUID(uuidString: volumeGroupID) != nil && UUID(uuidString: systemVolumeUUID) != nil }
}

struct ScanResult: Sendable {
    let candidates: [SystemCandidate]
    let currentSystemID: String?
    let warnings: [String]
}

enum ScanError: Error, LocalizedError {
    case diskutilFailed(exitCode: Int32, message: String)
    case plistParsingFailed(String)
    case noContainersFound
    var errorDescription: String? {
        switch self {
        case .diskutilFailed(let code, _): return "无法读取磁盘信息（工具状态 \(code)）"
        case .plistParsingFailed(let detail): return detail
        case .noContainersFound: return "未发现 APFS 容器"
        }
    }
}

enum ScanProgress: Sendable { case readingGroups, identifyingCurrentSystem, checkingCandidates(completed: Int, total: Int) }

protocol SystemScanning: Sendable {
    func scan(onProgress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanResult
    func validateTarget(_ target: BootTarget) async throws -> String
}

extension SystemScanning {
    func scan() async throws -> ScanResult { try await scan(onProgress: { _ in }) }
}

/// 卷组枚举直接取得成员关系；每轮只读信息不跨认证等待缓存。
final class DiskutilScanner: SystemScanning {
    private let executor: CommandExecuting
    init(executor: CommandExecuting = ProcessExecutor()) { self.executor = executor }

    private struct Member {
        let device: String
        let uuid: String
        let role: String
    }
    private struct Group {
        let id: String
        let members: [Member]
        var systems: [Member] { members.filter { $0.role == "System" } }
        var data: [Member] { members.filter { $0.role == "Data" } }
    }

    func scan(onProgress: @escaping @Sendable (ScanProgress) async -> Void) async throws -> ScanResult {
        await onProgress(.readingGroups)
        let groups = try await listGroups()
        await onProgress(.identifyingCurrentSystem)
        let root = try await info("/")
        let current = try currentID(root)
        guard groups.filter({ $0.id.caseInsensitiveCompare(current) == .orderedSame }).count == 1 else { throw ScanError.plistParsingFailed("当前系统无法对应唯一卷组，已禁用切换。") }
        var candidates: [SystemCandidate] = []
        var warnings: [String] = []
        for (offset, group) in groups.enumerated() {
            await onProgress(.checkingCandidates(completed: offset, total: groups.count))
            do {
                let diskInfo: [String: Any]?
                if let member = group.systems.first { diskInfo = try await info(member.device) } else { diskInfo = nil }
                let dataInfo: [String: Any]?
                if let member = group.data.first { dataInfo = try await info(member.device) } else { dataInfo = nil }
                candidates.append(candidate(group, info: diskInfo ?? [:], dataInfo: dataInfo, currentID: current))
            } catch {
                warnings.append("有系统卷信息读取失败，请刷新后重试。")
                candidates.append(candidate(group, info: [:], dataInfo: nil, currentID: current))
            }
        }
        await onProgress(.checkingCandidates(completed: groups.count, total: groups.count))
        return ScanResult(candidates: candidates.sorted { $0.name < $1.name }, currentSystemID: current, warnings: warnings)
    }

    /// 只核对所选目标；授权后再次调用，不信任先前路径。
    func validateTarget(_ target: BootTarget) async throws -> String {
        guard target.isValid else { throw ScanError.plistParsingFailed("目标身份不完整，请重新扫描。") }
        let groups = try await listGroups()
        let matches = groups.filter { $0.id.caseInsensitiveCompare(target.volumeGroupID) == .orderedSame }
        guard matches.count == 1, let group = matches.first, group.systems.count == 1, group.data.count == 1,
              group.systems[0].uuid.caseInsensitiveCompare(target.systemVolumeUUID) == .orderedSame else {
            throw ScanError.plistParsingFailed("目标身份已变化或无法唯一确认，请重新扫描。")
        }
        let root = try await info("/")
        let current = try currentID(root)
        guard groups.filter({ $0.id.caseInsensitiveCompare(current) == .orderedSame }).count == 1 else {
            throw ScanError.plistParsingFailed("当前系统无法对应唯一卷组，已禁用切换。")
        }
        guard current.caseInsensitiveCompare(group.id) != .orderedSame else { throw ScanError.plistParsingFailed("不能切换到当前正在运行的系统。") }
        let system = group.systems[0]
        let systemInfo = try await info(system.device)
        guard candidate(group, info: systemInfo, dataInfo: ["Locked": false, "VolumeUUID": group.data[0].uuid, "APFSVolumeGroupID": group.id], currentID: current).canSwitch,
              matchesIdentity(systemInfo, target), let mount = systemInfo["MountPoint"] as? String, mount.hasPrefix("/") else {
            throw ScanError.plistParsingFailed("目标已断开、锁定、未挂载或信息不足，请重新扫描。")
        }
        let dataInfo = try await info(group.data[0].device)
        guard matchesIdentity(dataInfo, BootTarget(volumeGroupID: group.id, systemVolumeUUID: group.data[0].uuid)), dataInfo["Locked"] as? Bool == false else {
            throw ScanError.plistParsingFailed("目标数据卷状态无法确认，请解锁后重新扫描。")
        }
        let mountedInfo = try await info(mount)
        guard matchesIdentity(mountedInfo, target), mountedInfo["MountPoint"] as? String == mount,
              mountedInfo["Locked"] as? Bool == false else { throw ScanError.plistParsingFailed("目标挂载对象已变化，请重新扫描。") }
        return mount
    }

    private func listGroups() async throws -> [Group] {
        let plist = try await command(["apfs", "listVolumeGroups", "-plist"])
        guard let containers = plist["Containers"] as? [[String: Any]] else { throw ScanError.plistParsingFailed("无法解析系统卷组信息。") }
        var groups: [Group] = []
        for container in containers {
            guard let rawGroups = container["VolumeGroups"] as? [[String: Any]] else { throw ScanError.plistParsingFailed("卷组信息缺少必要字段。") }
            for raw in rawGroups {
                guard let id = raw["APFSVolumeGroupUUID"] as? String, UUID(uuidString: id) != nil,
                      let volumes = raw["Volumes"] as? [[String: Any]] else { throw ScanError.plistParsingFailed("卷组身份无法确认。") }
                let members = volumes.compactMap { v -> Member? in
                    guard let device = v["DeviceIdentifier"] as? String, !device.isEmpty,
                          let uuid = v["DiskUUID"] as? String, UUID(uuidString: uuid) != nil,
                          let role = v["Role"] as? String else { return nil }
                    return Member(device: device, uuid: uuid, role: role)
                }
                groups.append(Group(id: id, members: members))
            }
        }
        guard Set(groups.map { $0.id.lowercased() }).count == groups.count else { throw ScanError.plistParsingFailed("发现重复卷组身份，不能安全选择目标。") }
        return groups
    }

    private func currentID(_ root: [String: Any]) throws -> String {
        guard let id = root["APFSVolumeGroupID"] as? String, UUID(uuidString: id) != nil else { throw ScanError.plistParsingFailed("无法确认当前系统身份，已禁用切换。") }
        return id
    }

    private func matchesIdentity(_ info: [String: Any], _ target: BootTarget) -> Bool {
        guard let group = info["APFSVolumeGroupID"] as? String, let uuid = info["VolumeUUID"] as? String else { return false }
        return group.caseInsensitiveCompare(target.volumeGroupID) == .orderedSame && uuid.caseInsensitiveCompare(target.systemVolumeUUID) == .orderedSame
    }

    private func candidate(_ group: Group, info: [String: Any], dataInfo: [String: Any]?, currentID: String) -> SystemCandidate {
        let current = group.id.caseInsensitiveCompare(currentID) == .orderedSame
        let system = group.systems.first
        let mount = info["MountPoint"] as? String
        let locked = info["Locked"] as? Bool
        let readiness: SystemCandidate.Readiness
        if current { readiness = .currentSystem }
        else if group.systems.count != 1 || group.data.count != 1 { readiness = .unknown(reason: "系统与数据卷关联不完整") }
        else if let member = group.data.first, let dataInfo, !matchesIdentity(dataInfo, BootTarget(volumeGroupID: group.id, systemVolumeUUID: member.uuid)) { readiness = .unknown(reason: "数据卷身份信息不一致") }
        else if locked == true || dataInfo?["Locked"] as? Bool == true { readiness = .locked }
        else if locked == nil || dataInfo?["Locked"] as? Bool == nil { readiness = .unknown(reason: "无法确认锁定状态") }
        else if mount == nil || mount?.isEmpty == true { readiness = .notMounted }
        else if let system, matchesIdentity(info, BootTarget(volumeGroupID: group.id, systemVolumeUUID: system.uuid)) { readiness = .ready }
        else { readiness = .unknown(reason: "系统卷身份信息不一致") }
        return SystemCandidate(volumeGroupID: group.id, systemVolumeUUID: system?.uuid ?? "", name: info["VolumeName"] as? String ?? "未知系统",
            version: mount.flatMap { readVersion($0) }, isInternal: info["Internal"] as? Bool, isCurrent: current, readiness: readiness)
    }

    private func info(_ device: String) async throws -> [String: Any] { try await command(["info", "-plist", device]) }
    private func command(_ arguments: [String]) async throws -> [String: Any] {
        let result = try await executor.run(path: "/usr/sbin/diskutil", arguments: arguments)
        guard result.termination == .exit, result.exitCode == 0 else { throw ScanError.diskutilFailed(exitCode: result.exitCode, message: "") }
        guard let data = result.stdout.data(using: .utf8), let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw ScanError.plistParsingFailed("无法解析磁盘结构信息。") }
        return dict
    }
    private func readVersion(_ mount: String) -> String? {
        guard let data = FileManager.default.contents(atPath: (mount as NSString).appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = dict["ProductName"] as? String, let version = dict["ProductVersion"] as? String else { return nil }
        return "\(name) \(version)"
    }
}
