import LCSignCore
import SwiftUI
import UIKit

struct HomeView: View {

    @EnvironmentObject private var model: AppModel

    /// 三个弹窗共用一个状态。
    ///
    /// 不要写成三个并列的 `.sheet(isPresented:)` —— SwiftUI 对同一个视图上
    /// 叠加多个 sheet 的处理并不一致，实测只有最后一个能稳定弹出来。
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case sign, certificates, diagnostics
        var id: String { rawValue }
    }

    var body: some View {
        navigationContent
            .navigationViewStyle(.stack)
            .task {
                await model.refreshCertificates()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .sign:         SignSheet()
                case .certificates: CertificateListView()
                case .diagnostics:  DiagnosticsView()
                }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: isShowingAlert,
                presenting: model.alert
            ) { _ in
                Button("好", role: .cancel) {}
            } message: { payload in
                Text(payload.message)
            }
    }

    /// 拆出来单独算：直接写在 body 里会让类型检查器在
    /// NavigationView + toolbar + sheet + alert 的链式调用上超时。
    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )
    }

    // MARK: - 骨架

    private var navigationContent: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    StatusBoard(model: model)
                    primaryAction
                    quickTiles

                    if let certificate = featuredCertificate {
                        certificateSection(certificate)
                    }

                    tasksSection

                    footer
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("LCSign")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .certificates
            } label: {
                Image(systemName: "key.fill")
            }
            .accessibilityLabel("证书库")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .diagnostics
            } label: {
                Image(systemName: "stethoscope")
            }
            .accessibilityLabel("诊断")
        }
    }

    /// 首页只展示一张「当前证书」：优先用用户上次选中的那张，
    /// 否则用第一张可用的。全都在证书库里，不在这里堆。
    private var featuredCertificate: SigningCertificate? {
        if let id = model.preferredCertificateID,
           let match = model.certificates.first(where: { $0.id == id }) {
            return match
        }
        return model.usableCertificates.first ?? model.certificates.first
    }

    // MARK: - 主操作

    private var primaryAction: some View {
        Button {
            activeSheet = .sign
        } label: {
            HStack(spacing: Metric.Space.m) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 20, weight: .semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("选择 IPA 并重签名")
                        .font(.system(size: 17, weight: .semibold))
                    Text(primaryActionSubtitle)
                        .font(Typo.micro)
                        .opacity(0.85)
                }

                Spacer(minLength: Metric.Space.s)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.8)
            }
            .padding(.horizontal, Metric.Space.l)
            .padding(.vertical, Metric.Space.l)
        }
        .buttonStyle(PrimaryActionStyle())
        .disabled(model.usableCertificates.isEmpty)
    }

    private var primaryActionSubtitle: String {
        if model.certificates.isEmpty { return "还没有证书，先导入 p12 与描述文件" }
        if model.usableCertificates.isEmpty { return "现有证书不可用，请检查有效期与配对情况" }
        return "当前证书：\(featuredCertificate?.displayName ?? "—")"
    }

    // MARK: - 快捷入口

    private var quickTiles: some View {
        HStack(spacing: Metric.Space.m) {
            QuickTile(
                symbol: "key.fill",
                title: "证书库",
                subtitle: model.certificates.isEmpty
                    ? "尚未导入"
                    : "\(model.certificates.count) 张证书",
                badge: certificateBadge,
                tint: Brand.accent
            ) {
                activeSheet = .certificates
            }

            QuickTile(
                symbol: "stethoscope",
                title: "引擎自检",
                subtitle: selfTestSubtitle,
                badge: selfTestBadge,
                tint: selfTestTint
            ) {
                activeSheet = .diagnostics
            }
        }
    }

    // 显式写全类型而不是 `.init(...)`：返回类型是 Optional，
    // 隐式成员查找能不能穿过 Optional 各版本表现不一致。
    private var certificateBadge: QuickTile.Badge? {
        if model.certificates.isEmpty {
            return QuickTile.Badge(text: "空", tint: Brand.warning)
        }
        if model.usableCertificates.isEmpty {
            return QuickTile.Badge(text: "不可用", tint: Brand.danger)
        }
        return QuickTile.Badge(text: "可用", tint: Brand.success)
    }

    private var selfTestSubtitle: String {
        guard let record = model.lastSelfTest else { return "尚未运行" }
        return formattedRelative(record.date)
    }

    private var selfTestBadge: QuickTile.Badge? {
        guard let record = model.lastSelfTest else { return nil }
        if record.isHealthy {
            return QuickTile.Badge(text: "通过", tint: Brand.success)
        }
        return QuickTile.Badge(text: "\(record.failureCount) 项失败", tint: Brand.danger)
    }

    private var selfTestTint: Color {
        guard let record = model.lastSelfTest else { return Brand.accent }
        return record.isHealthy ? Brand.success : Brand.danger
    }

    // MARK: - 当前证书

    private func certificateSection(_ certificate: SigningCertificate) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "当前证书",
                          trailing: model.certificates.count > 1
                              ? "共 \(model.certificates.count) 张" : nil)

            Button {
                activeSheet = .certificates
            } label: {
                CertificateCard(certificate: certificate)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 任务

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(
                title: "签名记录",
                trailing: model.tasks.isEmpty ? nil : "\(model.tasks.count) 条"
            )

            if model.tasks.isEmpty {
                Card {
                    HStack(spacing: Metric.Space.m) {
                        IconBadge(symbol: "tray", tint: .secondary, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有签名记录")
                                .font(Typo.body)
                                .foregroundColor(.primary)
                            Text("签名完成后，产物会出现在这里，可以直接导出。")
                                .font(Typo.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                if model.tasks.contains(where: { !$0.isRunning }) {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                model.clearFinishedTasks()
                            }
                        } label: {
                            Label("清除已完成", systemImage: "trash")
                        }
                        .buttonStyle(GhostActionStyle(tint: .secondary, compact: true))
                    }
                }

                ForEach(model.tasks) { task in
                    TaskCard(
                        task: task,
                        onRetry: { Task { await model.retry(task) } },
                        onRemove: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                model.removeTask(task.id)
                            }
                        }
                    )
                }
            }
        }
    }

    private var footer: some View {
        Text("签名产物保存在「文件」App → 我的 iPhone → LCSign → Signed 目录下，"
           + "也可以在任务卡上直接导出。")
            .font(Typo.micro)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metric.Space.s)
            .padding(.top, Metric.Space.s)
    }
}

