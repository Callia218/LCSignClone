import Foundation
import ZIPFoundation

/// IPA 的解包与打包。
///
/// 注意用流式方式逐条处理，不要 `Data(contentsOf:)` 整个读进来 ——
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

        guard let archive = Archive(url: ipa, accessMode: .read) else {
            throw SigningError.noAppBundleInArchive
        }

        let basePath = directory.standardizedFileURL.path

        for entry in archive {
            let destination = directory.appendingPathComponent(entry.path).standardizedFileURL

            // 防 zip slip：条目路径不能逃出目标目录
            guard destination.path == basePath
                    || destination.path.hasPrefix(basePath + "/") else {
                continue
            }

            switch entry.type {
            case .directory:
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)

            case .file:
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destination)

            @unknown default:
                continue
            }
        }

        return try inspect(directory: directory)
    }

    /// 在已解包的目录里定位 .app 并读取清单
    public static func inspect(directory: URL) throws -> Contents {
        let fm = FileManager.default
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)

        let entries = (try? fm.contentsOfDirectory(at: payload,
                                                   includingPropertiesForKeys: nil,
                                                   options: [])) ?? []
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw SigningError.noAppBundleInArchive
        }

        let infoURL = app.appendingPathComponent("Info.plist")
        guard let info = try? PropertyListSerialization
            .propertyList(from: Data(contentsOf: infoURL), options: [], format: nil)
                as? [String: Any] else {
            throw SigningError.noAppBundleInArchive
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

    /// 把已签名的 .app 重新打成 IPA
    ///
    /// IPA 的结构是 `Payload/xxx.app/...`，所以压缩的基准目录是 `Payload` 的父目录。
    public static func package(appBundle: URL, to ipa: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ipa.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: ipa)

        guard let archive = Archive(url: ipa, accessMode: .create) else {
            throw SigningError.packagingFailed("无法创建归档文件")
        }

        let payload = appBundle.deletingLastPathComponent()
        let root = payload.deletingLastPathComponent()

        do {
            try addDirectory(payload, relativeTo: root, into: archive)
        } catch {
            throw SigningError.packagingFailed(error.localizedDescription)
        }
    }

    private static func addDirectory(_ directory: URL,
                                     relativeTo base: URL,
                                     into archive: Archive) throws {
        let fm = FileManager.default
        let basePath = base.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path

        guard dirPath.hasPrefix(basePath) else { return }

        var relative = String(dirPath.dropFirst(basePath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        guard !relative.isEmpty else { return }
        relative += "/"

        try archive.addEntry(with: relative,
                             type: .directory,
                             uncompressedSize: 0,
                             compressionMethod: .none,
                             provider: { _, _ in Data() })

        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) ?? false

            if isDirectory {
                try addDirectory(child, relativeTo: base, into: archive)
                continue
            }

            let childPath = child.standardizedFileURL.path
            guard childPath.hasPrefix(basePath + "/") else { continue }

            var rel = String(childPath.dropFirst(basePath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }

            try archive.addEntry(with: rel, fileURL: child, compressionMethod: .deflate)
        }
    }
}
