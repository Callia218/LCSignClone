import Foundation

/// 描述文件（mobileprovision）的解析结果。
///
/// mobileprovision 本质是 CMS/PKCS#7 签名包裹的一段 XML plist。
/// 我们只需要读内容、不需要验证签名，所以直接截取 plist 段落解析即可 ——
/// 比走 Security.framework 的 CMSDecoder 更快，也少踩平台差异的坑。
public struct ProvisioningProfile: Sendable {

    public let name: String
    public let uuid: String
    public let teamID: String
    /// 形如 `ABCDE12345.com.example.app` 或 `ABCDE12345.*`
    public let applicationIdentifier: String
    public let entitlements: [String: Any]
    /// 白名单设备 UDID。App Store 类型的描述文件此数组为空。
    public let provisionedDevices: [String]
    public let creationDate: Date?
    public let expirationDate: Date
    public let platforms: [String]

    // MARK: - 派生属性

    public var isExpired: Bool { Date() >= expirationDate }

    public var daysRemaining: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0)
    }

    public var deviceCount: Int { provisionedDevices.count }

    /// 是否为通配符 App ID
    public var isWildcard: Bool {
        applicationIdentifier.hasSuffix(".*") || applicationIdentifier.hasSuffix(".*")
    }

    // MARK: - 覆盖性校验

    /// 描述文件的 App ID 能否覆盖指定的 Bundle ID。
    ///
    /// 三种情况：完全匹配、通配符前缀匹配、全局通配符。
    public func covers(bundleID: String) -> Bool {
        let pattern: String
        if let dot = applicationIdentifier.firstIndex(of: ".") {
            pattern = String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
        } else {
            pattern = applicationIdentifier
        }

        if pattern == "*" { return true }

        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }

        return bundleID == pattern
    }

    /// 找出目标 entitlements 里有哪些键**不在**本描述文件的授权范围内。
    ///
    /// 这是「签名成功但启动闪退」的头号原因，签名前必须先跑一遍。
    public func unauthorizedEntitlementKeys(in target: [String: Any]) -> [String] {
        target.keys.filter { key in
            // get-task-allow 在开发描述文件里由系统管理，不参与比对
            if key == "get-task-allow" { return false }
            guard let allowed = entitlements[key] else { return true }
            return !Self.valueAllowed(allowed, target[key])
        }.sorted()
    }

    /// 宽松比较：数组按子集判断，字典递归，标量按相等
    private static func valueAllowed(_ allowed: Any, _ requested: Any?) -> Bool {
        guard let requested else { return false }

        if let a = allowed as? String, let b = requested as? String { return a == b }
        if let a = allowed as? Bool,   let b = requested as? Bool   { return a == b }
        if let a = allowed as? Int,    let b = requested as? Int    { return a == b }

        if let a = allowed as? [String], let b = requested as? [String] {
            return Set(b).isSubset(of: Set(a))
        }
        if let a = allowed as? [String: Any], let b = requested as? [String: Any] {
            return b.allSatisfy { valueAllowed(a[$0.key] as Any, $0.value) }
        }
        return false
    }

    // MARK: - 解析

    public static func parse(contentsOf url: URL) throws -> ProvisioningProfile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SigningError.profileUnreadable(error.localizedDescription)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> ProvisioningProfile {
        guard let plistData = extractPlist(from: data) else {
            throw SigningError.profileUnreadable(
                "未找到内嵌的 plist 段，这个文件可能不是 .mobileprovision"
            )
        }

        let raw: Any
        do {
            raw = try PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil
            )
        } catch {
            throw SigningError.profileUnreadable("plist 解析失败：\(error.localizedDescription)")
        }

        guard let dict = raw as? [String: Any] else {
            throw SigningError.profileUnreadable("plist 根节点不是字典")
        }

        guard let expiration = dict["ExpirationDate"] as? Date else {
            throw SigningError.profileUnreadable("缺少 ExpirationDate 字段")
        }

        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]

        return ProvisioningProfile(
            name: dict["Name"] as? String ?? "未命名描述文件",
            uuid: dict["UUID"] as? String ?? "",
            teamID: (dict["TeamIdentifier"] as? [String])?.first ?? "",
            applicationIdentifier: entitlements["application-identifier"] as? String ?? "",
            entitlements: entitlements,
            provisionedDevices: dict["ProvisionedDevices"] as? [String] ?? [],
            creationDate: dict["CreationDate"] as? Date,
            expirationDate: expiration,
            platforms: dict["Platform"] as? [String] ?? []
        )
    }

    /// 从 CMS 包裹里截出 XML plist 段
    private static func extractPlist(from data: Data) -> Data? {
        let startTag = Data("<?xml".utf8)
        let endTag = Data("</plist>".utf8)

        guard let start = data.range(of: startTag) else { return nil }
        guard let end = data.range(of: endTag, in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }
}
