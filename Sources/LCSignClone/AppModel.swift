import Foundation
import LCSignCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 任务模型

/// 一次签名任务在界面上的表示。
///
/// 比最初的版本多存了几样东西，都是「结果页需要展示」的信息：
/// 输入/产物大小、用时、使用的证书名、当前阶段的细节文案。
/// 这些在签名过程中本来就是已知的，丢掉之后再想显示就只能靠猜。
struct SigningTask: Identifiable {

    enum Status: Equatable {
        case running
        case success
        case failed(String)
    }

    let id = UUID()
    var name: String
    var bundleID: String?
    var certificateName: String

    /// 阶段名（来自 SigningService.Stage）
    var stage: String = "准备中"
    /// 阶段细节，比如「重新打包 42%」
    var detail: String = ""
    var fraction: Double = 0

    var status: Status = .running

    var inputURL: URL?
    var inputSize: Int64 = 0
    var outputURL: URL?
    var outputSize: Int64 = 0

    var startedAt = Date()
    var finishedAt: Date?

    var isRunning: Bool { status == .running }

    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// 压缩率。只展示不参与逻辑，纯粹是「产物看着正常」的一个直观信号。
    var compressionRatio: Double? {
        guard inputSize > 0, outputSize > 0 else { return nil }
        return Double(outputSize) / Double(inputSize)
    }
}

/// 上一次引擎自检的结果，持久化后首页才能一直显示健康状态。
struct SelfTestRecord: Codable, Equatable {

    var date: Date
    var failureCount: Int
    var stepCount: Int
    var elapsed: TimeInterval
    /// 第一个失败的步骤名，方便在首页直接说清是哪一步挂了
    var failedStep: String?

