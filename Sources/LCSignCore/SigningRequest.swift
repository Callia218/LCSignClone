import Foundation

/// 一次签名任务的全部参数。
///
/// 所有 `URL` 都指向本地文件。沙盒外（比如「文件」App 投递进来）的路径
/// 需要先复制到 App 容器内再传进来，否则签名过程中权限会被回收。
public struct SigningRequest: Sendable {

    // 输入输出
    public var inputIPA: URL
    public var outputIPA: URL

    // 签名身份
    public var p12: URL
    public var p12Password: String
    public var provision: URL?

    // 改写项（nil 表示保持原值）
    public var entitlements: URL?
    public var bundleID: String?
    public var bundleVersion: String?
    public var displayName: String?
    public var iconFile: URL?

    // 注入
    public var dylibs: [URL]

    public init(inputIPA: URL,
                outputIPA: URL,
                p12: URL,
                p12Password: String,
                provision: URL? = nil,
                entitlements: URL? = nil,
                bundleID: String? = nil,
                bundleVersion: String? = nil,
                displayName: String? = nil,
                iconFile: URL? = nil,
                dylibs: [URL] = []) {
        self.inputIPA = inputIPA
        self.outputIPA = outputIPA
        self.p12 = p12
        self.p12Password = p12Password
        self.provision = provision
        self.entitlements = entitlements
        self.bundleID = bundleID
        self.bundleVersion = bundleVersion
        self.displayName = displayName
        self.iconFile = iconFile
        self.dylibs = dylibs
    }

    /// 输出文件名：原文件名 + 时间戳，避免覆盖
    public static func defaultOutputURL(for input: URL, in directory: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        return directory
            .appendingPathComponent("\(base)-signed-\(f.string(from: Date()))")
            .appendingPathExtension("ipa")
    }
}
