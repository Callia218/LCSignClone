import Foundation

/// 引擎自检：在**不需要任何证书**的前提下，验证「构造 .app → 打包 → 解包 →
/// 签名 → 校验产物」这条链路在当前设备上是否真的能跑通。
///
/// 为什么需要它：签名失败的原因高度集中在两类 ——
///
///   1. 引擎本身跑不起来：zsign 静态库没链上、架构不对、沙盒写不了临时目录…
///   2. 证书 / 描述文件有问题：密码错、Team 不匹配、App ID 覆盖不了、权限越界…
///
/// 没有自检的时候，这两类会混成同一句「签名失败」，排查方向全靠猜。
/// 而 ad-hoc 签名不校验任何身份（zsign 在 `bAdhoc` 为真时只写一个固定的空
/// CMS 槽），正好可以把第 1 类单独摘出来验证：自检过了，后续真签名再失败，
/// 就一定是证书侧的问题。
///
/// 自检用的可执行文件是**本框架自己的 Mach-O**。它是一段真实、结构完整的
/// 机器码，能让 zsign 走完「读 Mach-O 头 → 定位 LC_CODE_SIGNATURE →
/// 重算 CodeDirectory → 重写签名数据」的全部逻辑。换成随手造的假文件是不行的：
/// zsign 会按 magic 判断是不是 Mach-O，假文件根本进不了签名列表，自检等于没做。
public enum EngineSelfTest {

    // MARK: - 结果模型

    public enum Outcome: Equatable, Sendable {
        case passed
        case failed(String)
        case skipped(String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        /// SF Symbol 名，供界面直接使用
        public var symbolName: String {
            switch self {
            case .passed:  return "checkmark.circle.fill"
            case .failed:  return "xmark.octagon.fill"
            case .skipped: return "minus.circle"
            }
        }

        public var text: String {
            switch self {
            case .passed:            return "通过"
            case .failed(let why):   return why
            case .skipped(let why):  return why
            }
        }
    }

    public struct Step: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let detail: String
        public let outcome: Outcome
    }

    public struct Report: Sendable {
        public let steps: [Step]
        public let startedAt: Date
        public let finishedAt: Date

        public var isHealthy: Bool { !steps.contains { $0.outcome.isFailure } }
        public var failureCount: Int { steps.filter { $0.outcome.isFailure }.count }
        public var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    }

    // MARK: - 入口

    /// 同步执行全部自检步骤。
    ///
    /// 调用方负责放到后台线程：里面要解压、要签名，放主线程会卡住界面。
    public static func run() -> Report {
        let startedAt = Date()
        var steps: [Step] = []

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("LCSignSelfTest-\(UUID().uuidString)", isDirectory: true)

        defer { try? fm.removeItem(at: root) }

        func finish() -> Report {
            Report(steps: steps, startedAt: startedAt, finishedAt: Date())
        }

        // ---- 0. 临时目录可写 ----
        // 沙盒里写不了临时目录的话，后面每一步都会以奇怪的方式失败，先单独确认。
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            steps.append(Step(title: "准备临时目录", detail: root.path, outcome: .passed))
        } catch {
            steps.append(Step(title: "准备临时目录",
                              detail: error.localizedDescription,
                              outcome: .failed("临时目录不可写：\(error.localizedDescription)")))
            return finish()
        }

        // ---- 1. 定位一段真实的 Mach-O ----
        guard let engineBinary = locateEngineBinary() else {
            steps.append(Step(title: "定位引擎二进制",
                              detail: "LCSignCore.framework 内找不到可执行文件",
                              outcome: .failed("读不到框架自己的 Mach-O，无法进行签名自检。")))
            return finish()
        }
        steps.append(Step(title: "定位引擎二进制",
                          detail: "\(engineBinary.lastPathComponent)（\(fileSize(engineBinary)) 字节）",
                          outcome: .passed))

        // ---- 2. 构造合成 .app ----
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("SelfTest.app", isDirectory: true)

        do {
            try fm.createDirectory(at: app, withIntermediateDirectories: true)

            // 用框架自己的 Mach-O 当可执行文件（理由见类型注释）
            try fm.copyItem(at: engineBinary, to: app.appendingPathComponent("SelfTest"))

            let info: [String: Any] = [
                "CFBundleIdentifier": "com.example.lcsigncore.selftest",
                "CFBundleExecutable": "SelfTest",
                "CFBundleName": "SelfTest",
                "CFBundleDisplayName": "LCSign 自检",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0",
                "CFBundlePackageType": "APPL",
                "MinimumOSVersion": "15.0",
                "CFBundleSupportedPlatforms": ["iPhoneOS"]
            ]
            let infoData = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try infoData.write(to: app.appendingPathComponent("Info.plist"))

            try Data("LCSign self-test resource\n".utf8)
                .write(to: app.appendingPathComponent("Resource.txt"))

            // 空目录：确认打包 / 解包往返不会把它吃掉（真实 .app 里这种目录不少）
            try fm.createDirectory(at: app.appendingPathComponent("EmptyDir", isDirectory: true),
                                   withIntermediateDirectories: true)

            steps.append(Step(title: "构造合成 .app",
                              detail: "Info.plist + 真实 Mach-O + 1 个资源文件 + 1 个空目录",
                              outcome: .passed))
        } catch {
            steps.append(Step(title: "构造合成 .app",
                              detail: error.localizedDescription,
                              outcome: .failed("构造测试用 .app 失败：\(error.localizedDescription)")))
            return finish()
        }

