import Compression
import Foundation

/// 手写的 ZIP 写入器 —— 只实现 IPA 打包需要的那一小部分。
///
/// ## 为什么不用 ZIPFoundation
///
/// `Archive.addEntry` 每写一个条目，都会**先把已有的中央目录整段读出来、
/// 再连同新条目一起写回去**（见 ZIPFoundation 的
/// `Archive+Writing.swift` 第 124–155 行：`readChunk(of: existingSize)` +
/// `writeLargeChunk(existingData, ...)`）。于是写 n 个条目就是 O(n²) 的 I/O：
/// 中央目录条目约 100 字节，5000 个文件的累计写入量约 1.25 GB。
/// 大 `.app` 打包会明显变慢 —— 而这个 App 的核心用途恰恰是处理大包。
///
/// 这里换成标准的 O(n) 写法：顺序写「本地文件头 + 压缩数据」，中央目录条目
/// 先攒在内存里，最后一次性写出。内存开销与文件数成正比（每条约 100 字节），
/// 与文件大小无关。
///
/// ## 实现要点
///
/// - **压缩**用 Compression 框架的流式 API。`COMPRESSION_ZLIB` 产出的是
///   **裸 DEFLATE**（不带 zlib 头，也不带 Adler-32 校验和），正是 ZIP
///   method 8 需要的东西。之所以要流式而不是 `compression_encode_buffer`：
///   后者要求整个输入在内存里，而 `.app` 里的可执行文件动辄几百 MB。
/// - **CRC 与压缩后长度**要等数据写完才知道，所以本地文件头先写占位值，
///   数据写完后再 `seek` 回去补写。这样就不必启用 data descriptor
///   （通用位标记 bit 3），兼容性更好 —— 不少解包工具对 data descriptor
///   支持不完整。
/// - **ZIP64**：单个文件 ≥ 4 GB，或中央目录偏移/总长度/条目数超出 32 位
///   范围时启用。是否启用要在写本地头之前就决定（否则补写时长度会变），
///   而这两个条件（文件未压缩大小、当前偏移）在写之前都是已知的。
final class ZipWriter {

    // MARK: - 常量

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4b50
    private static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4b50

    private static let zip64ExtraFieldID: UInt16 = 0x0001

    /// 通用位标记第 11 位：文件名是 UTF-8
    private static let utf8Flag: UInt16 = 0x0800

    /// 高字节是「制作平台」= 3（Unix），低字节是版本 3.0。
    /// 声明成 Unix 才能让解包方按 POSIX 权限位判断条目是不是目录。
    private static let versionMadeBy: UInt16 = 0x031E
    private static let versionNeeded: UInt16 = 20
    private static let versionNeededZip64: UInt16 = 45

    private static let storeMethod: UInt16 = 0
    private static let deflateMethod: UInt16 = 8

    private static let uint32Limit: UInt64 = 0xFFFF_FFFF
    private static let uint16Limit: UInt64 = 0xFFFF

    /// 读文件的块大小。256 KB 是压缩率与内存之间的常见折中。
    private static let chunkSize = 256 * 1024

    // MARK: - 中央目录条目

    private struct CentralEntry {
        var name: Data
        var flags: UInt16
        var method: UInt16
        var dosTime: UInt16
        var dosDate: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var externalAttributes: UInt32
        /// 该条目的本地头是否带 ZIP64 扩展字段
        var localHeaderUsesZip64: Bool
    }

    // MARK: - 状态

    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [CentralEntry] = []
    private var isFinished = false

