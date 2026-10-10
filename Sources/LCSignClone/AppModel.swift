import Foundation
import LCSignCore
import SwiftUI
import UniformTypeIdentifiers

/// 一次签名任务在界面上的表示
struct SigningTask: Identifiable {
    enum Status: Equatable {
        case running
        case success
        case failed(String)
    }

    let id = UUID()
    var name: String
    var stage: String = "准备中"
    var fraction: Double = 0
    var status: Status = .running
    var outputURL: URL?
    var startedAt = Date()

    var isRunning: Bool { status == .running }
}

@MainActor
final class AppModel: ObservableObject {

    @Published var certificates: [SigningCertificate] = []
    @Published var tasks: [SigningTask] = []
    @Published var alert: AlertPayload?

    /// 从其他 App 通过分享菜单投递进来的 IPA，等用户在签名界面确认
    @Published var pendingIPA: URL?

    struct AlertPayload: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private let store = CertificateStore.shared
    private let service = SigningService()

    // MARK: - 证书

    func refreshCertificates() async {
        do {
            certificates = try await store.all()
        } catch {
            present(error, title: "读取证书库失败")
        }
    }

    func importCertificate(p12: URL, password: String, provision: URL?) async {
        do {
            // 沙盒外的文件先搬进来，否则后续签名时权限已被回收
            let localP12 = try Self.copyIntoSandbox(p12)
            let localProvision = try provision.map(Self.copyIntoSandbox)

            _ = try await store.add(p12: localP12,
                                    password: password,
                                    provision: localProvision)

            try? FileManager.default.removeItem(at: localP12)
            if let localProvision { try? FileManager.default.removeItem(at: localProvision) }

            await refreshCertificates()
        } catch {
            present(error, title: "导入证书失败")
        }
    }

    func remove(_ certificate: SigningCertificate) async {
        do {
            try await store.remove(certificate.id)
            await refreshCertificates()
        } catch {
            present(error, title: "删除失败")
        }
    }

    // MARK: - 外部投递

    /// 处理通过分享菜单 / URL Scheme 投递进来的文件。
    /// 只接收 .ipa，其他类型直接拒绝 —— 不要静默吞掉。
    func acceptIncoming(_ url: URL) async {
        guard url.pathExtension.lowercased() == "ipa" else {
            alert = AlertPayload(title: "不支持的文件类型",
                                 message: "目前只接收 .ipa 文件，收到的是 .\(url.pathExtension)。")
            return
        }
        do {
            pendingIPA = try Self.copyIntoSandbox(url)
        } catch {
            present(error, title: "接收文件失败")
        }
    }

    // MARK: - 签名

    func startSigning(input: URL,
                      certificate: SigningCertificate,
                      password: String?,
                      bundleID: String?,
                      displayName: String?) async {

        let task = SigningTask(name: input.deletingPathExtension().lastPathComponent)
        tasks.insert(task, at: 0)
        let taskID = task.id

        do {
            let localInput = try Self.copyIntoSandbox(input)
            defer { try? FileManager.default.removeItem(at: localInput) }

            let p12 = await store.p12URL(for: certificate)
            let provision = await store.provisionURL(for: certificate)

            let resolvedPassword: String
            if let password, !password.isEmpty {
                resolvedPassword = password
            } else {
                resolvedPassword = try await store.password(for: certificate)
            }

            let outputDir = try Self.outputDirectory()
            let output = SigningRequest.defaultOutputURL(for: input, in: outputDir)

            let request = SigningRequest(
                inputIPA: localInput,
                outputIPA: output,
                p12: p12,
                p12Password: resolvedPassword,
                provision: provision,
                bundleID: bundleID?.isEmpty == true ? nil : bundleID,
                displayName: displayName?.isEmpty == true ? nil : displayName
            )

            let result = try await service.sign(request) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          let index = self.tasks.firstIndex(where: { $0.id == taskID })
                    else { return }
                    self.tasks[index].stage = progress.stage.rawValue
                    self.tasks[index].fraction = progress.fraction
                }
            }

            update(taskID) {
                $0.status = .success
                $0.stage = "已完成"
                $0.fraction = 1
                $0.outputURL = result
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                       ?? error.localizedDescription
            let suggestion = (error as? LocalizedError)?.recoverySuggestion

            update(taskID) {
                $0.status = .failed(message)
                $0.stage = "失败"
            }

            alert = AlertPayload(
                title: "签名失败",
                message: suggestion.map { "\(message)\n\n\($0)" } ?? message
            )
        }
    }

    private func update(_ id: UUID, _ mutate: (inout SigningTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    // MARK: - 工具

    private func present(_ error: Error, title: String) {
        let message = (error as? LocalizedError)?.errorDescription
                   ?? error.localizedDescription
        let suggestion = (error as? LocalizedError)?.recoverySuggestion
        alert = AlertPayload(title: title,
                             message: suggestion.map { "\(message)\n\n\($0)" } ?? message)
    }

    /// 把沙盒外的文件复制到 App 容器内。
    /// 用户通过「文件」App 选中的文件只是临时授权，签名过程中权限会失效。
    static func copyIntoSandbox(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// 签名产物的输出目录：Documents/Signed，方便通过「文件」App 取走
    static func outputDirectory() throws -> URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Signed", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - 文件类型

extension UTType {
    /// 有些系统没注册 ipa 类型，这里兜底
    static var ipaArchive: UTType {
        UTType(filenameExtension: "ipa") ?? .data
    }

    static var pkcs12: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }

    static var mobileProvision: UTType {
        UTType(filenameExtension: "mobileprovision") ?? .data
    }
}
