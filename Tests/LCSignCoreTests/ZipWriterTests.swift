import XCTest
import ZIPFoundation
import LCSignCore

/// `ZipWriter` 的往返一致性。
///
/// 为什么值得单独钉死：打包是**唯一一条会把整个 .app 重写一遍**的路径，
/// 而它坏了是静默的 —— 归档结构错一个字节，`unzip -l` 可能照样能列出条目，
/// 直到装到设备上才炸。而 ZIP 的字节布局又特别容易写错（偏移、长度、
/// 哨兵值、补写位置），所以这里逐项验证：
///
///   - 多块文件（跨过 256 KB 的读块边界，走多次压缩循环）
///   - 0 字节文件（走「喂空输入 + FINALIZE」的收尾路径）
///   - 非 ASCII 文件名（通用位标记 + 名字长度按字节算）
///   - 空目录（目录条目必须显式写进归档）
///   - 字节级内容一致 + CRC32 一致
///
/// 读取侧用 ZIPFoundation 的 `Archive`，与写入侧是两套完全独立的实现 ——
/// 所以「能读回来且内容一致」本身就是一次交叉验证。
final class ZipWriterTests: XCTestCase {

    // MARK: - 多块文件

    /// 2 MB 的伪随机数据，跨 8 个读块。压缩比接近 1:1，
    /// 正好覆盖「压缩后输出塞满输出缓冲、需要多轮 pump」的分支。
    func testRoundTripPreservesLargeFileBytes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = pseudoRandomData(count: 2 * 1024 * 1024 + 12_345, seed: 0x5EED)

        let app = try makeAppBundle(in: root, name: "Large")
        try payload.write(to: app.appendingPathComponent("Big.bin"))

        let ipa = root.appendingPathComponent("Large.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let out = root.appendingPathComponent("out", isDirectory: true)
        let contents = try IPAArchive.extract(ipa: ipa, to: out)

        let extracted = try Data(contentsOf: contents.appBundle.appendingPathComponent("Big.bin"))
        XCTAssertEqual(extracted.count, payload.count, "解出来的长度与源文件不一致")
        XCTAssertEqual(extracted, payload, "解出来的内容与源文件不一致")
    }

    // MARK: - 0 字节文件

    func testRoundTripPreservesEmptyFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Empty")
        try Data().write(to: app.appendingPathComponent("Zero.bin"))

        let ipa = root.appendingPathComponent("Empty.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let out = root.appendingPathComponent("out", isDirectory: true)
        let contents = try IPAArchive.extract(ipa: ipa, to: out)

        let zero = contents.appBundle.appendingPathComponent("Zero.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zero.path),
                      "0 字节文件在往返中丢失")
        XCTAssertEqual(try Data(contentsOf: zero).count, 0)
    }

    // MARK: - 非 ASCII 文件名

    func testRoundTripPreservesUnicodeNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Unicode")
        let directory = app.appendingPathComponent("中文资源", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let expected = Data("中文内容 with emoji 🎉\n".utf8)
        try expected.write(to: directory.appendingPathComponent("说明.txt"))

        let ipa = root.appendingPathComponent("Unicode.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let out = root.appendingPathComponent("out", isDirectory: true)
        let contents = try IPAArchive.extract(ipa: ipa, to: out)

        let restored = contents.appBundle
            .appendingPathComponent("中文资源")
            .appendingPathComponent("说明.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path),
                      "中文目录 / 文件名在往返中丢失")
        XCTAssertEqual(try Data(contentsOf: restored), expected)
    }

    // MARK: - 结构

    /// 归档里的条目类型必须能被子类实现正确识别：目录条目要带 POSIX 目录位，
    /// 否则解包方会把 `Payload/` 当成一个 0 字节的**文件**，
    /// 后面创建 `Payload/xxx.app/...` 时就会报「同名文件已存在」。
    func testDirectoryEntriesAreRecognizedAsDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Types")
        let ipa = root.appendingPathComponent("Types.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let archive = try XCTUnwrap(
            try? Archive(url: ipa, accessMode: .read, pathEncoding: nil)
        )

        var directoryCount = 0
        var fileCount = 0
        for entry in archive {
            if entry.path.hasSuffix("/") {
                XCTAssertEqual(entry.type, .directory,
                               "\(entry.path) 带目录后缀，但类型不是 directory")
                directoryCount += 1
            } else {
                XCTAssertEqual(entry.type, .file,
                               "\(entry.path) 的类型不是 file")
                fileCount += 1
            }
        }

        XCTAssertGreaterThan(directoryCount, 0, "归档里没有任何目录条目")
        XCTAssertGreaterThan(fileCount, 0, "归档里没有任何文件条目")
    }

