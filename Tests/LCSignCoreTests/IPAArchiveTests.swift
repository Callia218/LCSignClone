import XCTest
import ZIPFoundation
import LCSignCore

/// IPA 的解包与打包。
///
/// 这块代码在真机上最容易出问题（沙盒路径、权限、大文件流式处理），
/// 而且一旦坏了是静默的 —— 打出来的 IPA 少个空目录、多一层前缀，
/// 装的时候才报错。所以往返一致性要在这里钉死。
final class IPAArchiveTests: XCTestCase {

    // MARK: - 往返一致性

    func testPackageThenExtractRoundTrip() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root)
        let ipa = root.appendingPathComponent("Demo.ipa")

        try IPAArchive.package(appBundle: app, to: ipa)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipa.path))

        let out = root.appendingPathComponent("out", isDirectory: true)
        let contents = try IPAArchive.extract(ipa: ipa, to: out)

        XCTAssertEqual(contents.bundleID, "com.example.demo")
        XCTAssertEqual(contents.executableName, "Demo")
        XCTAssertEqual(contents.bundleVersion, "2.3")
        XCTAssertEqual(contents.displayName, "演示")

        // 空目录必须活下来：真实 .app 里这种目录不少，丢了会导致签名产物结构不完整
        var isDirectory: ObjCBool = false
        let emptyDir = contents.appBundle.appendingPathComponent("EmptyDir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emptyDir.path,
                                                    isDirectory: &isDirectory),
                      "空目录在打包/解包往返中丢失了")
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExtractedPayloadKeepsIPALayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Layout")
        let ipa = root.appendingPathComponent("Layout.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let out = root.appendingPathComponent("out", isDirectory: true)
        _ = try IPAArchive.extract(ipa: ipa, to: out)

        // IPA 的结构必须是 Payload/xxx.app/...，少一层或多一层都装不上
        let payload = out.appendingPathComponent("Payload", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path,
                                                    isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: payload.appendingPathComponent("Layout.app/Info.plist").path
        ))
    }

    // MARK: - 安全性

    func testExtractRejectsPathTraversal() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // 手工造一个带 `../` 条目的归档。正常 IPA 里不该出现这种条目，
        // 出现了就是典型的路径逃逸手法 —— 解包时必须跳过，不能写到目标目录外。
        let evil = root.appendingPathComponent("evil.ipa")
        try createArchive(at: evil) { archive in
            try add(entry: "../escaped.txt",
                    data: Data("pwned".utf8),
                    to: archive)

            let info: [String: Any] = [
                "CFBundleIdentifier": "com.example.evil",
                "CFBundleExecutable": "Evil",
                "CFBundleVersion": "1"
            ]
            try add(entry: "Payload/Evil.app/Info.plist",
                    data: try PropertyListSerialization.data(
                        fromPropertyList: info, format: .xml, options: 0
                    ),
                    to: archive)
            try add(entry: "Payload/Evil.app/Evil",
                    data: Data("fake-mach-o".utf8),
                    to: archive)
        }

        let out = root.appendingPathComponent("out", isDirectory: true)
        _ = try IPAArchive.extract(ipa: evil, to: out)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("escaped.txt").path
            ),
            "`../` 条目逃出了目标目录"
        )
        // 合法的部分仍然要正常解出来，不能因为一条恶意条目就整包失败
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("Payload/Evil.app/Info.plist").path
            )
        )
    }

    func testExtractRejectsArchiveWithoutAppBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let ipa = root.appendingPathComponent("empty.ipa")
        try createArchive(at: ipa) { archive in
            try add(entry: "Payload/README.txt",
                    data: Data("no app here".utf8),
                    to: archive)
        }

        let out = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try IPAArchive.extract(ipa: ipa, to: out))
    }

    // MARK: - 辅助

    /// 把归档的创建收进一个函数，让 `Archive` 在返回前离开作用域。
    /// ZIPFoundation 的归档对象在析构时才把中央目录落盘，
    /// 直接在同一个作用域里写读会读到半成品。
    private func createArchive(at url: URL, _ body: (Archive) throws -> Void) throws {
        let archive = try XCTUnwrap(
            try? Archive(url: url, accessMode: .create, pathEncoding: nil)
        )
        try body(archive)
    }

    private func add(entry name: String, data: Data, to archive: Archive) throws {
        // 显式写 Int64 并标注闭包参数类型，避开 ZIPFoundation 里
        // 新旧两个 addEntry 重载的歧义。
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none,
            provider: { (_: Int64, _: Int) throws -> Data in data }
        )
    }
}
