import Foundation

/// 一份可用的签名身份：p12 证书 + 配套的描述文件。
///
/// 注意这里存的是**沙盒内相对路径**而不是绝对路径 ——
/// iOS App 的容器路径每次重装都会变，存绝对路径会导致下次启动找不到文件。
public struct SigningCertificate: Identifiable, Codable, Hashable, Sendable {

    public enum ExpiryLevel: String, Codable, Sendable {
        case healthy    // 剩余 > 30 天
        case warning    // 剩余 7–30 天
        case critical   // 剩余 < 7 天
        case expired
    }

    public struct ProvisionSummary: Codable, Hashable, Sendable {
        public var name: String
        public var teamID: String
        public var applicationIdentifier: String
        public var expirationDate: Date
        public var provisionedDeviceCount: Int

        public init(name: String,
                    teamID: String,
                    applicationIdentifier: String,
                    expirationDate: Date,
                    provisionedDeviceCount: Int) {
            self.name = name
            self.teamID = teamID
            self.applicationIdentifier = applicationIdentifier
            self.expirationDate = expirationDate
            self.provisionedDeviceCount = provisionedDeviceCount
        }

        public var isExpired: Bool { Date() >= expirationDate }
    }

    public let id: UUID
    public var displayName: String
    public var teamID: String
    /// 证书 subject 的 CN 部分，用于展示
    public var commonName: String
    public var notBefore: Date
    public var notAfter: Date
    public var p12RelativePath: String
    public var provisionRelativePath: String?
    public var provision: ProvisionSummary?

    public init(id: UUID = UUID(),
                displayName: String,
                teamID: String,
                commonName: String,
                notBefore: Date,
                notAfter: Date,
                p12RelativePath: String,
                provisionRelativePath: String? = nil,
                provision: ProvisionSummary? = nil) {
        self.id = id
        self.displayName = displayName
        self.teamID = teamID
        self.commonName = commonName
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.p12RelativePath = p12RelativePath
        self.provisionRelativePath = provisionRelativePath
        self.provision = provision
    }

    // MARK: - 有效期

    public var isExpired: Bool { Date() >= notAfter }

    public var daysRemaining: Int {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day ?? 0
        return max(0, days)
    }

    public var expiryLevel: ExpiryLevel {
        if isExpired { return .expired }
        switch daysRemaining {
        case ..<7:   return .critical
        case 7..<30: return .warning
        default:     return .healthy
        }
    }

    /// 证书与描述文件的 Team ID 是否一致。
    /// 不一致的后果是签出来的包装不上，所以这是签名前必做的校验。
    public var isPaired: Bool {
        guard let provision else { return false }
        return provision.teamID == teamID
    }

    /// 是否可以直接用来签名
    public var isUsable: Bool {
        !isExpired && provisionRelativePath != nil && isPaired
    }

    /// 人类可读的有效期描述
    public var expiryDescription: String {
        switch expiryLevel {
        case .expired:  return "已过期"
        case .critical: return "\(daysRemaining) 天后过期"
        case .warning:  return "\(daysRemaining) 天后过期"
        case .healthy:  return "\(daysRemaining) 天后过期"
        }
    }
}
