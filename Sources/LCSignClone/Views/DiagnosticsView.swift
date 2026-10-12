import LCSignCore
import SwiftUI
import UIKit

/// 诊断页：一键跑引擎自检，把每一步的结果摊开。
///
/// 存在的理由：「签名失败」这四个字信息量太低 —— 可能是引擎根本没起来，
/// 也可能是证书有问题，两者的排查方向完全不同。自检不需要证书，
/// 所以正好能把这两类原因切开。
struct DiagnosticsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var report: EngineSelfTest.Report?
    @State private var isRunning = false

    var body: some View {
        NavigationView {
            List {
                runSection

                if let report {
                    resultSection(report)
                }

                environmentSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 自检

    private var runSection: some View {
        Section {
            Button {
                run()
            } label: {
                HStack {
                    Label("运行引擎自检", systemImage: "stethoscope")
                    Spacer()
                    if isRunning { ProgressView() }
                }
            }
            .disabled(isRunning)
        } footer: {
            Text("自检不需要证书，会临时构造一个 .app 并完整跑一遍"
               + "「打包 → 解包 → 签名 → 校验产物」。\n"
               + "自检通过说明签名引擎本身没问题，之后真签名再失败，"
               + "原因就一定在证书或描述文件上。")
        }
    }

    private func resultSection(_ report: EngineSelfTest.Report) -> some View {
        Section {
            ForEach(report.steps) { step in
                StepRow(step: step)
            }
        } header: {
            Text(report.isHealthy ? "全部通过" : "\(report.failureCount) 项未通过")
        } footer: {
            Text("耗时 \(String(format: "%.2f", report.elapsed)) 秒")
        }
    }

    // MARK: - 运行环境

    private var environmentSection: some View {
        Section("运行环境") {
            InfoRow(title: "系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            InfoRow(title: "机型", value: Self.machineIdentifier)
            InfoRow(title: "应用版本", value: Self.appVersion)
            InfoRow(title: "可用空间", value: Self.freeSpace)
            InfoRow(title: "容器目录", value: NSHomeDirectory())
        }
    }

    // MARK: - 动作

    private func run() {
        guard !isRunning else { return }
        isRunning = true

        Task {
            // 自检要解压、要签名，扔到后台去，别卡住界面
            let result = await Task.detached(priority: .userInitiated) {
                EngineSelfTest.run()
            }.value

            report = result
            isRunning = false
        }
    }

    // MARK: - 环境信息

    private static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static var freeSpace: String {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return "未知"
        }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }
}

// MARK: - 单步结果

private struct StepRow: View {

    let step: EngineSelfTest.Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.outcome.symbolName)
                .foregroundColor(tint)
                .font(.system(size: 16))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 15, weight: .medium))

                Text(step.outcome.text)
                    .font(.caption)
                    .foregroundColor(tint)

                Text(step.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch step.outcome {
        case .passed:  return .green
        case .failed:  return .red
        case .skipped: return .gray
        }
    }
}

// MARK: - 键值行

private struct InfoRow: View {

    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14))
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