    /// 目录条目必须真的写进归档，不能只靠子文件把路径「带出来」——
    /// 否则空目录会消失，而 iOS 的 .app 里空目录并不少见。
    func testEmptyDirectorySurvivesRoundTrip() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Dir")
        let ipa = root.appendingPathComponent("Dir.ipa")
        try IPAArchive.package(appBundle: app, to: ipa)

        let archive = try XCTUnwrap(
            try? Archive(url: ipa, accessMode: .read, pathEncoding: nil)
        )
        let paths = Set(archive.map(\.path))
        XCTAssertTrue(paths.contains("Payload/"), "缺 Payload/ 目录条目")
        XCTAssertTrue(paths.contains("Payload/Dir.app/EmptyDir/"),
                      "缺空目录条目，空目录会在解包后消失")
    }

    // MARK: - 进度回调

    /// 进度必须单调不减、落在 0…1，且结束时达到 1.0。
    /// 进度算错本身不影响产物，但会让界面在打包大包时看起来「卡死」。
    func testProgressIsMonotonicAndReachesOne() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try makeAppBundle(in: root, name: "Progress")
        try pseudoRandomData(count: 900 * 1024, seed: 7)
            .write(to: app.appendingPathComponent("Big.bin"))

        let ipa = root.appendingPathComponent("Progress.ipa")

        var samples: [Double] = []
        try IPAArchive.package(appBundle: app, to: ipa) { samples.append($0) }

        XCTAssertFalse(samples.isEmpty, "进度回调一次都没触发")
        XCTAssertEqual(samples.last ?? 0, 1.0, accuracy: 0.0001,
                       "进度没有收敛到 1.0")

        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next + 0.0001, "进度出现回退")
        }
        for value in samples {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    // MARK: - 输入校验

    func testExtractRejectsNonZipInput() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bogus = root.appendingPathComponent("bogus.ipa")
        try Data(repeating: 0x41, count: 4096).write(to: bogus)

        let out = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try IPAArchive.extract(ipa: bogus, to: out)) { error in
            guard let signingError = error as? SigningError else {
                return XCTFail("期望 SigningError，实际 \(type(of: error))")
            }
            guard case .archiveUnreadable = signingError else {
                return XCTFail("期望 archiveUnreadable，实际 \(signingError)")
            }
        }
    }

    /// 归档能打开、但里面没有 .app 时，报错必须带上「实际有什么」，
    /// 否则用户拿到的只是一句无法排查的「不是有效归档」。
    func testMissingAppBundleErrorCarriesDiagnostics() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let ipa = root.appendingPathComponent("noapp.ipa")
        try createArchive(at: ipa) { archive in
            try add(entry: "Payload/README.txt",
                    data: Data("no app here".utf8),
                    to: archive)
        }

        let out = root.appendingPathComponent("out", isDirectory: true)
        XCTAssertThrowsError(try IPAArchive.extract(ipa: ipa, to: out)) { error in
            guard let signingError = error as? SigningError else {
                return XCTFail("期望 SigningError，实际 \(type(of: error))")
            }
            guard case .noAppBundleInArchive(let detail) = signingError else {
                return XCTFail("期望 noAppBundleInArchive，实际 \(signingError)")
            }
            XCTAssertTrue(detail.contains("Payload"),
                          "诊断信息里应带上 Payload 里的实际内容，实际：\(detail)")
        }
    }

    // MARK: - 辅助

    /// 可复现的伪随机数据。用固定种子的 LCG 而不是 `SystemRandomNumberGenerator`，
    /// 这样测试失败时能原样重现，不依赖运气。
    private func pseudoRandomData(count: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        return Data(bytes)
    }

    /// 见 IPAArchiveTests 里的同名函数：归档对象在析构时才落盘，
    /// 同一个作用域里写读会读到半成品。
    private func createArchive(at url: URL, _ body: (Archive) throws -> Void) throws {
        let archive = try XCTUnwrap(
            try? Archive(url: url, accessMode: .create, pathEncoding: nil)
        )
        try body(archive)
    }

    private func add(entry name: String, data: Data, to archive: Archive) throws {
        try archive.addEntry(
            with: name,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none,
            provider: { (_: Int64, _: Int) throws -> Data in data }
        )
    }
}
