import LCSignCore
import SwiftUI
import UIKit

/// 诊断页：一键跑引擎自检，把每一步的结果摊开。
///
/// 存在的理由：「签名失败」这四个字信息量太低 —— 可能是引擎根本没起来，
/// 也可能是证书有问题，两者的排查方向完全不同。自检不需要证书，
/// 所以正好能把这两类原因切开。
///
/// 第二个用途是**取证**。之前排查一次真机崩溃，来回好几轮都在靠用户口述
/// 界面上的文字。所以这里加了一键复制完整报告 —— 环境信息 + 每一步的
/// 结果与细节，一条文本就能贴进任何地方。
struct DiagnosticsView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var report: EngineSelfTest.Report?
    @State private var isRunning = false
    @State private var didCopy = false
    /// 本次没跑、但上一次有失败时，用它提醒一下
    @State private var lastFailureHint: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    healthBanner
                    runSection

                    if let report {
                        stepsSection(report)
                    }

                    environmentSection
                    copySection
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear(perform: adoptStoredRecord)
        }
        .navigationViewStyle(.stack)
    }

    /// 打开页面时，如果本次还没跑过，就用上一次的记录提示一下。
    private func adoptStoredRecord() {
        guard report == nil, let record = model.lastSelfTest else { return }
        if !record.isHealthy, let step = record.failedStep {
            lastFailureHint = "上次自检在「\(step)」失败（\(formattedRelative(record.date))）"
        } else {
            lastFailureHint = nil
        }
    }

    // MARK: - 健康横幅

    private var healthBanner: some View {
        let state = bannerState

        return VStack(alignment: .leading, spacing: Metric.Space.m) {
            HStack(spacing: Metric.Space.m) {
                IconBadge(symbol: state.symbol, tint: state.tint, size: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(state.subtitle)
                        .font(Typo.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let report {
                HStack(spacing: Metric.Space.l) {
                    stat(value: "\(report.steps.count - report.failureCount)",
                         title: "通过",
                         tint: Brand.success)
                    stat(value: "\(report.failureCount)",
                         title: "失败",
                         tint: report.failureCount == 0 ? .secondary : Brand.danger)
                    stat(value: String(format: "%.1f", report.elapsed),
                         title: "秒",
                         tint: Brand.accent)
                }
            } else if let lastFailureHint {
                NoticeBar(level: .danger, text: lastFailureHint)
            }
        }
        .padding(Metric.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.card,
                                    style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                .strokeBorder(state.tint.opacity(0.35), lineWidth: 1)
        )
    }

    private var bannerState: (title: String, subtitle: String, symbol: String, tint: Color) {
        if isRunning {
            return ("正在自检…", "会临时构造一个 .app 并完整跑一遍打包与签名", "hourglass", Brand.accent)
        }
        if let report {
            if report.isHealthy {
                return ("引擎工作正常",
                        "自检不需要证书。之后真签名若失败，原因就在证书或描述文件上。",
                        "checkmark.seal.fill", Brand.success)
            }
            return ("引擎自检未通过",
                    "下面每一步的结果里，标红的那一步就是问题所在。",
                    "exclamationmark.triangle.fill", Brand.danger)
        }
        return ("尚未运行自检",
                "自检不需要证书，可以随时跑一次，用来把「引擎问题」和「证书问题」分开。",
                "stethoscope", Brand.accent)
    }

    private func stat(value: String, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .monospacedDigit()
            Text(title)
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 运行

    private var runSection: some View {
        VStack(spacing: Metric.Space.s) {
            Button(action: run) {
                HStack(spacing: Metric.Space.s) {
                    if isRunning {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isRunning ? "自检中，请稍候…" : "运行引擎自检")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(isRunning)

            Text("流程：构造合成 .app → 打包 → 解包 → 校验往返内容 → ad-hoc 签名 → 校验产物")
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - 步骤时间线

    private func stepsSection(_ report: EngineSelfTest.Report) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "自检步骤",
                          trailing: report.isHealthy
                              ? "全部通过" : "\(report.failureCount) 项未通过")

            Card {
                VStack(alignment: .leading, spacing: 0) {
                    // 用下标而不是 `Array(steps.enumerated())` + 双参数闭包：
                    // 后者依赖闭包对元组参数的解构，各版本编译器接受度不一致，
                    // 而这里本来就不需要那个语法糖。
                    ForEach(report.steps.indices, id: \.self) { index in
                        StepTimelineRow(
                            step: report.steps[index],
                            isLast: index == report.steps.count - 1
                        )
                    }
                }
            }
        }
    }

    // MARK: - 运行环境

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "运行环境")

            Card {
                VStack(alignment: .leading, spacing: Metric.Space.l) {
                    InfoRow(title: "系统",
                            value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    InfoRow(title: "机型", value: Self.machineIdentifier, monospaced: true)
                    InfoRow(title: "应用版本", value: Self.appVersion, monospaced: true)
                    InfoRow(title: "可用空间", value: Self.freeSpace, monospaced: true)
                    InfoRow(title: "容器目录", value: NSHomeDirectory(),
                            monospaced: true, selectable: true)
                }
            }
        }
    }

    // MARK: - 复制报告

    private var copySection: some View {
        VStack(spacing: Metric.Space.s) {
            Button {
                UIPasteboard.general.string = diagnosticReport()
                withAnimation(.easeOut(duration: 0.2)) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                }
            } label: {
                Label(didCopy ? "已复制到剪贴板" : "复制诊断报告",
                      systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(GhostActionStyle(tint: didCopy ? Brand.success : Brand.accent))

            Text("复制出来的是一段纯文本：环境信息 + 每一步的结果与细节。"
               + "反馈问题时把它贴出来，比口述界面上的文字准确得多。")
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metric.Space.s)
        }
    }

    /// 把当前页面上的信息拼成一段可粘贴的文本。
    private func diagnosticReport() -> String {
        var lines: [String] = []
        lines.append("LCSign 诊断报告")
        lines.append("生成时间：\(Self.timestampFormatter.string(from: Date()))")
        lines.append("")
        lines.append("[运行环境]")
        lines.append("系统：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("机型：\(Self.machineIdentifier)")
        lines.append("应用版本：\(Self.appVersion)")
        lines.append("可用空间：\(Self.freeSpace)")
        lines.append("容器目录：\(NSHomeDirectory())")
        lines.append("")
        lines.append("[引擎自检]")

        if let report {
            lines.append("结果：\(report.isHealthy ? "全部通过" : "\(report.failureCount) 项未通过")")
            lines.append("耗时：\(String(format: "%.2f", report.elapsed)) 秒")
            lines.append("")
            for (index, step) in report.steps.enumerated() {
                let mark = step.outcome.isFailure ? "FAIL" : "PASS"
                lines.append("\(index + 1). [\(mark)] \(step.title)")
                lines.append("   \(step.outcome.text)")
                if !step.detail.isEmpty {
                    lines.append("   \(step.detail)")
                }
            }
        } else if let record = model.lastSelfTest {
            lines.append("（本次未运行，以下是上一次的记录）")
            lines.append("时间：\(Self.timestampFormatter.string(from: record.date))")
            lines.append("结果：\(record.isHealthy ? "全部通过" : "\(record.failureCount) 项未通过")")
            if let step = record.failedStep {
                lines.append("失败步骤：\(step)")
            }
        } else {
            lines.append("（尚未运行）")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 动作

    private func run() {
        guard !isRunning else { return }
        isRunning = true
        lastFailureHint = nil

        Task {
            // 自检要解压、要签名，扔到后台去，别卡住界面。
            // 复用 model 里的方法，这样结果会一并持久化到首页的状态板上。
            let result = await model.runSelfTest()
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

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - 时间线单步

private struct StepTimelineRow: View {

    let step: EngineSelfTest.Step
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Metric.Space.m) {
            markerColumn

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Text(step.outcome.text)
                    .font(Typo.caption)
                    .foregroundColor(tint)
                    .fixedSize(horizontal: false, vertical: true)

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(Typo.identifier(11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : Metric.Space.l)
        }
    }

    /// 左边一列：圆点 + 连接线。连接线用固定宽度 + 弹性高度，
    /// 这样整条线会跟着右侧文字的高度伸展，不会断开。
    private var markerColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 26, height: 26)
                // 不用 outcome.symbolName（那是给列表用的实心圆图标），
                // 套在彩色圆底上会变成「圆里再套一个圆」。
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(tint)
            }

            if !isLast {
                Rectangle()
                    .fill(Brand.hairline)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 26)
    }

    private var symbol: String {
        switch step.outcome {
        case .passed:  return "checkmark"
        case .failed:  return "xmark"
        case .skipped: return "minus"
        }
    }

    private var tint: Color {
        switch step.outcome {
        case .passed:  return Brand.success
        case .failed:  return Brand.danger
        case .skipped: return .secondary
        }
    }
}
