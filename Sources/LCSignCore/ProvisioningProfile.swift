import Foundation

/// 描述文件（mobileprovision）的解析结果。
///
/// mobileprovision 本质是 CMS/PKCS#7 签名包裹的一段 XML plist。
/// 我们只需要读内容、不需要验证签名，所以直接截取 plist 段落解析即可 ——
/// 比走 Security.framework 的 CMSDecoder 更快，也少踩平台差异的坑。
///
/// `@unchecked Sendable`：所有字段都是 `let`，结构不可变，跨隔离域传递是安全的。
/// 但 `entitlements` 是 `[String: Any]`，编译器无法自动证明其 Sendable，
/// 只能手工担保（否则在 Swift 6 语言模式下会直接报错）。
public struct ProvisioningProfile: @unchecked Sendable {

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

    /// 去掉 Team 前缀后的 App ID 模式。
    ///
    /// `application-identifier` 形如 `ABCDE12345.com.example.app`，
    /// 真正描述覆盖范围的是第一个点之后的部分：`com.example.app`。
    public var appIDPattern: String {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else {
            return applicationIdentifier
        }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    /// 是否为通配符 App ID（`TEAMID.*` 或 `TEAMID.com.example.*`）
    public var isWildcard: Bool {
        let pattern = appIDPattern
        return pattern == "*" || pattern.hasSuffix(".*")
    }

    // MARK: - 覆盖性校验

    /// 描述文件的 App ID 能否覆盖指定的 Bundle ID。
    ///
    /// 三种情况：全局通配符、前缀通配符、完全匹配。
    public func covers(bundleID: String) -> Bool {
        let pattern = appIDPattern

        if pattern == "*" { return true }

        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            // `com.example.*` 既覆盖 com.example.app，也覆盖 com.example 本身
            return bundleID == prefix || bundleID.hasPrefix(prefix + ".")
        }

        return bundleID == pattern
    }

    /// 这几个键不参与授权比对 —— 它们天生绑定签名身份，签名时会被按描述文件
    /// 重新写入，拿源 App 里带过来的旧值去比只会误判：
    ///   - get-task-allow              开发描述文件里由系统管理
    ///   - application-identifier      形如 TEAMID.bundleid，随 Team 变
    ///   - team-identifier             同上
    ///   - keychain-access-groups      取值形如 TEAMID.*，同样随 Team 变
    private static let identityScopedEntitlementKeys: Set<String> = [
        "get-task-allow",
        "application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups"
    ]

    /// 找出目标 entitlements 里有哪些键**不在**本描述文件的授权范围内。
    ///
    /// 这是「签名成功但启动闪退」的头号原因，签名前必须先跑一遍。
    public func unauthorizedEntitlementKeys(in target: [String: Any]) -> [String] {
        target.keys.filter { key in
            if Self.identityScopedEntitlementKeys.contains(key) { return false }
            guard let allowed = entitlements[key] else { return true }
            return !Self.valueAllowed(allowed, target[key])
        }.sorted()
    }

    /// 宽松比较：数组按子集判断，字典递归，标量按相等。
    ///
    /// 字符串额外支持描述文件里的通配写法 —— `TEAMID.*`、`TEAMID.com.example.*`
    /// 都是合法的 App ID / keychain group 形式，用严格相等比会把它们全判成越权。
    private static func valueAllowed(_ allowed: Any, _ requested: Any?) -> Bool {
        guard let requested else { return false }

        if let a = allowed as? String, let b = requested as? String {
            return stringAllowed(a, b)
        }
        if let a = allowed as? Bool,   let b = requested as? Bool   { return a == b }
        if let a = allowed as? Int,    let b = requested as? Int    { return a == b }

        if let a = allowed as? [String], let b = requested as? [String] {
            return b.allSatisfy { item in a.contains { stringAllowed($0, item) } }
        }
        if let a = allowed as? [String: Any], let b = requested as? [String: Any] {
            // 显式判空：写成 a[pair.key] as Any 的话，缺键会变成
            // Optional<Any>.none 再被 as? 逐个类型试探，最终靠"全都匹配不上"
            // 兜到 false —— 结果虽然对，但没人看得出这是故意的。
            return b.allSatisfy { pair in
                guard let nested = a[pair.key] else { return false }
                return valueAllowed(nested, pair.value)
            }
        }
        return false
    }

    /// 带 `*` 的通配匹配，`*` 可以出现在任意位置、匹配任意长度子串。
    ///
    /// 只认尾部 `*` 是不够的 —— 描述文件里的真实写法至少有三类：
    ///   `TEAMID.*`、`iCloud.com.example.*`（尾部）
    ///   `applinks:*.example.com`（中间）
    private static func stringAllowed(_ allowed: String, _ requested: String) -> Bool {
        if allowed == requested { return true }

        // `X.*` 也覆盖裸的 `X`。
        //
        // 严格按 glob 语义，`*` 匹配零个或多个字符，所以 `com.example.*` 只该
        // 匹配 `com.example.` 开头的东西。但 Apple 对 App ID 的定义不是这样：
        // `TEAMID.com.example.*` 是覆盖 `com.example` 本身的。entitlements 里的
        // 通配写法沿用同一套规则，不然就会把合法请求判成越权。
        if allowed.hasSuffix(".*"), requested == String(allowed.dropLast(2)) {
            return true
        }

        guard allowed.contains("*") else { return false }

        let parts = allowed
            .split(separator: "*", omittingEmptySubsequences: false)
            .map(String.init)

        var remainder = Substring(requested)

        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }

            if index == 0 {
                // 首段必须落在开头
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if index == parts.count - 1 {
                // 末段必须落在结尾
                guard remainder.hasSuffix(part) else { return false }
                remainder = remainder.dropLast(part.count)
            } else {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
        }

        return true
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