        // ---- 3. 打包成 IPA ----
        let ipa = root.appendingPathComponent("SelfTest.ipa")
        do {
            try IPAArchive.package(appBundle: app, to: ipa)

            let size = fileSize(ipa)
            guard size > 0 else {
                steps.append(Step(title: "打包 IPA",
                                  detail: ipa.path,
                                  outcome: .failed("产出的 IPA 是空文件。")))
                return finish()
            }
            steps.append(Step(title: "打包 IPA", detail: "\(size) 字节", outcome: .passed))
        } catch {
            steps.append(Step(title: "打包 IPA",
                              detail: error.localizedDescription,
                              outcome: .failed("打包失败：\(error.localizedDescription)")))
            return finish()
        }

        // ---- 4. 解包回来 ----
        let extractDir = root.appendingPathComponent("extracted", isDirectory: true)
        let contents: IPAArchive.Contents
        do {
            contents = try IPAArchive.extract(ipa: ipa, to: extractDir)

            let emptyDir = contents.appBundle.appendingPathComponent("EmptyDir")
            guard fm.fileExists(atPath: emptyDir.path) else {
                steps.append(Step(title: "解包 IPA",
                                  detail: "空目录在往返中丢失",
                                  outcome: .failed("解包后空目录消失，打包逻辑有问题。")))
                return finish()
            }

            steps.append(Step(title: "解包 IPA",
                              detail: "\(contents.bundleID) · 可执行文件 \(contents.executableName)",
                              outcome: .passed))
        } catch {
            steps.append(Step(title: "解包 IPA",
                              detail: error.localizedDescription,
                              outcome: .failed("解包失败：\(error.localizedDescription)")))
            return finish()
        }

        // ---- 5. 调用签名引擎（ad-hoc，不需要证书）----
        do {
            try ZSignBridge.adHocSignApp(atPath: contents.appBundle.path)
            steps.append(Step(title: "调用签名引擎（ad-hoc）",
                              detail: "不校验身份，只验证引擎本身可用",
                              outcome: .passed))
        } catch {
            let reason = (error as NSError).localizedDescription
            steps.append(Step(title: "调用签名引擎（ad-hoc）",
                              detail: reason,
                              outcome: .failed("签名引擎不可用：\(reason)")))
            return finish()
        }

        // ---- 6. 校验签名产物 ----
        let codeResources = contents.appBundle
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources")

        guard fm.fileExists(atPath: codeResources.path) else {
            steps.append(Step(title: "校验签名产物",
                              detail: codeResources.path,
                              outcome: .failed("引擎返回成功，但没有写出 _CodeSignature/CodeResources。")))
            return finish()
        }

        do {
            let data = try Data(contentsOf: codeResources)

            guard let plist = try PropertyListSerialization
                .propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                steps.append(Step(title: "校验签名产物",
                                  detail: "\(data.count) 字节",
                                  outcome: .failed("CodeResources 不是合法的 plist 字典。")))
                return finish()
            }

            // 「资源有没有被收录」是引擎真的扫过这个目录的直接证据。
            // 但不同版本的 CodeResources 布局有差异，所以这条只写进 detail，
            // 不当失败处理 —— 卡在这里反而会误报。
            let recorded = recordedResources(in: plist)
            let hasResource = recorded.contains("Resource.txt")

            steps.append(Step(
                title: "校验签名产物",
                detail: "CodeResources \(data.count) 字节，收录 \(recorded.count) 项"
                      + (hasResource ? "（含 Resource.txt）" : ""),
                outcome: .passed
            ))
        } catch {
            steps.append(Step(title: "校验签名产物",
                              detail: error.localizedDescription,
                              outcome: .failed("读取 CodeResources 失败：\(error.localizedDescription)")))
        }

        return finish()
    }

    // MARK: - 私有

    /// 从 CodeResources 里取出被收录的文件名。
    /// zsign 会同时写 `files`（SHA1 时代）与 `files2`（SHA256 时代）两个字典。
    private static func recordedResources(in plist: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        for key in ["files", "files2"] {
            if let section = plist[key] as? [String: Any] {
                names.formUnion(section.keys)
            }
        }
        return names
    }

    /// 定位 LCSignCore.framework 里的可执行文件。
    ///
    /// 本类型就在这个 framework 里，所以能跑到这里就说明 framework 已经加载，
    /// 它的可执行文件必然存在 —— 这里只是把路径取出来而已。
    private static func locateEngineBinary() -> URL? {
        let fm = FileManager.default
        let bundle = Bundle(for: BundleToken.self)

        if let executable = bundle.executableURL,
           fm.fileExists(atPath: executable.path) {
            return executable
        }

        if let name = bundle.infoDictionary?["CFBundleExecutable"] as? String {
            let candidate = bundle.bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }

        return nil
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? Int } ?? 0
    }

    /// 仅用于拿到「本类型所属的 bundle」。
    private final class BundleToken {}
}