// MARK: - 状态板

/// 首页顶部的状态板：一眼看清「证书有没有、引擎行不行、上一条任务成没成」。
///
/// 之前首页只有一句「还没有签名任务」，用户得点进两个弹窗才能知道状态 ——
/// 这是最影响观感的地方：界面没有信息，自然显得空且粗糙。
private struct StatusBoard: View {

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.Space.l) {
            header
            metrics
        }
        .padding(Metric.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 渐变与水印都放进 background，再统一 clipShape ——
        // 水印用了负偏移，挂在 overlay 上会溢出圆角。
        // 名字不叫 background：那会和 View.background 修饰符撞名。
        .background(backgroundLayer)
        .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.hero,
                                    style: .continuous))
        .shadow(color: Brand.accentDeep.opacity(0.28), radius: 18, x: 0, y: 8)
    }

    private var backgroundLayer: some View {
        ZStack(alignment: .topTrailing) {
            Brand.heroGradient

            // 角上的大号水印符号，纯装饰，给渐变面一点层次
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 132, weight: .bold))
                .foregroundColor(.white.opacity(0.10))
                .offset(x: 26, y: -22)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: Metric.Space.m) {
            Image(systemName: "signature")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subheadline)
                    .font(Typo.micro)
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(title: "证书", value: "\(model.certificates.count)",
                   caption: model.usableCertificates.isEmpty ? "不可用" : "可用")
            divider
            metric(title: "记录", value: "\(model.tasks.count)",
                   caption: model.tasks.isEmpty ? "暂无" : "条")
            divider
            metric(title: "引擎", value: engineValue, caption: engineCaption)
        }
        .padding(.vertical, Metric.Space.m)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                    style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 1, height: 26)
    }

    private func metric(title: String, value: String, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Typo.micro)
                .foregroundColor(.white.opacity(0.7))
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 文案

    private var headline: String {
        if model.certificates.isEmpty { return "先导入一张签名证书" }
        if model.usableCertificates.isEmpty { return "现有证书不可用" }
        if let record = model.lastSelfTest, !record.isHealthy {
            return "引擎自检未通过"
        }
        if let task = model.latestTask, task.isRunning { return "正在签名…" }
        if let task = model.latestTask, case .success = task.status { return "就绪，上次签名成功" }
        return "就绪"
    }

    private var subheadline: String {
        if model.certificates.isEmpty {
            return "需要 p12 证书 + 配套的 mobileprovision 描述文件"
        }
        if model.usableCertificates.isEmpty {
            return "证书已过期、缺少描述文件，或 Team 与描述文件不一致"
        }
        if let record = model.lastSelfTest, !record.isHealthy {
            let step = record.failedStep.map { "「\($0)」" } ?? "某一步"
            return "上次自检在 \(step) 失败，点右上角诊断查看详情"
        }
        return "选一个 IPA，用当前证书重新签名"
    }

    private var engineValue: String {
        guard let record = model.lastSelfTest else { return "未测" }
        return record.isHealthy ? "正常" : "异常"
    }

    private var engineCaption: String {
        guard let record = model.lastSelfTest else { return "未运行" }
        return record.isHealthy ? "全部通过" : "\(record.failureCount) 项失败"
    }
}

