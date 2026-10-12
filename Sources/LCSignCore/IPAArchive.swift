import Foundation
import ZIPFoundation

/// IPA 的解包与打包。
///
/// 解包仍用 ZIPFoundation（它的读取路径没问题），打包改用自己的
/// ``ZipWriter`` —— 原因见那个类型的注释（ZIPFoundation 的写入是 O(n²)）。
///
/// 两条路径都注意用流式方式逐条处理，不要 `Data(contentsOf:)` 整个读进来 ——
/// 一个解包后几百 MB 的 IPA 会直接把内存打爆。
public enum IPAArchive {

    /// 解包结果
    public struct Contents: Sendable {
        public let appBundle: URL
        public let bundleID: String
        public let bundleVersion: String
        public let displayName: String
        public let executableName: String
    }

    // MARK: - 解包

    /// 解包 IPA 到指定目录，返回 .app 的路径与清单信息
    public static func extract(ipa: URL, to directory: URL) throws -> Contents {
        let fm = FileManager.default

        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let archive = try? Archive(url: ipa, accessMode: .read, pathEncoding: nil) else {
            throw SigningError.archiveUnreadable(
                "\(ipa.lastPathComponent) 不是合法的 zip，或文件已被截断。"
            )
        }

        var extractedFiles = 0

        for entry in archive {
            // 目录判定同时看 entry.type 和路径后缀：ZIP 规范里「以 / 结尾」
            // 就是目录，两个条件取或比只信其中一个稳。
            let isDirectory = entry.type == .directory || entry.path.hasSuffix("/")

            guard let relative = sanitizedRelativePath(entry.path), !relative.isEmpty else {
                // 会逃出目标目录的条目，直接丢掉
                continue
            }

            let destination = directory.appendingRelativePath(relative)

            if isDirectory {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }

            if entry.type == .symlink {
                // 正常 IPA 里不该出现符号链接。出现了就跳过 ——
                // 链接目标可能指向容器外，是典型的路径逃逸手法。
                continue
            }

            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            // 自己落盘，不用 ZIPFoundation 的 `extract(_:to:)`：
            // 那个重载会调 transferAttributes，把归档里记的 posixPermissions
            // 原样盖到文件上；一旦那一位是 0，落盘的文件或目录就变成不可读，
            // 后续 inspect 会以「没有 Payload」这种误导性的方式失败。
            // 用 consumer 重载可以绕开它，同时也绕开「目标已存在就报错」的
            // 前置检查（归档里出现重复条目时那个检查会直接让解包失败）。
            if !fm.fileExists(atPath: destination.path) {
                guard fm.createFile(atPath: destination.path, contents: nil) else {
                    throw SigningError.packagingFailed("无法创建文件：\(relative)")
                }
            }
            let handle = try FileHandle(forWritingTo: destination)
            do {
                try handle.truncate(atOffset: 0)
                _ = try archive.extract(entry, consumer: { chunk in
                    try handle.write(contentsOf: chunk)
                })
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            extractedFiles += 1
        }

        return try inspect(directory: directory, extractedFileCount: extractedFiles)
    }

    /// 在已解包的目录里定位 .app 并读取清单
    public static func inspect(directory: URL) throws -> Contents {
        try inspect(directory: directory, extractedFileCount: nil)
    }

    private static func inspect(directory: URL, extractedFileCount: Int?) throws -> Contents {
        let fm = FileManager.default
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)

        var isDirectoryFlag: ObjCBool = false
        guard fm.fileExists(atPath: payload.path, isDirectory: &isDirectoryFlag),
              isDirectoryFlag.boolValue else {
            // 把「实际解出了什么」一并带上。这类失败最容易被一句
            // 「不是有效归档」糊过去，而真正的原因往往就写在目录内容里。
            var detail = "解包目录里没有 Payload 文件夹。"
            if let extractedFileCount, extractedFileCount == 0 {
                detail = "归档里没有任何条目被解出来 —— 要么归档是空的，"
                       + "要么所有条目都被路径安全校验拦掉了。"
            }
            throw SigningError.noAppBundleInArchive(
                detail + listing(directory: directory)
            )
        }

        let entries = (try? fm.contentsOfDirectory(at: payload,
                                                   includingPropertiesForKeys: nil,
                                                   options: [])) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw SigningError.noAppBundleInArchive(
                "Payload 里没有 .app。" + listing(directory: payload)
            )
        }

