import Foundation

/// 签名编排。
///
/// 用 `actor` 隔离，因为签名是 CPU 密集操作（RSA + 逐文件 SHA256），
/// 几百 MB 的包可能耗时数十秒，必须离开主线程，否则会被系统判定为无响应而杀掉。
///
/// 流程刻意做成「先校验、后动手」：
/// 所有会导致「签完装不上」的问题都在真正签名之前拦掉，
/// 而不是等 zsign 跑完再报一个含糊的错误。
public actor SigningService {

    public enum Stage: String, Sendable {
        case validating = "校验输入"
        case extracting = "解包 IPA"
        case inspecting = "检查证书与描述文件"
        case signing    = "签名"
        case packaging  = "重新打包"
        case finished   = "完成"
    }

    public struct Progress: Sendable {
        public let stage: Stage
        /// 0.0 – 1.0
        public let fraction: Double
        public let detail: String

        public init(stage: Stage, fraction: Double, detail: String) {
            self.stage = stage
            self.fraction = fraction
            self.detail = detail
        }
    }

    private let fileManager = FileManager.default
    private let workRoot: URL

    public init(workRoot: URL? = nil) {
        if let workRoot {
            self.workRoot = workRoot
        } else {
            self.workRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("LCSignWork", isDirectory: true)
        }
    }

    // MARK: - 主流程

    public func sign(_ request: SigningRequest,
                     onProgress: @Sendable @escaping (Progress) -> Void) async throws -> URL {

        let sessionDir = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sessionDir) }

        // ---- 1. 校验输入文件都在 ----
        report(onProgress, .validating, 0.02, "检查输入文件")
        try require(request.inputIPA)
        try require(request.p12)
        if let url = request.provision { try require(url) }
        if let url = request.entitlements { try require(url) }
        if let url = request.iconFile { try require(url) }
        for url in request.dylibs { try require(url) }

        // ---- 2. 解包 ----
        report(onProgress, .extracting, 0.10, "解包 IPA")
        let extractDir = sessionDir.appendingPathComponent("extract", isDirectory: true)
        let contents = try IPAArchive.extract(ipa: request.inputIPA, to: extractDir)

        // ---- 3. 描述文件校验 ----
        report(onProgress, .inspecting, 0.25, "解析描述文件")
        var profile: ProvisioningProfile?
        if let url = request.provision {
            profile = try ProvisioningProfile.parse(contentsOf: url)
        }

        let targetBundleID = request.bundleID ?? contents.bundleID

        if let profile {
            if profile.isExpired {
                throw SigningError.profileExpired(profile.expirationDate)
            }
            if !profile.covers(bundleID: targetBundleID) {
                throw SigningError.bundleIDNotCovered(
                    bundleID: targetBundleID,
                    profileAppID: profile.applicationIdentifier
                )
            }
        }

        // ---- 4. entitlements 授权校验（闪退头号原因，提前拦） ----
        if let profile {
            report(onProgress, .inspecting, 0.32, "校验权限范围")
            let requested = try resolveEntitlements(
                request: request,
                appBundle: contents.appBundle,
                profile: profile
            )
            let unauthorized = profile.unauthorizedEntitlementKeys(in: requested)
            if !unauthorized.isEmpty {
                throw SigningError.entitlementsNotAuthorized(unauthorized)
            }
        }

        // ---- 5. 签名 ----
        report(onProgress, .signing, 0.45, "签名中，请勿切到后台")
        let password = request.p12Password

        try ZSignBridge.signApp(
            atPath: contents.appBundle.path,
            p12Path: request.p12.path,
            p12Password: password,
            provisionPath: request.provision?.path,
            entitlementsPath: request.entitlements?.path,
            bundleId: request.bundleID,
            bundleVersion: request.bundleVersion,
            displayName: request.displayName,
            iconFile: request.iconFile?.path,
            dylibPaths: request.dylibs.map(\.path)
        )

        // ---- 6. 打包 ----
        report(onProgress, .packaging, 0.85, "重新打包")
        try IPAArchive.package(appBundle: contents.appBundle, to: request.outputIPA)

        // ---- 7. 校验产物 ----
        try verifyOutput(request.outputIPA)

        report(onProgress, .finished, 1.0, "完成")
        return request.outputIPA
    }

    // MARK: - 辅助

    private func require(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SigningError.inputNotFound(url)
        }
    }

    private func report(_ sink: @Sendable (Progress) -> Void,
                        _ stage: Stage,
                        _ fraction: Double,
                        _ detail: String) {
        sink(Progress(stage: stage, fraction: fraction, detail: detail))
    }

    /// 决定这次签名用哪套 entitlements。优先级：
    /// 用户指定 > App 自带描述文件 > 目标描述文件
    private func resolveEntitlements(request: SigningRequest,
                                     appBundle: URL,
                                     profile: ProvisioningProfile) throws -> [String: Any] {
        if let url = request.entitlements {
            let data = try Data(contentsOf: url)
            if let dict = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any] {
                return dict
            }
        }

        let embedded = appBundle.appendingPathComponent("embedded.mobileprovision")
        if fileManager.fileExists(atPath: embedded.path),
           let existing = try? ProvisioningProfile.parse(contentsOf: embedded),
           !existing.entitlements.isEmpty {
            return existing.entitlements
        }

        return profile.entitlements
    }

    /// 签名后自检：这三个东西缺任何一个，包都装不上
    private func verifyOutput(_ ipa: URL) throws {
        let checkDir = workRoot.appendingPathComponent("verify-\(UUID().uuidString)",
                                                       isDirectory: true)
        defer { try? fileManager.removeItem(at: checkDir) }

        let contents: IPAArchive.Contents
        do {
            contents = try IPAArchive.extract(ipa: ipa, to: checkDir)
        } catch {
            throw SigningError.packagingFailed("产物无法解包：\(error.localizedDescription)")
        }

        let app = contents.appBundle

        guard fileManager.fileExists(atPath: app.appendingPathComponent("_CodeSignature").path) else {
            throw SigningError.packagingFailed("产物缺少 _CodeSignature/，签名未生效")
        }

        guard fileManager.fileExists(
            atPath: app.appendingPathComponent("embedded.mobileprovision").path
        ) else {
            throw SigningError.packagingFailed("产物缺少 embedded.mobileprovision，安装会被拒绝")
        }

        let executable = app.appendingPathComponent(contents.executableName)
        guard fileManager.fileExists(atPath: executable.path) else {
            throw SigningError.executableMissing(contents.executableName)
        }
    }
}