// MARK: - 快捷方块

private struct QuickTile: View {

    struct Badge {
        let text: String
        let tint: Color
    }

    let symbol: String
    let title: String
    let subtitle: String
    let badge: Badge?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Metric.Space.s) {
                HStack {
                    IconBadge(symbol: symbol, tint: tint, size: 36)
                    Spacer(minLength: 0)
                    if let badge {
                        StatusPill(text: badge.text, tint: badge.tint)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Typo.cardTitle)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(Typo.micro)
                        .fontWeight(.regular)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(Metric.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface)
            .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.card,
                                        style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 证书卡片

struct CertificateCard: View {

    let certificate: SigningCertificate

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                HStack(spacing: Metric.Space.m) {
                    IconBadge(symbol: "checkmark.seal.fill",
                              tint: Brand.tint(for: certificate.expiryLevel),
                              size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(certificate.displayName)
                            .font(Typo.cardTitle)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(certificate.teamID.isEmpty ? "未知 Team" : certificate.teamID)
                            .font(Typo.identifier(12))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: Metric.Space.s)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                if let provision = certificate.provision {
                    Text(provision.applicationIdentifier)
                        .font(Typo.identifier(12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                VStack(alignment: .leading, spacing: Metric.Space.xs) {
                    HStack {
                        Text(certificate.expiryDescription)
                            .font(Typo.micro)
                            .fontWeight(.regular)
                            .foregroundColor(Brand.tint(for: certificate.expiryLevel))
                        Spacer()
                        if !certificate.isUsable {
                            Text(problemText)
                                .font(Typo.micro)
                                .foregroundColor(Brand.danger)
                        }
                    }
                    Meter(value: validityFraction, tint: Brand.tint(for: certificate.expiryLevel))
                }
            }
        }
    }

    /// 有效期剩余比例（相对 365 天），用于进度条。纯展示。
    private var validityFraction: Double {
        guard !certificate.isExpired else { return 0 }
        return min(1, Double(certificate.daysRemaining) / 365)
    }

    private var problemText: String {
        if certificate.isExpired { return "已过期" }
        if certificate.provisionRelativePath == nil { return "缺描述文件" }
        if !certificate.isPaired { return "Team 不匹配" }
        return "不可用"
    }
}

// MARK: - 任务卡片

struct TaskCard: View {

    let task: SigningTask
    let onRetry: () -> Void
    let onRemove: () -> Void

    @State private var showingShare = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                header
                progress
                result
            }
        }
        .contextMenu {
            Button(role: .destructive, action: onRemove) {
                Label("删除这条记录", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showingShare) {
            if let output = task.outputURL {
                ActivityView(items: [output])
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: Metric.Space.m) {
            IconBadge(symbol: statusSymbol, tint: statusTint, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(Typo.cardTitle)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(secondaryLine)
                    .font(Typo.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Metric.Space.s)

            if task.isRunning {
                ProgressView()
            } else {
                StatusPill(text: statusText, tint: statusTint, symbol: statusSymbol)
            }
        }
    }

    private var secondaryLine: String {
        switch task.status {
        case .running:
            return task.detail.isEmpty ? task.stage : "\(task.stage) · \(task.detail)"
        case .success:
            return "\(task.certificateName) · 用时 \(formattedDuration(task.elapsed))"
        case .failed:
            return "\(task.certificateName) · 用时 \(formattedDuration(task.elapsed))"
        }
    }

    // MARK: 进度

    @ViewBuilder
    private var progress: some View {
        if task.isRunning {
            VStack(alignment: .leading, spacing: Metric.Space.xs) {
                Meter(value: task.fraction)
                HStack {
                    Text(task.stage)
                        .font(Typo.micro)
                        .fontWeight(.regular)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(task.fraction * 100))%")
                        .font(Typo.micro)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: 结果

    @ViewBuilder
    private var result: some View {
        switch task.status {
        case .running:
            EmptyView()

        case .success:
            successResult

        case .failed(let message):
            failedResult(message)
        }
    }

    private var successResult: some View {
        VStack(alignment: .leading, spacing: Metric.Space.m) {
            HStack(spacing: Metric.Space.l) {
                if task.outputSize > 0 {
                    stat(title: "产物", value: formattedBytes(task.outputSize))
                }
                if task.inputSize > 0 {
                    stat(title: "原始", value: formattedBytes(task.inputSize))
                }
                if let ratio = task.compressionRatio {
                    stat(title: "压缩比", value: String(format: "%.0f%%", ratio * 100))
                }
                Spacer(minLength: 0)
            }

            if task.outputURL != nil {
                Button {
                    showingShare = true
                } label: {
                    Label("导出 IPA", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryActionStyle(compact: true))
            }
        }
    }

    private func failedResult(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.m) {
            NoticeBar(level: .danger, text: message)

            HStack(spacing: Metric.Space.s) {
                Button {
                    onRetry()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GhostActionStyle(compact: true))

                Button(role: .destructive, action: onRemove) {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(GhostActionStyle(tint: Brand.danger, compact: true))
            }
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .monospacedDigit()
        }
    }

    // MARK: 状态

    private var statusSymbol: String {
        switch task.status {
        case .running: return "gearshape.2.fill"
        case .success: return "checkmark"
        case .failed:  return "exclamationmark"
        }
    }

    private var statusText: String {
        switch task.status {
        case .running: return "进行中"
        case .success: return "已完成"
        case .failed:  return "失败"
        }
    }

    private var statusTint: Color {
        switch task.status {
        case .running: return Brand.accent
        case .success: return Brand.success
        case .failed:  return Brand.danger
        }
    }
}

// MARK: - 分享面板

/// 用 UIActivityViewController 而不是 ShareLink —— 后者需要 iOS 16，
/// 而本项目的 deployment target 是 15.0。
struct ActivityView: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}

// MARK: - 小工具

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前
func formattedRelative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
    if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
    return "\(Int(seconds / 86_400)) 天前"
}
