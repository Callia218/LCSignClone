import Foundation
import Security

/// 证书库：把 p12 / mobileprovision 收进沙盒，元数据落 JSON，密码进钥匙串。
///
/// 密码**绝不**写进 JSON —— 那是明文文件。用钥匙串的
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，既不参与 iCloud 同步，
/// 也保证 App 在后台被唤醒时能读到。
public actor CertificateStore {

    public static let shared = CertificateStore()

    private static let keychainService = "com.example.lcsigncore.certificate"
    private static let indexFileName = "certificates.json"

    private let root: URL
    private var cache: [SigningCertificate] = []
    private var loaded = false

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Certificates", isDirectory: true)
        }
    }

    private var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }

    // MARK: - 读写索引

    public func all() throws -> [SigningCertificate] {
        if !loaded { try reload() }
        return cache.sorted { $0.notAfter > $1.notAfter }
    }

    private func reload() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else {
            cache = []
            loaded = true
            return
        }
        let data = try Data(contentsOf: indexURL)
        cache = (try? JSONDecoder().decode([SigningCertificate].self, from: data)) ?? []
        loaded = true
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        // 用 .completeFileProtection 兜底，避免设备未解锁时可读
        try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: - 增删

    /// 导入一份签名身份。会校验 p12 能否用给定密码打开。
    @discardableResult
    public func add(p12 sourceP12: URL,
                    password: String,
                    provision sourceProvision: URL? = nil,
                    displayName: String? = nil) throws -> SigningCertificate {

        if !loaded { try reload() }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 1. 用密码打开 p12，顺便把证书信息读出来
        let identity = try Self.loadIdentity(from: sourceP12, password: password)

        // 2. 解析描述文件
        var provision: ProvisioningProfile?
        if let sourceProvision {
            provision = try ProvisioningProfile.parse(contentsOf: sourceProvision)
        }

        // 3. 配对校验 —— 不配对就直接拒绝，别让用户签出一堆装不上的包
        if let provision, provision.teamID != identity.teamID {
            throw SigningError.teamIDMismatch(certificate: identity.teamID,
                                              profile: provision.teamID)
        }
        if let provision, provision.isExpired {
            throw SigningError.profileExpired(provision.expirationDate)
        }

        // 4. 落盘
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let p12Name = "identity.p12"
        let p12Dest = folder.appendingPathComponent(p12Name)
        try? fm.removeItem(at: p12Dest)
        try fm.copyItem(at: sourceP12, to: p12Dest)

        var provisionRelative: String?
        if let sourceProvision {
            let provName = "profile.mobileprovision"
            let provDest = folder.appendingPathComponent(provName)
            try? fm.removeItem(at: provDest)
            try fm.copyItem(at: sourceProvision, to: provDest)
            provisionRelative = "\(id.uuidString)/\(provName)"
        }

        let cert = SigningCertificate(
            id: id,
            displayName: displayName ?? identity.commonName,
            teamID: identity.teamID,
            commonName: identity.commonName,
            notBefore: identity.notBefore,
            notAfter: identity.notAfter,
            p12RelativePath: "\(id.uuidString)/\(p12Name)",
            provisionRelativePath: provisionRelative,
            provision: provision.map {
                SigningCertificate.ProvisionSummary(
                    name: $0.name,
                    teamID: $0.teamID,
                    applicationIdentifier: $0.applicationIdentifier,
                    expirationDate: $0.expirationDate,
                    provisionedDeviceCount: $0.deviceCount
                )
            }
        )

        try savePassword(password, for: id)

        cache.removeAll { $0.id == id }
        cache.append(cert)
        try persist()

        return cert
    }

    public func remove(_ id: UUID) throws {
        if !loaded { try reload() }

        let fm = FileManager.default
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try? fm.removeItem(at: folder)
        deletePassword(for: id)

        cache.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - 路径与密码

    public func p12URL(for cert: SigningCertificate) -> URL {
        root.appendingPathComponent(cert.p12RelativePath)
    }

    public func provisionURL(for cert: SigningCertificate) -> URL? {
        guard let relative = cert.provisionRelativePath else { return nil }
        let url = root.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func password(for cert: SigningCertificate) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "p12-\(cert.id.uuidString)",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw SigningError.p12Unreadable("钥匙串里找不到该证书的密码（OSStatus \(status)）")
        }
        return password
    }

    private func savePassword(_ password: String, for id: UUID) throws {
        let account = "p12-\(id.uuidString)"
        deletePassword(for: id)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String:   Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SigningError.p12Unreadable("密码写入钥匙串失败（OSStatus \(status)）")
        }
    }

    private func deletePassword(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "p12-\(id.uuidString)"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - p12 解析

    private struct IdentityInfo {
        var commonName: String
        var teamID: String
        var notBefore: Date
        var notAfter: Date
    }

    private static func loadIdentity(from url: URL, password: String) throws -> IdentityInfo {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SigningError.p12Unreadable("无法读取文件：\(error.localizedDescription)")
        }

        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &rawItems)

        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw SigningError.p12Unreadable("密码错误")
        default:
            throw SigningError.p12Unreadable("导入失败（OSStatus \(status)）")
        }

        guard let items = rawItems as? [[String: Any]], let first = items.first else {
            throw SigningError.p12Unreadable("文件里没有任何身份")
        }

        guard let identityRef = first[kSecImportItemIdentity as String] else {
            throw SigningError.p12Unreadable("文件里没有可用的签名身份")
        }

        // 走一个桥接把 CFTypeRef 转成 SecIdentity
        let identity = identityRef as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let cert = certificate else {
            throw SigningError.p12Unreadable("无法从身份中取出证书")
        }

        var cfCommonName: CFString?
        let nameStatus = SecCertificateCopyCommonName(cert, &cfCommonName)
        let commonName = (nameStatus == errSecSuccess ? cfCommonName as String? : nil)
            ?? "未命名证书"

        let fields = subjectFields(of: cert)
        let teamID = fields["Organizational Unit"] ?? ""
        let validity = validityDates(of: cert)

        return IdentityInfo(
            commonName: commonName,
            teamID: teamID,
            notBefore: validity?.notBefore ?? Date.distantPast,
            notAfter: validity?.notAfter ?? Date.distantPast
        )
    }

    private static func subjectFields(of cert: SecCertificate) -> [String: String] {
        let keys = [kSecOIDX509V1SubjectName] as CFArray
        guard let dict = SecCertificateCopyValues(cert, keys, nil) as? [String: Any],
              let entry = dict[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let values = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return [:]
        }

        var result: [String: String] = [:]
        for item in values {
            guard let label = item[kSecPropertyKeyLabel as String] as? String else { continue }
            if let value = item[kSecPropertyKeyValue as String] as? String {
                result[label] = value
            } else if let value = item[kSecPropertyKeyValue as String] as? [String: Any],
                      let inner = value["value"] as? String {
                result[label] = inner
            }
        }
        return result
    }

    private static func validityDates(of cert: SecCertificate) -> (notBefore: Date, notAfter: Date)? {
        let keys = [
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter
        ] as CFArray

        guard let dict = SecCertificateCopyValues(cert, keys, nil) as? [String: Any] else {
            return nil
        }

        func extract(_ oid: CFString) -> Date? {
            guard let entry = dict[oid as String] as? [String: Any],
                  let raw = entry[kSecPropertyKeyValue as String] else { return nil }

            if let date = raw as? Date { return date }

            // 有些系统返回的是格式化字符串
            if let text = raw as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                if let date = formatter.date(from: text) { return date }
                formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
                return formatter.date(from: text)
            }
            return nil
        }

        guard let before = extract(kSecOIDX509V1ValidityNotBefore),
              let after  = extract(kSecOIDX509V1ValidityNotAfter) else { return nil }

        return (before, after)
    }
}