        let infoURL = app.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL) else {
            throw SigningError.noAppBundleInArchive(
                "\(app.lastPathComponent) 里读不到 Info.plist。" + listing(directory: app)
            )
        }
        guard let info = (try? PropertyListSerialization.propertyList(from: infoData,
                                                                     options: [],
                                                                     format: nil))
                            as? [String: Any] else {
            throw SigningError.noAppBundleInArchive(
                "\(app.lastPathComponent)/Info.plist 不是合法的 plist 字典。"
            )
        }

        let executable = info["CFBundleExecutable"] as? String ?? ""
        guard !executable.isEmpty,
              fm.fileExists(atPath: app.appendingPathComponent(executable).path) else {
            throw SigningError.executableMissing(executable.isEmpty ? "(未知)" : executable)
        }

        return Contents(
            appBundle: app,
            bundleID: info["CFBundleIdentifier"] as? String ?? "",
            bundleVersion: info["CFBundleShortVersionString"] as? String ?? "1.0",
            displayName: (info["CFBundleDisplayName"] as? String)
                      ?? (info["CFBundleName"] as? String)
                      ?? app.deletingPathExtension().lastPathComponent,
            executableName: executable
        )
    }

    // MARK: - 打包

    /// 把已签名的 .app 重新打成 IPA。
    ///
    /// IPA 的结构是 `Payload/xxx.app/...`，所以归档里的根目录就是 `Payload`。
    ///
    /// `onProgress` 回调 0.0–1.0 的进度，用于界面进度条。
    public static func package(appBundle: URL,
                               to ipa: URL,
                               onProgress: ((Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        let payload = appBundle.deletingLastPathComponent()

        guard fm.fileExists(atPath: payload.path) else {
            throw SigningError.packagingFailed("找不到 Payload 目录：\(payload.lastPathComponent)")
        }

        let writer = try ZipWriter(url: ipa)
        var succeeded = false
        defer {
            writer.close()
            // 失败时别把半个归档留在输出目录里 —— 用户看到文件会以为成功了
            if !succeeded { try? fm.removeItem(at: ipa) }
        }

        do {
            let total = totalBytes(of: payload)
            let counter = ByteCounter()

            try addDirectory(payload,
                             relativePath: "Payload",
                             into: writer,
                             totalBytes: total,
                             counter: counter,
                             onProgress: onProgress)

            try writer.finish()
            succeeded = true
        } catch let error as SigningError {
            throw error
        } catch {
            throw SigningError.packagingFailed(error.localizedDescription)
        }
    }

    /// 已处理字节数的累加器。
    ///
    /// 用引用类型而不是 `inout Int64`：`addFile` 的 `onProgress` 是**可选**
    /// 函数类型参数，而可选函数类型参数在 Swift 里默认是 escaping 的，
    /// escaping 闭包捕获 `inout` 参数会直接编译报错
    /// （`escaping closure captures 'inout' parameter`）。
    /// 换成一个小盒子，闭包捕获的是对象引用，问题消失。
    private final class ByteCounter {
        var processed: Int64 = 0
    }

    /// 递归把 `directory` 写进归档。
    ///
    /// 相对路径是**一路拼出来的**，不做任何绝对路径的前缀运算 ——
    /// 见 `sanitizedRelativePath` 上方的注释，这类前缀运算在真机上会因
    /// `/var` → `/private/var` 的符号链接而算出不一致的结果。
    private static func addDirectory(_ directory: URL,
                                     relativePath: String,
                                     into writer: ZipWriter,
                                     totalBytes: Int64,
                                     counter: ByteCounter,
                                     onProgress: ((Double) -> Void)?) throws {
        let fm = FileManager.default

        // 目录条目必须显式写进归档，否则空目录在解包后会消失
        //（iOS 的 .app 里空目录并不少见）。
        try writer.addDirectory(relativePath)

        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) ?? false

            let childRelativePath = relativePath + "/" + child.lastPathComponent

            if isDirectory {
                try addDirectory(child,
                                 relativePath: childRelativePath,
                                 into: writer,
                                 totalBytes: totalBytes,
                                 counter: counter,
                                 onProgress: onProgress)
                continue
            }

            try writer.addFile(childRelativePath, at: child) { processed, _ in
                guard totalBytes > 0 else { return }
                onProgress?(Double(counter.processed + processed) / Double(totalBytes))
            }
            counter.processed += fileSize(child)
        }
    }

    // MARK: - 路径安全

    /// 把归档里的条目路径归一化成安全的相对路径。
    ///
    /// 返回 `nil` 表示这条路径会逃出目标目录，必须丢弃。
    ///
    /// ## 为什么不用 `standardizedFileURL`
    ///
    /// 原实现是这么做的：拿 `directory.standardizedFileURL.path` 当基准，
    /// 再拿 `appendingPathComponent(entry.path).standardizedFileURL.path`
    /// 去比前缀。这个写法**只在真机上会挂**：
    ///
    /// iOS 的临时目录在 `/var/...`，而 `/var` 是指向 `/private/var` 的符号
    /// 链接。已经存在的基准目录会被标准化成 `/private/var/...`，而刚拼出来、
    /// 还没创建的条目目标不会 —— 前缀比对于是全部失败，所有条目都被当成
    /// 「路径逃逸」跳过，最后以「没有 Payload 目录」这种误导性的方式报错。
    /// 模拟器上路径在 `/Users` 下，没有这层链接，所以一直是绿的。
    ///
    /// 改成纯词法归一化：只看路径本身，与它存不存在无关。
    static func sanitizedRelativePath(_ raw: String) -> String? {
        var components: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(String(part))
        }
        guard !components.isEmpty else { return nil }

        var result = components.joined(separator: "/")
        if raw.hasSuffix("/") { result += "/" }
        return result
    }

    // MARK: - 诊断信息

    /// 生成一小段「这个目录里实际有什么」的描述，附在报错里。
    private static func listing(directory: URL, limit: Int = 8) -> String {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return "（\(directory.lastPathComponent) 不存在或读不到）"
        }
        guard !items.isEmpty else {
            return "（\(directory.lastPathComponent) 是空的）"
        }
        let shown = items.sorted().prefix(limit).joined(separator: "、")
        let more = items.count > limit ? "，另有 \(items.count - limit) 项" : ""
        return " 实际内容：\(shown)\(more)。"
    }

    // MARK: - 小工具

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
            .int64Value ?? 0
    }

    /// 预先算出总字节数，用于把打包进度换算成百分比。
    /// 只读元数据，不读文件内容。
    private static func totalBytes(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - 相对路径拼接

extension URL {

    /// 逐段拼接相对路径。
    ///
    /// 不直接用 `appendingPathComponent(整个相对路径)`：部分 Foundation 版本
    /// 会把里面的 `/` 百分号转义掉，拼出一个名字里带 `%2F` 的文件。
    func appendingRelativePath(_ relative: String) -> URL {
        var url = self
        for part in relative.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        return url
    }
}