    var isHealthy: Bool { failureCount == 0 }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {

    @Published var certificates: [SigningCertificate] = []
    @Published var tasks: [SigningTask] = []
    @Published var alert: AlertPayload?
    @Published var lastSelfTest: SelfTestRecord?

    /// 从其他 App 通过分享菜单投递进来的 IPA，等用户在签名界面确认
    @Published var pendingIPA: URL?

    /// 上次用过的证书，下次打开签名页默认选中它
    @Published var preferredCertificateID: UUID?

    struct AlertPayload: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private let store = CertificateStore.shared
    private let service = SigningService()

    private static let selfTestKey = "lastSelfTestRecord"
    private static let preferredCertificateKey = "preferredCertificateID"

    init() {
        lastSelfTest = Self.loadSelfTestRecord()
        if let raw = UserDefaults.standard.string(forKey: Self.preferredCertificateKey) {
            preferredCertificateID = UUID(uuidString: raw)
        }
    }

    /// 最近一次任务（首页顶部状态条用）
    var latestTask: SigningTask? { tasks.first }

    var usableCertificates: [SigningCertificate] {
        certificates.filter(\.isUsable)
    }

    // MARK: - 证书

    func refreshCertificates() async {
        do {
            certificates = try await store.all()
            // 首选证书被删掉了就清掉偏好，否则签名页会选中一个不存在的项
            if let id = preferredCertificateID,
               !certificates.contains(where: { $0.id == id }) {
                setPreferredCertificate(nil)
            }
        } catch {
            present(error, title: "读取证书库失败")
        }
    }

    func setPreferredCertificate(_ id: UUID?) {
        preferredCertificateID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: Self.preferredCertificateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.preferredCertificateKey)
        }
    }

    func importCertificate(p12: URL,
                           password: String,
                           provision: URL?,
                           displayName: String?) async -> Bool {
        do {
            // 沙盒外的文件先搬进来，否则后续签名时权限已被回收
            let localP12 = try Self.copyIntoSandbox(p12)
            let localProvision = try provision.map(Self.copyIntoSandbox)

            let cert = try await store.add(
                p12: localP12,
                password: password,
                provision: localProvision,
                displayName: (displayName?.isEmpty == true) ? nil : displayName
            )

            try? FileManager.default.removeItem(at: localP12)
            if let localProvision { try? FileManager.default.removeItem(at: localProvision) }

            await refreshCertificates()
            setPreferredCertificate(cert.id)
            return true
        } catch {
            present(error, title: "导入证书失败")
            return false
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

        var task = SigningTask(name: input.deletingPathExtension().lastPathComponent,
                               certificateName: certificate.displayName)
        task.bundleID = bundleID
        tasks.insert(task, at: 0)
        let taskID = task.id

        do {
            // 把输入留在任务专属目录里而不是用完即删：
            // 失败后「重试」需要它，而用户从「文件」App 选的 URL 出了作用域就失效了。
            let localInput = try Self.stageInput(input, taskID: taskID)
            update(taskID) {
                $0.inputURL = localInput
                $0.inputSize = Self.fileSize(localInput)
            }

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
                    self.tasks[index].detail = progress.detail
                    // 进度只允许前进：解包 / 校验这类阶段没有细粒度进度，
                    // 若允许回退，进度条会在阶段切换时来回跳。
                    self.tasks[index].fraction = max(self.tasks[index].fraction,
                                                     progress.fraction)
                }
            }

            let size = Self.fileSize(result)
            update(taskID) {
                $0.status = .success
                $0.stage = "已完成"
                $0.detail = "产物 \(formattedBytes(size))"
                $0.fraction = 1
                $0.outputURL = result
                $0.outputSize = size
                $0.finishedAt = Date()
            }

            setPreferredCertificate(certificate.id)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                       ?? error.localizedDescription

            update(taskID) {
                $0.status = .failed(message)
                $0.stage = "失败"
                $0.detail = ""
                $0.finishedAt = Date()
            }

            // 失败信息同时留在任务卡上，不再弹窗打断 ——
            // 弹窗一关线索就没了，而这张卡会一直躺在列表里。
        }
    }

    /// 用原任务留下的输入重跑一次
    func retry(_ task: SigningTask) async {
        guard let input = task.inputURL,
              FileManager.default.fileExists(atPath: input.path) else {
            alert = AlertPayload(
                title: "无法重试",
                message: "这次任务的临时输入文件已被系统清理，请重新选择 IPA。"
            )
            return
        }
        guard let certificate = certificates.first(where: { $0.displayName == task.certificateName })
                ?? certificates.first(where: \.isUsable)
                ?? certificates.first else {
            alert = AlertPayload(title: "无法重试", message: "证书库是空的，请先导入证书。")
            return
        }

        await startSigning(input: input,
                           certificate: certificate,
                           password: nil,
                           bundleID: task.bundleID,
                           displayName: nil)
    }

    func removeTask(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        tasks.remove(at: index)
        discardInput(task)
    }

    func clearFinishedTasks() {
        let removed = tasks.filter { !$0.isRunning }
        tasks.removeAll { !$0.isRunning }
        for task in removed { discardInput(task) }
    }

    /// 删掉任务的输入文件 —— 但只在没有别的任务还指着它的时候。
    /// 「重试」是复用同一份输入起一个新任务，无脑删会把新任务的文件一起删掉。
    private func discardInput(_ task: SigningTask) {
        guard let input = task.inputURL else { return }
        guard !tasks.contains(where: { $0.inputURL == input }) else { return }
        try? FileManager.default.removeItem(at: input)
    }

    // MARK: - 引擎自检

    /// 跑一次自检并把结果持久化。首页据此显示健康状态。
    func runSelfTest() async -> EngineSelfTest.Report {
        let report = await Task.detached(priority: .userInitiated) {
            EngineSelfTest.run()
        }.value

        let record = SelfTestRecord(
            date: report.finishedAt,
            failureCount: report.failureCount,
            stepCount: report.steps.count,
            elapsed: report.elapsed,
            failedStep: report.steps.first { $0.outcome.isFailure }?.title
        )
        lastSelfTest = record
        Self.saveSelfTestRecord(record)
        return report
    }

    private static func loadSelfTestRecord() -> SelfTestRecord? {
        guard let data = UserDefaults.standard.data(forKey: selfTestKey) else { return nil }
        return try? JSONDecoder().decode(SelfTestRecord.self, from: data)
    }

    private static func saveSelfTestRecord(_ record: SelfTestRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: selfTestKey)
    }

    // MARK: - 工具

    private func update(_ id: UUID, _ mutate: (inout SigningTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

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

    /// 把输入文件收进任务专属目录，供签名与重试共用。
    ///
    /// 刻意不用 `copyIntoSandbox`：那个每次都会生成新名字，重试时就没法复用了。
    static func stageInput(_ url: URL, taskID: UUID) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCSignInputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                               withIntermediateDirectories: true)

        let extensionName = url.pathExtension.isEmpty ? "ipa" : url.pathExtension
        let destination = directory
            .appendingPathComponent(taskID.uuidString)
            .appendingPathExtension(extensionName)

        try? FileManager.default.removeItem(at: destination)

        // 已经在沙盒里（重试路径）就直接用，不必再拷一份大文件
        if url.path.hasPrefix(directory.path) {
            return url
        }
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

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
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
