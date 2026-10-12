import Foundation
import LCSignCore

/// 造一个结构上跟真实 mobileprovision 一致的测试用描述文件。
///
/// 真实文件是 CMS/PKCS#7 包裹的 XML plist，而 `ProvisioningProfile.parse`
/// 只负责截出其中的 `<?xml … </plist>` 段落、不验证签名。所以前后各塞一点
/// 垃圾字节就够了 —— 顺带也把「截取逻辑不会被前后噪声带偏」这件事测掉。
func makeProvisioningProfile(
    applicationIdentifier: String,
    entitlements: [String: Any] = [:],
    expirationDate: Date = Date().addingTimeInterval(86_400 * 90),
    teamID: String = "ABCDE12345",
    name: String = "测试描述文件"
) throws -> ProvisioningProfile {

    var allEntitlements = entitlements
    allEntitlements["application-identifier"] = applicationIdentifier

    let plist: [String: Any] = [
        "Name": name,
        "UUID": UUID().uuidString,
        "TeamIdentifier": [teamID],
        "Entitlements": allEntitlements,
        "CreationDate": Date(timeIntervalSince1970: 1_600_000_000),
        "ExpirationDate": expirationDate,
        "Platform": ["iOS"]
    ]

    let xml = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0
    )

    var blob = Data([0x30, 0x82, 0x12, 0x34])   // 冒充 CMS 的 SEQUENCE 头
    blob.append(xml)
    blob.append(Data("----fake-signature----".utf8))

    return try ProvisioningProfile.parse(blob)
}

/// 建一个用完自己清理的临时目录（调用方负责删，或用 defer）
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("LCSignTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 造一个结构完整的 .app 目录。
///
/// 注意这里的「可执行文件」是假的 —— IPAArchive 只检查它存在，不解析内容。
/// 需要真 Mach-O 的场景见 `EngineSelfTestTests`。
@discardableResult
func makeAppBundle(in root: URL,
                   name: String = "Demo",
                   bundleID: String = "com.example.demo",
                   displayName: String = "演示") throws -> URL {

    let payload = root.appendingPathComponent("Payload", isDirectory: true)
    let app = payload.appendingPathComponent("\(name).app", isDirectory: true)

    try FileManager.default.createDirectory(
        at: app.appendingPathComponent("EmptyDir", isDirectory: true),
        withIntermediateDirectories: true
    )

    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleExecutable": name,
        "CFBundleVersion": "7",
        "CFBundleShortVersionString": "2.3",
        "CFBundleDisplayName": displayName
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Info.plist"))

    try Data("fake-mach-o".utf8).write(to: app.appendingPathComponent(name))

    return app
}