    // MARK: - 生命周期

    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: url)

        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw SigningError.packagingFailed("无法创建归档文件：\(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    /// 关掉文件句柄。没写 `finish()` 就直接关会得到一个不完整的归档，
    /// 所以调用方应该只在失败清理路径上用它。
    func close() {
        try? handle.close()
    }

    // MARK: - 写条目

    /// 写一个目录条目。
    ///
    /// 目录必须显式写进归档，否则空目录在解包后会消失 —— 而 iOS 的 `.app`
    /// 里空目录并不少见（`_CodeSignature` 之外的插件目录、资源目录等）。
    func addDirectory(_ path: String) throws {
        let name = try Self.encodedName(path.hasSuffix("/") ? path : path + "/")
        let (time, date) = Self.dosDateTime(Date())

        var header = ByteBuffer()
        header.u32(Self.localHeaderSignature)
        header.u16(Self.versionNeeded)
        header.u16(Self.utf8Flag)
        header.u16(Self.storeMethod)
        header.u16(time)
        header.u16(date)
        header.u32(0)                 // crc32
        header.u32(0)                 // 压缩后长度
        header.u32(0)                 // 未压缩长度
        header.u16(UInt16(name.count))
        header.u16(0)                 // 扩展字段长度
        header.raw(name)

        let start = offset
        try write(header.data)

        entries.append(CentralEntry(
            name: name,
            flags: Self.utf8Flag,
            method: Self.storeMethod,
            dosTime: time,
            dosDate: date,
            crc32: 0,
            compressedSize: 0,
            uncompressedSize: 0,
            localHeaderOffset: start,
            externalAttributes: Self.externalAttributes(isDirectory: true),
            localHeaderUsesZip64: false
        ))
    }

    /// 写一个文件条目，内容从 `fileURL` 流式读取并压缩。
    ///
    /// `onProgress` 回调的是 (已处理字节, 总字节)，用于界面进度条。
    func addFile(_ path: String,
                 at fileURL: URL,
                 onProgress: ((Int64, Int64) -> Void)? = nil) throws {

        let name = try Self.encodedName(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let uncompressedSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()

        let (time, date) = Self.dosDateTime(modificationDate)

        // 是否给本地头加 ZIP64 扩展字段，必须在写之前定下来：
        // 补写时长度不能变，否则会把后面的数据覆盖掉。
        let usesZip64 = UInt64(uncompressedSize) >= Self.uint32Limit
            || offset >= Self.uint32Limit

        let extraFieldLength: UInt16 = usesZip64 ? 20 : 0   // 4 字节头 + 16 字节内容

        var header = ByteBuffer()
        header.u32(Self.localHeaderSignature)
        header.u16(usesZip64 ? Self.versionNeededZip64 : Self.versionNeeded)
        header.u16(Self.utf8Flag)
        header.u16(Self.deflateMethod)
        header.u16(time)
        header.u16(date)
        header.u32(0)                                            // crc32 占位
        header.u32(usesZip64 ? 0xFFFF_FFFF : 0)                  // 压缩后长度占位
        header.u32(usesZip64 ? 0xFFFF_FFFF : 0)                  // 未压缩长度占位
        header.u16(UInt16(name.count))
        header.u16(extraFieldLength)
        header.raw(name)

        if usesZip64 {
            header.u16(Self.zip64ExtraFieldID)
            header.u16(16)
            header.u64(UInt64(uncompressedSize))
            header.u64(0)                                        // 压缩后长度占位
        }

        let localHeaderOffset = offset
        try write(header.data)

        // ---- 流式压缩并写数据 ----
        let dataOffset = offset
        let crc = try Self.streamCompress(fileURL: fileURL,
                                          uncompressedSize: uncompressedSize,
                                          sink: { [self] chunk in try write(chunk) },
                                          onProgress: onProgress)
        let compressedSize = offset - dataOffset

        if compressedSize >= Self.uint32Limit && !usesZip64 {
            // 未压缩 < 4 GB 但压缩后 ≥ 4 GB，理论上几乎不可能
            // （deflate 最坏情况只比原数据大 0.03% 左右）。
            // 真出现了就明确报错，不要写一个坏归档出去。
            throw SigningError.packagingFailed(
                "\(path) 压缩后超过 4 GB，当前写入器未对该情况启用 ZIP64。"
            )
        }

        // ---- seek 回去补写本地头里的 crc 与长度 ----
        try handle.seek(toOffset: localHeaderOffset + 14)         // 跳过签名/版本/标记/方法/时间/日期
        var patch = ByteBuffer()
        patch.u32(crc)
        patch.u32(usesZip64 ? 0xFFFF_FFFF : UInt32(compressedSize))
        patch.u32(usesZip64 ? 0xFFFF_FFFF : UInt32(UInt64(uncompressedSize)))
        try handle.write(contentsOf: patch.data)

        if usesZip64 {
            // ZIP64 扩展字段里也要把压缩后长度补上
            try handle.seek(toOffset: localHeaderOffset + 30
                            + UInt64(name.count) + 12)
            var zip64Patch = ByteBuffer()
            zip64Patch.u64(compressedSize)
            try handle.write(contentsOf: zip64Patch.data)
        }

        // 补写把文件指针留在了前面，必须回到末尾，否则下一个条目会覆盖掉刚写的数据
        _ = try handle.seekToEnd()

        entries.append(CentralEntry(
            name: name,
            flags: Self.utf8Flag,
            method: Self.deflateMethod,
            dosTime: time,
            dosDate: date,
            crc32: crc,
            compressedSize: compressedSize,
            uncompressedSize: UInt64(uncompressedSize),
            localHeaderOffset: localHeaderOffset,
            externalAttributes: Self.externalAttributes(isDirectory: false),
            localHeaderUsesZip64: usesZip64
        ))
    }

    // MARK: - 收尾

    /// 写中央目录 + 中央目录结束记录。必须调用，否则归档不可读。
    func finish() throws {
        guard !isFinished else { return }
        isFinished = true

        let centralDirectoryOffset = offset

        var buffer = ByteBuffer()
        for entry in entries {
            buffer.raw(try Self.centralDirectoryRecord(for: entry))
        }
        try write(buffer.data)

        let centralDirectorySize = offset - centralDirectoryOffset
        try write(try Self.endRecords(entries: entries,
                                      centralDirectoryOffset: centralDirectoryOffset,
                                      centralDirectorySize: centralDirectorySize))
        try handle.synchronize()
    }

    // MARK: - 底层写入

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    // MARK: - 名称编码

    private static func encodedName(_ path: String) throws -> Data {
        guard let data = path.data(using: .utf8) else {
            throw SigningError.packagingFailed("文件名无法用 UTF-8 表示：\(path)")
        }
        guard data.count <= Int(UInt16.max) else {
            throw SigningError.packagingFailed("文件名过长：\(path)")
        }
        return data
    }

    // MARK: - 权限位

    /// ZIP 用「外部属性」的高 16 位存 POSIX 模式。这里显式写上 S_IFDIR /
    /// S_IFREG，解包方（包括本项目的 ZIPFoundation 读取路径）才会把条目
    /// 判成目录而不是文件。低 16 位给目录补上 DOS 的目录位（0x10），
    /// 照顾只认 DOS 属性的老工具。
    private static func externalAttributes(isDirectory: Bool) -> UInt32 {
        let permission: UInt32 = isDirectory ? 0o755 : 0o644
        let type: UInt32 = isDirectory ? 0o040_000 : 0o100_000   // S_IFDIR / S_IFREG
        let dosDirectoryBit: UInt32 = isDirectory ? 0x10 : 0
        return ((type | permission) << 16) | dosDirectoryBit
    }

    // MARK: - 时间

    /// MS-DOS 时间格式：秒只有 2 秒精度，年份从 1980 起。
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: date)

        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let month = min(max(parts.month ?? 1, 1), 12)
        let day = min(max(parts.day ?? 1, 1), 31)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)

        let time = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (time, dosDate)
    }

    // MARK: - 压缩

    /// 把 `fileURL` 的内容用裸 DEFLATE 压出来，逐块交给 `sink`，返回 CRC32。
    private static func streamCompress(fileURL: URL,
                                       uncompressedSize: Int64,
                                       sink: (Data) throws -> Void,
                                       onProgress: ((Int64, Int64) -> Void)?) throws -> UInt32 {

        guard let input = try? FileHandle(forReadingFrom: fileURL) else {
            throw SigningError.packagingFailed("无法读取文件：\(fileURL.lastPathComponent)")
        }
        defer { try? input.close() }

        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outputBuffer.deallocate() }

        // src_ptr 在 init 之前必须非空，先塞一个 1 字节的哑指针占位。
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }

        var stream = compression_stream(dst_ptr: outputBuffer,
                                        dst_size: 0,
                                        src_ptr: UnsafePointer(dummy),
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw SigningError.packagingFailed("无法初始化压缩器。")
        }
        defer { compression_stream_destroy(&stream) }

        var crc: UInt32 = 0
        var processed: Int64 = 0

        /// 反复调用 `compression_stream_process`，把当前喂进去的输入榨干。
        /// 返回 true 表示整个压缩流已经结束。
        func pump(final: Bool) throws -> Bool {
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                stream.dst_ptr = outputBuffer
                stream.dst_size = chunkSize

                let status = compression_stream_process(&stream, flags)
                if status == COMPRESSION_STATUS_ERROR {
                    throw SigningError.packagingFailed(
                        "压缩 \(fileURL.lastPathComponent) 时 zlib 报错。"
                    )
                }

                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    try sink(Data(bytes: outputBuffer, count: produced))
                }

                if status == COMPRESSION_STATUS_END { return true }

                // status == OK：输入还没吃完、或输出写满了还有余量，就继续；
                // 两者都不成立说明这轮喂的输入已经处理干净，等下一块。
                if stream.src_size > 0 { continue }
                if stream.dst_size == 0 { continue }
                return false
            }
        }

        // 逐块喂输入（中间块都不带 FINALIZE）
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            try chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    throw SigningError.packagingFailed(
                        "读取 \(fileURL.lastPathComponent) 失败。"
                    )
                }
                stream.src_ptr = base
                stream.src_size = raw.count
                crc = Self.crc32(crc, raw)
                processed += Int64(raw.count)
                onProgress?(processed, uncompressedSize)
                _ = try pump(final: false)
            }
        }

        // 收尾：喂一块空输入并带上 FINALIZE，让 zlib 吐出结束块。
        // 空文件（一个字节都没读到）走的也是这条路。
        stream.src_ptr = UnsafePointer(dummy)
        stream.src_size = 0
        _ = try pump(final: true)
        onProgress?(processed, max(uncompressedSize, processed))

        return crc
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// 逐字节算 CRC32。大文件下这里不是最快的实现，但比压缩本身便宜得多，
    /// 没必要为它引入额外的 C 依赖。
    private static func crc32(_ seed: UInt32, _ buffer: UnsafeRawBufferPointer) -> UInt32 {
        var value = seed ^ 0xFFFF_FFFF
        for byte in buffer {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    // MARK: - 中央目录

    private static func centralDirectoryRecord(for entry: CentralEntry) throws -> Data {
        let needsZip64Sizes = entry.compressedSize >= uint32Limit
            || entry.uncompressedSize >= uint32Limit
            || entry.localHeaderUsesZip64
        let needsZip64Offset = entry.localHeaderOffset >= uint32Limit

        var extra = ByteBuffer()
        if needsZip64Sizes || needsZip64Offset {
            var payload = ByteBuffer()
            // 顺序是固定的：未压缩长度、压缩后长度、本地头偏移。
            // 哪些字段真正溢出，就只写哪些，但顺序不能变。
            if needsZip64Sizes {
                payload.u64(entry.uncompressedSize)
                payload.u64(entry.compressedSize)
            }
            if needsZip64Offset {
                payload.u64(entry.localHeaderOffset)
            }
            extra.u16(zip64ExtraFieldID)
            extra.u16(UInt16(payload.data.count))
            extra.raw(payload.data)
        }

        var record = ByteBuffer()
        record.u32(centralHeaderSignature)
        record.u16(versionMadeBy)
        record.u16((needsZip64Sizes || needsZip64Offset) ? versionNeededZip64 : versionNeeded)
        record.u16(entry.flags)
        record.u16(entry.method)
        record.u16(entry.dosTime)
        record.u16(entry.dosDate)
        record.u32(entry.crc32)
        record.u32(needsZip64Sizes ? 0xFFFF_FFFF : UInt32(entry.compressedSize))
        record.u32(needsZip64Sizes ? 0xFFFF_FFFF : UInt32(entry.uncompressedSize))
        record.u16(UInt16(entry.name.count))
        record.u16(UInt16(extra.data.count))
        record.u16(0)                                       // 注释长度
        record.u16(0)                                       // 起始磁盘号
        record.u16(0)                                       // 内部属性
        record.u32(entry.externalAttributes)
        record.u32(needsZip64Offset ? 0xFFFF_FFFF : UInt32(entry.localHeaderOffset))
        record.raw(entry.name)
        record.raw(extra.data)
        return record.data
    }

    private static func endRecords(entries: [CentralEntry],
                                   centralDirectoryOffset: UInt64,
                                   centralDirectorySize: UInt64) throws -> Data {

        let count = UInt64(entries.count)
        // 按 APPNOTE 4.4.1.1，只有这三种情况才必须写 ZIP64 结束记录。
        // 单个条目用了 ZIP64 扩展字段、但整体没超范围时，不需要写它 ——
        // 少写一份就少一处兼容性风险。
        let needsZip64 = count >= uint16Limit
            || centralDirectoryOffset >= uint32Limit
            || centralDirectorySize >= uint32Limit

        var out = ByteBuffer()

        if needsZip64 {
            let zip64RecordOffset = centralDirectoryOffset + centralDirectorySize

            // ZIP64 中央目录结束记录
            out.u32(zip64EndOfCentralDirectorySignature)
            out.u64(44)                                     // 本记录剩余长度
            out.u16(versionMadeBy)
            out.u16(versionNeededZip64)
            out.u32(0)                                      // 本磁盘号
            out.u32(0)                                      // 中央目录起始磁盘号
            out.u64(count)
            out.u64(count)
            out.u64(centralDirectorySize)
            out.u64(centralDirectoryOffset)

            // ZIP64 定位器
            out.u32(zip64EndOfCentralDirectoryLocatorSignature)
            out.u32(0)                                      // ZIP64 结束记录所在磁盘号
            out.u64(zip64RecordOffset)
            out.u32(1)                                      // 总磁盘数
        }

        // 传统中央目录结束记录。超出 32 位范围时按规范填哨兵值。
        out.u32(endOfCentralDirectorySignature)
        out.u16(0)
        out.u16(0)
        out.u16(UInt16(min(count, uint16Limit)))
        out.u16(UInt16(min(count, uint16Limit)))
        out.u32(UInt32(min(centralDirectorySize, uint32Limit)))
        out.u32(UInt32(min(centralDirectoryOffset, uint32Limit)))
        out.u16(0)                                          // 注释长度
        return out.data
    }
}

// MARK: - 小端字节缓冲

/// 极简的小端写入缓冲。ZIP 的所有多字节字段都是小端。
private struct ByteBuffer {
    private(set) var data = Data()

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    mutating func raw(_ bytes: Data) {
        data.append(bytes)
    }
}
